import Darwin
import Foundation
import Synchronization
import TorrentEngineIPC
import TorrentEngineModel

package enum TorrentEngineConnectionRetryMode: Equatable, Sendable {
    case initial
    case replacingTerminatedController
}

package struct TorrentEngineConnectionRetryPolicy: Sendable {
    private static let connectionFailureDelays: [Duration] = [
        .milliseconds(50),
        .milliseconds(100),
        .milliseconds(200)
    ]
    private static let cleanupEpisodeDelays: [Duration] = [
        .milliseconds(250),
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
        .seconds(4),
        .seconds(5)
    ]
    // The service cleanup watchdog expires at 300 seconds. Recovery owns one
    // absolute wall-clock deadline with five seconds of relaunch headroom;
    // this value is no longer accumulated from sleeps.
    package static let cleanupEpisodeRetryBudget: Duration = .seconds(305)

    private var connectionFailureAttempt = 0
    private var cleanupEpisodeAttempt = 0
    private var isCleanupEpisode = false

    package init(mode: TorrentEngineConnectionRetryMode = .initial) {
        isCleanupEpisode = mode == .replacingTerminatedController
    }

    package mutating func delay(after error: TorrentEngineClientError) -> Duration? {
        switch error {
        case .serviceTemporarilyUnavailable:
            isCleanupEpisode = true
            return nextCleanupEpisodeDelay()
        case .requestTimedOut:
            // A timed-out bootstrap request has already terminalized its
            // controller. Retry only on a fresh controller, through the same
            // absolute cleanup horizon as an explicitly busy helper.
            isCleanupEpisode = true
            return nextCleanupEpisodeDelay()
        case .connectionFailed, .connectionCancelled:
            if isCleanupEpisode {
                return nextCleanupEpisodeDelay()
            }
            guard connectionFailureAttempt < Self.connectionFailureDelays.count else {
                return nil
            }
            defer {
                connectionFailureAttempt += 1
            }
            return Self.connectionFailureDelays[connectionFailureAttempt]
        default:
            return nil
        }
    }

    package static func retryWake(
        now: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant?,
        after delay: Duration
    ) -> ContinuousClock.Instant? {
        guard let deadline else {
            return now.advanced(by: delay)
        }
        guard now < deadline else {
            return nil
        }
        return min(now.advanced(by: delay), deadline)
    }

    private mutating func nextCleanupEpisodeDelay() -> Duration? {
        let delayIndex = min(
            cleanupEpisodeAttempt,
            Self.cleanupEpisodeDelays.index(before: Self.cleanupEpisodeDelays.endIndex)
        )
        cleanupEpisodeAttempt += 1
        return Self.cleanupEpisodeDelays[delayIndex]
    }
}

@safe final class TorrentXPCClientState: Sendable {
    private struct Values: Sendable {
        var available = true
        var failure: String?
        var recoveryDisposition = TorrentEngineRecoveryDisposition.none
        var libtorrentVersion = "Unknown"
        var continuation: AsyncStream<Void>.Continuation?
    }

    private let values: Mutex<Values>
    let wakeEvents: AsyncStream<Void>

    init() {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeEvents = stream.stream
        values = Mutex(Values(continuation: stream.continuation))
    }

    var isAvailable: Bool {
        values.withLock(\.available)
    }

    var failure: String? {
        values.withLock(\.failure)
    }

    var recoveryDisposition: TorrentEngineRecoveryDisposition {
        values.withLock(\.recoveryDisposition)
    }

    var libtorrentVersion: String {
        values.withLock(\.libtorrentVersion)
    }

    func setLibtorrentVersion(_ version: String) {
        values.withLock { $0.libtorrentVersion = version }
    }

    func signal() {
        let continuation = values.withLock(\.continuation)
        continuation?.yield()
    }

    func cancel(
        message: String,
        recoveryDisposition: TorrentEngineRecoveryDisposition
    ) {
        let continuation: AsyncStream<Void>.Continuation? = values.withLock { values in
            guard values.available else {
                // A transport callback can race a typed protocol failure back
                // to the actor. Never let a generic, replaceable cancellation
                // mask the stricter trust-boundary outcome.
                if recoveryDisposition == .terminal,
                   values.recoveryDisposition != .terminal {
                    values.failure = message
                    values.recoveryDisposition = .terminal
                }
                return nil
            }
            values.available = false
            values.failure = message
            values.recoveryDisposition = recoveryDisposition
            let continuation = values.continuation
            values.continuation = nil
            return continuation
        }
        continuation?.finish()
    }

    deinit {
        cancel(
            message: "The isolated torrent engine connection ended safely.",
            recoveryDisposition: .terminal
        )
    }
}

