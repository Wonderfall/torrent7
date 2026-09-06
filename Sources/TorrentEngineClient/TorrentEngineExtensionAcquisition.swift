import Foundation

package enum TorrentEngineExtensionAcquisitionError: Error, Equatable, Sendable {
    case invalidated
}

/// Owns one shared framework acquisition, independently of its callers.
/// Canceling or timing out a caller removes only that waiter. Completed handles
/// remain available, and invalidated generations cannot publish stale results.
package actor TorrentEngineExtensionAcquisition<Handle: Sendable, AcquisitionClock: Clock>
where AcquisitionClock.Duration == Duration {
    package struct Lease: Sendable {
        package let generation: UInt64
    }

    private struct Waiter {
        let continuation: CheckedContinuation<Lease, any Error>
        let deadline: AcquisitionClock.Instant?
        let deadlineTask: Task<Void, Never>?
    }

    private struct Launch {
        let identityID: String
        let generation: UInt64
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
    }

    private enum State {
        case idle
        case starting(Launch)
        case running(identityID: String, generation: UInt64, handle: Handle)
    }

    private let clock: AcquisitionClock
    private var state = State.idle
    private var nextGeneration: UInt64 = 0

    package init(clock: AcquisitionClock) {
        self.clock = clock
    }

    package func acquire(
        identityID: String,
        deadline: AcquisitionClock.Instant? = nil,
        launch: @escaping @Sendable (UInt64) async throws -> Handle
    ) async throws -> Lease {
        try checkCaller(deadline: deadline)
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            let lease = try await withCheckedThrowingContinuation { continuation in
                do {
                    try checkCaller(deadline: deadline)
                    register(
                        waiterID: waiterID, continuation: continuation,
                        identityID: identityID, deadline: deadline, launch: launch
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            try checkCaller(deadline: deadline)
            return lease
        } onCancel: {
            // This bounded actor hop removes one waiter; it does not own or
            // cancel the framework launch shared with other callers.
            Task {
                await self.finishWaiter(waiterID, error: CancellationError())
            }
        }
    }

    package func invalidate(generation: UInt64) {
        switch state {
        case .starting(let active) where active.generation == generation:
            state = .idle
            active.task.cancel()
            for waiter in active.waiters.values {
                waiter.deadlineTask?.cancel()
                waiter.continuation.resume(throwing: TorrentEngineExtensionAcquisitionError.invalidated)
            }
        case .running(_, let activeGeneration, _) where activeGeneration == generation:
            // Drop only the retained handle. In particular, never call
            // AppExtensionProcess.invalidate() to replace a controller.
            state = .idle
        default:
            break
        }
    }

    package var pendingAcquisitionCount: Int {
        guard case .starting(let active) = state else { return 0 }
        return active.waiters.count
    }

    /// Validates a lease and uses its handle without an actor-reentrancy gap.
    package func perform<Output: Sendable>(
        lease: Lease,
        deadline: AcquisitionClock.Instant? = nil,
        operation: @Sendable (Handle) throws -> Output
    ) throws -> Output {
        try checkCaller(deadline: deadline)
        guard case .running(_, let generation, let handle) = state,
              generation == lease.generation else {
            throw TorrentEngineExtensionAcquisitionError.invalidated
        }
        do {
            return try operation(handle)
        } catch {
            state = .idle
            throw error
        }
    }

    private func checkCaller(deadline: AcquisitionClock.Instant?) throws {
        try Task.checkCancellation()
        if let deadline, clock.now >= deadline {
            throw TorrentEngineClientError.recoveryDeadlineExceeded
        }
    }

    private func register(
        waiterID: UUID,
        continuation: CheckedContinuation<Lease, any Error>,
        identityID: String,
        deadline: AcquisitionClock.Instant?,
        launch: @escaping @Sendable (UInt64) async throws -> Handle
    ) {
        switch state {
        case .running(let activeIdentity, let generation, _) where activeIdentity == identityID:
            continuation.resume(returning: Lease(generation: generation))
            return
        case .starting(var active) where active.identityID == identityID:
            active.waiters[waiterID] = makeWaiter(
                id: waiterID, continuation: continuation, deadline: deadline
            )
            state = .starting(active)
            return
        case .starting(let active):
            invalidate(generation: active.generation)
        case .idle, .running:
            break
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        // The acquisition owns this task until completion or invalidation.
        // Weak capture lets teardown cancel it without a task/owner cycle.
        let task = Task<Void, Never> { [weak self] in
            let result: Result<Handle, any Error>
            do {
                result = .success(try await launch(generation))
            } catch {
                result = .failure(error)
            }
            await self?.completeLaunch(generation: generation, result: result)
        }
        state = .starting(Launch(
            identityID: identityID, generation: generation, task: task,
            waiters: [waiterID: makeWaiter(
                id: waiterID, continuation: continuation, deadline: deadline
            )]
        ))
    }

    private func makeWaiter(
        id: UUID,
        continuation: CheckedContinuation<Lease, any Error>,
        deadline: AcquisitionClock.Instant?
    ) -> Waiter {
        let deadlineTask = deadline.map { deadline in
            Task<Void, Never> { [weak self, clock] in
                do {
                    try await clock.sleep(until: deadline, tolerance: nil)
                } catch {
                    return
                }
                await self?.finishWaiter(id, error: TorrentEngineClientError.recoveryDeadlineExceeded)
            }
        }
        return Waiter(continuation: continuation, deadline: deadline, deadlineTask: deadlineTask)
    }

    private func finishWaiter(_ id: UUID, error: any Error) {
        guard case .starting(var active) = state,
              let waiter = active.waiters.removeValue(forKey: id) else { return }
        state = .starting(active)
        waiter.deadlineTask?.cancel()
        waiter.continuation.resume(throwing: error)
    }

    private func completeLaunch(generation: UInt64, result: Result<Handle, any Error>) {
        guard case .starting(let active) = state,
              active.generation == generation else { return }
        switch result {
        case .success(let handle):
            state = .running(identityID: active.identityID, generation: generation, handle: handle)
        case .failure:
            state = .idle
        }
        for waiter in active.waiters.values {
            waiter.deadlineTask?.cancel()
            if let deadline = waiter.deadline, clock.now >= deadline {
                waiter.continuation.resume(throwing: TorrentEngineClientError.recoveryDeadlineExceeded)
            } else {
                waiter.continuation.resume(with: result.map { _ in Lease(generation: generation) })
            }
        }
    }

    deinit {
        if case .starting(let active) = state {
            active.task.cancel()
            for waiter in active.waiters.values {
                waiter.deadlineTask?.cancel()
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
    }
}
