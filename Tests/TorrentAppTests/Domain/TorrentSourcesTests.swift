import Foundation
import Testing
import TorrentEngineModel
@testable import TorrentApp

@Suite("Torrent sources")
struct TorrentSourcesTests {
    @Test("Parses magnet sources case-insensitively")
    func parsesMagnetSourcesCaseInsensitively() throws {
        let draft = try #require(TorrentAddSourceParser.magnetDraft(
            from: " \nMAGNET:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=HTTPS%3A%2F%2Ftracker.example%2Fannounce "
        ))
        let magnetURI = try #require(draft.magnetURI)
        let securitySummary = TorrentSourceSecurityInspector.summary(magnetURI: magnetURI)

        #expect(magnetURI == "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=HTTPS%3A%2F%2Ftracker.example%2Fannounce")
        #expect(securitySummary.trackerCount == 1)
        #expect(securitySummary.httpsTrackerCount == 1)
        #expect(draft.fileURL == nil)
        #expect(draft.title == "Magnet Link")
    }

    @Test("Rejects non-magnet source text")
    func rejectsNonMagnetSourceText() {
        #expect(TorrentAddSourceParser.magnetDraft(from: "https://example.com/file.torrent") == nil)
    }

    @Test("Rejects oversized magnet source text")
    func rejectsOversizedMagnetSourceText() {
        let oversizedMagnet = "magnet:?\(String(repeating: "x", count: TorrentInputLimits.maxMagnetURIBytes))"

        #expect(TorrentAddSourceParser.magnetDraft(from: oversizedMagnet) == nil)
    }

    @Test("Filters torrent files case-insensitively")
    func filtersTorrentFilesCaseInsensitively() {
        let urls = [
            URL(filePath: "/tmp/first.torrent"),
            URL(filePath: "/tmp/ignored.txt"),
            URL(filePath: "/tmp/second.TORRENT")
        ]

        let drafts = TorrentAddSourceParser.torrentFileDrafts(from: urls)

        #expect(drafts.map(\.fileURL?.lastPathComponent) == ["first.torrent", "second.TORRENT"])
    }

    @Test("Tracker status favors disabled state before transient states")
    func trackerStatusFavorsDisabledStateBeforeTransientStates() {
        let tracker = TorrentTrackerItem(
            url: "udp://tracker.example/announce",
            message: "offline",
            tier: 0,
            failCount: 1,
            scrapeSeeders: 1,
            scrapeLeechers: 2,
            scrapeDownloaded: 3,
            updating: true,
            verified: true,
            hasError: true,
            enabled: false
        )

        #expect(tracker.statusText == "Disabled")
        #expect(tracker.statusSystemImage == "slash.circle")
        #expect(tracker.scrapeSummaryText == "1 seeder · 2 leechers · 3 completed")
    }
}
