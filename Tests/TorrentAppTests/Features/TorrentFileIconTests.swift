import Foundation
import Testing
import TorrentEngineModel
@testable import TorrentApp

@Suite("Torrent file icon resolution")
struct TorrentFileIconTests {
    @Test("Missing single-file torrent uses its filename extension")
    func missingSingleFileUsesFilenameExtension() {
        let row = TorrentRowSnapshot(makeTorrent(
            name: "archlinux-2026.07.01-x86_64.iso",
            savePath: "/Users/example/Downloads",
            contentKind: .singleFile
        ))

        #expect(TorrentFileIconSource.resolve(for: row) == .fileExtension("iso"))
    }

    @Test("Existing torrent item uses its exact path")
    func existingItemUsesExactPath() throws {
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

            #expect(TorrentFileIconSource.resolve(for: row) == .existingItem(itemURL.torrentFilePath))
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
