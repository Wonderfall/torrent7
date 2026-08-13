import Foundation
import Synchronization
import TorrentBridge
import TorrentEngineModel

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

private func torrentWakeCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context = unsafe context else {
        return
    }

    let relay = unsafe Unmanaged<TorrentWakeRelay>.fromOpaque(context).takeUnretainedValue()
    relay.signal()
}

package typealias TorrentClientCreationPreflight = @Sendable (
    _ stateDirectory: URL,
    _ enablePeerExchangePlugin: Bool,
    _ authorizedSaveRoots: [TorrentAuthorizedSaveRoot]
) throws -> Void

private struct TorrentRemovalResultStatus: Sendable {
    var state: Int32
    var error: String
}

package enum TorrentRemovalResultReadOverride: Sendable {
    case pending
    case unknownState
}

@safe private struct TorrentEncodedAuthorizedSaveRoots {
    let pathBlob: [UInt8]
    let nativeRoots: [TTorrentAuthorizedSaveRoot]
    // Native records contain process-local tokens registered by these roots.
    // Keep the token owners alive until the synchronous bridge call retains
    // every accepted lifetime.
    let retainedRoots: [TorrentAuthorizedSaveRoot]
}

private struct TorrentAuthorizedSaveRootIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
}

package typealias TorrentRemovalResultReader = @Sendable () throws -> TorrentRemovalResultReadOverride?
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

