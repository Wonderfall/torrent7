import Foundation
import Synchronization
import Testing
@testable import TorrentEngineClient

private enum ProcessLaunchProbeError: Error {
    case failed
}

private actor ProcessLaunchProbe {
    private var continuations: [
        UInt64: CheckedContinuation<Int, any Error>
    ] = [:]
    private var startedGenerations: [UInt64] = []
    private var startObservers: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

    func launch(generation: UInt64) async throws -> Int {
        startedGenerations.append(generation)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[generation] = continuation
            for observer in startObservers.removeValue(forKey: generation) ?? [] {
                observer.resume()
            }
        }
    }

    func waitUntilStarted(generation: UInt64) async {
        guard !startedGenerations.contains(generation) else { return }
        await withCheckedContinuation { continuation in
            startObservers[generation, default: []].append(continuation)
        }
    }

    func succeed(generation: UInt64, handle: Int) {
        continuations.removeValue(forKey: generation)?.resume(returning: handle)
    }

    func fail(generation: UInt64) {
        continuations.removeValue(forKey: generation)?.resume(
            throwing: ProcessLaunchProbeError.failed
        )
    }

    var launchCount: Int {
        startedGenerations.count
    }
}

@Suite("Enhanced Security engine extension discovery")
struct TorrentEngineExtensionIdentitySelectionTests {
    private let expectedBundleIdentifier = "app.torrent7.engine"
    private let expectedExtensionPointIdentifier = "app.torrent7.torrent-engine"

    @Test("Exactly one allowlisted identity is selected")
    func selectsExactIdentity() {
        #expect(select([expected]) == .selected("expected"))
    }

    @Test("Missing and mismatched identities fail closed")
    func rejectsMissingAndMismatchedIdentities() {
        #expect(select([]) == .unavailable)
        #expect(select([
            descriptor(
                id: "wrong-bundle",
                bundleIdentifier: "app.torrent7.other"
            )
        ]) == .unavailable)
        #expect(select([
            descriptor(
                id: "wrong-point",
                extensionPointIdentifier: "app.torrent7.other-point"
            )
        ]) == .unavailable)
    }

    @Test("Additional or duplicate identities are ambiguous")
    func rejectsAmbiguousIdentitySets() {
        #expect(select([expected, expected]) == .ambiguous)
        #expect(select([
            expected,
            descriptor(
                id: "unexpected",
                bundleIdentifier: "app.torrent7.other"
            )
        ]) == .ambiguous)
    }

    @Test("Disabled or unapproved extension state fails closed")
    func rejectsDisabledOrUnapprovedState() {
        #expect(select([expected], disabledCount: 1) == .unavailable)
        #expect(select([expected], unapprovedCount: 1) == .unavailable)
    }

    private var expected: TorrentEngineExtensionIdentityDescriptor {
        descriptor(id: "expected")
    }

    private func descriptor(
        id: String,
        bundleIdentifier: String? = nil,
        extensionPointIdentifier: String? = nil
    ) -> TorrentEngineExtensionIdentityDescriptor {
        TorrentEngineExtensionIdentityDescriptor(
            id: id,
            bundleIdentifier: bundleIdentifier ?? expectedBundleIdentifier,
            extensionPointIdentifier: extensionPointIdentifier
                ?? expectedExtensionPointIdentifier
        )
    }

    private func select(
        _ identities: [TorrentEngineExtensionIdentityDescriptor],
        disabledCount: Int = 0,
        unapprovedCount: Int = 0
    ) -> TorrentEngineExtensionIdentitySelection {
        TorrentEngineExtensionProcessCoordinator.selectIdentity(
            identities,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedExtensionPointIdentifier: expectedExtensionPointIdentifier,
            disabledCount: disabledCount,
            unapprovedCount: unapprovedCount
        )
    }
}

