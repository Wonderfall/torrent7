import Darwin
import Foundation
package import TorrentBridge
import TorrentMetainfo

/// Lifetime anchor for the synchronous peer-message parser installed into
/// libtorrent. Parsing is stateless, actor-free, and never suspends or reenters
/// the bridge.
@safe package final class TorrentPeerProtocolBridgeContext: Sendable {
    package init() {}
}

// SAFETY: Ownership/lifetime: the pointer came from Unmanaged.passRetained and this
// callback adds the native owner's requested retain; bounds/alignment: it addresses
// the exact class instance with no indexed bytes; synchronization: ARC retain is
// thread-safe; safe alternative: a C callback context cannot carry a Swift reference.
package func torrentPeerProtocolContextRetainCallback(
    _ context: UnsafeMutableRawPointer?
) -> UInt8 {
    guard let context = unsafe context else {
        return 0
    }
    _ = unsafe Unmanaged<TorrentPeerProtocolBridgeContext>
        .fromOpaque(context)
        .retain()
    return 1
}

// SAFETY: Ownership/lifetime: native releases exactly one retain previously accepted
// by the paired callback; bounds/alignment: the opaque pointer still addresses the exact
// class instance with no indexed bytes; synchronization: ARC release is thread-safe;
// safe alternative: a C callback context cannot carry a Swift reference.
package func torrentPeerProtocolContextReleaseCallback(
    _ context: UnsafeMutableRawPointer?
) {
    guard let context = unsafe context else {
        return
    }
    unsafe Unmanaged<TorrentPeerProtocolBridgeContext>
        .fromOpaque(context)
        .release()
}

// SAFETY: Ownership/lifetime: C++ retains the context and owns all buffers for this
// nonescaping synchronous callback; bounds/alignment: the ABI supplies typed pointers,
// messageSize and versionCapacity are validated before access, and writes remain bounded;
// synchronization: parsing is local and concurrent calls do not share state; safe alternative:
// the C callback ABI cannot encode Swift ownership or bounded buffer types.
package func torrentExtensionHandshakeParseCallback(
    _ context: UnsafeMutableRawPointer?,
    _ message: UnsafePointer<CChar>,
    _ messageSize: Int32,
    _ clientVersionOut: UnsafeMutablePointer<UInt8>,
    _ clientVersionCapacity: Int32,
    _ resultOut: UnsafeMutablePointer<TTorrentExtensionHandshakeResult>
) -> Int32 {
    unsafe resultOut.pointee = emptyHandshakeResult()
    guard unsafe context != nil,
          messageSize > 0,
          messageSize <= Int32(TTORRENT_MAX_EXTENSION_HANDSHAKE_BYTES),
          clientVersionCapacity >= Int32(TTORRENT_MAX_PEER_CLIENT_VERSION_BYTES) else {
        return EINVAL
    }

    do {
        let input = unsafe Data(bytes: message, count: Int(messageSize))
        let parsed = try TorrentPeerProtocolParser().parseExtensionHandshake(input)
        var output = emptyHandshakeResult()
        output.ut_metadata_id = parsed.utMetadataID.map(Int32.init) ?? -1
        output.ut_pex_id = parsed.utPEXID.map(Int32.init) ?? -1
        output.upload_only_id = parsed.uploadOnlyID.map(Int32.init) ?? -1
        output.holepunch_id = parsed.holepunchID.map(Int32.init) ?? -1
        output.dont_have_id = parsed.dontHaveID.map(Int32.init) ?? -1

        if let metadataSize = parsed.metadataSize {
            output.present_fields |= UInt32(TTORRENT_HANDSHAKE_HAS_METADATA_SIZE)
            output.metadata_size = metadataSize
        }
        if let listenPort = parsed.listenPort {
            output.present_fields |= UInt32(TTORRENT_HANDSHAKE_HAS_LISTEN_PORT)
            output.listen_port = Int32(listenPort)
        }
        if let lastSeenComplete = parsed.lastSeenComplete {
            output.present_fields |= UInt32(TTORRENT_HANDSHAKE_HAS_LAST_SEEN_COMPLETE)
            output.last_seen_complete = lastSeenComplete
        }
        if let requestQueueLimit = parsed.requestQueueLimit {
            output.present_fields |= UInt32(TTORRENT_HANDSHAKE_HAS_REQUEST_QUEUE)
            output.request_queue_limit = Int32(requestQueueLimit)
        }
        if let clientVersion = parsed.clientVersionUTF8 {
            guard clientVersion.count <= Int(clientVersionCapacity),
                  let compactSize = Int32(exactly: clientVersion.count) else {
                return EOVERFLOW
            }
            let copiedClientVersion = unsafe clientVersion.withUnsafeBytes { source in
                guard let sourceAddress = unsafe source.bindMemory(to: UInt8.self).baseAddress else {
                    return false
                }
                unsafe clientVersionOut.update(
                    from: sourceAddress,
                    count: source.count
                )
                return true
            }
            guard copiedClientVersion else {
                return EINVAL
            }
            output.present_fields |= UInt32(TTORRENT_HANDSHAKE_HAS_CLIENT_VERSION)
            output.client_version_size = compactSize
        }
        if let address = parsed.externalAddress {
            output.present_fields |= UInt32(TTORRENT_HANDSHAKE_HAS_EXTERNAL_ADDRESS)
            output.address_high = address.high
            output.address_low = address.low
            output.address_family = address.family.rawValue
        }
        if let uploadOnly = parsed.uploadOnly {
            output.present_fields |= UInt32(TTORRENT_HANDSHAKE_HAS_UPLOAD_ONLY)
            output.upload_only = uploadOnly ? 1 : 0
        }
        unsafe resultOut.pointee = output
        return 0
    } catch {
        return EINVAL
    }
}

