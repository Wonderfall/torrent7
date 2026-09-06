import Foundation

package enum TorrentQueuePriority: Int32, Codable, CaseIterable, Identifiable, Sendable {
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

package enum TorrentQueueMove: Int32, Codable, Sendable {
    case top = 0
    case up = 1
    case down = 2
    case bottom = 3

}

/// A zero-based position among unfinished torrents. Restoration respects
/// priority groups and bounds the position to the remaining live queue.
package struct TorrentQueuePosition: RawRepresentable, Codable, Equatable, Sendable {
    package let rawValue: Int32

    package init?(rawValue: Int32) {
        guard (0..<TorrentEngineLimits.maximumTorrentSnapshotCount).contains(Int(rawValue)) else {
            return nil
        }
        self.rawValue = rawValue
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int32.self)
        guard let position = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "The torrent queue position is out of range."
            )
        }
        self = position
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

package struct TorrentOptions: Codable, Equatable, Sendable {
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
