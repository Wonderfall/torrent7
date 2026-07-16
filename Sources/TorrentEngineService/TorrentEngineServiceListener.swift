import Darwin
import Foundation
import TorrentEngineIPC
import XPC

private enum TorrentEngineServiceIdentity {
    static let releaseAppIdentifier = "app.torrent7"
    static let debugAppIdentifier = "app.torrent7.debug"
    static let releaseServiceIdentifier = "app.torrent7.engine"
    static let debugServiceIdentifier = "app.torrent7.debug.engine"
    static let reducedAssuranceInfoKey = "Torrent7AllowAdHocXPCPeer"

    static func configuration(bundle: Bundle) throws -> TorrentEngineServiceConfiguration {
        guard let serviceIdentifier = bundle.bundleIdentifier else {
            throw TorrentEngineServiceStartupError.missingBundleIdentifier
        }

        let appIdentifier: String
        switch serviceIdentifier {
        case releaseServiceIdentifier:
            appIdentifier = releaseAppIdentifier
        case debugServiceIdentifier:
            appIdentifier = debugAppIdentifier
        default:
            throw TorrentEngineServiceStartupError.unrecognizedBundleIdentifier
        }

        let allowsAdHoc = bundle.object(
            forInfoDictionaryKey: reducedAssuranceInfoKey
        ) as? Bool == true
        return TorrentEngineServiceConfiguration(
            serviceIdentifier: serviceIdentifier,
            appIdentifier: appIdentifier,
            authentication: allowsAdHoc
                ? .reducedAssuranceAdHocDevelopment
                : .sameTeam
        )
    }
}

private struct TorrentEngineServiceConfiguration: Sendable {
    let serviceIdentifier: String
    let appIdentifier: String
    let authentication: TorrentEngineIPCPeerAuthentication
}

struct TorrentEngineServiceAdmissionLimits: Equatable, Sendable {
    static let standard = TorrentEngineServiceAdmissionLimits(
        maximumPeerCount: 4,
        maximumRequestCount: 16,
        maximumPayloadByteCount: TorrentEngineIPCLimits.maximumPayloadBytes + 8 * 1_024 * 1_024,
        maximumFileDescriptorCount: 4
    )

    let maximumPeerCount: Int
    let maximumRequestCount: Int
    let maximumPayloadByteCount: Int
    let maximumFileDescriptorCount: Int

    init(
        maximumPeerCount: Int,
        maximumRequestCount: Int,
        maximumPayloadByteCount: Int,
        maximumFileDescriptorCount: Int
    ) {
        precondition(maximumPeerCount >= 0)
        precondition(maximumRequestCount >= 0)
        precondition(maximumPayloadByteCount >= 0)
        precondition(maximumFileDescriptorCount >= 0)
        self.maximumPeerCount = maximumPeerCount
        self.maximumRequestCount = maximumRequestCount
        self.maximumPayloadByteCount = maximumPayloadByteCount
        self.maximumFileDescriptorCount = maximumFileDescriptorCount
    }
}

struct TorrentEngineServiceAdmissionSnapshot: Equatable, Sendable {
    let peerCount: Int
    let requestCount: Int
    let payloadByteCount: Int
    let fileDescriptorCount: Int
}

@safe final class TorrentEngineServiceSessionHandle: @unchecked Sendable {
    private enum Destination {
        case session(
            XPCSession,
            localCancellationHandler: @Sendable () -> Void
        )
        case observer(
            cancel: @Sendable (String) -> Void,
            send: @Sendable () -> Void
        )
    }

    private let destination: Destination

    init(
        session: XPCSession,
        localCancellationHandler: @escaping @Sendable () -> Void = {}
    ) {
        destination = .session(
            session,
            localCancellationHandler: localCancellationHandler
        )
    }

    init(
        cancelObserver: @escaping @Sendable (String) -> Void = { _ in },
        sendObserver: @escaping @Sendable () -> Void = {}
    ) {
        destination = .observer(cancel: cancelObserver, send: sendObserver)
    }

    func cancel(reason: String) {
        switch destination {
        case .session(let session, let localCancellationHandler):
            localCancellationHandler()
            session.cancel(reason: reason)
        case .observer(let cancelObserver, _):
            cancelObserver(reason)
        }
    }

    func send(message: XPCDictionary) throws {
        switch destination {
        case .session(let session, _):
            try session.send(message: message)
        case .observer(_, let sendObserver):
            sendObserver()
        }
    }
}