@Suite("Enhanced Security engine process single flight")
struct TorrentEngineProcessSingleFlightTests {
    @Test("Concurrent acquisitions share one process launch")
    func coalescesConcurrentAcquisitions() async throws {
        let processStore = TorrentEngineExtensionAcquisition<Int, ContinuousClock>(clock: ContinuousClock())
        let probe = ProcessLaunchProbe()
        let first = acquisition(processStore: processStore, probe: probe)
        await probe.waitUntilStarted(generation: 1)
        let second = acquisition(processStore: processStore, probe: probe)
        await waitForPendingAcquisitions(2, processStore: processStore)

        let launchCount = await probe.launchCount
        #expect(launchCount == 1)
        await probe.succeed(generation: 1, handle: 41)

        let firstLease = try await first.value
        let secondLease = try await second.value
        #expect(firstLease.generation == 1)
        #expect(secondLease.generation == 1)
        let firstHandle = try await processStore.perform(lease: firstLease) { $0 }
        let secondHandle = try await processStore.perform(lease: secondLease) { $0 }
        #expect(firstHandle == 41)
        #expect(secondHandle == 41)
    }

    @Test("An interrupted launch cannot replace a newer retained process")
    func rejectsStaleLaunchCompletion() async throws {
        let processStore = TorrentEngineExtensionAcquisition<Int, ContinuousClock>(clock: ContinuousClock())
        let probe = ProcessLaunchProbe()
        let stale = acquisition(processStore: processStore, probe: probe)
        await probe.waitUntilStarted(generation: 1)
        await processStore.invalidate(generation: 1)

        let replacement = acquisition(processStore: processStore, probe: probe)
        await probe.waitUntilStarted(generation: 2)
        await probe.succeed(generation: 2, handle: 42)
        let replacementLease = try await replacement.value
        #expect(replacementLease.generation == 2)
        let replacementHandle = try await processStore.perform(
            lease: replacementLease
        ) { $0 }
        #expect(replacementHandle == 42)

        await probe.succeed(generation: 1, handle: 41)
        do {
            _ = try await stale.value
            Issue.record("An interrupted process launch was unexpectedly published")
        } catch {
            #expect(error as? TorrentEngineExtensionAcquisitionError == .invalidated)
        }

        await processStore.invalidate(generation: 1)
        let retained = try await processStore.acquire(identityID: "expected") { _ in
            -1
        }
        #expect(retained.generation == 2)
        let retainedHandle = try await processStore.perform(lease: retained) { $0 }
        #expect(retainedHandle == 42)
    }

    @Test("A shared launch failure permits exactly one later retry")
    func retriesAfterSharedLaunchFailure() async throws {
        let processStore = TorrentEngineExtensionAcquisition<Int, ContinuousClock>(clock: ContinuousClock())
        let probe = ProcessLaunchProbe()
        let first = acquisition(processStore: processStore, probe: probe)
        await probe.waitUntilStarted(generation: 1)
        let second = acquisition(processStore: processStore, probe: probe)
        await waitForPendingAcquisitions(2, processStore: processStore)
        await probe.fail(generation: 1)

        for acquisition in [first, second] {
            do {
                _ = try await acquisition.value
                Issue.record("A failed process launch unexpectedly succeeded")
            } catch {
                #expect(error is ProcessLaunchProbeError)
            }
        }

        let retry = acquisition(processStore: processStore, probe: probe)
        await probe.waitUntilStarted(generation: 2)
        let launchCount = await probe.launchCount
        #expect(launchCount == 2)
        await probe.succeed(generation: 2, handle: 42)
        let retryLease = try await retry.value
        #expect(retryLease.generation == 2)
        let retryHandle = try await processStore.perform(lease: retryLease) { $0 }
        #expect(retryHandle == 42)
    }

