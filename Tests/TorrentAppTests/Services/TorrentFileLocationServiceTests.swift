import Foundation
import Testing
@testable import TorrentApp

@Suite("Torrent file location service")
struct TorrentFileLocationServiceTests {
    @Test("Reveals downloaded item inside save path")
    func revealsDownloadedItemInsideSavePath() async throws {
        try await withTemporaryDirectory { root in
            let saveURL = root.appending(path: "downloads", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)
            let itemURL = saveURL.appending(path: "Ubuntu.iso")
            #expect(FileManager.default.createFile(atPath: itemURL.torrentFilePath, contents: Data()))

            let service = TorrentFileLocationService()
            let torrent = makeTorrent(name: "Ubuntu.iso", savePath: saveURL.torrentFilePath)

            #expect(try await service.revealURL(for: torrent)?.torrentFilePath == itemURL.torrentFilePath)
        }
    }

    @Test("Falls back to save directory when item is missing")
    func fallsBackToSaveDirectoryWhenItemIsMissing() async throws {
        try await withTemporaryDirectory { root in
            let saveURL = root.appending(path: "downloads", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)

            let service = TorrentFileLocationService()
            let torrent = makeTorrent(name: "Missing.iso", savePath: saveURL.torrentFilePath)

            #expect(try await service.revealURL(for: torrent)?.torrentFilePath == saveURL.torrentFilePath)
        }
    }

    @Test("Reveals nearest existing parent for file paths")
    func revealsNearestExistingParentForFilePaths() async throws {
        try await withTemporaryDirectory { root in
            let saveURL = root.appending(path: "downloads", directoryHint: .isDirectory)
            let parentURL = saveURL.appending(path: "folder", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)

            let service = TorrentFileLocationService()
            let torrent = makeTorrent(savePath: saveURL.torrentFilePath)

            #expect(try await service.revealURL(
                for: torrent,
                filePath: "folder/missing/video.mkv"
            )?.torrentFilePath == parentURL.torrentFilePath)
        }
    }

    @Test("Rejects traversal outside save path")
    func rejectsTraversalOutsideSavePath() async throws {
        try await withTemporaryDirectory { root in
            let saveURL = root.appending(path: "downloads", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)

            let service = TorrentFileLocationService()
            let torrent = makeTorrent(name: "../outside.iso", savePath: saveURL.torrentFilePath)

            #expect(try await service.revealURL(for: torrent)?.torrentFilePath == saveURL.torrentFilePath)
            #expect(try await service.revealURL(for: torrent, filePath: "../outside.iso") == nil)
        }
    }

    @Test("Rejects symlink escapes outside save path")
    func rejectsSymlinkEscapesOutsideSavePath() async throws {
        try await withTemporaryDirectory { root in
            let saveURL = root.appending(path: "downloads", directoryHint: .isDirectory)
            let outsideURL = root.appending(path: "outside", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: saveURL.appending(path: "escape", directoryHint: .isDirectory),
                withDestinationURL: outsideURL
            )

            let service = TorrentFileLocationService()
            let torrent = makeTorrent(name: "escape/secret.txt", savePath: saveURL.torrentFilePath)

            #expect(try await service.revealURL(for: torrent)?.torrentFilePath == saveURL.torrentFilePath)
            #expect(try await service.revealURL(for: torrent, filePath: "escape/secret.txt") == nil)
        }
    }

    @Test("Batch resolution deduplicates shared download locations")
    func batchResolutionDeduplicatesLocations() async throws {
        try await withTemporaryDirectory { root in
            let saveURL = root.appending(path: "downloads", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)
            let service = TorrentFileLocationService()

            let urls = try await service.revealURLs(for: [
                makeTorrent(id: "alpha", name: "Missing A", savePath: saveURL.torrentFilePath),
                makeTorrent(id: "beta", name: "Missing B", savePath: saveURL.torrentFilePath),
            ])

            #expect(urls.map(\.torrentFilePath) == [saveURL.torrentFilePath])
        }
    }
}
