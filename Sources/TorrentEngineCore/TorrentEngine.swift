import Foundation
import Synchronization
import TorrentBridge
import TorrentEngineModel
import TorrentMetainfo

private func stringFromBridgeBuffer(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
    return String(decoding: bytes, as: UTF8.self)
}

@safe private final class TorrentWakeRelay: Sendable {
    private struct State: Sendable {
        var continuation: AsyncStream<Void>.Continuation?
    }

    private let state: Mutex<State>
    private let streamStorage: AsyncStream<Void>

    var stream: AsyncStream<Void> {
        streamStorage
    }

    init() {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        streamStorage = stream.stream
        state = Mutex(State(continuation: stream.continuation))
    }

    func signal() {
        let continuation = state.withLock { state in
            state.continuation
        }
        continuation?.yield(())
    }

    func finish() {
        let continuation = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.finish()
    }

    deinit {
        finish()
    }
}

// SAFETY: Ownership/lifetime: TorrentClientHandle keeps the relay alive while native may
// invoke this nonescaping callback; bounds/alignment: the opaque pointer is the exact class
// pointer installed at registration and no bytes are indexed; synchronization: signal uses
// Mutex and is callback-thread safe; safe alternative: the C callback ABI cannot carry a
// managed Swift reference.
private func torrentWakeCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context = unsafe context else {
        return
    }

    let relay = unsafe Unmanaged<TorrentWakeRelay>.fromOpaque(context).takeUnretainedValue()
    relay.signal()
}

package typealias TorrentClientCreationPreflight = @Sendable (
    _ stateDirectory: URL,
    _ enablePeerExchangePlugin: Bool
) throws -> Void

package typealias TorrentAlertErrorReader = @Sendable () -> String?

package enum TorrentAddError: LocalizedError, Sendable {
    case rejected(String)
    case commitStatusUnknown(String)

    package var errorDescription: String? {
        switch self {
        case .rejected(let message), .commitStatusUnknown(let message):
            message.isEmpty ? "The torrent could not be added." : message
        }
    }
}

private struct AddedTorrentIdentity: Sendable {
    let id: String
    let nativeToken: UInt64
}

@safe package struct TorrentEngineCriticalFaults: OptionSet, Sendable {
    package let rawValue: UInt32

    package init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    package static let sessionIdentityAuthority = Self(
        rawValue: UInt32(TTORRENT_CRITICAL_FAULT_SESSION_IDENTITY_AUTHORITY)
    )
    package static let networkContainmentUnconfirmed = Self(
        rawValue: UInt32(TTORRENT_CRITICAL_FAULT_NETWORK_CONTAINMENT_UNCONFIRMED)
    )
    package static let invalidNativeSignal = Self(rawValue: 1 << 31)
    package static let allKnown: Self = [
        .sessionIdentityAuthority,
        .networkContainmentUnconfirmed,
    ]
}

