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

    func launch(generation: UInt64) async throws -> Int {
        startedGenerations.append(generation)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[generation] = continuation
        }
    }

    func waitUntilStarted(generation: UInt64) async {
        while continuations[generation] == nil {
            await Task.yield()
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
        let processStore = TorrentEngineProcessSingleFlight<Int>()
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
        let processStore = TorrentEngineProcessSingleFlight<Int>()
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
            #expect(error as? TorrentEngineProcessLaunchError == .invalidated)
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
        let processStore = TorrentEngineProcessSingleFlight<Int>()
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
        let processStore = TorrentEngineProcessSingleFlight<Int>()
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
            #expect(error as? TorrentEngineProcessLaunchError == .invalidated)
        }
        let replacementHandle = try await processStore.perform(
            lease: replacementLease
        ) { $0 }
        #expect(replacementHandle == 42)
    }

    @Test("A canceled waiter does not consume the shared process")
    func canceledWaiterStopsBeforeHandleUse() async throws {
        let processStore = TorrentEngineProcessSingleFlight<Int>()
        let probe = ProcessLaunchProbe()
        let retained = acquisition(processStore: processStore, probe: probe)
        await probe.waitUntilStarted(generation: 1)
        let canceled = acquisition(processStore: processStore, probe: probe)
        await waitForPendingAcquisitions(2, processStore: processStore)
        canceled.cancel()
        await probe.succeed(generation: 1, handle: 41)

        let retainedLease = try await retained.value
        do {
            _ = try await canceled.value
            Issue.record("A canceled process waiter unexpectedly returned a lease")
        } catch {
            #expect(error is CancellationError)
        }
        let launchCount = await probe.launchCount
        #expect(launchCount == 1)
        let retainedHandle = try await processStore.perform(
            lease: retainedLease
        ) { $0 }
        #expect(retainedHandle == 41)
    }

    private func acquisition(
        processStore: TorrentEngineProcessSingleFlight<Int>,
        probe: ProcessLaunchProbe
    ) -> Task<TorrentEngineProcessSingleFlight<Int>.Lease, any Error> {
        Task {
            try await processStore.acquire(identityID: "expected") { generation in
                try await probe.launch(generation: generation)
            }
        }
    }

    private func waitForPendingAcquisitions(
        _ expectedCount: Int,
        processStore: TorrentEngineProcessSingleFlight<Int>
    ) async {
        while await processStore.pendingAcquisitionCount < expectedCount {
            await Task.yield()
        }
    }
}
