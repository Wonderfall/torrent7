package struct TorrentSourceSecuritySummary: Equatable, Sendable {
    package let trackerCount: Int
    package let httpsTrackerCount: Int
    package let webSeedCount: Int
    package let httpsWebSeedCount: Int

    package init(
        trackerCount: Int,
        httpsTrackerCount: Int,
        webSeedCount: Int,
        httpsWebSeedCount: Int
    ) {
        self.trackerCount = trackerCount
        self.httpsTrackerCount = httpsTrackerCount
        self.webSeedCount = webSeedCount
        self.httpsWebSeedCount = httpsWebSeedCount
    }

    package var sourceCount: Int {
        trackerCount + webSeedCount
    }

    package var httpsSourceCount: Int {
        httpsTrackerCount + httpsWebSeedCount
    }

    package var nonHTTPSSourceCount: Int {
        max(0, sourceCount - httpsSourceCount)
    }

    package var nonHTTPSTrackerCount: Int {
        max(0, trackerCount - httpsTrackerCount)
    }

    package var nonHTTPSWebSeedCount: Int {
        max(0, webSeedCount - httpsWebSeedCount)
    }

    package var hasHTTPSSources: Bool {
        httpsSourceCount > 0
    }

    package var hasNonHTTPSSources: Bool {
        nonHTTPSSourceCount > 0
    }

    package var hasNonHTTPSTrackers: Bool {
        nonHTTPSTrackerCount > 0
    }

    package var hasNonHTTPSWebSeeds: Bool {
        nonHTTPSWebSeedCount > 0
    }

    package var needsTrackerExceptionPrompt: Bool {
        trackerCount > 0 && httpsTrackerCount == 0
    }

    package var needsWebSeedExceptionPrompt: Bool {
        webSeedCount > 0 && httpsWebSeedCount == 0
    }

    package static let empty = TorrentSourceSecuritySummary(
        trackerCount: 0,
        httpsTrackerCount: 0,
        webSeedCount: 0,
        httpsWebSeedCount: 0
    )
}
