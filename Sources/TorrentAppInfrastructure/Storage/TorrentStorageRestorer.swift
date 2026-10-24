package import Foundation
import TorrentEngineIPC
package import TorrentStorageAuthority

package enum TorrentStorageRestorationError: LocalizedError, Equatable {
    case deadlineExceeded

    package var errorDescription: String? {
        "Saved payload verification exceeded its startup time budget. Check the download storage and reopen Torrent 7."
    }
}

package struct TorrentStorageRestoration: Sendable {
    package let registry: TorrentStorageBrokerRegistry
    package let parents: [TorrentStorageParentID: TorrentStorageParentAuthority]
}

package struct TorrentStorageRestorer: Sendable {
    private let maximumDuration: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    // Near-journal-limit verification reached 105 seconds on local APFS.
    // Five minutes leaves about 2.9x measured headroom; see
    // Documentation/StorageRestorationBenchmark.md for the workload and limits.
    package init(
        maximumDuration: Duration = .seconds(300),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        precondition(maximumDuration >= .zero)
        self.maximumDuration = maximumDuration
        self.now = now
    }

    /// The caller owns and awaits this operation. The budget covers the whole
    /// scan, including parent validation, and is checked between filesystem
    /// calls. It cannot interrupt a kernel call already in progress. Nothing
    /// is published on cancellation or expiry; the private registry releases
    /// its descriptors and access leases when this operation unwinds.
    @concurrent
    package func restore(
        leases: [DownloadFolderAccessLease],
        claims: [TorrentStorageClaim]
    ) async throws -> TorrentStorageRestoration {
        let deadline = now().advanced(by: maximumDuration)
        func checkInterruption() throws {
            try Task.checkCancellation()
            guard now() < deadline else {
                throw TorrentStorageRestorationError.deadlineExceeded
            }
        }

        let registry = TorrentStorageBrokerRegistry()
        var parents = [TorrentStorageParentID: TorrentStorageParentAuthority]()
        for lease in leases {
            try checkInterruption()
            if let parent = try? TorrentStorageParentAuthority(lease: lease) {
                parents[parent.id] = parent
            }
            try checkInterruption()
        }

        let planner = TorrentStorageDestinationPlanner()
        for claim in claims {
            try checkInterruption()
            guard claim.lease.state == .active,
                  let parent = parents[claim.manifest.parentID] else {
                continue
            }
            do {
                try planner.validateClaimRoot(claim, in: parent)
                try checkInterruption()
                try registry.install(claim: claim, parent: parent)
                let files = claim.manifest.logicalFiles
                for start in stride(
                    from: 0, to: files.count,
                    by: TorrentStorageBrokerProtocol.maximumStatBatchCount
                ) {
                    try checkInterruption()
                    let end = min(
                        files.count,
                        start + TorrentStorageBrokerProtocol.maximumStatBatchCount
                    )
                    _ = try registry.statBatch(
                        claimID: claim.manifest.claimID,
                        generation: claim.manifest.generation,
                        fileIndices: files[start..<end].map(\.index),
                        checkInterruption: checkInterruption
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TorrentStorageRestorationError {
                throw error
            } catch {
                // An interrupted scan is not evidence of an invalid claim.
                // Abort the entire restoration before removing any authority.
                try checkInterruption()
                try registry.removeClaim(
                    claimID: claim.manifest.claimID,
                    generation: claim.manifest.generation
                )
            }
        }
        try checkInterruption()
        return TorrentStorageRestoration(registry: registry, parents: parents)
    }
}