@safe final class TorrentEngineServiceAdmissionBudget: @unchecked Sendable {
    private struct State {
        var peerCount = 0
        var requestCount = 0
        var payloadByteCount = 0
        var fileDescriptorCount = 0
    }

    private let limits: TorrentEngineServiceAdmissionLimits
    private let lock = NSLock()
    private var state = State()

    init(limits: TorrentEngineServiceAdmissionLimits = .standard) {
        self.limits = limits
    }

    func acquirePeer() -> TorrentEngineServicePeerAdmission? {
        let acquired = lock.withLock {
            guard state.peerCount < limits.maximumPeerCount else {
                return false
            }
            state.peerCount += 1
            return true
        }
        return acquired ? TorrentEngineServicePeerAdmission(budget: self) : nil
    }

    func acquireRequest(
        payloadByteCount: Int,
        hasFileDescriptor: Bool
    ) -> TorrentEngineServiceRequestAdmission? {
        guard payloadByteCount >= 0 else {
            return nil
        }
        let fileDescriptorCount = hasFileDescriptor ? 1 : 0
        let acquired = lock.withLock {
            guard state.requestCount < limits.maximumRequestCount,
                  payloadByteCount <= limits.maximumPayloadByteCount - state.payloadByteCount,
                  fileDescriptorCount <= limits.maximumFileDescriptorCount
                    - state.fileDescriptorCount else {
                return false
            }
            state.requestCount += 1
            state.payloadByteCount += payloadByteCount
            state.fileDescriptorCount += fileDescriptorCount
            return true
        }
        guard acquired else {
            return nil
        }
        return TorrentEngineServiceRequestAdmission(
            budget: self,
            payloadByteCount: payloadByteCount,
            fileDescriptorCount: fileDescriptorCount
        )
    }

    fileprivate func releasePeer() {
        lock.withLock {
            precondition(state.peerCount > 0)
            state.peerCount -= 1
        }
    }

    fileprivate func releaseRequest(payloadByteCount: Int, fileDescriptorCount: Int) {
        lock.withLock {
            precondition(state.requestCount > 0)
            precondition(state.payloadByteCount >= payloadByteCount)
            precondition(state.fileDescriptorCount >= fileDescriptorCount)
            state.requestCount -= 1
            state.payloadByteCount -= payloadByteCount
            state.fileDescriptorCount -= fileDescriptorCount
        }
    }

    func snapshot() -> TorrentEngineServiceAdmissionSnapshot {
        lock.withLock {
            TorrentEngineServiceAdmissionSnapshot(
                peerCount: state.peerCount,
                requestCount: state.requestCount,
                payloadByteCount: state.payloadByteCount,
                fileDescriptorCount: state.fileDescriptorCount
            )
        }
    }
}

@safe final class TorrentEngineServicePeerAdmission: @unchecked Sendable {
    private let budget: TorrentEngineServiceAdmissionBudget
    private let lock = NSLock()
    private var isReleased = false

    init(budget: TorrentEngineServiceAdmissionBudget) {
        self.budget = budget
    }

    func release() {
        let shouldRelease = lock.withLock {
            guard !isReleased else {
                return false
            }
            isReleased = true
            return true
        }
        if shouldRelease {
            budget.releasePeer()
        }
    }

    deinit {
        release()
    }
}

@safe final class TorrentEngineServiceRequestAdmission: @unchecked Sendable {
    let payloadByteCount: Int
    let fileDescriptorCount: Int

    private let budget: TorrentEngineServiceAdmissionBudget
    private let lock = NSLock()
    private var isReleased = false

    init(
        budget: TorrentEngineServiceAdmissionBudget,
        payloadByteCount: Int,
        fileDescriptorCount: Int
    ) {
        self.budget = budget
        self.payloadByteCount = payloadByteCount
        self.fileDescriptorCount = fileDescriptorCount
    }

    func release() {
        let shouldRelease = lock.withLock {
            guard !isReleased else {
                return false
            }
            isReleased = true
            return true
        }
        if shouldRelease {
            budget.releaseRequest(
                payloadByteCount: payloadByteCount,
                fileDescriptorCount: fileDescriptorCount
            )
        }
    }

    deinit {
        release()
    }
}

