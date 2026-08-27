import TorrentEngineModel

@safe package struct TorrentQueueStore: Sendable {
    package enum Reconciliation: Equatable, Sendable {
        case unchanged
        case updated
        case rejected
    }

    package struct Placement: Equatable, Sendable {
        package let id: TorrentItem.ID
        package let priority: TorrentQueuePriority
    }

    private struct Entry: Equatable, Sendable {
        var priority: TorrentQueuePriority
        var rank: Int
    }

    package private(set) var isInitialized = false
    private var entriesByID = [TorrentItem.ID: Entry]()

    package var placements: [Placement] {
        orderedIDs.map { id in
            Placement(id: id, priority: entriesByID[id]?.priority ?? .normal)
        }
    }

    package mutating func reconcile(_ torrents: [TorrentItem]) -> Reconciliation {
        guard torrents.count <= TorrentEngineLimits.maximumTorrentSnapshotCount else {
            return .rejected
        }

        let ids = Set(torrents.map(\.id))
        guard ids.count == torrents.count, !ids.contains("") else {
            return .rejected
        }

        let previous = entriesByID
        entriesByID = entriesByID.filter { ids.contains($0.key) }

        let nativeOrder = torrents.sorted { left, right in
            let leftIsQueued = left.queuePosition >= 0
            let rightIsQueued = right.queuePosition >= 0
            if leftIsQueued != rightIsQueued {
                return leftIsQueued
            }
            if leftIsQueued, left.queuePosition != right.queuePosition {
                return left.queuePosition < right.queuePosition
            }
            return left.id < right.id
        }
        for torrent in nativeOrder where entriesByID[torrent.id] == nil {
            entriesByID[torrent.id] = Entry(
                priority: torrent.queuePriority,
                rank: nextRank(for: torrent.queuePriority)
            )
        }

        normalizeRanks()
        isInitialized = true
        return entriesByID == previous ? .unchanged : .updated
    }

    package func priority(for id: TorrentItem.ID) -> TorrentQueuePriority? {
        entriesByID[id]?.priority
    }

    package mutating func setPriority(
        _ priority: TorrentQueuePriority,
        for id: TorrentItem.ID
    ) -> Bool {
        guard var entry = entriesByID[id], entry.priority != priority else {
            return false
        }
        entry.priority = priority
        entry.rank = nextRank(for: priority)
        entriesByID[id] = entry
        normalizeRanks()
        return true
    }

    package mutating func move(_ id: TorrentItem.ID, by move: TorrentQueueMove) -> Bool {
        guard let selected = entriesByID[id] else {
            return false
        }

        var group = orderedIDs.filter { entriesByID[$0]?.priority == selected.priority }
        guard let sourceIndex = group.firstIndex(of: id) else {
            return false
        }

        let destinationIndex: Int
        switch move {
        case .top:
            destinationIndex = 0
        case .up:
            destinationIndex = max(0, sourceIndex - 1)
        case .down:
            destinationIndex = min(group.count - 1, sourceIndex + 1)
        case .bottom:
            destinationIndex = group.count - 1
        }
        guard destinationIndex != sourceIndex else {
            return false
        }

        let moved = group.remove(at: sourceIndex)
        group.insert(moved, at: destinationIndex)
        for (rank, entryID) in group.enumerated() {
            entriesByID[entryID]?.rank = rank
        }
        return true
    }

    private var orderedIDs: [TorrentItem.ID] {
        entriesByID.keys.sorted { leftID, rightID in
            guard let left = entriesByID[leftID], let right = entriesByID[rightID] else {
                return leftID < rightID
            }
            let leftPriority = Self.priorityRank(left.priority)
            let rightPriority = Self.priorityRank(right.priority)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            if left.rank != right.rank {
                return left.rank < right.rank
            }
            return leftID < rightID
        }
    }

    private func nextRank(for priority: TorrentQueuePriority) -> Int {
        entriesByID.values
            .lazy
            .filter { $0.priority == priority }
            .map(\.rank)
            .max()
            .map { $0 + 1 } ?? 0
    }

    private mutating func normalizeRanks() {
        for priority in TorrentQueuePriority.allCases {
            let group = orderedIDs.filter { entriesByID[$0]?.priority == priority }
            for (rank, id) in group.enumerated() {
                entriesByID[id]?.rank = rank
            }
        }
    }

    private static func priorityRank(_ priority: TorrentQueuePriority) -> Int {
        switch priority {
        case .high:
            0
        case .normal:
            1
        case .low:
            2
        }
    }
}
