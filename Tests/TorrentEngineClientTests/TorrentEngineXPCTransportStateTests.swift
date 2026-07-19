import Foundation
import Synchronization
import Testing
import TorrentEngineIPC
@testable import TorrentEngineClient

@Suite("XPC transport reply state")
struct TorrentEngineXPCTransportStateTests {
    private let epoch = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test("A known reply releases the connection before its observer resumes")
    func replyReleasesConnectionBeforeResume() async throws {
        let coordinator = TorrentEngineXPCTransport.ReplyCoordinator()
        let first = try await makePendingReply()
        let second = try await makePendingReply()
        let reply = makeReply()

        #expect(coordinator.register(first.pendingReply))
        #expect(coordinator.finish(
            first.pendingReply,
            with: .success(reply),
            cancelsConnection: false
        ))
        #expect(!coordinator.hasPendingReply)
        #expect(!coordinator.isCancelled)

        // The successor can register immediately; it cannot observe the old
        // completion in the coordinator after the first continuation resumes.
        #expect(coordinator.register(second.pendingReply))
        #expect(coordinator.finish(
            second.pendingReply,
            with: .success(reply),
            cancelsConnection: false
        ))
        #expect(try await first.result.value == reply)
        #expect(try await second.result.value == reply)
    }

    @Test("A terminal reply closes registration before resuming its observer")
    func terminalReplyClosesConnectionBeforeResume() async throws {
        let coordinator = TorrentEngineXPCTransport.ReplyCoordinator()
        let pending = try await makePendingReply()
        let replacement = try await makePendingReply()
        let terminalization = Mutex((didRun: false, wasCancelled: false, hadPending: false))
        let timeout = TorrentEngineClientError.requestTimedOut(outcomeUnknown: true)

        #expect(coordinator.register(pending.pendingReply))
        let didFinish = coordinator.finish(
            pending.pendingReply,
            with: .failure(timeout),
            cancelsConnection: true
        ) {
            terminalization.withLock { state in
                state.didRun = true
                state.wasCancelled = coordinator.isCancelled
                state.hadPending = coordinator.hasPendingReply
            }
        }
        #expect(didFinish)
        let observedTerminalization = terminalization.withLock { $0 }
        #expect(observedTerminalization.didRun)
        #expect(observedTerminalization.wasCancelled)
        #expect(!observedTerminalization.hadPending)
        #expect(coordinator.isCancelled)
        #expect(!coordinator.register(replacement.pendingReply))
        #expect(!coordinator.finish(
            pending.pendingReply,
            with: .success(makeReply()),
            cancelsConnection: false
        ))

        await #expect(throws: TorrentEngineClientError.self) {
            try await pending.result.value
        }
        replacement.pendingReply.finish(
            .failure(TorrentEngineClientError.connectionCancelled)
        )
        await #expect(throws: TorrentEngineClientError.self) {
            try await replacement.result.value
        }
    }

    @Test("Cancellation and a late reply have exactly one completion winner")
    func cancellationWinsExactlyOnce() async throws {
        let coordinator = TorrentEngineXPCTransport.ReplyCoordinator()
        let pending = try await makePendingReply()
        let notification = Mutex((count: 0, wasCancelled: false, hadPending: false))

        #expect(coordinator.register(pending.pendingReply))
        let didCancel = coordinator.cancel(
            with: TorrentEngineClientError.connectionCancelled
        ) {
            notification.withLock { state in
                state.count += 1
                state.wasCancelled = coordinator.isCancelled
                state.hadPending = coordinator.hasPendingReply
            }
        }
        #expect(didCancel)
        #expect(!coordinator.cancel(
            with: TorrentEngineClientError.connectionCancelled
        ) {
            notification.withLock { $0.count += 1 }
        })
        #expect(!coordinator.finish(
            pending.pendingReply,
            with: .success(makeReply()),
            cancelsConnection: false
        ))
        let observedNotification = notification.withLock { $0 }
        #expect(observedNotification.count == 1)
        #expect(observedNotification.wasCancelled)
        #expect(!observedNotification.hadPending)
        await #expect(throws: TorrentEngineClientError.self) {
            try await pending.result.value
        }
    }

    private func makeReply() -> TorrentEngineIPCReply {
        let header = TorrentEngineIPCHeader(
            requestID: UUID(),
            controllerID: UUID(),
            sequence: 1,
            operation: .poll,
            operationID: UUID(),
            expectedEpoch: epoch
        )
        return TorrentEngineIPCReply(
            header: header,
            engineEpoch: epoch,
            status: .success
        )
    }
}

private struct PendingReplyFixture {
    let pendingReply: TorrentEngineXPCTransport.PendingReply
    let result: Task<TorrentEngineIPCReply, any Error>
}

private enum PendingReplyFixtureError: Error {
    case missingPendingReply
}

private func makePendingReply() async throws -> PendingReplyFixture {
    let stream = AsyncStream<TorrentEngineXPCTransport.PendingReply>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )
    let result = Task<TorrentEngineIPCReply, any Error> {
        try await withCheckedThrowingContinuation { continuation in
            stream.continuation.yield(
                TorrentEngineXPCTransport.PendingReply(continuation)
            )
            stream.continuation.finish()
        }
    }
    var iterator = stream.stream.makeAsyncIterator()
    guard let pendingReply = await iterator.next() else {
        result.cancel()
        throw PendingReplyFixtureError.missingPendingReply
    }
    return PendingReplyFixture(pendingReply: pendingReply, result: result)
}
