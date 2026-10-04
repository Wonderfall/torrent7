import AppKit
import Foundation
import Observation
import Synchronization
import Testing
import TorrentEngineModel
@testable import TorrentApp

@Suite("Torrent file icon resolution")
struct TorrentFileIconTests {
    @MainActor
    @Test("Existing icon cells observe asynchronous image arrival without a row redraw")
    func cellsObserveImageArrival() async throws {
        let images = TorrentFileIconImages()
        let updates = Mutex(0)
        let sources: [TorrentFileIconSource] = [.folder, .genericFile, .fileExtension("iso")]
        for source in sources {
            let cell = FileItemIcon(source: source, images: images)
            withObservationTracking {
                _ = cell.body
            } onChange: {
                updates.withLock { $0 += 1 }
            }
        }
        #expect(updates.withLock { $0 } == 0)
        images.icons = try await FileIconService().icons(for: ["", "iso"])
        #expect(updates.withLock { $0 } == sources.count)
    }

    @Test("Outline icons can be reused after rows disappear and reappear")
    func outlineIcons() async throws {
        let service = FileIconService()
        let initial = try await service.icons(for: ["", "iso", "pdf"])
        let reloaded = try await service.icons(for: ["", "iso", "pdf"])
        #expect(Set(initial.keys) == [.folder, .genericFile, .fileExtension("iso"), .fileExtension("pdf")])
        #expect(Set(reloaded.keys) == Set(initial.keys))
        for source in initial.keys {
            let icon = try #require(reloaded[source])
            #expect(icon.size.width > 0 && icon.size.height > 0)
        }
    }

    @MainActor
    @Test("Cancelled icon loading preserves the already loaded images")
    func cancelledOutlineIcons() async throws {
        let service = FileIconService()
        let icons = try await service.icons(for: ["iso"])
        // This task inherits MainActor and cannot start before cancellation.
        let task = Task { try await service.icons(for: ["iso"]) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let reloaded = try await service.icons(for: ["iso"])
        #expect(Set(reloaded.keys) == Set(icons.keys))
        let retainedIcon = try #require(icons[.fileExtension("iso")])
        #expect(retainedIcon.size.width > 0 && retainedIcon.size.height > 0)
    }

    @Test("Missing single-file torrent uses its filename extension")
    func missingSingleFileUsesFilenameExtension() {
        let row = TorrentRowSnapshot(makeTorrent(
            name: "archlinux-2026.07.01-x86_64.iso",
            savePath: "/Users/example/Downloads",
            contentKind: .singleFile
        ))

        #expect(TorrentFileIconSource.resolve(for: row) == .fileExtension("iso"))
    }

    @Test("Engine save paths cannot influence torrent icons")
    func engineSavePathCannotInfluenceIcon() throws {
        try withTemporaryDirectory { root in
            let saveURL = root.appending(path: "downloads", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)
            let itemURL = saveURL.appending(path: "archlinux.iso")
            #expect(FileManager.default.createFile(atPath: itemURL.torrentFilePath, contents: Data()))
            let row = TorrentRowSnapshot(makeTorrent(
                name: itemURL.lastPathComponent,
                savePath: saveURL.torrentFilePath,
                contentKind: .singleFile
            ))

            #expect(TorrentFileIconSource.resolve(for: row) == .fileExtension("iso"))
        }
    }

    @Test("Missing dotted multi-file torrent uses a folder icon")
    func missingDottedDirectoryUsesFolderIcon() {
        let row = TorrentRowSnapshot(makeTorrent(
            name: "AlmaLinux-10.2-x86_64",
            savePath: "/Users/example/Downloads",
            contentKind: .directory
        ))

        #expect(TorrentFileIconSource.resolve(for: row) == .folder)
    }

    @Test("Missing extensionless single-file torrent uses a generic file icon")
    func missingExtensionlessFileUsesGenericFileIcon() {
        let row = TorrentRowSnapshot(makeTorrent(
            name: "README",
            savePath: "/Users/example/Downloads",
            contentKind: .singleFile
        ))

        #expect(TorrentFileIconSource.resolve(for: row) == .genericFile)
    }

    @Test("Traversal metadata cannot influence an icon outside the save path")
    func traversalFallsBackToFolder() {
        let row = TorrentRowSnapshot(makeTorrent(
            name: "../outside.iso",
            savePath: "/Users/example/Downloads",
            contentKind: .singleFile
        ))

        #expect(TorrentFileIconSource.resolve(for: row) == .folder)
    }
}
