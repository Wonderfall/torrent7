import Foundation
import Testing
import TorrentEngineModel
@testable import TorrentApp

@MainActor
@Suite("Torrent command state")
struct TorrentCommandStateTests {
    @Test("Command snapshot reports selected torrent presence")
    func commandSnapshotReportsSelectedTorrentPresence() {
        #expect(TorrentCommandSnapshot(selectedTorrentCount: 0).hasSelectedTorrents == false)
        #expect(TorrentCommandSnapshot(selectedTorrentCount: 2).hasSelectedTorrents == true)
    }

    @Test("Command state updates snapshots")
    func commandStateUpdatesSnapshots() {
        let state = TorrentCommandState()
        let snapshot = TorrentCommandSnapshot(
            hasTorrents: true,
            sortOrder: .progress,
            sortDirection: .descending,
            selectedTorrentCount: 1,
            hasSingleSelectedTorrent: true,
            canPauseSelectedTorrents: true
        )

        state.update(snapshot)

        #expect(state.snapshot == snapshot)
    }

    @Test("Selection state notifies only when IDs change")
    func selectionStateNotifiesOnlyWhenIDsChange() {
        let state = TorrentSelectionState()
        var changeCount = 0
        state.didChange = {
            changeCount += 1
        }

        state.ids = ["alpha"]
        state.ids = ["alpha"]
        state.ids = ["beta"]

        #expect(changeCount == 2)
    }

    @Test("List state updates torrents")
    func listStateUpdatesTorrents() async throws {
        let state = TorrentListState()
        let torrents = [makeTorrent(id: "alpha")]

        try await update(state, with: torrents)

        #expect(state.torrents == torrents)
    }

    @Test("List state separates stable rows from transfer metrics")
    func listStateSeparatesStableRowsFromTransferMetrics() async throws {
        let state = TorrentListState()
        let baseTorrent = makeTorrent(
            id: "alpha",
            progress: 0.1,
            totalDone: 10,
            downloadRate: 100,
            uploadRate: 10,
            downloadPayloadRate: 90,
            uploadPayloadRate: 8,
            state: .downloading
        )

        try await update(state, with: [baseTorrent])
        let initialRows = state.rows
        let metricsState = state.transferMetricState(for: "alpha")
        let registrationID = UUID()
        state.registerTransferMetricState(
            for: "alpha",
            state: metricsState,
            registrationID: registrationID
        )

        #expect(initialRows == [TorrentRowSnapshot(baseTorrent)])
        #expect(metricsState.metrics.downloadRate == 100)

        try await update(state, with: [
            makeTorrent(
                id: "alpha",
                progress: 0.2,
                totalDone: 20,
                downloadRate: 200,
                uploadRate: 20,
                downloadPayloadRate: 180,
                uploadPayloadRate: 16,
                state: .downloading
            ),
        ])

        #expect(state.rows == initialRows)
        #expect(state.transferMetricState(for: "alpha") === metricsState)
        #expect(metricsState.metrics.progress == 0.2)
        #expect(metricsState.metrics.totalDone == 20)
        #expect(metricsState.metrics.downloadRate == 200)
        #expect(metricsState.metrics.uploadRate == 20)
        #expect(state.totalDownloadRate == 200)
        #expect(state.totalUploadRate == 20)
        state.unregisterTransferMetricState(
            for: "alpha",
            registrationID: registrationID
        )
    }

    @Test("Content kind changes replace stable list rows")
    func contentKindChangesReplaceStableRows() async throws {
        let state = TorrentListState()
        try await update(state, with: [makeTorrent(id: "alpha", contentKind: .unknown)])
        let initialRows = state.rows

        try await update(state, with: [makeTorrent(id: "alpha", contentKind: .directory)])

        #expect(state.rows != initialRows)
        #expect(state.rows.first?.contentKind == .directory)
    }

    @Test("List rows ignore rate-only inactive transfer changes")
    func listRowsIgnoreRateOnlyInactiveTransferChanges() async throws {
        let state = TorrentListState()
        let baseTorrent = makeTorrent(id: "alpha", state: .finished, finished: true)

        try await update(state, with: [baseTorrent])
        let initialRows = state.rows
        let metricsState = state.transferMetricState(for: "alpha")
        let registrationID = UUID()
        state.registerTransferMetricState(
            for: "alpha",
            state: metricsState,
            registrationID: registrationID
        )

        try await update(state, with: [
            makeTorrent(id: "alpha", uploadRate: 100, uploadPayloadRate: 80, state: .finished, finished: true),
        ])

        #expect(state.rows == initialRows)
        #expect(state.transferMetricState(for: "alpha") === metricsState)
        #expect(metricsState.metrics.uploadRate == 100)
        #expect(metricsState.metrics.uploadPayloadRate == 80)
        state.unregisterTransferMetricState(
            for: "alpha",
            registrationID: registrationID
        )
    }

    @Test("List state releases offscreen transfer metric state")
    func listStateReleasesOffscreenTransferMetricState() async throws {
        let state = TorrentListState()
        try await update(state, with: [
            makeTorrent(id: "alpha", downloadRate: 100, state: .downloading),
        ])
        let registrationID = UUID()
        let visibleState = state.transferMetricState(for: "alpha")
        state.registerTransferMetricState(
            for: "alpha",
            state: visibleState,
            registrationID: registrationID
        )

        #expect(state.registeredTransferMetricStateCount == 1)

        state.unregisterTransferMetricState(
            for: "alpha",
            registrationID: registrationID
        )
        try await update(state, with: [
            makeTorrent(id: "alpha", downloadRate: 200, state: .downloading),
        ])
        let rematerializedState = state.transferMetricState(for: "alpha")

        #expect(state.registeredTransferMetricStateCount == 0)
        #expect(rematerializedState !== visibleState)
        #expect(visibleState.metrics.downloadRate == 100)
        #expect(rematerializedState.metrics.downloadRate == 200)
    }

    private func update(
        _ state: TorrentListState,
        with torrents: [TorrentItem]
    ) async throws {
        let presentation = try await TorrentListPresentation.prepare(
            torrents: torrents,
            previousTorrents: state.torrents,
            previousRows: state.rows
        )
        state.update(presentation)
    }

    @Test("Sidebar snapshot ignores live rate-only torrent changes")
    func sidebarSnapshotIgnoresLiveRateOnlyTorrentChanges() {
        let labels = [TorrentLabel(id: "linux", name: "Linux")]
        let labelAssignments = ["alpha": Set(["linux"])]
        let trackerHosts = ["alpha": Set(["tracker.example.org"])]
        let baseTorrents = [
            makeTorrent(
                id: "alpha",
                downloadRate: 100,
                uploadRate: 10,
                state: .downloading
            ),
        ]
        let updatedTorrents = [
            makeTorrent(
                id: "alpha",
                downloadRate: 200,
                uploadRate: 20,
                state: .downloading
            ),
        ]

        let first = TorrentSidebarSnapshot.make(
            torrents: baseTorrents,
            labels: labels,
            labelAssignments: labelAssignments,
            trackerHostsByTorrentID: trackerHosts
        )
        let second = TorrentSidebarSnapshot.make(
            torrents: updatedTorrents,
            labels: labels,
            labelAssignments: labelAssignments,
            trackerHostsByTorrentID: trackerHosts
        )

        #expect(first == second)
    }
}
