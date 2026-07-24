import Foundation
import TorrentEngineModel

struct TorrentPreferencesSnapshot: Sendable {
    let settings: TorrentSettings
    let sortOrder: TorrentSortOrder
    let sortDirections: [TorrentSortOrder: TorrentSortDirection]

    var selectedSortDirection: TorrentSortDirection {
        sortDirections[sortOrder] ?? sortOrder.defaultDirection
    }
}

actor TorrentPreferencesStore {
    private let domain: TorrentDefaultsDomain
    private var defaults: UserDefaults?
    private var newestSettingsRevision: UInt64 = 0
    private var newestSortRevision: UInt64 = 0

    init(domain: TorrentDefaultsDomain = .standard) {
        self.domain = domain
    }

    func load() async throws -> TorrentPreferencesSnapshot {
        try Task.checkCancellation()
        let defaults = userDefaults
        let settings = TorrentSettings.load(defaults: defaults)
        let sortOrder = TorrentSortOrder.load(defaults: defaults)
        var sortDirections = [TorrentSortOrder: TorrentSortDirection]()
        sortDirections.reserveCapacity(TorrentSortOrder.allCases.count)
        for order in TorrentSortOrder.allCases {
            sortDirections[order] = TorrentSortDirection.load(
                for: order,
                defaults: defaults
            )
        }
        try Task.checkCancellation()
        return TorrentPreferencesSnapshot(
            settings: settings,
            sortOrder: sortOrder,
            sortDirections: sortDirections
        )
    }

    func saveSettings(
        _ settings: TorrentSettings,
        revision: UInt64
    ) async throws {
        guard revision >= newestSettingsRevision else {
            return
        }
        newestSettingsRevision = revision
        try Task.checkCancellation()
        settings.save(defaults: userDefaults)
    }

    func saveSorting(
        order: TorrentSortOrder,
        direction: TorrentSortDirection,
        revision: UInt64
    ) async throws {
        guard revision >= newestSortRevision else {
            return
        }
        newestSortRevision = revision
        try Task.checkCancellation()
        let defaults = userDefaults
        order.save(defaults: defaults)
        direction.save(for: order, defaults: defaults)
    }

    private var userDefaults: UserDefaults {
        if let defaults {
            return defaults
        }
        let defaults = domain.makeUserDefaults()
        self.defaults = defaults
        return defaults
    }
}
