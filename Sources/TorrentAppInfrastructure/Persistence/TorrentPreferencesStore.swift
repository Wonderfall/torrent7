import Foundation
package import TorrentEngineModel

package struct TorrentPreferencesSnapshot: Sendable {
    package let settings: Result<TorrentSettings, TorrentSettingsLoadError>
    package let sortOrder: TorrentSortOrder
    package let sortDirections: [TorrentSortOrder: TorrentSortDirection]

    package var selectedSortDirection: TorrentSortDirection {
        sortDirections[sortOrder] ?? sortOrder.defaultDirection
    }
}

package actor TorrentPreferencesStore {
    private let domain: TorrentDefaultsDomain
    private var defaults: UserDefaults?
    private var newestSettingsRevision: UInt64 = 0
    private var newestSortRevision: UInt64 = 0

    package init(domain: TorrentDefaultsDomain = .standard) {
        self.domain = domain
    }

    package func load() async throws -> TorrentPreferencesSnapshot {
        try Task.checkCancellation()
        let defaults = userDefaults
        let settings = Result { () throws(TorrentSettingsLoadError) in
            try TorrentSettings.load(defaults: defaults)
        }
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

    package func saveSettings(
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

    package func saveSorting(
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
