import Darwin
import Foundation
package import TorrentBridge
import TorrentMetainfo

/// Lifetime anchor for synchronous KRPC parsing on libtorrent's network
/// thread. Parsing is stateless and never suspends or reenters native bridge
/// operations.
@safe package final class TorrentDHTMessageBridgeContext: Sendable {
    package init() {}
}

// SAFETY: Ownership/lifetime: the pointer was produced by Unmanaged.passRetained
// and this callback adds the native owner's requested retain; bounds/alignment: it
// addresses that exact class instance and no bytes are indexed; synchronization:
// ARC retain is thread-safe; safe alternative: a C callback context cannot carry a
// managed Swift reference.
package func torrentDHTParserContextRetainCallback(
    _ context: UnsafeMutableRawPointer?
) -> UInt8 {
    guard let context = unsafe context else {
        return 0
    }
    _ = unsafe Unmanaged<TorrentDHTMessageBridgeContext>
        .fromOpaque(context)
        .retain()
    return 1
}

// SAFETY: Ownership/lifetime: native calls this once for a retain previously accepted
// by the paired callback; bounds/alignment: the opaque pointer still addresses the exact
// class instance and no bytes are indexed; synchronization: ARC release is thread-safe;
// safe alternative: a C callback context cannot carry a managed Swift reference.
package func torrentDHTParserContextReleaseCallback(
    _ context: UnsafeMutableRawPointer?
) {
    guard let context = unsafe context else {
        return
    }
    unsafe Unmanaged<TorrentDHTMessageBridgeContext>
        .fromOpaque(context)
        .release()
}

