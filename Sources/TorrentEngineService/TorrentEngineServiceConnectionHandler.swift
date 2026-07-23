import Darwin
import ExtensionFoundation
import Foundation
import Synchronization
import TorrentEngineIPC
import XPC

package protocol TorrentEngineAppExtension: AppExtension {}

extension TorrentEngineAppExtension {
    @MainActor
    package var configuration: some AppExtensionConfiguration {
        do {
            return try TorrentEngineExtensionConfiguration.make()
        } catch {
            fatalError(
                "The isolated torrent engine extension could not start: "
                    + error.localizedDescription
            )
        }
    }
}

private enum TorrentEngineServiceIdentity {
    static func configuration(bundle: Bundle) throws -> TorrentEngineServiceConfiguration {
        guard let serviceIdentifier = bundle.bundleIdentifier else {
            throw TorrentEngineServiceStartupError.missingBundleIdentifier
        }
        guard let identity = TorrentEngineIPCIdentity.pair(
            serviceIdentifier: serviceIdentifier
        ) else {
            throw TorrentEngineServiceStartupError.unrecognizedBundleIdentifier
        }
        let allowsAdHoc = bundle.object(
            forInfoDictionaryKey: TorrentEngineIPCIdentity.reducedAssuranceInfoKey
        ) as? Bool == true
        let authentication = TorrentEngineIPCIdentity.authentication(
            allowsReducedAssurance: allowsAdHoc
        )
        return TorrentEngineServiceConfiguration(
            appIdentifier: identity.appIdentifier,
            authentication: authentication
        )
    }
}

private struct TorrentEngineServiceConfiguration: Sendable {
    let appIdentifier: String
    let authentication: TorrentEngineIPCPeerAuthentication
}

struct TorrentEngineServiceAdmissionLimits: Equatable, Sendable {
    static let standard = TorrentEngineServiceAdmissionLimits(
        maximumPeerCount: 4,
        maximumRequestCount: 16,
        maximumPayloadByteCount: TorrentEngineIPCLimits.maximumPayloadBytes + 8 * 1_024 * 1_024
    )

    let maximumPeerCount: Int
    let maximumRequestCount: Int
    let maximumPayloadByteCount: Int

    init(
        maximumPeerCount: Int,
        maximumRequestCount: Int,
        maximumPayloadByteCount: Int
    ) {
        precondition(maximumPeerCount >= 0)
        precondition(maximumRequestCount >= 0)
        precondition(maximumPayloadByteCount >= 0)
        self.maximumPeerCount = maximumPeerCount
        self.maximumRequestCount = maximumRequestCount
        self.maximumPayloadByteCount = maximumPayloadByteCount
    }
}

struct TorrentEngineServiceAdmissionSnapshot: Equatable, Sendable {
    let peerCount: Int
    let requestCount: Int
    let payloadByteCount: Int
}

@safe final class TorrentEngineServiceSessionHandle: Sendable {
    private enum Destination: Sendable {
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

@safe final class TorrentEngineServiceAdmissionBudget: Sendable {
    private struct State: Sendable {
        var peerCount = 0
        var requestCount = 0
        var payloadByteCount = 0
    }

    private let limits: TorrentEngineServiceAdmissionLimits
    private let state = Mutex(State())

    init(limits: TorrentEngineServiceAdmissionLimits = .standard) {
        self.limits = limits
    }

    func acquirePeer() -> TorrentEngineServicePeerAdmission? {
        let acquired = state.withLock { state in
            guard state.peerCount < limits.maximumPeerCount else {
                return false
            }
            state.peerCount += 1
            return true
        }
        return acquired ? TorrentEngineServicePeerAdmission(budget: self) : nil
    }

    func acquireRequest(payloadByteCount: Int) -> TorrentEngineServiceRequestAdmission? {
        guard payloadByteCount >= 0 else {
            return nil
        }
        let acquired = state.withLock { state in
            guard state.requestCount < limits.maximumRequestCount,
                  payloadByteCount <= limits.maximumPayloadByteCount
                    - state.payloadByteCount else {
                return false
            }
            state.requestCount += 1
            state.payloadByteCount += payloadByteCount
            return true
        }
        guard acquired else {
            return nil
        }
        return TorrentEngineServiceRequestAdmission(
            budget: self,
            payloadByteCount: payloadByteCount
        )
    }

    fileprivate func releasePeer() {
        state.withLock { state in
            precondition(state.peerCount > 0)
            state.peerCount -= 1
        }
    }

    fileprivate func releaseRequest(payloadByteCount: Int) {
        state.withLock { state in
            precondition(state.requestCount > 0)
            precondition(state.payloadByteCount >= payloadByteCount)
            state.requestCount -= 1
            state.payloadByteCount -= payloadByteCount
        }
    }

