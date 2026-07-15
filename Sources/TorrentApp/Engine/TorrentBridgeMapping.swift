import Foundation
import TorrentBridge

extension TorrentItem {
    init(snapshot: TTorrentSnapshot) {
        self.init(
            id: String(cStringTuple: snapshot.id),
            infoHash: String(cStringTuple: snapshot.info_hash),
            name: String(cStringTuple: snapshot.name),
            savePath: String(cStringTuple: snapshot.save_path),
            error: String(cStringTuple: snapshot.error),
            comment: String(cStringTuple: snapshot.comment),
            progress: min(max(snapshot.progress, 0), 1),
            totalDone: snapshot.total_done,
            totalWanted: snapshot.total_wanted,
            totalSize: snapshot.total_size,
            totalUpload: snapshot.total_upload,
            totalDownload: snapshot.total_download,
            totalPayloadUpload: snapshot.total_payload_upload,
            totalPayloadDownload: snapshot.total_payload_download,
            allTimeUpload: snapshot.all_time_upload,
            allTimeDownload: snapshot.all_time_download,
            addedTime: snapshot.added_time,
            createdTime: snapshot.created_time,
            completedTime: snapshot.completed_time,
            downloadRate: snapshot.download_rate,
            uploadRate: snapshot.upload_rate,
            downloadPayloadRate: snapshot.download_payload_rate,
            uploadPayloadRate: snapshot.upload_payload_rate,
            peers: snapshot.peers,
            knownPeers: snapshot.known_peers,
            seeds: snapshot.seeds,
            state: TorrentState(rawBridgeValue: snapshot.state),
            queuePosition: snapshot.queue_position,
            queuePriority: TorrentQueuePriority(bridgeValue: snapshot.queue_priority),
            paused: snapshot.paused.bridgeBool,
            autoManaged: snapshot.auto_managed.bridgeBool,
            seeding: snapshot.seeding.bridgeBool,
            finished: snapshot.finished.bridgeBool,
            hasMetadata: snapshot.has_metadata.bridgeBool,
            privateTorrent: snapshot.private_torrent.bridgeBool
        )
    }
}

extension TorrentNetworkStatus {
    init(status: TTorrentNetworkStatus) {
        self.init(
            requestedRevision: status.requested_revision,
            submittedRevision: status.submitted_revision,
            listenPort: status.listen_port,
            networkBlocked: status.network_blocked != 0,
            hasListener: status.has_listener != 0,
            endpoint: String(cStringTuple: status.endpoint),
            lastError: String(cStringTuple: status.last_error)
        )
    }
}

extension TorrentTrackerItem {
    init(snapshot: TTorrentTrackerSnapshot) {
        self.init(
            url: String(cStringTuple: snapshot.url),
            message: String(cStringTuple: snapshot.message),
            tier: snapshot.tier,
            failCount: snapshot.fail_count,
            scrapeSeeders: snapshot.scrape_seeders,
            scrapeLeechers: snapshot.scrape_leechers,
            scrapeDownloaded: snapshot.scrape_downloaded,
            updating: snapshot.updating.bridgeBool,
            verified: snapshot.verified.bridgeBool,
            hasError: snapshot.has_error.bridgeBool,
            enabled: snapshot.enabled.bridgeBool
        )
    }
}

extension TorrentTrackerHostItem {
    init(snapshot: TTorrentTrackerHostSnapshot) {
        self.init(
            torrentID: String(cStringTuple: snapshot.torrent_id),
            host: String(cStringTuple: snapshot.host)
        )
    }
}

extension TorrentWebSeedItem {
    init(snapshot: TTorrentWebSeedSnapshot) {
        self.init(
            url: String(cStringTuple: snapshot.url)
        )
    }
}

extension TorrentWebSeedActivity {
    init(snapshot: TTorrentWebSeedActivitySnapshot) {
        self.init(
            activeCount: snapshot.active_count,
            downloadRate: snapshot.download_rate,
            totalDownload: snapshot.total_download
        )
    }
}

extension TorrentPeerSources {
    init(snapshot: TTorrentPeerSourceSnapshot) {
        self.init(
            connected: snapshot.connected,
            tracker: snapshot.tracker,
            dht: snapshot.dht,
            peerExchange: snapshot.peer_exchange,
            localServiceDiscovery: snapshot.local_service_discovery,
            resumeData: snapshot.resume_data,
            incoming: snapshot.incoming,
            webSeed: snapshot.web_seed,
            other: snapshot.other
        )
    }
}

extension TorrentSourcePolicy {
    init(snapshot: TTorrentSourcePolicy) {
        self.init(
            isDHTEnabled: snapshot.enable_dht.bridgeBool,
            isPeerExchangeEnabled: snapshot.enable_peer_exchange.bridgeBool,
            isLocalServiceDiscoveryEnabled: snapshot.enable_lsd.bridgeBool,
            usesHTTPSTrackersOnly: snapshot.require_https_trackers.bridgeBool,
            usesHTTPSWebSeedsOnly: snapshot.require_https_web_seeds.bridgeBool,
            isDHTLocked: snapshot.dht_locked.bridgeBool,
            isPeerExchangeLocked: snapshot.peer_exchange_locked.bridgeBool,
            isLocalServiceDiscoveryLocked: snapshot.lsd_locked.bridgeBool,
            isMetadataValidationPending: snapshot.metadata_validation_pending.bridgeBool,
            allowsPreMetadataDHT: snapshot.allow_pre_metadata_dht.bridgeBool
        )
    }

}

extension TorrentSourcePolicyField {
    var bridgeValue: Int32 {
        switch self {
        case .dht:
            Int32(TTORRENT_SOURCE_POLICY_ENABLE_DHT)
        case .peerExchange:
            Int32(TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE)
        case .localServiceDiscovery:
            Int32(TTORRENT_SOURCE_POLICY_ENABLE_LSD)
        case .httpsTrackersOnly:
            Int32(TTORRENT_SOURCE_POLICY_REQUIRE_HTTPS_TRACKERS)
        case .httpsWebSeedsOnly:
            Int32(TTORRENT_SOURCE_POLICY_REQUIRE_HTTPS_WEB_SEEDS)
        case .preMetadataDHT:
            Int32(TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT)
        }
    }
}

extension TorrentFileItem {
    init(snapshot: TTorrentFileSnapshot) {
        self.init(
            path: String(cStringTuple: snapshot.path),
            size: snapshot.size,
            downloaded: snapshot.downloaded,
            progress: min(max(snapshot.progress, 0), 1),
            index: snapshot.index,
            priority: TorrentFilePriority(bridgeValue: snapshot.priority),
            isPadFile: snapshot.pad_file.bridgeBool
        )
    }
}

extension Bool {
    var bridgeFlag: UInt8 {
        self ? 1 : 0
    }
}

extension UInt8 {
    var bridgeBool: Bool {
        self != 0
    }
}

extension String {
    init<T>(cStringTuple tuple: T) {
        var tuple = tuple
        let bytes: [UInt8] = unsafe withUnsafeBytes(of: &tuple) { buffer in
            unsafe Array(buffer.prefix(buffer.firstIndex(of: 0) ?? buffer.count))
        }
        self = String(decoding: bytes, as: UTF8.self)
    }
}
