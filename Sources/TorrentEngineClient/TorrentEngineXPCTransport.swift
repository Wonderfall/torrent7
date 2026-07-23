import Foundation
import Synchronization
import TorrentEngineIPC
import XPC

package enum TorrentEngineClientError: LocalizedError, Sendable {
    case connectionFailed
    case connectionCancelled
    case invalidReply
    case engineRestarted
    case serviceRejected(String)
    case serviceTemporarilyUnavailable(String)
    case capabilityUnavailable
    case capabilityPathMismatch
    case invalidBookmark
    case requestQueueFull
    case requestExpiredBeforeSubmission
    case requestTimedOut(outcomeUnknown: Bool)
    case recoveryDeadlineExceeded

    package var errorDescription: String? {
        switch self {
        case .connectionFailed:
            "Could not connect to the isolated torrent engine."
        case .connectionCancelled:
            "The isolated torrent engine connection ended safely."
        case .invalidReply:
            "The isolated torrent engine returned an invalid response."
        case .engineRestarted:
            "The isolated torrent engine restarted. Try the operation again."
        case .serviceRejected(let message):
            message.isEmpty ? "The isolated torrent engine rejected the operation." : message
        case .serviceTemporarilyUnavailable(let message):
            message.isEmpty ? "The isolated torrent engine is finishing a previous connection. Try again shortly." : message
        case .capabilityUnavailable:
            "The download folder is not authorized in the isolated torrent engine."
        case .capabilityPathMismatch:
            "The isolated torrent engine resolved the download folder differently. Choose it again."
        case .invalidBookmark:
            "The download folder authorization could not be delegated safely."
        case .requestQueueFull:
            "Too many torrent engine requests are waiting. Try again."
        case .requestExpiredBeforeSubmission:
            "The torrent engine request expired before it could be sent."
        case .requestTimedOut(let outcomeUnknown):
            outcomeUnknown
                ? "The isolated torrent engine did not confirm the operation before its deadline. Its outcome is unknown."
                : "The isolated torrent engine did not respond before its deadline."
        case .recoveryDeadlineExceeded:
            "The isolated torrent engine could not recover before its deadline."
        }
    }
}

package enum TorrentEngineXPCIdentity {
    package static func configuration(bundle: Bundle = .main) throws -> TorrentEngineXPCConfiguration {
        guard let identity = TorrentEngineIPCIdentity.pair(
            appIdentifier: bundle.bundleIdentifier
        ) else {
            throw TorrentEngineClientError.connectionFailed
        }
        let authentication = TorrentEngineIPCIdentity.authentication(
            allowsReducedAssurance: bundle.object(
                forInfoDictionaryKey: TorrentEngineIPCIdentity.reducedAssuranceInfoKey
            ) as? Bool == true
        )
        return TorrentEngineXPCConfiguration(
            serviceIdentifier: identity.serviceIdentifier,
            extensionPointIdentifier: identity.extensionPointIdentifier,
            authentication: authentication
        )
    }
}

package struct TorrentEngineXPCConfiguration: Equatable, Sendable {
    package let serviceIdentifier: String
    package let extensionPointIdentifier: String
    package let authentication: TorrentEngineIPCPeerAuthentication
}

