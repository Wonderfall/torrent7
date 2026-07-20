import Foundation
import Testing
import TorrentEngineModel

@Suite("Torrent filesystem paths")
struct TorrentFilePathTests {
    @Test("Decoded paths preserve stable filesystem identity")
    func decodedPathsPreserveStableFilesystemIdentity() {
        #expect(
            URL(filePath: "/Downloads/Folder", directoryHint: .isDirectory).torrentFilePath
                == "/Downloads/Folder"
        )
        #expect(
            URL(filePath: "/Downloads/File.iso", directoryHint: .notDirectory).torrentFilePath
                == "/Downloads/File.iso"
        )
        #expect(
            URL(filePath: "/Downloads/Space % Folder", directoryHint: .isDirectory)
                .torrentFilePath == "/Downloads/Space % Folder"
        )
        #expect(URL(filePath: "/", directoryHint: .isDirectory).torrentFilePath == "/")
    }
}
