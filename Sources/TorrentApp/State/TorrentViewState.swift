import Foundation
import Observation
import TorrentEngineModel

struct TorrentCommandSnapshot: Equatable, Sendable {
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

    @concurrent
    static func prepare(
        torrentsByID: [TorrentItem.ID: TorrentItem],
        selectedIDs: Set<TorrentItem.ID>,
        sortOrder: TorrentSortOrder,
        sortDirection: TorrentSortDirection,
        canPauseAnyTorrent: Bool,
        canResumeAnyTorrent: Bool
    ) async throws -> Self {
        try Task.checkCancellation()
        var selectedTorrentCount = 0
        var canPauseSelectedTorrents = false
        var canResumeSelectedTorrents = false
        var canForceRecheckSelectedTorrents = false
        for (offset, id) in selectedIDs.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            guard let torrent = torrentsByID[id] else {
                continue
            }
            selectedTorrentCount += 1
            canPauseSelectedTorrents =
                canPauseSelectedTorrents || !torrent.manuallyPaused
            canResumeSelectedTorrents =
                canResumeSelectedTorrents || torrent.manuallyPaused
            canForceRecheckSelectedTorrents =
                canForceRecheckSelectedTorrents || torrent.hasMetadata
        }
        try Task.checkCancellation()
        return Self(
            hasTorrents: !torrentsByID.isEmpty,
            sortOrder: sortOrder,
            sortDirection: sortDirection,
            selectedTorrentCount: selectedTorrentCount,
            hasSingleSelectedTorrent: selectedTorrentCount == 1,
            canPauseSelectedTorrents: canPauseSelectedTorrents,
            canResumeSelectedTorrents: canResumeSelectedTorrents,
            canPauseAnyTorrent: canPauseAnyTorrent,
            canResumeAnyTorrent: canResumeAnyTorrent,
            canForceRecheckSelectedTorrents:
                canForceRecheckSelectedTorrents
        )
    }
}

struct TorrentListPresentation: Sendable {
    let torrents: [TorrentItem]
    let torrentsChanged: Bool
    let torrentsByID: [TorrentItem.ID: TorrentItem]
    let activeIDs: Set<TorrentItem.ID>
    let completionProjection: TorrentCompletionProjection
    let rows: [TorrentRowSnapshot]
    let rowsChanged: Bool
    let metricsByID: [TorrentItem.ID: TorrentTransferMetrics]
    let totalDownloadRate: Int64
    let totalUploadRate: Int64
    let dockDownloadRate: Int64
    let dockUploadRate: Int64
    let hasActiveTransfers: Bool
    let canPauseAnyTorrent: Bool
    let canResumeAnyTorrent: Bool

    @concurrent
    static func prepare(
        torrents: [TorrentItem],
        previousTorrents: [TorrentItem],
        previousRows: [TorrentRowSnapshot]
    ) async throws -> Self {
        var torrentsByID = [TorrentItem.ID: TorrentItem]()
        var activeIDs = Set<TorrentItem.ID>()
        var rows = [TorrentRowSnapshot]()
        var metricsByID = [TorrentItem.ID: TorrentTransferMetrics]()
        var completedTorrents = [TorrentCompletionCandidate]()
        var completedIDs = Set<TorrentItem.ID>()
        torrentsByID.reserveCapacity(torrents.count)
        activeIDs.reserveCapacity(torrents.count)
        rows.reserveCapacity(torrents.count)
        metricsByID.reserveCapacity(torrents.count)
        completedTorrents.reserveCapacity(torrents.count)
        completedIDs.reserveCapacity(torrents.count)

        var totalDownloadRate: Int64 = 0
        var totalUploadRate: Int64 = 0
        var dockDownloadRate: Int64 = 0
        var dockUploadRate: Int64 = 0
        var hasActiveTransfers = false
        var canPauseAnyTorrent = false
        var canResumeAnyTorrent = false

        for (index, torrent) in torrents.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if torrentsByID[torrent.id] == nil {
                torrentsByID[torrent.id] = torrent
            }
            activeIDs.insert(torrent.id)
            rows.append(TorrentRowSnapshot(torrent))
            metricsByID[torrent.id] = TorrentTransferMetrics(torrent)
            if torrent.downloadComplete {
                completedTorrents.append(TorrentCompletionCandidate(
                    id: torrent.id,
                    name: torrent.name
                ))
                completedIDs.insert(torrent.id)
            }
            totalDownloadRate += Int64(max(0, torrent.downloadRate))
            totalUploadRate += Int64(max(0, torrent.uploadRate))
            dockDownloadRate += Int64(max(0, torrent.downloadPayloadRate))
            dockUploadRate += Int64(max(0, torrent.uploadPayloadRate))
            hasActiveTransfers = hasActiveTransfers
                || torrent.downloadPayloadRate > 0
                || torrent.uploadPayloadRate > 0
            canPauseAnyTorrent = canPauseAnyTorrent || !torrent.manuallyPaused
            canResumeAnyTorrent = canResumeAnyTorrent || torrent.manuallyPaused
        }
        try Task.checkCancellation()

