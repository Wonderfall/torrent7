import Dispatch
import Foundation
import Synchronization
import Testing
@testable import TorrentEngineService

@Suite("Torrent engine containment watchdog", .serialized)
struct TorrentEngineServiceContainmentWatchdogTests {
    @Test("Armed cleanup expires, while completed cleanup disarms")
    func armAndDisarm() {
        let scheduler = ControllableWatchdogScheduler()
        let terminationCount = Mutex(0)
        let watchdog = TorrentEngineServiceContainmentWatchdog(
            timeout: .milliseconds(10),
            scheduler: scheduler.schedule,
            terminationHandler: {
                terminationCount.withLock { $0 += 1 }
            }
        )

        _ = watchdog.arm()
        #expect(scheduler.scheduledCount == 1)
        scheduler.runNext()
        #expect(terminationCount.withLock { $0 } == 1)

        let completed = watchdog.arm()
        watchdog.disarm(completed)
        scheduler.runNext()
        #expect(terminationCount.withLock { $0 } == 1)
    }

    @Test("Containment and cleanup watchdogs disarm independently")
    func containmentAndCleanupPhasesAreIndependent() {
        let scheduler = ControllableWatchdogScheduler()
        let terminationCount = Mutex(0)
        let containment = TorrentEngineServiceContainmentWatchdog(
            timeout: .never,
            scheduler: scheduler.schedule,
            terminationHandler: {
                terminationCount.withLock { $0 += 1 }
            }
        )
        let cleanup = TorrentEngineServiceContainmentWatchdog(
            timeout: .never,
            scheduler: scheduler.schedule,
            terminationHandler: {
                terminationCount.withLock { $0 += 1 }
            }
        )

        let containmentToken = containment.arm()
        let cleanupToken = cleanup.arm()
        #expect(containment.armedTokenCount == 1)
        #expect(cleanup.armedTokenCount == 1)

        containment.disarm(containmentToken)
        #expect(containment.armedTokenCount == 0)
        #expect(cleanup.armedTokenCount == 1)

        cleanup.disarm(cleanupToken)
        #expect(containment.armedTokenCount == 0)
        #expect(cleanup.armedTokenCount == 0)

        scheduler.runAll()
        #expect(terminationCount.withLock { $0 } == 0)
    }

    @Test("Nested tokens on one watchdog disarm independently")
    func nestedTokensAreIndependent() {
        let scheduler = ControllableWatchdogScheduler()
        let terminationCount = Mutex(0)
        let watchdog = TorrentEngineServiceContainmentWatchdog(
            timeout: .milliseconds(10),
            scheduler: scheduler.schedule,
            terminationHandler: {
                terminationCount.withLock { $0 += 1 }
            }
        )

        let completed = watchdog.arm()
        _ = watchdog.arm()
        #expect(watchdog.armedTokenCount == 2)
        watchdog.disarm(completed)
        #expect(watchdog.armedTokenCount == 1)

        scheduler.runAll()
        #expect(terminationCount.withLock { $0 } == 1)
        #expect(watchdog.armedTokenCount == 0)
    }

    @Test("Concurrent arm and disarm cannot leave stale deadlines")
    func concurrentArmAndDisarm() async {
        let scheduler = ControllableWatchdogScheduler()
        let terminationCount = Mutex(0)
        let watchdog = TorrentEngineServiceContainmentWatchdog(
            timeout: .milliseconds(40),
            scheduler: scheduler.schedule,
            terminationHandler: {
                terminationCount.withLock { $0 += 1 }
            }
        )
        let tokens = await withTaskGroup(of: UUID.self, returning: [UUID].self) { group in
            for _ in 0..<32 {
                group.addTask {
                    watchdog.arm()
                }
            }
            var values = [UUID]()
            for await token in group {
                values.append(token)
            }
            return values
        }
        #expect(watchdog.armedTokenCount == tokens.count)

        await withTaskGroup(of: Void.self) { group in
            for token in tokens {
                group.addTask {
                    watchdog.disarm(token)
                }
            }
        }
        #expect(watchdog.armedTokenCount == 0)
        #expect(scheduler.scheduledCount == tokens.count)
        scheduler.runAll()
        #expect(terminationCount.withLock { $0 } == 0)
    }
}

@safe private final class ControllableWatchdogScheduler: Sendable {
    private let scheduledOperations = Mutex([@Sendable () -> Void]())

    var scheduledCount: Int {
        scheduledOperations.withLock { $0.count }
    }

    func schedule(
        after _: DispatchTimeInterval,
        operation: @escaping @Sendable () -> Void
    ) {
        scheduledOperations.withLock { $0.append(operation) }
    }

    func runNext() {
        let operation = scheduledOperations.withLock { operations in
            operations.isEmpty ? nil : operations.removeFirst()
        }
        operation?()
    }

    func runAll() {
        let operations = scheduledOperations.withLock { operations in
            defer { operations.removeAll() }
            return operations
        }
        for operation in operations {
            operation()
        }
    }
}
