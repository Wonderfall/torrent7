import Darwin
import Foundation
import Testing
import TorrentBridge
import TorrentEngineModel

// SAFETY: Ownership/lifetime: this contract stub only tests pointer presence and never owns
// or dereferences it; bounds/alignment: no memory is accessed; synchronization: the stub is
// stateless; safe alternative: the production callback table requires a C pointer signature.
private func contractPayloadContextRetain(_ context: UnsafeMutableRawPointer?) -> UInt8 {
    unsafe context == nil ? 0 : 1
}

private func contractPayloadContextRelease(_ context: UnsafeMutableRawPointer?) {}

private func contractPayloadOpen(
    _ context: UnsafeMutableRawPointer?,
    _ claimID: UnsafePointer<UInt8>,
    _ generation: UInt64,
    _ fileIndex: Int32,
    _ writable: UInt8,
    _ descriptorOut: UnsafeMutablePointer<Int32>
) -> Int32 {
    2
}

private func contractPayloadSize(
    _ context: UnsafeMutableRawPointer?,
    _ claimID: UnsafePointer<UInt8>,
    _ generation: UInt64,
    _ fileIndex: Int32,
    _ sizeOut: UnsafeMutablePointer<Int64>
) -> Int32 {
    2
}

// SAFETY: Ownership/lifetime: the nonnull sentinel is never dereferenced by these stubs and
// the table is copied synchronously by client creation; bounds/alignment: no sentinel memory
// is accessed and the table has its exact imported layout; synchronization: callbacks are
// stateless; safe alternative: ABI contract tests must construct the imported C callback table.
private func contractPayloadBrokerCallbacks() -> TTorrentPayloadBrokerCallbacks {
    var callbacks = unsafe TTorrentPayloadBrokerCallbacks()
    unsafe callbacks.context = UnsafeMutableRawPointer(bitPattern: 1)
    unsafe callbacks.retain_context = contractPayloadContextRetain
    unsafe callbacks.release_context = contractPayloadContextRelease
    unsafe callbacks.open_payload = contractPayloadOpen
    unsafe callbacks.payload_size = contractPayloadSize
    return unsafe callbacks
}

// SAFETY: Ownership/lifetime: this stub only tests pointer presence without ownership or
// dereference; bounds/alignment: no memory is accessed; synchronization: it is stateless;
// safe alternative: the production C callback signature requires an opaque pointer.
private func contractSwarmMetainfoContextRetain(
    _ context: UnsafeMutableRawPointer?
) -> UInt8 {
    unsafe context == nil ? 0 : 1
}

private func contractSwarmMetainfoContextRelease(_ context: UnsafeMutableRawPointer?) {}

// SAFETY: Ownership/lifetime: the native contract-test caller owns resultOut for this
// synchronous stub; bounds/alignment: the ABI supplies one aligned typed result value;
// synchronization: the stub is stateless; safe alternative: ABI validation requires the
// real C callback signature.
private func contractSwarmMetainfoParse(
    _ context: UnsafeMutableRawPointer?,
    _ info: UnsafePointer<CChar>,
    _ infoSize: Int32,
    _ resultOut: UnsafeMutablePointer<TTorrentOwnedMetainfoCapsule>
) -> Int32 {
    unsafe resultOut.pointee = TTorrentOwnedMetainfoCapsule(bytes: nil, size: 0)
    return EINVAL
}

// SAFETY: Ownership/lifetime: the callback receives ownership only of a malloc pointer from
// its paired parser (nil in this stub); bounds/alignment: free does not dereference and accepts
// that original pointer; synchronization: each capsule is uniquely owned; safe alternative:
// the C callback contract requires C allocator-compatible release.
private func contractSwarmMetainfoCapsuleRelease(
    _ context: UnsafeMutableRawPointer?,
    _ capsule: TTorrentOwnedMetainfoCapsule
) {
    unsafe free(capsule.bytes)
}

// SAFETY: Ownership/lifetime: the nonnull sentinel is never dereferenced and the callback
// table is copied synchronously; bounds/alignment: the imported table has exact C layout;
// synchronization: stubs are stateless; safe alternative: the ABI test must construct the
// imported callback table directly.
private func contractSwarmMetainfoParserCallbacks()
    -> TTorrentSwarmMetainfoParserCallbacks {
    var callbacks = unsafe TTorrentSwarmMetainfoParserCallbacks()
    unsafe callbacks.context = UnsafeMutableRawPointer(bitPattern: 1)
    unsafe callbacks.retain_context = contractSwarmMetainfoContextRetain
    unsafe callbacks.release_context = contractSwarmMetainfoContextRelease
    unsafe callbacks.parse_info = contractSwarmMetainfoParse
    unsafe callbacks.release_capsule = contractSwarmMetainfoCapsuleRelease
    return unsafe callbacks
}

// SAFETY: Ownership/lifetime: this stub only tests pointer presence without dereference;
// bounds/alignment: no memory is accessed; synchronization: it is stateless; safe alternative:
// the production C callback signature requires an opaque pointer.
private func contractPeerProtocolContextRetain(
    _ context: UnsafeMutableRawPointer?
) -> UInt8 {
    unsafe context == nil ? 0 : 1
}

private func contractPeerProtocolContextRelease(_ context: UnsafeMutableRawPointer?) {}

// SAFETY: Ownership/lifetime: the native test caller owns resultOut for this synchronous stub;
// bounds/alignment: it supplies one aligned typed result value; synchronization: the stub is
// stateless; safe alternative: ABI validation requires the actual C callback signature.
private func contractExtensionHandshakeParse(
    _ context: UnsafeMutableRawPointer?,
    _ message: UnsafePointer<CChar>,
    _ messageSize: Int32,
    _ clientVersionOut: UnsafeMutablePointer<UInt8>,
    _ clientVersionCapacity: Int32,
    _ resultOut: UnsafeMutablePointer<TTorrentExtensionHandshakeResult>
) -> Int32 {
    unsafe resultOut.pointee = TTorrentExtensionHandshakeResult()
    return EINVAL
}

// SAFETY: Ownership/lifetime: the native test caller owns resultOut for this synchronous stub;
// bounds/alignment: it supplies one aligned typed result value; synchronization: the stub is
// stateless; safe alternative: ABI validation requires the actual C callback signature.
private func contractMetadataMessageParse(
    _ context: UnsafeMutableRawPointer?,
    _ message: UnsafePointer<CChar>,
    _ messageSize: Int32,
    _ resultOut: UnsafeMutablePointer<TTorrentMetadataMessageResult>
) -> Int32 {
    unsafe resultOut.pointee = TTorrentMetadataMessageResult()
    return EINVAL
}

