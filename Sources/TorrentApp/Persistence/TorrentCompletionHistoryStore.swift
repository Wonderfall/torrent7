import Foundation
import TorrentEngineModel

struct TorrentCompletionClaim: Sendable {
    let id: UUID
    let candidates: [TorrentCompletionCandidate]
}

protocol TorrentCompletionHistoryStoring: Actor {
    func contains(_ id: TorrentItem.ID) async throws -> Bool
    func claimNewlyCompleted(
        from candidates: [TorrentCompletionCandidate]
    ) async throws -> TorrentCompletionClaim
    func finalizeCompletionClaim(
        _ id: UUID,
        remembering completedIDs: Set<TorrentItem.ID>
    )
    func abandonCompletionClaim(_ id: UUID)
    func remember(_ ids: Set<TorrentItem.ID>) async throws
    func forget(_ ids: Set<TorrentItem.ID>) async throws
    func prune(retaining activeIDs: Set<TorrentItem.ID>) async throws
}

actor TorrentCompletionHistoryStore: TorrentCompletionHistoryStoring {
    private let suiteName: String?
    private var defaults: UserDefaults?
    private var completedIDs: Set<TorrentItem.ID>?
    private var reservedIDs = Set<TorrentItem.ID>()
    private var reservedIDsByClaim = [UUID: Set<TorrentItem.ID>]()

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    func contains(_ id: TorrentItem.ID) async throws -> Bool {
        try Task.checkCancellation()
        return try loadCompletedIDs().contains(id)
    }

    func claimNewlyCompleted(
        from candidates: [TorrentCompletionCandidate]
    ) async throws -> TorrentCompletionClaim {
        let knownIDs = try loadCompletedIDs()
        var newlyCompleted = [TorrentCompletionCandidate]()
        newlyCompleted.reserveCapacity(candidates.count)
        var claimedIDs = Set<TorrentItem.ID>()
        claimedIDs.reserveCapacity(candidates.count)
        for (offset, candidate) in candidates.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if !knownIDs.contains(candidate.id),
               !reservedIDs.contains(candidate.id),
               claimedIDs.insert(candidate.id).inserted {
                newlyCompleted.append(candidate)
            }
        }
        try Task.checkCancellation()

        let claimID = UUID()
        reservedIDs.formUnion(claimedIDs)
        reservedIDsByClaim[claimID] = claimedIDs
        return TorrentCompletionClaim(
            id: claimID,
            candidates: newlyCompleted
        )
    }

    func finalizeCompletionClaim(
        _ id: UUID,
        remembering completedIDs: Set<TorrentItem.ID>
    ) {
        releaseCompletionClaim(id)
        rememberAfterPublication(completedIDs)
    }

    func abandonCompletionClaim(_ id: UUID) {
        releaseCompletionClaim(id)
    }

    func remember(_ ids: Set<TorrentItem.ID>) async throws {
        try rememberSynchronously(ids)
    }

    private func rememberSynchronously(_ ids: Set<TorrentItem.ID>) throws {
        try Task.checkCancellation()
        guard !ids.isEmpty else {
            return
        }

        let currentIDs = try loadCompletedIDs()
        var updatedIDs = currentIDs
        for (offset, id) in ids.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            updatedIDs.insert(id)
        }
        guard updatedIDs != currentIDs else {
            return
        }

        try commit(updatedIDs)
    }

    private func rememberAfterPublication(_ ids: Set<TorrentItem.ID>) {
        guard !ids.isEmpty else {
            return
        }

        // A successful claim has already crossed its publication boundary.
        // Finish this small persistence transaction even if its caller is
        // canceled while waiting for the actor hop.
        let currentIDs = completedIDs ?? loadCompletedIDsWithoutCancellation()
        let updatedIDs = currentIDs.union(ids)
        guard updatedIDs != currentIDs else {
            return
        }

        commitWithoutCancellation(updatedIDs)
    }

    func forget(_ ids: Set<TorrentItem.ID>) async throws {
        try Task.checkCancellation()
        guard !ids.isEmpty else {
            return
        }

        let currentIDs = try loadCompletedIDs()
        var updatedIDs = currentIDs
        for (offset, id) in ids.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            updatedIDs.remove(id)
        }
        guard updatedIDs != currentIDs else {
            return
        }

        try commit(updatedIDs)
    }

    func prune(retaining activeIDs: Set<TorrentItem.ID>) async throws {
        let currentIDs = try loadCompletedIDs()
        var updatedIDs = Set<TorrentItem.ID>()
        updatedIDs.reserveCapacity(min(currentIDs.count, activeIDs.count))
        for (offset, id) in currentIDs.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if activeIDs.contains(id) {
                updatedIDs.insert(id)
            }
        }
        guard updatedIDs != currentIDs else {
            return
        }

        try commit(updatedIDs)
    }

    private func loadCompletedIDs() throws -> Set<TorrentItem.ID> {
        if let completedIDs {
            return completedIDs
        }
        let storedIDs =
            userDefaults.stringArray(forKey: TorrentCompletionKeys.completedTorrentIDs) ?? []
        var loadedIDs = Set<TorrentItem.ID>()
        loadedIDs.reserveCapacity(storedIDs.count)
        for (offset, id) in storedIDs.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            loadedIDs.insert(id)
        }
        try Task.checkCancellation()
        completedIDs = loadedIDs
        return loadedIDs
    }

    private func loadCompletedIDsWithoutCancellation() -> Set<TorrentItem.ID> {
        if let completedIDs {
            return completedIDs
        }
        let storedIDs =
            userDefaults.stringArray(forKey: TorrentCompletionKeys.completedTorrentIDs) ?? []
        let loadedIDs = Set(storedIDs)
        completedIDs = loadedIDs
        return loadedIDs
    }

    private func commit(_ updatedIDs: Set<TorrentItem.ID>) throws {
        let sortedIDs: [TorrentItem.ID]?
        if updatedIDs.isEmpty {
            sortedIDs = nil
        } else {
            sortedIDs = updatedIDs.sorted()
        }
        try Task.checkCancellation()

        if let sortedIDs {
            userDefaults.set(
                sortedIDs,
                forKey: TorrentCompletionKeys.completedTorrentIDs
            )
        } else {
            userDefaults.removeObject(forKey: TorrentCompletionKeys.completedTorrentIDs)
        }
        completedIDs = updatedIDs
    }

    private func commitWithoutCancellation(_ updatedIDs: Set<TorrentItem.ID>) {
        let sortedIDs = updatedIDs.isEmpty ? nil : updatedIDs.sorted()
        if let sortedIDs {
            userDefaults.set(
                sortedIDs,
                forKey: TorrentCompletionKeys.completedTorrentIDs
            )
        } else {
            userDefaults.removeObject(
                forKey: TorrentCompletionKeys.completedTorrentIDs
            )
        }
        completedIDs = updatedIDs
    }

    private func releaseCompletionClaim(_ id: UUID) {
        guard let claimedIDs = reservedIDsByClaim.removeValue(forKey: id) else {
            return
        }
        reservedIDs.subtract(claimedIDs)
    }

    private var userDefaults: UserDefaults {
        if let defaults {
            return defaults
        }
        let createdDefaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        defaults = createdDefaults
        return createdDefaults
    }
}
