import Darwin
import Foundation
import TorrentBridge
import TorrentMetainfo

/// Lifetime anchor for synchronous tracker-body parsing on libtorrent's
/// network thread. Parsing is stateless and never suspends or reenters native
/// bridge operations.
@safe package final class TorrentTrackerResponseBridgeContext: Sendable {
    package init() {}
}

// SAFETY: Ownership/lifetime: the pointer came from Unmanaged.passRetained and this
// callback adds the native owner's requested retain; bounds/alignment: it addresses
// the exact class instance with no indexed bytes; synchronization: ARC retain is
// thread-safe; safe alternative: a C callback context cannot carry a Swift reference.
package func torrentTrackerParserContextRetainCallback(
    _ context: UnsafeMutableRawPointer?
) -> UInt8 {
    guard let context = unsafe context else {
        return 0
    }
    _ = unsafe Unmanaged<TorrentTrackerResponseBridgeContext>
        .fromOpaque(context)
        .retain()
    return 1
}

// SAFETY: Ownership/lifetime: native releases exactly one retain previously accepted
// by the paired callback; bounds/alignment: the opaque pointer still addresses the exact
// class instance with no indexed bytes; synchronization: ARC release is thread-safe;
// safe alternative: a C callback context cannot carry a Swift reference.
package func torrentTrackerParserContextReleaseCallback(
    _ context: UnsafeMutableRawPointer?
) {
    guard let context = unsafe context else {
        return
    }
    unsafe Unmanaged<TorrentTrackerResponseBridgeContext>
        .fromOpaque(context)
        .release()
}

// SAFETY: Ownership/lifetime: C++ retains the context and owns all buffers for this
// nonescaping synchronous callback; bounds/alignment: the ABI supplies correctly typed
// pointers, body/hash sizes and peer capacity are validated before copying, and writes
// remain within capacity; synchronization: parsing is local and supports concurrent calls;
// safe alternative: the C function-pointer ABI cannot express Swift lifetimes or spans.
package func torrentHTTPTrackerResponseParseCallback(
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
    guard unsafe context != nil,
          bodySize > 0,
          bodySize <= Int32(TTORRENT_MAX_HTTP_TRACKER_RESPONSE_BYTES),
          isScrape <= 1,
          peerCapacity >= 0,
          peerCapacity <= Int32(TTORRENT_MAX_TRACKER_RESPONSE_PEERS) else {
        return EINVAL
    }

    let expectedHash: Data?
    if isScrape != 0 {
        guard scrapeInfoHashSize == 20,
              let scrapeInfoHash = unsafe scrapeInfoHash else {
            return EINVAL
        }
        expectedHash = unsafe Data(bytes: scrapeInfoHash, count: 20)
    } else {
        guard unsafe scrapeInfoHash == nil,
              scrapeInfoHashSize == 0 else {
            return EINVAL
        }
        expectedHash = nil
    }

    do {
        let input = unsafe Data(bytes: body, count: Int(bodySize))
        let parsed = try TorrentHTTPTrackerResponseParser().parse(
            input,
            scrapeInfoHash: expectedHash
        )
        guard parsed.body == input,
              parsed.peers.count <= Int(peerCapacity),
              let peerCount = Int32(exactly: parsed.peers.count) else {
            return EOVERFLOW
        }

        var records = [TTorrentTrackerPeerRecord]()
        records.reserveCapacity(parsed.peers.count)
        for peer in parsed.peers {
            var record = TTorrentTrackerPeerRecord()
            record.port = peer.port
            record.kind = peer.kind.rawValue
            switch peer.kind {
            case .hostname:
                guard peer.address == nil,
                      let hostname = peer.hostnameRange,
                      let hostnameOffset = Int32(exactly: hostname.lowerBound),
                      let hostnameSize = Int32(exactly: hostname.count) else {
                    return EINVAL
                }
                record.hostname_offset = hostnameOffset
                record.hostname_size = hostnameSize
                if let peerID = peer.peerIDRange {
                    guard peerID.count == 20,
                          let peerIDOffset = Int32(exactly: peerID.lowerBound) else {
                        return EINVAL
                    }
                    record.has_peer_id = 1
                    record.peer_id_offset = peerIDOffset
                }
            case .ipv4, .ipv6:
                guard peer.hostnameRange == nil,
                      peer.peerIDRange == nil,
                      let address = peer.address,
                      address.family.rawValue == peer.kind.rawValue else {
                    return EINVAL
                }
                record.address_high = address.high
                record.address_low = address.low
            }
            records.append(record)
        }

        var output = TTorrentHTTPTrackerResponseResult()
        output.interval = parsed.interval
        output.minimum_interval = parsed.minimumInterval
        output.complete = parsed.complete
        output.incomplete = parsed.incomplete
        output.downloaded = parsed.downloaded
        output.downloaders = parsed.downloaders
        output.peer_count = peerCount

        if let range = parsed.trackerIDRange {
            guard let offset = Int32(exactly: range.lowerBound),
                  let size = Int32(exactly: range.count) else {
                return EOVERFLOW
            }
            output.present_fields |= UInt32(TTORRENT_TRACKER_HAS_ID)
            output.tracker_id_offset = offset
            output.tracker_id_size = size
        }
        if let range = parsed.failureReasonRange {
            guard let offset = Int32(exactly: range.lowerBound),
                  let size = Int32(exactly: range.count) else {
                return EOVERFLOW
            }
            output.present_fields |= UInt32(TTORRENT_TRACKER_HAS_FAILURE_REASON)
            output.failure_reason_offset = offset
            output.failure_reason_size = size
        }
        if let range = parsed.warningMessageRange {
            guard let offset = Int32(exactly: range.lowerBound),
                  let size = Int32(exactly: range.count) else {
                return EOVERFLOW
            }
            output.present_fields |= UInt32(TTORRENT_TRACKER_HAS_WARNING_MESSAGE)
            output.warning_message_offset = offset
            output.warning_message_size = size
        }
        if let address = parsed.externalAddress {
            output.present_fields |= UInt32(TTORRENT_TRACKER_HAS_EXTERNAL_ADDRESS)
            output.address_high = address.high
            output.address_low = address.low
            output.address_family = address.family.rawValue
        }

        unsafe records.withUnsafeBufferPointer { source in
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