// SAFETY: Ownership/lifetime: the native test caller owns resultOut for this synchronous stub;
// bounds/alignment: it supplies one aligned typed result value; synchronization: the stub is
// stateless; safe alternative: ABI validation requires the actual C callback signature.
private func contractPeerExchangeParse(
    _ context: UnsafeMutableRawPointer?,
    _ message: UnsafePointer<CChar>,
    _ messageSize: Int32,
    _ recordsOut: UnsafeMutablePointer<TTorrentPeerExchangeRecord>,
    _ recordCapacity: Int32,
    _ resultOut: UnsafeMutablePointer<TTorrentPeerExchangeResult>
) -> Int32 {
    unsafe resultOut.pointee = TTorrentPeerExchangeResult()
    return EINVAL
}

// SAFETY: Ownership/lifetime: the nonnull sentinel is never dereferenced and the callback
// table is copied synchronously; bounds/alignment: the imported table has exact C layout;
// synchronization: stubs are stateless; safe alternative: the ABI test must construct the
// imported callback table directly.
private func contractPeerProtocolParserCallbacks()
    -> TTorrentPeerProtocolParserCallbacks {
    var callbacks = unsafe TTorrentPeerProtocolParserCallbacks()
    unsafe callbacks.context = UnsafeMutableRawPointer(bitPattern: 1)
    unsafe callbacks.retain_context = contractPeerProtocolContextRetain
    unsafe callbacks.release_context = contractPeerProtocolContextRelease
    unsafe callbacks.parse_extension_handshake = contractExtensionHandshakeParse
    unsafe callbacks.parse_metadata_message = contractMetadataMessageParse
    unsafe callbacks.parse_peer_exchange = contractPeerExchangeParse
    return unsafe callbacks
}

// SAFETY: Ownership/lifetime: this stub only tests pointer presence without dereference;
// bounds/alignment: no memory is accessed; synchronization: it is stateless; safe alternative:
// the production C callback signature requires an opaque pointer.
private func contractTrackerParserContextRetain(
    _ context: UnsafeMutableRawPointer?
) -> UInt8 {
    unsafe context == nil ? 0 : 1
}

private func contractTrackerParserContextRelease(_ context: UnsafeMutableRawPointer?) {}

// SAFETY: Ownership/lifetime: the native test caller owns resultOut for this synchronous stub;
// bounds/alignment: it supplies one aligned typed result value; synchronization: the stub is
// stateless; safe alternative: ABI validation requires the actual C callback signature.
private func contractHTTPTrackerResponseParse(
    _ context: UnsafeMutableRawPointer?,
    _ body: UnsafePointer<CChar>,
    _ bodySize: Int32,
    _ isScrape: UInt8,
    _ scrapeInfoHash: UnsafePointer<UInt8>?,
    _ scrapeInfoHashSize: Int32,
    _ peersOut: UnsafeMutablePointer<TTorrentTrackerPeerRecord>,
    _ peerCapacity: Int32,
    _ resultOut: UnsafeMutablePointer<TTorrentHTTPTrackerResponseResult>
) -> Int32 {
    unsafe resultOut.pointee = TTorrentHTTPTrackerResponseResult()
    return EINVAL
}

// SAFETY: Ownership/lifetime: the nonnull sentinel is never dereferenced and the callback
// table is copied synchronously; bounds/alignment: the imported table has exact C layout;
// synchronization: stubs are stateless; safe alternative: the ABI test must construct the
// imported callback table directly.
private func contractTrackerResponseParserCallbacks()
    -> TTorrentTrackerResponseParserCallbacks {
    var callbacks = unsafe TTorrentTrackerResponseParserCallbacks()
    unsafe callbacks.context = UnsafeMutableRawPointer(bitPattern: 1)
    unsafe callbacks.retain_context = contractTrackerParserContextRetain
    unsafe callbacks.release_context = contractTrackerParserContextRelease
    unsafe callbacks.parse_http_response = contractHTTPTrackerResponseParse
    return unsafe callbacks
}

// SAFETY: Ownership/lifetime: this stub only tests pointer presence without dereference;
// bounds/alignment: no memory is accessed; synchronization: it is stateless; safe alternative:
// the production C callback signature requires an opaque pointer.
private func contractDHTParserContextRetain(
    _ context: UnsafeMutableRawPointer?
) -> UInt8 {
    unsafe context == nil ? 0 : 1
}

private func contractDHTParserContextRelease(_ context: UnsafeMutableRawPointer?) {}

// SAFETY: Ownership/lifetime: the native test caller owns resultOut for this synchronous stub;
// bounds/alignment: it supplies one aligned typed result value; synchronization: the stub is
// stateless; safe alternative: ABI validation requires the actual C callback signature.
private func contractDHTMessageParse(
    _ context: UnsafeMutableRawPointer?,
    _ body: UnsafePointer<CChar>,
    _ bodySize: Int32,
    _ sourceAddressFamily: UInt8,
    _ nodesOut: UnsafeMutablePointer<TTorrentDHTNodeRecord>,
    _ nodeCapacity: Int32,
    _ peersOut: UnsafeMutablePointer<TTorrentDHTPeerRecord>,
    _ peerCapacity: Int32,
    _ resultOut: UnsafeMutablePointer<TTorrentDHTMessageResult>
) -> Int32 {
    unsafe resultOut.pointee = TTorrentDHTMessageResult()
    return EINVAL
}

// SAFETY: Ownership/lifetime: the nonnull sentinel is never dereferenced and the callback
// table is copied synchronously; bounds/alignment: the imported table has exact C layout;
// synchronization: stubs are stateless; safe alternative: the ABI test must construct the
// imported callback table directly.
private func contractDHTMessageParserCallbacks()
    -> TTorrentDHTMessageParserCallbacks {
    var callbacks = unsafe TTorrentDHTMessageParserCallbacks()
    unsafe callbacks.context = UnsafeMutableRawPointer(bitPattern: 1)
    unsafe callbacks.retain_context = contractDHTParserContextRetain
    unsafe callbacks.release_context = contractDHTParserContextRelease
    unsafe callbacks.parse_message = contractDHTMessageParse
    return unsafe callbacks
}

private func bridgeString(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
}

