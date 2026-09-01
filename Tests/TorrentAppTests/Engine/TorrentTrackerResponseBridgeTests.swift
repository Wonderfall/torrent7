import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
import TorrentBridge
@testable import TorrentEngineCore

@Suite("Swift HTTP tracker response callback")
struct TorrentTrackerResponseBridgeTests {
    // SAFETY: Ownership/lifetime: retained context, body, and output array live through the
    // synchronous callback; bounds/alignment: nonempty bytes bind between alignment-1 types
    // and exact record capacity is supplied; synchronization: locals are unshared;
    // safe alternative: caller-owned output must be tested through the C callback ABI.
    @Test("Announce callback emits bounded caller-owned typed records")
    func importsAnnounceResponse() {
        let hostnamePeer = bencodedDictionary([
            ("ip", bencodedString(Data("peer.example".utf8))),
            ("peer id", bencodedString(Data("abcdefghijklmnopqrst".utf8))),
            ("port", bencodedInteger(6_881)),
        ])
        let ipv6 = Data([
            0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 1,
            0x1a, 0xe2,
        ])
        let body = bencodedDictionary([
            ("complete", bencodedInteger(9)),
            ("external ip", bencodedString(Data([203, 0, 113, 8]))),
            ("incomplete", bencodedInteger(3)),
            ("interval", bencodedInteger(1_200)),
            ("peers", bencodedList([hostnamePeer])),
            ("peers6", bencodedString(ipv6)),
            ("tracker id", bencodedString(Data("token".utf8))),
            ("warning message", bencodedString(Data("warning".utf8))),
        ])

        unsafe withTrackerResponseContext { context in
            var records = [TTorrentTrackerPeerRecord](
                repeating: TTorrentTrackerPeerRecord(),
                count: 4
            )
            var result = TTorrentHTTPTrackerResponseResult()
            let status = unsafe body.withUnsafeBytes { rawBody in
                unsafe records.withUnsafeMutableBufferPointer { recordBuffer in
                    unsafe torrentHTTPTrackerResponseParseCallback(
                        context,
                        rawBody.bindMemory(to: CChar.self).baseAddress!,
                        Int32(rawBody.count),
                        0,
                        nil,
                        0,
                        recordBuffer.baseAddress!,
                        Int32(recordBuffer.count),
                        &result
                    )
                }
            }

            #expect(status == 0)
            #expect(result.interval == 1_200)
            #expect(result.minimum_interval == 30)
            #expect(result.complete == 9)
            #expect(result.incomplete == 3)
            #expect(result.downloaded == -1)
            #expect(result.downloaders == -1)
            #expect(result.peer_count == 2)
            #expect(result.address_family == UInt8(TTORRENT_PEER_ADDRESS_IPV4))
            #expect(result.address_low == 0xcb00_7108)
            #expect(result.present_fields == UInt32(
                TTORRENT_TRACKER_HAS_ID
                    | TTORRENT_TRACKER_HAS_WARNING_MESSAGE
                    | TTORRENT_TRACKER_HAS_EXTERNAL_ADDRESS
            ))
            #expect(bodySlice(
                body,
                offset: result.tracker_id_offset,
                size: result.tracker_id_size
            ) == Data("token".utf8))
            #expect(bodySlice(
                body,
                offset: result.warning_message_offset,
                size: result.warning_message_size
            ) == Data("warning".utf8))

            #expect(records[0].kind == UInt8(TTORRENT_TRACKER_PEER_HOSTNAME))
            #expect(records[0].port == 6_881)
            #expect(records[0].has_peer_id == 1)
            #expect(bodySlice(
                body,
                offset: records[0].hostname_offset,
                size: records[0].hostname_size
            ) == Data("peer.example".utf8))
            #expect(bodySlice(
                body,
                offset: records[0].peer_id_offset,
                size: 20
            ) == Data("abcdefghijklmnopqrst".utf8))
            #expect(records[1].kind == UInt8(TTORRENT_PEER_ADDRESS_IPV6))
            #expect(records[1].address_high == 0x2001_0db8_0000_0000)
            #expect(records[1].address_low == 1)
            #expect(records[1].port == 6_882)
        }
    }

    // SAFETY: Ownership/lifetime: retained context, body/hash Data, and outputs live through the
    // synchronous callback; bounds/alignment: both nonempty byte buffers have alignment 1 and
    // exact counts (including the 20-byte hash) are supplied; synchronization: locals are
    // unshared; safe alternative: binary scrape selection is a raw C callback contract.
    @Test("Scrape callback selects the exact binary info-hash")
    func importsScrapeResponse() {
        let infoHash = Data(0..<20)
        let statistics = bencodedDictionary([
            ("complete", bencodedInteger(11)),
            ("downloaded", bencodedInteger(23)),
            ("downloaders", bencodedInteger(4)),
            ("incomplete", bencodedInteger(7)),
        ])
        let body = bencodedDictionary([
            ("files", bencodedByteKeyedDictionary([(infoHash, statistics)])),
        ])

        unsafe withTrackerResponseContext { context in
            var peerSentinel = TTorrentTrackerPeerRecord()
            peerSentinel.address_low = 0xfeed_face
            var result = TTorrentHTTPTrackerResponseResult()
            let status = unsafe body.withUnsafeBytes { rawBody in
                unsafe infoHash.withUnsafeBytes { rawHash in
                    unsafe torrentHTTPTrackerResponseParseCallback(
                        context,
                        rawBody.bindMemory(to: CChar.self).baseAddress!,
                        Int32(rawBody.count),
                        1,
                        rawHash.bindMemory(to: UInt8.self).baseAddress!,
                        Int32(rawHash.count),
                        &peerSentinel,
                        1,
                        &result
                    )
                }
            }

            #expect(status == 0)
            #expect(result.complete == 11)
            #expect(result.incomplete == 7)
            #expect(result.downloaded == 23)
            #expect(result.downloaders == 4)
            #expect(result.peer_count == 0)
            #expect(peerSentinel.address_low == 0xfeed_face)
        }
    }

    // SAFETY: Ownership/lifetime: retained context, body, and outputs live through the
    // synchronous callback; bounds/alignment: nonempty body bytes bind at alignment 1 and zero
    // declared capacity prevents record writes; synchronization: locals are unshared;
    // safe alternative: capacity rejection must exercise the raw C callback.
    @Test("Capacity failure leaves caller records untouched and result empty")
    func rejectsInsufficientCapacityAtomically() {
        let body = bencodedDictionary([
            ("peers", bencodedString(Data([203, 0, 113, 8, 0x1a, 0xe1]))),
        ])

        unsafe withTrackerResponseContext { context in
            var sentinel = TTorrentTrackerPeerRecord()
            sentinel.address_low = 0xfeed_face
            var result = TTorrentHTTPTrackerResponseResult(
                address_high: 9,
                address_low: 9,
                interval: 9,
                minimum_interval: 9,
                complete: 9,
                incomplete: 9,
                downloaded: 9,
                downloaders: 9,
                tracker_id_offset: 9,
                tracker_id_size: 9,
                failure_reason_offset: 9,
                failure_reason_size: 9,
                warning_message_offset: 9,
                warning_message_size: 9,
                peer_count: 9,
                present_fields: 9,
                address_family: 9,
                reserved0: 9,
                reserved1: 9
            )
            let status = unsafe body.withUnsafeBytes { rawBody in
                unsafe torrentHTTPTrackerResponseParseCallback(
                    context,
                    rawBody.bindMemory(to: CChar.self).baseAddress!,
                    Int32(rawBody.count),
                    0,
                    nil,
                    0,
                    &sentinel,
                    0,
                    &result
                )
            }

            #expect(status == EOVERFLOW)
            #expect(sentinel.address_low == 0xfeed_face)
            #expect(result.peer_count == 0)
            #expect(result.present_fields == 0)
            #expect(result.interval == 0)
        }
    }

    // SAFETY: Ownership/lifetime: retained context, nonempty body, and outputs live through the
    // synchronous callback; bounds/alignment: bytes bind to alignment-1 CChar and record capacity
    // matches storage; synchronization: locals are unshared; safe alternative: invalid scalar
    // handling must be exercised through the raw callback.
    @Test("Callback argument validation clears stale scalar output")
    func rejectsInvalidArguments() {
        let body = Data("de".utf8)
        unsafe withTrackerResponseContext { context in
            var peer = TTorrentTrackerPeerRecord()
            var result = TTorrentHTTPTrackerResponseResult()
            result.peer_count = 9
            let status = unsafe body.withUnsafeBytes { rawBody in
                unsafe torrentHTTPTrackerResponseParseCallback(
                    context,
                    rawBody.bindMemory(to: CChar.self).baseAddress!,
                    Int32(rawBody.count),
                    2,
                    nil,
                    0,
                    &peer,
                    1,
                    &result
                )
            }

            #expect(status == EINVAL)
            #expect(result.peer_count == 0)
        }
    }

    // SAFETY: Ownership/lifetime: immutable body/context outlive concurrentPerform and each
    // output is local; bounds/alignment: nonempty bytes bind to alignment-1 CChar and capacity
    // matches one record; synchronization: only immutable input is shared and failures use
    // Mutex; safe alternative: callback concurrency must be tested through the C ABI.
    @Test("One retained context serves concurrent tracker callbacks before teardown")
    func supportsConcurrentCallbacksBeforeTeardown() {
        let body = bencodedDictionary([
            ("interval", bencodedInteger(60)),
        ])
        let context = TrackerConcurrentTestContext()
        let failures = Mutex(0)

        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            var peer = TTorrentTrackerPeerRecord()
            var result = TTorrentHTTPTrackerResponseResult()
            let status = unsafe body.withUnsafeBytes { rawBody in
                unsafe torrentHTTPTrackerResponseParseCallback(
                    context.pointer,
                    rawBody.bindMemory(to: CChar.self).baseAddress!,
                    Int32(rawBody.count),
                    0,
                    nil,
                    0,
                    &peer,
                    1,
                    &result
                )
            }
            if status != 0 || result.interval != 60 || result.peer_count != 0 {
                failures.withLock { count in
                    count += 1
                }
            }
        }

        #expect(failures.withLock { $0 == 0 })
        withExtendedLifetime(context) {}
    }
}

