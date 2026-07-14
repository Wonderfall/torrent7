import Testing
import TorrentBridge
@testable import TorrentApp

@Suite("Torrent bridge mapping")
struct TorrentBridgeMappingTests {
    @Test("Maps bridge booleans")
    func mapsBridgeBooleans() {
        #expect(true.bridgeFlag == 1)
        #expect(false.bridgeFlag == 0)
        #expect(UInt8(2).bridgeBool == true)
        #expect(UInt8(0).bridgeBool == false)
    }

    @Test("Decodes fixed bridge strings within tuple bounds")
    func decodesFixedBridgeStringsWithinTupleBounds() {
        let unterminated: (CChar, CChar, CChar) = (65, 66, 67)
        #expect(String(cStringTuple: unterminated) == "ABC")

        let invalidUTF8: (CChar, CChar, CChar) = (
            CChar(bitPattern: 0xE2),
            CChar(bitPattern: 0x28),
            0
        )
        #expect(String(cStringTuple: invalidUTF8).contains("\u{FFFD}"))
    }

    @Test("Maps torrent snapshots and clamps progress")
    func mapsTorrentSnapshotsAndClampsProgress() {
        var snapshot = TTorrentSnapshot()
        writeCString("torrent-id", to: &snapshot.id)
        writeCString("info-hash", to: &snapshot.info_hash)
        writeCString("Ubuntu ISO", to: &snapshot.name)
        writeCString("/Downloads", to: &snapshot.save_path)
        writeCString("disk full", to: &snapshot.error)
        writeCString("release image", to: &snapshot.comment)
        snapshot.progress = 1.5
        snapshot.total_done = 10
        snapshot.total_wanted = 20
        snapshot.total_size = 30
        snapshot.total_payload_upload = 30
        snapshot.total_payload_download = 40
        snapshot.all_time_upload = 25
        snapshot.all_time_download = 35
        snapshot.added_time = 123
        snapshot.created_time = 456
        snapshot.completed_time = 789
        snapshot.download_payload_rate = 1_000
        snapshot.upload_payload_rate = 500
        snapshot.peers = -1
        snapshot.known_peers = 2
        snapshot.state = Int32(TTORRENT_BRIDGE_STATE_DOWNLOADING)
        snapshot.queue_position = 4
        snapshot.queue_priority = Int32(TTORRENT_QUEUE_PRIORITY_HIGH)
        snapshot.paused = false.bridgeFlag
        snapshot.auto_managed = true.bridgeFlag
        snapshot.seeding = false.bridgeFlag
        snapshot.finished = true.bridgeFlag
        snapshot.has_metadata = true.bridgeFlag
        snapshot.private_torrent = true.bridgeFlag

        let item = TorrentItem(snapshot: snapshot)

        #expect(item.id == "torrent-id")
        #expect(item.infoHash == "info-hash")
        #expect(item.name == "Ubuntu ISO")
        #expect(item.error == "disk full")
        #expect(item.comment == "release image")
        #expect(item.progress == 1)
        #expect(item.totalSize == 30)
        #expect(item.createdTime == 456)
        #expect(item.completedTime == 789)
        #expect(item.state == .downloading)
        #expect(item.queued == false)
        #expect(item.finished == true)
        #expect(item.privateTorrent == true)
        #expect(item.knownPeerCount == 2)
        #expect(item.queuePosition == 4)
        #expect(item.queuePriority == .high)
    }

    @Test("Maps file snapshots and clamps progress")
    func mapsFileSnapshotsAndClampsProgress() {
        var snapshot = TTorrentFileSnapshot()
        writeCString("folder/video.mkv", to: &snapshot.path)
        snapshot.size = 1_000
        snapshot.downloaded = 250
        snapshot.progress = -0.5
        snapshot.index = 7
        snapshot.priority = 0
        snapshot.pad_file = true.bridgeFlag

        let file = TorrentFileItem(snapshot: snapshot)

        #expect(file.id == 7)
        #expect(file.displayName == "video.mkv")
        #expect(file.progress == 0)
        #expect(file.priority == .skip)
        #expect(file.isSkipped)
        #expect(file.isPadFile)
    }

