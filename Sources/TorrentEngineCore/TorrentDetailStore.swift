import TorrentEngineModel

@safe package struct TorrentDetailStore: Sendable {
    package static let maximumEntryCount = 256
    package static let payloadBudgetBytes = 64 * 1_024 * 1_024

    private enum Kind: Int, Comparable, Sendable {
        case trackers
        case webSeeds
        case webSeedActivity
        case peerSources
        case files
        case pieceMap

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private struct Key: Hashable, Sendable {
        let kind: Kind
        let torrentID: String
    }

    private enum Value: Equatable, Sendable {
        case trackers([TorrentTrackerItem])
        case webSeeds([TorrentWebSeedItem])
        case webSeedActivity(TorrentWebSeedActivity)
        case peerSources(TorrentPeerSources)
        case files([TorrentFileItem])
        case pieceMap(TorrentPieceMap)

        var kind: Kind {
            switch self {
            case .trackers: .trackers
            case .webSeeds: .webSeeds
            case .webSeedActivity: .webSeedActivity
            case .peerSources: .peerSources
            case .files: .files
            case .pieceMap: .pieceMap
            }
        }
    }

    private struct Entry: Sendable {
        var value: Value
        var revision: UInt64
        var payloadBytes: Int
        var lastAccess: UInt64
    }

    package private(set) var entryCount = 0
    package private(set) var payloadBytes = 0
    private var entries = [Key: Entry]()
    private var nextRevision: UInt64 = 1
    private var nextAccess: UInt64 = 1

    package mutating func trackerBatch(
        id: String,
        trackers: [TorrentTrackerItem],
        ifChangedSince previousRevision: UInt64?
    ) -> TorrentTrackerBatch? {
        guard let entry = reconcile(id: id, value: .trackers(trackers)) else {
            return nil
        }
        guard previousRevision != entry.revision else {
            return nil
        }
        return TorrentTrackerBatch(revision: entry.revision, trackers: trackers)
    }

    package mutating func webSeedBatch(
        id: String,
        webSeeds: [TorrentWebSeedItem],
        ifChangedSince previousRevision: UInt64?
    ) -> TorrentWebSeedBatch? {
        guard let entry = reconcile(id: id, value: .webSeeds(webSeeds)) else {
            return nil
        }
        guard previousRevision != entry.revision else {
            return nil
        }
        return TorrentWebSeedBatch(revision: entry.revision, webSeeds: webSeeds)
    }

    package mutating func webSeedActivity(
        id: String,
        activity: TorrentWebSeedActivity
    ) -> TorrentWebSeedActivity? {
        guard reconcile(id: id, value: .webSeedActivity(activity)) != nil else {
            return nil
        }
        return activity
    }

    package mutating func peerSources(
        id: String,
        sources: TorrentPeerSources
    ) -> TorrentPeerSources? {
        guard reconcile(id: id, value: .peerSources(sources)) != nil else {
            return nil
        }
        return sources
    }

    package mutating func fileBatch(
        id: String,
        files: [TorrentFileItem],
        ifChangedSince previousRevision: UInt64?
    ) -> TorrentFileBatch? {
        guard let entry = reconcile(id: id, value: .files(files)) else {
            return nil
        }
        guard previousRevision != entry.revision else {
            return nil
        }
        return TorrentFileBatch(revision: entry.revision, files: files)
    }

    package mutating func pieceMapBatch(
        id: String,
        pieceMap: TorrentPieceMap,
        ifChangedSince previousRevision: UInt64?
    ) -> TorrentPieceMapBatch? {
        guard let entry = reconcile(id: id, value: .pieceMap(pieceMap)) else {
            return nil
        }
        guard previousRevision != entry.revision else {
            return nil
        }
        return TorrentPieceMapBatch(revision: entry.revision, pieceMap: pieceMap)
    }

    package mutating func retainTorrentIDs(_ retainedIDs: Set<String>) {
        let removedKeys = entries.keys.filter { !retainedIDs.contains($0.torrentID) }
        for key in removedKeys {
            removeValue(forKey: key)
        }
    }

    private mutating func reconcile(id: String, value: Value) -> Entry? {
        guard !id.isEmpty else {
            return nil
        }
        let key = Key(kind: value.kind, torrentID: id)
        let cost = Self.estimatedPayloadBytes(for: value)
        guard cost <= Self.payloadBudgetBytes else {
            return nil
        }

        if var existing = entries[key], existing.value == value {
            existing.lastAccess = takeAccessSequence()
            entries[key] = existing
            return existing
        }

        evictIfNeeded(inserting: key, newPayloadBytes: cost)
        let previousCost = entries[key]?.payloadBytes ?? 0
        guard payloadBytes >= previousCost else {
            return nil
        }
        let basePayload = payloadBytes - previousCost
        guard entries[key] != nil || entries.count < Self.maximumEntryCount,
              basePayload <= Self.payloadBudgetBytes - cost,
              nextRevision < UInt64.max else {
            return nil
        }

        let entry = Entry(
            value: value,
            revision: nextRevision,
            payloadBytes: cost,
            lastAccess: takeAccessSequence()
        )
        nextRevision += 1
        entries[key] = entry
        payloadBytes = basePayload + cost
        entryCount = entries.count
        return entry
    }

    private mutating func evictIfNeeded(
        inserting key: Key,
        newPayloadBytes: Int
    ) {
        while true {
            let replacedPayloadBytes = entries[key]?.payloadBytes ?? 0
            guard payloadBytes >= replacedPayloadBytes else {
                return
            }
            let basePayloadBytes = payloadBytes - replacedPayloadBytes
            let entryLimitExceeded = entries[key] == nil
                && entries.count >= Self.maximumEntryCount
            let payloadLimitExceeded = basePayloadBytes
                > Self.payloadBudgetBytes - newPayloadBytes
            guard entryLimitExceeded || payloadLimitExceeded else {
                return
            }
            guard let victim = entries
                .filter({ $0.key != key })
                .min(by: { lhs, rhs in
                    if lhs.value.lastAccess != rhs.value.lastAccess {
                        return lhs.value.lastAccess < rhs.value.lastAccess
                    }
                    if lhs.key.kind != rhs.key.kind {
                        return lhs.key.kind < rhs.key.kind
                    }
                    return lhs.key.torrentID < rhs.key.torrentID
                })?.key else {
                return
            }
            removeValue(forKey: victim)
        }
    }

    private mutating func removeValue(forKey key: Key) {
        guard let removed = entries.removeValue(forKey: key) else {
            return
        }
        payloadBytes -= removed.payloadBytes
        entryCount = entries.count
    }

    private mutating func takeAccessSequence() -> UInt64 {
        if nextAccess == UInt64.max {
            compactAccessSequences()
        }
        let sequence = nextAccess
        nextAccess += 1
        return sequence
    }

    private mutating func compactAccessSequences() {
        let orderedKeys = entries.sorted { lhs, rhs in
            if lhs.value.lastAccess != rhs.value.lastAccess {
                return lhs.value.lastAccess < rhs.value.lastAccess
            }
            if lhs.key.kind != rhs.key.kind {
                return lhs.key.kind < rhs.key.kind
            }
            return lhs.key.torrentID < rhs.key.torrentID
        }.map(\.key)

        nextAccess = 1
        for key in orderedKeys {
            guard var entry = entries[key] else {
                continue
            }
            entry.lastAccess = nextAccess
            entries[key] = entry
            nextAccess += 1
        }
    }

    private static func estimatedPayloadBytes(for value: Value) -> Int {
        switch value {
        case .trackers(let trackers):
            trackers.reduce(saturatingMultiply(MemoryLayout<TorrentTrackerItem>.stride, trackers.count)) {
                saturatingAdd($0, saturatingAdd($1.url.utf8.count, $1.message.utf8.count))
            }
        case .webSeeds(let webSeeds):
            webSeeds.reduce(saturatingMultiply(MemoryLayout<TorrentWebSeedItem>.stride, webSeeds.count)) {
                saturatingAdd($0, $1.url.utf8.count)
            }
        case .webSeedActivity:
            MemoryLayout<TorrentWebSeedActivity>.stride
        case .peerSources:
            MemoryLayout<TorrentPeerSources>.stride
        case .files(let files):
            files.reduce(saturatingMultiply(MemoryLayout<TorrentFileItem>.stride, files.count)) {
                saturatingAdd($0, $1.path.utf8.count)
            }
        case .pieceMap(let pieceMap):
            saturatingAdd(
                MemoryLayout<TorrentPieceMap>.stride,
                saturatingMultiply(pieceMap.pieces.count, 5)
            )
        }
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : result
    }

    private static func saturatingMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : result
    }
}