/// The callback context is retained once for the whole concurrent batch and
/// released only after every synchronous invocation has joined.
// SAFETY: Ownership/lifetime: the single retained context outlives the whole concurrent batch;
// bounds/alignment: pointer is the exact aligned opaque class address and is not byte-indexed;
// synchronization: the pointer is immutable, the parser context is stateless, and all callbacks
// join before deinit; safe alternative: UnsafeMutableRawPointer is not Sendable, but the C ABI
// requires the same opaque context address for every callback.
@safe private final class TrackerConcurrentTestContext: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer

    // SAFETY: Ownership/lifetime: passRetained creates the unique retain released after all
    // callbacks join; bounds/alignment: this is the exact aligned class address with no byte
    // access; synchronization: context is immutable; safe alternative: C callbacks accept
    // only an opaque context pointer.
    init() {
        unsafe pointer = Unmanaged.passRetained(TorrentTrackerResponseBridgeContext())
            .toOpaque()
    }

    // SAFETY: Ownership/lifetime: this balances init's retain after concurrent work joined;
    // bounds/alignment: pointer is the exact class address with no byte access;
    // synchronization: teardown follows concurrentPerform; safe alternative: opaque C
    // ownership must be modeled with Unmanaged.
    deinit {
        unsafe Unmanaged<TorrentTrackerResponseBridgeContext>
            .fromOpaque(pointer)
            .release()
    }
}

