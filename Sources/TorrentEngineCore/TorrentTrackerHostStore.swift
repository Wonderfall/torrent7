package import TorrentEngineModel

@safe package struct TorrentTrackerHostStore: Sendable {
    package private(set) var revision: UInt64 = 0
    package private(set) var isInitialized = false
    private var hosts = [TorrentTrackerHostItem]()

    package mutating func reconcile(
        _ incoming: [TorrentTrackerHostItem],
        torrentIDs: Set<TorrentItem.ID>
    ) -> TorrentSnapshotStore.Reconciliation {
        guard incoming.count <= TorrentEngineLimits.maximumTrackerHostRowCount else {
            return .rejected
        }

        var uniqueHosts = Set<TorrentTrackerHostItem>(minimumCapacity: incoming.count)
        for host in incoming {
            guard !host.torrentID.isEmpty,
                  !host.host.isEmpty,
                  torrentIDs.contains(host.torrentID),
                  uniqueHosts.insert(host).inserted else {
                return .rejected
            }
        }
        let orderedHosts = uniqueHosts.sorted {
            if $0.torrentID != $1.torrentID {
                return $0.torrentID < $1.torrentID
            }
            return $0.host < $1.host
        }

        guard orderedHosts != hosts else {
            isInitialized = true
            return .unchanged
        }
        guard revision < UInt64.max else {
            return .rejected
        }

        hosts = orderedHosts
        isInitialized = true
        revision += 1
        return .updated
    }

    package func batch() -> TorrentTrackerHostBatch {
        TorrentTrackerHostBatch(revision: revision, hosts: hosts)
    }
}
