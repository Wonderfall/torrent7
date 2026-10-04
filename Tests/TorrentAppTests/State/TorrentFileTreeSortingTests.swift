import Foundation
import Testing
import TorrentAppInfrastructure
import TorrentEngineModel

@Suite("Torrent file sorting")
struct TorrentFileTreeSortingTests {
    @Test("Each column sorts by its underlying value in both directions", arguments:
        [TorrentFileTree.Sort.Key.name, .size, .progress, .priority],
        [SortOrder.forward, .reverse]
    )
    func columns(_ key: TorrentFileTree.Sort.Key, _ order: SortOrder) async throws {
        let tree = try await TorrentFileTree.prepare(files: [
            file(0, "Pack/file2", size: 10, downloaded: 3, priority: .normal),
            file(1, "Pack/file10", size: 70, downloaded: 70, priority: .skip),
            file(2, "Pack/file1", size: 25, priority: .high),
            file(3, "Pack/file20", size: 40, downloaded: 20, priority: .low),
        ], sortOrder: [TorrentFileTree.Sort(key, order: order)])
        let ascending: [Int32]
        switch key {
        case .name: ascending = [2, 0, 1, 3]
        case .size: ascending = [0, 2, 3, 1]
        case .progress: ascending = [2, 0, 3, 1]
        case .priority: ascending = [1, 3, 0, 2]
        }
        let children = try #require(tree.roots.first?.children)
        #expect(children.compactMap(\.file?.index) == (order == .forward ? ascending : ascending.reversed()))
    }

    @Test("Size starts largest first and sorts every level by aggregate bytes")
    func nestedSizes() async throws {
        let files = [
            file(0, "Pack/A/small", size: 10),
            file(1, "Pack/A/large", size: 20),
            file(2, "Pack/B/huge", size: 90),
            file(3, "Pack/middle", size: 50),
        ]
        let original = try await TorrentFileTree.prepare(files: files)
        let sorted = try await TorrentFileTree.prepare(files: files, sortOrder: [TorrentFileTree.Sort(.size)])
        let root = try #require(sorted.roots.first)
        let children = try #require(root.children)
        #expect(children.map(\.name) == ["B", "middle", "A"])
        #expect(children.last?.children?.map(\.name) == ["large", "small"])
        #expect(root.id == original.roots.first?.id)
        #expect(Set(root.fileIndices) == [0, 1, 2, 3])
        #expect(root.size == original.roots.first?.size)
        #expect(sorted.fileCounts == original.fileCounts)
        #expect(children.last?.id == .folder(containingFileIndex: 0, depth: 1))
    }

    @Test("Priority starts high first and keeps mixed folders distinct from skipped files")
    func mixedPriority() async throws {
        let tree = try await TorrentFileTree.prepare(files: [
            file(0, "Pack/Mixed/high", priority: .high),
            file(1, "Pack/Mixed/normal", priority: .normal),
            file(2, "Pack/skipped", priority: .skip),
            file(3, "Pack/low", priority: .low),
            file(4, "Pack/normal", priority: .normal),
            file(5, "Pack/high", priority: .high),
        ], sortOrder: [TorrentFileTree.Sort(.priority)])
        let children = try #require(tree.roots.first?.children)
        #expect(children.map(\.name) == ["high", "normal", "low", "skipped", "Mixed"])
        #expect(children.last?.priority == nil)
        #expect(children.last?.children?.map(\.priority) == [.high, .normal])
    }

    @Test("Secondary columns and equal-value ties produce deterministic ordering")
    func equalValues() async throws {
        let files = [
            file(0, "file10", priority: .high),
            file(1, "file2", priority: .high),
            file(2, "file1", priority: .low),
        ]
        let sortOrder = [TorrentFileTree.Sort(.size), TorrentFileTree.Sort(.priority)]
        let first = try await TorrentFileTree.prepare(files: files, sortOrder: sortOrder)
        let second = try await TorrentFileTree.prepare(files: files.reversed(), sortOrder: sortOrder)
        #expect(first.roots.map(\.id) == [.file(1), .file(0), .file(2)])
        #expect(first.roots.map(\.id) == second.roots.map(\.id))
    }

    @Test("Name sorting keeps folders first when reversed")
    func foldersFirst() async throws {
        let tree = try await TorrentFileTree.prepare(files: [
            file(0, "Root/A/item"), file(1, "Root/B/item"), file(2, "Root/z"),
        ], sortOrder: [TorrentFileTree.Sort(.name, order: .reverse)])
        #expect(tree.roots.first?.children?.map(\.name) == ["B", "A", "z"])
    }

    @Test("Add and inspector presentations sort the displayed priority overrides")
    func presentedPriorities() async throws {
        let files = [file(0, "first", priority: .normal), file(1, "second", priority: .normal)]
        let order = [TorrentFileTree.Sort(.priority)]
        let add = try await TorrentAddFileSelectionPresentation.prepare(
            generation: 1, files: files, bulkPriority: nil, overrides: [1: .high], sortOrder: order
        )
        let inspector = try await TorrentFileBatchPresentation.prepare(
            batch: TorrentFileBatch(revision: 1, files: files), pendingPriorities: [1: .high], sortOrder: order
        )
        #expect(add.tree.roots.map(\.id) == [.file(1), .file(0)])
        #expect(inspector.tree.roots.map(\.id) == [.file(1), .file(0)])
        #expect(add.filePriorities == [1: .high])
        #expect(inspector.remainingPendingPriorities == [1: .high])
    }

    private func file(
        _ index: Int32, _ path: String, size: Int64 = 10,
        downloaded: Int64 = 0, priority: TorrentFilePriority = .normal
    ) -> TorrentFileItem {
        TorrentFileItem(path: path, size: size, downloaded: downloaded,
            progress: Double(downloaded) / Double(size), index: index, priority: priority, isPadFile: false)
    }
}
