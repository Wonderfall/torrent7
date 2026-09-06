import Foundation
import Synchronization

/// Advances time separately from timer delivery so tests can also model an
/// executor that delivers a launch result before an overdue timer callback.
final class ExtensionAcquisitionTestClock: Clock {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = ContinuousClock.now
        var sleepers: [UUID: Sleeper] = [:]
        var observers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())
    var now: Instant { state.withLock(\.now) }
    var minimumResolution: Duration { .nanoseconds(1) }
    var pendingSleepCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (earlyResult, observers) = state.withLock { state -> (
                    Result<Void, any Error>?, [CheckedContinuation<Void, Never>]
                ) in
                    if Task.isCancelled {
                        return (.failure(CancellationError()), [])
                    }
                    if state.now >= deadline {
                        return (.success(()), [])
                    }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    let ready = state.observers.filter { $0.count <= state.sleepers.count }
                    state.observers.removeAll { $0.count <= state.sleepers.count }
                    return (nil, ready.map(\.continuation))
                }
                for observer in observers { observer.resume() }
                if let earlyResult { continuation.resume(with: earlyResult) }
            }
        } onCancel: {
            let sleeper = self.state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        state.withLock { $0.now = $0.now.advanced(by: duration) }
    }

    func resumeDueSleepers() {
        let ready = state.withLock { state in
            let ready = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in ready.keys { state.sleepers.removeValue(forKey: id) }
            return ready.values.map(\.continuation)
        }
        for continuation in ready { continuation.resume() }
    }

    func waitUntilSleeping(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let isReady = state.withLock { state in
                guard state.sleepers.count < count else { return true }
                state.observers.append((count, continuation))
                return false
            }
            if isReady { continuation.resume() }
        }
    }
}