private enum TorrentEngineServiceStartupError: LocalizedError {
    case missingBundleIdentifier
    case unrecognizedBundleIdentifier
    case stateDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .missingBundleIdentifier:
            "The XPC service bundle identifier is missing."
        case .unrecognizedBundleIdentifier:
            "The XPC service bundle identifier is not allowlisted."
        case .stateDirectoryUnavailable:
            "The isolated torrent engine state directory is unavailable."
        }
    }
}

@safe final class TorrentEngineServiceBootstrap {
    private let listener: XPCListener

    init(bundle: Bundle = .main) throws {
        let configuration = try TorrentEngineServiceIdentity.configuration(bundle: bundle)
        let stateDirectory = try Self.prepareStateDirectory()
        let containmentWatchdog = TorrentEngineServiceContainmentWatchdog(
            timeout: .seconds(5)
        )
        let cleanupWatchdog = TorrentEngineServiceContainmentWatchdog(
            timeout: .seconds(300)
        )
        let runtime = try TorrentEngineServiceRuntime(
            stateDirectory: stateDirectory,
            authentication: configuration.authentication,
            containmentWatchdog: containmentWatchdog,
            cleanupWatchdog: cleanupWatchdog
        )
        let queue = DispatchQueue(
            label: "app.torrent7.engine.listener",
            qos: .userInitiated
        )
        let admissionBudget = TorrentEngineServiceAdmissionBudget()
        let incomingHandler: @Sendable (
            XPCListener.IncomingSessionRequest
        ) -> XPCListener.IncomingSessionRequest.Decision = { request in
            guard let peerAdmission = admissionBudget.acquirePeer() else {
                return request.reject(reason: "Torrent engine peer limit exceeded")
            }
            let peer = TorrentEngineServicePeer(
                runtime: runtime,
                admissionBudget: admissionBudget,
                peerAdmission: peerAdmission,
                containmentWatchdog: containmentWatchdog,
                cleanupWatchdog: cleanupWatchdog
            )
            let (decision, session) = request.accept(
                incomingMessageHandler: { message in
                    peer.receive(message)
                    return nil
                },
                cancellationHandler: { _ in
                    peer.cancel()
                }
            )
            peer.bind(session: session)
            return decision
        }

        switch configuration.authentication {
        case .sameTeam:
            listener = try XPCListener(
                service: configuration.serviceIdentifier,
                targetQueue: queue,
                options: .inactive,
                requirement: .isFromSameTeam(
                    andMatchesSigningIdentifier: configuration.appIdentifier
                ),
                incomingSessionHandler: incomingHandler
            )
        case .reducedAssuranceAdHocDevelopment:
            // This weaker mode is reachable only through the explicit Info.plist
            // development switch. Identified builds omit that switch and always
            // use the exact signing requirement above.
            listener = try XPCListener(
                service: configuration.serviceIdentifier,
                targetQueue: queue,
                options: .inactive,
                incomingSessionHandler: incomingHandler
            )
        }
    }

    func activate() throws {
        try listener.activate()
    }

    private static func prepareStateDirectory() throws -> URL {
        let fileManager = FileManager.default
        let applicationSupport: URL
        do {
            applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw TorrentEngineServiceStartupError.stateDirectoryUnavailable
        }

        let requested = applicationSupport
            .appendingPathComponent("Torrent7", isDirectory: true)
            .appendingPathComponent("EngineState", isDirectory: true)
            .standardizedFileURL
        do {
            try fileManager.createDirectory(
                at: requested,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: requested.path(percentEncoded: false)
            )
        } catch {
            throw TorrentEngineServiceStartupError.stateDirectoryUnavailable
        }

        let canonical = requested.resolvingSymlinksInPath().standardizedFileURL
        var requestedMetadata = stat()
        var canonicalMetadata = stat()
        let requestedStatus = unsafe requested.path(percentEncoded: false).withCString {
            unsafe Darwin.lstat($0, &requestedMetadata)
        }
        let canonicalStatus = unsafe canonical.path(percentEncoded: false).withCString {
            unsafe Darwin.lstat($0, &canonicalMetadata)
        }
        guard requestedStatus == 0,
              canonicalStatus == 0,
              (requestedMetadata.st_mode & S_IFMT) == S_IFDIR,
              (canonicalMetadata.st_mode & S_IFMT) == S_IFDIR,
              requestedMetadata.st_dev == canonicalMetadata.st_dev,
              requestedMetadata.st_ino == canonicalMetadata.st_ino else {
            throw TorrentEngineServiceStartupError.stateDirectoryUnavailable
        }
        return canonical
    }
}