@Suite("Torrent bridge contract")
struct TorrentBridgeContractTests {
    @Test("Pins bridge ABI version, limits, states, and native event kinds")
    func pinsBridgeConstants() {
        #expect(UInt32(TTORRENT_BRIDGE_ABI_VERSION) == 64)
        #expect(UInt32(TTORRENT_MAGNET_IMPORT_SCHEMA_VERSION) == 1)
        #expect(UInt32(TTORRENT_METAINFO_CAPSULE_MAGIC) == 0x494d_3754)
        #expect(UInt16(TTORRENT_METAINFO_CAPSULE_SCHEMA_VERSION) == 1)
        #expect(UInt16(TTORRENT_METAINFO_CAPSULE_HEADER_SIZE) == 160)
        #expect(UInt16(TTORRENT_METAINFO_CAPSULE_FILE_RECORD_SIZE) == 32)
        #expect(UInt16(TTORRENT_METAINFO_CAPSULE_RANGE_RECORD_SIZE) == 8)
        #expect(UInt16(TTORRENT_METAINFO_CAPSULE_TRACKER_RECORD_SIZE) == 16)
        #expect(UInt16(TTORRENT_METAINFO_CAPSULE_PIECE_LAYER_RECORD_SIZE) == 24)
        #expect(UInt16(TTORRENT_METAINFO_CAPSULE_FILE_INDEX_RECORD_SIZE) == 4)
        #expect(Int(TTORRENT_METAINFO_CAPSULE_MAX_BYTES) == 96 * 1_024 * 1_024)
        #expect(UInt8(TTORRENT_METAINFO_INPUT_TORRENT_FILE) == 1)
        #expect(UInt8(TTORRENT_METAINFO_INPUT_INFO_DICTIONARY) == 2)
        #expect(UInt8(TTORRENT_METAINFO_KIND_V1) == 1)
        #expect(UInt8(TTORRENT_METAINFO_KIND_V2) == 2)
        #expect(UInt8(TTORRENT_METAINFO_KIND_HYBRID) == 3)
        #expect(UInt8(TTORRENT_METAINFO_PRIVATE) == 1 << 0)
        #expect(UInt32(TTORRENT_METAINFO_FILE_PADDING) == 1 << 0)
        #expect(UInt32(TTORRENT_METAINFO_FILE_EXECUTABLE) == 1 << 1)
        #expect(UInt32(TTORRENT_METAINFO_FILE_HIDDEN) == 1 << 2)
        #expect(UInt16(TTORRENT_METAINFO_FIELD_ANNOUNCE) == 1 << 0)
        #expect(UInt16(TTORRENT_METAINFO_FIELD_ANNOUNCE_LIST) == 1 << 1)
        #expect(UInt16(TTORRENT_METAINFO_FIELD_URL_LIST) == 1 << 2)
        #expect(UInt16(TTORRENT_METAINFO_FIELD_PIECE_LAYERS) == 1 << 3)
        #expect(UInt16(TTORRENT_METAINFO_FIELD_COMMENT) == 1 << 4)
        #expect(UInt16(TTORRENT_METAINFO_FIELD_CREATED_BY) == 1 << 5)
        #expect(UInt16(TTORRENT_METAINFO_FIELD_CREATION_DATE) == 1 << 6)
        #expect(UInt16(TTORRENT_METAINFO_FIELD_DHT_NODES) == 1 << 7)
        #expect(Int32(TTORRENT_MAX_HTTP_TRACKER_RESPONSE_BYTES) == 512 * 1_024)
        #expect(Int32(TTORRENT_MAX_TRACKER_RESPONSE_PEERS) == 3_000)
        #expect(Int32(TTORRENT_MAX_TRACKER_ID_BYTES) == 1_024)
        #expect(Int32(TTORRENT_MAX_TRACKER_MESSAGE_BYTES) == 1_024)
        #expect(Int32(TTORRENT_MAX_TRACKER_HOSTNAME_BYTES) == 255)
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
        #expect(Int32(TTORRENT_MAX_EVENT_COUNT) == 1_024)
        #expect(Int32(TTORRENT_MAX_RESUME_ID_COUNT) == 8)
        #expect(Int32(TTORRENT_REMOVAL_TOMBSTONE_FILENAME_CAPACITY) == 96)
        #expect(UInt8(TTORRENT_EVENT_TORRENTS_CHANGED) == 1)
        #expect(UInt8(TTORRENT_EVENT_TRACKERS_CHANGED) == 2)
        #expect(UInt8(TTORRENT_EVENT_WEB_SEEDS_CHANGED) == 3)
        #expect(UInt8(TTORRENT_EVENT_FILES_CHANGED) == 4)
        #expect(UInt8(TTORRENT_EVENT_NETWORK_CHANGED) == 5)
        #expect(UInt8(TTORRENT_EVENT_ERRORS_AVAILABLE) == 6)
        #expect(UInt8(TTORRENT_EVENT_PIECES_CHANGED) == 7)
        #expect(UInt8(TTORRENT_EVENT_TRACKER_HOSTS_CHANGED) == 8)
        #expect(UInt8(TTORRENT_EVENT_HEALTH_CHANGED) == 9)
        #expect(UInt8(TTORRENT_EVENT_RESYNC_REQUIRED) == 10)
        #expect(UInt8(TTORRENT_EVENT_RESUME_SAVE_REQUESTED) == 11)
        #expect(UInt8(TTORRENT_EVENT_RESUME_RETRY_REQUESTED) == 12)
        #expect(UInt8(TTORRENT_EVENT_CRITICAL_FAULT) == 13)
        #expect(UInt32(TTORRENT_CRITICAL_FAULT_SESSION_IDENTITY_AUTHORITY) == 1 << 0)
        #expect(UInt32(TTORRENT_CRITICAL_FAULT_NETWORK_CONTAINMENT_UNCONFIRMED) == 1 << 1)
        #expect(UInt8(TTORRENT_RESUME_SAVE_ROUTINE) == 0)
        #expect(UInt8(TTORRENT_RESUME_SAVE_POLICY) == 1)
        #expect(UInt8(TTORRENT_RESUME_SAVE_FULL) == 2)
        #expect(Int32(TTORRENT_QUEUE_PRIORITY_LOW) == 0)
        #expect(Int32(TTORRENT_QUEUE_PRIORITY_NORMAL) == 1)
        #expect(Int32(TTORRENT_QUEUE_PRIORITY_HIGH) == 2)
        #expect(Int32(TTORRENT_FILE_PRIORITY_SKIP) == 0)
        #expect(Int32(TTORRENT_FILE_PRIORITY_LOW) == 1)
        #expect(Int32(TTORRENT_FILE_PRIORITY_NORMAL) == 4)
        #expect(Int32(TTORRENT_FILE_PRIORITY_HIGH) == 7)
        #expect(Int32(TTORRENT_ADD_REJECTED) == 0)
        #expect(Int32(TTORRENT_ADD_COMMITTED) == 1)
        #expect(Int32(TTORRENT_ADD_OUTCOME_UNKNOWN) == 2)
        #expect(UInt8(TTORRENT_BOOLEAN_POLICY_INHERIT) == 0)
        #expect(UInt8(TTORRENT_BOOLEAN_POLICY_DISABLED) == 1)
        #expect(UInt8(TTORRENT_BOOLEAN_POLICY_ENABLED) == 2)
        #expect(UInt8(TTORRENT_HTTPS_POLICY_INHERIT) == 0)
        #expect(UInt8(TTORRENT_HTTPS_POLICY_ORIGINAL) == 1)
        #expect(UInt8(TTORRENT_HTTPS_POLICY_PREFER) == 2)
        #expect(UInt8(TTORRENT_HTTPS_POLICY_REQUIRE) == 3)
        #expect(UInt8(TTORRENT_DHT_DISCOVERY_ALONGSIDE_TRACKERS) == 0)
        #expect(UInt8(TTORRENT_DHT_DISCOVERY_AFTER_ALL_TRACKERS_FAIL) == 1)
        #expect(UInt8(TTORRENT_DHT_STATUS_DISABLED) == 0)
        #expect(UInt8(TTORRENT_DHT_STATUS_STARTING) == 1)
        #expect(UInt8(TTORRENT_DHT_STATUS_RUNNING) == 2)
        #expect(Int(TTORRENT_MAX_DHT_MESSAGE_BYTES) == 1_500)
        #expect(Int(TTORRENT_MAX_DHT_MESSAGE_NODES) == 64)
        #expect(Int(TTORRENT_MAX_DHT_MESSAGE_PEERS) == 256)
        #expect(Int(TTORRENT_MAX_DHT_MESSAGE_SAMPLES) == 64)
        #expect(UInt8(TTORRENT_DHT_MESSAGE_QUERY) == 1)
        #expect(UInt8(TTORRENT_DHT_MESSAGE_RESPONSE) == 2)
        #expect(UInt8(TTORRENT_DHT_MESSAGE_ERROR) == 3)
        #expect(UInt8(TTORRENT_DHT_QUERY_UNKNOWN) == 255)
        #expect(UInt8(TTORRENT_CONTENT_KIND_UNKNOWN) == 0)
        #expect(UInt8(TTORRENT_CONTENT_KIND_SINGLE_FILE) == 1)
        #expect(UInt8(TTORRENT_CONTENT_KIND_DIRECTORY) == 2)
    }

