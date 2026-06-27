import Foundation

enum TorrentSortOrder: String, CaseIterable, Identifiable, Sendable {
    private static let defaultsKey = "TorrentSortOrder"

    case dateAdded
    case name
    case status
    case progress
    case downloadSpeed
    case uploadSpeed
    case peers
    case priority

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .dateAdded:
            return "Date Added"
        case .name:
            return "Name"
        case .status:
            return "Status"
        case .progress:
            return "Progress"
        case .downloadSpeed:
            return "Download Speed"
        case .uploadSpeed:
            return "Upload Speed"
        case .peers:
            return "Peers"
        case .priority:
            return "Priority"
        }
    }

    var defaultDirection: TorrentSortDirection {
        switch self {
        case .dateAdded, .name, .status, .priority:
            return .ascending
        case .progress, .downloadSpeed, .uploadSpeed, .peers:
            return .descending
        }
    }

    static func load(defaults: UserDefaults = .standard) -> TorrentSortOrder {
        guard let value = defaults.string(forKey: defaultsKey),
              let sortOrder = TorrentSortOrder(rawValue: value) else {
            return .dateAdded
        }
        return sortOrder
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    func sorted(_ torrents: [TorrentItem], direction: TorrentSortDirection) -> [TorrentItem] {
        torrents.sorted { lhs, rhs in
            let result = compare(lhs, rhs)
            if result != .orderedSame {
                return direction == .ascending ? result == .orderedAscending : result == .orderedDescending
            }
            return compareNames(lhs, rhs) == .orderedAscending
        }
    }

    private func compare(_ lhs: TorrentItem, _ rhs: TorrentItem) -> ComparisonResult {
        switch self {
        case .dateAdded:
            if lhs.addedTime != rhs.addedTime {
                return lhs.addedTime < rhs.addedTime ? .orderedAscending : .orderedDescending
            }
            return .orderedSame
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .status:
            if lhs.statusSortRank != rhs.statusSortRank {
                return lhs.statusSortRank < rhs.statusSortRank ? .orderedAscending : .orderedDescending
            }
            return .orderedSame
        case .progress:
            if lhs.progress != rhs.progress {
                return lhs.progress < rhs.progress ? .orderedAscending : .orderedDescending
            }
            return .orderedSame
        case .downloadSpeed:
            if lhs.downloadPayloadRate != rhs.downloadPayloadRate {
                return lhs.downloadPayloadRate < rhs.downloadPayloadRate ? .orderedAscending : .orderedDescending
            }
            return .orderedSame
        case .uploadSpeed:
            if lhs.uploadPayloadRate != rhs.uploadPayloadRate {
                return lhs.uploadPayloadRate < rhs.uploadPayloadRate ? .orderedAscending : .orderedDescending
            }
            return .orderedSame
        case .peers:
            if lhs.knownPeerCount != rhs.knownPeerCount {
                return lhs.knownPeerCount < rhs.knownPeerCount ? .orderedAscending : .orderedDescending
            }
            return .orderedSame
        case .priority:
            if prioritySortRank(lhs.queuePriority) != prioritySortRank(rhs.queuePriority) {
                return prioritySortRank(lhs.queuePriority) < prioritySortRank(rhs.queuePriority) ? .orderedAscending : .orderedDescending
            }
            if lhs.queuePosition != rhs.queuePosition {
                return lhs.queuePosition < rhs.queuePosition ? .orderedAscending : .orderedDescending
            }
            return .orderedSame
        }
    }

    private func compareNames(_ lhs: TorrentItem, _ rhs: TorrentItem) -> ComparisonResult {
        lhs.name.localizedStandardCompare(rhs.name)
    }

    private func prioritySortRank(_ priority: TorrentQueuePriority) -> Int {
        switch priority {
        case .high:
            0
        case .normal:
            1
        case .low:
            2
        }
    }
}

enum TorrentSortDirection: String, CaseIterable, Identifiable, Sendable {
    case ascending
    case descending

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .ascending:
            return "Ascending"
        case .descending:
            return "Descending"
        }
    }

    static func load(for sortOrder: TorrentSortOrder, defaults: UserDefaults = .standard) -> TorrentSortDirection {
        guard let value = defaults.string(forKey: defaultsKey(for: sortOrder)),
              let direction = TorrentSortDirection(rawValue: value) else {
            return sortOrder.defaultDirection
        }
        return direction
    }

    func save(for sortOrder: TorrentSortOrder, defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey(for: sortOrder))
    }

    private static func defaultsKey(for sortOrder: TorrentSortOrder) -> String {
        "TorrentSortDirection.\(sortOrder.rawValue)"
    }
}