// SAFETY: Ownership/lifetime: C++ retains the context and owns input/output storage for
// this synchronous callback; bounds/alignment: the ABI supplies typed pointers and the
// message byte count is validated before its exact copy; synchronization: parsing uses
// only local state; safe alternative: the C callback ABI cannot express Swift ownership.
package func torrentMetadataMessageParseCallback(
    _ context: UnsafeMutableRawPointer?,
    _ message: UnsafePointer<CChar>,
    _ messageSize: Int32,
    _ resultOut: UnsafeMutablePointer<TTorrentMetadataMessageResult>
) -> Int32 {
    unsafe resultOut.pointee = TTorrentMetadataMessageResult()
    guard unsafe context != nil,
          messageSize > 0,
          messageSize <= Int32(TTORRENT_MAX_METADATA_MESSAGE_BYTES) else {
        return EINVAL
    }
    do {
        let input = unsafe Data(bytes: message, count: Int(messageSize))
        let parsed = try TorrentPeerProtocolParser().parseMetadataControlMessage(input)
        var output = TTorrentMetadataMessageResult()
        output.raw_message_type = parsed.rawMessageType
        output.piece = parsed.piece
        output.payload_offset = parsed.payloadOffset
        output.payload_size = parsed.payloadSize
        output.kind = parsed.kind.rawValue
        if let totalSize = parsed.totalSize {
            output.has_total_size = 1
            output.total_size = totalSize
        }
        unsafe resultOut.pointee = output
        return 0
    } catch {
        return EINVAL
    }
}

// SAFETY: Ownership/lifetime: C++ retains the context and owns all buffers for this
// nonescaping synchronous callback; bounds/alignment: the ABI supplies typed pointers,
// messageSize and recordCapacity are validated, and writes stay within that capacity;
// synchronization: parsing is local and supports concurrent calls; safe alternative:
// the C callback ABI cannot encode Swift ownership or bounded buffer types.
package func torrentPeerExchangeParseCallback(
    _ context: UnsafeMutableRawPointer?,
    _ message: UnsafePointer<CChar>,
    _ messageSize: Int32,
    _ recordsOut: UnsafeMutablePointer<TTorrentPeerExchangeRecord>,
    _ recordCapacity: Int32,
    _ resultOut: UnsafeMutablePointer<TTorrentPeerExchangeResult>
) -> Int32 {
    unsafe resultOut.pointee = TTorrentPeerExchangeResult()
    guard unsafe context != nil,
          messageSize > 0,
          messageSize <= Int32(TTORRENT_MAX_PEX_MESSAGE_BYTES),
          recordCapacity >= Int32(TTORRENT_MAX_PEX_MESSAGE_CONTACTS) else {
        return EINVAL
    }
    do {
        let input = unsafe Data(bytes: message, count: Int(messageSize))
        let parsed = try TorrentPeerProtocolParser().parsePeerExchange(input)
        guard parsed.contacts.count <= Int(recordCapacity),
              let recordCount = Int32(exactly: parsed.contacts.count),
              let addedCount = Int32(exactly: parsed.addedCount),
              let droppedCount = Int32(exactly: parsed.droppedCount) else {
            return EOVERFLOW
        }

        var records = [TTorrentPeerExchangeRecord]()
        records.reserveCapacity(parsed.contacts.count)
        for contact in parsed.contacts {
            var record = TTorrentPeerExchangeRecord()
            record.address_high = contact.address.high
            record.address_low = contact.address.low
            record.port = contact.port
            record.address_family = contact.address.family.rawValue
            record.action = contact.action.rawValue
            record.flags = contact.flags
            records.append(record)
        }
        records.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else {
                return
            }
            unsafe recordsOut.update(from: baseAddress, count: source.count)
        }
        var output = TTorrentPeerExchangeResult()
        output.record_count = recordCount
        output.added_count = addedCount
        output.dropped_count = droppedCount
        unsafe resultOut.pointee = output
        return 0
    } catch {
        return EINVAL
    }
}

private func emptyHandshakeResult() -> TTorrentExtensionHandshakeResult {
    var result = TTorrentExtensionHandshakeResult()
    result.ut_metadata_id = -1
    result.ut_pex_id = -1
    result.upload_only_id = -1
    result.holepunch_id = -1
    result.dont_have_id = -1
    return result
}
