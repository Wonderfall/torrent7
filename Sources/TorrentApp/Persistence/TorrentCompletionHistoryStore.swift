import Foundation

protocol TorrentCompletionHistoryStoring: AnyObject {
    func contains(_ id: TorrentItem.ID) -> Bool
    func remember(_ ids: Set<TorrentItem.ID>)
    func forget(_ ids: Set<TorrentItem.ID>)
    func prune(retaining activeIDs: Set<TorrentItem.ID>)
}

final class TorrentCompletionHistoryStore: TorrentCompletionHistoryStoring {
    private let defaults: UserDefaults
    private var completedIDs: Set<TorrentItem.ID>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        completedIDs = Set(defaults.stringArray(forKey: TorrentCompletionKeys.completedTorrentIDs) ?? [])
    }

    func contains(_ id: TorrentItem.ID) -> Bool {
        completedIDs.contains(id)
    }

    func remember(_ ids: Set<TorrentItem.ID>) {
        guard !ids.isEmpty else {
            return
        }

        let updatedIDs = completedIDs.union(ids)
        guard updatedIDs != completedIDs else {
            return
        }

        completedIDs = updatedIDs
        save()
    }

    func forget(_ ids: Set<TorrentItem.ID>) {
        guard !ids.isEmpty else {
            return
        }

        let updatedIDs = completedIDs.subtracting(ids)
        guard updatedIDs != completedIDs else {
            return
        }

        completedIDs = updatedIDs
        save()
    }

    func prune(retaining activeIDs: Set<TorrentItem.ID>) {
        let updatedIDs = completedIDs.intersection(activeIDs)
        guard updatedIDs != completedIDs else {
            return
        }

        completedIDs = updatedIDs
        save()
    }

    private func save() {
        if completedIDs.isEmpty {
            defaults.removeObject(forKey: TorrentCompletionKeys.completedTorrentIDs)
        } else {
            defaults.set(completedIDs.sorted(), forKey: TorrentCompletionKeys.completedTorrentIDs)
        }
    }
}
