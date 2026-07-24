import Foundation

@MainActor
final class TorrentStoreAuthorizationLane {
    private enum Acquisition {
        case acquired
        case cancelled
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Acquisition, Never>
    }

    private(set) var isHeld = false
    private var waiters = [Waiter]()

    var waitingCount: Int {
        waiters.count
    }

    func acquire() async throws {
        try Task.checkCancellation()

        guard isHeld else {
            isHeld = true
            do {
                try Task.checkCancellation()
            } catch {
                release()
                throw error
            }
            return
        }

        let waiterID = UUID()
        let acquisition: Acquisition = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Acquisition, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [self] in
                cancelWaiter(id: waiterID)
            }
        }

        guard case .acquired = acquisition else {
            throw CancellationError()
        }
        do {
            try Task.checkCancellation()
        } catch {
            release()
            throw error
        }
    }

    func release() {
        precondition(isHeld)
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume(returning: .acquired)
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: .cancelled)
    }
}