// SAFETY: Ownership/lifetime: the retain spans the nonescaping synchronous body and defer
// balances it; bounds/alignment: the opaque pointer is the exact aligned class address;
// synchronization: helper use is single-threaded unless body joins its work; safe alternative:
// invoking the callback requires an opaque C context pointer.
private func withTrackerResponseContext(
    _ body: (UnsafeMutableRawPointer) -> Void
) {
    let retained = unsafe Unmanaged.passRetained(TorrentTrackerResponseBridgeContext())
    defer {
        unsafe retained.release()
    }
    unsafe body(retained.toOpaque())
}

private func bodySlice(_ body: Data, offset: Int32, size: Int32) -> Data {
    Data(body[Int(offset)..<(Int(offset) + Int(size))])
}

private func bencodedInteger(_ value: Int64) -> Data {
    Data("i\(value)e".utf8)
}

private func bencodedString(_ value: Data) -> Data {
    Data("\(value.count):".utf8) + value
}

private func bencodedList(_ values: [Data]) -> Data {
    values.reduce(into: Data([UInt8(ascii: "l")])) { result, value in
        result.append(value)
    } + Data([UInt8(ascii: "e")])
}

private func bencodedDictionary(_ fields: [(String, Data)]) -> Data {
    bencodedByteKeyedDictionary(fields.map { (Data($0.0.utf8), $0.1) })
}

private func bencodedByteKeyedDictionary(_ fields: [(Data, Data)]) -> Data {
    let sorted = fields.sorted { left, right in
        left.0.lexicographicallyPrecedes(right.0)
    }
    var result = Data([UInt8(ascii: "d")])
    for (key, value) in sorted {
        result.append(bencodedString(key))
        result.append(value)
    }
    result.append(UInt8(ascii: "e"))
    return result
}
