import Foundation
import TorrentEngineModel

struct TorrentLabelStore {
    private struct Storage: Codable {
        var labels: [TorrentLabel]
        var assignments: [TorrentItem.ID: [TorrentLabel.ID]]
    }

    private static let defaultsKey = "TorrentLabels.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> (labels: [TorrentLabel], assignments: [TorrentItem.ID: Set<TorrentLabel.ID>]) {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let storage = try? JSONDecoder().decode(Storage.self, from: data) else {
            return ([], [:])
        }

        let labelIDs = Set(storage.labels.map(\.id))
        let assignments = storage.assignments.reduce(into: [TorrentItem.ID: Set<TorrentLabel.ID>]()) { result, item in
            let validIDs = Set(item.value).intersection(labelIDs)
            if !validIDs.isEmpty {
                result[item.key] = validIDs
            }
        }

        return (storage.labels, assignments)
    }

    func save(labels: [TorrentLabel], assignments: [TorrentItem.ID: Set<TorrentLabel.ID>]) {
        let labelIDs = Set(labels.map(\.id))
        let sanitizedAssignments = assignments.reduce(into: [TorrentItem.ID: [TorrentLabel.ID]]()) { result, item in
            let validIDs = item.value.intersection(labelIDs)
            if !validIDs.isEmpty {
                result[item.key] = Array(validIDs).sorted()
            }
        }

        let storage = Storage(labels: labels, assignments: sanitizedAssignments)
        guard let data = try? JSONEncoder().encode(storage) else {
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