    // SAFETY: Ownership/lifetime: MemoryLayout inspects only compile-time imported types;
    // bounds/alignment: no instances or addresses are accessed and expected C sizes/alignments
    // are asserted; synchronization: this metadata query is immutable; safe alternative:
    // strict memory safety marks callback-bearing C structs unsafe even for layout inspection.
    @Test("Pins Swift-imported C struct layout")
    func pinsSwiftImportedCStructLayout() {
        #expect(MemoryLayout<TTorrentEvent>.size == 16)
        #expect(MemoryLayout<TTorrentEvent>.alignment == 8)
        #expect(MemoryLayout<TTorrentEvent>.offset(of: \.native_token) == 0)
        #expect(MemoryLayout<TTorrentEvent>.offset(of: \.kind) == 8)
        #expect(MemoryLayout<TTorrentEvent>.offset(of: \.resume_save_mode) == 9)
        #expect(MemoryLayout<TTorrentEvent>.offset(of: \.critical_faults) == 12)
        #expect(MemoryLayout<TTorrentPresentationMetadata>.size == 1_040)
        #expect(MemoryLayout<TTorrentPresentationMetadata>.alignment == 8)
        #expect(MemoryLayout<TTorrentPresentationMetadata>.offset(of: \.created_time) == 8)
        #expect(MemoryLayout<TTorrentPresentationMetadata>.offset(of: \.comment) == 16)
        #expect(MemoryLayout<TTorrentResumeID>.size == 68)
        #expect(MemoryLayout<TTorrentResumeID>.alignment == 1)
        #expect(MemoryLayout<TTorrentSnapshot>.size == 2_336)
        #expect(MemoryLayout<TTorrentSnapshot>.alignment == 8)
        #expect(MemoryLayout<TTorrentSnapshot>.offset(of: \TTorrentSnapshot.content_kind) == 2_334)
        #expect(MemoryLayout<TTorrentQueuePlacement>.size == 16)
        #expect(MemoryLayout<TTorrentQueuePlacement>.alignment == 8)
        #expect(MemoryLayout<TTorrentQueuePlacement>.offset(of: \.priority) == 8)
        #expect(MemoryLayout<TTorrentTrackerSnapshot>.size == 1_560)
        #expect(MemoryLayout<TTorrentTrackerSnapshot>.alignment == 4)
        #expect(MemoryLayout<TTorrentTrackerHostSnapshot>.size == 264)
        #expect(MemoryLayout<TTorrentTrackerHostSnapshot>.alignment == 8)
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
        let payloadBrokerCallbacksSize = unsafe MemoryLayout<TTorrentPayloadBrokerCallbacks>.size
        let payloadBrokerCallbacksAlignment = unsafe MemoryLayout<TTorrentPayloadBrokerCallbacks>.alignment
        let ownedMetainfoCapsuleSize = unsafe MemoryLayout<TTorrentOwnedMetainfoCapsule>.size
        let ownedMetainfoCapsuleAlignment = unsafe MemoryLayout<TTorrentOwnedMetainfoCapsule>.alignment
        let swarmParserCallbacksSize = unsafe MemoryLayout<TTorrentSwarmMetainfoParserCallbacks>.size
        let swarmParserCallbacksAlignment = unsafe MemoryLayout<TTorrentSwarmMetainfoParserCallbacks>.alignment
        let handshakeResultSize = MemoryLayout<TTorrentExtensionHandshakeResult>.size
        let metadataResultSize = MemoryLayout<TTorrentMetadataMessageResult>.size
        let pexRecordSize = MemoryLayout<TTorrentPeerExchangeRecord>.size
        let pexResultSize = MemoryLayout<TTorrentPeerExchangeResult>.size
        let peerParserCallbacksSize = unsafe MemoryLayout<TTorrentPeerProtocolParserCallbacks>.size
        let trackerPeerRecordSize = MemoryLayout<TTorrentTrackerPeerRecord>.size
        let trackerResultSize = MemoryLayout<TTorrentHTTPTrackerResponseResult>.size
        let trackerParserCallbacksSize = unsafe MemoryLayout<TTorrentTrackerResponseParserCallbacks>.size
        let dhtParserCallbacksSize = unsafe MemoryLayout<TTorrentDHTMessageParserCallbacks>.size
        #expect(payloadBrokerCallbacksSize == 40)
        #expect(payloadBrokerCallbacksAlignment == 8)
        #expect(ownedMetainfoCapsuleSize == 16)
        #expect(ownedMetainfoCapsuleAlignment == 8)
        #expect(swarmParserCallbacksSize == 40)
        #expect(swarmParserCallbacksAlignment == 8)
        #expect(handshakeResultSize == 64)
        #expect(metadataResultSize == 32)
        #expect(pexRecordSize == 24)
        #expect(pexResultSize == 16)
        #expect(peerParserCallbacksSize == 48)
        #expect(trackerPeerRecordSize == 40)
        #expect(MemoryLayout<TTorrentTrackerPeerRecord>.alignment == 8)
        #expect(trackerResultSize == 80)
        #expect(MemoryLayout<TTorrentHTTPTrackerResponseResult>.alignment == 8)
        #expect(trackerParserCallbacksSize == 32)
        #expect(MemoryLayout<TTorrentDHTNodeRecord>.size == 32)
        #expect(MemoryLayout<TTorrentDHTNodeRecord>.alignment == 8)
        #expect(MemoryLayout<TTorrentDHTPeerRecord>.size == 24)
        #expect(MemoryLayout<TTorrentDHTPeerRecord>.alignment == 8)
        #expect(MemoryLayout<TTorrentDHTMessageResult>.size == 112)
        #expect(MemoryLayout<TTorrentDHTMessageResult>.alignment == 8)
        #expect(dhtParserCallbacksSize == 32)
        #expect(MemoryLayout<TTorrentStorageActivation>.size == 96)
        #expect(MemoryLayout<TTorrentStorageActivation>.alignment == 8)
        #expect(MemoryLayout<TTorrentStorageActivation>.offset(of: \.claim_generation) == 16)
        #expect(MemoryLayout<TTorrentStorageActivation>.offset(of: \.source_manifest_digest) == 24)
        #expect(MemoryLayout<TTorrentStorageActivation>.offset(of: \.preserved_torrent_id) == 56)
        #expect(MemoryLayout<TTorrentPieceMapSnapshot>.size == 16)
        #expect(MemoryLayout<TTorrentPieceMapSnapshot>.alignment == 4)
        #expect(MemoryLayout<TTorrentMagnetImport>.size == 68)
        #expect(MemoryLayout<TTorrentMagnetImport>.alignment == 4)
        #expect(MemoryLayout<TTorrentMagnetTracker>.size == 12)
        #expect(MemoryLayout<TTorrentMagnetTracker>.alignment == 4)
        #expect(MemoryLayout<TTorrentByteRange>.size == 8)
        #expect(MemoryLayout<TTorrentByteRange>.alignment == 4)
        #expect(MemoryLayout<TTorrentFileSelectionRange>.size == 8)
        #expect(MemoryLayout<TTorrentFileSelectionRange>.alignment == 4)
        #expect(MemoryLayout<TTorrentSessionSettings>.size == 48)
        #expect(MemoryLayout<TTorrentSessionSettings>.alignment == 4)
        #expect(MemoryLayout<TTorrentSessionSettings>.offset(of: \.dht_discovery_policy) == 46)
        #expect(MemoryLayout<TTorrentNetworkStatus>.size == 656)
        #expect(MemoryLayout<TTorrentNetworkStatus>.alignment == 4)
        #expect(MemoryLayout<TTorrentNetworkStatus>.offset(of: \.dht_routing_nodes) == 648)
        #expect(MemoryLayout<TTorrentNetworkStatus>.offset(of: \.dht_status) == 652)
        #expect(MemoryLayout<TTorrentBridgeHealth>.size == 536)
        #expect(MemoryLayout<TTorrentBridgeHealth>.alignment == 8)
        #expect(MemoryLayout<TTorrentSourcePolicyState>.size == 24)
        #expect(MemoryLayout<TTorrentSourcePolicyState>.alignment == 8)
        #expect(MemoryLayout<TTorrentSourcePolicyApplication>.size == 24)
        #expect(MemoryLayout<TTorrentSourcePolicyApplication>.alignment == 8)
        #expect(MemoryLayout<TTorrentAddOptions>.size == 78)
        #expect(MemoryLayout<TTorrentAddOptions>.alignment == 1)
        #expect(MemoryLayout<TTorrentOptions>.size == 20)
        #expect(MemoryLayout<TTorrentOptions>.alignment == 4)
        #expect(MemoryLayout<TTorrentOptionsResult>.size == 24)
        #expect(MemoryLayout<TTorrentOptionsResult>.alignment == 4)
        #expect(MemoryLayout<TTorrentOptionsResult>.offset(of: \.options) == 4)
        #expect(MemoryLayout<TTorrentWebSeedActivityResult>.size == 24)
        #expect(MemoryLayout<TTorrentWebSeedActivityResult>.alignment == 8)
        #expect(MemoryLayout<TTorrentWebSeedActivityResult>.offset(of: \.activity) == 8)
        #expect(MemoryLayout<TTorrentPeerSourcesResult>.size == 40)
        #expect(MemoryLayout<TTorrentPeerSourcesResult>.alignment == 4)
        #expect(MemoryLayout<TTorrentPeerSourcesResult>.offset(of: \.sources) == 4)
        #expect(MemoryLayout<TTorrentNetworkStatusResult>.size == 660)
        #expect(MemoryLayout<TTorrentNetworkStatusResult>.alignment == 4)
        #expect(MemoryLayout<TTorrentNetworkStatusResult>.offset(of: \.network_status) == 4)
        #expect(MemoryLayout<TTorrentBridgeHealthResult>.size == 544)
        #expect(MemoryLayout<TTorrentBridgeHealthResult>.alignment == 8)
        #expect(MemoryLayout<TTorrentBridgeHealthResult>.offset(of: \.health) == 8)
    }

