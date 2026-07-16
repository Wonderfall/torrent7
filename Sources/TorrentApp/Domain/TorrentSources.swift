import Foundation
import TorrentBridge

struct TorrentTrackerItem: Identifiable, Hashable, Sendable {
    let url: String
    let message: String
    let tier: Int32
    let failCount: Int32
    let scrapeSeeders: Int32
    let scrapeLeechers: Int32
    let scrapeDownloaded: Int32
    let updating: Bool
    let verified: Bool
    let hasError: Bool
    let enabled: Bool

    var id: String {
        "\(tier):\(url)"
    }

    var statusText: String {
        if !enabled {
            return "Disabled"
        }
        if updating {
            return "Updating"
        }
        if hasError {
            return "Error"
        }
        if verified {
            return "Working"
        }
        return "Not Contacted"
    }

    var statusSystemImage: String {
        if !enabled {
            return "slash.circle"
        }
        if updating {
            return "arrow.triangle.2.circlepath"
        }
        if hasError {
            return "exclamationmark.triangle"
        }
        if verified {
            return "checkmark.circle"
        }
        return "clock"
    }

    var scrapeSummaryText: String? {
        var parts = [String]()
        if scrapeSeeders >= 0 {
            parts.append("\(scrapeSeeders) \(scrapeSeeders == 1 ? "seeder" : "seeders")")
        }
        if scrapeLeechers >= 0 {
            parts.append("\(scrapeLeechers) \(scrapeLeechers == 1 ? "leecher" : "leechers")")
        }
        if scrapeDownloaded >= 0 {
            parts.append("\(scrapeDownloaded) completed")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct TorrentTrackerHostItem: Hashable, Sendable {
    let torrentID: TorrentItem.ID
    let host: String
}

struct TorrentWebSeedItem: Identifiable, Hashable, Sendable {
    let url: String

    var id: String {
        url
    }
}

struct TorrentWebSeedActivity: Hashable, Sendable {
    let activeCount: Int32
    let downloadRate: Int32
    let totalDownload: Int64

    static let empty = TorrentWebSeedActivity(activeCount: 0, downloadRate: 0, totalDownload: 0)

    var summaryText: String? {
        guard activeCount > 0 else {
            return nil
        }

        let connectionText = "\(activeCount) active"
        guard downloadRate > 0 else {
            return connectionText
        }
        return "\(connectionText) · \(ByteFormat.rate(downloadRate))"
    }
}

struct TorrentPeerSources: Hashable, Sendable {
    let connected: Int32
    let tracker: Int32
    let dht: Int32
    let peerExchange: Int32
    let localServiceDiscovery: Int32
    let resumeData: Int32
    let incoming: Int32
    let webSeed: Int32
    let other: Int32

    static let empty = TorrentPeerSources(
        connected: 0,
        tracker: 0,
        dht: 0,
        peerExchange: 0,
        localServiceDiscovery: 0,
        resumeData: 0,
        incoming: 0,
        webSeed: 0,
        other: 0
    )

    var hasConnectedPeers: Bool {
        connected > 0
    }
}

struct TorrentPieceMap: Equatable, Sendable {
    let totalPieces: Int
    let completedPieces: Int
    let availablePieces: Int
    let isMapAvailable: Bool
    let isMapTruncated: Bool
    let pieces: [UInt8]
    private let completedPiecePrefixCounts: [UInt32]

    static func == (lhs: TorrentPieceMap, rhs: TorrentPieceMap) -> Bool {
        lhs.totalPieces == rhs.totalPieces
            && lhs.completedPieces == rhs.completedPieces
            && lhs.availablePieces == rhs.availablePieces
            && lhs.isMapAvailable == rhs.isMapAvailable
            && lhs.isMapTruncated == rhs.isMapTruncated
            && lhs.pieces == rhs.pieces
    }

    static let empty = TorrentPieceMap(
        totalPieces: 0,
        completedPieces: 0,
        availablePieces: 0,
        isMapAvailable: false,
        isMapTruncated: false,
        pieces: []
    )

    init(
        totalPieces: Int,
        completedPieces: Int,
        availablePieces: Int,
        isMapAvailable: Bool,
        isMapTruncated: Bool,
        pieces: [UInt8]
    ) {
        self.totalPieces = max(0, totalPieces)
        self.completedPieces = max(0, completedPieces)
        self.availablePieces = max(0, availablePieces)
        self.isMapAvailable = isMapAvailable
        self.isMapTruncated = isMapTruncated
        self.pieces = pieces
        completedPiecePrefixCounts = Self.completedPiecePrefixCounts(for: pieces)
    }

    init(snapshot: TTorrentPieceMapSnapshot, pieces: [UInt8]) {
        self.init(
            totalPieces: Int(snapshot.total_pieces),
            completedPieces: Int(snapshot.completed_pieces),
            availablePieces: Int(snapshot.available_pieces),
            isMapAvailable: snapshot.map_available != 0,
            isMapTruncated: snapshot.map_truncated != 0,
            pieces: pieces
        )
    }

    var progress: Double {
        guard totalPieces > 0 else {
            return 0
        }
        return min(max(Double(completedPieces) / Double(totalPieces), 0), 1)
    }

    var completedSummary: String {
        "\(completedPieces.formatted()) of \(totalPieces.formatted()) pieces"
    }

    var displayedPieces: Int {
        min(totalPieces, availablePieces, pieces.count)
    }

    func completedPieceCount(in range: Range<Int>) -> Int {
        guard !completedPiecePrefixCounts.isEmpty else {
            return 0
        }
        let lowerBound = min(max(0, range.lowerBound), completedPiecePrefixCounts.count - 1)
        let upperBound = min(max(lowerBound, range.upperBound), completedPiecePrefixCounts.count - 1)
        return Int(completedPiecePrefixCounts[upperBound] - completedPiecePrefixCounts[lowerBound])
    }

    private static func completedPiecePrefixCounts(for pieces: [UInt8]) -> [UInt32] {
        var prefixCounts = [UInt32]()
        prefixCounts.reserveCapacity(pieces.count + 1)
        prefixCounts.append(0)
        var completedCount: UInt32 = 0
        for piece in pieces {
            if piece != 0 {
                completedCount += 1
            }
            prefixCounts.append(completedCount)
        }
        return prefixCounts
    }
}

struct TorrentSourcePolicy: Equatable, Sendable {
    var isDHTEnabled: Bool
    var isPeerExchangeEnabled: Bool
    var isLocalServiceDiscoveryEnabled: Bool
    var usesHTTPSTrackersOnly: Bool
    var usesHTTPSWebSeedsOnly: Bool
    var isDHTLocked: Bool
    var isPeerExchangeLocked: Bool
    var isLocalServiceDiscoveryLocked: Bool
    var isMetadataValidationPending: Bool
    var allowsPreMetadataDHT: Bool

    static let unavailable = TorrentSourcePolicy(
        isDHTEnabled: false,
        isPeerExchangeEnabled: false,
        isLocalServiceDiscoveryEnabled: false,
        usesHTTPSTrackersOnly: false,
        usesHTTPSWebSeedsOnly: false,
        isDHTLocked: false,
        isPeerExchangeLocked: false,
        isLocalServiceDiscoveryLocked: false,
        isMetadataValidationPending: false,
        allowsPreMetadataDHT: false
    )

    subscript(field: TorrentSourcePolicyField) -> Bool {
        get {
            switch field {
            case .dht:
                isDHTEnabled
            case .peerExchange:
                isPeerExchangeEnabled
            case .localServiceDiscovery:
                isLocalServiceDiscoveryEnabled
            case .httpsTrackersOnly:
                usesHTTPSTrackersOnly
            case .httpsWebSeedsOnly:
                usesHTTPSWebSeedsOnly
            case .preMetadataDHT:
                allowsPreMetadataDHT
            }
        }
        set {
            switch field {
            case .dht:
                isDHTEnabled = newValue
            case .peerExchange:
                isPeerExchangeEnabled = newValue
            case .localServiceDiscovery:
                isLocalServiceDiscoveryEnabled = newValue
            case .httpsTrackersOnly:
                usesHTTPSTrackersOnly = newValue
            case .httpsWebSeedsOnly:
                usesHTTPSWebSeedsOnly = newValue
            case .preMetadataDHT:
                allowsPreMetadataDHT = newValue
            }
        }
    }
}

enum TorrentSourcePolicyField: Sendable {
    case dht
    case peerExchange
    case localServiceDiscovery
    case httpsTrackersOnly
    case httpsWebSeedsOnly
    case preMetadataDHT
}

enum TorrentFilePriority: Int32, CaseIterable, Identifiable, Sendable {
    case skip = 0
    case low = 1
    case normal = 4
    case high = 7

    static let allCases: [TorrentFilePriority] = [.high, .normal, .low, .skip]

    var id: Self { self }

    init(bridgeValue: Int32) {
        switch bridgeValue {
        case Int32(TTORRENT_FILE_PRIORITY_SKIP):
            self = .skip
        case Int32(TTORRENT_FILE_PRIORITY_LOW)...3:
            self = .low
        case 5...Int32(TTORRENT_FILE_PRIORITY_HIGH):
            self = .high
        default:
            self = .normal
        }
    }

    var title: String {
        switch self {
        case .high:
            "High"
        case .normal:
            "Normal"
        case .low:
            "Low"
        case .skip:
            "Skip"
        }
    }

    var bridgeValue: Int32 {
        switch self {
        case .skip:
            Int32(TTORRENT_FILE_PRIORITY_SKIP)
        case .low:
            Int32(TTORRENT_FILE_PRIORITY_LOW)
        case .normal:
            Int32(TTORRENT_FILE_PRIORITY_NORMAL)
        case .high:
            Int32(TTORRENT_FILE_PRIORITY_HIGH)
        }
    }
}

struct TorrentFileItem: Identifiable, Hashable, Sendable {
    let path: String
    let size: Int64
    let downloaded: Int64
    let progress: Double
    let index: Int32
    let priority: TorrentFilePriority
    let isPadFile: Bool

    var id: Int32 {
        index
    }

    var displayName: String {
        guard let name = path.split(separator: "/").last else {
            return path
        }
        return String(name)
    }

    var detailText: String {
        "\(ByteFormat.size(downloaded)) of \(ByteFormat.size(size))"
    }

    var isSkipped: Bool {
        priority == .skip
    }

    var statusText: String {
        if isSkipped {
            return "Skipped"
        }
        if progress >= 1 {
            return "Complete"
        }
        if downloaded > 0 {
            return "Downloading"
        }
        return "Waiting"
    }

    func withPriority(_ priority: TorrentFilePriority) -> TorrentFileItem {
        TorrentFileItem(
            path: path,
            size: size,
            downloaded: downloaded,
            progress: progress,
            index: index,
            priority: priority,
            isPadFile: isPadFile
        )
    }
}

struct TorrentFilePreview: Equatable, Sendable {
    let name: String
    let id: String
    let totalSize: Int64
    let sourceSecuritySummary: TorrentSourceSecuritySummary
    let files: [TorrentFileItem]
    let torrentData: Data

    var visibleFiles: [TorrentFileItem] {
        files.filter { !$0.isPadFile }
    }

    var visibleFileCount: Int {
        visibleFiles.count
    }
}

struct TorrentNetworkStatus: Equatable, Sendable {
    let requestedRevision: UInt64
    let submittedRevision: UInt64
    let listenPort: Int32
    let networkBlocked: Bool
    let hasListener: Bool
    let endpoint: String
    let lastError: String

    static let empty = TorrentNetworkStatus(
        requestedRevision: 0,
        submittedRevision: 0,
        listenPort: 0,
        networkBlocked: true,
        hasListener: false,
        endpoint: "",
        lastError: ""
    )

    var isApplying: Bool {
        requestedRevision > submittedRevision
    }
}

struct TorrentBridgeHealth: Equatable, Sendable {
    let isAvailable: Bool
    let totalAlertWorkerFailures: UInt64
    let consecutiveAlertWorkerFailures: UInt64
    let isAlertWorkerDegraded: Bool
    let lastAlertWorkerError: String

    static let healthy = TorrentBridgeHealth(
        isAvailable: true,
        totalAlertWorkerFailures: 0,
        consecutiveAlertWorkerFailures: 0,
        isAlertWorkerDegraded: false,
        lastAlertWorkerError: ""
    )

    static let unavailable = TorrentBridgeHealth(
        isAvailable: false,
        totalAlertWorkerFailures: 0,
        consecutiveAlertWorkerFailures: 0,
        isAlertWorkerDegraded: false,
        lastAlertWorkerError: ""
    )
}
