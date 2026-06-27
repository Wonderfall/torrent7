import Foundation
import TorrentBridge

enum TorrentQueuePriority: Int32, CaseIterable, Identifiable, Sendable {
    case low = 0
    case normal = 1
    case high = 2

    static let allCases: [TorrentQueuePriority] = [.high, .normal, .low]

    var id: Self { self }

    init(bridgeValue: Int32) {
        switch bridgeValue {
        case Self.low.rawValue:
            self = .low
        case Self.high.rawValue:
            self = .high
        default:
            self = .normal
        }
    }

    var title: String {
        switch self {
        case .low:
            "Low"
        case .normal:
            "Normal"
        case .high:
            "High"
        }
    }

    var bridgeValue: Int32 {
        rawValue
    }

    var bridgeByteValue: UInt8 {
        UInt8(bridgeValue)
    }
}

enum TorrentQueueMove: Int32, Sendable {
    case top = 0
    case up = 1
    case down = 2
    case bottom = 3

    var bridgeValue: Int32 {
        rawValue
    }
}

struct TorrentOptions: Equatable, Sendable {
    var downloadRateLimitKBps: Int
    var uploadRateLimitKBps: Int
    var uploadSlotLimit: Int
    var connectionLimit: Int
    var queuePriority: TorrentQueuePriority

    static let unlimited = TorrentOptions(
        downloadRateLimitKBps: 0,
        uploadRateLimitKBps: 0,
        uploadSlotLimit: 0,
        connectionLimit: 0,
        queuePriority: .normal
    )

    init(
        downloadRateLimitKBps: Int,
        uploadRateLimitKBps: Int,
        uploadSlotLimit: Int,
        connectionLimit: Int,
        queuePriority: TorrentQueuePriority = .normal
    ) {
        self.downloadRateLimitKBps = Self.clampedKilobytesPerSecond(downloadRateLimitKBps)
        self.uploadRateLimitKBps = Self.clampedKilobytesPerSecond(uploadRateLimitKBps)
        self.uploadSlotLimit = Self.clampedCountLimit(uploadSlotLimit)
        self.connectionLimit = Self.clampedCountLimit(connectionLimit)
        self.queuePriority = queuePriority
    }

    init(snapshot: TTorrentOptions) {
        self.init(
            downloadRateLimitKBps: Self.kilobytesPerSecond(fromBridgeLimit: snapshot.download_rate_limit),
            uploadRateLimitKBps: Self.kilobytesPerSecond(fromBridgeLimit: snapshot.upload_rate_limit),
            uploadSlotLimit: Self.countLimit(fromBridgeLimit: snapshot.max_uploads),
            connectionLimit: Self.countLimit(fromBridgeLimit: snapshot.max_connections),
            queuePriority: TorrentQueuePriority(bridgeValue: snapshot.queue_priority)
        )
    }

    var bridgeValue: TTorrentOptions {
        TTorrentOptions(
            download_rate_limit: Self.bridgeLimit(fromKilobytesPerSecond: downloadRateLimitKBps),
            upload_rate_limit: Self.bridgeLimit(fromKilobytesPerSecond: uploadRateLimitKBps),
            max_uploads: Self.bridgeCountLimit(fromCountLimit: uploadSlotLimit),
            max_connections: Self.bridgeCountLimit(fromCountLimit: connectionLimit),
            queue_priority: queuePriority.bridgeValue
        )
    }

    var normalized: TorrentOptions {
        TorrentOptions(
            downloadRateLimitKBps: downloadRateLimitKBps,
            uploadRateLimitKBps: uploadRateLimitKBps,
            uploadSlotLimit: uploadSlotLimit,
            connectionLimit: connectionLimit,
            queuePriority: queuePriority
        )
    }

    private static func kilobytesPerSecond(fromBridgeLimit limit: Int32) -> Int {
        guard limit > 0 else {
            return 0
        }
        return clampedKilobytesPerSecond(Int(limit) / 1024)
    }

    private static func bridgeLimit(fromKilobytesPerSecond value: Int) -> Int32 {
        value <= 0 ? -1 : Int32(clampedKilobytesPerSecond(value) * 1024)
    }

    private static func clampedKilobytesPerSecond(_ value: Int) -> Int {
        min(max(value, 0), 1_000_000)
    }

    private static func countLimit(fromBridgeLimit limit: Int32) -> Int {
        guard limit > 0 else {
            return 0
        }
        return clampedCountLimit(Int(limit))
    }

    private static func bridgeCountLimit(fromCountLimit value: Int) -> Int32 {
        value <= 0 ? -1 : Int32(clampedCountLimit(value))
    }

    private static func clampedCountLimit(_ value: Int) -> Int {
        guard value > 0 else {
            return 0
        }
        return min(max(value, 2), 100_000)
    }
}
