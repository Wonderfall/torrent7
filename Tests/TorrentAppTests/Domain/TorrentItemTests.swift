import Testing
import TorrentBridge
import TorrentEngineModel
@testable import TorrentEngineCore
@testable import TorrentApp

@Suite("Torrent item")
struct TorrentItemTests {
    @Test("Status text follows user-facing precedence")
    func statusTextFollowsUserFacingPrecedence() {
        #expect(makeTorrent(error: "disk full", paused: true, autoManaged: false).statusText == "Error")
        #expect(makeTorrent(paused: true, autoManaged: false, seeding: true).statusText == "Paused")
        #expect(makeTorrent(paused: true, autoManaged: true, seeding: true).statusText == "Queued")
        #expect(makeTorrent(seeding: true, finished: true).statusText == "Seeding")
        #expect(makeTorrent(finished: true).statusText == "Finished")
        #expect(makeTorrent(state: .downloading, hasMetadata: false).statusText == "Metadata")
        #expect(makeTorrent(state: .checkingResumeData).statusText == "Resuming")
    }

    @Test("Status sort rank puts urgent and active states first")
    func statusSortRankPutsUrgentAndActiveStatesFirst() {
        let torrents = [
            makeTorrent(id: "paused", paused: true, autoManaged: false),
            makeTorrent(id: "queued", paused: true, autoManaged: true),
            makeTorrent(id: "finished", finished: true),
            makeTorrent(id: "seeding", seeding: true),
            makeTorrent(id: "downloading", state: .downloading),
            makeTorrent(id: "checking", state: .checkingFiles),
            makeTorrent(id: "metadata", hasMetadata: false),
            makeTorrent(id: "error", error: "disk full")
        ]

        let sorted = TorrentSortOrder.status.sorted(torrents, direction: .ascending)

        #expect(sorted.map(\.id) == [
            "error",
            "metadata",
            "checking",
            "downloading",
            "seeding",
            "finished",
            "queued",
            "paused"
        ])
    }

    @Test("Peer counts are nonnegative and internally consistent")
    func peerCountsAreNonnegativeAndInternallyConsistent() {
        let torrent = makeTorrent(peers: -2, knownPeers: -1)

        #expect(torrent.connectedPeerCount == 0)
        #expect(torrent.knownPeerCount == 0)
        #expect(torrent.hasPeerInformation == false)
        #expect(torrent.peerSummaryText == "0/0 peers")

        let torrentWithKnownPeers = makeTorrent(peers: 4, knownPeers: 1)
        #expect(torrentWithKnownPeers.connectedPeerCount == 4)
        #expect(torrentWithKnownPeers.knownPeerCount == 4)
        #expect(torrentWithKnownPeers.peerSummaryText == "4/4 peers")

        let torrentWithOneKnownPeer = makeTorrent(peers: 0, knownPeers: 1)
        #expect(torrentWithOneKnownPeer.peerSummaryText == "0/1 peer")
    }

    @Test("Displayed totals never go below payload totals")
    func displayedTotalsNeverGoBelowPayloadTotals() {
        let torrent = makeTorrent(
            totalPayloadUpload: 50,
            totalPayloadDownload: 60,
            allTimeUpload: 10,
            allTimeDownload: 20
        )

        #expect(torrent.displayedAllTimeUpload == 50)
        #expect(torrent.displayedAllTimeDownload == 60)
    }

    @Test("Torrent state maps bridge raw values and titles")
    func torrentStateMapsBridgeRawValuesAndTitles() {
        #expect(TorrentState(rawBridgeValue: Int32(TTORRENT_BRIDGE_STATE_CHECKING_FILES)) == .checkingFiles)
        #expect(TorrentState(rawBridgeValue: Int32(TTORRENT_BRIDGE_STATE_DOWNLOADING_METADATA)) == .downloadingMetadata)
        #expect(TorrentState(rawBridgeValue: Int32(TTORRENT_BRIDGE_STATE_DOWNLOADING)) == .downloading)
        #expect(TorrentState(rawBridgeValue: Int32(TTORRENT_BRIDGE_STATE_FINISHED)) == .finished)
        #expect(TorrentState(rawBridgeValue: Int32(TTORRENT_BRIDGE_STATE_SEEDING)) == .seeding)
        #expect(TorrentState(rawBridgeValue: Int32(TTORRENT_BRIDGE_STATE_CHECKING_RESUME_DATA)) == .checkingResumeData)
        #expect(TorrentState(rawBridgeValue: 999) == .unknown)
        #expect(TorrentState.unknown.title == "Unknown")
    }
}
