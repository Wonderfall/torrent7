package enum TorrentInputLimits {
    package static let maxMagnetURIBytes = 64 * 1024
    package static let maxTorrentFileBytes = 64 * 1024 * 1024
}

package enum TorrentEngineLimits {
    package static let maximumFileCount = 20_000
    package static let maximumTrackerCount = 2_000
    package static let maximumWebSeedCount = 2_000
    package static let maximumTorrentSnapshotCount = 20_000
    package static let maximumTrackerHostRowCount = 20_000
    package static let maximumAuthorizedSavePathCount = 20_000
    package static let maximumAuthorizedSavePathBytes = 1_023
    package static let maximumAuthorizedSavePathBlobBytes = 20_480_000
    package static let maximumPieceMapCount = 0x20_0000
    package static let torrentIDCapacity = 68
    package static let trackerHostCapacity = 256
}

package struct TorrentEngineDirtySet: OptionSet, Sendable {
    package let rawValue: UInt32

    package init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    package static let torrents = Self(rawValue: 1 << 0)
    package static let trackers = Self(rawValue: 1 << 1)
    package static let webSeeds = Self(rawValue: 1 << 2)
    package static let files = Self(rawValue: 1 << 3)
    package static let network = Self(rawValue: 1 << 4)
    package static let errors = Self(rawValue: 1 << 5)
    package static let pieces = Self(rawValue: 1 << 6)
    package static let trackerHosts = Self(rawValue: 1 << 7)
    package static let health = Self(rawValue: 1 << 8)
}