    @Test("Pins fixed C string field capacities")
    func pinsFixedCStringFieldCapacities() {
        let snapshot = TTorrentSnapshot()
        let presentation = TTorrentPresentationMetadata()
        let tracker = TTorrentTrackerSnapshot()
        let trackerHost = TTorrentTrackerHostSnapshot()
        let webSeed = TTorrentWebSeedSnapshot()
        let file = TTorrentFileSnapshot()
        let network = TTorrentNetworkStatus()
        let health = TTorrentBridgeHealth()

        #expect(MemoryLayout.size(ofValue: snapshot.id) == Int(TTORRENT_ID_CAPACITY))
        #expect(MemoryLayout.size(ofValue: snapshot.id) == 68)
        #expect(MemoryLayout.size(ofValue: snapshot.info_hash) == 68)
        #expect(MemoryLayout.size(ofValue: snapshot.name) == 512)
        #expect(MemoryLayout.size(ofValue: snapshot.save_path) == 1_024)
        #expect(MemoryLayout.size(ofValue: snapshot.error) == 512)
        #expect(MemoryLayout.size(ofValue: presentation.comment) == 1_024)
        #expect(MemoryLayout.size(ofValue: tracker.url) == 1_024)
        #expect(MemoryLayout.size(ofValue: tracker.message) == 512)
        #expect(MemoryLayout.size(ofValue: trackerHost.host) == Int(TTORRENT_TRACKER_HOST_CAPACITY))
        #expect(MemoryLayout.size(ofValue: webSeed.url) == 1_024)
        #expect(MemoryLayout.size(ofValue: file.path) == 1_024)
        #expect(MemoryLayout.size(ofValue: network.endpoint) == 128)
        #expect(MemoryLayout.size(ofValue: network.last_error) == 512)
        #expect(MemoryLayout.size(ofValue: health.last_alert_worker_error) == 512)
    }

