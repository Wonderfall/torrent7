import Foundation
import Testing
import TorrentBridge

@Suite("Torrent bridge contract")
struct TorrentBridgeContractTests {
    @Test("Pins bridge ABI version, limits, states, and dirty masks")
    func pinsBridgeConstants() {
        #expect(UInt32(TTORRENT_BRIDGE_ABI_VERSION) == 30)
        #expect(Int32(TTORRENT_BRIDGE_STATE_UNKNOWN) == -1)
        #expect(Int32(TTORRENT_BRIDGE_STATE_CHECKING_FILES) == 1)
        #expect(Int32(TTORRENT_BRIDGE_STATE_DOWNLOADING_METADATA) == 2)
        #expect(Int32(TTORRENT_BRIDGE_STATE_DOWNLOADING) == 3)
        #expect(Int32(TTORRENT_BRIDGE_STATE_FINISHED) == 4)
        #expect(Int32(TTORRENT_BRIDGE_STATE_SEEDING) == 5)
        #expect(Int32(TTORRENT_BRIDGE_STATE_CHECKING_RESUME_DATA) == 7)

        #expect(Int32(TTORRENT_MAX_FILE_COUNT) == 20_000)
        #expect(Int32(TTORRENT_MAX_TRACKER_COUNT) == 2_000)
        #expect(Int32(TTORRENT_MAX_WEB_SEED_COUNT) == 2_000)
        #expect(Int32(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT) == 20_000)
        #expect(Int32(TTORRENT_MAX_TRACKER_HOST_ROW_COUNT) == 20_000)
        #expect(Int32(TTORRENT_ID_CAPACITY) == 68)
        #expect(Int32(TTORRENT_TRACKER_HOST_CAPACITY) == 256)
        #expect(Int32(TTORRENT_MAX_PIECE_MAP_COUNT) == 0x200000)

        #expect(UInt32(TTORRENT_DIRTY_TORRENTS) == 1 << 0)
        #expect(UInt32(TTORRENT_DIRTY_TRACKERS) == 1 << 1)
        #expect(UInt32(TTORRENT_DIRTY_WEB_SEEDS) == 1 << 2)
        #expect(UInt32(TTORRENT_DIRTY_FILES) == 1 << 3)
        #expect(UInt32(TTORRENT_DIRTY_NETWORK) == 1 << 4)
        #expect(UInt32(TTORRENT_DIRTY_ERRORS) == 1 << 5)
        #expect(UInt32(TTORRENT_DIRTY_PIECES) == 1 << 6)
        #expect(UInt32(TTORRENT_DIRTY_TRACKER_HOSTS) == 1 << 7)
        #expect(Int32(TTORRENT_QUEUE_PRIORITY_LOW) == 0)
        #expect(Int32(TTORRENT_QUEUE_PRIORITY_NORMAL) == 1)
        #expect(Int32(TTORRENT_QUEUE_PRIORITY_HIGH) == 2)
        #expect(Int32(TTORRENT_FILE_PRIORITY_SKIP) == 0)
        #expect(Int32(TTORRENT_FILE_PRIORITY_LOW) == 1)
        #expect(Int32(TTORRENT_FILE_PRIORITY_NORMAL) == 4)
        #expect(Int32(TTORRENT_FILE_PRIORITY_HIGH) == 7)
        #expect(Int32(TTORRENT_REMOVAL_PENDING) == 0)
        #expect(Int32(TTORRENT_REMOVAL_SUCCEEDED) == 1)
        #expect(Int32(TTORRENT_REMOVAL_FAILED) == 2)
        #expect(Int32(TTORRENT_SOURCE_POLICY_ENABLE_DHT) == 0)
        #expect(Int32(TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE) == 1)
        #expect(Int32(TTORRENT_SOURCE_POLICY_ENABLE_LSD) == 2)
        #expect(Int32(TTORRENT_SOURCE_POLICY_REQUIRE_HTTPS_TRACKERS) == 3)
        #expect(Int32(TTORRENT_SOURCE_POLICY_REQUIRE_HTTPS_WEB_SEEDS) == 4)
        #expect(Int32(TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT) == 5)
    }

