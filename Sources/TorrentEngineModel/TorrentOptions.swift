import Foundation

package enum TorrentQueuePriority: Int32, CaseIterable, Identifiable, Sendable {
    case low = 0
    case normal = 1
    case high = 2

    package static let allCases: [TorrentQueuePriority] = [.high, .normal, .low]

    package var id: Self { self }

    package var title: String {
        switch self {
        case .low:
            "Low"
        case .normal:
            "Normal"
        case .high:
            "High"
        }
    }

}

package enum TorrentQueueMove: Int32, Sendable {
    case top = 0
    case up = 1
    case down = 2
    case bottom = 3

}

package struct TorrentOptions: Equatable, Sendable {
    package var downloadRateLimitKBps: Int
    package var uploadRateLimitKBps: Int
    package var uploadSlotLimit: Int
    package var connectionLimit: Int
    package var queuePriority: TorrentQueuePriority

    package static let unlimited = TorrentOptions(
        downloadRateLimitKBps: 0,
        uploadRateLimitKBps: 0,
        uploadSlotLimit: 0,
        connectionLimit: 0,
        queuePriority: .normal
    )

    package init(
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

    package var normalized: TorrentOptions {
        TorrentOptions(
            downloadRateLimitKBps: downloadRateLimitKBps,
            uploadRateLimitKBps: uploadRateLimitKBps,
            uploadSlotLimit: uploadSlotLimit,
            connectionLimit: connectionLimit,
            queuePriority: queuePriority
        )
    }

    private static func clampedKilobytesPerSecond(_ value: Int) -> Int {
        min(max(value, 0), 1_000_000)
    }

    private static func clampedCountLimit(_ value: Int) -> Int {
        guard value > 0 else {
            return 0
        }
        return min(max(value, 2), 100_000)
    }
}