    // SAFETY: Ownership/lifetime: the bridge returns process-static version storage;
    // bounds/alignment: its contract guarantees a NUL-terminated CChar sequence;
    // synchronization: immutable storage is read once; safe alternative: the bridge exposes
    // the version only as a C string pointer.
    @Test("Libtorrent version is pinned to 2.1.1")
    func libtorrentVersionIsPinned() {
        let version = unsafe String(cString: TorrentBridgeLibtorrentVersion())

        #expect(version == "2.1.1.0")
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

    // SAFETY: Ownership/lifetime: temporary path/error storage lives through synchronous
    // creation and any returned client is uniquely destroyed; bounds/alignment: MutableSpan
    // and withCString provide exact capacities/NUL termination; synchronization: test state
    // is local; safe alternative: this negative ABI contract can only be exercised via C API.
    @Test("Create rejects an incomplete swarm metainfo parser table")
    func createRejectsIncompleteSwarmMetainfoParser() throws {
        try withTemporaryDirectory { stateDirectory in
            var errorBuffer = BridgeErrorBuffer()
            let maybeClient = unsafe errorBuffer.withMutableBuffer { buffer in
                var error: MutableSpan<CChar> = buffer.mutableSpan
                defer { error = .init() }
                return stateDirectory.torrentFilePath.withCString { path in
                    unsafe TorrentClientCreateWithError(
                        path,
                        1,
                        contractPayloadBrokerCallbacks(),
                        TTorrentSwarmMetainfoParserCallbacks(),
                        contractPeerProtocolParserCallbacks(),
                        contractTrackerResponseParserCallbacks(),
                        contractDHTMessageParserCallbacks(),
                        &error
                    )
                }
            }
            if let client = unsafe maybeClient {
                unsafe TorrentClientDestroyBlocking(client)
            }
            let didCreate = unsafe maybeClient != nil

            #expect(!didCreate)
            #expect(
                errorBuffer.string
                    == "The swarm metainfo parser callback table is incomplete."
            )
        }
    }

