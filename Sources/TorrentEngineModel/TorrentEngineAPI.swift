import Foundation

package enum TorrentEngineError: LocalizedError, Sendable {
    case failedToCreateClient
    case startupFailed(String)
    case bridgeError(String)

    package var errorDescription: String? {
        switch self {
        case .failedToCreateClient:
            return "Could not start libtorrent."
        case .startupFailed(let message):
            return message.isEmpty ? "Could not start libtorrent." : "Could not start libtorrent: \(message)"
        case .bridgeError(let message):
            return message.isEmpty ? "The torrent operation failed." : message
        }
    }
}

package enum TorrentRemovalOutcome: Codable, Equatable, Sendable {
    case removed
    case removedWithWarning(String)
}

package struct TorrentFolderAuthorization: Equatable, Sendable {
    package let path: String
    package let bookmarkData: Data

    package init(path: String, bookmarkData: Data) {
        self.path = path
        self.bookmarkData = bookmarkData
    }
}

package protocol TorrentEngineServicing: Sendable {
    var startupFailureMessage: String? { get }
    var libtorrentVersion: String { get }
    var isAvailable: Bool { get }

    /// Ends the controller connection and waits for engine-owned resources to
    /// be released. Implementations must be idempotent.
    func shutdown() async
    /// Immediately removes the controller transport as a fail-closed boundary.
    func terminateConnection() async
    func restart(enablePeerExchangePlugin: Bool, authorizedSavePaths: [String]) async throws
    func delegateFolderAuthorization(_ authorization: TorrentFolderAuthorization) async throws
    func reconcileFolderAuthorizations(
        _ authorizations: [TorrentFolderAuthorization]
    ) async throws
    func wakeEvents() async -> AsyncStream<Void>
    func addMagnet(
        _ magnet: String,
        savePath: String,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        enablePeerExchange: Bool,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool,
        allowPreMetadataDHT: Bool
    ) async throws -> String
    func addTorrentFile(
        data: Data,
        savePath: String,
        filePriorities: [Int32: TorrentFilePriority]?,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        enablePeerExchange: Bool,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool
    ) async throws -> String
    func previewTorrentFile(data: Data) async throws -> TorrentFilePreview
    func pause(id: String) async throws
    func resume(id: String) async throws
    func reannounce(id: String) async throws
    func forceRecheck(id: String) async throws
    func remove(id: String, deleteFiles: Bool) async throws -> TorrentRemovalOutcome
    func applySettings(_ settings: TorrentSettings, networkBinding: TorrentNetworkBinding) async throws
    func blockNetworkNow() async throws
    func saveAll() async
    func saveAllChecked() async throws
    func takeAlertError() async -> String?
    func takeChanges() async -> UInt32
    func networkStatus() async -> TorrentNetworkStatus
    func bridgeHealth() async -> TorrentBridgeHealth
    func poll(
        since revision: UInt64?,
        sortedBy sortOrder: TorrentSortOrder,
        direction: TorrentSortDirection,
        includeTrackerHosts: Bool
    ) async -> TorrentEnginePollResult
    func snapshotsIfChanged(
        since revision: UInt64?,
        sortedBy sortOrder: TorrentSortOrder,
        direction: TorrentSortDirection
    ) async -> TorrentSnapshotBatch?
    func requestSources(id: String) async throws
    func sourcePolicy(id: String) async throws -> TorrentSourcePolicy
    func setSourcePolicy(id: String, field: TorrentSourcePolicyField, enabled: Bool) async throws
    func torrentOptions(id: String) async throws -> TorrentOptions
    func setTorrentOptions(id: String, options: TorrentOptions) async throws
    func moveTorrentInQueue(id: String, move: TorrentQueueMove) async throws
    func requestFiles(id: String) async throws
    func setFilePriority(id: String, fileIndex: Int32, priority: TorrentFilePriority) async throws
    func requestPieceMap(id: String) async throws
    func trackerBatch(id: String, since revision: UInt64?) async -> TorrentTrackerBatch?
    func trackerHostBatch() async -> TorrentTrackerHostBatch
    func webSeedBatch(id: String, since revision: UInt64?) async -> TorrentWebSeedBatch?
    func webSeedActivity(id: String) async -> TorrentWebSeedActivity?
    func peerSources(id: String) async -> TorrentPeerSources?
    func fileBatch(id: String, since revision: UInt64?) async -> TorrentFileBatch?
    func pieceMapBatch(id: String, since revision: UInt64?) async -> TorrentPieceMapBatch?
}