    @Test("Maps piece map snapshots and precomputes piece ranges")
    func mapsPieceMapSnapshotsAndPrecomputesPieceRanges() {
        let snapshot = TTorrentPieceMapSnapshot(
            total_pieces: 10,
            completed_pieces: 6,
            available_pieces: 4,
            map_available: true.bridgeFlag,
            map_truncated: true.bridgeFlag
        )
        let pieceMap = TorrentPieceMap(snapshot: snapshot, pieces: [1, 0, 1, 1])

        #expect(pieceMap.totalPieces == 10)
        #expect(pieceMap.completedPieces == 6)
        #expect(pieceMap.availablePieces == 4)
        #expect(pieceMap.isMapAvailable)
        #expect(pieceMap.isMapTruncated)
        #expect(pieceMap.displayedPieces == 4)
        #expect(pieceMap.progress == 0.6)
        #expect(pieceMap.completedPieceCount(in: 0..<4) == 3)
        #expect(pieceMap.completedPieceCount(in: 1..<3) == 1)
        #expect(pieceMap.completedSummary == "6 of 10 pieces")
    }

    @Test("Maps network status")
    func mapsNetworkStatus() {
        var status = TTorrentNetworkStatus()
        status.requested_revision = 2
        status.submitted_revision = 1
        status.listen_port = 51_413
        status.network_blocked = true.bridgeFlag
        status.has_listener = false.bridgeFlag
        writeCString("0.0.0.0:51413", to: &status.endpoint)
        writeCString("blocked", to: &status.last_error)

        let mapped = TorrentNetworkStatus(status: status)

        #expect(mapped.requestedRevision == 2)
        #expect(mapped.submittedRevision == 1)
        #expect(mapped.listenPort == 51_413)
        #expect(mapped.networkBlocked)
        #expect(!mapped.hasListener)
        #expect(mapped.endpoint == "0.0.0.0:51413")
        #expect(mapped.lastError == "blocked")
        #expect(mapped.isApplying)
    }

    @Test("Maps source policy")
    func mapsSourcePolicy() {
        let policy = TorrentSourcePolicy(
            snapshot: TTorrentSourcePolicy(
                enable_dht: true.bridgeFlag,
                enable_peer_exchange: false.bridgeFlag,
                enable_lsd: true.bridgeFlag,
                require_https_trackers: true.bridgeFlag,
                require_https_web_seeds: false.bridgeFlag,
                dht_locked: true.bridgeFlag,
                peer_exchange_locked: true.bridgeFlag,
                lsd_locked: false.bridgeFlag
            )
        )

        #expect(policy.isDHTEnabled)
        #expect(!policy.isPeerExchangeEnabled)
        #expect(policy.isLocalServiceDiscoveryEnabled)
        #expect(policy.usesHTTPSTrackersOnly)
        #expect(!policy.usesHTTPSWebSeedsOnly)
        #expect(policy.isDHTLocked)
        #expect(policy.isPeerExchangeLocked)
        #expect(!policy.isLocalServiceDiscoveryLocked)

        let bridgePolicy = policy.bridgeValue
        #expect(bridgePolicy.enable_dht == true.bridgeFlag)
        #expect(bridgePolicy.enable_peer_exchange == false.bridgeFlag)
        #expect(bridgePolicy.enable_lsd == true.bridgeFlag)
        #expect(bridgePolicy.require_https_trackers == true.bridgeFlag)
        #expect(bridgePolicy.require_https_web_seeds == false.bridgeFlag)
        #expect(bridgePolicy.dht_locked == true.bridgeFlag)
        #expect(bridgePolicy.peer_exchange_locked == true.bridgeFlag)
        #expect(bridgePolicy.lsd_locked == false.bridgeFlag)
    }