    @Test("Pins Swift-imported C struct layout")
    func pinsSwiftImportedCStructLayout() {
        #expect(MemoryLayout<TTorrentSnapshot>.size == 3_360)
        #expect(MemoryLayout<TTorrentSnapshot>.alignment == 8)
        #expect(MemoryLayout<TTorrentTrackerSnapshot>.size == 1_560)
        #expect(MemoryLayout<TTorrentTrackerSnapshot>.alignment == 4)
        #expect(MemoryLayout<TTorrentTrackerHostSnapshot>.size == 324)
        #expect(MemoryLayout<TTorrentTrackerHostSnapshot>.alignment == 1)
        #expect(MemoryLayout<TTorrentWebSeedSnapshot>.size == 1_024)
        #expect(MemoryLayout<TTorrentWebSeedSnapshot>.alignment == 1)
        #expect(MemoryLayout<TTorrentWebSeedActivitySnapshot>.size == 16)
        #expect(MemoryLayout<TTorrentWebSeedActivitySnapshot>.alignment == 8)
        #expect(MemoryLayout<TTorrentPeerSourceSnapshot>.size == 36)
        #expect(MemoryLayout<TTorrentPeerSourceSnapshot>.alignment == 4)
        #expect(MemoryLayout<TTorrentFileSnapshot>.size == 1_064)
        #expect(MemoryLayout<TTorrentFileSnapshot>.alignment == 8)
        #expect(MemoryLayout<TTorrentFilePriorityEntry>.size == 8)
        #expect(MemoryLayout<TTorrentFilePriorityEntry>.alignment == 4)
        #expect(MemoryLayout<TTorrentRemovalResult>.size == 516)
        #expect(MemoryLayout<TTorrentRemovalResult>.alignment == 4)
        #expect(MemoryLayout<TTorrentPieceMapSnapshot>.size == 16)
        #expect(MemoryLayout<TTorrentPieceMapSnapshot>.alignment == 4)
        #expect(MemoryLayout<TTorrentFilePreview>.size == 616)
        #expect(MemoryLayout<TTorrentFilePreview>.alignment == 8)
        let sessionSettingsSize = unsafe MemoryLayout<TTorrentSessionSettings>.size
        let sessionSettingsAlignment = unsafe MemoryLayout<TTorrentSessionSettings>.alignment
        #expect(sessionSettingsSize == 72)
        #expect(sessionSettingsAlignment == 8)
        #expect(MemoryLayout<TTorrentNetworkStatus>.size == 664)
        #expect(MemoryLayout<TTorrentNetworkStatus>.alignment == 8)
        #expect(MemoryLayout<TTorrentSourcePolicy>.size == 10)
        #expect(MemoryLayout<TTorrentSourcePolicy>.alignment == 1)
        #expect(MemoryLayout<TTorrentAddOptions>.size == 6)
        #expect(MemoryLayout<TTorrentAddOptions>.alignment == 1)
        #expect(MemoryLayout<TTorrentOptions>.size == 20)
        #expect(MemoryLayout<TTorrentOptions>.alignment == 4)
    }

    @Test("Pins fixed C string field capacities")
    func pinsFixedCStringFieldCapacities() {
        let snapshot = TTorrentSnapshot()
        let tracker = TTorrentTrackerSnapshot()
        let trackerHost = TTorrentTrackerHostSnapshot()
        let webSeed = TTorrentWebSeedSnapshot()
        let file = TTorrentFileSnapshot()
        let removal = TTorrentRemovalResult()
        let preview = TTorrentFilePreview()
        let network = TTorrentNetworkStatus()

        #expect(MemoryLayout.size(ofValue: snapshot.id) == Int(TTORRENT_ID_CAPACITY))
        #expect(MemoryLayout.size(ofValue: snapshot.id) == 68)
        #expect(MemoryLayout.size(ofValue: snapshot.info_hash) == 68)
        #expect(MemoryLayout.size(ofValue: snapshot.name) == 512)
        #expect(MemoryLayout.size(ofValue: snapshot.save_path) == 1_024)
        #expect(MemoryLayout.size(ofValue: snapshot.error) == 512)
        #expect(MemoryLayout.size(ofValue: snapshot.comment) == 1_024)
        #expect(MemoryLayout.size(ofValue: tracker.url) == 1_024)
        #expect(MemoryLayout.size(ofValue: tracker.message) == 512)
        #expect(MemoryLayout.size(ofValue: trackerHost.torrent_id) == Int(TTORRENT_ID_CAPACITY))
        #expect(MemoryLayout.size(ofValue: trackerHost.host) == Int(TTORRENT_TRACKER_HOST_CAPACITY))
        #expect(MemoryLayout.size(ofValue: webSeed.url) == 1_024)
        #expect(MemoryLayout.size(ofValue: file.path) == 1_024)
        #expect(MemoryLayout.size(ofValue: removal.error) == 512)
        #expect(MemoryLayout.size(ofValue: preview.name) == 512)
        #expect(MemoryLayout.size(ofValue: preview.id) == 68)
        #expect(MemoryLayout.size(ofValue: network.endpoint) == 128)
        #expect(MemoryLayout.size(ofValue: network.last_error) == 512)
    }