    @Test("A superseded lease cannot use a newer process handle")
    func rejectsSupersededLease() async throws {
        let processStore = TorrentEngineExtensionAcquisition<Int, ContinuousClock>(clock: ContinuousClock())
        let probe = ProcessLaunchProbe()
        let initial = acquisition(processStore: processStore, probe: probe)
        await probe.waitUntilStarted(generation: 1)
        await probe.succeed(generation: 1, handle: 41)
        let staleLease = try await initial.value
        await processStore.invalidate(generation: 1)

        let replacement = acquisition(processStore: processStore, probe: probe)
        await probe.waitUntilStarted(generation: 2)
        await probe.succeed(generation: 2, handle: 42)
        let replacementLease = try await replacement.value

        do {
            _ = try await processStore.perform(lease: staleLease) { $0 }
            Issue.record("A superseded process lease unexpectedly remained usable")
        } catch {
            #expect(error as? TorrentEngineExtensionAcquisitionError == .invalidated)
        }
        let replacementHandle = try await processStore.perform(
            lease: replacementLease
        ) { $0 }
        #expect(replacementHandle == 42)
    }

    @Test("A canceled waiter does not consume the shared process")
    func canceledWaiterStopsBeforeHandleUse() async throws {
        let processStore = TorrentEngineExtensionAcquisition<Int, ContinuousClock>(clock: ContinuousClock())
        let probe = ProcessLaunchProbe()
        let retained = acquisition(processStore: processStore, probe: probe)
        await probe.waitUntilStarted(generation: 1)
        let canceled = acquisition(processStore: processStore, probe: probe)
        await waitForPendingAcquisitions(2, processStore: processStore)
        canceled.cancel()
        // Cancellation must finish while framework launch is still held.
        do {
            _ = try await canceled.value
            Issue.record("A canceled process waiter unexpectedly returned a lease")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await processStore.pendingAcquisitionCount == 1)
        await probe.succeed(generation: 1, handle: 41)
        let retainedLease = try await retained.value
        let launchCount = await probe.launchCount
        #expect(launchCount == 1)
        let retainedHandle = try await processStore.perform(
            lease: retainedLease
        ) { $0 }
        #expect(retainedHandle == 41)
    }

    @Test("A shared launch survives the cancellation of all current waiters")
    func launchOutlivesCanceledWaiters() async throws {
        let store = TorrentEngineExtensionAcquisition<Int, ContinuousClock>(clock: ContinuousClock())
        let probe = ProcessLaunchProbe()
        let canceled = acquisition(processStore: store, probe: probe)
        await probe.waitUntilStarted(generation: 1)
        canceled.cancel()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(await store.pendingAcquisitionCount == 0)

        let later = acquisition(processStore: store, probe: probe)
        await waitForPendingAcquisitions(1, processStore: store)
        #expect(await probe.launchCount == 1)
        await probe.succeed(generation: 1, handle: 42)
        let lease = try await later.value
        #expect(try await store.perform(lease: lease) { $0 } == 42)
    }

    @Test("Waiter deadlines expire independently without canceling shared acquisition")
    func independentWaiterDeadlines() async throws {
        let clock = ExtensionAcquisitionTestClock()
        let store = TorrentEngineExtensionAcquisition<Int, ExtensionAcquisitionTestClock>(clock: clock)
        let probe = ProcessLaunchProbe()
        let first = acquisition(
            processStore: store, probe: probe, deadline: clock.now.advanced(by: .seconds(10))
        )
        await probe.waitUntilStarted(generation: 1)
        let second = acquisition(
            processStore: store, probe: probe, deadline: clock.now.advanced(by: .seconds(20))
        )
        await clock.waitUntilSleeping(2)
        clock.advance(by: .seconds(10))
        clock.resumeDueSleepers()
        await expectRecoveryDeadline(first)
        #expect(await store.pendingAcquisitionCount == 1)
        #expect(await probe.launchCount == 1)
        await probe.succeed(generation: 1, handle: 42)
        let lease = try await second.value
        #expect(try await store.perform(lease: lease) { $0 } == 42)
        #expect(clock.pendingSleepCount == 0)
    }

