import Testing
import TorrentAppInfrastructure
import TorrentEngineModel

@Suite("Torrent file hierarchy")
struct TorrentFileTreeTests {
    @Test("File counts exclude folders and padding and keep skipped files separate from finished files")
    func fileCounts() async throws {
        let tree = try await TorrentFileTree.prepare(files: [
            file(0, "Root/finished", downloaded: 10),
            file(1, "Root/Nested/downloading", downloaded: 1, priority: .low),
            file(2, "Root/Nested/waiting", priority: .high),
            file(3, "Root/skipped", priority: .skip),
            file(4, "Root/finished-but-skipped", downloaded: 10, priority: .skip),
            file(5, "Root/empty", size: 0),
            file(6, "Root/.pad/finished", downloaded: 10, pad: true),
            file(7, "Root/.pad/waiting", pad: true),
        ])

        #expect(tree.fileCounts.finished == 2)
        #expect(tree.fileCounts.downloading == 1)
        #expect(tree.fileCounts.waiting == 1)
        #expect(tree.fileCounts.skipped == 2)
        #expect(tree.fileCount == 6)
    }

    @Test("File counts follow progress updates and pending skip or resume changes")
    func updatedFileCounts() async throws {
        let initial = try await TorrentFileTree.prepare(files: [
            file(0, "Root/one"), file(1, "Root/two"),
        ])
        #expect(initial.fileCounts.waiting == 2)

        let updated = try await TorrentFileTree.prepare(files: [
            file(0, "Root/one", downloaded: 1), file(1, "Root/two", downloaded: 10),
        ])
        #expect(updated.fileCounts.finished == 1)
        #expect(updated.fileCounts.downloading == 1)
        #expect(updated.fileCounts.waiting == 0)

        let pending = try await TorrentFileBatchPresentation.prepare(
            batch: TorrentFileBatch(revision: 2, files: [
                file(0, "Root/one", downloaded: 1),
                file(1, "Root/two", downloaded: 10, priority: .skip),
            ]),
            pendingPriorities: [0: .skip, 1: .normal]
        )
        #expect(pending.tree.fileCounts.finished == 1)
        #expect(pending.tree.fileCounts.downloading == 0)
        #expect(pending.tree.fileCounts.waiting == 0)
        #expect(pending.tree.fileCounts.skipped == 1)
        #expect(pending.tree.fileCount == 2)
    }

    @Test("Folders contain exact descendants, retain indices, and sort naturally")
    func hierarchy() async throws {
        let tree = try await TorrentFileTree.prepare(files: [
            file(7, "Pack/Disc 2/track10.flac"),
            file(2, "Pack/Disc 2/track2.flac"),
            file(9, "Pack/Disc 20/track2.flac"),
            file(4, "Pack/readme"),
            file(5, "Other/readme"),
        ])
        #expect(tree.fileCount == 5)
        #expect(tree.roots.map(\.name) == ["Other", "Pack"])
        let pack = try #require(tree.roots.last)
        let children = try #require(pack.children)
        #expect(children.map(\.name) == ["Disc 2", "Disc 20", "readme"])
        #expect(children[0].fileIndices == [2, 7])
        #expect(children[0].children?.map(\.name) == ["track2.flac", "track10.flac"])
        #expect(children[1].id == .folder(containingFileIndex: 9, depth: 1))
        #expect(pack.id == .folder(containingFileIndex: 2, depth: 0))
        #expect(children[2].id == .file(4))
        #expect(Set(pack.fileIndices) == [2, 4, 7, 9])
    }

    @Test("Mixed folder priorities propagate and progress is weighted by bytes")
    func aggregates() async throws {
        let tree = try await TorrentFileTree.prepare(files: [
            file(0, "Root/Nested/small", size: 10, downloaded: 10, priority: .high),
            file(1, "Root/Nested/large", size: 90, downloaded: 0, priority: .skip),
            file(2, "Root/.pad/0", size: 99, pad: true),
        ])
        let root = try #require(tree.roots.first)
        #expect(tree.fileCount == 2)
        #expect(root.fileIndices.count == 2)
        #expect(root.priority == nil)
        #expect(root.children?.first?.priority == nil)
        #expect(root.size == 100)
        #expect(root.downloaded == 10)
        #expect(root.progress == 0.1)
        #expect(root.children?.count == 1)
    }

    @Test("Icon types use leaf extensions, ignore padding, and remain stable across progress updates")
    func iconTypes() async throws {
        let files = [
            file(0, "Folder.with.dots/LICENSE"),
            file(1, "Folder.with.dots/image.PNG"),
            file(2, "Folder.with.dots/another.png"),
            file(3, "Folder.with.dots/.pad/unused.iso", pad: true),
        ]
        let tree = try await TorrentFileTree.prepare(files: files)
        #expect(tree.filenameExtensions == ["", "png"])
        let children = try #require(tree.roots.first?.children)
        #expect(children.first { $0.id == .file(0) }?.filenameExtension == "")
        #expect(children.first { $0.id == .file(1) }?.filenameExtension == "png")
        let changed = try await TorrentFileTree.prepare(files: files.map { $0.withPriority(.skip) })
        #expect(changed.filenameExtensions == tree.filenameExtensions)
    }

