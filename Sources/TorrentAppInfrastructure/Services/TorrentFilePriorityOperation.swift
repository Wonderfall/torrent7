import Synchronization
package import TorrentEngineModel
import TorrentStorageAuthority

/// The store's FIFO owns the batch and cleanup. Cancellation reaches the native
/// operation without abandoning provisional grants or cancelling the shared queue.
package final class TorrentFilePriorityOperation: Sendable {
    private let torrentID: String
    private let priorities: [Int32: TorrentFilePriority]
    private let cancelled = Mutex(false)

    package init(torrentID: String, priorities: [Int32: TorrentFilePriority]) {
        self.torrentID = torrentID
        self.priorities = priorities
    }

    package func cancel() {
        cancelled.withLock { $0 = true }
    }

    @concurrent
    package func apply(
        engine: any TorrentEngineServicing,
        journal: TorrentStorageClaimJournal?,
        registry: TorrentStorageBrokerRegistry
    ) async throws {
        try checkCancellation()
        guard priorities.count <= TorrentEngineLimits.maximumFileCount,
              priorities.keys.allSatisfy({
                  (0..<Int32(TorrentEngineLimits.maximumFileCount)).contains($0)
              }) else {
            throw TorrentStorageBrokerRegistryError.fileUnavailable
        }
        guard !priorities.isEmpty else { return }
        let changes = priorities.sorted { $0.key < $1.key }
        let claims = await journal?.allClaims().filter {
            $0.torrentID == torrentID && $0.lease.state == .active
        } ?? []
        guard claims.count <= 1 else { throw TorrentStorageJournalError.corrupt }
        guard let journal, var claim = claims.first else {
            try await engine.setFilePriorities(
                id: torrentID, priorities: priorities,
                isCancelled: { self.cancelled.withLock { $0 } }
            )
            try checkCancellation()
            return
        }
        guard changes.allSatisfy({ index, _ in
            claim.manifest.logicalFiles.indices.contains(Int(index))
                && claim.lease.fileAvailability.indices.contains(Int(index))
                && !claim.manifest.logicalFiles[Int(index)].isPadding
        }) else {
            throw TorrentStorageBrokerRegistryError.fileUnavailable
        }

        var confirmedAvailability = claim.lease.fileAvailability
        var grantedAvailability = confirmedAvailability
        for (index, priority) in changes where priority != .skip {
            grantedAvailability[Int(index)] = true
        }
        try checkCancellation()
        // Authorize all increases before sending any engine commands, with one
        // durable journal update regardless of the number of descendant files.
        claim = try await replaceAvailability(
            grantedAvailability, claim: claim, journal: journal, registry: registry, engine: engine
        )

        var failure: (any Error)?
        do {
            try await engine.setFilePriorities(
                id: torrentID, priorities: priorities,
                isCancelled: { self.cancelled.withLock { $0 } }
            )
            for (index, priority) in changes {
                confirmedAvailability[Int(index)] = priority != .skip
            }
            try checkCancellation()
        } catch {
            failure = error
        }
        // Skips become restrictive only after native handle release is confirmed.
        // A committed batch remains authoritative even if its caller cancelled.
        // A rejected batch revokes every provisional increase before advancing.
        _ = try await replaceAvailability(
            confirmedAvailability, claim: claim, journal: journal, registry: registry, engine: engine
        )
        if let failure { throw failure }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled.withLock({ $0 }) { throw CancellationError() }
    }

    private func replaceAvailability(
        _ availability: [Bool],
        claim: TorrentStorageClaim,
        journal: TorrentStorageClaimJournal,
        registry: TorrentStorageBrokerRegistry,
        engine: any TorrentEngineServicing
    ) async throws -> TorrentStorageClaim {
        guard availability != claim.lease.fileAvailability else { return claim }
        do {
            let updated = try await journal.replaceAvailability(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation,
                expectedAvailabilityRevision: claim.lease.availabilityRevision,
                fileAvailability: availability
            )
            try registry.replace(claim: updated)
            return updated
        } catch {
            // A failed durable update cannot leave a live engine using broader
            // authority than the completed commands. Recovery requires a restart.
            await engine.terminateConnection(recoveryDisposition: .terminal)
            try registry.removeClaim(
                claimID: claim.manifest.claimID, generation: claim.manifest.generation
            )
            throw error
        }
    }
}