    @Test("Libtorrent version is pinned to 2.1.0")
    func libtorrentVersionIsPinned() {
        let version = unsafe String(cString: TorrentBridgeLibtorrentVersion())

        #expect(version == "2.1.0.0")
    }

    @Test("Create reports invalid state paths through the error buffer")
    func createReportsInvalidStatePathsThroughErrorBuffer() {
        let missingPathResult = invalidCreateResult(path: nil)
        #expect(!missingPathResult.didCreate)
        #expect(missingPathResult.error == "Missing state path.")

        let relativePathResult = invalidCreateResult(path: "relative/state")
        #expect(!relativePathResult.didCreate)
        #expect(relativePathResult.error == "The state path must be absolute.")
    }

    @Test("Null client query APIs zero outputs")
    func nullClientQueryAPIsZeroOutputs() {
        var dirtyMask: UInt32 = UInt32.max
        let changeRevision = unsafe TorrentClientTakeChanges(nil, &dirtyMask)
        #expect(changeRevision == 0)
        #expect(dirtyMask == 0)

        var revision: UInt64 = UInt64.max
        var requiredCount: Int32 = -1
        let copiedSnapshots = unsafe TorrentClientCopySnapshotBatch(nil, nil, 0, &revision, &requiredCount)
        #expect(copiedSnapshots == 0)
        #expect(revision == 0)
        #expect(requiredCount == 0)

        var status = TTorrentNetworkStatus()
        status.listen_port = 51_413
        let copiedNetworkStatus = unsafe TorrentClientCopyNetworkStatus(nil, &status)
        #expect(copiedNetworkStatus == 0)
        #expect(status.listen_port == 0)
        #expect(status.network_blocked == 0)
        #expect(status.has_listener == 0)

        var sourcePolicy = TTorrentSourcePolicy(
            enable_dht: 1,
            enable_peer_exchange: 1,
            enable_lsd: 1,
            require_https_trackers: 1,
            require_https_web_seeds: 1,
            dht_locked: 1,
            peer_exchange_locked: 1,
            lsd_locked: 1,
            metadata_validation_pending: 1,
            allow_pre_metadata_dht: 1
        )
        var errorBuffer = BridgeErrorBuffer()
        errorBuffer.writeSentinel()
        let copiedSourcePolicy = errorBuffer.withMutableBuffer { buffer in
            unsafe TorrentClientCopySourcePolicy(nil, nil, &sourcePolicy, &buffer, Int32(buffer.count))
        }
        #expect(copiedSourcePolicy == 1)
        #expect(sourcePolicy.enable_dht == 0)
        #expect(sourcePolicy.enable_peer_exchange == 0)
        #expect(sourcePolicy.enable_lsd == 0)
        #expect(sourcePolicy.require_https_trackers == 0)
        #expect(sourcePolicy.require_https_web_seeds == 0)
        #expect(sourcePolicy.dht_locked == 0)
        #expect(sourcePolicy.peer_exchange_locked == 0)
        #expect(sourcePolicy.lsd_locked == 0)
        #expect(sourcePolicy.metadata_validation_pending == 0)
        #expect(sourcePolicy.allow_pre_metadata_dht == 0)
        #expect(errorBuffer.string == "Missing torrent client, torrent id, or source policy.")

        errorBuffer.writeSentinel()
        let setSourcePolicy = errorBuffer.withMutableBuffer { buffer in
            unsafe TorrentClientSetSourcePolicyField(
                nil,
                nil,
                Int32(TTORRENT_SOURCE_POLICY_ENABLE_DHT),
                0,
                &buffer,
                Int32(buffer.count)
            )
        }
        #expect(setSourcePolicy == 1)
        #expect(errorBuffer.string == "Missing torrent client or torrent id.")

        var activity = TTorrentWebSeedActivitySnapshot(active_count: 3, download_rate: 4, total_download: 5)
        revision = UInt64.max
        let copiedWebSeedActivity = unsafe TorrentClientCopyWebSeedActivity(nil, nil, &activity, &revision)
        #expect(copiedWebSeedActivity == 0)
        #expect(activity.active_count == 0)
        #expect(activity.download_rate == 0)
        #expect(activity.total_download == 0)
        #expect(revision == 0)

        var pieceMap = TTorrentPieceMapSnapshot(
            total_pieces: 12,
            completed_pieces: 6,
            available_pieces: 12,
            map_available: 1,
            map_truncated: 1
        )
        revision = UInt64.max
        requiredCount = -1
        var pieces = Array<UInt8>(repeating: 1, count: 4)
        let copiedPieceMap = unsafe pieces.withUnsafeMutableBufferPointer { buffer in
            unsafe TorrentClientCopyPieceMap(nil, nil, &pieceMap, buffer.baseAddress, Int32(buffer.count), &revision, &requiredCount)
        }
        #expect(copiedPieceMap == 0)
        #expect(pieceMap.total_pieces == 0)
        #expect(pieceMap.completed_pieces == 0)
        #expect(pieceMap.available_pieces == 0)
        #expect(pieceMap.map_available == 0)
        #expect(pieceMap.map_truncated == 0)
        #expect(revision == 0)
        #expect(requiredCount == 0)

        errorBuffer = BridgeErrorBuffer()
        errorBuffer.writeSentinel()
        let tookAlertError = errorBuffer.withMutableBuffer { buffer in
            unsafe TorrentClientTakeAlertError(nil, &buffer, Int32(buffer.count))
        }
        #expect(tookAlertError == 0)
        #expect(errorBuffer.string == "")
    }

