import TorrentEngineModel

@safe package struct TorrentSnapshotStore: Sendable {
    private struct Presentation: Equatable, Sendable {
        let comment: String
        let createdTime: Int64
    }

    package enum Reconciliation: Equatable, Sendable {
        case unchanged
        case updated
        case rejected
    }

    package private(set) var revision: UInt64 = 0
    package private(set) var isInitialized = false
    private var torrentsByID = [TorrentItem.ID: TorrentItem]()
    private var presentationByID = [TorrentItem.ID: Presentation]()

    package var torrents: [TorrentItem] {
        torrentsByID
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    package var torrentIDs: Set<TorrentItem.ID> {
        Set(torrentsByID.keys)
    }

    package mutating func registerPresentation(
        id: TorrentItem.ID,
        comment: String,
        createdTime: Int64
    ) -> Bool {
        guard !id.isEmpty, createdTime >= 0 else {
            return false
        }
        guard !comment.isEmpty || createdTime != 0 else {
            presentationByID.removeValue(forKey: id)
            return true
        }
        presentationByID[id] = Presentation(
            comment: comment,
            createdTime: createdTime
        )
        return true
    }

    package mutating func reconcile(_ torrents: [TorrentItem]) -> Reconciliation {
        guard torrents.count <= TorrentEngineLimits.maximumTorrentSnapshotCount else {
            return .rejected
        }

        var nextByID = [TorrentItem.ID: TorrentItem](minimumCapacity: torrents.count)
        for torrent in torrents {
            let presentedTorrent = if let presentation = presentationByID[torrent.id] {
                torrent.replacingPresentation(
                    comment: presentation.comment,
                    createdTime: presentation.createdTime
                )
            } else {
                torrent
            }
            guard !torrent.id.isEmpty,
                  nextByID.updateValue(presentedTorrent, forKey: torrent.id) == nil else {
                return .rejected
            }
        }

        let retainedPresentation = presentationByID.isEmpty
            ? presentationByID
            : presentationByID.filter { nextByID[$0.key] != nil }

        guard nextByID != torrentsByID else {
            presentationByID = retainedPresentation
            isInitialized = true
            return .unchanged
        }
        guard revision < UInt64.max else {
            return .rejected
        }

        torrentsByID = nextByID
        presentationByID = retainedPresentation
        isInitialized = true
        revision += 1
        return .updated
    }

    package func batch(ifChangedSince previousRevision: UInt64?) -> TorrentSnapshotBatch? {
        guard previousRevision != revision else {
            return nil
        }
        return TorrentSnapshotBatch(revision: revision, torrents: torrents)
    }
}
