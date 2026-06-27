import Foundation

struct TorrentItem: Identifiable, Hashable, Sendable {
    let id: String
    let infoHash: String
    let name: String
    let savePath: String
    let error: String
    let comment: String
    let progress: Double
    let totalDone: Int64
    let totalWanted: Int64
    let totalSize: Int64
    let totalUpload: Int64
    let totalDownload: Int64
    let totalPayloadUpload: Int64
    let totalPayloadDownload: Int64
    let allTimeUpload: Int64
    let allTimeDownload: Int64
    let addedTime: Int64
    let createdTime: Int64
    let completedTime: Int64
    let downloadRate: Int32
    let uploadRate: Int32
    let downloadPayloadRate: Int32
    let uploadPayloadRate: Int32
    let peers: Int32
    let knownPeers: Int32
    let seeds: Int32
    let state: TorrentState
    let queuePosition: Int32
    let queuePriority: TorrentQueuePriority
    let paused: Bool
    let autoManaged: Bool
    let seeding: Bool
    let finished: Bool
    let hasMetadata: Bool
    let privateTorrent: Bool

    var manuallyPaused: Bool {
        paused && !autoManaged
    }

    var queued: Bool {
        paused && autoManaged
    }

    var displayedAllTimeUpload: Int64 {
        max(allTimeUpload, totalPayloadUpload)
    }

    var displayedAllTimeDownload: Int64 {
        max(allTimeDownload, totalPayloadDownload)
    }

    var downloadComplete: Bool {
        finished || seeding
    }

    var hasPeerInformation: Bool {
        knownPeerCount > 0
    }

    var peerSummaryText: String {
        "\(connectedPeerCount)/\(knownPeerCount) \(knownPeerCount == 1 ? "peer" : "peers")"
    }

    var statusText: String {
        if !error.isEmpty {
            return "Error"
        }
        if manuallyPaused {
            return "Paused"
        }
        if queued {
            return "Queued"
        }
        if seeding {
            return "Seeding"
        }
        if finished {
            return "Finished"
        }
        if !hasMetadata {
            return "Metadata"
        }
        return state.title
    }

    var connectedPeerCount: Int32 {
        max(0, peers)
    }

    var knownPeerCount: Int32 {
        max(connectedPeerCount, knownPeers)
    }

    var statusSortRank: Int {
        if !error.isEmpty {
            return 0
        }
        if !hasMetadata || state == .downloadingMetadata {
            return 1
        }
        if state == .checkingFiles || state == .checkingResumeData {
            return 2
        }
        if state == .downloading {
            return 3
        }
        if seeding {
            return 4
        }
        if finished {
            return 5
        }
        if queued {
            return 6
        }
        if manuallyPaused {
            return 7
        }
        return 8
    }

    var isActiveTransfer: Bool {
        error.isEmpty
            && !manuallyPaused
            && (state == .downloading
                || state == .downloadingMetadata
                || state == .checkingFiles
                || state == .checkingResumeData
                || seeding)
    }
}

struct TorrentRowSnapshot: Identifiable, Hashable, Sendable {
    let id: TorrentItem.ID
    let name: String
    let savePath: String
    let error: String
    let state: TorrentState
    let queuePriority: TorrentQueuePriority
    let paused: Bool
    let autoManaged: Bool
    let seeding: Bool
    let finished: Bool
    let hasMetadata: Bool
    let active: Bool

    init(_ torrent: TorrentItem) {
        id = torrent.id
        name = torrent.name
        savePath = torrent.savePath
        error = torrent.error
        state = torrent.state
        queuePriority = torrent.queuePriority
        paused = torrent.paused
        autoManaged = torrent.autoManaged
        seeding = torrent.seeding
        finished = torrent.finished
        hasMetadata = torrent.hasMetadata
        active = torrent.isActiveTransfer
    }

    var manuallyPaused: Bool {
        paused && !autoManaged
    }

    var queued: Bool {
        paused && autoManaged
    }

    var downloadComplete: Bool {
        finished || seeding
    }