    // SAFETY: Ownership/lifetime: temporary path/error storage lives through synchronous
    // creation and any returned client is uniquely destroyed; bounds/alignment: MutableSpan
    // and withCString provide exact capacities/NUL termination; synchronization: test state
    // is local; safe alternative: this negative ABI contract can only be exercised via C API.
    @Test("Create rejects an incomplete peer protocol parser table")
    func createRejectsIncompletePeerProtocolParser() throws {
        try withTemporaryDirectory { stateDirectory in
            var errorBuffer = BridgeErrorBuffer()
            let maybeClient = unsafe errorBuffer.withMutableBuffer { buffer in
                var error: MutableSpan<CChar> = buffer.mutableSpan
                defer { error = .init() }
                return stateDirectory.torrentFilePath.withCString { path in
                    unsafe TorrentClientCreateWithError(
                        path,
                        1,
                        contractPayloadBrokerCallbacks(),
                        contractSwarmMetainfoParserCallbacks(),
                        TTorrentPeerProtocolParserCallbacks(),
                        contractTrackerResponseParserCallbacks(),
                        contractDHTMessageParserCallbacks(),
                        &error
                    )
                }
            }
            if let client = unsafe maybeClient {
                unsafe TorrentClientDestroyBlocking(client)
            }
            #expect(unsafe maybeClient == nil)
            #expect(
                errorBuffer.string
                    == "The peer protocol parser callback table is incomplete."
            )
        }
    }

    // SAFETY: Ownership/lifetime: temporary path/error storage lives through synchronous
    // creation and any returned client is uniquely destroyed; bounds/alignment: MutableSpan
    // and withCString provide exact capacities/NUL termination; synchronization: test state
    // is local; safe alternative: this negative ABI contract can only be exercised via C API.
    @Test("Create rejects an incomplete tracker response parser table")
    func createRejectsIncompleteTrackerResponseParser() throws {
        try withTemporaryDirectory { stateDirectory in
            var errorBuffer = BridgeErrorBuffer()
            let maybeClient = unsafe errorBuffer.withMutableBuffer { buffer in
                var error: MutableSpan<CChar> = buffer.mutableSpan
                defer { error = .init() }
                return stateDirectory.torrentFilePath.withCString { path in
                    unsafe TorrentClientCreateWithError(
                        path,
                        1,
                        contractPayloadBrokerCallbacks(),
                        contractSwarmMetainfoParserCallbacks(),
                        contractPeerProtocolParserCallbacks(),
                        TTorrentTrackerResponseParserCallbacks(),
                        contractDHTMessageParserCallbacks(),
                        &error
                    )
                }
            }
            if let client = unsafe maybeClient {
                unsafe TorrentClientDestroyBlocking(client)
            }
            #expect(unsafe maybeClient == nil)
            #expect(
                errorBuffer.string
                    == "The tracker response parser callback table is incomplete."
            )
        }
    }

    // SAFETY: Ownership/lifetime: temporary path/error storage lives through synchronous
    // creation and any returned client is uniquely destroyed; bounds/alignment: MutableSpan
    // and withCString provide exact capacities/NUL termination; synchronization: test state
    // is local; safe alternative: this negative ABI contract can only be exercised via C API.
    @Test("Create rejects an incomplete DHT message parser table")
    func createRejectsIncompleteDHTMessageParser() throws {
        try withTemporaryDirectory { stateDirectory in
            var errorBuffer = BridgeErrorBuffer()
            let maybeClient = unsafe errorBuffer.withMutableBuffer { buffer in
                var error: MutableSpan<CChar> = buffer.mutableSpan
                defer { error = .init() }
                return stateDirectory.torrentFilePath.withCString { path in
                    unsafe TorrentClientCreateWithError(
                        path,
                        1,
                        contractPayloadBrokerCallbacks(),
                        contractSwarmMetainfoParserCallbacks(),
                        contractPeerProtocolParserCallbacks(),
                        contractTrackerResponseParserCallbacks(),
                        TTorrentDHTMessageParserCallbacks(),
                        &error
                    )
                }
            }
            if let client = unsafe maybeClient {
                unsafe TorrentClientDestroyBlocking(client)
            }
            #expect(unsafe maybeClient == nil)
            #expect(
                errorBuffer.string
                    == "The DHT message parser callback table is incomplete."
            )
        }
    }

    // SAFETY: Ownership/lifetime: all output scalars/arrays are local for synchronous null-client
    // calls; bounds/alignment: typed pointers and exact spans/capacities are supplied and the
    // one fixed-array byte read is within its asserted layout; synchronization: locals are
    // unshared; safe alternative: null-behavior and raw ABI bounds require direct C calls.
    @Test("Null client query APIs zero outputs")
    func nullClientQueryAPIsZeroOutputs() {
        var eventSpan: MutableSpan<TTorrentEvent> = .init()
        var eventCount: Int32 = -1
        var eventsAvailable: UInt8 = 1
        let copiedEvents = unsafe TorrentClientDrainEvents(
            nil,
            &eventSpan,
            &eventCount,
            &eventsAvailable
        )
        #expect(copiedEvents == 0)
        #expect(eventCount == 0)
        #expect(eventsAvailable == 0)

        var presentationSpan: MutableSpan<TTorrentPresentationMetadata> = .init()
        var presentationCount: Int32 = -1
        var presentationAvailable: UInt8 = 1
        let copiedPresentation = unsafe TorrentClientDrainPresentationMetadata(
            nil,
            &presentationSpan,
            &presentationCount,
            &presentationAvailable
        )
        #expect(copiedPresentation == 0)
        #expect(presentationCount == 0)
        #expect(presentationAvailable == 0)

        var requiredCount: Int32 = -1
        var snapshotsAvailable: UInt8 = 1
        let copiedSnapshots = unsafe TorrentClientCopySnapshotBatch(
            nil,
            nil,
            0,
            &requiredCount,
            &snapshotsAvailable
        )
        #expect(copiedSnapshots == 0)
        #expect(requiredCount == 0)
        #expect(snapshotsAvailable == 0)

        let networkResult = TorrentClientCopyNetworkStatus(nil)
        #expect(networkResult.status == 0)
        #expect(networkResult.network_status.listen_port == 0)
        #expect(networkResult.network_status.network_blocked == 0)
        #expect(networkResult.network_status.has_listener == 0)
        #expect(networkResult.network_status.dht_status == UInt8(TTORRENT_DHT_STATUS_DISABLED))

        let healthResult = TorrentClientCopyHealth(nil)
        #expect(healthResult.status == 0)
        #expect(healthResult.health.total_alert_worker_failures == 0)
        #expect(healthResult.health.consecutive_alert_worker_failures == 0)
        #expect(healthResult.health.alert_worker_degraded == 0)
        let firstHealthErrorByte = withUnsafeBytes(of: healthResult.health.last_alert_worker_error) { bytes in
            unsafe bytes[0]
        }
        #expect(firstHealthErrorByte == 0)

        var requiredSourcePolicyCount: Int32 = -1
        var sourcePolicyAvailable: UInt8 = 1
        var sourcePolicySpan: MutableSpan<TTorrentSourcePolicyState> = .init()
        let copiedSourcePolicies = unsafe TorrentClientCopySourcePolicyStateBatch(
            nil,
            &sourcePolicySpan,
            &requiredSourcePolicyCount,
            &sourcePolicyAvailable
        )
        #expect(copiedSourcePolicies == 0)
        #expect(requiredSourcePolicyCount == 0)
        #expect(sourcePolicyAvailable == 0)

        var errorBuffer = BridgeErrorBuffer()
        errorBuffer.writeSentinel()
        let appliedSourcePolicy = errorBuffer.withMutableBuffer { buffer in
            let applicationSpan: Span<TTorrentSourcePolicyApplication> = .init()
            var errorSpan: MutableSpan<CChar> = buffer.mutableSpan
            return TorrentClientApplySourcePolicyState(
                nil,
                applicationSpan,
                &errorSpan
            )
        }
        #expect(appliedSourcePolicy == 1)
        #expect(errorBuffer.string == "Missing torrent client.")

        let webSeedActivityResult = TorrentClientCopyWebSeedActivity(nil, 0)
        #expect(webSeedActivityResult.status == 0)
        #expect(webSeedActivityResult.activity.active_count == 0)
        #expect(webSeedActivityResult.activity.download_rate == 0)
        #expect(webSeedActivityResult.activity.total_download == 0)

        let peerSourcesResult = TorrentClientCopyPeerSources(nil, 0)
        #expect(peerSourcesResult.status == 0)
        #expect(peerSourcesResult.sources.connected == 0)

        var pieceMap = TTorrentPieceMapSnapshot(
            total_pieces: 12,
            completed_pieces: 6,
            available_pieces: 12,
            map_available: 1,
            map_truncated: 1
        )
        requiredCount = -1
        var available: UInt8 = 1
        var pieces = Array<UInt8>(repeating: 1, count: 4)
        let copiedPieceMap = pieces.withUnsafeMutableBufferPointer { buffer in
            unsafe TorrentClientCopyPieceMap(
                nil,
                0,
                &pieceMap,
                buffer.baseAddress,
                Int32(buffer.count),
                &requiredCount,
                &available
            )
        }
        #expect(copiedPieceMap == 0)
        #expect(pieceMap.total_pieces == 0)
        #expect(pieceMap.completed_pieces == 0)
        #expect(pieceMap.available_pieces == 0)
        #expect(pieceMap.map_available == 0)
        #expect(pieceMap.map_truncated == 0)
        #expect(requiredCount == 0)
        #expect(available == 0)

        errorBuffer = BridgeErrorBuffer()
        errorBuffer.writeSentinel()
        let tookAlertError = errorBuffer.withMutableBuffer { buffer in
            unsafe TorrentClientTakeAlertError(nil, &buffer, Int32(buffer.count))
        }
        #expect(tookAlertError == 0)
        #expect(errorBuffer.string == "")
    }

    // SAFETY: Ownership/lifetime: local arrays outlive each synchronous bridge invocation;
    // bounds/alignment: imported Span wrappers carry their exact typed capacities;
    // synchronization: test storage is unshared; safe alternative: verifying the generated
    // safe-interop ABI requires direct calls to the imported C functions.
    @Test("Imports bounded bridge buffers as lifetime-scoped Swift spans")
    func importsBoundedBuffersAsSwiftSpans() {
        var snapshotStorage = [TTorrentSnapshot()]
        var snapshots: MutableSpan<TTorrentSnapshot> = snapshotStorage.mutableSpan
        var requiredCount: Int32 = -1
        var available: UInt8 = 1

        let copiedSnapshots = unsafe TorrentClientCopySnapshotBatch(
            nil,
            &snapshots,
            &requiredCount,
            &available
        )

        #expect(copiedSnapshots == 0)
        #expect(requiredCount == 0)
        #expect(available == 0)

        var errorStorage = [CChar](repeating: 0, count: 128)
        var error: MutableSpan<CChar> = errorStorage.mutableSpan

        let settings = TTorrentSessionSettings()
        let interfaceStorage = "utun4".utf8.map { CChar(bitPattern: $0) }
        let interface: Span<CChar> = interfaceStorage.span
        let settingsResult = TorrentClientApplySettings(
            nil,
            settings,
            interface,
            &error
        )

        #expect(settingsResult != 0)
    }

    // SAFETY: Ownership/lifetime: local output/error storage lives through every synchronous
    // null-client call; bounds/alignment: exact spans and aligned scalar inouts are supplied;
    // synchronization: all state is local; safe alternative: null-input mutation contracts
    // must be exercised directly at the C ABI boundary.
    @Test("Null client mutation APIs report contract errors")
    func nullClientMutationAPIsReportContractErrors() {
        var addOutcome = Int32.max
        var nativeToken = UInt64.max
        var addedIDStorage = Array<CChar>(repeating: 1, count: Int(TTORRENT_ID_CAPACITY))
        var errorStorage = Array<CChar>(repeating: 0, count: 1_024)
        var addedID: MutableSpan<CChar> = addedIDStorage.mutableSpan
        var error: MutableSpan<CChar> = errorStorage.mutableSpan
        let addResult = unsafe TorrentClientAddParsedMagnet(
            nil,
            TTorrentMagnetImport(),
            .init(),
            .init(),
            .init(),
            .init(),
            TTorrentAddOptions(),
            &addedID,
            &nativeToken,
            &addOutcome,
            &error
        )
        addedID = .init()
        error = .init()

        #expect(addResult == 1)
        #expect(bridgeString(errorStorage) == "Missing torrent client, native token, or add outcome output.")
        #expect(addOutcome == Int32(TTORRENT_ADD_REJECTED))
        #expect(nativeToken == 0)

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
            unsafe TorrentClientSaveResumeDataChecked(
                nil,
                0,
                UInt8(TTORRENT_RESUME_SAVE_ROUTINE),
                &errorBuffer,
                capacity
            )
        }

        expectBridgeError(
            code: 1,
            message: "Missing torrent client."
        ) { errorBuffer, capacity in
            unsafe TorrentClientRecoverPendingRemovalsChecked(
                nil,
                &errorBuffer,
                capacity
            )
        }

        TorrentClientDestroy(nil)
        TorrentClientDestroyBlocking(nil)
    }

    @Test("Creates, blocks, queries, recovers, and destroys an empty client")
    func createsBlocksQueriesRecoversAndDestroysEmptyClient() throws {
        try withTemporaryDirectory { stateDirectory in
            let result = emptyClientSmokeResult(statePath: stateDirectory.torrentFilePath)

            #expect(result.didCreate, Comment(rawValue: result.creationError))
            #expect(result.blockNetworkCode == 0, Comment(rawValue: result.blockNetworkError))
            #expect(result.copiedNetworkStatus == 1)
            #expect(result.networkBlocked)
            #expect(result.copiedHealth == 1)
            #expect(result.bridgeHealthIsHealthy)
            #expect(result.copiedSnapshots == 0)
            #expect(result.requiredSnapshotCount == 0)
            #expect(result.snapshotsAvailable)
            #expect(result.recoverPendingRemovalsCode == 0, Comment(rawValue: result.recoverPendingRemovalsError))
        }
    }
}

