import Darwin
import TorrentBridge

private let swarmMetainfoContext = TorrentSwarmMetainfoParserBridgeContext()
private let peerProtocolContext = TorrentPeerProtocolBridgeContext()
private let trackerResponseContext = TorrentTrackerResponseBridgeContext()
private let dhtMessageContext = TorrentDHTMessageBridgeContext()

@_cdecl("TorrentParserFuzzMakeSwarmMetainfoCallbacks")
public func torrentParserFuzzMakeSwarmMetainfoCallbacks(
    _ output: UnsafeMutablePointer<TTorrentSwarmMetainfoParserCallbacks>?
) -> Int32 {
    // SAFETY: Ownership/lifetime: globals outlive the fuzz process, native retains through the
    // installed callbacks, and output is caller-owned for this synchronous call; bounds/alignment:
    // output points to one aligned imported table; synchronization: contexts are immutable and
    // callbacks thread-safe; safe alternative: libFuzzer's C harness requires a C callback table.
    guard let output = unsafe output else {
        return EINVAL
    }
    var callbacks = unsafe TTorrentSwarmMetainfoParserCallbacks()
    unsafe callbacks.context = Unmanaged.passUnretained(swarmMetainfoContext).toOpaque()
    unsafe callbacks.retain_context = torrentSwarmMetainfoContextRetainCallback
    unsafe callbacks.release_context = torrentSwarmMetainfoContextReleaseCallback
    unsafe callbacks.parse_info = torrentSwarmMetainfoParseCallback
    unsafe callbacks.release_capsule = torrentSwarmMetainfoCapsuleReleaseCallback
    unsafe output.pointee = callbacks
    return 0
}

@_cdecl("TorrentParserFuzzMakePeerProtocolCallbacks")
public func torrentParserFuzzMakePeerProtocolCallbacks(
    _ output: UnsafeMutablePointer<TTorrentPeerProtocolParserCallbacks>?
) -> Int32 {
    // SAFETY: Ownership/lifetime: globals outlive the fuzz process, native retains through the
    // installed callbacks, and output is caller-owned for this synchronous call; bounds/alignment:
    // output points to one aligned imported table; synchronization: contexts are immutable and
    // callbacks thread-safe; safe alternative: libFuzzer's C harness requires a C callback table.
    guard let output = unsafe output else {
        return EINVAL
    }
    var callbacks = unsafe TTorrentPeerProtocolParserCallbacks()
    unsafe callbacks.context = Unmanaged.passUnretained(peerProtocolContext).toOpaque()
    unsafe callbacks.retain_context = torrentPeerProtocolContextRetainCallback
    unsafe callbacks.release_context = torrentPeerProtocolContextReleaseCallback
    unsafe callbacks.parse_extension_handshake = torrentExtensionHandshakeParseCallback
    unsafe callbacks.parse_metadata_message = torrentMetadataMessageParseCallback
    unsafe callbacks.parse_peer_exchange = torrentPeerExchangeParseCallback
    unsafe output.pointee = callbacks
    return 0
}

@_cdecl("TorrentParserFuzzMakeTrackerResponseCallbacks")
public func torrentParserFuzzMakeTrackerResponseCallbacks(
    _ output: UnsafeMutablePointer<TTorrentTrackerResponseParserCallbacks>?
) -> Int32 {
    // SAFETY: Ownership/lifetime: globals outlive the fuzz process, native retains through the
    // installed callbacks, and output is caller-owned for this synchronous call; bounds/alignment:
    // output points to one aligned imported table; synchronization: contexts are immutable and
    // callbacks thread-safe; safe alternative: libFuzzer's C harness requires a C callback table.
    guard let output = unsafe output else {
        return EINVAL
    }
    var callbacks = unsafe TTorrentTrackerResponseParserCallbacks()
    unsafe callbacks.context = Unmanaged.passUnretained(trackerResponseContext).toOpaque()
    unsafe callbacks.retain_context = torrentTrackerParserContextRetainCallback
    unsafe callbacks.release_context = torrentTrackerParserContextReleaseCallback
    unsafe callbacks.parse_http_response = torrentHTTPTrackerResponseParseCallback
    unsafe output.pointee = callbacks
    return 0
}

@_cdecl("TorrentParserFuzzMakeDHTMessageCallbacks")
public func torrentParserFuzzMakeDHTMessageCallbacks(
    _ output: UnsafeMutablePointer<TTorrentDHTMessageParserCallbacks>?
) -> Int32 {
    // SAFETY: Ownership/lifetime: globals outlive the fuzz process, native retains through the
    // installed callbacks, and output is caller-owned for this synchronous call; bounds/alignment:
    // output points to one aligned imported table; synchronization: contexts are immutable and
    // callbacks thread-safe; safe alternative: libFuzzer's C harness requires a C callback table.
    guard let output = unsafe output else {
        return EINVAL
    }
    var callbacks = unsafe TTorrentDHTMessageParserCallbacks()
    unsafe callbacks.context = Unmanaged.passUnretained(dhtMessageContext).toOpaque()
    unsafe callbacks.retain_context = torrentDHTParserContextRetainCallback
    unsafe callbacks.release_context = torrentDHTParserContextReleaseCallback
    unsafe callbacks.parse_message = torrentDHTMessageParseCallback
    unsafe output.pointee = callbacks
    return 0
}