    var statusText: String {
        if !error.isEmpty {
            return "Error"
        }
        if manuallyPaused {
            return "Paused"
        }
        if queued {
            return "Queued"
        }
        if seeding {
            return "Seeding"
        }
        if finished {
            return "Finished"
        }
        if !hasMetadata {
            return "Metadata"
        }
        return state.title
    }
}

struct TorrentTransferMetrics: Equatable, Sendable {
    static let empty = TorrentTransferMetrics()

    let progress: Double
    let totalDone: Int64
    let totalWanted: Int64
    let totalPayloadUpload: Int64
    let totalPayloadDownload: Int64
    let allTimeUpload: Int64
    let allTimeDownload: Int64
    let downloadRate: Int32
    let uploadRate: Int32
    let downloadPayloadRate: Int32
    let uploadPayloadRate: Int32
    let peers: Int32
    let knownPeers: Int32

    init(
        progress: Double = 0,
        totalDone: Int64 = 0,
        totalWanted: Int64 = 0,
        totalPayloadUpload: Int64 = 0,
        totalPayloadDownload: Int64 = 0,
        allTimeUpload: Int64 = 0,
        allTimeDownload: Int64 = 0,
        downloadRate: Int32 = 0,
        uploadRate: Int32 = 0,
        downloadPayloadRate: Int32 = 0,
        uploadPayloadRate: Int32 = 0,
        peers: Int32 = 0,
        knownPeers: Int32 = 0
    ) {
        self.progress = progress
        self.totalDone = totalDone
        self.totalWanted = totalWanted
        self.totalPayloadUpload = totalPayloadUpload
        self.totalPayloadDownload = totalPayloadDownload
        self.allTimeUpload = allTimeUpload
        self.allTimeDownload = allTimeDownload
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.downloadPayloadRate = downloadPayloadRate
        self.uploadPayloadRate = uploadPayloadRate
        self.peers = peers
        self.knownPeers = knownPeers
    }

    init(_ torrent: TorrentItem) {
        self.init(
            progress: torrent.progress,
            totalDone: torrent.totalDone,
            totalWanted: torrent.totalWanted,
            totalPayloadUpload: torrent.totalPayloadUpload,
            totalPayloadDownload: torrent.totalPayloadDownload,
            allTimeUpload: torrent.allTimeUpload,
            allTimeDownload: torrent.allTimeDownload,
            downloadRate: torrent.downloadRate,
            uploadRate: torrent.uploadRate,
            downloadPayloadRate: torrent.downloadPayloadRate,
            uploadPayloadRate: torrent.uploadPayloadRate,
            peers: torrent.peers,
            knownPeers: torrent.knownPeers
        )
    }

    var displayedAllTimeUpload: Int64 {
        max(allTimeUpload, totalPayloadUpload)
    }

    var displayedAllTimeDownload: Int64 {
        max(allTimeDownload, totalPayloadDownload)
    }

    var connectedPeerCount: Int32 {
        max(0, peers)
    }

    var knownPeerCount: Int32 {
        max(connectedPeerCount, knownPeers)
    }

    var peerSummaryText: String {
        "\(connectedPeerCount)/\(knownPeerCount) \(knownPeerCount == 1 ? "peer" : "peers")"
    }
}


enum TorrentState: Int32, Hashable, Sendable {
    case checkingFiles = 1
    case downloadingMetadata = 2
    case downloading = 3
    case finished = 4
    case seeding = 5
    case checkingResumeData = 7
    case unknown = -1

    init(rawBridgeValue: Int32) {
        self = TorrentState(rawValue: rawBridgeValue) ?? .unknown
    }

    var title: String {
        switch self {
        case .checkingFiles:
            return "Checking"
        case .downloadingMetadata:
            return "Metadata"
        case .downloading:
            return "Downloading"
        case .finished:
            return "Finished"
        case .seeding:
            return "Seeding"
        case .checkingResumeData:
            return "Resuming"
        case .unknown:
            return "Unknown"
        }
    }
}
