import Testing
import TorrentEngineModel
@testable import TorrentApp

@Suite("Torrent browser projection")
struct TorrentBrowserProjectionTests {
    @Test("Filtering combines sidebar metadata and search text")
    func filteringCombinesScopeAndSearch() async throws {
        let rows = [
            TorrentRowSnapshot(makeTorrent(id: "alpha", name: "Alpha Linux")),
            TorrentRowSnapshot(makeTorrent(id: "beta", name: "Beta Linux")),
            TorrentRowSnapshot(makeTorrent(id: "gamma", name: "Gamma")),
        ]
        let projection = try await TorrentBrowserProjection.prepare(
            rows: rows,
            selection: .label("linux"),
            query: "Alpha",
            labels: [TorrentLabel(id: "linux", name: "Linux")],
            labelAssignments: [
                "alpha": ["linux"],
                "beta": ["linux"],
            ],
            trackerHostsByTorrentID: [:]
        )

        #expect(projection.rows.map(\.id) == ["alpha"])
        #expect(projection.ids == ["alpha"])
        #expect(projection.orderedIDs == ["alpha"])
        #expect(projection.rowIndicesByID == ["alpha": 0])
        #expect(
            projection.labelsByTorrentID["alpha"]
                == [TorrentLabel(id: "linux", name: "Linux")]
        )
    }

    @Test("A cancelled projection does not publish a partial result")
    func cancelledProjectionThrows() async {
        let rows = (0..<20_000).map { index in
            TorrentRowSnapshot(makeTorrent(
                id: "torrent-\(index)",
                name: "Torrent \(index)"
            ))
        }
        let task = Task {
            try await TorrentBrowserProjection.prepare(
                rows: rows,
                selection: .all,
                query: "",
                labels: [],
                labelAssignments: [:],
                trackerHostsByTorrentID: [:]
            )
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("Bounds search input before it becomes UI coordination state")
    func boundsSearchInput() {
        let query = String(repeating: "é", count: 2_000)
        let bounded = TorrentBrowserProjection.boundedQueryInput(query)

        #expect(bounded.utf8.count <= 1_024)
    }

    @MainActor
    @Test("A superseded projection cannot replace current filter state")
    func supersededProjectionIsRejected() {
        let state = TorrentBrowserFilterState()
        let firstID = TorrentBrowserFilterRequestID(
            rowRevision: 1,
            metadataRevision: 1,
            selection: .all,
            query: ""
        )
        let secondID = TorrentBrowserFilterRequestID(
            rowRevision: 2,
            metadataRevision: 1,
            selection: .all,
            query: ""
        )
        state.begin(firstID)
        state.begin(secondID)

        state.apply(
            TorrentBrowserProjection(
                rows: [TorrentRowSnapshot(makeTorrent(id: "stale"))],
                ids: ["stale"],
                orderedIDs: ["stale"],
                rowIndicesByID: ["stale": 0],
                query: "",
                labelsByTorrentID: [:]
            ),
            for: firstID
        )

        #expect(state.rows.isEmpty)
        #expect(state.ids.isEmpty)
    }

    @Test("Selection summaries precompute bulk action state and labels")
    func selectionSummaryPrecomputesActions() async throws {
        let rows = [
            TorrentRowSnapshot(makeTorrent(
                id: "alpha",
                queuePriority: .normal
            )),
            TorrentRowSnapshot(makeTorrent(
                id: "beta",
                queuePriority: .high,
                paused: true
            )),
        ]

        let summary = try await TorrentListSelectionSummary.prepare(
            selectionRevision: 4,
            filterRevision: 9,
            selectedIDs: ["alpha", "beta", "missing"],
            rows: rows,
            rowIndicesByID: ["alpha": 0, "beta": 1],
            labelAssignments: [
                "alpha": ["linux"],
                "beta": ["linux", "iso"],
            ]
        )

        #expect(summary.ids == ["alpha", "beta"])
        #expect(summary.firstID == "alpha")
        #expect(summary.hasMetadata)
        #expect(summary.canPause)
        #expect(summary.canResume)
        #expect(summary.commonQueuePriority == nil)
        #expect(summary.labeledTorrentCount(for: "linux") == 2)
        #expect(summary.labeledTorrentCount(for: "iso") == 1)
    }

    @Test("Range selection preparation unions on a concurrent executor")
    func rangeSelectionPreparationUnionsBase() async throws {
        let request = TorrentListSelectionRequest(
            filterRevision: 3,
            expectedSelectionRevision: 5,
            baseIDs: ["outside"],
            members: .range(startID: "beta", endID: "delta"),
            anchorID: "beta",
            focusID: "delta"
        )

        let projection = try await TorrentListSelectionProjection.prepare(
            request: request,
            orderedIDs: ["alpha", "beta", "gamma", "delta"],
            rowIndicesByID: [
                "alpha": 0,
                "beta": 1,
                "gamma": 2,
                "delta": 3,
            ]
        )

        #expect(
            projection.ids
                == ["outside", "beta", "gamma", "delta"]
        )
    }
}
