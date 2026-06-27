import Foundation
import Testing
@testable import TorrentApp

@Suite("Torrent source models")
struct TorrentSourceModelTests {
    @Test("Magnet source security summary counts HTTPS and non-HTTPS sources")
    func magnetSourceSecuritySummaryCountsHTTPSSources() {
        let summary = TorrentSourceSecurityParser.summary(
            magnetURI: "magnet:?xt=urn:btih:abc&tr=http%3A%2F%2Ftracker.example%2Fannounce&tr=HTTPS%3A%2F%2Fsecure.example%2Fannounce&ws=http%3A%2F%2Fseed.example%2Ffile&ws=https%3A%2F%2Fsecure.example%2Ffile"
        )

        #expect(summary.trackerCount == 2)
        #expect(summary.httpsTrackerCount == 1)
        #expect(summary.webSeedCount == 2)
        #expect(summary.httpsWebSeedCount == 1)
        #expect(summary.sourceCount == 4)
        #expect(summary.nonHTTPSSourceCount == 2)
        #expect(summary.nonHTTPSTrackerCount == 1)
        #expect(summary.nonHTTPSWebSeedCount == 1)
        #expect(summary.hasHTTPSSources)
        #expect(summary.hasNonHTTPSSources)
        #expect(summary.hasNonHTTPSTrackers)
        #expect(summary.hasNonHTTPSWebSeeds)
        #expect(!summary.needsTrackerExceptionPrompt)
        #expect(!summary.needsWebSeedExceptionPrompt)
    }

    @Test("Magnet source security summary asks for exception when no HTTPS source exists")
    func magnetSourceSecuritySummaryRequiresExceptionWithoutHTTPSSources() {
        let summary = TorrentSourceSecurityParser.summary(
            magnetURI: "magnet:?xt=urn:btih:abc&tr=udp%3A%2F%2Ftracker.example%2Fannounce&ws=http%3A%2F%2Fseed.example%2Ffile"
        )

        #expect(summary.sourceCount == 2)
        #expect(summary.httpsSourceCount == 0)
        #expect(summary.needsTrackerExceptionPrompt)
        #expect(summary.needsWebSeedExceptionPrompt)
    }

    @Test("Tracker status follows disabled updating error verified order")
    func trackerStatusFollowsDisabledUpdatingErrorVerifiedOrder() {
        #expect(tracker(updating: true, verified: true, hasError: true, enabled: false).statusText == "Disabled")
        #expect(tracker(updating: true, verified: true, hasError: true).statusText == "Updating")
        #expect(tracker(verified: true, hasError: true).statusText == "Error")
        #expect(tracker(verified: true).statusText == "Working")
        #expect(tracker().statusText == "Not Contacted")
    }

    @Test("Tracker scrape summary omits missing counts")
    func trackerScrapeSummaryOmitsMissingCounts() {
        #expect(tracker(scrapeSeeders: -1, scrapeLeechers: -1, scrapeDownloaded: -1).scrapeSummaryText == nil)
        #expect(tracker(scrapeSeeders: 1, scrapeLeechers: 1, scrapeDownloaded: 2).scrapeSummaryText == "1 seeder · 1 leecher · 2 completed")
    }

    @Test("Web seed kind falls back to URL seed")
    func webSeedKindFallsBackToURLSeed() {
        #expect(TorrentWebSeedKind(rawBridgeValue: 0) == .urlSeed)
        #expect(TorrentWebSeedKind(rawBridgeValue: 1) == .httpSeed)
        #expect(TorrentWebSeedKind(rawBridgeValue: 999) == .urlSeed)
        #expect(TorrentWebSeedKind.urlSeed.title == "Web Seed")
        #expect(TorrentWebSeedKind.httpSeed.title == "HTTP Seed")
    }

    @Test("Web seed activity summarizes active connections")
    func webSeedActivitySummarizesActiveConnections() {
        #expect(TorrentWebSeedActivity.empty.summaryText == nil)
        #expect(TorrentWebSeedActivity(activeCount: 1, downloadRate: 0, totalDownload: 0).summaryText == "1 active")
        #expect(
            TorrentWebSeedActivity(activeCount: 2, downloadRate: 1_024, totalDownload: 0).summaryText
                == "2 active · \(ByteFormat.rate(Int32(1_024)))"
        )
    }

    @Test("File item display and status reflect path progress and priority")
    func fileItemDisplayAndStatusReflectPathProgressAndPriority() {
        let waiting = file(path: "folder/video.mkv")
        let downloading = file(path: "video.mkv", downloaded: 1, progress: 0.5)
        let complete = file(path: "video.mkv", downloaded: 10, progress: 1)
        let skipped = file(path: "video.mkv", priority: .skip)

        #expect(waiting.displayName == "video.mkv")
        #expect(waiting.statusText == "Waiting")
        #expect(downloading.statusText == "Downloading")
        #expect(complete.statusText == "Complete")
        #expect(skipped.statusText == "Skipped")
        #expect(waiting.detailText == "\(ByteFormat.size(0)) of \(ByteFormat.size(10))")
    }

    @Test("File priorities map raw bridge values to user classes")
    func filePrioritiesMapRawBridgeValuesToUserClasses() {
        #expect(TorrentFilePriority(bridgeValue: 0) == .skip)
        #expect(TorrentFilePriority(bridgeValue: 1) == .low)
        #expect(TorrentFilePriority(bridgeValue: 3) == .low)
        #expect(TorrentFilePriority(bridgeValue: 4) == .normal)
        #expect(TorrentFilePriority(bridgeValue: 5) == .high)
        #expect(TorrentFilePriority(bridgeValue: 7) == .high)
        #expect(TorrentFilePriority(bridgeValue: 99) == .normal)
    }

    @Test("File preview hides pad files")
    func filePreviewHidesPadFiles() {
        let visible = file(path: "video.mkv", index: 1)
        let pad = file(path: ".pad/0", index: 2, isPadFile: true)
        let preview = TorrentFilePreview(
            name: "Preview",
            id: "hash",
            totalSize: 10,
            sourceSecuritySummary: .empty,
            files: [visible, pad],
            torrentData: Data()
        )

        #expect(preview.visibleFiles == [visible])
        #expect(preview.visibleFileCount == 1)
    }
}

private func tracker(
    scrapeSeeders: Int32 = -1,
    scrapeLeechers: Int32 = -1,
    scrapeDownloaded: Int32 = -1,
    updating: Bool = false,
    verified: Bool = false,
    hasError: Bool = false,
    enabled: Bool = true
) -> TorrentTrackerItem {
    TorrentTrackerItem(
        url: "udp://tracker.example/announce",
        message: "",
        tier: 0,
        failCount: 0,
        scrapeSeeders: scrapeSeeders,
        scrapeLeechers: scrapeLeechers,
        scrapeDownloaded: scrapeDownloaded,
        updating: updating,
        verified: verified,
        hasError: hasError,
        enabled: enabled
    )
}

private func file(
    path: String,
    downloaded: Int64 = 0,
    progress: Double = 0,
    index: Int32 = 0,
    priority: TorrentFilePriority = .normal,
    isPadFile: Bool = false
) -> TorrentFileItem {
    TorrentFileItem(
        path: path,
        size: 10,
        downloaded: downloaded,
        progress: progress,
        index: index,
        priority: priority,
        isPadFile: isPadFile
    )
}