package struct TorrentEnginePollResult: Codable, Sendable {
    package let dirtyMask: UInt32
    package let alertErrors: [String]
    package let networkStatus: TorrentNetworkStatus
    package let bridgeHealth: TorrentBridgeHealth
    package let snapshotBatch: TorrentSnapshotBatch?
    package let trackerHostBatch: TorrentTrackerHostBatch?

    package init(
        dirtyMask: UInt32,
        alertErrors: [String],
        networkStatus: TorrentNetworkStatus,
        bridgeHealth: TorrentBridgeHealth,
        snapshotBatch: TorrentSnapshotBatch?,
        trackerHostBatch: TorrentTrackerHostBatch?
    ) {
        self.dirtyMask = dirtyMask
        self.alertErrors = Array(alertErrors.prefix(TorrentEngineLimits.maximumAlertErrorsPerPoll))
        self.networkStatus = networkStatus
        self.bridgeHealth = bridgeHealth
        self.snapshotBatch = snapshotBatch
        self.trackerHostBatch = trackerHostBatch
    }

    private enum CodingKeys: String, CodingKey {
        case dirtyMask
        case alertErrors
        case networkStatus
        case bridgeHealth
        case snapshotBatch
        case trackerHostBatch
    }

    package init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dirtyMask: try values.decode(UInt32.self, forKey: .dirtyMask),
            alertErrors: try values.decode([String].self, forKey: .alertErrors),
            networkStatus: try values.decode(TorrentNetworkStatus.self, forKey: .networkStatus),
            bridgeHealth: try values.decode(TorrentBridgeHealth.self, forKey: .bridgeHealth),
            snapshotBatch: try values.decodeIfPresent(TorrentSnapshotBatch.self, forKey: .snapshotBatch),
            trackerHostBatch: try values.decodeIfPresent(TorrentTrackerHostBatch.self, forKey: .trackerHostBatch)
        )
    }

    package func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(dirtyMask, forKey: .dirtyMask)
        try values.encode(alertErrors, forKey: .alertErrors)
        try values.encode(networkStatus, forKey: .networkStatus)
        try values.encode(bridgeHealth, forKey: .bridgeHealth)
        try values.encodeIfPresent(snapshotBatch, forKey: .snapshotBatch)
        try values.encodeIfPresent(trackerHostBatch, forKey: .trackerHostBatch)
    }
}

extension TorrentEngineServicing {
    package func poll(
        since revision: UInt64?,
        sortedBy sortOrder: TorrentSortOrder,
        direction: TorrentSortDirection,
        includeTrackerHosts: Bool
    ) async -> TorrentEnginePollResult {
        let health = await bridgeHealth()
        let dirtyMask = await takeChanges()
        var alertErrors = [String]()
        alertErrors.reserveCapacity(TorrentEngineLimits.maximumAlertErrorsPerPoll)
        for _ in 0..<TorrentEngineLimits.maximumAlertErrorsPerPoll {
            guard let error = await takeAlertError() else {
                break
            }
            if !error.isEmpty {
                alertErrors.append(error)
            }
        }
        let status = await networkStatus()
        let trackerHostsChanged = TorrentEngineDirtySet(rawValue: dirtyMask).contains(.trackerHosts)
        let trackerHosts = includeTrackerHosts || trackerHostsChanged
            ? await trackerHostBatch()
            : nil
        let snapshots = await snapshotsIfChanged(
            since: revision,
            sortedBy: sortOrder,
            direction: direction
        )
        return TorrentEnginePollResult(
            dirtyMask: dirtyMask,
            alertErrors: alertErrors,
            networkStatus: status,
            bridgeHealth: health,
            snapshotBatch: snapshots,
            trackerHostBatch: trackerHosts
        )
    }
}

package struct TorrentSnapshotBatch: Codable, Sendable {
    package var revision: UInt64
    package var torrents: [TorrentItem]

    package init(revision: UInt64, torrents: [TorrentItem]) {
        self.revision = revision
        self.torrents = torrents
    }
}

package struct TorrentTrackerBatch: Codable, Sendable {
    package var revision: UInt64
    package var trackers: [TorrentTrackerItem]

    package init(revision: UInt64, trackers: [TorrentTrackerItem]) {
        self.revision = revision
        self.trackers = trackers
    }
}

package struct TorrentTrackerHostBatch: Codable, Sendable {
    package var revision: UInt64
    package var hosts: [TorrentTrackerHostItem]

    package init(revision: UInt64, hosts: [TorrentTrackerHostItem]) {
        self.revision = revision
        self.hosts = hosts
    }
}

package struct TorrentWebSeedBatch: Codable, Sendable {
    package var revision: UInt64
    package var webSeeds: [TorrentWebSeedItem]

    package init(revision: UInt64, webSeeds: [TorrentWebSeedItem]) {
        self.revision = revision
        self.webSeeds = webSeeds
    }
}

package struct TorrentFileBatch: Codable, Sendable {
    package var revision: UInt64
    package var files: [TorrentFileItem]

    package init(revision: UInt64, files: [TorrentFileItem]) {
        self.revision = revision
        self.files = files
    }
}

package struct TorrentPieceMapBatch: Codable, Sendable {
    package var revision: UInt64
    package var pieceMap: TorrentPieceMap

    package init(revision: UInt64, pieceMap: TorrentPieceMap) {
        self.revision = revision
        self.pieceMap = pieceMap
    }
}
