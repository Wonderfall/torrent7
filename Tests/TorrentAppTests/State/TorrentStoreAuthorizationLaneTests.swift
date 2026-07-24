import Testing
@testable import TorrentApp

@MainActor
@Suite("Torrent store authorization lane")
struct TorrentStoreAuthorizationLaneTests {
    @Test("Cancelling a waiter removes it without releasing the current owner")
    func cancellingWaiterPreservesCurrentOwner() async throws {
        let lane = TorrentStoreAuthorizationLane()
        try await lane.acquire()

        let waiter = Task { @MainActor in
            do {
                try await lane.acquire()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await waitForWaiter(in: lane)

        waiter.cancel()

        #expect(await waiter.value)
        #expect(lane.waitingCount == 0)
        #expect(lane.isHeld)

        lane.release()
        #expect(!lane.isHeld)
    }

    @Test("Releasing the lane transfers ownership to the next waiter")
    func releaseTransfersOwnership() async throws {
        let lane = TorrentStoreAuthorizationLane()
        try await lane.acquire()

        let waiter = Task { @MainActor in
            do {
                try await lane.acquire()
                lane.release()
                return true
            } catch {
                return false
            }
        }
        await waitForWaiter(in: lane)

        lane.release()

        #expect(await waiter.value)
        #expect(!lane.isHeld)
        #expect(lane.waitingCount == 0)
    }

    private func waitForWaiter(in lane: TorrentStoreAuthorizationLane) async {
        for _ in 0..<20 where lane.waitingCount == 0 {
            await Task.yield()
        }
        #expect(lane.waitingCount == 1)
    }
}