package protocol TorrentEngineIPCTransport: Sendable {
    func send(
        _ request: TorrentEngineIPCRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> TorrentEngineIPCReply
    func cancel()
}

@safe package final class TorrentEngineXPCTransport: TorrentEngineIPCTransport, @unchecked Sendable {
    @safe package final class PendingReply: @unchecked Sendable {
        private struct State: Sendable {
            var continuation: CheckedContinuation<TorrentEngineIPCReply, any Error>?
            var timeoutTask: Task<Void, Never>?
        }

        private let state: Mutex<State>

        package init(_ continuation: CheckedContinuation<TorrentEngineIPCReply, any Error>) {
            state = Mutex(State(continuation: continuation))
        }

        package func installTimeoutTask(_ task: Task<Void, Never>) {
            let shouldCancel = state.withLock { state in
                guard state.continuation != nil else {
                    return true
                }
                state.timeoutTask = task
                return false
            }
            if shouldCancel {
                task.cancel()
            }
        }

        @discardableResult
        package func finish(_ result: Result<TorrentEngineIPCReply, any Error>) -> Bool {
            let completion = state.withLock { state
                -> (CheckedContinuation<TorrentEngineIPCReply, any Error>, Task<Void, Never>?)? in
                guard let continuation = state.continuation else {
                    return nil
                }
                state.continuation = nil
                let timeoutTask = state.timeoutTask
                state.timeoutTask = nil
                return (continuation, timeoutTask)
            }
            guard let (continuation, timeoutTask) = completion else {
                return false
            }
            timeoutTask?.cancel()
            continuation.resume(with: result)
            return true
        }
    }

    @safe package final class ReplyCoordinator: Sendable {
        private struct State: Sendable {
            var isCancelled = false
            var pendingReply: PendingReply?
        }

        private let state = Mutex(State())

        @discardableResult
        package func register(_ pendingReply: PendingReply) -> Bool {
            state.withLock { state in
                guard !state.isCancelled, state.pendingReply == nil else {
                    return false
                }
                state.pendingReply = pendingReply
                return true
            }
        }

        /// Claims one correlated reply before resuming its observer.
        ///
        /// Clearing the pending slot first lets a successful reply hand the
        /// serialized connection to its successor without a transient false
        /// `connectionCancelled`. A terminal result also closes registration
        /// atomically, so no successor can enter before the XPC session is
        /// cancelled by `beforeResume`.
        @discardableResult
        package func finish(
            _ pendingReply: PendingReply,
            with result: Result<TorrentEngineIPCReply, any Error>,
            cancelsConnection: Bool,
            beforeResume: @Sendable () -> Void = {}
        ) -> Bool {
            let didClaim = state.withLock { state in
                guard !state.isCancelled,
                      state.pendingReply === pendingReply else {
                    return false
                }
                state.pendingReply = nil
                if cancelsConnection {
                    state.isCancelled = true
                }
                return true
            }
            guard didClaim else {
                return false
            }
            if cancelsConnection {
                beforeResume()
            }
            return pendingReply.finish(result)
        }

        /// Atomically terminalizes the connection and takes any pending reply.
        /// The external cancellation/notification runs before the observer is
        /// resumed, while the coordinator is already closed to new requests.
        @discardableResult
        package func cancel(
            with error: any Error,
            beforeResume: @Sendable () -> Void
        ) -> Bool {
            let cancellation: (didCancel: Bool, pendingReply: PendingReply?) =
                state.withLock { state in
                    guard !state.isCancelled else {
                        return (didCancel: false, pendingReply: nil)
                    }
                    state.isCancelled = true
                    let pendingReply = state.pendingReply
                    state.pendingReply = nil
                    return (didCancel: true, pendingReply: pendingReply)
                }
            guard cancellation.didCancel else {
                return false
            }
            beforeResume()
            cancellation.pendingReply?.finish(.failure(error))
            return true
        }

        package var isCancelled: Bool {
            state.withLock(\.isCancelled)
        }

        package var hasPendingReply: Bool {
            state.withLock { $0.pendingReply != nil }
        }
    }

    private let session: XPCSession
    private let replies: ReplyCoordinator
    private let cancellationHandler: @Sendable () -> Void

    package init(
        controllerID: UUID,
        session: XPCSession,
        configuration: TorrentEngineXPCConfiguration,
        hintHandler: @escaping @Sendable () -> Void,
        cancellationHandler: @escaping @Sendable () -> Void
    ) throws {
        self.cancellationHandler = cancellationHandler
        let replyCoordinator = ReplyCoordinator()
        replies = replyCoordinator

        let incomingHandler: @Sendable (XPCDictionary) -> XPCDictionary? = {
            [controllerID, hintHandler] dictionary in
            guard let metadata = try? TorrentEngineIPCEnvelopeCodec.inspectRequest(
                dictionary
            ), Self.validateHint(metadata, controllerID: controllerID) else {
                return nil
            }
            hintHandler()
            return nil
        }
        let cancelled: @Sendable (XPCRichError) -> Void = { _ in
            replyCoordinator.cancel(
                with: TorrentEngineClientError.connectionCancelled
            ) {
                cancellationHandler()
            }
        }

        self.session = session
        session.setIncomingMessageHandler(incomingHandler)
        session.setCancellationHandler(cancelled)
        if configuration.authentication == .sameTeam {
            session.setPeerRequirement(
                .isFromSameTeam(
                    andMatchesSigningIdentifier: configuration.serviceIdentifier
                )
            )
        }
        try session.activate()
    }

    package func send(
        _ request: TorrentEngineIPCRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> TorrentEngineIPCReply {
        guard !replies.isCancelled else {
            throw TorrentEngineClientError.connectionCancelled
        }

        let dictionary: XPCDictionary
        do {
            dictionary = try TorrentEngineIPCEnvelopeCodec.encode(
                request,
                maximumPayloadBytes: request.header.operation.maximumRequestPayloadBytes
            )
        } catch {
            throw TorrentEngineClientError.connectionFailed
        }

        guard ContinuousClock().now < deadline else {
            // Envelope encoding completed after the caller's deadline, but no
            // XPC send was submitted. Preserve the controller and let the
            // client reuse this sequence for a later request.
            throw TorrentEngineClientError.requestExpiredBeforeSubmission
        }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<TorrentEngineIPCReply, any Error>) in
            let pendingReply = PendingReply(continuation)
            guard replies.register(pendingReply) else {
                pendingReply.finish(.failure(TorrentEngineClientError.connectionCancelled))
                return
            }

            session.send(message: dictionary) { [weak self, pendingReply] result in
                guard let self else {
                    return
                }
                let decoded: Result<TorrentEngineIPCReply, TorrentEngineClientError>
                switch result {
                case .success(let replyDictionary):
                    do {
                        let reply = try TorrentEngineIPCEnvelopeCodec.decodeReply(
                            replyDictionary,
                            maximumPayloadBytes: request.header.operation.maximumReplyPayloadBytes
                        )
                        decoded = try .success(Self.validateDecodedReply(reply, for: request))
                    } catch let error as TorrentEngineClientError {
                        decoded = .failure(error)
                    } catch {
                        decoded = .failure(.invalidReply)
                    }
                case .failure:
                    decoded = .failure(.connectionFailed)
                }
                let cancelsConnection = switch decoded {
                case .success:
                    false
                case .failure(let error):
                    error.isFatalTransportError
                }
                self.replies.finish(
                    pendingReply,
                    with: decoded.mapError { $0 as any Error },
                    cancelsConnection: cancelsConnection
                ) { [self] in
                    session.cancel(reason: "Torrent engine reply was not safe to continue")
                    cancellationHandler()
                }
            }

            // This timer is connection-owned. Caller cancellation cannot stop
            // an authenticated transaction from being drained or bounded.
            // Install it after send submission so a deadline cannot win and
            // then allow an unsubmitted mutation to be sent afterward.
            let timeoutTask = Task.detached { [weak self, pendingReply] in
                do {
                    try await ContinuousClock().sleep(until: deadline)
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                let timeout = TorrentEngineClientError.requestTimedOut(
                    outcomeUnknown: request.header.operation.timeoutCanLeaveOutcomeUnknown
                )
                self.replies.finish(
                    pendingReply,
                    with: .failure(timeout),
                    cancelsConnection: true
                ) { [self] in
                    session.cancel(reason: "Torrent engine request deadline expired")
                    cancellationHandler()
                }
            }
            pendingReply.installTimeoutTask(timeoutTask)
        }
    }

    package func cancel() {
        replies.cancel(with: TorrentEngineClientError.connectionCancelled) { [self] in
            session.cancel(reason: "Torrent engine client closed")
            cancellationHandler()
        }
    }

    package static func validateHint(
        _ metadata: TorrentEngineIPCRequestMetadata,
        controllerID: UUID
    ) -> Bool {
        metadata.header.controllerID == controllerID
            && metadata.header.operation == .changeHint
            && !metadata.hasPayload
    }

    package static func validateDecodedReply(
        _ reply: TorrentEngineIPCReply,
        for request: TorrentEngineIPCRequest
    ) throws -> TorrentEngineIPCReply {
        guard reply.header == request.header else {
            throw TorrentEngineClientError.invalidReply
        }
        if let expectedEpoch = request.header.expectedEpoch,
           reply.engineEpoch != expectedEpoch {
            throw TorrentEngineClientError.engineRestarted
        }
        switch reply.status {
        case .success:
            return reply
        case .failure:
            switch reply.failureCode {
            case .controllerBusy, .serviceShuttingDown:
                throw TorrentEngineClientError.serviceTemporarilyUnavailable(
                    reply.errorMessage ?? ""
                )
            case .operationRejected, nil:
                throw TorrentEngineClientError.serviceRejected(reply.errorMessage ?? "")
            }
        }
    }

    deinit {
        cancel()
    }
}

extension TorrentEngineClientError {
    package var isFatalTransportError: Bool {
        switch self {
        case .connectionFailed, .connectionCancelled, .invalidReply, .engineRestarted,
             .recoveryDeadlineExceeded:
            true
        case .serviceRejected, .serviceTemporarilyUnavailable,
             .capabilityUnavailable, .capabilityPathMismatch,
             .invalidBookmark, .requestQueueFull,
             .requestExpiredBeforeSubmission:
            false
        case .requestTimedOut:
            true
        }
    }
}

extension TorrentEngineIPCOperation {
    package var requestTimeout: Duration {
        switch self {
        case .handshake, .restart:
            .seconds(120)
        case .shutdown, .remove, .saveAll:
            .seconds(60)
        case .poll, .previewTorrentFile, .addMagnet, .addTorrentFile,
             .applySettings, .blockNetwork:
            .seconds(30)
        default:
            .seconds(15)
        }
    }

    package var timeoutCanLeaveOutcomeUnknown: Bool {
        switch self {
        case .poll, .previewTorrentFile, .requestSources,
             .sourcePolicy, .torrentOptions, .requestFiles,
             .requestPieceMap, .trackerBatch, .webSeedBatch,
             .webSeedActivity, .peerSources, .fileBatch,
             .pieceMapBatch, .readDataset, .closeDataset,
             .changeHint:
            false
        default:
            true
        }
    }
}
