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

package enum TorrentRemovalOutcome: Equatable, Sendable {
    case removed
    case removedWithWarning(String)
}

package protocol TorrentEngineServicing: Sendable {
    var startupFailureMessage: String? { get }
    var libtorrentVersion: String { get }
    var isAvailable: Bool { get }

    func restart(enablePeerExchangePlugin: Bool, authorizedSavePaths: [String]) async throws
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
    func applySettings(_ settings: TorrentSettings, networkBlocked: Bool) async throws
    func blockNetworkNow() async throws
    func saveAll() async
    func saveAllChecked() async throws
    func takeAlertError() async -> String?
    func takeChanges() async -> UInt32
    func networkStatus() async -> TorrentNetworkStatus
    func bridgeHealth() async -> TorrentBridgeHealth
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

package struct TorrentSnapshotBatch: Sendable {
    package var revision: UInt64
    package var torrents: [TorrentItem]

    package init(revision: UInt64, torrents: [TorrentItem]) {
        self.revision = revision
        self.torrents = torrents
    }
}

package struct TorrentTrackerBatch: Sendable {
    package var revision: UInt64
    package var trackers: [TorrentTrackerItem]

    package init(revision: UInt64, trackers: [TorrentTrackerItem]) {
        self.revision = revision
        self.trackers = trackers
    }
}

package struct TorrentTrackerHostBatch: Sendable {
    package var revision: UInt64
    package var hosts: [TorrentTrackerHostItem]

    package init(revision: UInt64, hosts: [TorrentTrackerHostItem]) {
        self.revision = revision
        self.hosts = hosts
    }
}

package struct TorrentWebSeedBatch: Sendable {
    package var revision: UInt64
    package var webSeeds: [TorrentWebSeedItem]

    package init(revision: UInt64, webSeeds: [TorrentWebSeedItem]) {
        self.revision = revision
        self.webSeeds = webSeeds
    }
}

package struct TorrentFileBatch: Sendable {
    package var revision: UInt64
    package var files: [TorrentFileItem]

    package init(revision: UInt64, files: [TorrentFileItem]) {
        self.revision = revision
        self.files = files
    }
}

package struct TorrentPieceMapBatch: Sendable {
    package var revision: UInt64
    package var pieceMap: TorrentPieceMap

    package init(revision: UInt64, pieceMap: TorrentPieceMap) {
        self.revision = revision
        self.pieceMap = pieceMap
    }
}
