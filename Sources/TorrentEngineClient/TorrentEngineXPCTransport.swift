import Darwin
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
    package static let releaseAppIdentifier = "app.torrent7"
    package static let debugAppIdentifier = "app.torrent7.debug"
    package static let releaseServiceIdentifier = "app.torrent7.engine"
    package static let debugServiceIdentifier = "app.torrent7.debug.engine"
    package static let reducedAssuranceInfoKey = "Torrent7AllowAdHocXPCPeer"

    package static var serviceIdentifier: String {
        Bundle.main.bundleIdentifier == debugAppIdentifier
            ? debugServiceIdentifier
            : releaseServiceIdentifier
    }

    package static var appIdentifier: String {
        Bundle.main.bundleIdentifier == debugAppIdentifier
            ? debugAppIdentifier
            : releaseAppIdentifier
    }

    package static var authentication: TorrentEngineIPCPeerAuthentication {
        Bundle.main.object(forInfoDictionaryKey: reducedAssuranceInfoKey) as? Bool == true
            ? .reducedAssuranceAdHocDevelopment
            : .sameTeam
    }
}

package protocol TorrentEngineIPCTransport: Sendable {
    func send(_ request: TorrentEngineIPCRequest) async throws -> TorrentEngineIPCReply
    func cancel()
}

@safe package final class TorrentEngineXPCTransport: TorrentEngineIPCTransport, @unchecked Sendable {
    private struct State: Sendable {
        var isCancelled = false
        var didNotifyCancellation = false
    }

    @safe private final class ConnectionState: Sendable {
        let value = Mutex(State())
    }

    private let session: XPCSession
    private let state: ConnectionState
    private let controllerID: UUID
    private let hintHandler: @Sendable () -> Void
    private let cancellationHandler: @Sendable () -> Void

    package init(
        controllerID: UUID,
        hintHandler: @escaping @Sendable () -> Void,
        cancellationHandler: @escaping @Sendable () -> Void
    ) throws {
        self.controllerID = controllerID
        self.hintHandler = hintHandler
        self.cancellationHandler = cancellationHandler
        let connectionState = ConnectionState()
        state = connectionState

        let serviceIdentifier = TorrentEngineXPCIdentity.serviceIdentifier
        let incomingHandler: @Sendable (XPCDictionary) -> XPCDictionary? = {
            [controllerID, hintHandler] dictionary in
            guard let request = try? TorrentEngineIPCEnvelopeCodec.decodeRequest(
                dictionary,
                maximumPayloadBytes: 64 * 1_024
            ), Self.validateDecodedHint(request, controllerID: controllerID) else {
                return nil
            }
            hintHandler()
            return nil
        }
        let cancelled: @Sendable (XPCRichError) -> Void = { _ in
            let shouldNotify = connectionState.value.withLock { value in
                value.isCancelled = true
                guard !value.didNotifyCancellation else {
                    return false
                }
                value.didNotifyCancellation = true
                return true
            }
            if shouldNotify {
                cancellationHandler()
            }
        }

        switch TorrentEngineXPCIdentity.authentication {
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
            value.isCancelled = true
            guard !value.didNotifyCancellation else {
                return false
            }
            value.didNotifyCancellation = true
            return true
        }
        if shouldCancel {
            session.cancel(reason: "Torrent engine client closed")
            cancellationHandler()
        }
    }

    package static func validateDecodedHint(
        _ request: TorrentEngineIPCRequest,
        controllerID: UUID
    ) -> Bool {
        defer {
            if let descriptor = request.fileDescriptor {
                Darwin.close(descriptor)
            }
        }
        return request.header.controllerID == controllerID
            && request.header.operation == .changeHint
            && request.payload == nil
            && request.fileDescriptor == nil
    }

    package static func validateDecodedReply(
        _ reply: TorrentEngineIPCReply,
        for request: TorrentEngineIPCRequest
    ) throws -> TorrentEngineIPCReply {
        defer {
            if let descriptor = reply.fileDescriptor {
                Darwin.close(descriptor)
            }
        }
        guard reply.header == request.header,
              reply.fileDescriptor == nil else {
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