@safe package actor TorrentEngine {
    package static let clientCreationPreflight = Mutex<TorrentClientCreationPreflight?>(nil)

    private let stateDirectory: URL?
    private let removalResultReader: TorrentRemovalResultReader?
    private let alertErrorReader: TorrentAlertErrorReader?
    package nonisolated let startupFailureMessage: String?
    private let runtimeFailureMessage = Mutex<String?>(nil)
    private let wakeRelay = TorrentWakeRelay()
    private var client: TorrentClientHandle?
    private var hasPendingRemovalRequest = false
    private var isShutdown = false
    package nonisolated let libtorrentVersion: String

    package init(
        stateDirectory: URL,
        enablePeerExchangePlugin: Bool,
        authorizedSaveRoots: [TorrentAuthorizedSaveRoot] = [],
        removalResultReader: TorrentRemovalResultReader? = nil,
        alertErrorReader: TorrentAlertErrorReader? = nil
    ) throws {
        self.stateDirectory = stateDirectory
        self.removalResultReader = removalResultReader
        self.alertErrorReader = alertErrorReader
        startupFailureMessage = nil
        unsafe libtorrentVersion = String(cString: TorrentBridgeLibtorrentVersion())
        client = try Self.createClient(
            stateDirectory: stateDirectory,
            wakeRelay: wakeRelay,
            enablePeerExchangePlugin: enablePeerExchangePlugin,
            authorizedSaveRoots: authorizedSaveRoots
        )
    }

    package init(startupFailureMessage: String) {
        stateDirectory = nil
        removalResultReader = nil
        alertErrorReader = nil
        self.startupFailureMessage = startupFailureMessage
        unsafe libtorrentVersion = String(cString: TorrentBridgeLibtorrentVersion())
        client = nil
    }

    package nonisolated var isAvailable: Bool {
        startupFailureMessage == nil && runtimeFailureMessage.withLock { $0 == nil }
    }

    package func restart(
        enablePeerExchangePlugin: Bool,
        authorizedSaveRoots: [TorrentAuthorizedSaveRoot]
    ) throws {
        guard !isShutdown else {
            throw TorrentEngineError.bridgeError("The torrent engine has been shut down.")
        }
        guard !hasPendingRemovalRequest else {
            throw TorrentEngineError.bridgeError("The torrent engine cannot restart while removal is pending.")
        }
        guard let stateDirectory else {
            throw TorrentEngineError.startupFailed(startupFailureMessage ?? "")
        }
        let hasRuntimeFailure = runtimeFailureMessage.withLock { $0 != nil }
        if !hasRuntimeFailure, client != nil {
            try saveAllChecked()
        }
        runtimeFailureMessage.withLock { $0 = nil }
        destroyClient(waitForShutdown: true)
        do {
            client = try Self.createClient(
                stateDirectory: stateDirectory,
                wakeRelay: wakeRelay,
                enablePeerExchangePlugin: enablePeerExchangePlugin,
                authorizedSaveRoots: authorizedSaveRoots
            )
        } catch {
            runtimeFailureMessage.withLock { $0 = error.localizedDescription }
            throw error
        }
    }

    package func replaceAuthorizedSaveRoots(
        _ authorizedSaveRoots: [TorrentAuthorizedSaveRoot]
    ) throws {
        let client = try unsafe requireClient()
        let encoded = try Self.encodeAuthorizedSaveRoots(authorizedSaveRoots)
        try withExtendedLifetime(encoded.retainedRoots) {
            try throwingAuthorizedRootReplacement { errorBuffer in
                let paths: Span<UInt8>? = encoded.pathBlob.isEmpty ? nil : encoded.pathBlob.span
                let roots: Span<TTorrentAuthorizedSaveRoot>? = encoded.nativeRoots.isEmpty
                    ? nil
                    : encoded.nativeRoots.span
                return unsafe TorrentClientReplaceAuthorizedSavePaths(
                    client,
                    paths,
                    roots,
                    torrentAuthorizedSaveRootRetainCallback,
                    torrentAuthorizedSaveRootReleaseCallback,
                    &errorBuffer
                )
            }
        }
    }

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

        while hasPendingRemovalRequest {
            await Self.waitForRemovalPollIntervalIgnoringCancellation()
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

    package func addMagnet(
        _ magnet: String,
        savePath: String,
        startsPaused: Bool = false,
        queuePriority: TorrentQueuePriority = .normal,
        enablePeerExchange: Bool = true,
        allowNonHTTPSTrackers: Bool = false,
        allowNonHTTPSWebSeeds: Bool = false,
        allowPreMetadataDHT: Bool = false
    ) throws -> String {
        let client = try unsafe requireClient()
        var options = TTorrentAddOptions(
            starts_paused: startsPaused.bridgeFlag,
            queue_priority: queuePriority.bridgeByteValue,
            enable_peer_exchange: enablePeerExchange.bridgeFlag,
            allow_non_https_trackers: allowNonHTTPSTrackers.bridgeFlag,
            allow_non_https_web_seeds: allowNonHTTPSWebSeeds.bridgeFlag,
            allow_pre_metadata_dht: allowPreMetadataDHT.bridgeFlag
        )
        return try unsafe throwingBridgeAddReturningString(capacity: Int(TTORRENT_ID_CAPACITY)) { outputBuffer, addOutcome, errorBuffer in
            unsafe magnet.withCString { magnetPointer in
                unsafe savePath.withCString { savePointer in
                    unsafe TorrentClientAddMagnet(
                        client,
                        magnetPointer,
                        savePointer,
                        &options,
                        &outputBuffer,
                        addOutcome,
                        &errorBuffer
                    )
                }
            }
        }
    }

    package func addTorrentFile(
        data: Data,
        savePath: String,
        filePriorities: [Int32: TorrentFilePriority]? = nil,
        startsPaused: Bool = false,
        queuePriority: TorrentQueuePriority = .normal,
        enablePeerExchange: Bool = true,
        allowNonHTTPSTrackers: Bool = false,
        allowNonHTTPSWebSeeds: Bool = false
    ) throws -> String {
        let client = try unsafe requireClient()
        try Self.validateTorrentData(data)
        let priorityEntries = filePriorities?
            .map { index, priority in
                TTorrentFilePriorityEntry(index: index, priority: priority.bridgeValue)
            }
            .sorted { $0.index < $1.index }
        var options = TTorrentAddOptions(
            starts_paused: startsPaused.bridgeFlag,
            queue_priority: queuePriority.bridgeByteValue,
            enable_peer_exchange: enablePeerExchange.bridgeFlag,
            allow_non_https_trackers: allowNonHTTPSTrackers.bridgeFlag,
            allow_non_https_web_seeds: allowNonHTTPSWebSeeds.bridgeFlag,
            allow_pre_metadata_dht: false.bridgeFlag
        )
        if let priorityEntries {
            return try unsafe throwingBridgeAddReturningString(capacity: Int(TTORRENT_ID_CAPACITY)) { outputBuffer, addOutcome, errorBuffer in
                let torrentData: Span<UInt8>? = data.span
                let priorities: Span<TTorrentFilePriorityEntry>? = priorityEntries.span
                return unsafe savePath.withCString { savePointer in
                    unsafe TorrentClientAddTorrentFileDataWithPriorities(
                        client,
                        torrentData,
                        savePointer,
                        &options,
                        priorities,
                        &outputBuffer,
                        addOutcome,
                        &errorBuffer
                    )
                }
            }
        } else {
            return try unsafe throwingBridgeAddReturningString(capacity: Int(TTORRENT_ID_CAPACITY)) { outputBuffer, addOutcome, errorBuffer in
                let torrentData: Span<UInt8>? = data.span
                return unsafe savePath.withCString { savePointer in
                    unsafe TorrentClientAddTorrentFileData(
                        client,
                        torrentData,
                        savePointer,
                        &options,
                        &outputBuffer,
                        addOutcome,
                        &errorBuffer
                    )
                }
            }
        }
    }

    package func previewTorrentFile(data: Data) throws -> TorrentFilePreview {
        let client = try unsafe requireClient()
        try Self.validateTorrentData(data)
        var preview = TTorrentFilePreview()
        var requiredCount: Int32 = 0
        try throwingBridgeCall { errorBuffer in
            let torrentData: Span<UInt8>? = data.span
            var files: MutableSpan<TTorrentFileSnapshot>?
            return unsafe TorrentClientPreviewTorrentFileData(
                client,
                torrentData,
                &preview,
                &files,
                &requiredCount,
                &errorBuffer
            )
        }

        let capacity = max(0, Int(requiredCount))
        guard capacity <= Int(TTORRENT_MAX_FILE_COUNT) else {
            throw TorrentEngineError.bridgeError("The torrent contains too many files. The maximum is \(TTORRENT_MAX_FILE_COUNT).")
        }

        var fileSnapshots = Array(repeating: TTorrentFileSnapshot(), count: capacity)
        if capacity > 0 {
            try throwingBridgeCall { errorBuffer in
                let torrentData: Span<UInt8>? = data.span
                var files: MutableSpan<TTorrentFileSnapshot>? = fileSnapshots.mutableSpan
                return unsafe TorrentClientPreviewTorrentFileData(
                    client,
                    torrentData,
                    &preview,
                    &files,
                    &requiredCount,
                    &errorBuffer
                )
            }
        }

        return TorrentFilePreview(
            name: String(cStringTuple: preview.name),
            id: String(cStringTuple: preview.id),
            totalSize: preview.total_size,
            sourceSecuritySummary: TorrentSourceSecuritySummary(
                trackerCount: Int(preview.tracker_count),
                httpsTrackerCount: Int(preview.https_tracker_count),
                webSeedCount: Int(preview.web_seed_count),
                httpsWebSeedCount: Int(preview.https_web_seed_count)
            ),
            files: fileSnapshots.prefix(capacity).map(TorrentFileItem.init(snapshot:)),
            torrentData: data
        )
    }

    package func pause(id: String) throws {
        let client = try unsafe requireClient()
        try throwingBridgeCall { errorBuffer in
            unsafe id.withCString { unsafe TorrentClientPause(client, $0, &errorBuffer) }
        }
    }

    package func resume(id: String) throws {
        let client = try unsafe requireClient()
        try throwingBridgeCall { errorBuffer in
            unsafe id.withCString { unsafe TorrentClientResume(client, $0, &errorBuffer) }
        }
    }

    package func reannounce(id: String) throws {
        let client = try unsafe requireClient()
        try throwingBridgeCall { errorBuffer in
            unsafe id.withCString { unsafe TorrentClientReannounce(client, $0, &errorBuffer) }
        }
    }

    package func forceRecheck(id: String) throws {
        let client = try unsafe requireClient()
        try throwingBridgeCall { errorBuffer in
            unsafe id.withCString { unsafe TorrentClientForceRecheck(client, $0, &errorBuffer) }
        }
    }

    package func remove(
        id: String,
        deleteFiles: Bool
    ) async throws -> TorrentRemovalOutcome {
        let client = try unsafe requireClient()
        if deleteFiles {
            guard !hasPendingRemovalRequest else {
                throw TorrentEngineError.bridgeError("Another torrent data deletion is already pending.")
            }
            hasPendingRemovalRequest = true
        }
        defer {
            if deleteFiles {
                hasPendingRemovalRequest = false
            }
        }

        var requestToken: UInt64 = 0
        var removalCommitted: UInt8 = 0
        do {
            try throwingBridgeCall { errorBuffer in
                unsafe id.withCString {
                    unsafe TorrentClientRemove(
                        client,
                        $0,
                        deleteFiles.bridgeFlag,
                        false.bridgeFlag,
                        &requestToken,
                        &removalCommitted,
                        &errorBuffer
                    )
                }
            }
        } catch {
            guard removalCommitted != 0 else {
                throw error
            }
            return quiesceAfterUntrackableRemoval(
                detail: error.localizedDescription,
                downloadedFilesMayRemain: deleteFiles
            )
        }

        guard deleteFiles else {
            guard removalCommitted != 0, requestToken == 0 else {
                return quiesceAfterUntrackableRemoval(
                    detail: "The bridge returned inconsistent non-deleting removal state.",
                    downloadedFilesMayRemain: false
                )
            }
            return .removed
        }
        guard removalCommitted != 0, requestToken != 0 else {
            return quiesceAfterUntrackableRemoval(
                detail: "The bridge returned inconsistent deleting removal state."
            )
        }

        while true {
            let result: TorrentRemovalResultStatus
            do {
                result = try unsafe removalResult(client: client, requestToken: requestToken)
            } catch {
                return quiesceAfterUntrackableRemoval(detail: error.localizedDescription)
            }

            switch result.state {
            case Int32(TTORRENT_REMOVAL_PENDING):
                await Self.waitForRemovalPollIntervalIgnoringCancellation()
                guard !isShutdown,
                      unsafe client == self.client?.pointer else {
                    return Self.removedWithBoundedWarning(
                        "The torrent engine was stopped for security containment while data deletion was pending. Some downloaded files may remain on disk."
                    )
                }
            case Int32(TTORRENT_REMOVAL_SUCCEEDED):
                return .removed
            case Int32(TTORRENT_REMOVAL_FAILED):
                let message = result.error
                return Self.removedWithBoundedWarning(
                    message.isEmpty
                        ? "The torrent was removed, but some downloaded files may remain on disk."
                        : message
                )
            default:
                return quiesceAfterUntrackableRemoval(
                    detail: "The bridge returned an unknown deletion state."
                )
            }
        }
    }

    private func removalResult(
        client: OpaquePointer,
        requestToken: UInt64
    ) throws -> TorrentRemovalResultStatus {
        if let removalResultReader,
           let override = try removalResultReader() {
            switch override {
            case .pending:
                return TorrentRemovalResultStatus(
                    state: Int32(TTORRENT_REMOVAL_PENDING),
                    error: ""
                )
            case .unknownState:
                return TorrentRemovalResultStatus(
                    state: .max,
                    error: ""
                )
            }
        }

        var result = TTorrentRemovalResult()
        try throwingBridgeCall { errorBuffer in
            unsafe TorrentClientTakeRemovalResult(
                client,
                requestToken,
                &result,
                &errorBuffer
            )
        }
        return TorrentRemovalResultStatus(
            state: result.state,
            error: String(cStringTuple: result.error)
        )
    }

    private func quiesceAfterUntrackableRemoval(
        detail: String,
        downloadedFilesMayRemain: Bool = true
    ) -> TorrentRemovalOutcome {
        let fileWarning = downloadedFilesMayRemain ? " Some downloaded files may remain on disk." : ""
        let message = "The torrent was removed, but the bridge could not reliably track the operation. "
            + "The torrent engine was stopped safely before folder access was released."
            + fileWarning
            + " \(detail)"
        let boundedMessage = Self.boundedRemovalWarning(message)
        runtimeFailureMessage.withLock { $0 = boundedMessage }
        destroyClient(waitForShutdown: true)
        return .removedWithWarning(boundedMessage)
    }

    private nonisolated static func removedWithBoundedWarning(
        _ message: String
    ) -> TorrentRemovalOutcome {
        .removedWithWarning(boundedRemovalWarning(message))
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

    /// Terminal deletion tracking must remain rate-limited after its caller is canceled.
    /// A detached child gives the sleep a fresh cancellation context; directly sleeping
    /// here would throw immediately and turn the terminal-state loop into a hot poll.
    private nonisolated static func waitForRemovalPollIntervalIgnoringCancellation() async {
        await Task.detached {
            try? await Task.sleep(for: .milliseconds(25))
        }.value
    }

    package func applySettings(
        _ settings: TorrentSettings,
        networkBinding: TorrentNetworkBinding
    ) throws {
        let client = try unsafe requireClient()
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
            bridgeSettings.use_dht_by_default = settings.effectiveUseDHTByDefault.bridgeFlag
            bridgeSettings.enable_lsd = settings.effectiveEnableLocalServiceDiscovery.bridgeFlag
            bridgeSettings.use_lsd_by_default = settings.effectiveUseLocalServiceDiscoveryByDefault.bridgeFlag
            bridgeSettings.use_pex_by_default = settings.effectiveUsePeerExchangeByDefault.bridgeFlag
            bridgeSettings.require_https_trackers = settings.useHTTPSTrackersOnly.bridgeFlag
            bridgeSettings.require_https_web_seeds = settings.useHTTPSWebSeedsOnly.bridgeFlag
            bridgeSettings.encryption_policy = settings.libtorrentEncryptionPolicy
            bridgeSettings.anonymous_mode = settings.effectiveAnonymousMode.bridgeFlag
            bridgeSettings.network_blocked = networkBinding.networkBlocked.bridgeFlag
            return unsafe TorrentClientApplySettings(
                client,
                &bridgeSettings,
                networkInterface,
                &errorBuffer
            )
        }
    }

    package func blockNetworkNow() throws -> TorrentNetworkBlockDisposition {
        let client = try unsafe requireClient()
        try unsafe blockNetwork(client: client)
        return .engineRemainsAvailable
    }

    private func blockNetwork(client: OpaquePointer) throws {
        try throwingBridgeCall { errorBuffer in
            unsafe TorrentClientBlockNetwork(client, &errorBuffer)
        }
    }

    package func saveAll() {
        guard let pointer = unsafe client?.pointer else {
            return
        }

        unsafe TorrentClientSaveAll(pointer)
    }

    package func saveAllChecked() throws {
        let client = try unsafe requireClient()
        try unsafe saveAllChecked(client: client)
    }

    private func saveAllChecked(client: OpaquePointer) throws {
        try throwingBridgeCall { errorBuffer in
            unsafe TorrentClientSaveAllChecked(client, &errorBuffer)
        }
    }

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

    package func takeChanges() -> UInt32 {
        guard let pointer = unsafe client?.pointer else {
            return 0
        }

        var dirtyMask: UInt32 = 0
        _ = unsafe TorrentClientTakeChanges(pointer, &dirtyMask)
        return dirtyMask
    }

    package func networkStatus() -> TorrentNetworkStatus {
        guard let pointer = unsafe client?.pointer else {
            return .empty
        }

        var status = TTorrentNetworkStatus()
        let copied = unsafe TorrentClientCopyNetworkStatus(pointer, &status) != 0
        guard copied else {
            return .empty
        }
        return TorrentNetworkStatus(status: status)
    }

    package func bridgeHealth() -> TorrentBridgeHealth {
        guard let pointer = unsafe client?.pointer else {
            return .unavailable
        }

        var health = TTorrentBridgeHealth()
        let copied = unsafe TorrentClientCopyHealth(pointer, &health) != 0
        guard copied else {
            return .unavailable
        }
        return TorrentBridgeHealth(snapshot: health)
    }

    package func poll(
        since revision: UInt64?,
        sortedBy sortOrder: TorrentSortOrder,
        direction: TorrentSortDirection,
        includeTrackerHosts: Bool
    ) -> TorrentEnginePollResult {
        let health = bridgeHealth()
        let dirtyMask = takeChanges()
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
        let status = networkStatus()
        let trackerHostsChanged = TorrentEngineDirtySet(rawValue: dirtyMask).contains(.trackerHosts)
        let trackerHosts = includeTrackerHosts || trackerHostsChanged
            ? trackerHostBatch()
            : nil
        let snapshots = snapshotsIfChanged(
            since: revision,
            sortedBy: sortOrder,
            direction: direction
        )
        return TorrentEnginePollResult(
            dirtyMask: dirtyMask,
            alertErrors: alertErrors,
            networkStatus: status,
            bridgeHealth: health,
            snapshotBatch: snapshots,
            trackerHostBatch: trackerHosts
        )
    }

    package func snapshots() -> [TorrentItem] {
        snapshotBatch().torrents
    }

    package func snapshotsIfChanged(
        since revision: UInt64?,
        sortedBy sortOrder: TorrentSortOrder,
        direction: TorrentSortDirection
    ) -> TorrentSnapshotBatch? {
        guard let client else {
            if runtimeFailureMessage.withLock({ $0 != nil }) {
                return nil
            }
            return revision == 0 ? nil : TorrentSnapshotBatch(revision: 0, torrents: [])
        }

        guard let batch = snapshotBatch(client: client, ifChangedSince: revision) else {
            return nil
        }

        return TorrentSnapshotBatch(revision: batch.revision, torrents: sortOrder.sorted(batch.torrents, direction: direction))
    }

    package func requestSources(id: String) throws {
        let client = try unsafe requireClient()
        try throwingBridgeCall { errorBuffer in
            unsafe id.withCString {
                unsafe TorrentClientRequestSources(client, $0, &errorBuffer)
            }
        }
    }

    package func sourcePolicy(id: String) throws -> TorrentSourcePolicy {
        let client = try unsafe requireClient()
        var policy = TTorrentSourcePolicy()
        try throwingBridgeCall { errorBuffer in
            unsafe id.withCString {
                unsafe TorrentClientCopySourcePolicy(client, $0, &policy, &errorBuffer)
            }
        }
        return TorrentSourcePolicy(snapshot: policy)
    }

    package func setSourcePolicy(id: String, field: TorrentSourcePolicyField, enabled: Bool) throws {
        let client = try unsafe requireClient()
        try throwingBridgeCall { errorBuffer in
            unsafe id.withCString {
                unsafe TorrentClientSetSourcePolicyField(
                    client,
                    $0,
                    field.bridgeValue,
                    enabled.bridgeFlag,
                    &errorBuffer
                )
            }
        }
    }

    package func torrentOptions(id: String) throws -> TorrentOptions {
        let client = try unsafe requireClient()
        var options = TTorrentOptions()
        try throwingBridgeCall { errorBuffer in
            unsafe id.withCString {
                unsafe TorrentClientCopyTorrentOptions(client, $0, &options, &errorBuffer)
            }
        }
        return TorrentOptions(snapshot: options)
    }

    package func setTorrentOptions(id: String, options: TorrentOptions) throws {
        let client = try unsafe requireClient()
        var bridgeOptions = options.bridgeValue
        try throwingBridgeCall { errorBuffer in
            unsafe id.withCString {
                unsafe TorrentClientSetTorrentOptions(client, $0, &bridgeOptions, &errorBuffer)
            }
        }
    }

    package func moveTorrentInQueue(id: String, move: TorrentQueueMove) throws {
        let client = try unsafe requireClient()
        try throwingBridgeCall { errorBuffer in
            unsafe id.withCString {
                unsafe TorrentClientMoveTorrentInQueue(client, $0, move.bridgeValue, &errorBuffer)
            }
        }
    }

    package func requestFiles(id: String) throws {
        let client = try unsafe requireClient()
        try throwingBridgeCall { errorBuffer in
            unsafe id.withCString {
                unsafe TorrentClientRequestFiles(client, $0, &errorBuffer)
            }
        }
    }

    package func setFilePriority(id: String, fileIndex: Int32, priority: TorrentFilePriority) throws {
        let client = try unsafe requireClient()
        try throwingBridgeCall { errorBuffer in
            unsafe id.withCString {
                unsafe TorrentClientSetFilePriority(client, $0, fileIndex, priority.bridgeValue, &errorBuffer)
            }
        }
    }

    package func requestPieceMap(id: String) throws {
        let client = try unsafe requireClient()
        try throwingBridgeCall { errorBuffer in
            unsafe id.withCString {
                unsafe TorrentClientRequestPieceMap(client, $0, &errorBuffer)
            }
        }
    }

    package func trackerBatch(id: String, since previousRevision: UInt64?) -> TorrentTrackerBatch? {
        guard let client, let pointer = unsafe client.pointer else {
            return nil
        }

        var revision: UInt64 = 0
        var requiredCount: Int32 = 0
        var resident: UInt8 = 0
        var trackerSpan: MutableSpan<TTorrentTrackerSnapshot>?
        _ = unsafe id.withCString { idPointer in
            unsafe TorrentClientCopyTrackerBatch(
                pointer,
                idPointer,
                &trackerSpan,
                &revision,
                &requiredCount,
                &resident
            )
        }
        guard resident != 0 else {
            return nil
        }
        if previousRevision == revision {
            return nil
        }
        guard requiredCount > 0 else {
            return TorrentTrackerBatch(revision: revision, trackers: [])
        }

        var capacity = Self.cappedCapacity(requiredCount: requiredCount, minimum: 4, maximum: TTORRENT_MAX_TRACKER_COUNT)
        var trackers = Array(repeating: TTorrentTrackerSnapshot(), count: capacity)
        var copied = Self.withMutableBridgeSpan(&trackers) { trackerSpan in
            unsafe id.withCString { idPointer in
                unsafe TorrentClientCopyTrackerBatch(
                    pointer,
                    idPointer,
                    &trackerSpan,
                    &revision,
                    &requiredCount,
                    &resident
                )
            }
        }

        while requiredCount > Int32(capacity), capacity < Int(TTORRENT_MAX_TRACKER_COUNT) {
            capacity = Self.grownCapacity(
                current: capacity,
                requiredCount: requiredCount,
                maximum: TTORRENT_MAX_TRACKER_COUNT
            )
            trackers = Array(repeating: TTorrentTrackerSnapshot(), count: capacity)
            copied = Self.withMutableBridgeSpan(&trackers) { trackerSpan in
                unsafe id.withCString { idPointer in
                    unsafe TorrentClientCopyTrackerBatch(
                        pointer,
                        idPointer,
                        &trackerSpan,
                        &revision,
                        &requiredCount,
                        &resident
                    )
                }
            }
        }

        guard resident != 0 else {
            return nil
        }
        guard copied > 0 else {
            return TorrentTrackerBatch(revision: revision, trackers: [])
        }

        return TorrentTrackerBatch(
            revision: revision,
            trackers: trackers.prefix(Int(copied)).map(TorrentTrackerItem.init(snapshot:))
        )
    }

    package func trackerHostBatch() -> TorrentTrackerHostBatch {
        guard let client, let pointer = unsafe client.pointer else {
            return TorrentTrackerHostBatch(revision: 0, hosts: [])
        }

        var revision: UInt64 = 0
        var requiredCount: Int32 = 0
        var hostSpan: MutableSpan<TTorrentTrackerHostSnapshot>?
        _ = unsafe TorrentClientCopyTrackerHostBatch(pointer, &hostSpan, &revision, &requiredCount)

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
                &revision,
                &requiredCount
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
                    &revision,
                    &requiredCount
                )
            }
        }

        guard copied > 0 else {
            return TorrentTrackerHostBatch(revision: revision, hosts: [])
        }

        return TorrentTrackerHostBatch(
            revision: revision,
            hosts: hosts.prefix(Int(copied)).map(TorrentTrackerHostItem.init(snapshot:))
        )
    }

    package func webSeedBatch(id: String, since previousRevision: UInt64?) -> TorrentWebSeedBatch? {
        guard let client, let pointer = unsafe client.pointer else {
            return nil
        }

        var revision: UInt64 = 0
        var requiredCount: Int32 = 0
        var resident: UInt8 = 0
        var webSeedSpan: MutableSpan<TTorrentWebSeedSnapshot>?
        _ = unsafe id.withCString { idPointer in
            unsafe TorrentClientCopyWebSeedBatch(
                pointer,
                idPointer,
                &webSeedSpan,
                &revision,
                &requiredCount,
                &resident
            )
        }
        guard resident != 0 else {
            return nil
        }
        if previousRevision == revision {
            return nil
        }
        guard requiredCount > 0 else {
            return TorrentWebSeedBatch(revision: revision, webSeeds: [])
        }

        var capacity = Self.cappedCapacity(requiredCount: requiredCount, minimum: 4, maximum: TTORRENT_MAX_WEB_SEED_COUNT)
        var webSeeds = Array(repeating: TTorrentWebSeedSnapshot(), count: capacity)
        var copied = Self.withMutableBridgeSpan(&webSeeds) { webSeedSpan in
            unsafe id.withCString { idPointer in
                unsafe TorrentClientCopyWebSeedBatch(
                    pointer,
                    idPointer,
                    &webSeedSpan,
                    &revision,
                    &requiredCount,
                    &resident
                )
            }
        }

        while requiredCount > Int32(capacity), capacity < Int(TTORRENT_MAX_WEB_SEED_COUNT) {
            capacity = Self.grownCapacity(
                current: capacity,
                requiredCount: requiredCount,
                maximum: TTORRENT_MAX_WEB_SEED_COUNT
            )
            webSeeds = Array(repeating: TTorrentWebSeedSnapshot(), count: capacity)
            copied = Self.withMutableBridgeSpan(&webSeeds) { webSeedSpan in
                unsafe id.withCString { idPointer in
                    unsafe TorrentClientCopyWebSeedBatch(
                        pointer,
                        idPointer,
                        &webSeedSpan,
                        &revision,
                        &requiredCount,
                        &resident
                    )
                }
            }
        }

        guard resident != 0 else {
            return nil
        }
        guard copied > 0 else {
            return TorrentWebSeedBatch(revision: revision, webSeeds: [])
        }

        return TorrentWebSeedBatch(
            revision: revision,
            webSeeds: webSeeds.prefix(Int(copied)).map(TorrentWebSeedItem.init(snapshot:))
        )
    }

    package func webSeedActivity(id: String) -> TorrentWebSeedActivity? {
        guard let client, let pointer = unsafe client.pointer else {
            return nil
        }

        var activity = TTorrentWebSeedActivitySnapshot()
        let copied = unsafe id.withCString { idPointer in
            unsafe TorrentClientCopyWebSeedActivity(pointer, idPointer, &activity, nil)
        }
        guard copied != 0 else {
            return nil
        }
        return TorrentWebSeedActivity(snapshot: activity)
    }

    package func peerSources(id: String) -> TorrentPeerSources? {
        guard let client, let pointer = unsafe client.pointer else {
            return nil
        }

        var sources = TTorrentPeerSourceSnapshot()
        let copied = unsafe id.withCString { idPointer in
            unsafe TorrentClientCopyPeerSources(pointer, idPointer, &sources, nil)
        }
        guard copied != 0 else {
            return nil
        }
        return TorrentPeerSources(snapshot: sources)
    }

    package func fileBatch(id: String, since previousRevision: UInt64?) -> TorrentFileBatch? {
        guard let client, let pointer = unsafe client.pointer else {
            return nil
        }

        var revision: UInt64 = 0
        var requiredCount: Int32 = 0
        var resident: UInt8 = 0
        var fileSpan: MutableSpan<TTorrentFileSnapshot>?
        _ = unsafe id.withCString { idPointer in
            unsafe TorrentClientCopyFileBatch(
                pointer,
                idPointer,
                &fileSpan,
                &revision,
                &requiredCount,
                &resident
            )
        }
        guard resident != 0 else {
            return nil
        }
        if previousRevision == revision {
            return nil
        }
        guard requiredCount > 0 else {
            return TorrentFileBatch(revision: revision, files: [])
        }

        var capacity = Self.cappedCapacity(requiredCount: requiredCount, minimum: 8, maximum: TTORRENT_MAX_FILE_COUNT)
        var files = Array(repeating: TTorrentFileSnapshot(), count: capacity)
        var copied = Self.withMutableBridgeSpan(&files) { fileSpan in
            unsafe id.withCString { idPointer in
                unsafe TorrentClientCopyFileBatch(
                    pointer,
                    idPointer,
                    &fileSpan,
                    &revision,
                    &requiredCount,
                    &resident
                )
            }
        }

        while requiredCount > Int32(capacity), capacity < Int(TTORRENT_MAX_FILE_COUNT) {
            capacity = Self.grownCapacity(
                current: capacity,
                requiredCount: requiredCount,
                maximum: TTORRENT_MAX_FILE_COUNT
            )
            files = Array(repeating: TTorrentFileSnapshot(), count: capacity)
            copied = Self.withMutableBridgeSpan(&files) { fileSpan in
                unsafe id.withCString { idPointer in
                    unsafe TorrentClientCopyFileBatch(
                        pointer,
                        idPointer,
                        &fileSpan,
                        &revision,
                        &requiredCount,
                        &resident
                    )
                }
            }
        }

        guard resident != 0 else {
            return nil
        }
        guard copied > 0 else {
            return TorrentFileBatch(revision: revision, files: [])
        }

        return TorrentFileBatch(
            revision: revision,
            files: files.prefix(Int(copied)).map(TorrentFileItem.init(snapshot:))
        )
    }

    package func pieceMapBatch(id: String, since previousRevision: UInt64?) -> TorrentPieceMapBatch? {
        guard let client, let pointer = unsafe client.pointer else {
            return nil
        }

        var revision: UInt64 = 0
        var requiredCount: Int32 = 0
        var resident: UInt8 = 0
        var pieceSpan: MutableSpan<UInt8>?
        _ = unsafe id.withCString { idPointer in
            unsafe TorrentClientCopyPieceMap(
                pointer,
                idPointer,
                nil,
                &pieceSpan,
                &revision,
                &requiredCount,
                &resident
            )
        }
        guard resident != 0 else {
            return nil
        }
        if previousRevision == revision {
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
            unsafe id.withCString { idPointer in
                unsafe TorrentClientCopyPieceMap(
                    pointer,
                    idPointer,
                    &snapshot,
                    &pieceSpan,
                    &revision,
                    &requiredCount,
                    &resident
                )
            }
        }

        while requiredCount > Int32(capacity), capacity < Int(TTORRENT_MAX_PIECE_MAP_COUNT) {
            capacity = Self.grownCapacity(
                current: capacity,
                requiredCount: requiredCount,
                maximum: TTORRENT_MAX_PIECE_MAP_COUNT
            )
            pieces = Array<UInt8>(repeating: 0, count: capacity)
            copied = Self.withMutableBridgeSpan(&pieces) { pieceSpan in
                unsafe id.withCString { idPointer in
                    unsafe TorrentClientCopyPieceMap(
                        pointer,
                        idPointer,
                        &snapshot,
                        &pieceSpan,
                        &revision,
                        &requiredCount,
                        &resident
                    )
                }
            }
        }

        guard resident != 0 else {
            return nil
        }
        let copiedPieces = Array(pieces.prefix(max(0, Int(copied))))
        return TorrentPieceMapBatch(
            revision: revision,
            pieceMap: TorrentPieceMap(snapshot: snapshot, pieces: copiedPieces)
        )
    }

    private func snapshotBatch() -> TorrentSnapshotBatch {
        guard let client else {
            return TorrentSnapshotBatch(revision: 0, torrents: [])
        }

        return snapshotBatch(client: client)
    }

    private func snapshotBatch(client: TorrentClientHandle) -> TorrentSnapshotBatch {
        guard let batch = snapshotBatch(client: client, ifChangedSince: nil) else {
            return TorrentSnapshotBatch(revision: 0, torrents: [])
        }
        return batch
    }

    private func snapshotBatch(client: TorrentClientHandle, ifChangedSince previousRevision: UInt64?) -> TorrentSnapshotBatch? {
        guard let pointer = unsafe client.pointer else {
            return previousRevision == 0 ? nil : TorrentSnapshotBatch(revision: 0, torrents: [])
        }

        var revision: UInt64 = 0
        var requiredCount: Int32 = 0
        var snapshotSpan: MutableSpan<TTorrentSnapshot>?
        _ = unsafe TorrentClientCopySnapshotBatch(pointer, &snapshotSpan, &revision, &requiredCount)
        if let previousRevision, previousRevision == revision {
            return nil
        }

        var capacity = Self.cappedCapacity(
            requiredCount: requiredCount,
            minimum: 16,
            maximum: TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT
        )
        var snapshots = Array(repeating: TTorrentSnapshot(), count: capacity)
        var copied = Self.withMutableBridgeSpan(&snapshots) { snapshotSpan in
            unsafe TorrentClientCopySnapshotBatch(
                pointer,
                &snapshotSpan,
                &revision,
                &requiredCount
            )
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
                    pointer,
                    &snapshotSpan,
                    &revision,
                    &requiredCount
                )
            }
        }

        guard copied > 0 else {
            return TorrentSnapshotBatch(revision: revision, torrents: [])
        }

        return TorrentSnapshotBatch(
            revision: revision,
            torrents: snapshots.prefix(Int(copied)).map(TorrentItem.init(snapshot:))
        )
    }

    private static func createClient(
        stateDirectory: URL,
        wakeRelay: TorrentWakeRelay,
        enablePeerExchangePlugin: Bool,
        authorizedSaveRoots: [TorrentAuthorizedSaveRoot]
    ) throws -> TorrentClientHandle {
        try clientCreationPreflight.withLock { $0 }?(
            stateDirectory,
            enablePeerExchangePlugin,
            authorizedSaveRoots
        )

        let path = stateDirectory.torrentFilePath
        let encoded = try encodeAuthorizedSaveRoots(authorizedSaveRoots)
        var errorBuffer = Array<CChar>(repeating: 0, count: 1024)
        var errorSpan: MutableSpan<CChar>? = errorBuffer.mutableSpan
        let created = unsafe withExtendedLifetime(encoded.retainedRoots) {
            unsafe path.withCString { pointer in
                let paths: Span<UInt8>? = encoded.pathBlob.isEmpty ? nil : encoded.pathBlob.span
                let roots: Span<TTorrentAuthorizedSaveRoot>? = encoded.nativeRoots.isEmpty
                    ? nil
                    : encoded.nativeRoots.span
                return unsafe TorrentClientCreateWithError(
                    pointer,
                    enablePeerExchangePlugin.bridgeFlag,
                    paths,
                    roots,
                    torrentAuthorizedSaveRootRetainCallback,
                    torrentAuthorizedSaveRootReleaseCallback,
                    &errorSpan
                )
            }
        }
        errorSpan = nil
        guard let created = unsafe created else {
            let message = stringFromBridgeBuffer(errorBuffer)
            throw TorrentEngineError.bridgeError(message.isEmpty ? "Unknown startup error." : message)
        }
        return unsafe TorrentClientHandle(created, wakeRelay: wakeRelay)
    }

    private nonisolated static func encodeAuthorizedSaveRoots(
        _ roots: [TorrentAuthorizedSaveRoot]
    ) throws -> TorrentEncodedAuthorizedSaveRoots {
        guard roots.count <= Int(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT) else {
            throw TorrentEngineError.bridgeError("Too many authorized download folders were provided.")
        }

        var uniquePaths = Set<String>(minimumCapacity: roots.count)
        var uniqueIdentities = Set<TorrentAuthorizedSaveRootIdentity>(minimumCapacity: roots.count)
        for root in roots {
            let path = root.canonicalPath
            let bytes = path.utf8
            guard !bytes.isEmpty,
                  bytes.count <= Int(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BYTES),
                  !bytes.contains(0),
                  (path as NSString).isAbsolutePath,
                  uniquePaths.insert(path).inserted,
                  uniqueIdentities.insert(TorrentAuthorizedSaveRootIdentity(
                      device: root.device,
                      inode: root.inode
                  )).inserted else {
                throw TorrentEngineError.bridgeError("An authorized download folder path is invalid.")
            }
        }

        let sortedRoots = roots.sorted { $0.canonicalPath < $1.canonicalPath }
        var blob = [UInt8]()
        var nativeRoots = [TTorrentAuthorizedSaveRoot]()
        nativeRoots.reserveCapacity(sortedRoots.count)
        for root in sortedRoots {
            let bytes = Array(root.canonicalPath.utf8)
            guard blob.count <= Int(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BLOB_BYTES) - bytes.count - 1 else {
                throw TorrentEngineError.bridgeError("The authorized download folder list is too large.")
            }
            blob.append(contentsOf: bytes)
            blob.append(0)
            nativeRoots.append(root.nativeRecord())
        }
        return TorrentEncodedAuthorizedSaveRoots(
            pathBlob: blob,
            nativeRoots: nativeRoots,
            retainedRoots: sortedRoots
        )
    }

    private func requireClient() throws -> OpaquePointer {
        if let startupFailureMessage {
            throw TorrentEngineError.startupFailed(startupFailureMessage)
        }
        if let runtimeFailureMessage = runtimeFailureMessage.withLock({ $0 }) {
            throw TorrentEngineError.bridgeError(runtimeFailureMessage)
        }
        guard let pointer = unsafe client?.pointer else {
            throw TorrentEngineError.failedToCreateClient
        }
        return unsafe pointer
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

    private func throwingAuthorizedRootReplacement(
        _ body: (inout MutableSpan<CChar>?) -> Int32
    ) throws {
        var errorBuffer = Array<CChar>(repeating: 0, count: 1_024)
        var errorSpan: MutableSpan<CChar>? = errorBuffer.mutableSpan
        let result = body(&errorSpan)
        errorSpan = nil
        guard result != 0 else {
            return
        }
        let message = stringFromBridgeBuffer(errorBuffer)
        if result == Int32(TTORRENT_ERROR_AUTHORIZED_SAVE_ROOT_CAPACITY) {
            throw TorrentEngineError.authorizedRootCapacityReached(message)
        }
        throw TorrentEngineError.bridgeError(message)
    }

    private func throwingBridgeAddReturningString(
        capacity: Int,
        _ body: (
            inout MutableSpan<CChar>?,
            UnsafeMutablePointer<Int32>,
            inout MutableSpan<CChar>?
        ) -> Int32
    ) throws -> String {
        var outputBuffer = Array<CChar>(repeating: 0, count: capacity)
        var errorBuffer = Array<CChar>(repeating: 0, count: 1_024)
        var addOutcome = Int32(TTORRENT_ADD_REJECTED)
        var outputSpan: MutableSpan<CChar>? = outputBuffer.mutableSpan
        var errorSpan: MutableSpan<CChar>? = errorBuffer.mutableSpan
        let result = unsafe body(&outputSpan, &addOutcome, &errorSpan)
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
        guard !value.isEmpty else {
            throw TorrentAddError.commitStatusUnknown(
                "Torrent was added, but its identity was not returned."
            )
        }
        return value
    }

    private static func validateTorrentData(_ data: Data) throws {
        guard !data.isEmpty else {
            throw TorrentEngineError.bridgeError("The torrent file is empty.")
        }
        guard data.count <= TorrentInputLimits.maxTorrentFileBytes else {
            throw TorrentEngineError.bridgeError("The torrent file is too large.")
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
        unsafe rawPointer
    }

    init(_ pointer: OpaquePointer, wakeRelay: TorrentWakeRelay) {
        unsafe rawPointer = pointer
        self.wakeRelay = wakeRelay
        unsafe TorrentClientSetWakeCallback(
            pointer,
            torrentWakeCallback,
            Unmanaged.passUnretained(wakeRelay).toOpaque()
        )
    }

    func destroyBlocking() {
        guard let pointer = unsafe rawPointer else {
            return
        }

        unsafe rawPointer = nil
        unsafe TorrentClientDestroyBlocking(pointer)
    }

    deinit {
        if let rawPointer = unsafe rawPointer {
            unsafe TorrentClientDestroy(rawPointer)
        }
    }
}