    @Test("Maps torrent options")
    func mapsTorrentOptions() {
        let options = TorrentOptions(
            snapshot: TTorrentOptions(
                download_rate_limit: -1,
                upload_rate_limit: 256 * 1024,
                max_uploads: -1,
                max_connections: 42,
                queue_priority: Int32(TTORRENT_QUEUE_PRIORITY_HIGH)
            )
        )

        #expect(options.downloadRateLimitKBps == 0)
        #expect(options.uploadRateLimitKBps == 256)
        #expect(options.uploadSlotLimit == 0)
        #expect(options.connectionLimit == 42)
        #expect(options.queuePriority == .high)
        #expect(options.bridgeValue.download_rate_limit == -1)
        #expect(options.bridgeValue.upload_rate_limit == 256 * 1024)
        #expect(options.bridgeValue.max_uploads == -1)
        #expect(options.bridgeValue.max_connections == 42)
        #expect(options.bridgeValue.queue_priority == Int32(TTORRENT_QUEUE_PRIORITY_HIGH))

        let clamped = TorrentOptions(
            downloadRateLimitKBps: -5,
            uploadRateLimitKBps: 2_000_000,
            uploadSlotLimit: 1,
            connectionLimit: 200_000
        )
        #expect(clamped.downloadRateLimitKBps == 0)
        #expect(clamped.uploadRateLimitKBps == 1_000_000)
        #expect(clamped.uploadSlotLimit == 2)
        #expect(clamped.connectionLimit == 100_000)
        #expect(clamped.queuePriority == .normal)
    }

    @Test("Maps tracker and web seed snapshots")
    func mapsTrackerAndWebSeedSnapshots() {
        var trackerSnapshot = TTorrentTrackerSnapshot()
        writeCString("udp://tracker.example/announce", to: &trackerSnapshot.url)
        writeCString("working", to: &trackerSnapshot.message)
        trackerSnapshot.tier = 2
        trackerSnapshot.fail_count = 1
        trackerSnapshot.scrape_seeders = 10
        trackerSnapshot.scrape_leechers = 20
        trackerSnapshot.scrape_downloaded = 30
        trackerSnapshot.updating = false.bridgeFlag
        trackerSnapshot.verified = true.bridgeFlag
        trackerSnapshot.has_error = false.bridgeFlag
        trackerSnapshot.enabled = true.bridgeFlag

        let tracker = TorrentTrackerItem(snapshot: trackerSnapshot)

        #expect(tracker.url == "udp://tracker.example/announce")
        #expect(tracker.message == "working")
        #expect(tracker.tier == 2)
        #expect(tracker.verified)
        #expect(tracker.enabled)

        var webSeedSnapshot = TTorrentWebSeedSnapshot()
        writeCString("https://example.com/file", to: &webSeedSnapshot.url)

        let webSeed = TorrentWebSeedItem(snapshot: webSeedSnapshot)

        #expect(webSeed.url == "https://example.com/file")
    }

    @Test("Maps web seed activity snapshots")
    func mapsWebSeedActivitySnapshots() {
        var snapshot = TTorrentWebSeedActivitySnapshot()
        snapshot.active_count = 3
        snapshot.download_rate = 4
        snapshot.total_download = 5

        let activity = TorrentWebSeedActivity(snapshot: snapshot)

        #expect(activity.activeCount == 3)
        #expect(activity.downloadRate == 4)
        #expect(activity.totalDownload == 5)
    }

    @Test("Maps peer source snapshots")
    func mapsPeerSourceSnapshots() {
        var snapshot = TTorrentPeerSourceSnapshot()
        snapshot.connected = 10
        snapshot.tracker = 1
        snapshot.dht = 2
        snapshot.peer_exchange = 3
        snapshot.local_service_discovery = 4
        snapshot.resume_data = 5
        snapshot.incoming = 6
        snapshot.web_seed = 7
        snapshot.other = 8

        let sources = TorrentPeerSources(snapshot: snapshot)

        #expect(sources.connected == 10)
        #expect(sources.tracker == 1)
        #expect(sources.dht == 2)
        #expect(sources.peerExchange == 3)
        #expect(sources.localServiceDiscovery == 4)
        #expect(sources.resumeData == 5)
        #expect(sources.incoming == 6)
        #expect(sources.webSeed == 7)
        #expect(sources.other == 8)
    }
}

private func writeCString<T>(_ string: String, to tuple: inout T) {
    unsafe withUnsafeMutableBytes(of: &tuple) { bytes in
        for index in bytes.indices {
            unsafe bytes[index] = 0
        }

        for (index, byte) in string.utf8.prefix(max(0, bytes.count - 1)).enumerated() {
            unsafe bytes[index] = byte
        }
    }
}
