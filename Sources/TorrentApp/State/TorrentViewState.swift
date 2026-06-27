import Foundation
import Observation

struct TorrentCommandSnapshot: Equatable {
    var hasTorrents = false
    var sortOrder = TorrentSortOrder.dateAdded
    var sortDirection = TorrentSortDirection.ascending
    var selectedTorrentCount = 0
    var hasSingleSelectedTorrent = false
    var canPauseSelectedTorrents = false
    var canResumeSelectedTorrents = false
    var canPauseAnyTorrent = false
    var canResumeAnyTorrent = false
    var canForceRecheckSelectedTorrents = false

    var hasSelectedTorrents: Bool {
        selectedTorrentCount > 0
    }
}

@MainActor
@Observable
final class TorrentCommandState {
    private(set) var snapshot = TorrentCommandSnapshot()

    func update(_ snapshot: TorrentCommandSnapshot) {
        guard snapshot != self.snapshot else {
            return
        }
        self.snapshot = snapshot
    }
}

@MainActor
@Observable
final class TorrentSelectionState {
    var ids = Set<TorrentItem.ID>() {
        didSet {
            guard ids != oldValue else {
                return
            }
            didChange?()
        }
    }

    @ObservationIgnored
    var didChange: (() -> Void)?
}

@MainActor
@Observable
final class TorrentListState {
    private(set) var torrents: [TorrentItem] = []
    private(set) var rows: [TorrentRowSnapshot] = []
    private(set) var totalDownloadRate: Int64 = 0
    private(set) var totalUploadRate: Int64 = 0

    @ObservationIgnored
    private var transferMetricStatesByID = [TorrentItem.ID: TorrentTransferMetricsState]()

    @ObservationIgnored
    private let emptyTransferMetricState = TorrentTransferMetricsState(metrics: .empty)

    func update(_ torrents: [TorrentItem]) {
        let activeIDs = Set(torrents.map(\.id))
        transferMetricStatesByID = transferMetricStatesByID.filter { activeIDs.contains($0.key) }

        for torrent in torrents {
            let metrics = TorrentTransferMetrics(torrent)
            if let state = transferMetricStatesByID[torrent.id] {
                state.update(metrics)
            } else {
                transferMetricStatesByID[torrent.id] = TorrentTransferMetricsState(metrics: metrics)
            }
        }

        let rows = torrents.map(TorrentRowSnapshot.init)
        if rows != self.rows {
            self.rows = rows
        }

        let totalDownloadRate = torrents.reduce(Int64(0)) { total, torrent in
            total + Int64(max(0, torrent.downloadRate))
        }
        if totalDownloadRate != self.totalDownloadRate {
            self.totalDownloadRate = totalDownloadRate
        }

        let totalUploadRate = torrents.reduce(Int64(0)) { total, torrent in
            total + Int64(max(0, torrent.uploadRate))
        }
        if totalUploadRate != self.totalUploadRate {
            self.totalUploadRate = totalUploadRate
        }

        if torrents != self.torrents {
            self.torrents = torrents
        }
    }

    func transferMetricState(for torrentID: TorrentItem.ID) -> TorrentTransferMetricsState {
        transferMetricStatesByID[torrentID] ?? emptyTransferMetricState
    }
}

@MainActor
@Observable
final class TorrentTransferMetricsState {
    private(set) var metrics: TorrentTransferMetrics

    init(metrics: TorrentTransferMetrics) {
        self.metrics = metrics
    }

    func update(_ metrics: TorrentTransferMetrics) {
        guard metrics != self.metrics else {
            return
        }
        self.metrics = metrics
    }
}

struct TorrentSidebarLabelSnapshot: Equatable, Identifiable {
    var label: TorrentLabel
    var count: Int

    var id: TorrentLabel.ID {
        label.id
    }
}

struct TorrentSidebarTrackerHostSnapshot: Equatable, Identifiable {
    var host: String
    var count: Int

    var id: String {
        host
    }
}

struct TorrentSidebarSnapshot: Equatable {
    var scopeCounts: [TorrentSidebarScope: Int] = [:]
    var unlabeledCount = 0
    var labelRows: [TorrentSidebarLabelSnapshot] = []
    var noTrackersCount = 0
    var trackerHostRows: [TorrentSidebarTrackerHostSnapshot] = []

