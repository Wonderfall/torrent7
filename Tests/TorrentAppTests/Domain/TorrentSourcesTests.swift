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

    @Test("Prepares magnet security summaries asynchronously")
    func preparesMagnetSecuritySummary() async throws {
        let summary =
            try await TorrentSourceSecurityInspector.prepareSummary(
                magnetURI:
                    "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=https%3A%2F%2Ftracker.example%2Fannounce"
            )

        #expect(summary.trackerCount == 1)
        #expect(summary.httpsTrackerCount == 1)
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

    @Test("Stops oversized magnet preparation at the input limit")
    func boundsOversizedMagnetPreparation() async throws {
        let oversizedMagnet =
            "magnet:?"
            + String(
                repeating: "x",
                count: TorrentInputLimits.maxMagnetURIBytes * 2
            )

        let preparation =
            try await TorrentAddSourceParser.prepareMagnetDraft(
                from: oversizedMagnet
            )

        #expect(preparation.draft == nil)
        #expect(preparation.isTooLarge)
    }

    @Test("Filters torrent files case-insensitively")
    func filtersTorrentFilesCaseInsensitively() async throws {
        let urls = [
            URL(filePath: "/tmp/first.torrent"),
            URL(filePath: "/tmp/ignored.txt"),
            URL(filePath: "/tmp/second.TORRENT")
        ]

        let batch = try await TorrentAddSourceParser.torrentFileDrafts(
            from: urls,
            maximumCount: 2
        )

        #expect(batch.drafts.map(\.fileURL?.lastPathComponent) == [
            "first.torrent",
            "second.TORRENT",
        ])
        #expect(!batch.exceededLimit)
    }

    @Test("Bounds torrent file draft preparation")
    func boundsTorrentFileDraftPreparation() async throws {
        let urls = (0..<70).map {
            URL(filePath: "/tmp/\($0).torrent")
        }

        let batch = try await TorrentAddSourceParser.torrentFileDrafts(
            from: urls,
            maximumCount: 3
        )

        #expect(batch.drafts.count == 3)
        #expect(batch.exceededLimit)
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

    @Test("Prepares tracker status summary asynchronously")
    func preparesTrackerStatusSummary() async throws {
        let working = TorrentTrackerItem(
            url: "https://tracker.example/announce",
            message: "",
            tier: 0,
            failCount: 0,
            scrapeSeeders: 0,
            scrapeLeechers: 0,
            scrapeDownloaded: 0,
            updating: false,
            verified: true,
            hasError: false,
            enabled: true
        )
        let updating = TorrentTrackerItem(
            url: "https://backup.example/announce",
            message: "",
            tier: 1,
            failCount: 0,
            scrapeSeeders: 0,
            scrapeLeechers: 0,
            scrapeDownloaded: 0,
            updating: true,
            verified: false,
            hasError: false,
            enabled: true
        )

        let summary = try await TorrentTrackerSummary.prepare(
            trackers: [working, updating]
        )

        #expect(summary.text == "1 working · 1 updating")
    }
}