private struct BridgeErrorBuffer {
    private var storage = Array<CChar>(repeating: 0, count: 1_024)

    var string: String {
        let bytes = storage.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func writeSentinel() {
        storage = Array("sentinel".utf8CString)
        storage.append(contentsOf: Array(repeating: 0, count: 1_024 - storage.count))
    }

    mutating func withMutableBuffer<Result>(_ body: (inout [CChar]) -> Result) -> Result {
        body(&storage)
    }
}

// SAFETY: Ownership/lifetime: local error/path storage lives through synchronous creation and
// any returned client is uniquely destroyed; bounds/alignment: MutableSpan is exact and
// withCString provides NUL termination; synchronization: helper state is local;
// safe alternative: validating nullable C creation inputs requires the raw bridge API.
private func invalidCreateResult(path: String?) -> (didCreate: Bool, error: String) {
    var errorBuffer = BridgeErrorBuffer()
    let didCreate = errorBuffer.withMutableBuffer { buffer -> Bool in
        var error: MutableSpan<CChar> = buffer.mutableSpan
        defer { error = .init() }
        if let path {
            let client = path.withCString { statePath in
                unsafe TorrentClientCreateWithError(
                    statePath,
                    1,
                    contractPayloadBrokerCallbacks(),
                    contractSwarmMetainfoParserCallbacks(),
                    contractPeerProtocolParserCallbacks(),
                    contractTrackerResponseParserCallbacks(),
                    contractDHTMessageParserCallbacks(),
                    &error
                )
            }
            if let client = unsafe client {
                unsafe TorrentClientDestroyBlocking(client)
                return true
            }
            return false
        }
        let client = unsafe TorrentClientCreateWithError(
            nil,
            1,
            contractPayloadBrokerCallbacks(),
            contractSwarmMetainfoParserCallbacks(),
            contractPeerProtocolParserCallbacks(),
            contractTrackerResponseParserCallbacks(),
            contractDHTMessageParserCallbacks(),
            &error
        )
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
    var copiedHealth: Int32 = 0
    var bridgeHealthIsHealthy = false
    var copiedSnapshots: Int32 = -1
    var requiredSnapshotCount: Int32 = -1
    var snapshotsAvailable = false
    var recoverPendingRemovalsCode: Int32 = -1
    var recoverPendingRemovalsError = ""
}

// SAFETY: Ownership/lifetime: the path/error/output values live through synchronous calls and
// the uniquely owned client is deferred-destroyed; bounds/alignment: C strings are terminated,
// error capacities are exact, and null snapshot output advertises zero capacity;
// synchronization: one test thread owns the client; safe alternative: end-to-end ABI smoke
// coverage requires invoking the raw C bridge.
private func emptyClientSmokeResult(statePath: String) -> EmptyClientSmokeResult {
    var result = EmptyClientSmokeResult()
    var creationErrorBuffer = BridgeErrorBuffer()
    let maybeClient = unsafe creationErrorBuffer.withMutableBuffer { buffer in
        var error: MutableSpan<CChar> = buffer.mutableSpan
        defer { error = .init() }
        return statePath.withCString { statePathPointer in
            unsafe TorrentClientCreateWithError(
                statePathPointer,
                1,
                contractPayloadBrokerCallbacks(),
                contractSwarmMetainfoParserCallbacks(),
                contractPeerProtocolParserCallbacks(),
                contractTrackerResponseParserCallbacks(),
                contractDHTMessageParserCallbacks(),
                &error
            )
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

    let networkResult = unsafe TorrentClientCopyNetworkStatus(client)
    result.copiedNetworkStatus = networkResult.status
    result.networkBlocked = networkResult.network_status.network_blocked != 0

    let healthResult = unsafe TorrentClientCopyHealth(client)
    result.copiedHealth = healthResult.status
    result.bridgeHealthIsHealthy = healthResult.health.total_alert_worker_failures == 0
        && healthResult.health.consecutive_alert_worker_failures == 0
        && healthResult.health.alert_worker_degraded == 0

    var requiredCount: Int32 = -1
    var snapshotsAvailable: UInt8 = 0
    result.copiedSnapshots = unsafe TorrentClientCopySnapshotBatch(
        client,
        nil,
        0,
        &requiredCount,
        &snapshotsAvailable
    )
    result.requiredSnapshotCount = requiredCount
    result.snapshotsAvailable = snapshotsAvailable != 0

    var recoveryErrorBuffer = BridgeErrorBuffer()
    result.recoverPendingRemovalsCode = recoveryErrorBuffer.withMutableBuffer { buffer in
        unsafe TorrentClientRecoverPendingRemovalsChecked(
            client,
            &buffer,
            Int32(buffer.count)
        )
    }
    result.recoverPendingRemovalsError = recoveryErrorBuffer.string

    return result
}
