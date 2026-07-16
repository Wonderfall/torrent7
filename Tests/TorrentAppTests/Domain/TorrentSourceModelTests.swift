import Foundation
import Testing
import TorrentEngineModel
@testable import TorrentEngineCore
@testable import TorrentApp

@Suite("Torrent source models")
struct TorrentSourceModelTests {
    @Test("Magnet source security summary counts HTTPS and non-HTTPS sources")
    func magnetSourceSecuritySummaryCountsHTTPSSources() {
        let summary = TorrentSourceSecurityInspector.summary(
            magnetURI: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=http%3A%2F%2Ftracker.example%2Fannounce&tr=HTTPS%3A%2F%2Fsecure.example%2Fannounce&ws=http%3A%2F%2Fseed.example%2Ffile&ws=https%3A%2F%2Fsecure.example%2Ffile"
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
        let summary = TorrentSourceSecurityInspector.summary(
            magnetURI: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=udp%3A%2F%2Ftracker.example%2Fannounce&ws=http%3A%2F%2Fseed.example%2Ffile"
        )

        #expect(summary.sourceCount == 2)
        #expect(summary.httpsSourceCount == 0)
        #expect(summary.needsTrackerExceptionPrompt)
        #expect(summary.needsWebSeedExceptionPrompt)
    }

    @Test("Magnet source security summary ignores empty trackers")
    func magnetSourceSecuritySummaryIgnoresEmptyTrackers() {
        let summary = TorrentSourceSecurityInspector.summary(
            magnetURI: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=&tr"
        )

        #expect(summary.trackerCount == 0)
        #expect(summary.httpsTrackerCount == 0)
    }

    @Test("Magnet source security summary ignores malformed HTTPS trackers")
    func magnetSourceSecuritySummaryIgnoresMalformedHTTPSTrackers() {
        let summary = TorrentSourceSecurityInspector.summary(
            magnetURI: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=https%3A%2F%2F&tr=https%3A%2F%2Funder_score.example%2Fannounce&tr=https%3A%2F%2Fsecure.example%2Fannounce%0A&tr=https%3A%2F%2Fsecure.example%2Fannounce%"
        )

        #expect(summary.trackerCount == 0)
        #expect(summary.httpsTrackerCount == 0)
    }

    @Test("Magnet source security summary validates raw tracker hostnames")
    func magnetSourceSecuritySummaryValidatesRawTrackerHostnames() {
        let summary = TorrentSourceSecurityInspector.summary(
            magnetURI: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=https%3A%2F%2Fexa%252emple.com%2Fannounce&tr=https%3A%2F%2F%2565xample.com%2Fannounce"
        )

        #expect(summary.trackerCount == 0)
        #expect(summary.httpsTrackerCount == 0)
    }

    @Test("Magnet source security summary decodes tracker values once")
    func magnetSourceSecuritySummaryDecodesTrackerValuesOnce() {
        let summary = TorrentSourceSecurityInspector.summary(
            magnetURI: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=https%3A%2F%2Ftracker.example%2Fann+ounce&t%72=https%3A%2F%2Fsecure.example%2Fannounce"
        )

        #expect(summary.trackerCount == 0)
        #expect(summary.httpsTrackerCount == 0)
    }

    @Test("Magnet source security summary decodes parameter names exactly once")
    func magnetSourceSecuritySummaryDecodesParameterNamesOnce() {
        let summary = TorrentSourceSecurityInspector.summary(
            magnetURI: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&t%72=https%3A%2F%2Fsecure.example%2Fannounce&t%2572=https%3A%2F%2Fignored.example%2Fannounce"
        )

        #expect(summary.trackerCount == 1)
        #expect(summary.httpsTrackerCount == 1)
    }

    @Test("Magnet source security summary validates base32 v1 hashes")
    func magnetSourceSecuritySummaryValidatesBase32V1Hashes() {
        let valid = TorrentSourceSecurityInspector.summary(
            magnetURI: "magnet:?xt=urn:btih:ABCDEFGHIJKLMNOPQRSTUVWXYZ234567&tr=https%3A%2F%2Fsecure.example%2Fannounce"
        )
        let invalid = TorrentSourceSecurityInspector.summary(
            magnetURI: "magnet:?xt=urn:btih:ABCDEFGHIJKLMNOPQRSTUVWXYZ234568&tr=https%3A%2F%2Fsecure.example%2Fannounce"
        )

        #expect(valid.trackerCount == 1)
        #expect(invalid == .empty)
    }

    @Test("Magnet source security summary recognizes numbered tracker parameters")
    func magnetSourceSecuritySummaryRecognizesNumberedTrackerParameters() {
        let summary = TorrentSourceSecurityInspector.summary(
            magnetURI: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr.1=http%3A%2F%2Ftracker.example%2Fannounce&TR.=https%3A%2F%2Fsecure.example%2Fannounce&tr.label=https%3A%2F%2Fignored.example%2Fannounce"
        )

        #expect(summary.trackerCount == 2)
        #expect(summary.httpsTrackerCount == 1)
    }

    @Test("Magnet source security summary rejects multiple-at tracker authorities")
    func magnetSourceSecuritySummaryRejectsMultipleAtTrackerAuthorities() {
        let summary = TorrentSourceSecurityInspector.summary(
            magnetURI: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=https%3A%2F%2Fu%3Ap%40evil%40host.example%2Fannounce"
        )

        #expect(summary.trackerCount == 0)
        #expect(summary.httpsTrackerCount == 0)
    }

    @Test("Magnet source security summary accepts supported tracker authorities")
    func magnetSourceSecuritySummaryAcceptsSupportedTrackerAuthorities() {
        let summary = TorrentSourceSecurityInspector.summary(
            magnetURI: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=http%3A%2F%2Fuser%3Apass%40tracker.example%3A8080%2Fannounce&tr=HTTPS%3A%2F%2F%5Bfe80%3A%3A1%2525en0%5D%3A443%2Fannounce&tr=udp%3A%2F%2Ftracker.example%3A1337"
        )

        #expect(summary.trackerCount == 3)
        #expect(summary.httpsTrackerCount == 1)
    }

    @Test("Magnet source security inspection fails closed")
    func magnetSourceSecurityInspectionFailsClosed() {
        let invalid = TorrentSourceSecurityInspector.summary(
            magnetURI: "magnet:?xt=urn:btih:not-a-hash&tr=https%3A%2F%2Ftracker.example%2Fannounce"
        )
        let oversized = TorrentSourceSecurityInspector.summary(
            magnetURI: "magnet:?\(String(repeating: "x", count: TorrentInputLimits.maxMagnetURIBytes))"
        )

        #expect(invalid == .empty)
        #expect(oversized == .empty)
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

    @Test("Web seed activity summarizes active connections")
    func webSeedActivitySummarizesActiveConnections() {
        #expect(TorrentWebSeedActivity.empty.summaryText == nil)
        #expect(TorrentWebSeedActivity(activeCount: 1, downloadRate: 0, totalDownload: 0).summaryText == "1 active")
        #expect(
            TorrentWebSeedActivity(activeCount: 2, downloadRate: 1_024, totalDownload: 0).summaryText
                == "2 active · \(ByteFormat.rate(Int32(1_024)))"
        )
    }

    @Test("Source policy field mutation changes only the selected value")
    func sourcePolicyFieldMutationIsScoped() {
        var policy = TorrentSourcePolicy(
            isDHTEnabled: true,
            isPeerExchangeEnabled: true,
            isLocalServiceDiscoveryEnabled: true,
            usesHTTPSTrackersOnly: true,
            usesHTTPSWebSeedsOnly: true,
            isDHTLocked: false,
            isPeerExchangeLocked: false,
            isLocalServiceDiscoveryLocked: false,
            isMetadataValidationPending: false,
            allowsPreMetadataDHT: false
        )
        let original = policy

        policy[.dht] = false

        #expect(!policy.isDHTEnabled)
        #expect(policy.isPeerExchangeEnabled == original.isPeerExchangeEnabled)
        #expect(policy.isLocalServiceDiscoveryEnabled == original.isLocalServiceDiscoveryEnabled)
        #expect(policy.usesHTTPSTrackersOnly == original.usesHTTPSTrackersOnly)
        #expect(policy.usesHTTPSWebSeedsOnly == original.usesHTTPSWebSeedsOnly)
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