    @Test("Null client mutation APIs report contract errors")
    func nullClientMutationAPIsReportContractErrors() {
        expectBridgeError(
            code: 1,
            message: "Missing torrent client, magnet URI, save path, or add options."
        ) { errorBuffer, capacity in
            var addedID = Array<CChar>(repeating: 1, count: Int(TTORRENT_ID_CAPACITY))
            return unsafe addedID.withUnsafeMutableBufferPointer { addedIDBuffer in
                unsafe TorrentClientAddMagnet(
                    nil,
                    nil,
                    nil,
                    nil,
                    addedIDBuffer.baseAddress,
                    Int32(addedIDBuffer.count),
                    &errorBuffer,
                    capacity
                )
            }
        }

        expectBridgeError(
            code: 1,
            message: "Missing torrent client or torrent id."
        ) { errorBuffer, capacity in
            unsafe TorrentClientRequestSources(nil, nil, &errorBuffer, capacity)
        }

        expectBridgeError(
            code: 1,
            message: "Missing torrent client or torrent id."
        ) { errorBuffer, capacity in
            unsafe TorrentClientRequestPieceMap(nil, nil, &errorBuffer, capacity)
        }

        expectBridgeError(
            code: 1,
            message: "Missing torrent client."
        ) { errorBuffer, capacity in
            unsafe TorrentClientBlockNetwork(nil, &errorBuffer, capacity)
        }

        expectBridgeError(
            code: 1,
            message: "Missing torrent client."
        ) { errorBuffer, capacity in
            unsafe TorrentClientSaveAllChecked(nil, &errorBuffer, capacity)
        }

        TorrentClientSaveAll(nil)
        TorrentClientDestroy(nil)
        TorrentClientDestroyBlocking(nil)
    }

    @Test("Creates, blocks, queries, saves, and destroys an empty client")
    func createsBlocksQueriesSavesAndDestroysEmptyClient() throws {
        try withTemporaryDirectory { stateDirectory in
            let result = emptyClientSmokeResult(statePath: stateDirectory.path)

            #expect(result.didCreate, Comment(rawValue: result.creationError))
            #expect(result.blockNetworkCode == 0, Comment(rawValue: result.blockNetworkError))
            #expect(result.copiedNetworkStatus == 1)
            #expect(result.networkBlocked)
            #expect(result.copiedSnapshots == 0)
            #expect(result.requiredSnapshotCount == 0)
            #expect(result.saveAllCheckedCode == 0, Comment(rawValue: result.saveAllCheckedError))
        }
    }
}

private struct BridgeErrorBuffer {
    private var storage = Array<CChar>(repeating: 0, count: 1_024)

