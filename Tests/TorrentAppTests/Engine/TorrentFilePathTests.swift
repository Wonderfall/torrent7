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

    @Test("Escaped separators and NULs remain filename text")
    func escapedPathComponents() throws {
        let escapedSeparator = try #require(URL(string: "file:///tmp/a%2Fb.torrent"))
        let escapedNull = try #require(URL(string: "file:///tmp/a%00b.torrent"))
        #expect(escapedSeparator.torrentFilePath == "/tmp/a%2Fb.torrent")
        #expect(escapedNull.torrentFilePath == "/tmp/a%00b.torrent")
    }
}
