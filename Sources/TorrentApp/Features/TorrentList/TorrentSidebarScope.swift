import Foundation
import TorrentEngineModel

enum TorrentSidebarScope: String, CaseIterable, Identifiable {
    case all
    case active
    case downloading
    case seeding
    case queued
    case paused
    case completed
    case errors
    case priorityHigh
    case priorityNormal
    case priorityLow

    static let statusScopes: [Self] = [
        .all,
        .active,
        .downloading,
        .seeding,
        .queued,
        .paused,
        .completed,
        .errors,
    ]

    static let statusFilterScopes: [Self] = [
        .active,
        .downloading,
        .seeding,
        .queued,
        .paused,
        .completed,
        .errors,
    ]

    static let priorityScopes: [Self] = [
        .priorityHigh,
        .priorityNormal,
        .priorityLow,
    ]

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .active:
            return "Active"
        case .downloading:
            return "Downloading"
        case .seeding:
            return "Seeding"
        case .queued:
            return "Queued"
        case .paused:
            return "Paused"
        case .completed:
            return "Completed"
        case .errors:
            return "Errors"
        case .priorityHigh:
            return "High"
        case .priorityNormal:
            return "Normal"
        case .priorityLow:
            return "Low"
        }
    }

    var emptyTitle: String {
        switch self {
        case .all:
            return "No Torrents"
        case .active:
            return "No Active Torrents"
        case .downloading:
            return "No Downloading Torrents"
        case .seeding:
            return "No Seeding Torrents"
        case .queued:
            return "No Queued Torrents"
        case .paused:
            return "No Paused Torrents"
        case .completed:
            return "No Completed Torrents"
        case .errors:
            return "No Torrent Errors"
        case .priorityHigh:
            return "No High Priority Torrents"
        case .priorityNormal:
            return "No Normal Priority Torrents"
        case .priorityLow:
            return "No Low Priority Torrents"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "tray.full"
        case .active:
            return "bolt.circle"
        case .downloading:
            return "arrow.down.circle"
        case .seeding:
            return "arrow.up.circle"
        case .queued:
            return "clock.circle"
        case .paused:
            return "pause.circle"
        case .completed:
            return "checkmark.circle"
        case .errors:
            return "exclamationmark.triangle"
        case .priorityHigh:
            return "arrow.up.circle"
        case .priorityNormal:
            return "equal.circle"
        case .priorityLow:
            return "arrow.down.circle"
        }
    }

    var isPriorityScope: Bool {
        switch self {
        case .priorityHigh, .priorityNormal, .priorityLow:
            return true
        case .all, .active, .downloading, .seeding, .queued, .paused, .completed, .errors:
            return false
        }
    }

    var isStatusFilterScope: Bool {
        switch self {
        case .active, .downloading, .seeding, .queued, .paused, .completed, .errors:
            return true
        case .all, .priorityHigh, .priorityNormal, .priorityLow:
            return false
        }
    }

    func contains(_ torrent: TorrentItem) -> Bool {
        switch self {
        case .all:
            return true
        case .active:
            return torrent.isActiveTransfer
        case .downloading:
            return torrent.error.isEmpty
                && !torrent.paused
                && !torrent.downloadComplete
                && (torrent.state == .downloading || torrent.state == .downloadingMetadata || !torrent.hasMetadata)
        case .seeding:
            return torrent.error.isEmpty && torrent.seeding && !torrent.paused
        case .queued:
            return torrent.error.isEmpty && torrent.queued
        case .paused:
            return torrent.error.isEmpty && torrent.manuallyPaused
        case .completed:
            return torrent.error.isEmpty && torrent.finished
        case .errors:
            return !torrent.error.isEmpty
        case .priorityHigh:
            return torrent.queuePriority == .high
        case .priorityNormal:
            return torrent.queuePriority == .normal
        case .priorityLow:
            return torrent.queuePriority == .low
        }
    }

    func contains(_ row: TorrentRowSnapshot) -> Bool {
        switch self {
        case .all:
            return true
        case .active:
            return row.active
        case .downloading:
            return row.error.isEmpty
                && !row.paused
                && !row.downloadComplete
                && (row.state == .downloading || row.state == .downloadingMetadata || !row.hasMetadata)
        case .seeding:
            return row.error.isEmpty && row.seeding && !row.paused
        case .queued:
            return row.error.isEmpty && row.queued
        case .paused:
            return row.error.isEmpty && row.manuallyPaused
        case .completed:
            return row.error.isEmpty && row.finished
        case .errors:
            return !row.error.isEmpty
        case .priorityHigh:
            return row.queuePriority == .high
        case .priorityNormal:
            return row.queuePriority == .normal
        case .priorityLow:
            return row.queuePriority == .low
        }
    }
}
