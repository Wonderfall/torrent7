import Testing
@testable import TorrentApp

@Suite("Torrent sorting")
struct TorrentSortingTests {
    @Test("Persists sort orders in isolated defaults", arguments: TorrentSortOrder.allCases)
    func persistsSortOrdersInIsolatedDefaults(_ sortOrder: TorrentSortOrder) throws {
        try withIsolatedDefaults { defaults in
            sortOrder.save(defaults: defaults)
            #expect(TorrentSortOrder.load(defaults: defaults) == sortOrder)
        }
    }

    @Test("Falls back to default sort directions")
    func fallsBackToDefaultSortDirections() throws {
        try withIsolatedDefaults { defaults in
            #expect(TorrentSortDirection.load(for: .dateAdded, defaults: defaults) == .ascending)
            #expect(TorrentSortDirection.load(for: .progress, defaults: defaults) == .descending)
        }
    }

    @Test("Falls back when persisted sort values are invalid")
    func fallsBackWhenPersistedSortValuesAreInvalid() throws {
        try withIsolatedDefaults { defaults in
            defaults.set("bogus", forKey: "TorrentSortOrder")
            defaults.set("sideways", forKey: "TorrentSortDirection.name")

            #expect(TorrentSortOrder.load(defaults: defaults) == .dateAdded)
            #expect(TorrentSortDirection.load(for: .name, defaults: defaults) == .ascending)
        }
    }

    @Test("Priority choices show most important first")
    func priorityChoicesShowMostImportantFirst() {
        #expect(TorrentQueuePriority.allCases == [.high, .normal, .low])
    }

    @Test("Sorts by progress and breaks ties by name")
    func sortsByProgressAndBreaksTiesByName() {
        let torrents = [
            makeTorrent(id: "beta", name: "Beta", progress: 0.5),
            makeTorrent(id: "gamma", name: "Gamma", progress: 0.9),
            makeTorrent(id: "alpha", name: "Alpha", progress: 0.5)
        ]

        let sorted = TorrentSortOrder.progress.sorted(torrents, direction: .descending)

        #expect(sorted.map(\.id) == ["gamma", "alpha", "beta"])
    }

    @Test("Sorts by priority and queue position")
    func sortsByPriorityAndQueuePosition() {
        let torrents = [
            makeTorrent(id: "normal", name: "Normal", queuePosition: 0, queuePriority: .normal),
            makeTorrent(id: "high-later", name: "High Later", queuePosition: 2, queuePriority: .high),
            makeTorrent(id: "low", name: "Low", queuePosition: 0, queuePriority: .low),
            makeTorrent(id: "high-earlier", name: "High Earlier", queuePosition: 1, queuePriority: .high)
        ]

        let sorted = TorrentSortOrder.priority.sorted(torrents, direction: .ascending)

        #expect(sorted.map(\.id) == ["high-earlier", "high-later", "normal", "low"])
    }
}
