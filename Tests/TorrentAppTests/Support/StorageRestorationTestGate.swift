import Dispatch
import Foundation
import Synchronization
import Testing

/// Stops the synchronous worker at a clock read while the test remains
/// free to use MainActor. A bounded wait also makes a missing executor hop fail
/// instead of deadlocking the test runner.
final class StorageRestorationTestGate: Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let released = DispatchSemaphore(value: 0)
    private let readCount = Mutex(0)
    private let pauseOnRead: Int
    private let instant = ContinuousClock.now

    init(pauseOnRead: Int = 1) {
        self.pauseOnRead = pauseOnRead
    }

    func now() -> ContinuousClock.Instant {
        #expect(!Thread.isMainThread, "Filesystem restoration must leave MainActor")
        let shouldPause = readCount.withLock { count in
            count += 1
            return count == pauseOnRead
        }
        if shouldPause {
            entered.continuation.yield()
            entered.continuation.finish()
            #expect(released.wait(timeout: .now() + .seconds(5)) == .success)
        }
        return instant
    }

    func waitUntilEntered() async {
        for await _ in entered.stream { return }
    }

    func release() {
        released.signal()
    }
}
