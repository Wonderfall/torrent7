import Foundation
import TorrentEngineModel

enum TorrentSidebarSelection: Hashable, Identifiable {
    case scope(TorrentSidebarScope)
    case unlabeled
    case label(TorrentLabel.ID)
    case noTrackers
    case trackerHost(String)

    static let all = TorrentSidebarSelection.scope(.all)

    var id: String {
        switch self {
        case .scope(let scope):
            return "scope:\(scope.rawValue)"
        case .unlabeled:
            return "builtin:unlabeled"
        case .label(let labelID):
            return "label:\(labelID)"
        case .noTrackers:
            return "builtin:no-trackers"
        case .trackerHost(let host):
            return "tracker:\(host)"
        }
    }

    var isPriorityScope: Bool {
        guard case .scope(let scope) = self else {
            return false
        }
        return scope.isPriorityScope
    }

    var isStatusFilterScope: Bool {
        guard case .scope(let scope) = self else {
            return false
        }
        return scope.isStatusFilterScope
    }

    var isLabelScope: Bool {
        switch self {
        case .unlabeled, .label:
            return true
        case .scope, .noTrackers, .trackerHost:
            return false
        }
    }

    var isTrackerScope: Bool {
        switch self {
        case .noTrackers, .trackerHost:
            return true
        case .scope, .unlabeled, .label:
            return false
        }
    }

    func contains(_ torrent: TorrentItem, labelIDs: Set<TorrentLabel.ID>, trackerHosts: Set<String>) -> Bool {
        switch self {
        case .scope(let scope):
            return scope.contains(torrent)
        case .unlabeled:
            return labelIDs.isEmpty
        case .label(let labelID):
            return labelIDs.contains(labelID)
        case .noTrackers:
            return trackerHosts.isEmpty
        case .trackerHost(let host):
            return trackerHosts.contains(host)
        }
    }

    func contains(_ row: TorrentRowSnapshot, labelIDs: Set<TorrentLabel.ID>, trackerHosts: Set<String>) -> Bool {
        switch self {
        case .scope(let scope):
            return scope.contains(row)
        case .unlabeled:
            return labelIDs.isEmpty
        case .label(let labelID):
            return labelIDs.contains(labelID)
        case .noTrackers:
            return trackerHosts.isEmpty
        case .trackerHost(let host):
            return trackerHosts.contains(host)
        }
    }

    func emptyTitle(labels: [TorrentLabel]) -> String {
        switch self {
        case .scope(let scope):
            return scope.emptyTitle
        case .unlabeled:
            return "No Unlabeled Torrents"
        case .label(let labelID):
            guard let label = labels.first(where: { $0.id == labelID }) else {
                return "No Labeled Torrents"
            }
            return "No \(label.name) Torrents"
        case .noTrackers:
            return "No Torrents Without Trackers"
        case .trackerHost(let host):
            return "No Torrents from \(host)"
        }
    }

    func emptySystemImage(labels: [TorrentLabel]) -> String {
        switch self {
        case .scope(let scope):
            return scope.systemImage
        case .unlabeled:
            return "tag.slash"
        case .label:
            return "tag"
        case .noTrackers:
            return "antenna.radiowaves.left.and.right.slash"
        case .trackerHost:
            return "antenna.radiowaves.left.and.right"
        }
    }
}