    func count(for scope: TorrentSidebarScope) -> Int {
        scopeCounts[scope] ?? 0
    }

    static func make(
        torrents: [TorrentItem],
        labels: [TorrentLabel],
        labelAssignments: [TorrentItem.ID: Set<TorrentLabel.ID>],
        trackerHostsByTorrentID: [TorrentItem.ID: Set<String>]
    ) -> Self {
        let validLabelIDs = Set(labels.map(\.id))
        var scopeCounts = Dictionary(uniqueKeysWithValues: TorrentSidebarScope.allCases.map { ($0, 0) })
        var labelCounts = [TorrentLabel.ID: Int]()
        var unlabeledCount = 0
        var trackerHostCounts = [String: Int]()
        var noTrackersCount = 0

        for torrent in torrents {
            for scope in TorrentSidebarScope.allCases where scope.contains(torrent) {
                scopeCounts[scope, default: 0] += 1
            }

            let assignedLabelIDs = (labelAssignments[torrent.id] ?? []).intersection(validLabelIDs)
            if assignedLabelIDs.isEmpty {
                unlabeledCount += 1
            } else {
                for labelID in assignedLabelIDs {
                    labelCounts[labelID, default: 0] += 1
                }
            }

            let trackerHosts = trackerHostsByTorrentID[torrent.id] ?? []
            if trackerHosts.isEmpty {
                noTrackersCount += 1
            } else {
                for host in trackerHosts {
                    trackerHostCounts[host, default: 0] += 1
                }
            }
        }

        return Self(
            scopeCounts: scopeCounts,
            unlabeledCount: unlabeledCount,
            labelRows: labels.map { label in
                TorrentSidebarLabelSnapshot(label: label, count: labelCounts[label.id] ?? 0)
            },
            noTrackersCount: noTrackersCount,
            trackerHostRows: trackerHostCounts.map { host, count in
                TorrentSidebarTrackerHostSnapshot(host: host, count: count)
            }
            .sorted { lhs, rhs in
                lhs.host.localizedStandardCompare(rhs.host) == .orderedAscending
            }
        )
    }
}

@MainActor
@Observable
final class TorrentSidebarState {
    private(set) var snapshot = TorrentSidebarSnapshot()

    func update(_ snapshot: TorrentSidebarSnapshot) {
        guard snapshot != self.snapshot else {
            return
        }
        self.snapshot = snapshot
    }
}

@MainActor
@Observable
final class TorrentSettingsState {
    var settings: TorrentSettings
    var downloadFolder: URL?
    var networkInterfaces: [NetworkInterfaceOption]
    var selectedTab: TorrentSettingsTab

    init(
        settings: TorrentSettings,
        downloadFolder: URL?,
        networkInterfaces: [NetworkInterfaceOption] = [],
        selectedTab: TorrentSettingsTab = .general
    ) {
        self.settings = settings
        self.downloadFolder = downloadFolder
        self.networkInterfaces = networkInterfaces
        self.selectedTab = selectedTab
    }

    var selectableNetworkInterfaces: [NetworkInterfaceOption] {
        settings.showOnlyVPNInterfaces ? networkInterfaces.filter(\.isVPNBacked) : networkInterfaces
    }

    var requiredNetworkInterfaceAvailable: Bool {
        guard settings.requireNetworkInterface else {
            return true
        }

        let interfaceName = settings.libtorrentRequiredNetworkInterfaceName
        guard !interfaceName.isEmpty,
              let option = networkInterfaces.first(where: { $0.name == interfaceName }) else {
            return false
        }

        return !settings.showOnlyVPNInterfaces || option.isVPNBacked
    }

    var networkProtectionStatusText: String {
        guard settings.requireNetworkInterface else {
            return "Off"
        }

        let interfaceName = settings.libtorrentRequiredNetworkInterfaceName
        guard !interfaceName.isEmpty else {
            return "Choose an interface"
        }

        guard let option = networkInterfaces.first(where: { $0.name == interfaceName }) else {
            return settings.showOnlyVPNInterfaces ? "\(interfaceName) VPN inactive" : "\(interfaceName) unavailable"
        }
        guard !settings.showOnlyVPNInterfaces || option.isVPNBacked else {
            return "\(interfaceName) VPN inactive"
        }
        return "Active on \(option.displayName)"
    }
}