        return Self(
            torrents: torrents,
            torrentsChanged: torrents != previousTorrents,
            torrentsByID: torrentsByID,
            activeIDs: activeIDs,
            completionProjection: TorrentCompletionProjection(
                completedTorrents: completedTorrents,
                completedIDs: completedIDs,
                activeIDs: activeIDs
            ),
            rows: rows,
            rowsChanged: rows != previousRows,
            metricsByID: metricsByID,
            totalDownloadRate: totalDownloadRate,
            totalUploadRate: totalUploadRate,
            dockDownloadRate: dockDownloadRate,
            dockUploadRate: dockUploadRate,
            hasActiveTransfers: hasActiveTransfers,
            canPauseAnyTorrent: canPauseAnyTorrent,
            canResumeAnyTorrent: canResumeAnyTorrent
        )
    }

    @concurrent
    static func prepareRemoving(
        _ removedIDs: Set<TorrentItem.ID>,
        from torrents: [TorrentItem],
        previousRows: [TorrentRowSnapshot]
    ) async throws -> Self {
        var remainingTorrents = [TorrentItem]()
        remainingTorrents.reserveCapacity(torrents.count)
        for (index, torrent) in torrents.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if !removedIDs.contains(torrent.id) {
                remainingTorrents.append(torrent)
            }
        }
        return try await prepare(
            torrents: remainingTorrents,
            previousTorrents: torrents,
            previousRows: previousRows
        )
    }

    @concurrent
    static func prepareSorted(
        torrents: [TorrentItem],
        sortOrder: TorrentSortOrder,
        sortDirection: TorrentSortDirection,
        previousRows: [TorrentRowSnapshot]
    ) async throws -> Self {
        try Task.checkCancellation()
        let sortedTorrents = sortOrder.sorted(torrents, direction: sortDirection)
        try Task.checkCancellation()
        return try await prepare(
            torrents: sortedTorrents,
            previousTorrents: torrents,
            previousRows: previousRows
        )
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
            precondition(revision != UInt64.max)
            revision += 1
            didChange?()
        }
    }

    @ObservationIgnored
    private(set) var revision: UInt64 = 0

    @ObservationIgnored
    var didChange: (() -> Void)?
}

@MainActor
@Observable
final class TorrentListState {
    private struct TransferMetricStateEntry {
        let state: TorrentTransferMetricsState
        var registrationIDs = Set<UUID>()
    }

    private(set) var torrents: [TorrentItem] = []
    private(set) var torrentsByID = [TorrentItem.ID: TorrentItem]()
    private(set) var rows: [TorrentRowSnapshot] = []
    private(set) var totalDownloadRate: Int64 = 0
    private(set) var totalUploadRate: Int64 = 0
    private(set) var dockDownloadRate: Int64 = 0
    private(set) var dockUploadRate: Int64 = 0
    private(set) var hasActiveTransfers = false
    private(set) var rowRevision: UInt64 = 0
    private(set) var canPauseAnyTorrent = false
    private(set) var canResumeAnyTorrent = false

    @ObservationIgnored
    private var transferMetricStateEntriesByID =
        [TorrentItem.ID: TransferMetricStateEntry]()

    @ObservationIgnored
    private var metricsByID = [TorrentItem.ID: TorrentTransferMetrics]()

    @ObservationIgnored
    private let emptyTransferMetricState = TorrentTransferMetricsState(metrics: .empty)

    func update(_ presentation: TorrentListPresentation) {
        var staleMetricStateIDs = [TorrentItem.ID]()
        staleMetricStateIDs.reserveCapacity(transferMetricStateEntriesByID.count)
        for (torrentID, entry) in transferMetricStateEntriesByID {
            if let metrics = presentation.metricsByID[torrentID] {
                entry.state.update(metrics)
                if entry.registrationIDs.isEmpty {
                    staleMetricStateIDs.append(torrentID)
                }
            } else {
                staleMetricStateIDs.append(torrentID)
            }
        }
        for torrentID in staleMetricStateIDs {
            transferMetricStateEntriesByID.removeValue(forKey: torrentID)
        }
        metricsByID = presentation.metricsByID

        if presentation.rowsChanged {
            rows = presentation.rows
            rowRevision &+= 1
        }

        if presentation.totalDownloadRate != totalDownloadRate {
            totalDownloadRate = presentation.totalDownloadRate
        }

        if presentation.totalUploadRate != totalUploadRate {
            totalUploadRate = presentation.totalUploadRate
        }

        dockDownloadRate = presentation.dockDownloadRate
        dockUploadRate = presentation.dockUploadRate
        hasActiveTransfers = presentation.hasActiveTransfers
        canPauseAnyTorrent = presentation.canPauseAnyTorrent
        canResumeAnyTorrent = presentation.canResumeAnyTorrent
        torrents = presentation.torrents
        torrentsByID = presentation.torrentsByID
    }

    func torrent(id: TorrentItem.ID) -> TorrentItem? {
        torrentsByID[id]
    }

