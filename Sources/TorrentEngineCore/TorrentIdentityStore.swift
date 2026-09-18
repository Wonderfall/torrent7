import Foundation
package import TorrentEngineModel

@safe package struct TorrentIdentityStore: Sendable {
    package struct NativeSnapshot: Sendable {
        package let nativeToken: UInt64
        package let torrent: TorrentItem
    }

    package enum Reconciliation: Equatable, Sendable {
        case unchanged
        case updated
        case rejected
    }

    private enum State: Equatable, Sendable {
        case active
        case removalRequested
    }

    private struct Entry: Equatable, Sendable {
        let nativeToken: UInt64
        let generation: UInt64
        var state: State
    }

    private var entriesByID = [TorrentItem.ID: Entry]()
    private var idByNativeToken = [UInt64: TorrentItem.ID]()
    private var nextGeneration: UInt64 = 1
    package private(set) var isInitialized = false

    package mutating func registerAddedTorrent(
        id: TorrentItem.ID,
        nativeToken: UInt64
    ) -> Bool {
        guard Self.isCanonicalID(id), nativeToken != 0 else {
            return false
        }
        if let existing = entriesByID[id] {
            return existing.nativeToken == nativeToken && existing.state == .active
        }
        guard idByNativeToken[nativeToken] == nil,
              let generation = allocateGeneration() else {
            return false
        }
        entriesByID[id] = Entry(
            nativeToken: nativeToken,
            generation: generation,
            state: .active
        )
        idByNativeToken[nativeToken] = id
        return true
    }

    package mutating func reconcile(
        _ snapshots: [NativeSnapshot]
    ) -> Reconciliation {
        guard snapshots.count <= TorrentEngineLimits.maximumTorrentSnapshotCount else {
            return .rejected
        }

        var snapshotsByID = [TorrentItem.ID: NativeSnapshot](minimumCapacity: snapshots.count)
        var snapshotIDByToken = [UInt64: TorrentItem.ID](minimumCapacity: snapshots.count)
        for snapshot in snapshots {
            let id = snapshot.torrent.id
            guard Self.isCanonicalID(id),
                  snapshot.nativeToken != 0,
                  snapshotsByID.updateValue(snapshot, forKey: id) == nil,
                  snapshotIDByToken.updateValue(id, forKey: snapshot.nativeToken) == nil else {
                return .rejected
            }
            if let existing = entriesByID[id], existing.nativeToken != snapshot.nativeToken {
                return .rejected
            }
            if let existingID = idByNativeToken[snapshot.nativeToken], existingID != id {
                return .rejected
            }
        }

        var nextEntries = entriesByID.filter { snapshotsByID[$0.key] != nil }
        var nextIDsByToken = idByNativeToken.filter { snapshotIDByToken[$0.key] != nil }
        for snapshot in snapshots where nextEntries[snapshot.torrent.id] == nil {
            guard let generation = allocateGeneration() else {
                return .rejected
            }
            nextEntries[snapshot.torrent.id] = Entry(
                nativeToken: snapshot.nativeToken,
                generation: generation,
                state: .active
            )
            nextIDsByToken[snapshot.nativeToken] = snapshot.torrent.id
        }
        for id in nextEntries.keys {
            nextEntries[id]?.state = .active
        }

        let changed = nextEntries != entriesByID || nextIDsByToken != idByNativeToken
        entriesByID = nextEntries
        idByNativeToken = nextIDsByToken
        isInitialized = true
        return changed ? .updated : .unchanged
    }

    package func nativeToken(for id: TorrentItem.ID) -> UInt64? {
        guard let entry = entriesByID[id], entry.state == .active else {
            return nil
        }
        return entry.nativeToken
    }

    package func id(forNativeToken nativeToken: UInt64) -> TorrentItem.ID? {
        idByNativeToken[nativeToken]
    }

    package var activeNativeTokens: Set<UInt64> {
        Set(entriesByID.values.lazy.compactMap { entry in
            entry.state == .active ? entry.nativeToken : nil
        })
    }

    package func makeCanonicalID() -> TorrentItem.ID? {
        for _ in 0..<256 {
            let id = "t:" + UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
            if entriesByID[id] == nil {
                return id
            }
        }
        return nil
    }

    package static func isCanonicalID(_ id: TorrentItem.ID) -> Bool {
        let bytes = id.utf8
        guard bytes.count == 34,
              bytes[bytes.startIndex] == UInt8(ascii: "t"),
              bytes[bytes.index(after: bytes.startIndex)] == UInt8(ascii: ":") else {
            return false
        }
        return bytes.dropFirst(2).allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    package mutating func beginRemoval(id: TorrentItem.ID) -> UInt64? {
        guard var entry = entriesByID[id], entry.state == .active else {
            return nil
        }
        entry.state = .removalRequested
        entriesByID[id] = entry
        return entry.nativeToken
    }

    package mutating func cancelRemoval(id: TorrentItem.ID, nativeToken: UInt64) {
        guard var entry = entriesByID[id], entry.nativeToken == nativeToken else {
            return
        }
        entry.state = .active
        entriesByID[id] = entry
    }

    package mutating func completeRemoval(id: TorrentItem.ID, nativeToken: UInt64) {
        guard let entry = entriesByID[id], entry.nativeToken == nativeToken else {
            return
        }
        entriesByID.removeValue(forKey: id)
        idByNativeToken.removeValue(forKey: nativeToken)
    }

    private mutating func allocateGeneration() -> UInt64? {
        guard nextGeneration != 0 else {
            return nil
        }
        let generation = nextGeneration
        nextGeneration &+= 1
        return generation
    }
}
