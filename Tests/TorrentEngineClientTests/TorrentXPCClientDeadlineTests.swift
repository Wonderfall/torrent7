import Foundation
import Synchronization
import Testing
import TorrentEngineIPC
import TorrentEngineModel
@testable import TorrentEngineClient

@Suite("Torrent engine client deadlines")
struct TorrentXPCClientDeadlineTests {
    @Test("A queued request expires without consuming a sequence or ending the controller")
    func queuedDeadlineIncludesSlotWait() async throws {
        let epoch = UUID()
        let blocker = QueueDeadlineBlocker()
        let transport = QueueDeadlineTransport { request in
            switch request.header.operation {
            case .handshake:
                return try queueDeadlineReply(
                    TorrentEngineIPCHandshakeResponse(
                        libtorrentVersion: "2.1.0",
                        folders: []
                    ),
                    for: request,
                    epoch: epoch
                )
            case .pause:
                await blocker.block()
                return try queueDeadlineReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            case .reannounce:
                return try queueDeadlineReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            default:
                throw QueueDeadlineTestError.unexpectedOperation(
                    request.header.operation
                )
            }
        }
        let client = try await TorrentXPCClient.connect(
            enablePeerExchangePlugin: false,
            folderAuthorizations: [],
            transport: transport,
            requestTimeoutOverrides: [
                .pause: .seconds(1),
                .reannounce: .milliseconds(50),
            ]
        )

        let inFlight = Task {
            try await client.pause(id: "v1:\(String(repeating: "a", count: 40))")
        }
        await blocker.waitUntilBlocked()

        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await client.reannounce(
                id: "v1:\(String(repeating: "a", count: 40))"
            )
            Issue.record("Expected the queued request to expire")
        } catch let error as TorrentEngineClientError {
            if case .requestExpiredBeforeSubmission = error {
                // Expected: no sequence or wire request was consumed.
            } else {
                Issue.record("Expected a pre-submission deadline, got \(error)")
            }
        }
        let elapsed = started.duration(to: clock.now)

        #expect(elapsed >= .milliseconds(25))
        #expect(elapsed < .seconds(1))
        #expect(client.isAvailable)
        #expect(!transport.isCancelled)
        #expect(transport.operations == [.handshake, .pause])

        await blocker.release()
        try await inFlight.value
        try await client.reannounce(
            id: "v1:\(String(repeating: "a", count: 40))"
        )

        #expect(transport.operations == [.handshake, .pause, .reannounce])
        #expect(transport.sequences == [1, 2, 3])
        #expect(client.isAvailable)
        #expect(!transport.isCancelled)
    }

    @Test("A guaranteed-unsubmitted transport expiry reuses its reserved sequence")
    func transportExpiryDoesNotConsumeSequence() async throws {
        let epoch = UUID()
        let transport = QueueDeadlineTransport { request in
            switch request.header.operation {
            case .handshake:
                return try queueDeadlineReply(
                    TorrentEngineIPCHandshakeResponse(
                        libtorrentVersion: "2.1.0",
                        folders: []
                    ),
                    for: request,
                    epoch: epoch
                )
            case .pause:
                throw TorrentEngineClientError.requestExpiredBeforeSubmission
            case .reannounce:
                return try queueDeadlineReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            default:
                throw QueueDeadlineTestError.unexpectedOperation(
                    request.header.operation
                )
            }
        }
        let client = try await TorrentXPCClient.connect(
            enablePeerExchangePlugin: false,
            folderAuthorizations: [],
            transport: transport
        )
        let torrentID = "v1:\(String(repeating: "b", count: 40))"

        await #expect(throws: TorrentEngineClientError.self) {
            try await client.pause(id: torrentID)
        }
        try await client.reannounce(id: torrentID)

        #expect(transport.operations == [.handshake, .pause, .reannounce])
        #expect(transport.sequences == [1, 2, 2])
        #expect(client.isAvailable)
        #expect(!transport.isCancelled)
    }

    @Test("Connection establishment cannot finish after its absolute deadline")
    func connectionDeadlineIncludesFinalProcessing() async throws {
        let epoch = UUID()
        let transport = QueueDeadlineTransport { request in
            guard request.header.operation == .handshake else {
                throw QueueDeadlineTestError.unexpectedOperation(
                    request.header.operation
                )
            }
            try await Task.sleep(for: .milliseconds(150))
            return try queueDeadlineReply(
                TorrentEngineIPCHandshakeResponse(
                    libtorrentVersion: "2.1.0",
                    folders: []
                ),
                for: request,
                epoch: epoch
            )
        }
        let deadline = ContinuousClock().now.advanced(by: .milliseconds(100))

        do {
            _ = try await TorrentXPCClient.connect(
                enablePeerExchangePlugin: false,
                folderAuthorizations: [],
                transport: transport,
                connectionDeadline: deadline
            )
            Issue.record("Expected the absolute connection deadline to win")
        } catch let error as TorrentEngineClientError {
            if case .recoveryDeadlineExceeded = error {
                // Expected.
            } else {
                Issue.record("Expected recoveryDeadlineExceeded, got \(error)")
            }
        }

        #expect(transport.operations == [.handshake])
        #expect(transport.isCancelled)
    }
}

@safe private final class QueueDeadlineTransport: TorrentEngineIPCTransport, Sendable {
    typealias Handler = @Sendable (TorrentEngineIPCRequest) async throws
        -> TorrentEngineIPCReply

    private struct State: Sendable {
        var requests = [TorrentEngineIPCRequest]()
        var isCancelled = false
    }

    private let handler: Handler
    private let state = Mutex(State())

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(
        _ request: TorrentEngineIPCRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> TorrentEngineIPCReply {
        try state.withLock { state in
            guard !state.isCancelled else {
                throw TorrentEngineClientError.connectionCancelled
            }
            state.requests.append(request)
        }
        guard ContinuousClock().now < deadline else {
            throw TorrentEngineClientError.requestTimedOut(
                outcomeUnknown: request.header.operation.timeoutCanLeaveOutcomeUnknown
            )
        }
        return try await handler(request)
    }

    func cancel() {
        state.withLock { $0.isCancelled = true }
    }

    var operations: [TorrentEngineIPCOperation] {
        state.withLock { $0.requests.map(\.header.operation) }
    }

    var sequences: [UInt64] {
        state.withLock { $0.requests.map(\.header.sequence) }
    }

    var isCancelled: Bool {
        state.withLock(\.isCancelled)
    }
}

private actor QueueDeadlineBlocker {
    private var isBlocked = false
    private var observationWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func block() async {
        isBlocked = true
        let waiters = observationWaiters
        observationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else {
            return
        }
        await withCheckedContinuation { continuation in
            observationWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private enum QueueDeadlineTestError: Error {
    case unexpectedOperation(TorrentEngineIPCOperation)
}

private func queueDeadlineReply<Value: Encodable & Sendable>(
    _ value: Value,
    for request: TorrentEngineIPCRequest,
    epoch: UUID
) throws -> TorrentEngineIPCReply {
    TorrentEngineIPCReply(
        header: request.header,
        engineEpoch: epoch,
        status: .success,
        payload: try TorrentEngineIPCPropertyListCodec.encode(
            value,
            maximumBytes: request.header.operation.maximumReplyPayloadBytes
        )
    )
}