    func transferMetricState(for torrentID: TorrentItem.ID) -> TorrentTransferMetricsState {
        if let entry = transferMetricStateEntriesByID[torrentID] {
            return entry.state
        }
        guard let metrics = metricsByID[torrentID] else {
            return emptyTransferMetricState
        }
        let state = TorrentTransferMetricsState(metrics: metrics)
        transferMetricStateEntriesByID[torrentID] = TransferMetricStateEntry(state: state)
        return state
    }

    func registerTransferMetricState(
        for torrentID: TorrentItem.ID,
        state: TorrentTransferMetricsState,
        registrationID: UUID
    ) {
        guard let metrics = metricsByID[torrentID] else {
            return
        }
        state.update(metrics)
        if var entry = transferMetricStateEntriesByID[torrentID] {
            precondition(
                entry.state === state,
                "One torrent row must use one transfer-metric state"
            )
            entry.registrationIDs.insert(registrationID)
            transferMetricStateEntriesByID[torrentID] = entry
        } else {
            transferMetricStateEntriesByID[torrentID] = TransferMetricStateEntry(
                state: state,
                registrationIDs: [registrationID]
            )
        }
    }

    func unregisterTransferMetricState(
        for torrentID: TorrentItem.ID,
        registrationID: UUID
    ) {
        guard var entry = transferMetricStateEntriesByID[torrentID] else {
            return
        }
        entry.registrationIDs.remove(registrationID)
        if entry.registrationIDs.isEmpty {
            transferMetricStateEntriesByID.removeValue(forKey: torrentID)
        } else {
            transferMetricStateEntriesByID[torrentID] = entry
        }
    }

    var registeredTransferMetricStateCount: Int {
        transferMetricStateEntriesByID.values.count {
            !$0.registrationIDs.isEmpty
        }
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

struct TorrentSidebarLabelSnapshot: Equatable, Identifiable, Sendable {
    var label: TorrentLabel
    var count: Int

    var id: TorrentLabel.ID {
        label.id
    }
}

struct TorrentSidebarTrackerHostSnapshot: Equatable, Identifiable, Sendable {
    var host: String
    var count: Int

    var id: String {
        host
    }
}

struct TorrentSidebarSnapshot: Equatable, Sendable {
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
        build(
            torrents: torrents,
            labels: labels,
            labelAssignments: labelAssignments,
            trackerHostsByTorrentID: trackerHostsByTorrentID,
            checkCancellation: {}
        )
    }

    @concurrent
    static func prepare(
        torrents: [TorrentItem],
        labels: [TorrentLabel],
        labelAssignments: [TorrentItem.ID: Set<TorrentLabel.ID>],
        trackerHostsByTorrentID: [TorrentItem.ID: Set<String>]
    ) async throws -> Self {
        try build(
            torrents: torrents,
            labels: labels,
            labelAssignments: labelAssignments,
            trackerHostsByTorrentID: trackerHostsByTorrentID,
            checkCancellation: {
                try Task.checkCancellation()
            }
        )
    }

    private static func build(
        torrents: [TorrentItem],
        labels: [TorrentLabel],
        labelAssignments: [TorrentItem.ID: Set<TorrentLabel.ID>],
        trackerHostsByTorrentID: [TorrentItem.ID: Set<String>],
        checkCancellation: () throws -> Void
    ) rethrows -> Self {
        let validLabelIDs = Set(labels.map(\.id))
        var scopeCounts = Dictionary(uniqueKeysWithValues: TorrentSidebarScope.allCases.map { ($0, 0) })
        var labelCounts = [TorrentLabel.ID: Int]()
        var unlabeledCount = 0
        var trackerHostCounts = [String: Int]()
        var noTrackersCount = 0

        for (index, torrent) in torrents.enumerated() {
            if index.isMultiple(of: 128) {
                try checkCancellation()
            }
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

        try checkCancellation()
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
    var networkInterfacesAreAuthoritative: Bool
    var selectedTab: TorrentSettingsTab

    init(
        settings: TorrentSettings,
        downloadFolder: URL?,
        networkInterfaces: [NetworkInterfaceOption] = [],
        networkInterfacesAreAuthoritative: Bool = true,
        selectedTab: TorrentSettingsTab = .general
    ) {
        self.settings = settings
        self.downloadFolder = downloadFolder
        self.networkInterfaces = networkInterfaces
        self.networkInterfacesAreAuthoritative = networkInterfacesAreAuthoritative
        self.selectedTab = selectedTab
    }

    var selectableNetworkInterfaces: [NetworkInterfaceOption] {
        settings.showOnlyVPNInterfaces ? networkInterfaces.filter(\.isVPNBacked) : networkInterfaces
    }

    var requiredNetworkInterfaceAvailable: Bool {
        guard settings.requireNetworkInterface else {
            return true
        }
        guard networkInterfacesAreAuthoritative else {
            return false
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
        guard networkInterfacesAreAuthoritative else {
            return "Refreshing interfaces…"
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