    @Test("Single files have no synthetic folder; padding-only torrents are empty")
    func leavesAndEmpty() async throws {
        let single = try await TorrentFileTree.prepare(files: [file(3, "README")])
        #expect(single.roots.count == 1)
        #expect(single.roots.first?.children == nil)
        #expect(single.roots.first?.id == .file(3))
        let empty = try await TorrentFileTree.prepare(files: [])
        let padding = try await TorrentFileTree.prepare(files: [file(0, ".pad/0", pad: true)])
        #expect(empty.fileCounts == TorrentFileTree.empty.fileCounts)
        #expect(empty.fileCount == 0)
        #expect(padding.roots.isEmpty)
        #expect(padding.fileCounts == empty.fileCounts)
    }

    @Test("Zero-sized and very large totals stay finite and do not overflow")
    func sizeBoundaries() async throws {
        let zero = try await TorrentFileTree.prepare(files: [file(0, "Root/empty", size: 0)])
        #expect(zero.roots.first?.progress == 1)
        let huge = try await TorrentFileTree.prepare(files: [
            file(0, "Root/a", size: .max), file(1, "Root/b", size: .max),
        ])
        #expect(huge.roots.first?.size == .max)
        #expect(huge.roots.first?.progress == 0)
    }

    @Test("Folder identities survive priority, progress, and input-order changes")
    func stableIdentity() async throws {
        let first = try await TorrentFileTree.prepare(files: [
            file(0, "Root/A/one"), file(1, "Root/a/two"),
        ])
        let second = try await TorrentFileTree.prepare(files: [
            file(1, "Root/a/two", downloaded: 10, priority: .skip),
            file(0, "Root/A/one", downloaded: 5, priority: .high),
        ])
        #expect(first.roots.map(\.id) == second.roots.map(\.id))
        #expect(first.roots.first?.children?.map(\.id) == second.roots.first?.children?.map(\.id))
        #expect(first.roots.first?.children?.count == 2)
    }

    @Test("Large folders retain every file without a presentation limit")
    func maximumFileCount() async throws {
        let files = (0..<TorrentEngineLimits.maximumFileCount).map {
            file(Int32($0), "Root/Folder/\($0)")
        }
        let tree = try await TorrentFileTree.prepare(files: files)
        #expect(tree.fileCount == files.count)
        #expect(tree.fileCounts.waiting == files.count)
        #expect(tree.roots.first?.fileIndices.count == files.count)
        #expect(tree.roots.first?.children?.first?.children?.count == files.count)
    }

    @Test("Deep folders retain distinct file-index and depth identities")
    func deepHierarchy() async throws {
        let folders = Array(repeating: "folder", count: 32)
        let tree = try await TorrentFileTree.prepare(files: [file(0, (folders + ["leaf"]).joined(separator: "/"))])
        var node = try #require(tree.roots.first)
        for depth in 1...folders.count {
            #expect(node.id == .folder(containingFileIndex: 0, depth: depth - 1))
            #expect(node.path == folders.prefix(depth).joined(separator: "/"))
            #expect(node.fileIndices == [0])
            node = try #require(node.children?.first)
        }
        #expect(node.id == .file(0))
    }

    @Test("Folder changes override a bulk default without changing sibling folders")
    func addSelection() async throws {
        let files = [file(0, "Root/A/one"), file(1, "Root/A/two"), file(2, "Root/AB/three")]
        let selection = try await TorrentAddFileSelectionPresentation.prepare(
            generation: 8, files: files, bulkPriority: .skip, overrides: [0: .high],
            change: TorrentFilePriorityChange(fileIndices: [0, 1], priority: .normal)
        )
        #expect(selection.generation == 8)
        #expect(selection.filePriorities == [2: .skip])
        #expect(selection.overrides == [0: .normal, 1: .normal])
        #expect(selection.selectedFileCount == 2)
        #expect(selection.selectedFileSize == 20)
        #expect(selection.tree.roots.first?.priority == nil)

        let restored = try await TorrentAddFileSelectionPresentation.prepare(
            generation: 9, files: files, bulkPriority: .skip, overrides: selection.overrides,
            change: TorrentFilePriorityChange(fileIndices: [0, 1], priority: .skip)
        )
        #expect(restored.overrides.isEmpty)
        #expect(!restored.hasDownloadableFile)
        #expect(restored.tree.roots.first?.priority == .skip)
    }

    @Test("Confirmed priorities clear pending overlays and recompute folder state")
    func reconciles() async throws {
        let presentation = try await TorrentFileBatchPresentation.prepare(
            batch: TorrentFileBatch(revision: 9, files: [
                file(0, "Root/a", priority: .high), file(1, "Root/b", priority: .normal),
            ]),
            pendingPriorities: [0: .high, 1: .high]
        )
        #expect(presentation.remainingPendingPriorities == [1: .high])
        #expect(presentation.tree.roots.first?.priority == .high)
    }

    private func file(
        _ index: Int32, _ path: String, size: Int64 = 10,
        downloaded: Int64 = 0, priority: TorrentFilePriority = .normal, pad: Bool = false
    ) -> TorrentFileItem {
        TorrentFileItem(path: path, size: size, downloaded: downloaded,
            progress: size == 0 ? 1 : Double(downloaded) / Double(size),
            index: index, priority: priority, isPadFile: pad)
    }
}

@Suite("Folder priority operations")
struct TorrentFilePriorityChangeTests {
    @Test("Priority planning excludes padding, unchanged files, and other folders")
    func plansExactFiles() async throws {
        let files = (0..<4).map { index in
            TorrentFileItem(path: "Root/\(index)", size: 1, downloaded: 0, progress: 0,
                index: Int32(index), priority: index == 0 ? .skip : .normal, isPadFile: index == 2)
        }
        let change = TorrentFilePriorityChange(fileIndices: [0, 1, 2], priority: .skip)
        #expect(try await change.pendingPriorities(in: files) == [1: .skip])
    }

}