    var string: String {
        unsafe storage.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return ""
            }
            return unsafe String(cString: baseAddress)
        }
    }

    mutating func writeSentinel() {
        storage = Array("sentinel".utf8CString)
        storage.append(contentsOf: Array(repeating: 0, count: 1_024 - storage.count))
    }

    mutating func withMutableBuffer<Result>(_ body: (inout [CChar]) -> Result) -> Result {
        body(&storage)
    }
}

private func invalidCreateResult(path: String?) -> (didCreate: Bool, error: String) {
    var errorBuffer = BridgeErrorBuffer()
    let didCreate = errorBuffer.withMutableBuffer { buffer -> Bool in
        if let path {
            let client = unsafe path.withCString { statePath in
                unsafe TorrentClientCreateWithError(statePath, 1, &buffer, Int32(buffer.count))
            }
            if let client = unsafe client {
                unsafe TorrentClientDestroyBlocking(client)
                return true
            }
            return false
        }
        let client = unsafe TorrentClientCreateWithError(nil, 1, &buffer, Int32(buffer.count))
        if let client = unsafe client {
            unsafe TorrentClientDestroyBlocking(client)
            return true
        }
        return false
    }
    return (didCreate, errorBuffer.string)
}

private func expectBridgeSuccess(
    _ body: (inout [CChar], Int32) -> Int32,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    var errorBuffer = BridgeErrorBuffer()
    let code = errorBuffer.withMutableBuffer { buffer in
        body(&buffer, Int32(buffer.count))
    }

    #expect(code == 0, Comment(rawValue: errorBuffer.string), sourceLocation: sourceLocation)
    #expect(errorBuffer.string == "", sourceLocation: sourceLocation)
}

private func expectBridgeError(
    code expectedCode: Int32,
    message expectedMessage: String,
    _ body: (inout [CChar], Int32) -> Int32,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    var errorBuffer = BridgeErrorBuffer()
    let code = errorBuffer.withMutableBuffer { buffer in
        body(&buffer, Int32(buffer.count))
    }

    #expect(code == expectedCode, sourceLocation: sourceLocation)
    #expect(errorBuffer.string == expectedMessage, sourceLocation: sourceLocation)
}

private struct EmptyClientSmokeResult {
    var didCreate = false
    var creationError = ""
    var blockNetworkCode: Int32 = -1
    var blockNetworkError = ""
    var copiedNetworkStatus: Int32 = 0
    var networkBlocked = false
    var copiedSnapshots: Int32 = -1
    var requiredSnapshotCount: Int32 = -1
    var saveAllCheckedCode: Int32 = -1
    var saveAllCheckedError = ""
}

private func emptyClientSmokeResult(statePath: String) -> EmptyClientSmokeResult {
    var result = EmptyClientSmokeResult()
    var creationErrorBuffer = BridgeErrorBuffer()
    let maybeClient = unsafe creationErrorBuffer.withMutableBuffer { buffer in
        unsafe statePath.withCString { statePathPointer in
            unsafe TorrentClientCreateWithError(statePathPointer, 1, &buffer, Int32(buffer.count))
        }
    }
    guard let client = unsafe maybeClient else {
        result.creationError = creationErrorBuffer.string
        return result
    }
    result.didCreate = true
    defer {
        unsafe TorrentClientDestroyBlocking(client)
    }

    var blockNetworkErrorBuffer = BridgeErrorBuffer()
    result.blockNetworkCode = blockNetworkErrorBuffer.withMutableBuffer { buffer in
        unsafe TorrentClientBlockNetwork(client, &buffer, Int32(buffer.count))
    }
    result.blockNetworkError = blockNetworkErrorBuffer.string

    var status = TTorrentNetworkStatus()
    result.copiedNetworkStatus = unsafe TorrentClientCopyNetworkStatus(client, &status)
    result.networkBlocked = status.network_blocked != 0

    var revision: UInt64 = UInt64.max
    var requiredCount: Int32 = -1
    result.copiedSnapshots = unsafe TorrentClientCopySnapshotBatch(client, nil, 0, &revision, &requiredCount)
    result.requiredSnapshotCount = requiredCount

    var saveErrorBuffer = BridgeErrorBuffer()
    result.saveAllCheckedCode = saveErrorBuffer.withMutableBuffer { buffer in
        unsafe TorrentClientSaveAllChecked(client, &buffer, Int32(buffer.count))
    }
    result.saveAllCheckedError = saveErrorBuffer.string

    return result
}
