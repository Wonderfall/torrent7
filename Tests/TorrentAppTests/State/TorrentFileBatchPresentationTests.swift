import Testing
import TorrentAppInfrastructure
import TorrentEngineModel

@Suite("Torrent file batch presentation")
struct TorrentFileBatchPresentationTests {
    @Test("Preparation overlays pending priorities in the file tree")
    func preparationOverlaysPendingPriorities() async throws {
        let presentation = try await TorrentFileBatchPresentation.prepare(
            batch: TorrentFileBatch(
                revision: 42,
                files: [
                    makeFile(index: 0, priority: .normal),
                    makeFile(index: 1, priority: .low),
                ]
            ),
            pendingPriorities: [1: .high]
        )

        #expect(presentation.revision == 42)
        #expect(
            presentation.tree.roots.map(\.priority)
                == [.normal, .high]
        )
        #expect(presentation.remainingPendingPriorities == [1: .high])
    }

    @Test("An older refresh finishing after a sort change cannot replace a newer poll")
    func staleRefreshDoesNotPoisonLaterSorts() async throws {
        let older = TorrentFileBatch(revision: 1, files: [
            makeFile(index: 0, priority: .normal), makeFile(index: 1, priority: .normal),
        ])
        let newer = TorrentFileBatch(revision: 2, files: [
            makeFile(index: 0, priority: .skip), makeFile(index: 1, priority: .high),
        ])
        var state = TorrentFilePresentationState()
        let publishedNewer = state.apply(try await TorrentFileBatchPresentation.prepare(
            batch: newer, pendingPriorities: [:]
        ))
        #expect(publishedNewer)

        // The priority refresh finishes with an obsolete sort order. Its cache
        // update must not regress the snapshot that the next sort will use.
        let acceptedOlder = state.accept(older)
        #expect(!acceptedOlder)
        let source = try #require(state.latestBatch)
        let publishedSort = state.apply(try await TorrentFileBatchPresentation.prepare(
            batch: source, pendingPriorities: [:], sortOrder: [.init(.priority)]
        ))
        #expect(publishedSort)
        #expect(state.latestBatch?.revision == 2)
        #expect(state.tree.roots.map(\.priority) == [.high, .skip])

        let publishedOlder = state.apply(try await TorrentFileBatchPresentation.prepare(
            batch: older, pendingPriorities: [:]
        ))
        #expect(!publishedOlder)
        #expect(state.tree.roots.map(\.priority) == [.high, .skip])
    }

    @Test("Cancelled preparation does not return a partial presentation")
    func cancelledPreparationThrows() async {
        let files = (0..<20_000).map { index in
            makeFile(index: Int32(index), priority: .normal)
        }
        let task = Task {
            try await TorrentFileBatchPresentation.prepare(
                batch: TorrentFileBatch(revision: 1, files: files),
                pendingPriorities: [:]
            )
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private func makeFile(
        index: Int32,
        priority: TorrentFilePriority
    ) -> TorrentFileItem {
        TorrentFileItem(
            path: "file-\(index)",
            size: 1,
            downloaded: 0,
            progress: 0,
            index: index,
            priority: priority,
            isPadFile: false
        )
    }
}
