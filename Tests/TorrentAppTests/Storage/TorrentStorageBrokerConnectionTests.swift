import Foundation
import Synchronization
import Testing
import TorrentAppInfrastructure
import TorrentEngineIPC
import XPC
@testable import TorrentEngineClient

@Suite("Storage broker connection ownership")
struct TorrentStorageBrokerConnectionTests {
    @Test("A failed command handshake retries with a fresh production storage broker")
    func retryAfterBrokerAcceptance() async throws {
        let configuration = TorrentEngineXPCConfiguration(
            serviceIdentifier: "app.torrent7.engine",
            extensionPointIdentifier: "app.torrent7.torrent-engine",
            authentication: .reducedAssuranceAdHocDevelopment
        )
        let brokers = Mutex<[TorrentStorageBrokerServer]>([])
        let transports = Mutex<[BrokerConsumingTransport]>([])
        let client = try await TorrentXPCClient.connect(
            enablePeerExchangePlugin: false,
            makeStorageBroker: {
                let broker = try TorrentStorageBrokerServer(
                    registry: TorrentStorageBrokerRegistry(),
                    engineConfiguration: configuration
                )
                brokers.withLock { $0.append(broker) }
                return broker
            },
            makeTransport: { _, _, _ in
                transports.withLock { transports in
                    let transport = BrokerConsumingTransport(failHandshake: transports.isEmpty)
                    transports.append(transport)
                    return transport
                }
            }
        )
        let attempts = transports.withLock { $0 }
        let servers = brokers.withLock { $0 }
        #expect(attempts.count == 2)
        #expect(servers.count == 2)
        #expect(Set(servers.map(\.sessionNonce)).count == 2)
        #expect(attempts.allSatisfy { $0.acceptedBrokerHandshake })
        #expect(attempts.first?.isCancelled == true)
        #expect(attempts.last?.isCancelled == false)
        #expect(client.isAvailable)

        await client.shutdown()
        #expect(attempts.allSatisfy { $0.isCancelled })
    }

    @Test("A failed broker factory cancels the newly created command transport")
    func brokerFactoryFailureCleansTransport() async {
        let transport = BrokerConsumingTransport(failHandshake: false)
        await #expect(throws: TorrentEngineClientError.self) {
            try await TorrentXPCClient.connect(
                enablePeerExchangePlugin: false,
                makeStorageBroker: {
                    throw TorrentEngineClientError.serviceRejected("Broker creation failed")
                },
                makeTransport: { _, _, _ in transport }
            )
        }
        #expect(transport.isCancelled)
        #expect(!transport.acceptedBrokerHandshake)
    }
}

/// Exercises the real single-session GUI broker while controlling the command
/// handshake failure that occurs after the helper has consumed its endpoint.
private final class BrokerConsumingTransport: TorrentEngineIPCTransport {
    private struct State {
        var session: XPCSession?
        var isCancelled = false
        var acceptedBrokerHandshake = false
    }

    private let state = Mutex(State())
    private let epoch = UUID()
    private let failHandshake: Bool

    init(failHandshake: Bool) {
        self.failHandshake = failHandshake
    }

    var isCancelled: Bool { state.withLock(\.isCancelled) }
    var acceptedBrokerHandshake: Bool { state.withLock(\.acceptedBrokerHandshake) }

    func send(
        _ request: TorrentEngineIPCRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> TorrentEngineIPCReply {
        let payload: Data
        switch request.header.operation {
        case .handshake:
            let endpoint = try #require(request.brokerEndpoint)
            let handshake = try TorrentEngineIPCJSONCodec.decode(
                TorrentEngineIPCHandshakeRequest.self,
                from: #require(request.payload),
                maximumBytes: request.header.operation.maximumRequestPayloadBytes,
                limits: request.header.operation.requestJSONLimits
            )
            let session = try XPCSession(endpoint: endpoint, options: .inactive)
            let installed = state.withLock { state in
                guard !state.isCancelled else { return false }
                state.session = session
                return true
            }
            guard installed else {
                session.cancel(reason: "The command attempt was canceled")
                throw CancellationError()
            }
            try session.activate()
            let brokerRequest = TorrentStorageBrokerRequest.handshake(.init(
                requestID: UUID(), engineEpoch: epoch,
                sessionNonce: handshake.brokerSessionNonce,
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            ))
            let reply: TorrentStorageBrokerReply = try await withCheckedThrowingContinuation { continuation in
                session.send(message: TorrentStorageBrokerIPCCodec.encode(brokerRequest)) { result in
                    do {
                        let decoded = try TorrentStorageBrokerIPCCodec.decodeReply(
                            result.get(), for: brokerRequest
                        )
                        continuation.resume(returning: decoded)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            guard case .success = reply else {
                throw TorrentEngineClientError.invalidReply
            }
            state.withLock { $0.acceptedBrokerHandshake = true }
            if failHandshake {
                throw TorrentEngineClientError.connectionFailed
            }
            payload = try TorrentEngineIPCJSONCodec.encode(
                TorrentEngineIPCHandshakeResponse(libtorrentVersion: "2.1.1.0"),
                maximumBytes: request.header.operation.maximumReplyPayloadBytes,
                limits: request.header.operation.replyJSONLimits
            )
        case .shutdown:
            payload = try TorrentEngineIPCJSONCodec.encode(
                TorrentEngineIPCEmpty(),
                maximumBytes: request.header.operation.maximumReplyPayloadBytes,
                limits: request.header.operation.replyJSONLimits
            )
        default:
            throw TorrentEngineClientError.invalidReply
        }
        return TorrentEngineIPCReply(
            header: request.header, engineEpoch: epoch,
            status: .success, payload: payload
        )
    }

    func cancel() {
        let session = state.withLock { state in
            state.isCancelled = true
            defer { state.session = nil }
            return state.session
        }
        session?.cancel(reason: "The command attempt ended")
    }
}
