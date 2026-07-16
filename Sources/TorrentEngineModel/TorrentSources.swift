import Foundation

package struct TorrentTrackerItem: Identifiable, Hashable, Sendable {
    package let url: String
    package let message: String
    package let tier: Int32
    package let failCount: Int32
    package let scrapeSeeders: Int32
    package let scrapeLeechers: Int32
    package let scrapeDownloaded: Int32
    package let updating: Bool
    package let verified: Bool
    package let hasError: Bool
    package let enabled: Bool

    package init(
        url: String,
        message: String,
        tier: Int32,
        failCount: Int32,
        scrapeSeeders: Int32,
        scrapeLeechers: Int32,
        scrapeDownloaded: Int32,
        updating: Bool,
        verified: Bool,
        hasError: Bool,
        enabled: Bool
    ) {
        self.url = url
        self.message = message
        self.tier = tier
        self.failCount = failCount
        self.scrapeSeeders = scrapeSeeders
        self.scrapeLeechers = scrapeLeechers
        self.scrapeDownloaded = scrapeDownloaded
        self.updating = updating
        self.verified = verified
        self.hasError = hasError
        self.enabled = enabled
    }

    package var id: String {
        "\(tier):\(url)"
    }

    package var statusText: String {
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

    package var statusSystemImage: String {
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

    package var scrapeSummaryText: String? {
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

package struct TorrentTrackerHostItem: Hashable, Sendable {
    package let torrentID: TorrentItem.ID
    package let host: String

    package init(torrentID: TorrentItem.ID, host: String) {
        self.torrentID = torrentID
        self.host = host
    }
}

package struct TorrentWebSeedItem: Identifiable, Hashable, Sendable {
    package let url: String

    package init(url: String) {
        self.url = url
    }

    package var id: String {
        url
    }
}

package struct TorrentWebSeedActivity: Hashable, Sendable {
    package let activeCount: Int32
    package let downloadRate: Int32
    package let totalDownload: Int64

    package static let empty = TorrentWebSeedActivity(activeCount: 0, downloadRate: 0, totalDownload: 0)

    package init(activeCount: Int32, downloadRate: Int32, totalDownload: Int64) {
        self.activeCount = activeCount
        self.downloadRate = downloadRate
        self.totalDownload = totalDownload
    }

}

package struct TorrentPeerSources: Hashable, Sendable {
    package let connected: Int32
    package let tracker: Int32
    package let dht: Int32
    package let peerExchange: Int32
    package let localServiceDiscovery: Int32
    package let resumeData: Int32
    package let incoming: Int32
    package let webSeed: Int32
    package let other: Int32

    package static let empty = TorrentPeerSources(
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

    package init(
        connected: Int32,
        tracker: Int32,
        dht: Int32,
        peerExchange: Int32,
        localServiceDiscovery: Int32,
        resumeData: Int32,
        incoming: Int32,
        webSeed: Int32,
        other: Int32
    ) {
        self.connected = connected
        self.tracker = tracker
        self.dht = dht
        self.peerExchange = peerExchange
        self.localServiceDiscovery = localServiceDiscovery
        self.resumeData = resumeData
        self.incoming = incoming
        self.webSeed = webSeed
        self.other = other
    }

    package var hasConnectedPeers: Bool {
        connected > 0
    }
}

package struct TorrentPieceMap: Equatable, Sendable {
    package let totalPieces: Int
    package let completedPieces: Int
    package let availablePieces: Int
    package let isMapAvailable: Bool
    package let isMapTruncated: Bool
    package let pieces: [UInt8]
    private let completedPiecePrefixCounts: [UInt32]

    package static func == (lhs: TorrentPieceMap, rhs: TorrentPieceMap) -> Bool {
        lhs.totalPieces == rhs.totalPieces
            && lhs.completedPieces == rhs.completedPieces
            && lhs.availablePieces == rhs.availablePieces
            && lhs.isMapAvailable == rhs.isMapAvailable
            && lhs.isMapTruncated == rhs.isMapTruncated
            && lhs.pieces == rhs.pieces
    }

    package static let empty = TorrentPieceMap(
        totalPieces: 0,
        completedPieces: 0,
        availablePieces: 0,
        isMapAvailable: false,
        isMapTruncated: false,
        pieces: []
    )

    package init(
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

    package var progress: Double {
        guard totalPieces > 0 else {
            return 0
        }
        return min(max(Double(completedPieces) / Double(totalPieces), 0), 1)
    }

    package var completedSummary: String {
        "\(completedPieces.formatted()) of \(totalPieces.formatted()) pieces"
    }

    package var displayedPieces: Int {
        min(totalPieces, availablePieces, pieces.count)
    }

    package func completedPieceCount(in range: Range<Int>) -> Int {
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

package struct TorrentSourcePolicy: Equatable, Sendable {
    package var isDHTEnabled: Bool
    package var isPeerExchangeEnabled: Bool
    package var isLocalServiceDiscoveryEnabled: Bool
    package var usesHTTPSTrackersOnly: Bool
    package var usesHTTPSWebSeedsOnly: Bool
    package var isDHTLocked: Bool
    package var isPeerExchangeLocked: Bool
    package var isLocalServiceDiscoveryLocked: Bool
    package var isMetadataValidationPending: Bool
    package var allowsPreMetadataDHT: Bool

    package static let unavailable = TorrentSourcePolicy(
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

    package init(
        isDHTEnabled: Bool,
        isPeerExchangeEnabled: Bool,
        isLocalServiceDiscoveryEnabled: Bool,
        usesHTTPSTrackersOnly: Bool,
        usesHTTPSWebSeedsOnly: Bool,
        isDHTLocked: Bool,
        isPeerExchangeLocked: Bool,
        isLocalServiceDiscoveryLocked: Bool,
        isMetadataValidationPending: Bool,
        allowsPreMetadataDHT: Bool
    ) {
        self.isDHTEnabled = isDHTEnabled
        self.isPeerExchangeEnabled = isPeerExchangeEnabled
        self.isLocalServiceDiscoveryEnabled = isLocalServiceDiscoveryEnabled
        self.usesHTTPSTrackersOnly = usesHTTPSTrackersOnly
        self.usesHTTPSWebSeedsOnly = usesHTTPSWebSeedsOnly
        self.isDHTLocked = isDHTLocked
        self.isPeerExchangeLocked = isPeerExchangeLocked
        self.isLocalServiceDiscoveryLocked = isLocalServiceDiscoveryLocked
        self.isMetadataValidationPending = isMetadataValidationPending
        self.allowsPreMetadataDHT = allowsPreMetadataDHT
    }

    package subscript(field: TorrentSourcePolicyField) -> Bool {
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

package enum TorrentSourcePolicyField: Sendable {
    case dht
    case peerExchange
    case localServiceDiscovery
    case httpsTrackersOnly
    case httpsWebSeedsOnly
    case preMetadataDHT
}

package enum TorrentFilePriority: Int32, CaseIterable, Identifiable, Sendable {
    case skip = 0
    case low = 1
    case normal = 4
    case high = 7

    package static let allCases: [TorrentFilePriority] = [.high, .normal, .low, .skip]

    package var id: Self { self }

    package var title: String {
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

}

package struct TorrentFileItem: Identifiable, Hashable, Sendable {
    package let path: String
    package let size: Int64
    package let downloaded: Int64
    package let progress: Double
    package let index: Int32
    package let priority: TorrentFilePriority
    package let isPadFile: Bool

    package init(
        path: String,
        size: Int64,
        downloaded: Int64,
        progress: Double,
        index: Int32,
        priority: TorrentFilePriority,
        isPadFile: Bool
    ) {
        self.path = path
        self.size = size
        self.downloaded = downloaded
        self.progress = progress
        self.index = index
        self.priority = priority
        self.isPadFile = isPadFile
    }

    package var id: Int32 {
        index
    }

    package var displayName: String {
        guard let name = path.split(separator: "/").last else {
            return path
        }
        return String(name)
    }

    package var isSkipped: Bool {
        priority == .skip
    }

    package var statusText: String {
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

    package func withPriority(_ priority: TorrentFilePriority) -> TorrentFileItem {
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

package struct TorrentFilePreview: Equatable, Sendable {
    package let name: String
    package let id: String
    package let totalSize: Int64
    package let sourceSecuritySummary: TorrentSourceSecuritySummary
    package let files: [TorrentFileItem]
    package let torrentData: Data

    package init(
        name: String,
        id: String,
        totalSize: Int64,
        sourceSecuritySummary: TorrentSourceSecuritySummary,
        files: [TorrentFileItem],
        torrentData: Data
    ) {
        self.name = name
        self.id = id
        self.totalSize = totalSize
        self.sourceSecuritySummary = sourceSecuritySummary
        self.files = files
        self.torrentData = torrentData
    }

    package var visibleFiles: [TorrentFileItem] {
        files.filter { !$0.isPadFile }
    }

    package var visibleFileCount: Int {
        visibleFiles.count
    }
}

package struct TorrentNetworkStatus: Equatable, Sendable {
    package let requestedRevision: UInt64
    package let submittedRevision: UInt64
    package let listenPort: Int32
    package let networkBlocked: Bool
    package let hasListener: Bool
    package let endpoint: String
    package let lastError: String

    package static let empty = TorrentNetworkStatus(
        requestedRevision: 0,
        submittedRevision: 0,
        listenPort: 0,
        networkBlocked: true,
        hasListener: false,
        endpoint: "",
        lastError: ""
    )

    package init(
        requestedRevision: UInt64,
        submittedRevision: UInt64,
        listenPort: Int32,
        networkBlocked: Bool,
        hasListener: Bool,
        endpoint: String,
        lastError: String
    ) {
        self.requestedRevision = requestedRevision
        self.submittedRevision = submittedRevision
        self.listenPort = listenPort
        self.networkBlocked = networkBlocked
        self.hasListener = hasListener
        self.endpoint = endpoint
        self.lastError = lastError
    }

    package var isApplying: Bool {
        requestedRevision > submittedRevision
    }
}

package struct TorrentBridgeHealth: Equatable, Sendable {
    package let isAvailable: Bool
    package let totalAlertWorkerFailures: UInt64
    package let consecutiveAlertWorkerFailures: UInt64
    package let isAlertWorkerDegraded: Bool
    package let lastAlertWorkerError: String

    package static let healthy = TorrentBridgeHealth(
        isAvailable: true,
        totalAlertWorkerFailures: 0,
        consecutiveAlertWorkerFailures: 0,
        isAlertWorkerDegraded: false,
        lastAlertWorkerError: ""
    )

    package static let unavailable = TorrentBridgeHealth(
        isAvailable: false,
        totalAlertWorkerFailures: 0,
        consecutiveAlertWorkerFailures: 0,
        isAlertWorkerDegraded: false,
        lastAlertWorkerError: ""
    )

    package init(
        isAvailable: Bool,
        totalAlertWorkerFailures: UInt64,
        consecutiveAlertWorkerFailures: UInt64,
        isAlertWorkerDegraded: Bool,
        lastAlertWorkerError: String
    ) {
        self.isAvailable = isAvailable
        self.totalAlertWorkerFailures = totalAlertWorkerFailures
        self.consecutiveAlertWorkerFailures = consecutiveAlertWorkerFailures
        self.isAlertWorkerDegraded = isAlertWorkerDegraded
        self.lastAlertWorkerError = lastAlertWorkerError
    }
}