    func snapshot() -> TorrentEngineServiceAdmissionSnapshot {
        state.withLock { state in
            TorrentEngineServiceAdmissionSnapshot(
                peerCount: state.peerCount,
                requestCount: state.requestCount,
                payloadByteCount: state.payloadByteCount
            )
        }
    }
}

@safe final class TorrentEngineServicePeerAdmission: Sendable {
    private let budget: TorrentEngineServiceAdmissionBudget
    private let isReleased = Mutex(false)

    init(budget: TorrentEngineServiceAdmissionBudget) {
        self.budget = budget
    }

    func release() {
        let shouldRelease = isReleased.withLock { isReleased in
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

@safe final class TorrentEngineServiceRequestAdmission: Sendable {
    let payloadByteCount: Int

    private let budget: TorrentEngineServiceAdmissionBudget
    private let isReleased = Mutex(false)

    init(
        budget: TorrentEngineServiceAdmissionBudget,
        payloadByteCount: Int
    ) {
        self.budget = budget
        self.payloadByteCount = payloadByteCount
    }

    func release() {
        let shouldRelease = isReleased.withLock { isReleased in
            guard !isReleased else {
                return false
            }
            isReleased = true
            return true
        }
        if shouldRelease {
            budget.releaseRequest(payloadByteCount: payloadByteCount)
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
            "The engine extension bundle identifier is missing."
        case .unrecognizedBundleIdentifier:
            "The engine extension bundle identifier is not allowlisted."
        case .stateDirectoryUnavailable:
            "The isolated torrent engine state directory is unavailable."
        }
    }
}

package enum TorrentEngineExtensionConfiguration {
    @MainActor
    package static func make(bundle: Bundle = .main) throws -> ConnectionHandler {
        let configuration = try TorrentEngineServiceIdentity.configuration(bundle: bundle)
        let stateDirectory = try Self.prepareStateDirectory()
        let containmentWatchdog = TorrentEngineServiceContainmentWatchdog(
            timeout: .seconds(5)
        )
        let cleanupWatchdog = TorrentEngineServiceContainmentWatchdog(
            timeout: .seconds(300)
        )
        let runtime = TorrentEngineServiceRuntime(
            stateDirectory: stateDirectory,
            containmentWatchdog: containmentWatchdog,
            cleanupWatchdog: cleanupWatchdog
        )
        let queue = DispatchQueue(
            label: "app.torrent7.engine.connection-handler",
            qos: .userInitiated
        )
        let admissionBudget = TorrentEngineServiceAdmissionBudget()
        return ConnectionHandler(
            onSessionRequest: { request in
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
                return request.accept { inactiveSession in
                    inactiveSession.setTargetQueue(queue)
                    if configuration.authentication == .sameTeam {
                        inactiveSession.setPeerRequirement(
                            .isFromSameTeam(
                                andMatchesSigningIdentifier: configuration.appIdentifier
                            )
                        )
                    }
                    peer.bind(session: inactiveSession)
                    return peer
                }
            }
        )
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
            .appending(path: "Torrent7", directoryHint: .isDirectory)
            .appending(path: "EngineState", directoryHint: .isDirectory)
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

@safe private final class TorrentEngineServicePeer: XPCPeerHandler, Sendable {
    typealias Input = XPCDictionary
    typealias Output = XPCDictionary
    private static let maximumQueuedRequestCount = 8
    private static let maximumQueuedPayloadBytes = TorrentEngineIPCLimits.maximumPayloadBytes
    private static let transientReplyGracePeriod: Duration = .seconds(1)

    private struct State: Sendable {
        var session: XPCSession?
        var isCancelled = false
        var isRetiringAfterReply = false
        var tailTask: Task<Void, Never>?
        var retirementTask: Task<Void, Never>?
        var queuedRequestCount = 0
        var queuedPayloadByteCount = 0
    }

    private let runtime: TorrentEngineServiceRuntime
    private let admissionBudget: TorrentEngineServiceAdmissionBudget
    private let peerAdmission: TorrentEngineServicePeerAdmission
    private let containmentWatchdog: TorrentEngineServiceContainmentWatchdog
    private let cleanupWatchdog: TorrentEngineServiceContainmentWatchdog
    private let token = UUID()
    private let state = Mutex(State())

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
        let shouldCancel = state.withLock { state in
            guard !state.isCancelled else {
                return true
            }
            state.session = session
            return false
        }
        if shouldCancel {
            session.cancel(reason: "Torrent engine peer closed before activation")
        }
    }

    func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
        receive(message)
        return nil
    }

    func handleCancellation(error _: XPCRichError) {
        cancel()
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
        } catch {
            // No trustworthy header exists for a correlated failure reply. XPC
            // owns the original message objects and releases any contained FD.
            if let session = state.withLock({ $0.session }) {
                reject(session: session, reason: "Malformed torrent engine request")
            } else {
                cancel()
            }
            return
        }

        var requestAdmission: TorrentEngineServiceRequestAdmission?
        var peerSession: XPCSession?
        var sessionToCancel: XPCSession?
        state.withLock { state in
            guard !state.isCancelled,
                  !state.isRetiringAfterReply,
                  let session = state.session else {
                return
            }
            guard state.queuedRequestCount < Self.maximumQueuedRequestCount,
                  metadata.payloadByteCount <= Self.maximumQueuedPayloadBytes
                    - state.queuedPayloadByteCount,
                  let admission = admissionBudget.acquireRequest(
                    payloadByteCount: metadata.payloadByteCount
                  ) else {
                sessionToCancel = session
                return
            }
            state.queuedRequestCount += 1
            state.queuedPayloadByteCount += admission.payloadByteCount
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
        state.withLock { state in
            guard !state.isCancelled, state.session != nil else {
                return
            }
            let predecessor = state.tailTask
            state.tailTask = Task { [weak self, runtime, token] in
                await predecessor?.value
                defer {
                    self?.requestDidFinish(requestAdmission)
                }
                guard let self, !self.peerIsCancelled else {
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
                switch disposition {
                case .continuePeer:
                    break
                case .retirePeerAfterReply:
                    self.retireAfterReply()
                case .terminatePeer:
                    // Latch cancellation before this task completes so every
                    // already-queued successor observes a terminal peer instead
                    // of racing the asynchronous XPC cancellation callback.
                    self.cancel()
                }
            }
            wasScheduled = true
        }

        guard wasScheduled else {
            requestDidFinish(requestAdmission)
            return
        }
    }

    func cancel() {
        // Publish containment before publishing cancellation. A request can
        // observe isCancelled as soon as the peer state mutex is released and must
        // never enter native disconnect work without an armed deadline.
        let containmentToken = containmentWatchdog.arm()
        let cancellation: (
            shouldNotify: Bool,
            tailTask: Task<Void, Never>?,
            retirementTask: Task<Void, Never>?
        ) = state.withLock { state in
            guard !state.isCancelled else {
                return (false, nil, nil)
            }
            state.isCancelled = true
            state.session = nil
            let tailTask = state.tailTask
            state.tailTask = nil
            let retirementTask = state.retirementTask
            state.retirementTask = nil
            return (true, tailTask, retirementTask)
        }

        guard cancellation.shouldNotify else {
            containmentWatchdog.disarm(containmentToken)
            return
        }
        cancellation.retirementTask?.cancel()
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
        state.withLock { $0.isCancelled || $0.isRetiringAfterReply }
    }

    private func retireAfterReply() {
        let retiringSession = state.withLock { state -> XPCSession? in
            guard !state.isCancelled,
                  !state.isRetiringAfterReply,
                  state.retirementTask == nil,
                  let session = state.session else {
                return nil
            }
            // Latch terminal state before the current request completes. Any
            // queued successor drains without entering the runtime, and no new
            // request can be admitted during the reply delivery window.
            state.isRetiringAfterReply = true
            return session
        }
        guard let retiringSession else {
            return
        }

        let task = Task { [weak self, retiringSession] in
            do {
                try await Task.sleep(for: Self.transientReplyGracePeriod)
            } catch {
                return
            }
            self?.cancel()
            retiringSession.cancel(
                reason: "Torrent engine transient reply grace period elapsed"
            )
        }
        let installed = state.withLock { state in
            guard !state.isCancelled,
                  state.isRetiringAfterReply,
                  state.retirementTask == nil else {
                return false
            }
            state.retirementTask = task
            return true
        }
        if !installed {
            task.cancel()
        }
    }

    private func reject(session: XPCSession, reason: String) {
        cancel()
        session.cancel(reason: reason)
    }

    private func requestDidFinish(
        _ admission: TorrentEngineServiceRequestAdmission
    ) {
        state.withLock { state in
            precondition(state.queuedRequestCount > 0)
            precondition(state.queuedPayloadByteCount >= admission.payloadByteCount)
            state.queuedRequestCount -= 1
            state.queuedPayloadByteCount -= admission.payloadByteCount
        }
        admission.release()
    }
}

/// XPCDictionary lacks Sendable conformance. The destination is immutable, and
/// `didReply` transfers it to exactly one synchronous sender.
@safe final class TorrentEnginePendingReply: @unchecked Sendable {
    private enum Destination {
        case message(XPCDictionary)
        case observer(@Sendable (XPCDictionary, TorrentEngineIPCReplyStatus) -> Void)
    }

    private let destination: Destination
    private let didReply = Mutex(false)

    init(message: XPCDictionary) {
        destination = .message(message)
    }

    init(
        sendObserver: @escaping @Sendable (TorrentEngineIPCReplyStatus) -> Void
    ) {
        destination = .observer { _, status in
            sendObserver(status)
        }
    }

    init(
        replyObserver: @escaping @Sendable (
            XPCDictionary,
            TorrentEngineIPCReplyStatus
        ) -> Void
    ) {
        destination = .observer(replyObserver)
    }

    func send(_ reply: XPCDictionary, status: TorrentEngineIPCReplyStatus) {
        let shouldReply = didReply.withLock { didReply in
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
            case .observer(let replyObserver):
                replyObserver(reply, status)
            }
        }
    }
}