@safe private final class TorrentEngineServicePeer: @unchecked Sendable {
    private static let maximumQueuedRequestCount = 8
    private static let maximumQueuedPayloadBytes = TorrentEngineIPCLimits.maximumPayloadBytes
    private static let maximumQueuedFileDescriptorCount = 1

    private let runtime: TorrentEngineServiceRuntime
    private let admissionBudget: TorrentEngineServiceAdmissionBudget
    private let peerAdmission: TorrentEngineServicePeerAdmission
    private let containmentWatchdog: TorrentEngineServiceContainmentWatchdog
    private let cleanupWatchdog: TorrentEngineServiceContainmentWatchdog
    private let token = UUID()
    private let lock = NSLock()
    private var session: XPCSession?
    private var isCancelled = false
    private var tailTask: Task<Void, Never>?
    private var queuedRequestCount = 0
    private var queuedPayloadByteCount = 0
    private var queuedFileDescriptorCount = 0

    init(
        runtime: TorrentEngineServiceRuntime,
        admissionBudget: TorrentEngineServiceAdmissionBudget,
        peerAdmission: TorrentEngineServicePeerAdmission,
        containmentWatchdog: TorrentEngineServiceContainmentWatchdog,
        cleanupWatchdog: TorrentEngineServiceContainmentWatchdog
    ) {
        self.runtime = runtime
        self.admissionBudget = admissionBudget
        self.peerAdmission = peerAdmission
        self.containmentWatchdog = containmentWatchdog
        self.cleanupWatchdog = cleanupWatchdog
    }

    func bind(session: XPCSession) {
        let shouldCancel = lock.withLock {
            guard !isCancelled else {
                return true
            }
            self.session = session
            return false
        }
        if shouldCancel {
            session.cancel(reason: "Torrent engine peer closed before activation")
        }
    }

    func receive(_ message: XPCDictionary) {
        let metadata: TorrentEngineIPCRequestMetadata
        do {
            metadata = try TorrentEngineIPCEnvelopeCodec.inspectRequest(message)
            guard metadata.payloadByteCount
                    <= metadata.header.operation.maximumRequestPayloadBytes else {
                throw TorrentEngineIPCError.payloadTooLarge(
                    actual: metadata.payloadByteCount,
                    maximum: metadata.header.operation.maximumRequestPayloadBytes
                )
            }
            let expectsFileDescriptor = metadata.header.operation == .importStateMigrationFile
            guard metadata.hasFileDescriptor == expectsFileDescriptor else {
                throw TorrentEngineIPCError.invalidFileDescriptor
            }
        } catch {
            // No trustworthy header exists for a correlated failure reply. XPC
            // owns the original message objects and releases any contained FD.
            if let session = lock.withLock({ session }) {
                reject(session: session, reason: "Malformed torrent engine request")
            } else {
                cancel()
            }
            return
        }

        var requestAdmission: TorrentEngineServiceRequestAdmission?
        var peerSession: XPCSession?
        var sessionToCancel: XPCSession?
        lock.withLock {
            guard !isCancelled, let session else {
                return
            }
            let fileDescriptorCount = metadata.hasFileDescriptor ? 1 : 0
            guard queuedRequestCount < Self.maximumQueuedRequestCount,
                  metadata.payloadByteCount <= Self.maximumQueuedPayloadBytes
                    - queuedPayloadByteCount,
                  fileDescriptorCount <= Self.maximumQueuedFileDescriptorCount
                    - queuedFileDescriptorCount,
                  let admission = admissionBudget.acquireRequest(
                    payloadByteCount: metadata.payloadByteCount,
                    hasFileDescriptor: metadata.hasFileDescriptor
                  ) else {
                sessionToCancel = session
                return
            }
            queuedRequestCount += 1
            queuedPayloadByteCount += admission.payloadByteCount
            queuedFileDescriptorCount += admission.fileDescriptorCount
            requestAdmission = admission
            peerSession = session
        }

        guard let requestAdmission, let peerSession else {
            if let sessionToCancel {
                reject(
                    session: sessionToCancel,
                    reason: "Torrent engine request admission limit exceeded"
                )
            }
            return
        }

        let request: TorrentEngineIPCRequest
        do {
            request = try TorrentEngineIPCEnvelopeCodec.decodeRequest(
                message,
                metadata: metadata,
                maximumPayloadBytes: metadata.header.operation.maximumRequestPayloadBytes
            )
        } catch {
            requestDidFinish(requestAdmission)
            reject(session: peerSession, reason: "Malformed torrent engine request")
            return
        }

        let pendingReply = TorrentEnginePendingReply(message: message)
        var wasScheduled = false
        lock.withLock {
            guard !isCancelled, session != nil else {
                return
            }
            let predecessor = tailTask
            tailTask = Task { [weak self, runtime, token] in
                await predecessor?.value
                defer {
                    self?.requestDidFinish(requestAdmission)
                }
                guard let self, !self.peerIsCancelled else {
                    if let descriptor = request.fileDescriptor {
                        Darwin.close(descriptor)
                    }
                    return
                }
                let disposition = await runtime.handle(
                    request,
                    from: token,
                    session: TorrentEngineServiceSessionHandle(
                        session: peerSession,
                        localCancellationHandler: { [weak self] in
                            self?.cancel()
                        }
                    ),
                    peerIsCancelled: { [weak self] in
                        self?.peerIsCancelled ?? true
                    },
                    pendingReply: pendingReply
                )
                if disposition == .terminatePeer {
                    // Latch cancellation before this task completes so every
                    // already-queued successor observes a terminal peer instead
                    // of racing the asynchronous XPC cancellation callback.
                    self.cancel()
                }
            }
            wasScheduled = true
        }

        guard wasScheduled else {
            if let descriptor = request.fileDescriptor {
                Darwin.close(descriptor)
            }
            requestDidFinish(requestAdmission)
            return
        }
    }