@safe package final class TorrentLegacyResumeDirectory: @unchecked Sendable {
    package let filenames: [String]
    private let directoryFileDescriptor: Int32

    private init(directoryFileDescriptor: Int32, filenames: [String]) {
        self.directoryFileDescriptor = directoryFileDescriptor
        self.filenames = filenames
    }

    deinit {
        Darwin.close(directoryFileDescriptor)
    }

    package static func open(stateDirectory: URL) throws -> TorrentLegacyResumeDirectory? {
        guard stateDirectory.isFileURL else {
            throw TorrentEngineClientError.migrationFailed
        }
        var statePathMetadata = stat()
        let statePathStatus = unsafe stateDirectory.path(percentEncoded: false).withCString {
            unsafe Darwin.lstat($0, &statePathMetadata)
        }
        if statePathStatus != 0 {
            guard errno == ENOENT else {
                throw TorrentEngineClientError.migrationFailed
            }
            return nil
        }
        guard (statePathMetadata.st_mode & S_IFMT) == S_IFDIR,
              statePathMetadata.st_uid == geteuid(),
              (statePathMetadata.st_mode & 0o022) == 0 else {
            throw TorrentEngineClientError.migrationFailed
        }

        let stateDescriptor = unsafe stateDirectory.path(percentEncoded: false).withCString {
            unsafe Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard stateDescriptor >= 0 else {
            throw TorrentEngineClientError.migrationFailed
        }
        defer {
            Darwin.close(stateDescriptor)
        }

        var stateDescriptorMetadata = stat()
        guard unsafe Darwin.fstat(stateDescriptor, &stateDescriptorMetadata) == 0,
              stateDescriptorMetadata.st_dev == statePathMetadata.st_dev,
              stateDescriptorMetadata.st_ino == statePathMetadata.st_ino else {
            throw TorrentEngineClientError.migrationFailed
        }

        var resumePathMetadata = stat()
        let resumePathStatus = unsafe "ResumeData".withCString {
            unsafe Darwin.fstatat(
                stateDescriptor,
                $0,
                &resumePathMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if resumePathStatus != 0 {
            guard errno == ENOENT else {
                throw TorrentEngineClientError.migrationFailed
            }
            return nil
        }
        guard (resumePathMetadata.st_mode & S_IFMT) == S_IFDIR,
              resumePathMetadata.st_uid == geteuid(),
              (resumePathMetadata.st_mode & 0o022) == 0 else {
            throw TorrentEngineClientError.migrationFailed
        }

        let descriptor = unsafe "ResumeData".withCString {
            unsafe Darwin.openat(
                stateDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw TorrentEngineClientError.migrationFailed
        }
        var descriptorIsOwned = true
        defer {
            if descriptorIsOwned {
                Darwin.close(descriptor)
            }
        }

        var descriptorMetadata = stat()
        guard unsafe Darwin.fstat(descriptor, &descriptorMetadata) == 0,
              descriptorMetadata.st_dev == resumePathMetadata.st_dev,
              descriptorMetadata.st_ino == resumePathMetadata.st_ino else {
            throw TorrentEngineClientError.migrationFailed
        }

        let enumerationDescriptor = Darwin.dup(descriptor)
        guard enumerationDescriptor >= 0,
              let directory = unsafe Darwin.fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 {
                Darwin.close(enumerationDescriptor)
            }
            throw TorrentEngineClientError.migrationFailed
        }
        defer {
            unsafe Darwin.closedir(directory)
        }

        var filenames = [String]()
        while true {
            errno = 0
            guard let entry = unsafe Darwin.readdir(directory) else {
                guard errno == 0 else {
                    throw TorrentEngineClientError.migrationFailed
                }
                break
            }
            let filename = unsafe withUnsafePointer(to: entry.pointee.d_name) { pointer in
                unsafe pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    unsafe String(cString: $0)
                }
            }
            guard filename != ".", filename != ".." else {
                continue
            }
            guard isAllowlisted(filename: filename) else {
                continue
            }
            guard filenames.count < TorrentEngineIPCLimits.maximumStateMigrationFileCount else {
                throw TorrentEngineClientError.migrationFailed
            }
            filenames.append(filename)
        }
        filenames.sort()
        guard Set(filenames).count == filenames.count else {
            throw TorrentEngineClientError.migrationFailed
        }

        descriptorIsOwned = false
        return TorrentLegacyResumeDirectory(
            directoryFileDescriptor: descriptor,
            filenames: filenames
        )
    }

    package func openFile(named filename: String) throws -> Int32 {
        guard Self.isAllowlisted(filename: filename) else {
            throw TorrentEngineClientError.migrationFailed
        }
        let descriptor = unsafe filename.withCString {
            unsafe Darwin.openat(
                directoryFileDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw TorrentEngineClientError.migrationFailed
        }
        var metadata = stat()
        guard unsafe Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink > 0,
              metadata.st_size > 0 else {
            Darwin.close(descriptor)
            throw TorrentEngineClientError.migrationFailed
        }
        return descriptor
    }

    private static func isAllowlisted(filename: String) -> Bool {
        guard !filename.isEmpty,
              filename.utf8.count <= 96,
              !filename.contains("/"),
              !filename.contains("\0") else {
            return false
        }
        if filename.hasPrefix("removal-"), filename.hasSuffix(".fastresume.remove") {
            let value = filename
                .dropFirst("removal-".count)
                .dropLast(".fastresume.remove".count)
            return isLowercaseHex(value, count: 32)
        }
        guard filename.hasSuffix(".fastresume") else {
            return false
        }
        let identifier = filename.dropLast(".fastresume".count)
        if identifier.hasPrefix("t:") {
            return isLowercaseHex(identifier.dropFirst(2), count: 32)
        }
        if identifier.hasPrefix("v1:") {
            return isLowercaseHex(identifier.dropFirst(3), count: 40)
        }
        if identifier.hasPrefix("v2:") {
            return isLowercaseHex(identifier.dropFirst(3), count: 64)
        }
        return false
    }

    private static func isLowercaseHex<S: StringProtocol>(_ value: S, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!)
                || ($0 >= Character("a").asciiValue! && $0 <= Character("f").asciiValue!)
        }
    }
}

@safe package actor TorrentXPCClient: TorrentEngineServicing {
    private static let maximumQueuedRequestCount = 128

    private enum CapabilityState: Equatable, Sendable {
        case committed
        case provisional
    }

    private struct CapabilityRecord: Equatable, Sendable {
        let id: UUID
        var state: CapabilityState
    }

    private let controllerID: UUID
    private let transport: any TorrentEngineIPCTransport
    private let state: TorrentXPCClientState
    private let requestTimeoutOverrides: [TorrentEngineIPCOperation: Duration]
    private var connectionDeadline: ContinuousClock.Instant?
    private var engineEpoch: UUID?
    private var nextSequence: UInt64 = 1
    private var capabilitiesByCanonicalPath = [String: CapabilityRecord]()
    private var latestNetworkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot?
    private var requestIsInFlight = false
    private struct RequestWaiter {
        let id: UUID
        let deadlineTask: Task<Void, Never>
        let continuation: CheckedContinuation<RequestSlotAcquisition, Never>
    }
    private var requestWaiters = [RequestWaiter]()
    private struct PollPipelineWaiter {
        let id: UUID
        let continuation: CheckedContinuation<PollPipelineSlotAcquisition, Never>
    }
    private var pollPipelineIsInFlight = false
    private var pollPipelineWaiters = [PollPipelineWaiter]()

    package var pendingPollPipelineAcquisitionCount: Int {
        pollPipelineWaiters.count
    }

    package nonisolated var startupFailureMessage: String? {
        state.failure
    }

    package nonisolated var libtorrentVersion: String {
        state.libtorrentVersion
    }

    package nonisolated var isAvailable: Bool {
        state.isAvailable
    }

    package nonisolated var recoveryDisposition: TorrentEngineRecoveryDisposition {
        state.recoveryDisposition
    }

    private init(
        controllerID: UUID,
        transport: any TorrentEngineIPCTransport,
        state: TorrentXPCClientState,
        requestTimeoutOverrides: [TorrentEngineIPCOperation: Duration],
        connectionDeadline: ContinuousClock.Instant?
    ) {
        self.controllerID = controllerID
        self.transport = transport
        self.state = state
        self.requestTimeoutOverrides = requestTimeoutOverrides
        self.connectionDeadline = connectionDeadline
    }

    package static func connect(
        enablePeerExchangePlugin: Bool,
        folderAuthorizations: [TorrentFolderAuthorization],
        legacyStateDirectory: URL? = nil,
        retryMode: TorrentEngineConnectionRetryMode = .initial
    ) async throws -> TorrentXPCClient {
        let configuration = try TorrentEngineXPCIdentity.configuration()
        var retryPolicy = TorrentEngineConnectionRetryPolicy(mode: retryMode)
        let clock = ContinuousClock()
        // One connect call owns one wall-clock horizon. This includes the
        // first transport attempt, migration/bootstrap requests, processing,
        // and every retry sleep; a late first busy reply cannot restart it.
        let recoveryDeadline = clock.now.advanced(
            by: TorrentEngineConnectionRetryPolicy.cleanupEpisodeRetryBudget
        )
        while true {
            if clock.now >= recoveryDeadline {
                throw TorrentEngineClientError.recoveryDeadlineExceeded
            }
            do {
                let controllerID = UUID()
                let state = TorrentXPCClientState()
                let session = try await TorrentEngineExtensionProcessCoordinator.shared
                    .makeSession(configuration: configuration)
                let transport = try TorrentEngineXPCTransport(
                    controllerID: controllerID,
                    session: session,
                    configuration: configuration,
                    hintHandler: { state.signal() },
                    cancellationHandler: {
                        state.cancel(
                            message: "The isolated torrent engine connection ended safely.",
                            recoveryDisposition: .replaceController
                        )
                    }
                )
                return try await establishConnection(
                    controllerID: controllerID,
                    transport: transport,
                    state: state,
                    enablePeerExchangePlugin: enablePeerExchangePlugin,
                    folderAuthorizations: folderAuthorizations,
                    legacyStateDirectory: legacyStateDirectory,
                    requestTimeoutOverrides: [:],
                    connectionDeadline: recoveryDeadline
                )
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else {
                    throw CancellationError()
                }
                let failure = error as? TorrentEngineClientError ?? .connectionFailed
                if clock.now >= recoveryDeadline {
                    throw TorrentEngineClientError.recoveryDeadlineExceeded
                }
                guard let delay = retryPolicy.delay(after: failure) else {
                    throw failure
                }
                guard let wake = TorrentEngineConnectionRetryPolicy.retryWake(
                    now: clock.now,
                    deadline: recoveryDeadline,
                    after: delay
                ) else {
                    throw TorrentEngineClientError.recoveryDeadlineExceeded
                }
                try await clock.sleep(until: wake)
            }
        }
    }

    /// Establishes a client over an alternate authenticated transport.
    ///
    /// This keeps transport behavior independently testable without weakening
    /// the production XPC peer requirements used by the primary overload.
    package static func connect(
        enablePeerExchangePlugin: Bool,
        folderAuthorizations: [TorrentFolderAuthorization],
        legacyStateDirectory: URL? = nil,
        transport: any TorrentEngineIPCTransport,
        controllerID: UUID = UUID(),
        requestTimeoutOverrides: [TorrentEngineIPCOperation: Duration] = [:],
        connectionDeadline: ContinuousClock.Instant? = nil
    ) async throws -> TorrentXPCClient {
        try await establishConnection(
            controllerID: controllerID,
            transport: transport,
            state: TorrentXPCClientState(),
            enablePeerExchangePlugin: enablePeerExchangePlugin,
            folderAuthorizations: folderAuthorizations,
            legacyStateDirectory: legacyStateDirectory,
            requestTimeoutOverrides: requestTimeoutOverrides,
            connectionDeadline: connectionDeadline
        )
    }

    private static func establishConnection(
        controllerID: UUID,
        transport: any TorrentEngineIPCTransport,
        state: TorrentXPCClientState,
        enablePeerExchangePlugin: Bool,
        folderAuthorizations: [TorrentFolderAuthorization],
        legacyStateDirectory: URL?,
        requestTimeoutOverrides: [TorrentEngineIPCOperation: Duration],
        connectionDeadline: ContinuousClock.Instant?
    ) async throws -> TorrentXPCClient {
        let client = TorrentXPCClient(
            controllerID: controllerID,
            transport: transport,
            state: state,
            requestTimeoutOverrides: requestTimeoutOverrides,
            connectionDeadline: connectionDeadline
        )
        do {
            if let legacyStateDirectory {
                try await client.migrateLegacyStateIfNeeded(from: legacyStateDirectory)
            }
            try await client.bootstrap(
                enablePeerExchangePlugin: enablePeerExchangePlugin,
                folderAuthorizations: folderAuthorizations
            )
            try await client.finishConnectionEstablishment()
            return client
        } catch {
            let failure = error as? TorrentEngineClientError ?? .connectionFailed
            state.cancel(
                message: failure.localizedDescription,
                recoveryDisposition: failure.recoveryDisposition
            )
            transport.cancel()
            throw error
        }
    }

    private func finishConnectionEstablishment() throws {
        if let connectionDeadline,
           ContinuousClock().now >= connectionDeadline {
            throw TorrentEngineClientError.recoveryDeadlineExceeded
        }
        connectionDeadline = nil
    }

    package func shutdown() async {
        if state.isAvailable {
            try? await invokeUnit(.shutdown, TorrentEngineIPCEmpty())
        }
        capabilitiesByCanonicalPath.removeAll(keepingCapacity: false)
        engineEpoch = nil
        terminalize(
            message: "The isolated torrent engine connection ended safely.",
            recoveryDisposition: .terminal
        )
    }

    package func terminateConnection(
        recoveryDisposition: TorrentEngineRecoveryDisposition
    ) async {
        capabilitiesByCanonicalPath.removeAll(keepingCapacity: false)
        engineEpoch = nil
        terminalize(
            message: TorrentEngineClientError.connectionCancelled.localizedDescription,
            recoveryDisposition: recoveryDisposition
        )
    }

    package func restart(
        enablePeerExchangePlugin: Bool,
        authorizedSavePaths: [String]
    ) async throws {
        var granted = [(path: String, record: CapabilityRecord)]()
        granted.reserveCapacity(authorizedSavePaths.count)
        for path in try Self.canonicalPaths(authorizedSavePaths) {
            guard let record = capabilitiesByCanonicalPath[path] else {
                throw TorrentEngineClientError.capabilityUnavailable
            }
            granted.append((path, record))
        }

        do {
            try await invokeUnit(
                .restart,
                TorrentEngineIPCRestartRequest(
                    enablePeerExchangePlugin: enablePeerExchangePlugin,
                    capabilityIDs: granted.map(\.record.id)
                )
            )
            capabilitiesByCanonicalPath = Dictionary(
                uniqueKeysWithValues: granted.map {
                    ($0.path, CapabilityRecord(id: $0.record.id, state: .committed))
                }
            )
        } catch {
            if Self.isDefiniteUnsubmittedOrRejectedFailure(error) {
                for grant in granted where grant.record.state == .provisional {
                    await revokeForMandatoryCleanup(capabilityID: grant.record.id)
                }
            }
            throw error
        }
    }

    package func delegateFolderAuthorization(
        _ authorization: TorrentFolderAuthorization
    ) async throws {
        let canonicalPath = try Self.canonicalPath(authorization.path)
        guard !authorization.bookmarkData.isEmpty,
              authorization.bookmarkData.count <= TorrentEngineIPCLimits.maximumBookmarkBytes else {
            throw TorrentEngineClientError.invalidBookmark
        }
        if capabilitiesByCanonicalPath[canonicalPath] != nil {
            return
        }
        let granted = try await grantProvisionalFolder(
            path: canonicalPath,
            bookmarkData: authorization.bookmarkData
        )
        capabilitiesByCanonicalPath[canonicalPath] = CapabilityRecord(
            id: granted.capabilityID,
            state: .provisional
        )
    }

    package func reconcileFolderAuthorizations(
        _ authorizations: [TorrentFolderAuthorization]
    ) async throws {
        let normalized: [TorrentFolderAuthorization]
        let response: TorrentEngineIPCReplaceFoldersResponse
        do {
            normalized = try Self.canonicalAuthorizations(authorizations)
            response = try await invoke(
                .replaceFolderCapabilities,
                TorrentEngineIPCReplaceFoldersRequest(
                    folders: normalized.map {
                        TorrentEngineIPCFolderGrant(bookmark: $0.bookmarkData)
                    }
                )
            )
        } catch {
            // Exact replacement is the revocation boundary. If it cannot be
            // confirmed, retaining the previous capability set would leave
            // authority that the GUI has already removed. Tear down the
            // controller so service disconnect cleanup revokes everything.
            let failure = responseFailure(from: error)
            terminalize(failure)
            throw failure
        }

        let expectedPaths = Set(normalized.map(\.path))
        guard response.folders.count == expectedPaths.count,
              Set(response.folders.map(\.resolvedPath)) == expectedPaths else {
            let error = TorrentEngineClientError.invalidReply
            terminalize(error)
            throw error
        }

        var replacements = [String: CapabilityRecord]()
        replacements.reserveCapacity(response.folders.count)
        for folder in response.folders {
            guard replacements.updateValue(
                CapabilityRecord(id: folder.capabilityID, state: .committed),
                forKey: folder.resolvedPath
            ) == nil else {
                let error = TorrentEngineClientError.invalidReply
                terminalize(error)
                throw error
            }
        }
        capabilitiesByCanonicalPath = replacements
    }

    package func wakeEvents() -> AsyncStream<Void> {
        state.wakeEvents
    }

    package func addMagnet(
        _ magnet: String,
        savePath: String,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        enablePeerExchange: Bool,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool,
        allowPreMetadataDHT: Bool
    ) async throws -> String {
        let folder = try await folderCapability(for: savePath)
        do {
            let response: TorrentEngineIPCAddedTorrentResponse = try await invoke(
                .addMagnet,
                TorrentEngineIPCAddMagnetRequest(
                    magnet: magnet,
                    folderCapabilityID: folder.capabilityID,
                    startsPaused: startsPaused,
                    queuePriority: queuePriority,
                    enablePeerExchange: enablePeerExchange,
                    allowNonHTTPSTrackers: allowNonHTTPSTrackers,
                    allowNonHTTPSWebSeeds: allowNonHTTPSWebSeeds,
                    allowPreMetadataDHT: allowPreMetadataDHT
                )
            )
            capabilitiesByCanonicalPath[folder.path] = CapabilityRecord(
                id: folder.capabilityID,
                state: .committed
            )
            return response.identifier
        } catch {
            if folder.wasProvisional, Self.isDefiniteUnsubmittedOrRejectedFailure(error) {
                await revokeForMandatoryCleanup(capabilityID: folder.capabilityID)
            }
            throw error
        }
    }

    package func addTorrentFile(
        data: Data,
        savePath: String,
        filePriorities: [Int32: TorrentFilePriority]?,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        enablePeerExchange: Bool,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool
    ) async throws -> String {
        let folder = try await folderCapability(for: savePath)
        let priorityEntries = filePriorities?.map {
            TorrentEngineIPCFilePriorityEntry(index: $0.key, priority: $0.value)
        }.sorted { $0.index < $1.index }
        do {
            let response: TorrentEngineIPCAddedTorrentResponse = try await invoke(
                .addTorrentFile,
                TorrentEngineIPCAddTorrentFileRequest(
                    torrentData: data,
                    folderCapabilityID: folder.capabilityID,
                    filePriorities: priorityEntries,
                    startsPaused: startsPaused,
                    queuePriority: queuePriority,
                    enablePeerExchange: enablePeerExchange,
                    allowNonHTTPSTrackers: allowNonHTTPSTrackers,
                    allowNonHTTPSWebSeeds: allowNonHTTPSWebSeeds
                )
            )
            capabilitiesByCanonicalPath[folder.path] = CapabilityRecord(
                id: folder.capabilityID,
                state: .committed
            )
            return response.identifier
        } catch {
            if folder.wasProvisional, Self.isDefiniteUnsubmittedOrRejectedFailure(error) {
                await revokeForMandatoryCleanup(capabilityID: folder.capabilityID)
            }
            throw error
        }
    }

    package func previewTorrentFile(data: Data) async throws -> TorrentFilePreview {
        guard !data.isEmpty else {
            throw TorrentEngineClientError.serviceRejected("The torrent file is empty.")
        }
        let response: TorrentEngineIPCFilePreviewResponse = try await invokeRaw(
            .previewTorrentFile,
            payload: data
        )
        return TorrentFilePreview(
            name: response.name,
            id: response.id,
            totalSize: response.totalSize,
            sourceSecuritySummary: response.sourceSecuritySummary,
            files: response.files,
            torrentData: data
        )
    }

    package func pause(id: String) async throws {
        try await invokeUnit(.pause, TorrentEngineIPCTorrentIDRequest(id: id))
    }

    package func resume(id: String) async throws {
        try await invokeUnit(.resume, TorrentEngineIPCTorrentIDRequest(id: id))
    }

    package func reannounce(id: String) async throws {
        try await invokeUnit(.reannounce, TorrentEngineIPCTorrentIDRequest(id: id))
    }

    package func forceRecheck(id: String) async throws {
        try await invokeUnit(.forceRecheck, TorrentEngineIPCTorrentIDRequest(id: id))
    }

    package func remove(id: String, deleteFiles: Bool) async throws -> TorrentRemovalOutcome {
        let response: TorrentEngineIPCRemovalResponse = try await invoke(
            .remove,
            TorrentEngineIPCRemoveRequest(id: id, deleteFiles: deleteFiles)
        )
        return response.outcome
    }

    package func applySettings(
        _ settings: TorrentSettings,
        networkBinding: TorrentNetworkBinding
    ) async throws {
        try await invokeUnit(
            .applySettings,
            TorrentEngineIPCApplySettingsRequest(settings: settings, networkBinding: networkBinding)
        )
    }

    package func blockNetworkNow() async throws -> TorrentNetworkBlockDisposition {
        guard !requestIsInFlight else {
            // Network revocation must preempt long-running ordered operations
            // such as terminal file deletion. Cancelling the authenticated
            // controller invokes the helper's out-of-band disconnect path,
            // which blocks (or force-contains) the native engine immediately.
            terminalize(.connectionCancelled)
            return .engineReplacementRequired
        }
        do {
            try await invokeUnit(.blockNetwork, TorrentEngineIPCEmpty())
            return .engineRemainsAvailable
        } catch {
            // A block that cannot be confirmed is itself a fail-closed
            // boundary. Closing the controller enters the same independently
            // watched service-disconnect containment path as urgent preemption.
            terminalize(responseFailure(from: error))
            return .engineReplacementRequired
        }
    }

    package func saveAll() async throws {
        try await invokeUnit(.saveAll, TorrentEngineIPCEmpty())
    }

    package func poll(
        since revision: UInt64?,
        sortedBy sortOrder: TorrentSortOrder,
        direction: TorrentSortDirection,
        includeTrackerHosts: Bool
    ) async throws -> TorrentEnginePollResult {
        do {
            try await acquirePollPipelineSlot()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw pollFailure(from: error)
        }
        defer {
            releasePollPipelineSlot()
        }

        var ownedDatasetIDs = [UUID]()
        do {
            let response = try await pollWire(
                since: revision,
                sortedBy: sortOrder,
                direction: direction,
                includeTrackerHosts: includeTrackerHosts
            )
            ownedDatasetIDs = [
                response.snapshotDataset?.id,
                response.trackerHostDataset?.id,
            ].compactMap { $0 }
            var snapshotBatch: TorrentSnapshotBatch?
            var trackerHostBatch: TorrentTrackerHostBatch?
            if let descriptor = response.snapshotDataset {
                let torrents: [TorrentItem] = try await loadDatasetContents(descriptor)
                try await closeDataset(descriptor.id)
                ownedDatasetIDs.removeAll { $0 == descriptor.id }
                snapshotBatch = TorrentSnapshotBatch(
                    revision: descriptor.revision,
                    torrents: torrents
                )
            }
            if let descriptor = response.trackerHostDataset {
                let hosts: [TorrentTrackerHostItem] = try await loadDatasetContents(descriptor)
                try await closeDataset(descriptor.id)
                ownedDatasetIDs.removeAll { $0 == descriptor.id }
                trackerHostBatch = TorrentTrackerHostBatch(
                    revision: descriptor.revision,
                    hosts: hosts
                )
            }
            return TorrentEnginePollResult(
                dirtyMask: response.dirtyMask,
                alertErrors: response.alertErrors,
                networkStatus: response.networkStatus,
                bridgeHealth: response.bridgeHealth,
                snapshotBatch: snapshotBatch,
                trackerHostBatch: trackerHostBatch,
                networkInterfaceSnapshot: response.networkInterfaceSnapshot
            )
        } catch is CancellationError {
            await closeDatasetsForMandatoryPollCleanup(ownedDatasetIDs)
            throw CancellationError()
        } catch {
            let failure = responseFailure(from: error)
            if failure.isFatalTransportError {
                // Do not continue using a connection after malformed or
                // otherwise untrusted helper data. Disconnect cleanup owns
                // any remaining service-side datasets in this case.
                terminalize(failure)
                throw failure
            }
            await closeDatasetsForMandatoryPollCleanup(ownedDatasetIDs)
            throw pollFailure(from: failure)
        }
    }

    private func pollFailure(from error: any Error) -> TorrentEngineClientError {
        let failure = responseFailure(from: error)
        if failure.recoveryDisposition == .terminal {
            terminalize(failure)
        }
        return failure
    }

    package func requestSources(id: String) async throws {
        try await invokeUnit(.requestSources, TorrentEngineIPCTorrentIDRequest(id: id))
    }

    package func sourcePolicy(id: String) async throws -> TorrentSourcePolicy {
        try await invoke(.sourcePolicy, TorrentEngineIPCTorrentIDRequest(id: id))
    }

    package func setSourcePolicy(
        id: String,
        field: TorrentSourcePolicyField,
        enabled: Bool
    ) async throws {
        try await invokeUnit(
            .setSourcePolicy,
            TorrentEngineIPCSetSourcePolicyRequest(id: id, field: field, enabled: enabled)
        )
    }

    package func torrentOptions(id: String) async throws -> TorrentOptions {
        try await invoke(.torrentOptions, TorrentEngineIPCTorrentIDRequest(id: id))
    }

    package func setTorrentOptions(id: String, options: TorrentOptions) async throws {
        try await invokeUnit(
            .setTorrentOptions,
            TorrentEngineIPCSetTorrentOptionsRequest(id: id, options: options)
        )
    }

    package func moveTorrentInQueue(id: String, move: TorrentQueueMove) async throws {
        try await invokeUnit(.moveTorrentInQueue, TorrentEngineIPCMoveQueueRequest(id: id, move: move))
    }

    package func requestFiles(id: String) async throws {
        try await invokeUnit(.requestFiles, TorrentEngineIPCTorrentIDRequest(id: id))
    }

    package func setFilePriority(
        id: String,
        fileIndex: Int32,
        priority: TorrentFilePriority
    ) async throws {
        try await invokeUnit(
            .setFilePriority,
            TorrentEngineIPCSetFilePriorityRequest(
                id: id,
                fileIndex: fileIndex,
                priority: priority
            )
        )
    }

    package func requestPieceMap(id: String) async throws {
        try await invokeUnit(.requestPieceMap, TorrentEngineIPCTorrentIDRequest(id: id))
    }

    package func trackerBatch(id: String, since revision: UInt64?) async -> TorrentTrackerBatch? {
        try? await invokeOptional(
            .trackerBatch,
            TorrentEngineIPCTorrentRevisionRequest(id: id, revision: revision)
        )
    }

    package func webSeedBatch(id: String, since revision: UInt64?) async -> TorrentWebSeedBatch? {
        try? await invokeOptional(
            .webSeedBatch,
            TorrentEngineIPCTorrentRevisionRequest(id: id, revision: revision)
        )
    }

    package func webSeedActivity(id: String) async -> TorrentWebSeedActivity? {
        try? await invokeOptional(.webSeedActivity, TorrentEngineIPCTorrentIDRequest(id: id))
    }

    package func peerSources(id: String) async -> TorrentPeerSources? {
        try? await invokeOptional(.peerSources, TorrentEngineIPCTorrentIDRequest(id: id))
    }

    package func fileBatch(id: String, since revision: UInt64?) async -> TorrentFileBatch? {
        try? await invokeOptional(
            .fileBatch,
            TorrentEngineIPCTorrentRevisionRequest(id: id, revision: revision)
        )
    }

    package func pieceMapBatch(id: String, since revision: UInt64?) async -> TorrentPieceMapBatch? {
        try? await invokeOptional(
            .pieceMapBatch,
            TorrentEngineIPCTorrentRevisionRequest(id: id, revision: revision)
        )
    }

    private func bootstrap(
        enablePeerExchangePlugin: Bool,
        folderAuthorizations: [TorrentFolderAuthorization]
    ) async throws {
        let authorizations = try Self.canonicalAuthorizations(folderAuthorizations)
        let folders = authorizations.map {
            TorrentEngineIPCFolderGrant(bookmark: $0.bookmarkData)
        }
        let request = TorrentEngineIPCHandshakeRequest(
            enablePeerExchangePlugin: enablePeerExchangePlugin,
            folders: folders
        )
        let (response, epoch): (TorrentEngineIPCHandshakeResponse, UUID) = try await invokeBeforeHandshake(
            .handshake,
            request
        )
        guard response.folders.count == authorizations.count else {
            throw TorrentEngineClientError.invalidReply
        }
        var capabilities = [String: CapabilityRecord]()
        for (authorization, granted) in zip(authorizations, response.folders) {
            let path = authorization.path
            guard granted.resolvedPath == path,
                  capabilities.updateValue(
                    CapabilityRecord(id: granted.capabilityID, state: .committed),
                    forKey: path
                  ) == nil else {
                throw TorrentEngineClientError.capabilityPathMismatch
            }
        }
        engineEpoch = epoch
        capabilitiesByCanonicalPath = capabilities
        state.setLibtorrentVersion(response.libtorrentVersion)
    }

    private func migrateLegacyStateIfNeeded(from stateDirectory: URL) async throws {
        let begin: TorrentEngineIPCStateMigrationBeginResponse
        do {
            (begin, _) = try await invokeBeforeHandshake(
                .beginStateMigration,
                TorrentEngineIPCEmpty()
            )
        } catch {
            throw Self.migrationFailure(from: error)
        }
        guard !begin.alreadyComplete else {
            return
        }

        let legacyDirectory: TorrentLegacyResumeDirectory?
        do {
            legacyDirectory = try TorrentLegacyResumeDirectory.open(
                stateDirectory: stateDirectory
            )
        } catch {
            try? await invokeUnitBeforeHandshake(
                .abortStateMigration,
                TorrentEngineIPCEmpty()
            )
            throw TorrentEngineClientError.migrationFailed
        }

        guard let legacyDirectory, !legacyDirectory.filenames.isEmpty else {
            do {
                try await invokeUnitBeforeHandshake(
                    .abortStateMigration,
                    TorrentEngineIPCEmpty()
                )
                return
            } catch {
                throw Self.migrationFailure(from: error)
            }
        }

        do {
            for filename in legacyDirectory.filenames {
                let descriptor = try legacyDirectory.openFile(named: filename)
                defer {
                    Darwin.close(descriptor)
                }
                try await invokeUnitBeforeHandshake(
                    .importStateMigrationFile,
                    TorrentEngineIPCStateMigrationFileRequest(name: filename),
                    fileDescriptor: descriptor
                )
            }
            try await invokeUnitBeforeHandshake(
                .commitStateMigration,
                TorrentEngineIPCEmpty()
            )
        } catch {
            try? await invokeUnitBeforeHandshake(
                .abortStateMigration,
                TorrentEngineIPCEmpty()
            )
            throw Self.migrationFailure(from: error)
        }
    }

    private static func migrationFailure(from error: any Error) -> any Error {
        if error is CancellationError {
            return CancellationError()
        }
        guard let clientError = error as? TorrentEngineClientError else {
            return TorrentEngineClientError.migrationFailed
        }
        if case .serviceRejected = clientError {
            return TorrentEngineClientError.migrationFailed
        }
        return clientError
    }

    private func pollWire(
        since revision: UInt64?,
        sortedBy sortOrder: TorrentSortOrder,
        direction: TorrentSortDirection,
        includeTrackerHosts: Bool
    ) async throws -> TorrentEngineIPCPollResponse {
        let response: TorrentEngineIPCPollResponse = try await invoke(
            .poll,
            TorrentEngineIPCPollRequest(
                snapshotRevision: revision,
                sortOrder: sortOrder,
                sortDirection: direction,
                includeTrackerHosts: includeTrackerHosts
            )
        )
        do {
            try acceptNetworkInterfaceSnapshot(response.networkInterfaceSnapshot)
        } catch {
            terminalize(.invalidReply)
            throw TorrentEngineClientError.invalidReply
        }
        return response
    }

    private func acceptNetworkInterfaceSnapshot(
        _ snapshot: TorrentNetworkInterfaceSnapshot
    ) throws {
        if let latestNetworkInterfaceSnapshot {
            guard snapshot.revision > latestNetworkInterfaceSnapshot.revision
                    || snapshot == latestNetworkInterfaceSnapshot else {
                throw TorrentEngineClientError.invalidReply
            }
        }
        latestNetworkInterfaceSnapshot = snapshot
    }

    private func loadDatasetContents<Value: Codable & Sendable>(
        _ descriptor: TorrentEngineIPCDatasetDescriptor
    ) async throws -> [Value] {
        var values = [Value]()
        values.reserveCapacity(descriptor.itemCount)
        var encodedByteCount = 0
        for pageIndex in 0..<descriptor.pageCount {
            let page: TorrentEngineIPCDatasetPage = try await invoke(
                .readDataset,
                TorrentEngineIPCReadDatasetRequest(id: descriptor.id, page: pageIndex)
            )
            guard page.id == descriptor.id,
                  page.kind == descriptor.kind,
                  page.page == pageIndex,
                  page.encodedItems.count
                    <= TorrentEngineIPCLimits.maximumDatasetAggregateBytes - encodedByteCount else {
                throw TorrentEngineClientError.invalidReply
            }
            encodedByteCount += page.encodedItems.count
            let pageValues = try TorrentEngineIPCPropertyListCodec.decode(
                [Value].self,
                from: page.encodedItems,
                maximumBytes: TorrentEngineIPCLimits.maximumDatasetPageBytes,
                decodingLimits: .init(
                    maximumContainerElementCount:
                        TorrentEngineIPCLimits.maximumDatasetPageItemCount,
                    maximumCollectionReferenceCount: 128 * 1_024
                )
            )
            guard !pageValues.isEmpty else {
                throw TorrentEngineClientError.invalidReply
            }
            values.append(contentsOf: pageValues)
            guard values.count <= descriptor.itemCount else {
                throw TorrentEngineClientError.invalidReply
            }
        }
        guard values.count == descriptor.itemCount else {
            throw TorrentEngineClientError.invalidReply
        }
        try TorrentEngineClientResponseValidator.validateDataset(
            values,
            kind: descriptor.kind,
            authorizedSavePaths: Set(capabilitiesByCanonicalPath.keys)
        )
        return values
    }

    private func closeDataset(_ id: UUID) async throws {
        try await invokeUnit(.closeDataset, TorrentEngineIPCCloseDatasetRequest(id: id))
    }

    private func folderCapability(
        for path: String
    ) async throws -> (path: String, capabilityID: UUID, wasProvisional: Bool) {
        let canonicalPath = try Self.canonicalPath(path)
        if let record = capabilitiesByCanonicalPath[canonicalPath] {
            return (canonicalPath, record.id, record.state == .provisional)
        }
        throw TorrentEngineClientError.capabilityUnavailable
    }

    private func grantProvisionalFolder(
        path: String,
        bookmarkData: Data
    ) async throws -> TorrentEngineIPCGrantedFolder {
        let response: TorrentEngineIPCGrantFolderResponse = try await invoke(
            .grantFolderCapability,
            TorrentEngineIPCFolderGrant(bookmark: bookmarkData)
        )
        guard response.folder.resolvedPath == path else {
            await revokeForMandatoryCleanup(
                capabilityID: response.folder.capabilityID
            )
            throw TorrentEngineClientError.capabilityPathMismatch
        }
        return response.folder
    }

    private func revoke(capabilityID: UUID) async throws {
        try await invokeUnit(
            .revokeFolderCapability,
            TorrentEngineIPCRevokeFolderRequest(capabilityID: capabilityID)
        )
        capabilitiesByCanonicalPath = capabilitiesByCanonicalPath.filter {
            $0.value.id != capabilityID
        }
    }

    /// Security cleanup belongs to the authenticated connection once the
    /// triggering reply is known. Run it from an uncancelled task so an
    /// observer disappearing cannot suppress the revoke between requests.
    private func revokeForMandatoryCleanup(capabilityID: UUID) async {
        let result = await Task.detached { [weak self] ()
            -> Result<Void, TorrentEngineClientError> in
            guard let self else {
                return .failure(.connectionFailed)
            }
            do {
                try await self.revoke(capabilityID: capabilityID)
                return .success(())
            } catch let error as TorrentEngineClientError {
                return .failure(error)
            } catch {
                return .failure(.connectionFailed)
            }
        }.value
        guard case .failure(let failure) = result else {
            return
        }
        if failure.recoveryDisposition == .terminal {
            terminalize(failure)
        } else {
            terminalize(.connectionFailed)
        }
    }

    private func closeDatasetsForMandatoryPollCleanup(_ ids: [UUID]) async {
        guard !ids.isEmpty else {
            return
        }
        let cleanupSucceeded = await Task.detached { [weak self, ids] in
            guard let self else {
                return false
            }
            var succeeded = true
            for id in ids {
                do {
                    try await self.closeDataset(id)
                } catch {
                    succeeded = false
                }
            }
            return succeeded
        }.value
        guard cleanupSucceeded else {
            // A failed close leaves the helper's dataset budget uncertain.
            // Replacing the controller invokes disconnect cleanup before a
            // later poll can allocate another dataset.
            if state.isAvailable {
                terminalize(.connectionFailed)
            }
            return
        }
    }

    private func invokeUnit<Request: Encodable & Sendable>(
        _ operation: TorrentEngineIPCOperation,
        _ request: Request
    ) async throws {
        let _: TorrentEngineIPCEmpty = try await invoke(operation, request)
    }

    private func invoke<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ operation: TorrentEngineIPCOperation,
        _ request: Request
    ) async throws -> Response {
        guard let engineEpoch else {
            let error = TorrentEngineClientError.connectionFailed
            terminalize(error)
            throw error
        }
        let payload = try TorrentEngineIPCPropertyListCodec.encode(
            request,
            maximumBytes: operation.maximumRequestPayloadBytes
        )
        let reply = try await send(operation: operation, payload: payload, expectedEpoch: engineEpoch)
        return try decodeValidatedResponse(reply, for: operation)
    }

    private func invokeRaw<Response: Decodable & Sendable>(
        _ operation: TorrentEngineIPCOperation,
        payload: Data
    ) async throws -> Response {
        guard payload.count <= operation.maximumRequestPayloadBytes else {
            throw TorrentEngineClientError.serviceRejected(
                "The torrent file exceeds the supported size limit."
            )
        }
        guard let engineEpoch else {
            let error = TorrentEngineClientError.connectionFailed
            terminalize(error)
            throw error
        }
        let reply = try await send(
            operation: operation,
            payload: payload,
            expectedEpoch: engineEpoch
        )
        return try decodeValidatedResponse(reply, for: operation)
    }

    private func invokeOptional<
        Request: Encodable & Sendable,
        Response: Codable & Sendable
    >(
        _ operation: TorrentEngineIPCOperation,
        _ request: Request
    ) async throws -> Response? {
        let response: TorrentEngineIPCOptionalValue<Response> = try await invoke(
            operation,
            request
        )
        guard let value = response.value else {
            return nil
        }
        do {
            try TorrentEngineClientResponseValidator.validate(value)
            return value
        } catch {
            let failure = responseFailure(from: error)
            if failure.isFatalTransportError {
                terminalize(failure)
            }
            throw failure
        }
    }

    private func invokeBeforeHandshake<
        Request: Encodable & Sendable,
        Response: Decodable & Sendable
    >(
        _ operation: TorrentEngineIPCOperation,
        _ request: Request
    ) async throws -> (Response, UUID) {
        let payload = try TorrentEngineIPCPropertyListCodec.encode(
            request,
            maximumBytes: operation.maximumRequestPayloadBytes
        )
        let reply = try await send(operation: operation, payload: payload, expectedEpoch: nil)
        let response: Response = try decodeValidatedResponse(reply, for: operation)
        return (response, reply.engineEpoch)
    }

    private func invokeUnitBeforeHandshake<Request: Encodable & Sendable>(
        _ operation: TorrentEngineIPCOperation,
        _ request: Request,
        fileDescriptor: Int32? = nil
    ) async throws {
        let payload = try TorrentEngineIPCPropertyListCodec.encode(
            request,
            maximumBytes: operation.maximumRequestPayloadBytes
        )
        let reply = try await send(
            operation: operation,
            payload: payload,
            expectedEpoch: nil,
            fileDescriptor: fileDescriptor
        )
        let _: TorrentEngineIPCEmpty = try decodeValidatedResponse(reply, for: operation)
    }

    private func decodeValidatedResponse<Response: Decodable & Sendable>(
        _ reply: TorrentEngineIPCReply,
        for operation: TorrentEngineIPCOperation
    ) throws -> Response {
        do {
            guard let replyPayload = reply.payload else {
                throw TorrentEngineClientError.invalidReply
            }
            let response = try TorrentEngineIPCPropertyListCodec.decode(
                Response.self,
                from: replyPayload,
                maximumBytes: operation.maximumReplyPayloadBytes,
                decodingLimits: operation.propertyListDecodingLimits
            )
            try TorrentEngineClientResponseValidator.validate(response)
            return response
        } catch {
            let failure = responseFailure(from: error)
            if failure.isFatalTransportError {
                terminalize(failure)
            }
            throw failure
        }
    }

    private func send(
        operation: TorrentEngineIPCOperation,
        payload: Data?,
        expectedEpoch: UUID?,
        fileDescriptor: Int32? = nil
    ) async throws -> TorrentEngineIPCReply {
        let clock = ContinuousClock()
        let requestTimeout = requestTimeoutOverrides[operation]
            ?? operation.requestTimeout
        let operationDeadline = clock.now.advanced(by: requestTimeout)
        let deadline = connectionDeadline.map { min($0, operationDeadline) }
            ?? operationDeadline
        try await acquireRequestSlot(deadline: deadline)
        defer {
            releaseRequestSlot()
        }
        guard state.isAvailable else {
            throw TorrentEngineClientError.connectionCancelled
        }
        guard !Task.isCancelled else {
            // No sequence has been consumed and no wire request exists yet, so
            // cancellation here affects only this caller, not the controller.
            throw CancellationError()
        }
        guard clock.now < deadline else {
            throw TorrentEngineClientError.requestExpiredBeforeSubmission
        }
        guard nextSequence != UInt64.max else {
            let error = TorrentEngineClientError.connectionCancelled
            terminalize(error)
            throw error
        }
        let header = TorrentEngineIPCHeader(
            requestID: UUID(),
            controllerID: controllerID,
            sequence: nextSequence,
            operation: operation,
            operationID: UUID(),
            expectedEpoch: expectedEpoch
        )
        do {
            let reply = try await transport.send(
                TorrentEngineIPCRequest(
                    header: header,
                    payload: payload,
                    fileDescriptor: fileDescriptor
                ),
                deadline: deadline
            )
            nextSequence += 1
            return reply
        } catch {
            let failure: TorrentEngineClientError
            if let clientError = error as? TorrentEngineClientError {
                failure = clientError
            } else {
                failure = .connectionFailed
            }
            // Only this transport result guarantees that submission never
            // happened. Every other reply or transport failure may have
            // consumed the sequence, even when the controller is contained.
            if case .requestExpiredBeforeSubmission = failure {
                // Keep the reserved sequence for the next request.
            } else {
                nextSequence += 1
            }
            if failure.isFatalTransportError {
                terminalize(failure)
            }
            throw failure
        }
    }

    private func terminalize(_ error: TorrentEngineClientError) {
        terminalize(
            message: error.localizedDescription,
            recoveryDisposition: error.recoveryDisposition
        )
    }

    private func terminalize(
        message: String,
        recoveryDisposition: TorrentEngineRecoveryDisposition
    ) {
        let waiters = requestWaiters
        requestWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.deadlineTask.cancel()
            waiter.continuation.resume(returning: .unavailable)
        }
        let pollWaiters = pollPipelineWaiters
        pollPipelineWaiters.removeAll(keepingCapacity: false)
        for waiter in pollWaiters {
            waiter.continuation.resume(returning: .unavailable)
        }
        state.cancel(
            message: message,
            recoveryDisposition: recoveryDisposition
        )
        transport.cancel()
    }

    private func responseFailure(from error: any Error) -> TorrentEngineClientError {
        error as? TorrentEngineClientError ?? .invalidReply
    }

    private enum RequestSlotAcquisition: Sendable {
        case acquired
        case unavailable
        case deadlineExpired
    }

    private func acquireRequestSlot(
        deadline: ContinuousClock.Instant
    ) async throws {
        guard state.isAvailable else {
            throw TorrentEngineClientError.connectionCancelled
        }
        guard !Task.isCancelled else {
            throw CancellationError()
        }
        guard ContinuousClock().now < deadline else {
            throw TorrentEngineClientError.requestExpiredBeforeSubmission
        }
        if !requestIsInFlight {
            requestIsInFlight = true
            return
        }
        guard requestWaiters.count < Self.maximumQueuedRequestCount else {
            throw TorrentEngineClientError.requestQueueFull
        }

        let waiterID = UUID()
        let acquisition = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<RequestSlotAcquisition, Never>) in
                guard !Task.isCancelled, state.isAvailable else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                guard ContinuousClock().now < deadline else {
                    continuation.resume(returning: .deadlineExpired)
                    return
                }
                let deadlineTask = Task.detached { [weak self] in
                    do {
                        try await ContinuousClock().sleep(until: deadline)
                    } catch {
                        return
                    }
                    await self?.expireRequestWaiter(waiterID)
                }
                requestWaiters.append(RequestWaiter(
                    id: waiterID,
                    deadlineTask: deadlineTask,
                    continuation: continuation
                ))
            }
        } onCancel: { [self] in
            Task {
                await cancelRequestWaiter(waiterID)
            }
        }
        switch acquisition {
        case .acquired:
            break
        case .deadlineExpired:
            throw TorrentEngineClientError.requestExpiredBeforeSubmission
        case .unavailable:
            if Task.isCancelled {
                throw CancellationError()
            }
            throw TorrentEngineClientError.connectionCancelled
        }
        guard state.isAvailable else {
            // Slot ownership was transferred before the connection became
            // terminal. Release it here because invoke() has not installed its
            // defer yet.
            releaseRequestSlot()
            throw TorrentEngineClientError.connectionCancelled
        }
    }

    private func cancelRequestWaiter(_ id: UUID) {
        guard let index = requestWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = requestWaiters.remove(at: index)
        waiter.deadlineTask.cancel()
        waiter.continuation.resume(returning: .unavailable)
    }

    private func expireRequestWaiter(_ id: UUID) {
        guard let index = requestWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = requestWaiters.remove(at: index)
        waiter.deadlineTask.cancel()
        waiter.continuation.resume(returning: .deadlineExpired)
    }

    private func releaseRequestSlot() {
        guard !requestWaiters.isEmpty else {
            requestIsInFlight = false
            return
        }
        let waiter = requestWaiters.removeFirst()
        waiter.deadlineTask.cancel()
        waiter.continuation.resume(returning: .acquired)
    }

    private enum PollPipelineSlotAcquisition: Sendable {
        case acquired
        case unavailable
    }

    private func acquirePollPipelineSlot() async throws {
        guard state.isAvailable else {
            throw TorrentEngineClientError.connectionCancelled
        }
        guard !Task.isCancelled else {
            throw CancellationError()
        }
        if !pollPipelineIsInFlight {
            pollPipelineIsInFlight = true
            return
        }
        guard pollPipelineWaiters.count < Self.maximumQueuedRequestCount else {
            throw TorrentEngineClientError.requestQueueFull
        }

        let waiterID = UUID()
        let acquisition = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<PollPipelineSlotAcquisition, Never>) in
                guard !Task.isCancelled, state.isAvailable else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                pollPipelineWaiters.append(PollPipelineWaiter(
                    id: waiterID,
                    continuation: continuation
                ))
            }
        } onCancel: { [self] in
            Task {
                await cancelPollPipelineWaiter(waiterID)
            }
        }
        guard acquisition == .acquired else {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw TorrentEngineClientError.connectionCancelled
        }
        guard state.isAvailable, !Task.isCancelled else {
            releasePollPipelineSlot()
            if Task.isCancelled {
                throw CancellationError()
            }
            throw TorrentEngineClientError.connectionCancelled
        }
    }

    private func cancelPollPipelineWaiter(_ id: UUID) {
        guard let index = pollPipelineWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = pollPipelineWaiters.remove(at: index)
        waiter.continuation.resume(returning: .unavailable)
    }

    private func releasePollPipelineSlot() {
        precondition(pollPipelineIsInFlight)
        guard !pollPipelineWaiters.isEmpty else {
            pollPipelineIsInFlight = false
            return
        }
        let waiter = pollPipelineWaiters.removeFirst()
        waiter.continuation.resume(returning: .acquired)
    }

    private static func canonicalPaths(_ paths: [String]) throws -> [String] {
        guard paths.count <= TorrentEngineLimits.maximumAuthorizedSavePathCount else {
            throw TorrentEngineClientError.capabilityUnavailable
        }
        var unique = Set<String>()
        for path in paths {
            unique.insert(try canonicalPath(path))
        }
        return unique.sorted()
    }

    private static func isDefiniteUnsubmittedOrRejectedFailure(
        _ error: any Error
    ) -> Bool {
        guard let clientError = error as? TorrentEngineClientError else {
            return false
        }
        switch clientError {
        case .serviceRejected, .requestExpiredBeforeSubmission:
            return true
        default:
            return false
        }
    }

    private static func canonicalAuthorizations(
        _ authorizations: [TorrentFolderAuthorization]
    ) throws -> [TorrentFolderAuthorization] {
        guard authorizations.count <= TorrentEngineLimits.maximumAuthorizedSavePathCount else {
            throw TorrentEngineClientError.capabilityUnavailable
        }
        var canonicalByPath = [String: TorrentFolderAuthorization]()
        var aggregateBookmarkBytes = 0
        for authorization in authorizations {
            guard !authorization.bookmarkData.isEmpty,
                  authorization.bookmarkData.count <= TorrentEngineIPCLimits.maximumBookmarkBytes,
                  aggregateBookmarkBytes <= TorrentEngineIPCLimits.maximumBookmarkAggregateBytes
                    - authorization.bookmarkData.count else {
                throw TorrentEngineClientError.invalidBookmark
            }
            aggregateBookmarkBytes += authorization.bookmarkData.count
            let path = try canonicalPath(authorization.path)
            guard canonicalByPath.updateValue(
                TorrentFolderAuthorization(path: path, bookmarkData: authorization.bookmarkData),
                forKey: path
            ) == nil else {
                throw TorrentEngineClientError.capabilityUnavailable
            }
        }
        return canonicalByPath.values.sorted { $0.path < $1.path }
    }

    private static func canonicalPath(_ path: String) throws -> String {
        guard !path.isEmpty,
              !path.utf8.contains(0),
              (path as NSString).isAbsolutePath,
              path.utf8.count <= TorrentEngineLimits.maximumAuthorizedSavePathBytes else {
            throw TorrentEngineClientError.capabilityUnavailable
        }
        let standardized = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
        let canonicalPath = canonical.path(percentEncoded: false)
        guard canonicalPath == standardized.path(percentEncoded: false),
              canonicalPath.utf8.count
                <= TorrentEngineLimits.maximumAuthorizedSavePathBytes else {
            throw TorrentEngineClientError.capabilityUnavailable
        }
        return canonicalPath
    }

    deinit {
        state.cancel(
            message: "The isolated torrent engine connection ended safely.",
            recoveryDisposition: .terminal
        )
        transport.cancel()
    }
}

extension TorrentEngineClientError {
    package var recoveryDisposition: TorrentEngineRecoveryDisposition {
        switch self {
        case .connectionFailed, .connectionCancelled, .serviceTemporarilyUnavailable:
            .replaceController
        case .invalidReply, .engineRestarted, .serviceRejected,
             .capabilityUnavailable, .capabilityPathMismatch,
             .invalidBookmark, .migrationFailed, .requestQueueFull,
             .recoveryDeadlineExceeded:
            .terminal
        case .requestExpiredBeforeSubmission:
            .none
        case .requestTimedOut:
            .replaceController
        }
    }
}
