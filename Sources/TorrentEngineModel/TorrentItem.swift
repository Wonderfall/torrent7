import Foundation

package struct TorrentItem: Identifiable, Hashable, Sendable {
    package let id: String
    package let infoHash: String
    package let name: String
    package let savePath: String
    package let error: String
    package let comment: String
    package let progress: Double
    package let totalDone: Int64
    package let totalWanted: Int64
    package let totalSize: Int64
    package let totalUpload: Int64
    package let totalDownload: Int64
    package let totalPayloadUpload: Int64
    package let totalPayloadDownload: Int64
    package let allTimeUpload: Int64
    package let allTimeDownload: Int64
    package let addedTime: Int64
    package let createdTime: Int64
    package let completedTime: Int64
    package let downloadRate: Int32
    package let uploadRate: Int32
    package let downloadPayloadRate: Int32
    package let uploadPayloadRate: Int32
    package let peers: Int32
    package let knownPeers: Int32
    package let seeds: Int32
    package let state: TorrentState
    package let queuePosition: Int32
    package let queuePriority: TorrentQueuePriority
    package let paused: Bool
    package let autoManaged: Bool
    package let seeding: Bool
    package let finished: Bool
    package let hasMetadata: Bool
    package let privateTorrent: Bool

    package init(
        id: String,
        infoHash: String,
        name: String,
        savePath: String,
        error: String,
        comment: String,
        progress: Double,
        totalDone: Int64,
        totalWanted: Int64,
        totalSize: Int64,
        totalUpload: Int64,
        totalDownload: Int64,
        totalPayloadUpload: Int64,
        totalPayloadDownload: Int64,
        allTimeUpload: Int64,
        allTimeDownload: Int64,
        addedTime: Int64,
        createdTime: Int64,
        completedTime: Int64,
        downloadRate: Int32,
        uploadRate: Int32,
        downloadPayloadRate: Int32,
        uploadPayloadRate: Int32,
        peers: Int32,
        knownPeers: Int32,
        seeds: Int32,
        state: TorrentState,
        queuePosition: Int32,
        queuePriority: TorrentQueuePriority,
        paused: Bool,
        autoManaged: Bool,
        seeding: Bool,
        finished: Bool,
        hasMetadata: Bool,
        privateTorrent: Bool
    ) {
        self.id = id
        self.infoHash = infoHash
        self.name = name
        self.savePath = savePath
        self.error = error
        self.comment = comment
        self.progress = progress
        self.totalDone = totalDone
        self.totalWanted = totalWanted
        self.totalSize = totalSize
        self.totalUpload = totalUpload
        self.totalDownload = totalDownload
        self.totalPayloadUpload = totalPayloadUpload
        self.totalPayloadDownload = totalPayloadDownload
        self.allTimeUpload = allTimeUpload
        self.allTimeDownload = allTimeDownload
        self.addedTime = addedTime
        self.createdTime = createdTime
        self.completedTime = completedTime
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.downloadPayloadRate = downloadPayloadRate
        self.uploadPayloadRate = uploadPayloadRate
        self.peers = peers
        self.knownPeers = knownPeers
        self.seeds = seeds
        self.state = state
        self.queuePosition = queuePosition
        self.queuePriority = queuePriority
        self.paused = paused
        self.autoManaged = autoManaged
        self.seeding = seeding
        self.finished = finished
        self.hasMetadata = hasMetadata
        self.privateTorrent = privateTorrent
    }

    package var manuallyPaused: Bool {
        paused && !autoManaged
    }

    package var queued: Bool {
        paused && autoManaged
    }

    package var displayedAllTimeUpload: Int64 {
        max(allTimeUpload, totalPayloadUpload)
    }

    package var displayedAllTimeDownload: Int64 {
        max(allTimeDownload, totalPayloadDownload)
    }

    package var downloadComplete: Bool {
        finished || seeding
    }

    package var hasPeerInformation: Bool {
        knownPeerCount > 0
    }

    package var peerSummaryText: String {
        "\(connectedPeerCount)/\(knownPeerCount) \(knownPeerCount == 1 ? "peer" : "peers")"
    }

    package var statusText: String {
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

    package var connectedPeerCount: Int32 {
        max(0, peers)
    }

    package var knownPeerCount: Int32 {
        max(connectedPeerCount, knownPeers)
    }

    package var statusSortRank: Int {
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

    package var isActiveTransfer: Bool {
        error.isEmpty
            && !manuallyPaused
            && (state == .downloading
                || state == .downloadingMetadata
                || state == .checkingFiles
                || state == .checkingResumeData
                || seeding)
    }
}

package struct TorrentRowSnapshot: Identifiable, Hashable, Sendable {
    package let id: TorrentItem.ID
    package let name: String
    package let savePath: String
    package let error: String
    package let state: TorrentState
    package let queuePriority: TorrentQueuePriority
    package let paused: Bool
    package let autoManaged: Bool
    package let seeding: Bool
    package let finished: Bool
    package let hasMetadata: Bool
    package let active: Bool

    package init(_ torrent: TorrentItem) {
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

    package var manuallyPaused: Bool {
        paused && !autoManaged
    }

    package var queued: Bool {
        paused && autoManaged
    }

    package var downloadComplete: Bool {
        finished || seeding
    }

    package var statusText: String {
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

package struct TorrentTransferMetrics: Equatable, Sendable {
    package static let empty = TorrentTransferMetrics()

    package let progress: Double
    package let totalDone: Int64
    package let totalWanted: Int64
    package let totalPayloadUpload: Int64
    package let totalPayloadDownload: Int64
    package let allTimeUpload: Int64
    package let allTimeDownload: Int64
    package let downloadRate: Int32
    package let uploadRate: Int32
    package let downloadPayloadRate: Int32
    package let uploadPayloadRate: Int32
    package let peers: Int32
    package let knownPeers: Int32

    package init(
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

    package init(_ torrent: TorrentItem) {
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

    package var displayedAllTimeUpload: Int64 {
        max(allTimeUpload, totalPayloadUpload)
    }

    package var displayedAllTimeDownload: Int64 {
        max(allTimeDownload, totalPayloadDownload)
    }

    package var connectedPeerCount: Int32 {
        max(0, peers)
    }

    package var knownPeerCount: Int32 {
        max(connectedPeerCount, knownPeers)
    }

    package var peerSummaryText: String {
        "\(connectedPeerCount)/\(knownPeerCount) \(knownPeerCount == 1 ? "peer" : "peers")"
    }
}


package enum TorrentState: Int32, Hashable, Sendable {
    case checkingFiles = 1
    case downloadingMetadata = 2
    case downloading = 3
    case finished = 4
    case seeding = 5
    case checkingResumeData = 7
    case unknown = -1

    package var title: String {
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