    func cancel() {
        // Publish containment before publishing cancellation. A request can
        // observe isCancelled as soon as the peer lock is released and must
        // never enter native disconnect work without an armed deadline.
        let containmentToken = containmentWatchdog.arm()
        let cancellation: (shouldNotify: Bool, tailTask: Task<Void, Never>?) = lock.withLock {
            guard !isCancelled else {
                return (false, nil)
            }
            isCancelled = true
            session = nil
            let task = self.tailTask
            self.tailTask = nil
            return (true, task)
        }

        guard cancellation.shouldNotify else {
            containmentWatchdog.disarm(containmentToken)
            return
        }
        let peerAdmission = peerAdmission
        let containmentWatchdog = containmentWatchdog
        let cleanupWatchdog = cleanupWatchdog
        Task {
            await runtime.beginDisconnect(peerToken: token)
            containmentWatchdog.disarm(containmentToken)
            let cleanupToken = cleanupWatchdog.arm()
            defer {
                cleanupWatchdog.disarm(cleanupToken)
            }
            await cancellation.tailTask?.value
            await runtime.finishDisconnect(peerToken: token)
            // Keep the peer charged to the admission budget until all queued
            // work and controller-owned resources have actually drained.
            peerAdmission.release()
        }
    }

    private var peerIsCancelled: Bool {
        lock.withLock { isCancelled }
    }

    private func reject(session: XPCSession, reason: String) {
        cancel()
        session.cancel(reason: reason)
    }

    private func requestDidFinish(
        _ admission: TorrentEngineServiceRequestAdmission
    ) {
        lock.withLock {
            precondition(queuedRequestCount > 0)
            precondition(queuedPayloadByteCount >= admission.payloadByteCount)
            precondition(queuedFileDescriptorCount >= admission.fileDescriptorCount)
            queuedRequestCount -= 1
            queuedPayloadByteCount -= admission.payloadByteCount
            queuedFileDescriptorCount -= admission.fileDescriptorCount
        }
        admission.release()
    }
}

@safe final class TorrentEnginePendingReply: @unchecked Sendable {
    private enum Destination {
        case message(XPCDictionary)
        case observer(@Sendable (TorrentEngineIPCReplyStatus) -> Void)
    }

    private let destination: Destination
    private let lock = NSLock()
    private var didReply = false

    init(message: XPCDictionary) {
        destination = .message(message)
    }

    init(
        sendObserver: @escaping @Sendable (TorrentEngineIPCReplyStatus) -> Void
    ) {
        destination = .observer(sendObserver)
    }

    func send(_ reply: XPCDictionary, status: TorrentEngineIPCReplyStatus) {
        let shouldReply = lock.withLock {
            guard !didReply else {
                return false
            }
            didReply = true
            return true
        }
        if shouldReply {
            switch destination {
            case .message(let message):
                message.reply(reply)
            case .observer(let sendObserver):
                sendObserver(status)
            }
        }
    }
}
