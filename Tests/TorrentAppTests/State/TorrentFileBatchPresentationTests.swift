import Testing
import TorrentEngineModel
@testable import TorrentApp

@Suite("Torrent file batch presentation")
struct TorrentFileBatchPresentationTests {
    @Test("Preparation overlays pending priorities in precomputed sections")
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
            presentation.sections.flatMap(\.files).map(\.priority)
                == [.normal, .high]
        )
        #expect(presentation.remainingPendingPriorities == [1: .high])
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