    @Test("Late launch completion cannot beat an overdue timer that has not run")
    func lateLaunchCannotExtendDeadline() async throws {
        let clock = ExtensionAcquisitionTestClock()
        let store = TorrentEngineExtensionAcquisition<Int, ExtensionAcquisitionTestClock>(clock: clock)
        let probe = ProcessLaunchProbe()
        let expired = acquisition(
            processStore: store, probe: probe, deadline: clock.now.advanced(by: .seconds(10))
        )
        await probe.waitUntilStarted(generation: 1)
        await clock.waitUntilSleeping(1)
        clock.advance(by: .seconds(10))
        await probe.succeed(generation: 1, handle: 42)
        await expectRecoveryDeadline(expired)
        #expect(clock.pendingSleepCount == 0)

        let lease = try await store.acquire(identityID: "expected") { _ in
            Issue.record("The completed shared handle should have been retained")
            return -1
        }
        #expect(try await store.perform(lease: lease) { $0 } == 42)
    }

    @Test("An expired acquisition does not start framework work")
    func expiredCallerDoesNotLaunch() async {
        let clock = ExtensionAcquisitionTestClock()
        let store = TorrentEngineExtensionAcquisition<Int, ExtensionAcquisitionTestClock>(clock: clock)
        let probe = ProcessLaunchProbe()
        let expired = acquisition(processStore: store, probe: probe, deadline: clock.now)
        await expectRecoveryDeadline(expired)
        #expect(await probe.launchCount == 0)
        #expect(await store.pendingAcquisitionCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    @Test("Cancellation, deadline and launch completion resume a waiter exactly once")
    func terminalAcquisitionRace() async throws {
        for _ in 0..<32 {
            let clock = ExtensionAcquisitionTestClock()
            let store = TorrentEngineExtensionAcquisition<Int, ExtensionAcquisitionTestClock>(clock: clock)
            let probe = ProcessLaunchProbe()
            let request = acquisition(
                processStore: store, probe: probe, deadline: clock.now.advanced(by: .seconds(10))
            )
            await probe.waitUntilStarted(generation: 1)
            await clock.waitUntilSleeping(1)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { request.cancel() }
                group.addTask {
                    clock.advance(by: .seconds(10))
                    clock.resumeDueSleepers()
                }
                group.addTask { await probe.succeed(generation: 1, handle: 42) }
            }
            do {
                let lease = try await request.value
                #expect(lease.generation == 1)
            } catch is CancellationError {
                // Cancellation is a valid winner.
            } catch {
                guard case .recoveryDeadlineExceeded = error as? TorrentEngineClientError else {
                    Issue.record("Unexpected acquisition error: \(error)")
                    return
                }
            }
            let lease = try await store.acquire(identityID: "expected") { _ in
                Issue.record("A waiter outcome must not cancel the shared launch")
                return -1
            }
            #expect(try await store.perform(lease: lease) { $0 } == 42)
            #expect(clock.pendingSleepCount == 0)
        }
    }

    private func expectRecoveryDeadline<C: Clock>(
        _ request: Task<TorrentEngineExtensionAcquisition<Int, C>.Lease, any Error>
    ) async where C.Duration == Duration {
        do {
            _ = try await request.value
            Issue.record("An expired acquisition unexpectedly succeeded")
        } catch {
            guard case .recoveryDeadlineExceeded = error as? TorrentEngineClientError else {
                Issue.record("Expected the recovery deadline, received \(error)")
                return
            }
        }
    }

    private func acquisition<C: Clock>(
        processStore: TorrentEngineExtensionAcquisition<Int, C>,
        probe: ProcessLaunchProbe,
        deadline: C.Instant? = nil
    ) -> Task<TorrentEngineExtensionAcquisition<Int, C>.Lease, any Error> where C.Duration == Duration {
        Task {
            try await processStore.acquire(identityID: "expected", deadline: deadline) { generation in
                try await probe.launch(generation: generation)
            }
        }
    }

    private func waitForPendingAcquisitions<C: Clock>(
        _ expectedCount: Int,
        processStore: TorrentEngineExtensionAcquisition<Int, C>
    ) async where C.Duration == Duration {
        while await processStore.pendingAcquisitionCount < expectedCount {
            await Task.yield()
        }
    }
}