@safe package actor TorrentEngine {
    package static let clientCreationPreflight = Mutex<TorrentClientCreationPreflight?>(nil)

    private let stateDirectory: URL?
    private let payloadBroker: (any TorrentPayloadBrokerAccess)?
    private let alertErrorReader: TorrentAlertErrorReader?
    package nonisolated let startupFailureMessage: String?
    private let runtimeFailureMessage = Mutex<String?>(nil)
    private let wakeRelay = TorrentWakeRelay()
    private var client: TorrentClientHandle?
    private var identityStore = TorrentIdentityStore()
    private var persistenceStore = TorrentPersistenceStore()
    private var snapshotStore = TorrentSnapshotStore()
    private var detailStore = TorrentDetailStore()
    private var trackerHostStore = TorrentTrackerHostStore()
    private var queueStore = TorrentQueueStore()
    private var sourcePolicyStore = TorrentSourcePolicyStore()
    private var queueNeedsApplication = false
    private var sourcePolicyNeedsApplication = false
    package private(set) var criticalFaults: TorrentEngineCriticalFaults = []
    private var pendingPersistenceErrors = [String]()
    private var isShutdown = false
    package nonisolated let libtorrentVersion: String

    // SAFETY: Ownership/lifetime: the bridge version pointer has process-static lifetime;
    // bounds/alignment: the bridge contract guarantees a NUL-terminated CChar sequence;
    // synchronization: immutable version storage is read during actor initialization;
    // safe alternative: the C bridge exposes its version only as a C string pointer.
    package init(
        stateDirectory: URL,
        enablePeerExchangePlugin: Bool,
        payloadBroker: any TorrentPayloadBrokerAccess,
        alertErrorReader: TorrentAlertErrorReader? = nil
    ) throws {
        self.stateDirectory = stateDirectory
        self.payloadBroker = payloadBroker
        self.alertErrorReader = alertErrorReader
        sourcePolicyStore = TorrentSourcePolicyStore(
            enablePeerExchangePlugin: enablePeerExchangePlugin
        )
        startupFailureMessage = nil
        unsafe libtorrentVersion = String(cString: TorrentBridgeLibtorrentVersion())
        client = try Self.createClient(
            stateDirectory: stateDirectory,
            wakeRelay: wakeRelay,
            enablePeerExchangePlugin: enablePeerExchangePlugin,
            payloadBroker: payloadBroker
        )
    }

    // SAFETY: Ownership/lifetime: the bridge version pointer has process-static lifetime;
    // bounds/alignment: the bridge contract guarantees a NUL-terminated CChar sequence;
    // synchronization: immutable version storage is read during actor initialization;
    // safe alternative: the C bridge exposes its version only as a C string pointer.
    package init(startupFailureMessage: String) {
        stateDirectory = nil
        payloadBroker = nil
        alertErrorReader = nil
        self.startupFailureMessage = startupFailureMessage
        unsafe libtorrentVersion = String(cString: TorrentBridgeLibtorrentVersion())
        client = nil
    }

    package nonisolated var isAvailable: Bool {
        startupFailureMessage == nil && runtimeFailureMessage.withLock { $0 == nil }
    }

    package func restart(
        enablePeerExchangePlugin: Bool
    ) throws {
        guard !isShutdown else {
            throw TorrentEngineError.bridgeError("The torrent engine has been shut down.")
        }
        guard let stateDirectory else {
            throw TorrentEngineError.startupFailed(startupFailureMessage ?? "")
        }
        guard let payloadBroker else {
            throw TorrentEngineError.startupFailed("The storage broker is unavailable.")
        }
        let hasRuntimeFailure = runtimeFailureMessage.withLock { $0 != nil }
        if !hasRuntimeFailure, client != nil {
            try saveAllChecked()
        }
        runtimeFailureMessage.withLock { $0 = nil }
        destroyClient(waitForShutdown: true)
        do {
            identityStore = TorrentIdentityStore()
            persistenceStore = TorrentPersistenceStore()
            pendingPersistenceErrors.removeAll(keepingCapacity: true)
            client = try Self.createClient(
                stateDirectory: stateDirectory,
                wakeRelay: wakeRelay,
                enablePeerExchangePlugin: enablePeerExchangePlugin,
                payloadBroker: payloadBroker
            )
            criticalFaults = []
            _ = sourcePolicyStore.setPeerExchangeAvailability(enablePeerExchangePlugin)
            queueNeedsApplication = true
            sourcePolicyNeedsApplication = true
        } catch {
            runtimeFailureMessage.withLock { $0 = error.localizedDescription }
            throw error
        }
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps each captured client pointer
    // alive until destroyClient after all synchronous bridge calls; bounds/alignment: called
    // helpers use typed scalars/spans and validate returned counts; synchronization: actor
    // isolation serializes shutdown and native blocking waits for worker quiescence;
    // safe alternative: the C++ client lifecycle is available only through the C bridge.
    package func shutdownSafely() async throws {
        guard let initialClient = unsafe client?.pointer else {
            isShutdown = true
            runtimeFailureMessage.withLock { message in
                if message == nil {
                    message = "The torrent engine was shut down safely."
                }
            }
            wakeRelay.finish()
            return
        }

        var errors = [String]()
        do {
            try unsafe blockNetwork(client: initialClient)
        } catch {
            let detail = error.localizedDescription
            forceContainmentAfterNetworkBlockFailure(detail: detail)
            throw TorrentEngineError.bridgeError(
                "The torrent engine was force-stopped after network blocking failed. \(detail)"
            )
        }

        isShutdown = true
        let shuttingDownMessage = "The torrent engine is shutting down safely."
        runtimeFailureMessage.withLock { message in
            if message == nil {
                message = shuttingDownMessage
            }
        }

        if let runtimeFailure = runtimeFailureMessage.withLock({ $0 }),
           runtimeFailure != shuttingDownMessage {
            errors.append(runtimeFailure)
        }
        if let currentClient = unsafe client?.pointer {
            do {
                try unsafe saveAllChecked(client: currentClient)
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        destroyClient(waitForShutdown: true)
        wakeRelay.finish()

        let failureMessage: String?
        if errors.isEmpty {
            failureMessage = nil
            runtimeFailureMessage.withLock { $0 = "The torrent engine was shut down safely." }
        } else {
            let detail = errors.joined(separator: " ")
            failureMessage = "The torrent engine was stopped, but safe shutdown reported an error. \(detail)"
            runtimeFailureMessage.withLock { $0 = failureMessage }
        }

        if let failureMessage {
            throw TorrentEngineError.bridgeError(failureMessage)
        }
    }

    /// Final fail-closed boundary for a native network-block failure. This may
    /// run while a removal poll is suspended; that poll validates shutdown
    /// immediately after every suspension before touching its captured pointer.
    package func forceContainmentAfterNetworkBlockFailure(detail: String = "") {
        let suffix = detail.isEmpty ? "" : " \(detail)"
        let message = "The torrent engine was force-stopped because network blocking failed.\(suffix)"
        isShutdown = true
        runtimeFailureMessage.withLock { $0 = message }
        destroyClient(waitForShutdown: true)
        wakeRelay.finish()
    }

    package func wakeEvents() -> AsyncStream<Void> {
        wakeRelay.stream
    }

    // SAFETY: Ownership/lifetime: the actor-owned client and all payload/output arrays live
    // through the synchronous add call; bounds/alignment: SafeInterop Span wrappers carry
    // exact element counts and the fixed output capacity is bridge-defined; synchronization:
    // actor isolation serializes client mutation; safe alternative: adding to the C++ engine
    // requires its C ABI despite bounded Swift wrappers.
    package func addMagnet(
        _ magnet: ParsedMagnet,
        startsPaused: Bool = false,
        queuePriority: TorrentQueuePriority = .normal,
        enablePeerExchange: Bool = true,
        httpsTrackerPolicy: TorrentHTTPSTrackerPolicyOverride = .inherit,
        httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicyOverride = .inherit,
        allowPreMetadataDHT: Bool = false
    ) throws -> String {
        let client = try unsafe requireClient()
        let bridgePayload = try TorrentMagnetBridgePayload(magnet)
        guard let requestedID = identityStore.makeCanonicalID() else {
            throw TorrentEngineError.bridgeError(
                "A unique Swift torrent identifier could not be generated."
            )
        }
        let sourcePolicy = sourcePolicyStore.addPolicy(
            enablePeerExchange: enablePeerExchange,
            httpsTrackerPolicy: httpsTrackerPolicy,
            httpsWebSeedPolicy: httpsWebSeedPolicy,
            allowPreMetadataDHT: allowPreMetadataDHT
        )
        let options = Self.nativeAddOptions(
            canonicalID: requestedID,
            startsPaused: startsPaused,
            queuePriority: queuePriority,
            sourcePolicy: sourcePolicy,
            httpsTrackerPolicy: httpsTrackerPolicy,
            httpsWebSeedPolicy: httpsWebSeedPolicy,
            allowPreMetadataDHT: allowPreMetadataDHT
        )
        let added = try unsafe throwingBridgeAdd(capacity: Int(TTORRENT_ID_CAPACITY)) { outputBuffer, nativeToken, addOutcome, errorBuffer in
            let blob: Span<UInt8>? = bridgePayload.blob.isEmpty
                ? nil
                : bridgePayload.blob.span
            let trackers: Span<TTorrentMagnetTracker>? = bridgePayload.trackers.isEmpty
                ? nil
                : bridgePayload.trackers.span
            let webSeeds: Span<TTorrentByteRange>? = bridgePayload.webSeeds.isEmpty
                ? nil
                : bridgePayload.webSeeds.span
            let fileSelections: Span<TTorrentFileSelectionRange>? =
                bridgePayload.fileSelections.isEmpty
                    ? nil
                    : bridgePayload.fileSelections.span
            return unsafe TorrentClientAddParsedMagnet(
                client,
                bridgePayload.header,
                blob,
                trackers,
                webSeeds,
                fileSelections,
                options,
                &outputBuffer,
                nativeToken,
                addOutcome,
                &errorBuffer
            )
        }
        guard added.id == requestedID,
              identityStore.registerAddedTorrent(id: added.id, nativeToken: added.nativeToken) else {
            throw TorrentAddError.commitStatusUnknown(
                "Torrent was added, but its Swift identity could not be registered."
            )
        }
        sourcePolicyStore.registerAddedTorrent(
            id: added.id,
            enablePeerExchange: enablePeerExchange,
            httpsTrackerPolicy: httpsTrackerPolicy,
            httpsWebSeedPolicy: httpsWebSeedPolicy,
            allowPreMetadataDHT: allowPreMetadataDHT
        )
        queueNeedsApplication = true
        sourcePolicyNeedsApplication = true
        return added.id
    }

    // SAFETY: Ownership/lifetime: the actor-owned client, parsed capsule, priorities, and
    // output buffers live through each synchronous add call; bounds/alignment: SafeInterop
    // spans carry exact element counts and fixed fields are populated by bounded helpers;
    // synchronization: actor isolation serializes client mutation; safe alternative: the
    // C++ engine can only consume the capsule through its C ABI.
    package func addTorrentFile(
        data: Data,
        activation: TorrentStorageActivation,
        filePriorities: [Int32: TorrentFilePriority]? = nil,
        startsPaused: Bool = false,
        queuePriority: TorrentQueuePriority = .normal,
        enablePeerExchange: Bool = true,
        httpsTrackerPolicy: TorrentHTTPSTrackerPolicyOverride = .inherit,
        httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicyOverride = .inherit
    ) throws -> String {
        let client = try unsafe requireClient()
        try Self.validateTorrentData(data)
        let metainfo = try TorrentMetainfoParser().parse(data)
        let capsule = try TorrentMetainfoBridgeCapsule(metainfo)
        guard let requestedID = activation.preservedTorrentID ?? identityStore.makeCanonicalID() else {
            throw TorrentEngineError.bridgeError(
                "A unique Swift torrent identifier could not be generated."
            )
        }
        let nativeActivation = Self.nativeStorageActivation(activation)
        let priorityEntries = filePriorities?
            .map { index, priority in
                TTorrentFilePriorityEntry(index: index, priority: priority.bridgeValue)
            }
            .sorted { $0.index < $1.index }
        let sourcePolicy = sourcePolicyStore.addPolicy(
            enablePeerExchange: enablePeerExchange,
            httpsTrackerPolicy: httpsTrackerPolicy,
            httpsWebSeedPolicy: httpsWebSeedPolicy,
            allowPreMetadataDHT: false
        )
        let options = Self.nativeAddOptions(
            canonicalID: requestedID,
            startsPaused: startsPaused,
            queuePriority: queuePriority,
            sourcePolicy: sourcePolicy,
            httpsTrackerPolicy: httpsTrackerPolicy,
            httpsWebSeedPolicy: httpsWebSeedPolicy,
            allowPreMetadataDHT: false
        )
        let added: AddedTorrentIdentity
        if let priorityEntries {
            added = try unsafe throwingBridgeAdd(capacity: Int(TTORRENT_ID_CAPACITY)) { outputBuffer, nativeToken, addOutcome, errorBuffer in
                let capsuleBytes: Span<UInt8>? = capsule.bytes.span
                let priorities: Span<TTorrentFilePriorityEntry>? = priorityEntries.span
                return unsafe TorrentClientAddMetainfoCapsuleWithPriorities(
                    client,
                    capsuleBytes,
                    nativeActivation,
                    options,
                    priorities,
                    &outputBuffer,
                    nativeToken,
                    addOutcome,
                    &errorBuffer
                )
            }
        } else {
            added = try unsafe throwingBridgeAdd(capacity: Int(TTORRENT_ID_CAPACITY)) { outputBuffer, nativeToken, addOutcome, errorBuffer in
                let capsuleBytes: Span<UInt8>? = capsule.bytes.span
                return unsafe TorrentClientAddMetainfoCapsule(
                    client,
                    capsuleBytes,
                    nativeActivation,
                    options,
                    &outputBuffer,
                    nativeToken,
                    addOutcome,
                    &errorBuffer
                )
            }
        }
        guard added.id == requestedID,
              identityStore.registerAddedTorrent(id: added.id, nativeToken: added.nativeToken) else {
            throw TorrentAddError.commitStatusUnknown(
                "Torrent was added, but its Swift identity could not be registered."
            )
        }
        sourcePolicyStore.registerAddedTorrent(
            id: added.id,
            enablePeerExchange: enablePeerExchange,
            httpsTrackerPolicy: httpsTrackerPolicy,
            httpsWebSeedPolicy: httpsWebSeedPolicy,
            allowPreMetadataDHT: false
        )
        queueNeedsApplication = true
        sourcePolicyNeedsApplication = true
        return added.id
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps the client alive through the
    // synchronous bridge call; bounds/alignment: the token is a validated scalar and the
    // error span is bounded; synchronization: actor isolation serializes mutation;
    // safe alternative: pause is exposed only by the C++ bridge ABI.
    package func pause(id: String) throws {
        let client = try unsafe requireClient()
        let nativeToken = try nativeToken(for: id)
        try throwingBridgeCall { errorBuffer in
            unsafe TorrentClientPause(client, nativeToken, &errorBuffer)
        }
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps the client alive through all
    // synchronous calls; bounds/alignment: validated scalar tokens and bounded spans are used;
    // synchronization: actor isolation serializes resume and queue-state application;
    // safe alternative: native resume/queue operations exist only behind the C bridge ABI.
    package func resume(id: String) throws {
        let client = try unsafe requireClient()
        let nativeToken = try nativeToken(for: id)
        try unsafe ensureQueueState(client: client)
        try throwingBridgeCall { errorBuffer in
            unsafe TorrentClientResume(client, nativeToken, &errorBuffer)
        }
        try unsafe applyQueueState(queueStore, client: client)
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps the client alive through the
    // synchronous call; bounds/alignment: the token is validated and the error span bounded;
    // synchronization: actor isolation serializes client access; safe alternative:
    // reannounce is exposed only by the C++ bridge ABI.
    package func reannounce(id: String) throws {
        let client = try unsafe requireClient()
        let nativeToken = try nativeToken(for: id)
        try throwingBridgeCall { errorBuffer in
            unsafe TorrentClientReannounce(client, nativeToken, &errorBuffer)
        }
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps the client alive through the
    // synchronous call; bounds/alignment: the token is validated and the error span bounded;
    // synchronization: actor isolation serializes client access; safe alternative:
    // force-recheck is exposed only by the C++ bridge ABI.
    package func forceRecheck(id: String) throws {
        let client = try unsafe requireClient()
        let nativeToken = try nativeToken(for: id)
        try throwingBridgeCall { errorBuffer in
            unsafe TorrentClientForceRecheck(client, nativeToken, &errorBuffer)
        }
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps `client` alive across this
    // nonsuspending removal transaction and every local bridge buffer remains in scope;
    // bounds/alignment: native tokens, spans, and returned counts are validated by helpers;
    // synchronization: actor isolation plus durable tombstone sequencing serializes removal;
    // safe alternative: native removal/persistence operations exist only through the C ABI.
    package func remove(id: String) throws -> TorrentRemovalOutcome {
        let client = try unsafe requireClient()
        guard let nativeToken = identityStore.beginRemoval(id: id) else {
            throw TorrentEngineError.bridgeError("Torrent not found.")
        }
        let resumeIDs: [String]
        let tombstoneFilename: String
        do {
            resumeIDs = try unsafe copyResumeIDs(client: client, nativeToken: nativeToken)
            tombstoneFilename = try unsafe persistRemovalTombstone(
                client: client,
                resumeIDs: resumeIDs
            )
        } catch {
            identityStore.cancelRemoval(id: id, nativeToken: nativeToken)
            throw error
        }
        guard persistenceStore.registerRemovalTombstone(
            filename: tombstoneFilename,
            resumeIDs: resumeIDs
        ) else {
            do {
                try unsafe clearRemovalTombstone(
                    client: client,
                    filename: tombstoneFilename
                )
            } catch {
                identityStore.completeRemoval(id: id, nativeToken: nativeToken)
                persistenceStore.remove(nativeToken: nativeToken)
                return quiesceAfterUntrackableRemoval(detail: error.localizedDescription)
            }
            identityStore.cancelRemoval(id: id, nativeToken: nativeToken)
            throw TorrentEngineError.bridgeError(
                "The durable removal intent could not be indexed in Swift."
            )
        }

        var removalCommitted: UInt8 = 0
        do {
            try throwingBridgeCall { errorBuffer in
                unsafe TorrentClientRemove(
                    client,
                    nativeToken,
                    &removalCommitted,
                    &errorBuffer
                )
            }
        } catch let removalError {
            guard removalCommitted != 0 else {
                do {
                    try unsafe clearRemovalTombstone(
                        client: client,
                        filename: tombstoneFilename
                    )
                } catch let cleanupError {
                    identityStore.completeRemoval(id: id, nativeToken: nativeToken)
                    persistenceStore.remove(nativeToken: nativeToken)
                    return quiesceAfterUntrackableRemoval(
                        detail: "\(removalError.localizedDescription) \(cleanupError.localizedDescription)"
                    )
                }
                persistenceStore.completeRemovalCleanup(
                    tombstoneFilename: tombstoneFilename
                )
                identityStore.cancelRemoval(id: id, nativeToken: nativeToken)
                throw removalError
            }
            identityStore.completeRemoval(id: id, nativeToken: nativeToken)
            persistenceStore.remove(nativeToken: nativeToken)
            for cleanupError in unsafe processPendingRemovalCleanups(client: client) {
                recordPersistenceError(cleanupError)
            }
            return quiesceAfterUntrackableRemoval(detail: removalError.localizedDescription)
        }

        guard removalCommitted != 0 else {
            identityStore.cancelRemoval(id: id, nativeToken: nativeToken)
            return quiesceAfterUntrackableRemoval(
                detail: "The bridge returned inconsistent removal state."
            )
        }
        identityStore.completeRemoval(id: id, nativeToken: nativeToken)
        persistenceStore.remove(nativeToken: nativeToken)
        for cleanupError in unsafe processPendingRemovalCleanups(client: client) {
            recordPersistenceError(cleanupError)
        }
        return .removed
    }

    private func quiesceAfterUntrackableRemoval(detail: String) -> TorrentRemovalOutcome {
        let message = "The torrent was removed, but the bridge could not reliably track the operation. "
            + "The torrent engine was stopped safely before storage access was released."
            + " \(detail)"
        let boundedMessage = Self.boundedRemovalWarning(message)
        runtimeFailureMessage.withLock { $0 = boundedMessage }
        destroyClient(waitForShutdown: true)
        return .removedWithWarning(boundedMessage)
    }

    package nonisolated static func boundedRemovalWarning(_ message: String) -> String {
        guard message.utf8.count > TorrentEngineLimits.maximumRemovalWarningBytes else {
            return message
        }
        var result = ""
        result.reserveCapacity(TorrentEngineLimits.maximumRemovalWarningBytes)
        var byteCount = 0
        for character in message {
            let characterBytes = character.utf8.count
            guard byteCount + characterBytes <= TorrentEngineLimits.maximumRemovalWarningBytes else {
                break
            }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }

    // SAFETY: Ownership/lifetime: the actor-owned client remains alive for all synchronous
    // settings/state calls; bounds/alignment: settings use typed fields and exact spans;
    // synchronization: actor isolation serializes configuration changes and network blocking;
    // safe alternative: libtorrent settings are available only through the C bridge ABI.
    package func applySettings(
        _ settings: TorrentSettings,
        networkBinding: TorrentNetworkBinding
    ) throws {
        let client = try unsafe requireClient()
        try unsafe applyNativeSettings(settings, networkBlocked: true, client: client)
        if sourcePolicyStore.updateDefaults(settings) {
            sourcePolicyNeedsApplication = true
        }
        try unsafe refreshNativeState(client: client)
        if !networkBinding.networkBlocked {
            try unsafe applyNativeSettings(settings, networkBlocked: false, client: client)
        }
    }

    // SAFETY: Ownership/lifetime: the caller's handle owns `client` and local settings/name
    // bytes live through the synchronous call; bounds/alignment: SafeInterop Span supplies
    // the exact CChar count and the error buffer is bounded; synchronization: callers are
    // actor-isolated; safe alternative: the native settings API is a C bridge function.
    private func applyNativeSettings(
        _ settings: TorrentSettings,
        networkBlocked: Bool,
        client: OpaquePointer
    ) throws {
        try throwingBridgeCall { errorBuffer in
            let networkInterfaceBytes = settings.libtorrentRequiredNetworkInterfaceName.utf8.map {
                CChar(bitPattern: $0)
            }
            let networkInterface: Span<CChar>? = networkInterfaceBytes.isEmpty
                ? nil
                : networkInterfaceBytes.span
            var bridgeSettings = TTorrentSessionSettings()
            bridgeSettings.download_rate_limit = settings.libtorrentDownloadRateLimit
            bridgeSettings.upload_rate_limit = settings.libtorrentUploadRateLimit
            bridgeSettings.active_downloads = settings.libtorrentActiveDownloads
            bridgeSettings.active_seeds = settings.libtorrentActiveSeeds
            bridgeSettings.active_limit = settings.libtorrentActiveLimit
            bridgeSettings.share_ratio_limit = settings.libtorrentShareRatioLimit
            bridgeSettings.seed_time_limit = settings.libtorrentSeedTimeLimit
            bridgeSettings.incoming_port = settings.libtorrentIncomingPort
            bridgeSettings.accept_incoming_connections = settings.acceptIncomingConnections.bridgeFlag
            bridgeSettings.enable_port_forwarding = settings.effectiveUsePortForwarding.bridgeFlag
            bridgeSettings.enable_dht = settings.enableDHTNetwork.bridgeFlag
            bridgeSettings.dht_read_only = settings.reduceDHTContribution.bridgeFlag
            bridgeSettings.dht_discovery_policy = UInt8(settings.dhtDiscoveryPolicy.rawValue)
            bridgeSettings.enable_lsd = settings.effectiveEnableLocalServiceDiscovery.bridgeFlag
            bridgeSettings.encryption_policy = settings.libtorrentEncryptionPolicy
            bridgeSettings.anonymous_mode = settings.effectiveAnonymousMode.bridgeFlag
            bridgeSettings.network_blocked = networkBlocked.bridgeFlag
            return unsafe TorrentClientApplySettings(
                client,
                bridgeSettings,
                networkInterface,
                &errorBuffer
            )
        }
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps the client alive for the
    // synchronous block; bounds/alignment: only a bounded error span is passed;
    // synchronization: actor isolation serializes containment; safe alternative:
    // native network containment is exposed only through the C bridge.
    package func blockNetworkNow() throws -> TorrentNetworkBlockDisposition {
        let client = try unsafe requireClient()
        try unsafe blockNetwork(client: client)
        return .engineRemainsAvailable
    }

    // SAFETY: Ownership/lifetime: the caller's actor-owned handle keeps `client` alive;
    // bounds/alignment: the mutable error span has exact array capacity; synchronization:
    // callers serialize access through the actor; safe alternative: blocking the native
    // engine network requires the C bridge function.
    private func blockNetwork(client: OpaquePointer) throws {
        try throwingBridgeCall { errorBuffer in
            unsafe TorrentClientBlockNetwork(client, &errorBuffer)
        }
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps the pointer alive for these
    // nonsuspending calls; bounds/alignment: persistence helpers validate tokens/counts and
    // use bounded spans; synchronization: actor isolation serializes client/persistence state;
    // safe alternative: native snapshot/resume persistence is only exposed by the C bridge.
    package func saveAll() {
        guard let pointer = unsafe client?.pointer else {
            return
        }
        if !identityStore.isInitialized {
            try? unsafe refreshNativeState(client: pointer)
        }
        guard persistenceStore.requestSave(
            nativeTokens: identityStore.activeNativeTokens,
            mode: .full
        ) else {
            recordPersistenceError("Resume-save generation space was exhausted.")
            return
        }
        for error in unsafe processPendingPersistence(client: pointer) {
            recordPersistenceError(error)
        }
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps the client alive for the
    // synchronous helper; bounds/alignment: bounded bridge helpers validate all buffers;
    // synchronization: actor isolation serializes persistence; safe alternative:
    // native resume persistence is available only through the C bridge.
    package func saveAllChecked() throws {
        let client = try unsafe requireClient()
        try unsafe saveAllChecked(client: client)
    }

    // SAFETY: Ownership/lifetime: the caller's handle owns `client` for this nonsuspending
    // function; bounds/alignment: persistence helpers validate tokens/counts and spans;
    // synchronization: callers are actor-isolated; safe alternative: native persistence
    // operations are available only through the C bridge ABI.
    private func saveAllChecked(client: OpaquePointer) throws {
        if !identityStore.isInitialized {
            try unsafe refreshNativeState(client: client)
        }
        guard persistenceStore.requestSave(
            nativeTokens: identityStore.activeNativeTokens,
            mode: .full
        ) else {
            throw TorrentEngineError.bridgeError(
                "Resume-save generation space was exhausted."
            )
        }
        let errors = unsafe processPendingPersistence(client: client)
        guard errors.isEmpty else {
            throw TorrentEngineError.bridgeError(errors.joined(separator: " "))
        }
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle and local CChar array live through
    // the synchronous copy; bounds/alignment: MutableSpan carries the exact 1,024-element
    // capacity and decoding stops at NUL; synchronization: actor isolation serializes drain;
    // safe alternative: the native alert queue is exposed only through the C bridge.
    package func takeAlertError() -> String? {
        if let alertErrorReader {
            return alertErrorReader()
        }
        guard let pointer = unsafe client?.pointer else {
            return nil
        }

        var errorBuffer = Array<CChar>(repeating: 0, count: 1024)
        var errorSpan: MutableSpan<CChar>? = errorBuffer.mutableSpan
        let didCopyError = unsafe TorrentClientTakeAlertError(pointer, &errorSpan) != 0
        errorSpan = nil
        guard didCopyError else {
            return nil
        }
        return stringFromBridgeBuffer(errorBuffer)
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle and each event buffer live through
    // synchronous bridge drains; bounds/alignment: SafeInterop MutableSpan communicates exact
    // capacities and every required count is capped before allocation/copy; synchronization:
    // actor isolation serializes drain/state updates; safe alternative: native events are
    // available only through the C bridge ABI.
    package func takeChanges() -> UInt32 {
        guard criticalFaults.isEmpty else {
            return TorrentEngineDirtySet.allKnown.rawValue
        }
        guard let pointer = unsafe client?.pointer else {
            return 0
        }

        var requiredCount: Int32 = 0
        var available: UInt8 = 0
        var eventSpan: MutableSpan<TTorrentEvent>?
        _ = unsafe TorrentClientDrainEvents(
            pointer,
            &eventSpan,
            &requiredCount,
            &available
        )
        guard available != 0,
              requiredCount >= 0,
              requiredCount <= TTORRENT_MAX_EVENT_COUNT else {
            return TorrentEngineDirtySet.allKnown.rawValue
        }
        guard requiredCount > 0 else {
            return 0
        }

        var capacity = Int(requiredCount)
        var events = Array(repeating: TTorrentEvent(), count: capacity)
        var copied = Self.withMutableBridgeSpan(&events) { eventSpan in
            unsafe TorrentClientDrainEvents(
                pointer,
                &eventSpan,
                &requiredCount,
                &available
            )
        }
        while requiredCount > Int32(capacity),
              requiredCount <= TTORRENT_MAX_EVENT_COUNT {
            capacity = Int(requiredCount)
            events = Array(repeating: TTorrentEvent(), count: capacity)
            copied = Self.withMutableBridgeSpan(&events) { eventSpan in
                unsafe TorrentClientDrainEvents(
                    pointer,
                    &eventSpan,
                    &requiredCount,
                    &available
                )
            }
        }
        guard available != 0,
              requiredCount >= 0,
              requiredCount <= TTORRENT_MAX_EVENT_COUNT,
              copied == requiredCount else {
            return TorrentEngineDirtySet.allKnown.rawValue
        }

        var changes: TorrentEngineDirtySet = []
        let drainedEvents = events.prefix(Int(copied))
        for event in drainedEvents {
            guard event.kind == UInt8(TTORRENT_EVENT_CRITICAL_FAULT) else {
                if event.critical_faults != 0 {
                    recordCriticalFaults(0)
                }
                continue
            }
            guard event.native_token == 0,
                  event.resume_save_mode == UInt8(TTORRENT_RESUME_SAVE_ROUTINE),
                  event.critical_faults != 0 else {
                recordCriticalFaults(0)
                continue
            }
            recordCriticalFaults(event.critical_faults)
        }
        guard criticalFaults.isEmpty else {
            return TorrentEngineDirtySet.allKnown.rawValue
        }

        if !identityStore.isInitialized {
            try? unsafe refreshNativeState(client: pointer)
        }

        var shouldAttemptPersistence = false
        for event in drainedEvents {
            switch event.kind {
            case UInt8(TTORRENT_EVENT_TORRENTS_CHANGED):
                changes.insert(.torrents)
            case UInt8(TTORRENT_EVENT_TRACKERS_CHANGED):
                changes.insert(.trackers)
            case UInt8(TTORRENT_EVENT_WEB_SEEDS_CHANGED):
                changes.insert(.webSeeds)
            case UInt8(TTORRENT_EVENT_FILES_CHANGED):
                changes.insert(.files)
            case UInt8(TTORRENT_EVENT_NETWORK_CHANGED):
                changes.insert(.network)
            case UInt8(TTORRENT_EVENT_ERRORS_AVAILABLE):
                changes.insert(.errors)
            case UInt8(TTORRENT_EVENT_PIECES_CHANGED):
                changes.insert(.pieces)
            case UInt8(TTORRENT_EVENT_TRACKER_HOSTS_CHANGED):
                changes.insert(.trackerHosts)
            case UInt8(TTORRENT_EVENT_HEALTH_CHANGED):
                changes.insert(.health)
            case UInt8(TTORRENT_EVENT_RESYNC_REQUIRED):
                changes = .allKnown
                shouldAttemptPersistence = true
                guard persistenceStore.requestSave(
                    nativeTokens: identityStore.activeNativeTokens,
                    mode: .full
                ) else {
                    recordPersistenceError("Resume-save generation space was exhausted.")
                    continue
                }
            case UInt8(TTORRENT_EVENT_RESUME_SAVE_REQUESTED):
                guard event.native_token != 0,
                      let mode = TorrentPersistenceStore.SaveMode(
                          rawValue: event.resume_save_mode
                      ),
                      persistenceStore.requestSave(
                          nativeToken: event.native_token,
                          mode: mode
                      ) else {
                    changes = .allKnown
                    shouldAttemptPersistence = true
                    continue
                }
                shouldAttemptPersistence = true
            case UInt8(TTORRENT_EVENT_RESUME_RETRY_REQUESTED):
                persistenceStore.requestNativeRemovalRecovery()
                shouldAttemptPersistence = true
            case UInt8(TTORRENT_EVENT_CRITICAL_FAULT):
                continue
            default:
                changes = .allKnown
            }
        }
        if identityStore.isInitialized {
            persistenceStore.retain(nativeTokens: identityStore.activeNativeTokens)
        }
        if shouldAttemptPersistence {
            for error in unsafe processPendingPersistence(client: pointer) {
                recordPersistenceError(error)
            }
        }
        return changes.rawValue
    }

    package func recordCriticalFaults(_ rawValue: UInt32) {
        let knownMask = TorrentEngineCriticalFaults.allKnown.rawValue
        let received = TorrentEngineCriticalFaults(rawValue: rawValue)
        let containsUnknownBits = rawValue & ~knownMask != 0
        if rawValue == 0 {
            criticalFaults.insert(.invalidNativeSignal)
        } else {
            criticalFaults.formUnion(received)
        }

        let message: String
        if rawValue == 0 || containsUnknownBits {
            message = "The torrent engine received an invalid native critical-fault signal. Restart the torrent engine to recover."
        } else if received.contains(.networkContainmentUnconfirmed) {
            message = "The torrent engine detected a critical native fault, but network containment could not be confirmed. Restart the torrent engine to recover."
        } else if received.contains(.sessionIdentityAuthority) {
            message = "The torrent engine contained networking because session identity authority became uncertain. Restart the torrent engine to recover."
        } else {
            message = "The torrent engine detected a critical native fault. Restart the torrent engine to recover."
        }
        runtimeFailureMessage.withLock { current in
            if current == nil {
                current = message
            }
        }

        if received.contains(.networkContainmentUnconfirmed) {
            destroyClient(waitForShutdown: true)
        }
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps the client alive through the
    // by-value synchronous query; bounds/alignment: the bridge returns a fixed typed struct;
    // synchronization: actor isolation serializes access; safe alternative: native network
    // status is available only through the C bridge ABI.
    package func networkStatus() -> TorrentNetworkStatus {
        guard let pointer = unsafe client?.pointer else {
            return .empty
        }

        let result = unsafe TorrentClientCopyNetworkStatus(pointer)
        guard result.status != 0 else {
            return .empty
        }
        return TorrentNetworkStatus(status: result.network_status)
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps the client alive through the
    // by-value synchronous query; bounds/alignment: the bridge returns a fixed typed struct;
    // synchronization: actor isolation serializes access; safe alternative: native health
    // state is available only through the C bridge ABI.
    package func bridgeHealth() -> TorrentBridgeHealth {
        guard let pointer = unsafe client?.pointer else {
            return .unavailable
        }

        let result = unsafe TorrentClientCopyHealth(pointer)
        guard result.status != 0 else {
            return .unavailable
        }
        return TorrentBridgeHealth(snapshot: result.health)
    }

    package func poll(
        since revision: UInt64?,
        sortedBy sortOrder: TorrentSortOrder,
        direction: TorrentSortDirection,
        includeTrackerHosts: Bool
    ) throws -> TorrentEnginePollResult {
        let dirtyMask = takeChanges()
        try throwIfRuntimeFailure()
        let health = bridgeHealth()
        var alertErrors = [String]()
        alertErrors.reserveCapacity(TorrentEngineLimits.maximumAlertErrorsPerPoll)
        for _ in 0..<TorrentEngineLimits.maximumAlertErrorsPerPoll {
            guard let error = takeAlertError() else {
                break
            }
            if !error.isEmpty {
                alertErrors.append(error)
            }
        }
        while alertErrors.count < TorrentEngineLimits.maximumAlertErrorsPerPoll,
              !pendingPersistenceErrors.isEmpty {
            alertErrors.append(pendingPersistenceErrors.removeFirst())
        }
        let status = networkStatus()
        let dirtySet = TorrentEngineDirtySet(rawValue: dirtyMask)
        let snapshots = try snapshotsIfChanged(
            since: revision,
            sortedBy: sortOrder,
            direction: direction,
            refreshNative: dirtySet.contains(.torrents) || !snapshotStore.isInitialized
        )
        let trackerHostsChanged = dirtySet.contains(.trackerHosts)
        let trackerHosts = includeTrackerHosts || trackerHostsChanged
            ? try trackerHostBatch()
            : nil
        return TorrentEnginePollResult(
            dirtyMask: dirtyMask,
            alertErrors: alertErrors,
            networkStatus: status,
            bridgeHealth: health,
            snapshotBatch: snapshots,
            trackerHostBatch: trackerHosts
        )
    }

    package func snapshots() throws -> [TorrentItem] {
        try snapshotBatch().torrents
    }

    package func snapshotsIfChanged(
        since revision: UInt64?,
        sortedBy sortOrder: TorrentSortOrder,
        direction: TorrentSortDirection
    ) throws -> TorrentSnapshotBatch? {
        try snapshotsIfChanged(
            since: revision,
            sortedBy: sortOrder,
            direction: direction,
            refreshNative: true
        )
    }

    private func snapshotsIfChanged(
        since revision: UInt64?,
        sortedBy sortOrder: TorrentSortOrder,
        direction: TorrentSortDirection,
        refreshNative: Bool
    ) throws -> TorrentSnapshotBatch? {
        guard let client else {
            if runtimeFailureMessage.withLock({ $0 != nil }) {
                return nil
            }
            return revision == 0 ? nil : TorrentSnapshotBatch(revision: 0, torrents: [])
        }

        guard let batch = try snapshotBatch(
            client: client,
            ifChangedSince: revision,
            refreshNative: refreshNative
        ) else {
            return nil
        }

        return TorrentSnapshotBatch(revision: batch.revision, torrents: sortOrder.sorted(batch.torrents, direction: direction))
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps the client alive while state
    // is synchronously refreshed; bounds/alignment: refresh helpers use exact bounded spans;
    // synchronization: actor isolation serializes native/Swift state reconciliation;
    // safe alternative: native source policy is available only through the C bridge.
    package func sourcePolicy(id: String) throws -> TorrentSourcePolicy {
        let client = try unsafe requireClient()
        try unsafe ensureSourcePolicyState(client: client)
        guard let policy = sourcePolicyStore.policy(for: id) else {
            throw TorrentEngineError.bridgeError("Torrent not found.")
        }
        return policy
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps the client alive during
    // synchronous refresh/application; bounds/alignment: typed applications use exact spans;
    // synchronization: actor isolation serializes transactional policy updates;
    // safe alternative: native source-policy mutation is exposed only through the C bridge.
    package func setSourcePolicy(id: String, mutation: TorrentSourcePolicyMutation) throws {
        let client = try unsafe requireClient()
        try unsafe ensureSourcePolicyState(client: client)
        var nextStore = sourcePolicyStore
        switch nextStore.mutate(id: id, mutation: mutation) {
        case .unavailable:
            throw TorrentEngineError.bridgeError(
                sourcePolicyStore.policy(for: id) == nil
                    ? "Torrent not found."
                    : "This source policy field is unavailable for the current metadata state."
            )
        case .unchanged:
            return
        case .updated:
            do {
                try unsafe applySourcePolicyState(nextStore, client: client)
            } catch {
                sourcePolicyNeedsApplication = true
                throw error
            }
            sourcePolicyStore = nextStore
        }
    }

    // SAFETY: Ownership/lifetime: the actor-owned client and local result/error storage live
    // through synchronous calls; bounds/alignment: fixed typed results and bounded error
    // spans are used; synchronization: actor isolation serializes state access;
    // safe alternative: native torrent options are available only through the C bridge.
    package func torrentOptions(id: String) throws -> TorrentOptions {
        let client = try unsafe requireClient()
        let nativeToken = try nativeToken(for: id)
        try unsafe ensureQueueState(client: client)
        var result = TTorrentOptionsResult()
        try throwingBridgeCall { errorBuffer in
            result = unsafe TorrentClientCopyTorrentOptions(client, nativeToken, &errorBuffer)
            return result.status
        }
        var options = TorrentOptions(snapshot: result.options)
        guard let queuePriority = queueStore.priority(for: id) else {
            throw TorrentEngineError.bridgeError("Torrent queue state is unavailable.")
        }
        options.queuePriority = queuePriority
        return options
    }

    // SAFETY: Ownership/lifetime: the actor-owned client and local option/error values live
    // through synchronous calls; bounds/alignment: only fixed structs and exact queue spans
    // cross the bridge; synchronization: actor isolation serializes the transactional update;
    // safe alternative: native option and queue mutation require the C bridge ABI.
    package func setTorrentOptions(id: String, options: TorrentOptions) throws {
        let client = try unsafe requireClient()
        let nativeToken = try nativeToken(for: id)
        try unsafe ensureQueueState(client: client)
        var nextQueueStore = queueStore
        let queueChanged = nextQueueStore.setPriority(options.queuePriority, for: id)
        let bridgeOptions = options.bridgeValue
        try throwingBridgeCall { errorBuffer in
            unsafe TorrentClientSetTorrentOptions(client, nativeToken, bridgeOptions, &errorBuffer)
        }
        if queueChanged {
            try unsafe applyQueueState(nextQueueStore, client: client)
            queueStore = nextQueueStore
        }
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps the client alive through the
    // synchronous queue application; bounds/alignment: an exact typed placement span is used;
    // synchronization: actor isolation serializes queue reconciliation; safe alternative:
    // native queue mutation is available only through the C bridge ABI.
    package func moveTorrentInQueue(id: String, move: TorrentQueueMove) throws {
        let client = try unsafe requireClient()
        try unsafe ensureQueueState(client: client)
        var nextQueueStore = queueStore
        guard nextQueueStore.move(id, by: move) else {
            return
        }
        try unsafe applyQueueState(nextQueueStore, client: client)
        queueStore = nextQueueStore
    }

    // SAFETY: Ownership/lifetime: the actor-owned client and local queue state live
    // through synchronous refresh/application; bounds/alignment: helpers validate native
    // identities and carry exact spans; synchronization: actor isolation serializes this
    // transaction; safe alternative: native queue application requires the C bridge.
    package func restoreQueuePosition(id: String, position: TorrentQueuePosition) throws {
        let client = try unsafe requireClient()
        _ = try nativeToken(for: id)
        try unsafe refreshNativeState(client: client)
        let queuedIDs = Set(snapshotStore.torrents.lazy
            .filter { $0.queuePosition >= 0 }
            .map(\.id))
        var nextQueueStore = queueStore
        guard nextQueueStore.restorePosition(id, to: position, queuedIDs: queuedIDs) else {
            return
        }
        try unsafe applyQueueState(nextQueueStore, client: client)
        queueStore = nextQueueStore
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle and local error buffer live through
    // the synchronous call; bounds/alignment: token/index/priority are validated typed scalars
    // and the error span is bounded; synchronization: actor isolation serializes mutation;
    // safe alternative: native file-priority mutation requires the C bridge ABI.
    package func setFilePriority(id: String, fileIndex: Int32, priority: TorrentFilePriority) throws {
        let client = try unsafe requireClient()
        let nativeToken = try nativeToken(for: id)
        try throwingBridgeCall { errorBuffer in
            unsafe TorrentClientSetFilePriority(client, nativeToken, fileIndex, priority.bridgeValue, &errorBuffer)
        }
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle and each local snapshot array live
    // through synchronous copies; bounds/alignment: MutableSpan supplies exact capacities and
    // required counts are nonnegative, capped, and equality-checked; synchronization: actor
    // isolation serializes copies; safe alternative: native tracker snapshots use the C ABI.
    package func trackerBatch(id: String, since previousRevision: UInt64?) -> TorrentTrackerBatch? {
        guard let client, let pointer = unsafe client.pointer else {
            return nil
        }
        guard let nativeToken = identityStore.nativeToken(for: id) else {
            return nil
        }

        var requiredCount: Int32 = 0
        var available: UInt8 = 0
        var trackerSpan: MutableSpan<TTorrentTrackerSnapshot>?
        _ = unsafe TorrentClientCopyTrackerBatch(
            pointer,
            nativeToken,
            &trackerSpan,
            &requiredCount,
            &available
        )
        guard available != 0, requiredCount >= 0 else {
            return nil
        }
        guard requiredCount > 0 else {
            return detailStore.trackerBatch(
                id: id,
                trackers: [],
                ifChangedSince: previousRevision
            )
        }

        var capacity = Self.cappedCapacity(requiredCount: requiredCount, minimum: 4, maximum: TTORRENT_MAX_TRACKER_COUNT)
        var trackers = Array(repeating: TTorrentTrackerSnapshot(), count: capacity)
        var copied = Self.withMutableBridgeSpan(&trackers) { trackerSpan in
            unsafe TorrentClientCopyTrackerBatch(
                pointer,
                nativeToken,
                &trackerSpan,
                &requiredCount,
                &available
            )
        }

        while requiredCount > Int32(capacity), capacity < Int(TTORRENT_MAX_TRACKER_COUNT) {
            capacity = Self.grownCapacity(
                current: capacity,
                requiredCount: requiredCount,
                maximum: TTORRENT_MAX_TRACKER_COUNT
            )
            trackers = Array(repeating: TTorrentTrackerSnapshot(), count: capacity)
            copied = Self.withMutableBridgeSpan(&trackers) { trackerSpan in
                unsafe TorrentClientCopyTrackerBatch(
                    pointer,
                    nativeToken,
                    &trackerSpan,
                    &requiredCount,
                    &available
                )
            }
        }

        guard available != 0,
              requiredCount >= 0,
              copied == requiredCount else {
            return nil
        }
        let items = trackers.prefix(Int(copied)).map(TorrentTrackerItem.init(snapshot:))
        return detailStore.trackerBatch(
            id: id,
            trackers: items,
            ifChangedSince: previousRevision
        )
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle and local host arrays live through
    // synchronous bridge copies; bounds/alignment: exact MutableSpan capacities are capped and
    // returned counts are checked before indexing; synchronization: actor isolation serializes
    // reconciliation; safe alternative: native tracker-host snapshots use the C bridge ABI.
    package func trackerHostBatch() throws -> TorrentTrackerHostBatch {
        guard let client, let pointer = unsafe client.pointer else {
            return trackerHostStore.batch()
        }

        var requiredCount: Int32 = 0
        var available: UInt8 = 0
        var hostSpan: MutableSpan<TTorrentTrackerHostSnapshot>?
        _ = unsafe TorrentClientCopyTrackerHostBatch(
            pointer,
            &hostSpan,
            &requiredCount,
            &available
        )
        guard available != 0, requiredCount >= 0 else {
            throw TorrentEngineError.bridgeError(
                "The native tracker-host snapshot was unavailable."
            )
        }
        guard requiredCount > 0 else {
            guard trackerHostStore.reconcile(
                [],
                torrentIDs: snapshotStore.torrentIDs
            ) != .rejected else {
                throw TorrentEngineError.bridgeError(
                    "The native tracker-host snapshot violated its bounded identity contract."
                )
            }
            return trackerHostStore.batch()
        }

        var capacity = Self.cappedCapacity(
            requiredCount: requiredCount,
            minimum: 4,
            maximum: TTORRENT_MAX_TRACKER_HOST_ROW_COUNT
        )
        var hosts = Array(repeating: TTorrentTrackerHostSnapshot(), count: capacity)
        var copied = Self.withMutableBridgeSpan(&hosts) { hostSpan in
            unsafe TorrentClientCopyTrackerHostBatch(
                pointer,
                &hostSpan,
                &requiredCount,
                &available
            )
        }

        while requiredCount > Int32(capacity), capacity < Int(TTORRENT_MAX_TRACKER_HOST_ROW_COUNT) {
            capacity = Self.grownCapacity(
                current: capacity,
                requiredCount: requiredCount,
                maximum: TTORRENT_MAX_TRACKER_HOST_ROW_COUNT
            )
            hosts = Array(repeating: TTorrentTrackerHostSnapshot(), count: capacity)
            copied = Self.withMutableBridgeSpan(&hosts) { hostSpan in
                unsafe TorrentClientCopyTrackerHostBatch(
                    pointer,
                    &hostSpan,
                    &requiredCount,
                    &available
                )
            }
        }

        guard available != 0,
              requiredCount >= 0,
              copied == requiredCount else {
            throw TorrentEngineError.bridgeError(
                "The native tracker-host snapshot changed while it was being copied."
            )
        }

        let items = try hosts.prefix(Int(copied)).map { snapshot in
            guard let id = identityStore.id(forNativeToken: snapshot.native_token) else {
                throw TorrentEngineError.bridgeError(
                    "The native tracker-host snapshot referenced an unknown token."
                )
            }
            return TorrentTrackerHostItem(
                torrentID: id,
                host: String(cStringTuple: snapshot.host)
            )
        }
        guard trackerHostStore.reconcile(
            items,
            torrentIDs: snapshotStore.torrentIDs
        ) != .rejected else {
            throw TorrentEngineError.bridgeError(
                "The native tracker-host snapshot violated its bounded identity contract."
            )
        }
        return trackerHostStore.batch()
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle and local web-seed arrays live through
    // synchronous copies; bounds/alignment: MutableSpan carries exact capped capacity and
    // returned counts are checked before use; synchronization: actor isolation serializes copy;
    // safe alternative: native web-seed snapshots are exposed only through the C bridge.
    package func webSeedBatch(id: String, since previousRevision: UInt64?) -> TorrentWebSeedBatch? {
        guard let client, let pointer = unsafe client.pointer else {
            return nil
        }
        guard let nativeToken = identityStore.nativeToken(for: id) else {
            return nil
        }

        var requiredCount: Int32 = 0
        var available: UInt8 = 0
        var webSeedSpan: MutableSpan<TTorrentWebSeedSnapshot>?
        _ = unsafe TorrentClientCopyWebSeedBatch(
            pointer,
            nativeToken,
            &webSeedSpan,
            &requiredCount,
            &available
        )
        guard available != 0, requiredCount >= 0 else {
            return nil
        }
        guard requiredCount > 0 else {
            return detailStore.webSeedBatch(
                id: id,
                webSeeds: [],
                ifChangedSince: previousRevision
            )
        }

        var capacity = Self.cappedCapacity(requiredCount: requiredCount, minimum: 4, maximum: TTORRENT_MAX_WEB_SEED_COUNT)
        var webSeeds = Array(repeating: TTorrentWebSeedSnapshot(), count: capacity)
        var copied = Self.withMutableBridgeSpan(&webSeeds) { webSeedSpan in
            unsafe TorrentClientCopyWebSeedBatch(
                pointer,
                nativeToken,
                &webSeedSpan,
                &requiredCount,
                &available
            )
        }

        while requiredCount > Int32(capacity), capacity < Int(TTORRENT_MAX_WEB_SEED_COUNT) {
            capacity = Self.grownCapacity(
                current: capacity,
                requiredCount: requiredCount,
                maximum: TTORRENT_MAX_WEB_SEED_COUNT
            )
            webSeeds = Array(repeating: TTorrentWebSeedSnapshot(), count: capacity)
            copied = Self.withMutableBridgeSpan(&webSeeds) { webSeedSpan in
                unsafe TorrentClientCopyWebSeedBatch(
                    pointer,
                    nativeToken,
                    &webSeedSpan,
                    &requiredCount,
                    &available
                )
            }
        }

        guard available != 0,
              requiredCount >= 0,
              copied == requiredCount else {
            return nil
        }
        let items = webSeeds.prefix(Int(copied)).map(TorrentWebSeedItem.init(snapshot:))
        return detailStore.webSeedBatch(
            id: id,
            webSeeds: items,
            ifChangedSince: previousRevision
        )
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps the client alive for the
    // synchronous by-value query; bounds/alignment: the bridge returns a fixed typed struct;
    // synchronization: actor isolation serializes access; safe alternative: native web-seed
    // activity is available only through the C bridge ABI.
    package func webSeedActivity(id: String) -> TorrentWebSeedActivity? {
        guard let client, let pointer = unsafe client.pointer else {
            return nil
        }
        guard let nativeToken = identityStore.nativeToken(for: id) else {
            return nil
        }

        let result = unsafe TorrentClientCopyWebSeedActivity(pointer, nativeToken)
        guard result.status != 0 else {
            return nil
        }
        return detailStore.webSeedActivity(
            id: id,
            activity: TorrentWebSeedActivity(snapshot: result.activity)
        )
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps the client alive for the
    // synchronous by-value query; bounds/alignment: the bridge returns a fixed typed struct;
    // synchronization: actor isolation serializes access; safe alternative: native peer-source
    // state is available only through the C bridge ABI.
    package func peerSources(id: String) -> TorrentPeerSources? {
        guard let client, let pointer = unsafe client.pointer else {
            return nil
        }
        guard let nativeToken = identityStore.nativeToken(for: id) else {
            return nil
        }

        let result = unsafe TorrentClientCopyPeerSources(pointer, nativeToken)
        guard result.status != 0 else {
            return nil
        }
        return detailStore.peerSources(
            id: id,
            sources: TorrentPeerSources(snapshot: result.sources)
        )
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle and each local file array live through
    // synchronous copies; bounds/alignment: exact MutableSpan capacities are capped and
    // returned counts are equality-checked before indexing; synchronization: actor isolation
    // serializes access; safe alternative: native file snapshots use the C bridge ABI.
    package func fileBatch(id: String, since previousRevision: UInt64?) -> TorrentFileBatch? {
        guard let client, let pointer = unsafe client.pointer else {
            return nil
        }
        guard let nativeToken = identityStore.nativeToken(for: id) else {
            return nil
        }

        var requiredCount: Int32 = 0
        var available: UInt8 = 0
        var fileSpan: MutableSpan<TTorrentFileSnapshot>?
        _ = unsafe TorrentClientCopyFileBatch(
            pointer,
            nativeToken,
            &fileSpan,
            &requiredCount,
            &available
        )
        guard available != 0, requiredCount >= 0 else {
            return nil
        }
        guard requiredCount > 0 else {
            return detailStore.fileBatch(
                id: id,
                files: [],
                ifChangedSince: previousRevision
            )
        }

        var capacity = Self.cappedCapacity(requiredCount: requiredCount, minimum: 8, maximum: TTORRENT_MAX_FILE_COUNT)
        var files = Array(repeating: TTorrentFileSnapshot(), count: capacity)
        var copied = Self.withMutableBridgeSpan(&files) { fileSpan in
            unsafe TorrentClientCopyFileBatch(
                pointer,
                nativeToken,
                &fileSpan,
                &requiredCount,
                &available
            )
        }

        while requiredCount > Int32(capacity), capacity < Int(TTORRENT_MAX_FILE_COUNT) {
            capacity = Self.grownCapacity(
                current: capacity,
                requiredCount: requiredCount,
                maximum: TTORRENT_MAX_FILE_COUNT
            )
            files = Array(repeating: TTorrentFileSnapshot(), count: capacity)
            copied = Self.withMutableBridgeSpan(&files) { fileSpan in
                unsafe TorrentClientCopyFileBatch(
                    pointer,
                    nativeToken,
                    &fileSpan,
                    &requiredCount,
                    &available
                )
            }
        }

        guard available != 0,
              requiredCount >= 0,
              copied == requiredCount else {
            return nil
        }
        let items = files.prefix(Int(copied)).map(TorrentFileItem.init(snapshot:))
        return detailStore.fileBatch(
            id: id,
            files: items,
            ifChangedSince: previousRevision
        )
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle and local byte arrays live through
    // synchronous copies; bounds/alignment: MutableSpan carries exact capped byte capacity and
    // returned counts are checked before slicing; synchronization: actor isolation serializes
    // access; safe alternative: the native piece map is exposed only through the C bridge.
    package func pieceMapBatch(id: String, since previousRevision: UInt64?) -> TorrentPieceMapBatch? {
        guard let client, let pointer = unsafe client.pointer else {
            return nil
        }
        guard let nativeToken = identityStore.nativeToken(for: id) else {
            return nil
        }

        var requiredCount: Int32 = 0
        var available: UInt8 = 0
        var pieceSpan: MutableSpan<UInt8>?
        _ = unsafe TorrentClientCopyPieceMap(
            pointer,
            nativeToken,
            nil,
            &pieceSpan,
            &requiredCount,
            &available
        )
        guard available != 0, requiredCount >= 0 else {
            return nil
        }

        var snapshot = TTorrentPieceMapSnapshot()
        var capacity = Self.cappedCapacity(
            requiredCount: requiredCount,
            minimum: 0,
            maximum: TTORRENT_MAX_PIECE_MAP_COUNT
        )
        var pieces = Array<UInt8>(repeating: 0, count: capacity)
        var copied = Self.withMutableBridgeSpan(&pieces) { pieceSpan in
            unsafe TorrentClientCopyPieceMap(
                pointer,
                nativeToken,
                &snapshot,
                &pieceSpan,
                &requiredCount,
                &available
            )
        }

        while requiredCount > Int32(capacity), capacity < Int(TTORRENT_MAX_PIECE_MAP_COUNT) {
            capacity = Self.grownCapacity(
                current: capacity,
                requiredCount: requiredCount,
                maximum: TTORRENT_MAX_PIECE_MAP_COUNT
            )
            pieces = Array<UInt8>(repeating: 0, count: capacity)
            copied = Self.withMutableBridgeSpan(&pieces) { pieceSpan in
                unsafe TorrentClientCopyPieceMap(
                    pointer,
                    nativeToken,
                    &snapshot,
                    &pieceSpan,
                    &requiredCount,
                    &available
                )
            }
        }

        guard available != 0,
              requiredCount >= 0,
              copied == requiredCount else {
            return nil
        }
        let copiedPieces = Array(pieces.prefix(max(0, Int(copied))))
        return detailStore.pieceMapBatch(
            id: id,
            pieceMap: TorrentPieceMap(snapshot: snapshot, pieces: copiedPieces),
            ifChangedSince: previousRevision
        )
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle and local byte array live through the
    // synchronous metadata copy; bounds/alignment: the announced count is positive, capped by
    // the torrent input limit, represented by an exact MutableSpan, and equality-checked;
    // synchronization: actor isolation serializes access; safe alternative: native metadata
    // is exposed only through the C bridge ABI.
    package func torrentMetadata(id: String) throws -> Data? {
        guard let client, let pointer = unsafe client.pointer else {
            return nil
        }
        guard let nativeToken = identityStore.nativeToken(for: id) else {
            return nil
        }

        var requiredCount: Int32 = 0
        var available: UInt8 = 0
        var metadataSpan: MutableSpan<UInt8>?
        _ = unsafe TorrentClientCopyTorrentMetadata(
            pointer,
            nativeToken,
            &metadataSpan,
            &requiredCount,
            &available
        )
        guard available != 0 else {
            return nil
        }
        guard requiredCount > 0,
              requiredCount <= Int32(TorrentInputLimits.maxTorrentFileBytes) else {
            throw TorrentEngineError.bridgeError(
                "Torrent metadata exceeded the trusted size limit."
            )
        }

        var bytes = [UInt8](repeating: 0, count: Int(requiredCount))
        let copied = Self.withMutableBridgeSpan(&bytes) { metadataSpan in
            unsafe TorrentClientCopyTorrentMetadata(
                pointer,
                nativeToken,
                &metadataSpan,
                &requiredCount,
                &available
            )
        }
        guard available != 0,
              copied == requiredCount,
              copied == Int32(bytes.count) else {
            throw TorrentEngineError.bridgeError(
                "Torrent metadata changed while it was being copied."
            )
        }
        return Data(bytes)
    }

    private func snapshotBatch() throws -> TorrentSnapshotBatch {
        guard let client else {
            return TorrentSnapshotBatch(revision: 0, torrents: [])
        }

        return try snapshotBatch(client: client)
    }

    private func snapshotBatch(client: TorrentClientHandle) throws -> TorrentSnapshotBatch {
        guard let batch = try snapshotBatch(
            client: client,
            ifChangedSince: nil,
            refreshNative: true
        ) else {
            return TorrentSnapshotBatch(revision: 0, torrents: [])
        }
        return batch
    }

    // SAFETY: Ownership/lifetime: the passed handle keeps its pointer alive for the
    // nonsuspending refresh; bounds/alignment: refresh helpers use exact capped spans;
    // synchronization: actor isolation serializes handle and store access; safe alternative:
    // native snapshot refresh is available only through the C bridge.
    private func snapshotBatch(
        client: TorrentClientHandle,
        ifChangedSince previousRevision: UInt64?,
        refreshNative: Bool
    ) throws -> TorrentSnapshotBatch? {
        if refreshNative {
            guard let pointer = unsafe client.pointer else {
                throw TorrentEngineError.bridgeError("The torrent engine is unavailable.")
            }
            try unsafe refreshNativeState(client: pointer)
        }
        return snapshotStore.batch(ifChangedSince: previousRevision)
    }

    // SAFETY: Ownership/lifetime: the caller's actor-owned handle keeps `client` alive;
    // bounds/alignment: refresh uses typed, capped spans; synchronization: actor isolation
    // serializes queue reconciliation; safe alternative: native state is available only
    // through the C bridge ABI.
    private func ensureQueueState(client: OpaquePointer) throws {
        guard !queueStore.isInitialized || queueNeedsApplication else {
            return
        }
        try unsafe refreshNativeState(client: client)
    }

    // SAFETY: Ownership/lifetime: the caller's actor-owned handle keeps `client` alive;
    // bounds/alignment: refresh uses typed, capped spans; synchronization: actor isolation
    // serializes source-policy reconciliation; safe alternative: native state is available
    // only through the C bridge ABI.
    private func ensureSourcePolicyState(client: OpaquePointer) throws {
        guard !sourcePolicyStore.isInitialized || sourcePolicyNeedsApplication else {
            return
        }
        try unsafe refreshNativeState(client: client)
    }

    // SAFETY: Ownership/lifetime: the caller's actor-owned handle owns `client` throughout
    // this nonsuspending reconciliation; bounds/alignment: all copy/apply helpers use exact
    // typed spans, capped counts, and validated identities; synchronization: actor isolation
    // makes reconciliation transactional; safe alternative: native state exists only behind
    // the C bridge ABI.
    private func refreshNativeState(client: OpaquePointer) throws {
        var snapshots = try reconcileNativeSnapshots(
            unsafe copyNativeSnapshots(client: client)
        )
        let wasQueueInitialized = queueStore.isInitialized
        let queueReconciliation = queueStore.reconcile(snapshots)
        guard queueReconciliation != .rejected else {
            throw TorrentEngineError.bridgeError(
                "The native torrent snapshot batch violated the Swift queue identity contract."
            )
        }

        if !wasQueueInitialized || queueReconciliation == .updated || queueNeedsApplication {
            try unsafe applyQueueState(queueStore, client: client)
            queueNeedsApplication = false
            snapshots = try reconcileNativeSnapshots(
                unsafe copyNativeSnapshots(client: client)
            )
        }

        let nativeSourceStates = try unsafe copyNativeSourcePolicyStates(client: client)
        let wasSourcePolicyInitialized = sourcePolicyStore.isInitialized
        let sourceReconciliation = sourcePolicyStore.reconcile(
            nativeSourceStates,
            torrentIDs: Set(snapshots.map(\.id))
        )
        guard sourceReconciliation != .rejected else {
            throw TorrentEngineError.bridgeError(
                "The native source-policy batch violated the Swift identity contract."
            )
        }
        if !wasSourcePolicyInitialized
            || sourceReconciliation == .updated
            || sourcePolicyNeedsApplication {
            sourcePolicyNeedsApplication = true
            try unsafe applySourcePolicyState(sourcePolicyStore, client: client)
            sourcePolicyNeedsApplication = false
            snapshots = try reconcileNativeSnapshots(
                unsafe copyNativeSnapshots(client: client)
            )
        }

        for metadata in try unsafe drainNativePresentationMetadata(client: client) {
            guard let id = identityStore.id(forNativeToken: metadata.native_token) else {
                continue
            }
            guard snapshotStore.registerPresentation(
                id: id,
                comment: String(cStringTuple: metadata.comment),
                createdTime: metadata.created_time
            ) else {
                throw TorrentEngineError.bridgeError(
                    "Native torrent presentation metadata violated its bounded value contract."
                )
            }
        }

        guard snapshotStore.reconcile(snapshots) != .rejected else {
            throw TorrentEngineError.bridgeError(
                "The native torrent snapshot batch violated its bounded identity contract."
            )
        }
        detailStore.retainTorrentIDs(snapshotStore.torrentIDs)
    }

    // SAFETY: Ownership/lifetime: the caller owns `client` and the placement array/error
    // buffer live through the synchronous call; bounds/alignment: Span carries the exact
    // typed element count; synchronization: actor isolation serializes queue application;
    // safe alternative: native queue state is accepted only by the C bridge.
    private func applyQueueState(
        _ state: TorrentQueueStore,
        client: OpaquePointer
    ) throws {
        let placements = try state.placements.map { placement in
            try nativeQueuePlacement(placement)
        }
        try throwingBridgeCall { errorBuffer in
            let placementSpan: Span<TTorrentQueuePlacement>? = placements.isEmpty
                ? nil
                : placements.span
            return unsafe TorrentClientApplyQueueState(
                client,
                placementSpan,
                &errorBuffer
            )
        }
    }

    // SAFETY: Ownership/lifetime: the caller owns `client` and the application array/error
    // buffer live through the synchronous call; bounds/alignment: Span carries the exact
    // typed element count; synchronization: actor isolation serializes policy application;
    // safe alternative: native source policy is accepted only by the C bridge.
    private func applySourcePolicyState(
        _ state: TorrentSourcePolicyStore,
        client: OpaquePointer
    ) throws {
        let applications = try state.applications.map { application in
            try nativeSourcePolicyApplication(application)
        }
        try throwingBridgeCall { errorBuffer in
            let applicationSpan: Span<TTorrentSourcePolicyApplication>? = applications.isEmpty
                ? nil
                : applications.span
            return unsafe TorrentClientApplySourcePolicyState(
                client,
                applicationSpan,
                &errorBuffer
            )
        }
    }

    // SAFETY: Ownership/lifetime: the caller owns `client` and each local state array lives
    // through synchronous copies; bounds/alignment: MutableSpan carries exact capacity,
    // counts are nonnegative/capped/equality-checked; synchronization: actor isolation
    // serializes copy/reconciliation; safe alternative: native states use the C bridge ABI.
    private func copyNativeSourcePolicyStates(
        client: OpaquePointer
    ) throws -> [TorrentSourcePolicyStore.NativeState] {
        var requiredCount: Int32 = 0
        var available: UInt8 = 0
        var stateSpan: MutableSpan<TTorrentSourcePolicyState>?
        _ = unsafe TorrentClientCopySourcePolicyStateBatch(
            client,
            &stateSpan,
            &requiredCount,
            &available
        )
        guard available != 0, requiredCount >= 0 else {
            throw TorrentEngineError.bridgeError("The native source-policy batch is unavailable.")
        }

        var capacity = Self.cappedCapacity(
            requiredCount: requiredCount,
            minimum: 16,
            maximum: TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT
        )
        var states = Array(repeating: TTorrentSourcePolicyState(), count: capacity)
        var copied = Self.withMutableBridgeSpan(&states) { stateSpan in
            unsafe TorrentClientCopySourcePolicyStateBatch(
                client,
                &stateSpan,
                &requiredCount,
                &available
            )
        }
        guard available != 0 else {
            throw TorrentEngineError.bridgeError(
                "The native source-policy batch became unavailable while being copied."
            )
        }
        while requiredCount > Int32(capacity), capacity < Int(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT) {
            capacity = Self.cappedCapacity(
                requiredCount: requiredCount,
                minimum: capacity * 2,
                maximum: TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT
            )
            states = Array(repeating: TTorrentSourcePolicyState(), count: capacity)
            copied = Self.withMutableBridgeSpan(&states) { stateSpan in
                unsafe TorrentClientCopySourcePolicyStateBatch(
                    client,
                    &stateSpan,
                    &requiredCount,
                    &available
                )
            }
            guard available != 0 else {
                throw TorrentEngineError.bridgeError(
                    "The native source-policy batch became unavailable while being copied."
                )
            }
        }
        guard copied >= 0,
              copied == requiredCount,
              copied <= Int32(states.count) else {
            throw TorrentEngineError.bridgeError(
                "The native source-policy batch changed beyond its bounded copy contract."
            )
        }
        return try states.prefix(Int(copied)).map { state in
            try swiftSourcePolicyState(state)
        }
    }

    // SAFETY: Ownership/lifetime: the caller owns `client` and each local snapshot array
    // lives through synchronous copies; bounds/alignment: MutableSpan carries exact capacity,
    // counts are nonnegative/capped/equality-checked; synchronization: actor isolation
    // serializes copy/reconciliation; safe alternative: native snapshots use the C bridge ABI.
    private func copyNativeSnapshots(
        client: OpaquePointer
    ) throws -> [TorrentIdentityStore.NativeSnapshot] {
        var requiredCount: Int32 = 0
        var available: UInt8 = 0
        var snapshotSpan: MutableSpan<TTorrentSnapshot>?
        _ = unsafe TorrentClientCopySnapshotBatch(
            client,
            &snapshotSpan,
            &requiredCount,
            &available
        )
        guard available != 0, requiredCount >= 0 else {
            throw TorrentEngineError.bridgeError("The native torrent snapshot batch is unavailable.")
        }

        var capacity = Self.cappedCapacity(
            requiredCount: requiredCount,
            minimum: 16,
            maximum: TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT
        )
        var snapshots = Array(repeating: TTorrentSnapshot(), count: capacity)
        var copied = Self.withMutableBridgeSpan(&snapshots) { snapshotSpan in
            unsafe TorrentClientCopySnapshotBatch(
                client,
                &snapshotSpan,
                &requiredCount,
                &available
            )
        }
        guard available != 0 else {
            throw TorrentEngineError.bridgeError("The native torrent snapshot batch became unavailable while being copied.")
        }

        while requiredCount > Int32(capacity), capacity < Int(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT) {
            capacity = Self.cappedCapacity(
                requiredCount: requiredCount,
                minimum: capacity * 2,
                maximum: TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT
            )
            snapshots = Array(repeating: TTorrentSnapshot(), count: capacity)
            copied = Self.withMutableBridgeSpan(&snapshots) { snapshotSpan in
                unsafe TorrentClientCopySnapshotBatch(
                    client,
                    &snapshotSpan,
                    &requiredCount,
                    &available
                )
            }
            guard available != 0 else {
                throw TorrentEngineError.bridgeError("The native torrent snapshot batch became unavailable while being copied.")
            }
        }

        guard copied >= 0,
              requiredCount >= 0,
              copied == requiredCount,
              copied <= Int32(snapshots.count) else {
            throw TorrentEngineError.bridgeError("The native torrent snapshot batch changed beyond its bounded copy contract.")
        }
        return snapshots.prefix(Int(copied)).map { snapshot in
            TorrentIdentityStore.NativeSnapshot(
                nativeToken: snapshot.native_token,
                torrent: TorrentItem(snapshot: snapshot)
            )
        }
    }

    // SAFETY: Ownership/lifetime: the caller owns `client` and local metadata arrays live
    // through synchronous drains; bounds/alignment: exact MutableSpan capacities and hard
    // maximums bound all writes, with returned counts equality-checked; synchronization:
    // actor isolation provides a single drainer; safe alternative: native metadata is exposed
    // only by the C bridge ABI.
    private func drainNativePresentationMetadata(
        client: OpaquePointer
    ) throws -> [TTorrentPresentationMetadata] {
        var requiredCount: Int32 = 0
        var available: UInt8 = 0
        var metadataSpan: MutableSpan<TTorrentPresentationMetadata>?
        _ = unsafe TorrentClientDrainPresentationMetadata(
            client,
            &metadataSpan,
            &requiredCount,
            &available
        )
        guard available != 0,
              requiredCount >= 0,
              requiredCount <= TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT else {
            throw TorrentEngineError.bridgeError(
                "Native torrent presentation metadata is unavailable or exceeds its bounded contract."
            )
        }
        guard requiredCount > 0 else {
            return []
        }

        var capacity = Int(requiredCount)
        var metadata = Array(repeating: TTorrentPresentationMetadata(), count: capacity)
        var copied = Self.withMutableBridgeSpan(&metadata) { metadataSpan in
            unsafe TorrentClientDrainPresentationMetadata(
                client,
                &metadataSpan,
                &requiredCount,
                &available
            )
        }
        while requiredCount > Int32(capacity),
              requiredCount <= TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT {
            capacity = Int(requiredCount)
            metadata = Array(repeating: TTorrentPresentationMetadata(), count: capacity)
            copied = Self.withMutableBridgeSpan(&metadata) { metadataSpan in
                unsafe TorrentClientDrainPresentationMetadata(
                    client,
                    &metadataSpan,
                    &requiredCount,
                    &available
                )
            }
        }
        guard available != 0,
              requiredCount >= 0,
              requiredCount <= TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT,
              copied == requiredCount,
              copied <= Int32(metadata.count) else {
            throw TorrentEngineError.bridgeError(
                "Native torrent presentation metadata changed beyond its bounded copy contract."
            )
        }
        return Array(metadata.prefix(Int(copied)))
    }

    private func reconcileNativeSnapshots(
        _ snapshots: [TorrentIdentityStore.NativeSnapshot]
    ) throws -> [TorrentItem] {
        guard identityStore.reconcile(snapshots) != .rejected else {
            throw TorrentEngineError.bridgeError(
                "The native torrent snapshot batch violated the Swift identity contract."
            )
        }
        persistenceStore.retain(nativeTokens: identityStore.activeNativeTokens)
        return snapshots.map(\.torrent)
    }

    // SAFETY: Ownership/lifetime: the caller's actor-owned handle owns `client` and error
    // buffers live through synchronous saves; bounds/alignment: tokens are tracked scalars and
    // error spans are exact; synchronization: actor isolation serializes persistence attempts;
    // safe alternative: resume save/recovery operations exist only through the C bridge.
    private func processPendingPersistence(
        client: OpaquePointer
    ) -> [String] {
        var errors = [String]()
        for attempt in persistenceStore.pendingAttempts() {
            do {
                try throwingBridgeCall { errorBuffer in
                    unsafe TorrentClientSaveResumeDataChecked(
                        client,
                        attempt.nativeToken,
                        attempt.mode.rawValue,
                        &errorBuffer
                    )
                }
                persistenceStore.complete(attempt, succeeded: true)
            } catch {
                persistenceStore.complete(attempt, succeeded: false)
                errors.append(
                    "Resume data could not be saved: \(error.localizedDescription)"
                )
            }
        }
        errors.append(contentsOf: unsafe processPendingRemovalCleanups(client: client))
        return errors
    }

    // SAFETY: Ownership/lifetime: the caller's actor-owned handle owns `client` for all
    // synchronous cleanup calls; bounds/alignment: resume rows/error spans are exact and
    // filenames are validated/NUL-terminated; synchronization: actor isolation and the
    // persistence state machine serialize retries; safe alternative: native removal cleanup
    // is available only through the C bridge ABI.
    private func processPendingRemovalCleanups(
        client: OpaquePointer
    ) -> [String] {
        var errors = [String]()
        for cleanup in persistenceStore.pendingRemovalCleanups {
            if !cleanup.resumeDataWasRemoved {
                do {
                    try unsafe removeResumeData(
                        client: client,
                        resumeIDs: cleanup.resumeIDs
                    )
                    persistenceStore.markResumeDataRemoved(
                        tombstoneFilename: cleanup.tombstoneFilename
                    )
                } catch {
                    errors.append(
                        "Torrent removal resume cleanup is pending: \(error.localizedDescription)"
                    )
                    continue
                }
            }

            do {
                try unsafe clearRemovalTombstone(
                    client: client,
                    filename: cleanup.tombstoneFilename
                )
                persistenceStore.completeRemovalCleanup(
                    tombstoneFilename: cleanup.tombstoneFilename
                )
            } catch {
                errors.append(
                    "Torrent removal marker cleanup is pending: \(error.localizedDescription)"
                )
            }
        }
        if persistenceStore.shouldRecoverNativeRemovals {
            do {
                try throwingBridgeCall { errorBuffer in
                    unsafe TorrentClientRecoverPendingRemovalsChecked(
                        client,
                        &errorBuffer
                    )
                }
                persistenceStore.completeNativeRemovalRecovery(succeeded: true)
            } catch {
                persistenceStore.completeNativeRemovalRecovery(succeeded: false)
                errors.append(
                    "Native removal recovery is pending: \(error.localizedDescription)"
                )
            }
        }
        return errors
    }

    // SAFETY: Ownership/lifetime: the caller owns `client` and the local row array lives
    // through synchronous copies; bounds/alignment: exact MutableSpan capacity is bounded by
    // TTORRENT_MAX_RESUME_ID_COUNT and counts are equality-checked; synchronization: actor
    // isolation serializes access; safe alternative: native resume IDs use the C bridge ABI.
    private func copyResumeIDs(
        client: OpaquePointer,
        nativeToken: UInt64
    ) throws -> [String] {
        var requiredCount: Int32 = 0
        var available: UInt8 = 0
        var idSpan: MutableSpan<TTorrentResumeID>?
        _ = unsafe TorrentClientCopyResumeIDs(
            client,
            nativeToken,
            &idSpan,
            &requiredCount,
            &available
        )
        guard available != 0,
              requiredCount > 0,
              requiredCount <= TTORRENT_MAX_RESUME_ID_COUNT else {
            throw TorrentEngineError.bridgeError(
                "The native resume identity set is unavailable or invalid."
            )
        }

        var rows = Array(
            repeating: TTorrentResumeID(),
            count: Int(requiredCount)
        )
        let copied = Self.withMutableBridgeSpan(&rows) { idSpan in
            unsafe TorrentClientCopyResumeIDs(
                client,
                nativeToken,
                &idSpan,
                &requiredCount,
                &available
            )
        }
        guard available != 0,
              copied == requiredCount,
              copied == rows.count else {
            throw TorrentEngineError.bridgeError(
                "The native resume identity set changed while being copied."
            )
        }
        let ids = rows.map { String(cStringTuple: $0.value) }
        guard !ids.contains(where: \.isEmpty), Set(ids).count == ids.count else {
            throw TorrentEngineError.bridgeError(
                "The native resume identity set contained an invalid value."
            )
        }
        return ids
    }

    // SAFETY: Ownership/lifetime: the caller owns `client` and row/filename/error buffers live
    // through the synchronous call; bounds/alignment: exact Span/MutableSpan capacities are
    // bridge-defined and each ID was bounded during conversion; synchronization: actor
    // isolation serializes durable removal state; safe alternative: native tombstone creation
    // exists only through the C bridge ABI.
    private func persistRemovalTombstone(
        client: OpaquePointer,
        resumeIDs: [String]
    ) throws -> String {
        let rows = try nativeResumeIDs(resumeIDs)
        var filenameBuffer = Array<CChar>(
            repeating: 0,
            count: Int(TTORRENT_REMOVAL_TOMBSTONE_FILENAME_CAPACITY)
        )
        try throwingBridgeCall { errorBuffer in
            let idSpan: Span<TTorrentResumeID>? = rows.span
            var filenameSpan: MutableSpan<CChar>? = filenameBuffer.mutableSpan
            return unsafe TorrentClientPersistRemovalTombstone(
                client,
                idSpan,
                &filenameSpan,
                &errorBuffer
            )
        }
        let filename = stringFromBridgeBuffer(filenameBuffer)
        guard !filename.isEmpty else {
            throw TorrentEngineError.bridgeError(
                "The durable removal tombstone filename was not returned."
            )
        }
        return filename
    }

    // SAFETY: Ownership/lifetime: the caller owns `client` and row/error buffers live through
    // the synchronous call; bounds/alignment: the exact row Span contains validated bounded
    // IDs; synchronization: actor isolation serializes persistence cleanup; safe alternative:
    // native resume-data deletion exists only through the C bridge ABI.
    private func removeResumeData(
        client: OpaquePointer,
        resumeIDs: [String]
    ) throws {
        let rows = try nativeResumeIDs(resumeIDs)
        try throwingBridgeCall { errorBuffer in
            let idSpan: Span<TTorrentResumeID>? = rows.span
            return unsafe TorrentClientRemoveResumeData(
                client,
                idSpan,
                &errorBuffer
            )
        }
    }

    // SAFETY: Ownership/lifetime: the caller owns `client`, the String pins its C storage, and
    // the error buffer lives through the synchronous call; bounds/alignment: filename was
    // produced by the bounded bridge and withCString NUL-terminates it; synchronization:
    // actor isolation serializes cleanup; safe alternative: native tombstone deletion is a C API.
    private func clearRemovalTombstone(
        client: OpaquePointer,
        filename: String
    ) throws {
        try throwingBridgeCall { errorBuffer in
            unsafe filename.withCString { filenamePointer in
                unsafe TorrentClientClearRemovalTombstone(
                    client,
                    filenamePointer,
                    &errorBuffer
                )
            }
        }
    }

    // SAFETY: Ownership/lifetime: each local imported row and UTF-8 array lives through its
    // synchronous copy; bounds/alignment: IDs are shorter than the fixed destination field,
    // indices come from the source array, and tuple storage is byte-addressable; synchronization:
    // locals are unshared; safe alternative: imported fixed C arrays lack a Swift collection API.
    private func nativeResumeIDs(_ ids: [String]) throws -> [TTorrentResumeID] {
        guard !ids.isEmpty,
              ids.count <= Int(TTORRENT_MAX_RESUME_ID_COUNT),
              Set(ids).count == ids.count else {
            throw TorrentEngineError.bridgeError("The resume identity set is invalid.")
        }
        return try ids.map { id in
            let bytes = Array(id.utf8)
            guard !bytes.isEmpty, bytes.count < Int(TTORRENT_ID_CAPACITY) else {
                throw TorrentEngineError.bridgeError("A resume identifier is invalid.")
            }
            var row = TTorrentResumeID()
            unsafe withUnsafeMutableBytes(of: &row.value) { destination in
                for index in bytes.indices {
                    unsafe destination[index] = bytes[index]
                }
            }
            return row
        }
    }

    private func recordPersistenceError(_ message: String) {
        let maximum = TorrentEngineLimits.maximumAlertErrorsPerPoll
        guard maximum > 0 else {
            return
        }
        if pendingPersistenceErrors.count >= maximum {
            pendingPersistenceErrors.removeFirst(
                pendingPersistenceErrors.count - maximum + 1
            )
        }
        pendingPersistenceErrors.append(message)
    }

    // SAFETY: Ownership/lifetime: each Swift context starts with one local retain, native
    // synchronously takes its own retain through the installed callback before creation returns,
    // deferred releases balance only the local retains, and the returned handle uniquely owns
    // the client; bounds/alignment: callback tables are exact imported structs, the path is
    // NUL-terminated, and MutableSpan bounds the error buffer; synchronization: Sendable callback
    // contexts provide their own locking and the client is not published until construction ends;
    // safe alternative: C callback tables and opaque client creation cannot be represented by a
    // wholly safe Swift API.
    private static func createClient(
        stateDirectory: URL,
        wakeRelay: TorrentWakeRelay,
        enablePeerExchangePlugin: Bool,
        payloadBroker: any TorrentPayloadBrokerAccess
    ) throws -> TorrentClientHandle {
        try clientCreationPreflight.withLock { $0 }?(
            stateDirectory,
            enablePeerExchangePlugin
        )

        let path = stateDirectory.torrentFilePath
        let context = TorrentPayloadBrokerBridgeContext(broker: payloadBroker)
        let retainedContext = unsafe Unmanaged.passRetained(context)
        let swarmMetainfoContext = TorrentSwarmMetainfoParserBridgeContext()
        let retainedSwarmMetainfoContext = unsafe Unmanaged.passRetained(
            swarmMetainfoContext
        )
        let peerProtocolContext = TorrentPeerProtocolBridgeContext()
        let retainedPeerProtocolContext = unsafe Unmanaged.passRetained(
            peerProtocolContext
        )
        let trackerResponseContext = TorrentTrackerResponseBridgeContext()
        let retainedTrackerResponseContext = unsafe Unmanaged.passRetained(
            trackerResponseContext
        )
        let dhtMessageContext = TorrentDHTMessageBridgeContext()
        let retainedDHTMessageContext = unsafe Unmanaged.passRetained(
            dhtMessageContext
        )
        defer {
            unsafe retainedContext.release()
            unsafe retainedSwarmMetainfoContext.release()
            unsafe retainedPeerProtocolContext.release()
            unsafe retainedTrackerResponseContext.release()
            unsafe retainedDHTMessageContext.release()
        }

        var callbacks = unsafe TTorrentPayloadBrokerCallbacks()
        unsafe callbacks.context = retainedContext.toOpaque()
        unsafe callbacks.retain_context = torrentPayloadContextRetainCallback
        unsafe callbacks.release_context = torrentPayloadContextReleaseCallback
        unsafe callbacks.open_payload = torrentPayloadOpenCallback
        unsafe callbacks.payload_size = torrentPayloadSizeCallback

        var swarmMetainfoCallbacks = unsafe TTorrentSwarmMetainfoParserCallbacks()
        unsafe swarmMetainfoCallbacks.context = retainedSwarmMetainfoContext.toOpaque()
        unsafe swarmMetainfoCallbacks.retain_context =
            torrentSwarmMetainfoContextRetainCallback
        unsafe swarmMetainfoCallbacks.release_context =
            torrentSwarmMetainfoContextReleaseCallback
        unsafe swarmMetainfoCallbacks.parse_info = torrentSwarmMetainfoParseCallback
        unsafe swarmMetainfoCallbacks.release_capsule =
            torrentSwarmMetainfoCapsuleReleaseCallback

        var peerProtocolCallbacks = unsafe TTorrentPeerProtocolParserCallbacks()
        unsafe peerProtocolCallbacks.context = retainedPeerProtocolContext.toOpaque()
        unsafe peerProtocolCallbacks.retain_context =
            torrentPeerProtocolContextRetainCallback
        unsafe peerProtocolCallbacks.release_context =
            torrentPeerProtocolContextReleaseCallback
        unsafe peerProtocolCallbacks.parse_extension_handshake =
            torrentExtensionHandshakeParseCallback
        unsafe peerProtocolCallbacks.parse_metadata_message =
            torrentMetadataMessageParseCallback
        unsafe peerProtocolCallbacks.parse_peer_exchange =
            torrentPeerExchangeParseCallback

        var trackerResponseCallbacks = unsafe TTorrentTrackerResponseParserCallbacks()
        unsafe trackerResponseCallbacks.context = retainedTrackerResponseContext.toOpaque()
        unsafe trackerResponseCallbacks.retain_context =
            torrentTrackerParserContextRetainCallback
        unsafe trackerResponseCallbacks.release_context =
            torrentTrackerParserContextReleaseCallback
        unsafe trackerResponseCallbacks.parse_http_response =
            torrentHTTPTrackerResponseParseCallback

        var dhtMessageCallbacks = unsafe TTorrentDHTMessageParserCallbacks()
        unsafe dhtMessageCallbacks.context = retainedDHTMessageContext.toOpaque()
        unsafe dhtMessageCallbacks.retain_context =
            torrentDHTParserContextRetainCallback
        unsafe dhtMessageCallbacks.release_context =
            torrentDHTParserContextReleaseCallback
        unsafe dhtMessageCallbacks.parse_message = torrentDHTMessageParseCallback

        var errorBuffer = Array<CChar>(repeating: 0, count: 1_024)
        var errorSpan: MutableSpan<CChar>? = errorBuffer.mutableSpan
        let created = unsafe path.withCString { pointer in
            unsafe TorrentClientCreateWithError(
                pointer,
                enablePeerExchangePlugin.bridgeFlag,
                callbacks,
                swarmMetainfoCallbacks,
                peerProtocolCallbacks,
                trackerResponseCallbacks,
                dhtMessageCallbacks,
                &errorSpan
            )
        }
        errorSpan = nil
        guard let created = unsafe created else {
            let message = stringFromBridgeBuffer(errorBuffer)
            throw TorrentEngineError.bridgeError(message.isEmpty ? "Unknown startup error." : message)
        }
        return unsafe TorrentClientHandle(created, wakeRelay: wakeRelay)
    }

    // SAFETY: Ownership/lifetime: the actor-owned TorrentClientHandle remains stored while the
    // returned pointer is used by nonsuspending actor methods; bounds/alignment: this is an
    // opaque handle and no raw bytes are accessed; synchronization: actor isolation prevents
    // concurrent destruction; safe alternative: the C bridge identifies its client by pointer.
    private func requireClient() throws -> OpaquePointer {
        if let startupFailureMessage {
            throw TorrentEngineError.startupFailed(startupFailureMessage)
        }
        try throwIfRuntimeFailure()
        guard let pointer = unsafe client?.pointer else {
            throw TorrentEngineError.failedToCreateClient
        }
        return unsafe pointer
    }

    private func throwIfRuntimeFailure() throws {
        if let runtimeFailureMessage = runtimeFailureMessage.withLock({ $0 }) {
            throw TorrentEngineError.bridgeError(runtimeFailureMessage)
        }
    }

    // SAFETY: Ownership/lifetime: the actor-owned handle keeps the client alive during any
    // synchronous refresh; bounds/alignment: refresh helpers use bounded typed spans;
    // synchronization: actor isolation serializes identity reconciliation; safe alternative:
    // native token discovery requires querying the C bridge.
    private func nativeToken(for id: TorrentItem.ID) throws -> UInt64 {
        let client = try unsafe requireClient()
        if !identityStore.isInitialized {
            try unsafe refreshNativeState(client: client)
        }
        guard let nativeToken = identityStore.nativeToken(for: id) else {
            throw TorrentEngineError.bridgeError("Torrent not found.")
        }
        return nativeToken
    }

    private func destroyClient(waitForShutdown: Bool = false) {
        if waitForShutdown {
            client?.destroyBlocking()
        }
        client = nil
    }

    private func throwingBridgeCall(
        _ body: (inout MutableSpan<CChar>?) -> Int32
    ) throws {
        var errorBuffer = Array<CChar>(repeating: 0, count: 1024)
        var errorSpan: MutableSpan<CChar>? = errorBuffer.mutableSpan
        let result = body(&errorSpan)
        errorSpan = nil
        if result != 0 {
            let message = stringFromBridgeBuffer(errorBuffer)
            throw TorrentEngineError.bridgeError(message)
        }
    }

    // SAFETY: Ownership/lifetime: output/error arrays and scalar inout values remain alive for
    // the nonescaping synchronous body invocation; bounds/alignment: MutableSpan exposes exact
    // capacities and Swift supplies aligned typed scalar pointers; synchronization: caller is
    // actor-isolated and locals are unshared; safe alternative: the C add ABI requires pointer
    // outputs even though its buffers use SafeInterop wrappers.
    private func throwingBridgeAdd(
        capacity: Int,
        _ body: (
            inout MutableSpan<CChar>?,
            UnsafeMutablePointer<UInt64>,
            UnsafeMutablePointer<Int32>,
            inout MutableSpan<CChar>?
        ) -> Int32
    ) throws -> AddedTorrentIdentity {
        var outputBuffer = Array<CChar>(repeating: 0, count: capacity)
        var errorBuffer = Array<CChar>(repeating: 0, count: 1_024)
        var addOutcome = Int32(TTORRENT_ADD_REJECTED)
        var nativeToken: UInt64 = 0
        var outputSpan: MutableSpan<CChar>? = outputBuffer.mutableSpan
        var errorSpan: MutableSpan<CChar>? = errorBuffer.mutableSpan
        let result = unsafe body(&outputSpan, &nativeToken, &addOutcome, &errorSpan)
        outputSpan = nil
        errorSpan = nil
        let errorMessage = stringFromBridgeBuffer(errorBuffer)

        guard result == 0 else {
            if addOutcome == Int32(TTORRENT_ADD_REJECTED) {
                throw TorrentAddError.rejected(errorMessage)
            }
            throw TorrentAddError.commitStatusUnknown(errorMessage)
        }
        guard addOutcome == Int32(TTORRENT_ADD_COMMITTED) else {
            throw TorrentAddError.commitStatusUnknown(
                "The bridge returned an inconsistent torrent add outcome."
            )
        }

        let value = stringFromBridgeBuffer(outputBuffer)
        guard !value.isEmpty, nativeToken != 0 else {
            throw TorrentAddError.commitStatusUnknown(
                "Torrent was added, but its identity was not returned."
            )
        }
        return AddedTorrentIdentity(id: value, nativeToken: nativeToken)
    }

    private static func validateTorrentData(_ data: Data) throws {
        guard !data.isEmpty else {
            throw TorrentEngineError.bridgeError("The torrent file is empty.")
        }
        guard data.count <= TorrentInputLimits.maxTorrentFileBytes else {
            throw TorrentEngineError.bridgeError("The torrent file is too large.")
        }
    }

    // SAFETY: Ownership/lifetime: the local imported struct and canonical-ID Data live through
    // the synchronous copy; bounds/alignment: canonical IDs are generated within the fixed
    // TTORRENT canonical_id capacity and copyBytes is bounded by destination storage;
    // synchronization: local values are unshared; safe alternative: the imported fixed C array
    // has no mutable Swift collection API.
    private static func nativeAddOptions(
        canonicalID: TorrentItem.ID,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        sourcePolicy: TorrentSourcePolicyStore.Application,
        httpsTrackerPolicy: TorrentHTTPSTrackerPolicyOverride,
        httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicyOverride,
        allowPreMetadataDHT: Bool
    ) -> TTorrentAddOptions {
        var options = TTorrentAddOptions()
        options.starts_paused = startsPaused.bridgeFlag
        options.queue_priority = queuePriority.bridgeByteValue
        options.enable_dht = sourcePolicy.enableDHT.bridgeFlag
        options.enable_peer_exchange = sourcePolicy.enablePeerExchange.bridgeFlag
        options.enable_lsd = sourcePolicy.enableLocalServiceDiscovery.bridgeFlag
        options.https_tracker_policy = UInt8(httpsTrackerPolicy.rawValue)
        options.https_web_seed_policy = UInt8(httpsWebSeedPolicy.rawValue)
        options.effective_https_tracker_policy = UInt8(
            sourcePolicy.effectiveHTTPSTrackerPolicy.rawValue
        )
        options.effective_https_web_seed_policy = UInt8(
            sourcePolicy.effectiveHTTPSWebSeedPolicy.rawValue
        )
        options.allow_pre_metadata_dht = allowPreMetadataDHT.bridgeFlag
        let canonicalIDBytes = Data(canonicalID.utf8)
        _ = unsafe withUnsafeMutableBytes(of: &options.canonical_id) { destination in
            _ = unsafe canonicalIDBytes.copyBytes(to: destination)
        }
        return options
    }

    // SAFETY: Ownership/lifetime: the local imported struct, UUID, digest, and ID bytes live
    // through each synchronous copy; bounds/alignment: UUID/digest sizes are fixed by validated
    // model invariants and preserved IDs fit their bridge field, while copyBytes remains bounded;
    // synchronization: locals are unshared; safe alternative: imported fixed C arrays have no
    // mutable Swift collection API.
    private static func nativeStorageActivation(
        _ activation: TorrentStorageActivation
    ) -> TTorrentStorageActivation {
        var native = TTorrentStorageActivation()
        native.claim_generation = activation.generation
        var uuid = activation.claimID.uuid
        _ = unsafe withUnsafeMutableBytes(of: &native.claim_id) { destination in
            unsafe withUnsafeBytes(of: &uuid) { source in
                unsafe destination.copyBytes(from: source)
            }
        }
        _ = unsafe withUnsafeMutableBytes(of: &native.source_manifest_digest) { destination in
            _ = unsafe activation.sourceManifestDigest.copyBytes(to: destination)
        }
        if let preservedTorrentID = activation.preservedTorrentID {
            let preservedIDBytes = Data(preservedTorrentID.utf8)
            _ = unsafe withUnsafeMutableBytes(of: &native.preserved_torrent_id) { destination in
                _ = unsafe preservedIDBytes.copyBytes(to: destination)
            }
        }
        return native
    }

    private func nativeQueuePlacement(
        _ placement: TorrentQueueStore.Placement
    ) throws -> TTorrentQueuePlacement {
        guard let nativeToken = identityStore.nativeToken(for: placement.id) else {
            throw TorrentEngineError.bridgeError("A Swift queue identity was invalid.")
        }

        var native = TTorrentQueuePlacement()
        native.native_token = nativeToken
        native.priority = placement.priority.bridgeValue
        return native
    }

    private func swiftSourcePolicyState(
        _ native: TTorrentSourcePolicyState
    ) throws -> TorrentSourcePolicyStore.NativeState {
        guard let id = identityStore.id(forNativeToken: native.native_token),
              let dhtOverride = Self.booleanPolicyOverride(native.dht_policy),
              let peerExchangeOverride = Self.booleanPolicyOverride(native.peer_exchange_policy),
              let localServiceDiscoveryOverride = Self.booleanPolicyOverride(native.lsd_policy),
              let trackerPolicy = TorrentHTTPSTrackerPolicyOverride(
                  rawValue: Int(native.https_tracker_policy)
              ),
              let webSeedPolicy = TorrentHTTPSWebSeedPolicyOverride(
                  rawValue: Int(native.https_web_seed_policy)
              ) else {
            throw TorrentEngineError.bridgeError("A native source-policy record was invalid.")
        }
        return TorrentSourcePolicyStore.NativeState(
            id: id,
            dhtOverride: dhtOverride,
            peerExchangeOverride: peerExchangeOverride,
            localServiceDiscoveryOverride: localServiceDiscoveryOverride,
            httpsTrackerPolicy: trackerPolicy,
            httpsWebSeedPolicy: webSeedPolicy,
            isDHTLocked: native.dht_locked.bridgeBool,
            isPeerExchangeLocked: native.peer_exchange_locked.bridgeBool,
            isLocalServiceDiscoveryLocked: native.lsd_locked.bridgeBool,
            isMetadataValidationPending: native.metadata_validation_pending.bridgeBool,
            allowsPreMetadataDHT: native.allow_pre_metadata_dht.bridgeBool
        )
    }

    private func nativeSourcePolicyApplication(
        _ application: TorrentSourcePolicyStore.Application
    ) throws -> TTorrentSourcePolicyApplication {
        guard let nativeToken = identityStore.nativeToken(for: application.id) else {
            throw TorrentEngineError.bridgeError("A Swift source-policy identity was invalid.")
        }

        var native = TTorrentSourcePolicyApplication()
        native.native_token = nativeToken
        native.dht_policy = Self.nativeBooleanPolicy(application.dhtOverride)
        native.peer_exchange_policy = Self.nativeBooleanPolicy(application.peerExchangeOverride)
        native.lsd_policy = Self.nativeBooleanPolicy(application.localServiceDiscoveryOverride)
        native.https_tracker_policy = UInt8(application.httpsTrackerPolicy.rawValue)
        native.https_web_seed_policy = UInt8(application.httpsWebSeedPolicy.rawValue)
        native.effective_https_tracker_policy = UInt8(
            application.effectiveHTTPSTrackerPolicy.rawValue
        )
        native.effective_https_web_seed_policy = UInt8(
            application.effectiveHTTPSWebSeedPolicy.rawValue
        )
        native.enable_dht = application.enableDHT.bridgeFlag
        native.enable_peer_exchange = application.enablePeerExchange.bridgeFlag
        native.enable_lsd = application.enableLocalServiceDiscovery.bridgeFlag
        native.allow_pre_metadata_dht = application.allowPreMetadataDHT.bridgeFlag
        return native
    }

    private static func booleanPolicyOverride(_ value: UInt8) -> Bool?? {
        switch value {
        case UInt8(TTORRENT_BOOLEAN_POLICY_INHERIT):
            .some(nil)
        case UInt8(TTORRENT_BOOLEAN_POLICY_DISABLED):
            .some(false)
        case UInt8(TTORRENT_BOOLEAN_POLICY_ENABLED):
            .some(true)
        default:
            nil
        }
    }

    private static func nativeBooleanPolicy(_ value: Bool?) -> UInt8 {
        switch value {
        case nil:
            UInt8(TTORRENT_BOOLEAN_POLICY_INHERIT)
        case false:
            UInt8(TTORRENT_BOOLEAN_POLICY_DISABLED)
        case true:
            UInt8(TTORRENT_BOOLEAN_POLICY_ENABLED)
        }
    }

    private static func withMutableBridgeSpan<Element>(
        _ storage: inout [Element],
        _ body: (inout MutableSpan<Element>?) -> Int32
    ) -> Int32 {
        var span: MutableSpan<Element>? = storage.mutableSpan
        return body(&span)
    }

    private static func cappedCapacity(requiredCount: Int32, minimum: Int, maximum: Int) -> Int {
        min(max(minimum, max(0, Int(requiredCount))), maximum)
    }

    private static func grownCapacity(current: Int, requiredCount: Int32, maximum: Int) -> Int {
        min(max(current * 2, max(0, Int(requiredCount))), maximum)
    }
}

@safe private final class TorrentClientHandle {
    private var rawPointer: OpaquePointer?
    private let wakeRelay: TorrentWakeRelay

    var pointer: OpaquePointer? {
        // SAFETY: Ownership/lifetime: `self` uniquely owns rawPointer until destroy sets it nil;
        // bounds/alignment: it is an opaque bridge handle with no byte access; synchronization:
        // the enclosing TorrentEngine actor serializes all access; safe alternative: the C bridge
        // exposes no non-pointer client identity.
        unsafe rawPointer
    }

    // SAFETY: Ownership/lifetime: this handle assumes unique ownership of `pointer` and stores
    // a strong wakeRelay before installing its unretained callback context; client destruction
    // clears and quiesces callbacks before either object dies; bounds/alignment: both are exact
    // opaque object pointers with no byte access; synchronization: native callback bookkeeping
    // and TorrentWakeRelay's Mutex support cross-thread wakes; safe alternative: the C bridge
    // callback/context API cannot retain a Swift object directly.
    init(_ pointer: OpaquePointer, wakeRelay: TorrentWakeRelay) {
        unsafe rawPointer = pointer
        self.wakeRelay = wakeRelay
        unsafe TorrentClientSetWakeCallback(
            pointer,
            torrentWakeCallback,
            Unmanaged.passUnretained(wakeRelay).toOpaque()
        )
    }

    // SAFETY: Ownership/lifetime: taking then niling rawPointer transfers its unique ownership
    // to the consuming destroy call; bounds/alignment: it is the exact opaque handle returned
    // by creation; synchronization: the engine actor is the sole caller and blocking destroy
    // quiesces callbacks/workers; safe alternative: native destruction requires the C bridge.
    func destroyBlocking() {
        guard let pointer = unsafe rawPointer else {
            return
        }

        unsafe rawPointer = nil
        unsafe TorrentClientDestroyBlocking(pointer)
    }

    // SAFETY: Ownership/lifetime: a remaining rawPointer is still uniquely owned by this handle
    // and the consuming native destructor clears/quiesces the wake callback before returning;
    // bounds/alignment: it is the exact opaque handle returned by creation; synchronization:
    // no actor operation can retain this dead handle; safe alternative: RAII fallback cleanup
    // must call the C bridge destructor.
    deinit {
        if let rawPointer = unsafe rawPointer {
            unsafe TorrentClientDestroy(rawPointer)
        }
    }
}