// SAFETY: Ownership/lifetime: C++ retains the context and owns all input/output storage
// for this nonescaping synchronous callback; bounds/alignment: the bridge ABI supplies
// correctly typed pointers, bodySize and both capacities are validated before copying,
// and output writes never exceed them; synchronization: parsing uses only local state and
// supports concurrent callbacks; safe alternative: the C function-pointer ABI cannot
// express Swift lifetimes or bounded buffers.
package func torrentDHTMessageParseCallback(
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
    guard unsafe context != nil,
          bodySize > 0,
          bodySize <= Int32(TTORRENT_MAX_DHT_MESSAGE_BYTES),
          nodeCapacity >= 0,
          nodeCapacity <= Int32(TTORRENT_MAX_DHT_MESSAGE_NODES),
          peerCapacity >= 0,
          peerCapacity <= Int32(TTORRENT_MAX_DHT_MESSAGE_PEERS),
          let sourceFamily = TorrentPeerAddressFamily(
              rawValue: sourceAddressFamily
          ) else {
        return EINVAL
    }

    do {
        let input = unsafe Data(bytes: body, count: Int(bodySize))
        let parsed = try TorrentDHTMessageParser().parse(
            input,
            sourceFamily: sourceFamily
        )
        guard parsed.body == input,
              parsed.nodes.count <= Int(nodeCapacity),
              parsed.peers.count <= Int(peerCapacity),
              parsed.sampleCount <= Int(TTORRENT_MAX_DHT_MESSAGE_SAMPLES),
              let nodeCount = Int32(exactly: parsed.nodes.count),
              let peerCount = Int32(exactly: parsed.peers.count),
              let sampleCount = Int32(exactly: parsed.sampleCount) else {
            return EOVERFLOW
        }

        var nodeRecords = [TTorrentDHTNodeRecord]()
        nodeRecords.reserveCapacity(parsed.nodes.count)
        for node in parsed.nodes {
            guard node.idRange.count == 20,
                  let idOffset = Int32(exactly: node.idRange.lowerBound) else {
                return EINVAL
            }
            var record = TTorrentDHTNodeRecord()
            record.address_high = node.address.high
            record.address_low = node.address.low
            record.id_offset = idOffset
            record.port = node.port
            record.address_family = node.address.family.rawValue
            nodeRecords.append(record)
        }

        var peerRecords = [TTorrentDHTPeerRecord]()
        peerRecords.reserveCapacity(parsed.peers.count)
        for peer in parsed.peers {
            var record = TTorrentDHTPeerRecord()
            record.address_high = peer.address.high
            record.address_low = peer.address.low
            record.port = peer.port
            record.address_family = peer.address.family.rawValue
            peerRecords.append(record)
        }

        var output = TTorrentDHTMessageResult()
        output.message_kind = parsed.kind.rawValue
        output.query_kind = parsed.queryKind.rawValue
        output.query_is_valid = parsed.queryIsValid ? 1 : 0
        output.node_count = nodeCount
        output.peer_count = peerCount
        output.sample_count = sampleCount

        if let range = parsed.transactionRange {
            guard let offset = Int32(exactly: range.lowerBound),
                  let size = Int32(exactly: range.count) else {
                return EOVERFLOW
            }
            output.present_fields |= UInt32(TTORRENT_DHT_HAS_TRANSACTION)
            output.transaction_offset = offset
            output.transaction_size = size
        }
        if let range = parsed.queryNameRange {
            guard let offset = Int32(exactly: range.lowerBound),
                  let size = Int32(exactly: range.count) else {
                return EOVERFLOW
            }
            output.present_fields |= UInt32(TTORRENT_DHT_HAS_QUERY_NAME)
            output.query_name_offset = offset
            output.query_name_size = size
        }
        if let range = parsed.nodeIDRange {
            guard range.count == 20,
                  let offset = Int32(exactly: range.lowerBound) else {
                return EINVAL
            }
            output.present_fields |= UInt32(TTORRENT_DHT_HAS_SENDER_ID)
            output.sender_id_offset = offset
        }
        if let range = parsed.targetRange {
            guard range.count == 20,
                  let offset = Int32(exactly: range.lowerBound) else {
                return EINVAL
            }
            output.present_fields |= UInt32(TTORRENT_DHT_HAS_TARGET)
            output.target_offset = offset
        }
        if let range = parsed.tokenRange {
            guard let offset = Int32(exactly: range.lowerBound),
                  let size = Int32(exactly: range.count) else {
                return EOVERFLOW
            }
            output.present_fields |= UInt32(TTORRENT_DHT_HAS_TOKEN)
            output.token_offset = offset
            output.token_size = size
        }
        if let range = parsed.nameRange {
            guard let offset = Int32(exactly: range.lowerBound),
                  let size = Int32(exactly: range.count) else {
                return EOVERFLOW
            }
            output.present_fields |= UInt32(TTORRENT_DHT_HAS_NAME)
            output.name_offset = offset
            output.name_size = size
        }
        if let code = parsed.errorCode {
            output.present_fields |= UInt32(TTORRENT_DHT_HAS_ERROR_CODE)
            output.error_code = code
        }
        if let range = parsed.errorMessageRange {
            guard let offset = Int32(exactly: range.lowerBound),
                  let size = Int32(exactly: range.count) else {
                return EOVERFLOW
            }
            output.present_fields |= UInt32(TTORRENT_DHT_HAS_ERROR_MESSAGE)
            output.error_message_offset = offset
            output.error_message_size = size
        }
        if let address = parsed.externalAddress {
            output.present_fields |= UInt32(TTORRENT_DHT_HAS_EXTERNAL_ADDRESS)
            output.external_address_high = address.high
            output.external_address_low = address.low
            output.external_address_family = address.family.rawValue
        }
        if let port = parsed.port {
            output.present_fields |= UInt32(TTORRENT_DHT_HAS_PORT)
            output.port = port
        }
        if let interval = parsed.interval {
            output.present_fields |= UInt32(TTORRENT_DHT_HAS_INTERVAL)
            output.interval = interval
        }
        if let count = parsed.totalInfoHashCount {
            output.present_fields |= UInt32(TTORRENT_DHT_HAS_INFOHASH_COUNT)
            output.total_infohash_count = count
        }
        if parsed.peersPresent {
            output.present_fields |= UInt32(TTORRENT_DHT_HAS_PEERS)
        }
        if let range = parsed.sampleHashesRange {
            guard range.count == parsed.sampleCount * 20,
                  let offset = Int32(exactly: range.lowerBound) else {
                return EINVAL
            }
            output.present_fields |= UInt32(TTORRENT_DHT_HAS_SAMPLES)
            output.sample_hashes_offset = offset
        }

        if parsed.readOnly {
            output.flags |= UInt32(TTORRENT_DHT_FLAG_READ_ONLY)
        }
        if parsed.noseed {
            output.flags |= UInt32(TTORRENT_DHT_FLAG_NOSEED)
        }
        if parsed.scrape {
            output.flags |= UInt32(TTORRENT_DHT_FLAG_SCRAPE)
        }
        if parsed.seed {
            output.flags |= UInt32(TTORRENT_DHT_FLAG_SEED)
        }
        if parsed.impliedPort {
            output.flags |= UInt32(TTORRENT_DHT_FLAG_IMPLIED_PORT)
        }
        if parsed.wantsSpecified {
            output.flags |= UInt32(TTORRENT_DHT_FLAG_WANT_SPECIFIED)
        }
        if parsed.wantsIPv4 {
            output.flags |= UInt32(TTORRENT_DHT_FLAG_WANT_IPV4)
        }
        if parsed.wantsIPv6 {
            output.flags |= UInt32(TTORRENT_DHT_FLAG_WANT_IPV6)
        }

        nodeRecords.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else {
                return
            }
            unsafe nodesOut.update(from: baseAddress, count: source.count)
        }
        peerRecords.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else {
                return
            }
            unsafe peersOut.update(from: baseAddress, count: source.count)
        }
        unsafe resultOut.pointee = output
        return 0
    } catch {
        return EINVAL
    }
}
