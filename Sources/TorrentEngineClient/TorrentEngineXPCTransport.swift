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
    case migrationFailed
    case requestQueueFull

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
        case .migrationFailed:
            "The previous torrent engine state could not be migrated safely."
        case .requestQueueFull:
            "Too many torrent engine requests are waiting. Try again."
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
            authentication: authentication
        )
    }
}

package struct TorrentEngineXPCConfiguration: Equatable, Sendable {
    package let serviceIdentifier: String
    package let authentication: TorrentEngineIPCPeerAuthentication
}

package protocol TorrentEngineIPCTransport: Sendable {
    func send(_ request: TorrentEngineIPCRequest) async throws -> TorrentEngineIPCReply
    func cancel()
}

@safe package final class TorrentEngineXPCTransport: TorrentEngineIPCTransport, @unchecked Sendable {
    private struct State: Sendable {
        var isCancelled = false
    }

    @safe private final class ConnectionState: Sendable {
        let value = Mutex(State())
    }

    private let session: XPCSession
    private let state: ConnectionState
    private let cancellationHandler: @Sendable () -> Void

    package init(
        controllerID: UUID,
        configuration: TorrentEngineXPCConfiguration,
        hintHandler: @escaping @Sendable () -> Void,
        cancellationHandler: @escaping @Sendable () -> Void
    ) throws {
        self.cancellationHandler = cancellationHandler
        let connectionState = ConnectionState()
        state = connectionState

        let serviceIdentifier = configuration.serviceIdentifier
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
            let shouldNotify = connectionState.value.withLock { value in
                guard !value.isCancelled else {
                    return false
                }
                value.isCancelled = true
                return true
            }
            if shouldNotify {
                cancellationHandler()
            }
        }

        switch configuration.authentication {
        case .sameTeam:
            session = try XPCSession(
                xpcService: serviceIdentifier,
                options: .inactive,
                requirement: .isFromSameTeam(
                    andMatchesSigningIdentifier: serviceIdentifier
                ),
                incomingMessageHandler: incomingHandler,
                cancellationHandler: cancelled
            )
        case .reducedAssuranceAdHocDevelopment:
            session = try XPCSession(
                xpcService: serviceIdentifier,
                options: .inactive,
                incomingMessageHandler: incomingHandler,
                cancellationHandler: cancelled
            )
        }
        try session.activate()
    }

    package func send(_ request: TorrentEngineIPCRequest) async throws -> TorrentEngineIPCReply {
        guard !state.value.withLock({ $0.isCancelled }) else {
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

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.send(message: dictionary) { [weak self] result in
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
                    if case .failure(let error) = decoded, error.isFatalTransportError {
                        self?.cancel()
                    }
                    continuation.resume(with: decoded)
                }
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    package func cancel() {
        let shouldCancel = state.value.withLock { value in
            guard !value.isCancelled else {
                return false
            }
            value.isCancelled = true
            return true
        }
        if shouldCancel {
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
            && !metadata.hasFileDescriptor
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
        case .connectionFailed, .connectionCancelled, .invalidReply, .engineRestarted:
            true
        case .serviceRejected, .serviceTemporarilyUnavailable,
             .capabilityUnavailable, .capabilityPathMismatch,
             .invalidBookmark, .migrationFailed, .requestQueueFull:
            false
        }
    }
}
