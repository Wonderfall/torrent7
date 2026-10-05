import Foundation
import Network
import Testing
import TorrentAppInfrastructure
import TorrentEngineModel

@Suite("Inspector search")
struct TorrentInspectorSearchTests {
    private func file(_ index: Int32, _ path: String, size: Int64 = 10) -> TorrentFileItem {
        TorrentFileItem(path: path, size: size, downloaded: 0, progress: 0,
            index: index, priority: .normal, isPadFile: false)
    }

    @Test("File matches keep their ancestors, original identities and sorted order")
    func nestedFiles() async throws {
        let files = [
            file(0, "Archive/Live/2026/Night/cover.jpg"),
            file(1, "Archive/Live/2026/Night/Café.flac", size: 20),
            file(2, "Archive/Live/2026/Night/Cafe reprise.flac", size: 30),
            file(3, "Archive/Studio/Other.flac"),
        ]
        let tree = try await TorrentFileTree.prepare(files: files, sortOrder: [.init(.size)], query: " CAFE \n")
        #expect(tree.fileCount == 2)
        #expect(tree.totalFileCount == 4)
        #expect(tree.query.text == "CAFE")
        var folder = try #require(tree.roots.first)
        for depth in 0..<4 {
            #expect(folder.id == .folder(containingFileIndex: 0, depth: depth))
            #expect(folder.fileIndices == [2, 1])
            #expect(folder.size == 50)
            if depth < 3 { folder = try #require(folder.children?.first) }
        }
        #expect(folder.children?.map(\.name) == ["Cafe reprise.flac", "Café.flac"])
        let changes = try await TorrentFilePriorityChange(fileIndices: folder.fileIndices, priority: .skip)
            .pendingPriorities(in: files)
        #expect(changes == [1: .skip, 2: .skip])

        let wholeFolder = try await TorrentFileTree.prepare(files: files, query: "live/2026")
        #expect(wholeFolder.fileCount == 3)
        let missing = try await TorrentFileTree.prepare(files: files, query: "missing")
        #expect(missing.roots.isEmpty)
        #expect(missing.fileCount == 0)
        #expect(missing.totalFileCount == 4)
        let restored = try await TorrentFileTree.prepare(files: files, query: " \n ")
        #expect(restored.fileCount == 4)
        #expect(restored.roots.first?.id == tree.roots.first?.id)
        #expect(restored.filenameExtensions == tree.filenameExtensions)
    }

    @Test("Filtering keeps the authoritative batch and pending edits to hidden files")
    func pendingEdits() async throws {
        let batch = TorrentFileBatch(revision: 4, files: [file(0, "Root/a.txt"), file(1, "Root/b.jpg")])
        let presentation = try await TorrentFileBatchPresentation.prepare(
            batch: batch, pendingPriorities: [0: .high, 1: .skip], query: ".txt"
        )
        #expect(presentation.revision == batch.revision)
        #expect(presentation.sourceBatch.files.map(\.index) == [0, 1])
        #expect(presentation.sourceBatch.files.allSatisfy { $0.priority == .normal })
        #expect(presentation.remainingPendingPriorities == [0: .high, 1: .skip])
        #expect(presentation.tree.fileCount == 1)
        #expect(presentation.tree.roots.first?.priority == .high)
    }

    @Test("Peers match endpoints, clients, localized countries and ISO country codes")
    func peers() async throws {
        // A deterministic country index maps public IPv4 to JP and IPv6 to FR.
        let data = Data(Array("T7CCDB01".utf8)
            + [0, 0, 0, 1, 1, 53, 40, 137, 0, 0, 0, 1, 0, 0, 0, 1]
            + [255, 255, 255, 255, 74, 80] + Array(repeating: 255, count: 16) + [70, 82])
        let countries = try TorrentCountryDatabase(data: data)
        let peers = [
            peer(Data([1, 1, 1, 1]), client: "Transmission 4.0"),
            peer(Data([8, 8, 8, 8]), client: "qBittorrent 5.1", rate: 1_000),
            peer(try #require(IPv6Address("2001:4860::8888")).rawValue, client: "Deluge 2.2"),
            peer(Data([192, 168, 1, 1]), client: "Example"),
        ]
        let snapshot = TorrentPeerSnapshot(peers: peers, totalCount: 4)
        let countryName = try #require(Locale.current.localizedString(forRegionCode: "JP"))
        for (query, expected) in [
            ("8.8.8.8:6881", [peers[1].id]), (" torrent ", [peers[1].id]),
            ("jp", [peers[1].id, peers[0].id]), (countryName, [peers[1].id, peers[0].id]),
            ("2001:4860::", [peers[2].id]), ("local network", [peers[3].id]), ("missing", []),
        ] {
            let rows = try await TorrentPeerRow.prepare(
                snapshot: snapshot, countries: countries, sortOrder: [.init(.download)], query: query
            )
            #expect(rows.map(\.id) == expected)
        }
        let restored = try await TorrentPeerRow.prepare(snapshot: snapshot, countries: countries, sortOrder: [], query: " \n")
        #expect(restored.count == 4)
    }

    @Test("Search treats punctuation literally and bounds oversized pasted input")
    func query() {
        #expect(TorrentSearchQuery(" CAFÉ ").matches("cafe"))
        #expect(!TorrentSearchQuery(".*").matches("filename"))
        #expect(TorrentSearchQuery("[mix]").matches("Live [Mix].flac"))
        #expect(TorrentSearchQuery(String(repeating: "a", count: 2_000)).text.utf8.count == 1_024)
    }

    private func peer(_ address: Data, client: String, rate: Int32 = 0) -> TorrentPeer {
        TorrentPeer(endpoint: .init(address: address, port: 6881), transport: .tcp, client: client,
            progressPartsPerMillion: 0, downloadRate: rate, uploadRate: 0,
            downloaded: 0, uploaded: 0, flags: [], sources: [])
    }
}
