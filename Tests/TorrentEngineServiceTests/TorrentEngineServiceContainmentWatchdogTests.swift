import Dispatch
import Foundation
import Synchronization
import Testing
@testable import TorrentEngineService

@Suite("Torrent engine containment watchdog", .serialized)
struct TorrentEngineServiceContainmentWatchdogTests {
    @Test("Armed cleanup expires, while completed cleanup disarms")
    func armAndDisarm() async throws {
        let terminationCount = Mutex(0)
        let watchdog = TorrentEngineServiceContainmentWatchdog(
            timeout: .milliseconds(10),
            terminationHandler: {
                terminationCount.withLock { $0 += 1 }
            }
        )

        _ = watchdog.arm()
        for _ in 0..<100 where terminationCount.withLock({ $0 == 0 }) {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(terminationCount.withLock { $0 } == 1)

        let completed = watchdog.arm()
        watchdog.disarm(completed)
        try await Task.sleep(for: .milliseconds(30))
        #expect(terminationCount.withLock { $0 } == 1)
    }

    @Test("Containment and cleanup deadlines are independent phases")
    func containmentAndCleanupPhasesAreIndependent() async throws {
        let containmentExpirations = Mutex(0)
        let cleanupExpirations = Mutex(0)
        let containment = TorrentEngineServiceContainmentWatchdog(
            timeout: .milliseconds(10),
            terminationHandler: {
                containmentExpirations.withLock { $0 += 1 }
            }
        )
        let cleanup = TorrentEngineServiceContainmentWatchdog(
            timeout: .milliseconds(40),
            terminationHandler: {
                cleanupExpirations.withLock { $0 += 1 }
            }
        )

        let containmentToken = containment.arm()
        #expect(containment.armedTokenCount == 1)
        containment.disarm(containmentToken)
        let cleanupToken = cleanup.arm()
        try await Task.sleep(for: .milliseconds(20))

        #expect(containment.armedTokenCount == 0)
        #expect(containmentExpirations.withLock { $0 } == 0)
        #expect(cleanup.armedTokenCount == 1)
        #expect(cleanupExpirations.withLock { $0 } == 0)

        cleanup.disarm(cleanupToken)
        try await Task.sleep(for: .milliseconds(30))
        #expect(cleanupExpirations.withLock { $0 } == 0)
    }

    @Test("Nested tokens on one watchdog disarm independently")
    func nestedTokensAreIndependent() async throws {
        let terminationCount = Mutex(0)
        let watchdog = TorrentEngineServiceContainmentWatchdog(
            timeout: .milliseconds(10),
            terminationHandler: {
                terminationCount.withLock { $0 += 1 }
            }
        )

        let completed = watchdog.arm()
        _ = watchdog.arm()
        #expect(watchdog.armedTokenCount == 2)
        watchdog.disarm(completed)
        #expect(watchdog.armedTokenCount == 1)

        for _ in 0..<100 where terminationCount.withLock({ $0 == 0 }) {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(terminationCount.withLock { $0 } == 1)
        #expect(watchdog.armedTokenCount == 0)
    }

    @Test("Concurrent arm and disarm cannot leave stale deadlines")
    func concurrentArmAndDisarm() async throws {
        let terminationCount = Mutex(0)
        let watchdog = TorrentEngineServiceContainmentWatchdog(
            timeout: .milliseconds(40),
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
        try await Task.sleep(for: .milliseconds(60))
        #expect(terminationCount.withLock { $0 } == 0)
    }
}
