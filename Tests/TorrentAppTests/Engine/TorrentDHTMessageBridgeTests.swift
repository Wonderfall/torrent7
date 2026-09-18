import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
import TorrentBridge
@testable import TorrentEngineCore

@Suite("Swift DHT message callback")
struct TorrentDHTMessageBridgeTests {
    // SAFETY: Ownership/lifetime: retained context, Data, and output arrays live through the
    // synchronous callback; bounds/alignment: nonempty byte storage is rebound only between
    // alignment-1 byte types and exact array capacities are supplied; synchronization: locals
    // are unshared; safe alternative: callback behavior must be tested through its C ABI.
    @Test("Response callback emits bounded typed KRPC records")
    func importsResponse() {
        let nodeID = Data(repeating: UInt8(ascii: "n"), count: 20)
        let senderID = Data(repeating: UInt8(ascii: "s"), count: 20)
        let sample = Data(repeating: UInt8(ascii: "h"), count: 20)
        let compactNode = nodeID + Data([203, 0, 113, 9, 0x1a, 0xe1])
        let compactPeer = Data([203, 0, 113, 10, 0x1a, 0xe2])
        let response = dhtBencodedDictionary([
            ("id", dhtBencodedString(senderID)),
            ("interval", dhtBencodedInteger(300)),
            ("nodes", dhtBencodedString(compactNode)),
            ("num", dhtBencodedInteger(42)),
            ("samples", dhtBencodedString(sample)),
            ("token", dhtBencodedString(Data("token".utf8))),
            ("values", dhtBencodedList([dhtBencodedString(compactPeer)])),
        ])
        let body = dhtBencodedDictionary([
            ("ip", dhtBencodedString(Data([203, 0, 113, 5, 0x1a, 0xe0]))),
            ("r", response),
            ("t", dhtBencodedString(Data("tx".utf8))),
            ("y", dhtBencodedString(Data("r".utf8))),
        ])

        unsafe withDHTMessageContext { context in
            var nodes = [TTorrentDHTNodeRecord](
                repeating: TTorrentDHTNodeRecord(),
                count: 2
            )
            var peers = [TTorrentDHTPeerRecord](
                repeating: TTorrentDHTPeerRecord(),
                count: 2
            )
            var result = TTorrentDHTMessageResult()
            let status = unsafe body.withUnsafeBytes { rawBody in
                nodes.withUnsafeMutableBufferPointer { nodeBuffer in
                    peers.withUnsafeMutableBufferPointer { peerBuffer in
                        unsafe torrentDHTMessageParseCallback(
                            context,
                            rawBody.bindMemory(to: CChar.self).baseAddress!,
                            Int32(rawBody.count),
                            UInt8(TTORRENT_PEER_ADDRESS_IPV6),
                            nodeBuffer.baseAddress!,
                            Int32(nodeBuffer.count),
                            peerBuffer.baseAddress!,
                            Int32(peerBuffer.count),
                            &result
                        )
                    }
                }
            }

            #expect(status == 0)
            #expect(result.message_kind == UInt8(TTORRENT_DHT_MESSAGE_RESPONSE))
            #expect(result.query_kind == UInt8(TTORRENT_DHT_QUERY_NONE))
            #expect(result.query_is_valid == 1)
            #expect(result.node_count == 1)
            #expect(result.peer_count == 1)
            #expect(result.sample_count == 1)
            #expect(result.interval == 300)
            #expect(result.total_infohash_count == 42)
            #expect(result.external_address_family == UInt8(TTORRENT_PEER_ADDRESS_IPV4))
            #expect(result.external_address_low == 0xcb00_7105)
            #expect(result.present_fields == UInt32(
                TTORRENT_DHT_HAS_TRANSACTION
                    | TTORRENT_DHT_HAS_SENDER_ID
                    | TTORRENT_DHT_HAS_TOKEN
                    | TTORRENT_DHT_HAS_EXTERNAL_ADDRESS
                    | TTORRENT_DHT_HAS_INTERVAL
                    | TTORRENT_DHT_HAS_INFOHASH_COUNT
                    | TTORRENT_DHT_HAS_PEERS
                    | TTORRENT_DHT_HAS_SAMPLES
            ))
            #expect(dhtBodySlice(
                body,
                offset: result.transaction_offset,
                size: result.transaction_size
            ) == Data("tx".utf8))
            #expect(dhtBodySlice(
                body,
                offset: result.sender_id_offset,
                size: 20
            ) == senderID)
            #expect(dhtBodySlice(
                body,
                offset: result.token_offset,
                size: result.token_size
            ) == Data("token".utf8))
            #expect(dhtBodySlice(
                body,
                offset: result.sample_hashes_offset,
                size: result.sample_count * 20
            ) == sample)

            #expect(nodes[0].address_family == UInt8(TTORRENT_PEER_ADDRESS_IPV4))
            #expect(nodes[0].address_low == 0xcb00_7109)
            #expect(nodes[0].port == 6_881)
            #expect(dhtBodySlice(
                body,
                offset: nodes[0].id_offset,
                size: 20
            ) == nodeID)
            #expect(peers[0].address_family == UInt8(TTORRENT_PEER_ADDRESS_IPV4))
            #expect(peers[0].address_low == 0xcb00_710a)
            #expect(peers[0].port == 6_882)
        }
    }

    // SAFETY: Ownership/lifetime: retained context, Data, and scalar outputs live through the
    // synchronous callback; bounds/alignment: nonempty bytes use alignment-1 CChar binding and
    // declared capacities match the single records; synchronization: locals are unshared;
    // safe alternative: capacity rejection is a raw callback ABI contract.
    @Test("Capacity rejection leaves record buffers untouched and clears result")
    func rejectsInsufficientCapacityAtomically() {
        let node = Data(repeating: UInt8(ascii: "n"), count: 20)
            + Data([203, 0, 113, 9, 0x1a, 0xe1])
        let response = dhtBencodedDictionary([
            ("id", dhtBencodedString(Data(repeating: 1, count: 20))),
            ("nodes", dhtBencodedString(node + node)),
        ])
        let body = dhtBencodedDictionary([
            ("r", response),
            ("y", dhtBencodedString(Data("r".utf8))),
        ])

        unsafe withDHTMessageContext { context in
            var nodeSentinel = TTorrentDHTNodeRecord()
            nodeSentinel.address_low = 0xfeed_face
            var peerSentinel = TTorrentDHTPeerRecord()
            peerSentinel.address_low = 0xdead_beef
            var result = TTorrentDHTMessageResult()
            result.node_count = 9
            let status = unsafe body.withUnsafeBytes { rawBody in
                unsafe torrentDHTMessageParseCallback(
                    context,
                    rawBody.bindMemory(to: CChar.self).baseAddress!,
                    Int32(rawBody.count),
                    UInt8(TTORRENT_PEER_ADDRESS_IPV4),
                    &nodeSentinel,
                    1,
                    &peerSentinel,
                    1,
                    &result
                )
            }

            #expect(status == EOVERFLOW)
            #expect(nodeSentinel.address_low == 0xfeed_face)
            #expect(peerSentinel.address_low == 0xdead_beef)
            #expect(result.node_count == 0)
            #expect(result.present_fields == 0)
        }
    }

    // SAFETY: Ownership/lifetime: retained context, Data, and scalar outputs live through the
    // synchronous callback; bounds/alignment: nonempty bytes use alignment-1 CChar binding and
    // declared capacities match the records; synchronization: locals are unshared;
    // safe alternative: malformed-input atomicity is a raw callback ABI contract.
    @Test("Malformed compact suffixes leave callback output untouched and empty")
    func rejectsPartialCompactRecordsAtomically() {
        let completeNode = Data(repeating: UInt8(ascii: "n"), count: 20)
            + Data([203, 0, 113, 9, 0x1a, 0xe1])
        let response = dhtBencodedDictionary([
            ("id", dhtBencodedString(Data(repeating: 1, count: 20))),
            ("nodes", dhtBencodedString(completeNode + Data([0xff]))),
        ])
        let body = dhtBencodedDictionary([
            ("r", response),
            ("y", dhtBencodedString(Data("r".utf8))),
        ])

        unsafe withDHTMessageContext { context in
            var node = TTorrentDHTNodeRecord()
            node.address_low = 0xfeed_face
            var peer = TTorrentDHTPeerRecord()
            peer.address_low = 0xdead_beef
            var result = TTorrentDHTMessageResult()
            result.node_count = 9
            let status = unsafe body.withUnsafeBytes { rawBody in
                unsafe torrentDHTMessageParseCallback(
                    context,
                    rawBody.bindMemory(to: CChar.self).baseAddress!,
                    Int32(rawBody.count),
                    UInt8(TTORRENT_PEER_ADDRESS_IPV4),
                    &node,
                    1,
                    &peer,
                    1,
                    &result
                )
            }

            #expect(status == EINVAL)
            #expect(node.address_low == 0xfeed_face)
            #expect(peer.address_low == 0xdead_beef)
            #expect(result.node_count == 0)
            #expect(result.present_fields == 0)
        }
    }

    // SAFETY: Ownership/lifetime: retained context, nonempty Data, and outputs live through the
    // synchronous callback; bounds/alignment: byte binding has alignment 1 and one-record
    // capacities match storage; synchronization: locals are unshared; safe alternative:
    // invalid scalar behavior must be exercised through the raw C callback.
    @Test("Invalid source family clears stale scalar output")
    func rejectsInvalidArguments() {
        let body = Data("de".utf8)
        unsafe withDHTMessageContext { context in
            var node = TTorrentDHTNodeRecord()
            var peer = TTorrentDHTPeerRecord()
            var result = TTorrentDHTMessageResult()
            result.peer_count = 9
            let status = unsafe body.withUnsafeBytes { rawBody in
                unsafe torrentDHTMessageParseCallback(
                    context,
                    rawBody.bindMemory(to: CChar.self).baseAddress!,
                    Int32(rawBody.count),
                    5,
                    &node,
                    1,
                    &peer,
                    1,
                    &result
                )
            }

            #expect(status == EINVAL)
            #expect(result.peer_count == 0)
        }
    }

    // SAFETY: Ownership/lifetime: immutable Data/context outlive concurrentPerform and every
    // output is invocation-local; bounds/alignment: nonempty bytes bind to alignment-1 CChar
    // and single-record capacities are exact; synchronization: only immutable inputs are shared
    // and failures use Mutex; safe alternative: thread-safety must exercise the raw callback.
    @Test("One retained context safely serves concurrent callbacks before teardown")
    func supportsConcurrentCallbacksBeforeTeardown() {
        let body = dhtBencodedDictionary([
            ("a", dhtBencodedDictionary([
                ("id", dhtBencodedString(Data(repeating: 1, count: 20))),
            ])),
            ("q", dhtBencodedString(Data("ping".utf8))),
            ("t", dhtBencodedString(Data([0, 1]))),
            ("y", dhtBencodedString(Data("q".utf8))),
        ])
        let context = DHTConcurrentTestContext()
        let failures = Mutex<[Int32]>([])

        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            var node = TTorrentDHTNodeRecord()
            var peer = TTorrentDHTPeerRecord()
            var result = TTorrentDHTMessageResult()
            let status = unsafe body.withUnsafeBytes { rawBody in
                unsafe torrentDHTMessageParseCallback(
                    context.pointer,
                    rawBody.bindMemory(to: CChar.self).baseAddress!,
                    Int32(rawBody.count),
                    UInt8(TTORRENT_PEER_ADDRESS_IPV4),
                    &node,
                    1,
                    &peer,
                    1,
                    &result
                )
            }
            if status != 0
                || result.message_kind != UInt8(TTORRENT_DHT_MESSAGE_QUERY)
                || result.query_kind != UInt8(TTORRENT_DHT_QUERY_PING)
                || result.query_is_valid != 1 {
                failures.withLock { values in
                    values.append(status)
                }
            }
        }

        #expect(failures.withLock { $0.isEmpty })
        withExtendedLifetime(context) {}
    }
}

/// The raw value represents one independently retained, immutable Swift object.
/// Concurrent callbacks only use it to establish that non-null lifetime; the
/// object is released after `concurrentPerform` has joined every invocation.
// SAFETY: Ownership/lifetime: the single retained context outlives the whole concurrent batch;
// bounds/alignment: pointer is the exact aligned opaque class address and is not byte-indexed;
// synchronization: the pointer is immutable, the parser context is stateless, and all callbacks
// join before deinit; safe alternative: UnsafeMutableRawPointer is not Sendable, but the C ABI
// requires the same opaque context address for every callback.
@safe private final class DHTConcurrentTestContext: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer

    // SAFETY: Ownership/lifetime: passRetained creates the unique retain released in deinit
    // after concurrentPerform joins; bounds/alignment: the opaque pointer is the exact aligned
    // class address with no byte access; synchronization: the context is immutable;
    // safe alternative: the C callback accepts only an opaque pointer.
    init() {
        unsafe pointer = Unmanaged.passRetained(TorrentDHTMessageBridgeContext())
            .toOpaque()
    }

    // SAFETY: Ownership/lifetime: this balances the single init retain after all callbacks
    // joined; bounds/alignment: pointer is the exact class address with no byte access;
    // synchronization: teardown is after concurrentPerform; safe alternative: opaque C
    // context ownership must be modeled with Unmanaged.
    deinit {
        unsafe Unmanaged<TorrentDHTMessageBridgeContext>
            .fromOpaque(pointer)
            .release()
    }
}

// SAFETY: Ownership/lifetime: the retain spans the nonescaping synchronous body and defer
// balances it; bounds/alignment: the opaque pointer is the exact aligned class address;
// synchronization: helper use is single-threaded unless the body joins its work;
// safe alternative: invoking the C callback requires an opaque context pointer.
private func withDHTMessageContext(
    _ body: (UnsafeMutableRawPointer) -> Void
) {
    let retained = unsafe Unmanaged.passRetained(TorrentDHTMessageBridgeContext())
    defer {
        unsafe retained.release()
    }
    unsafe body(retained.toOpaque())
}

private func dhtBodySlice(_ body: Data, offset: Int32, size: Int32) -> Data {
    Data(body[Int(offset)..<(Int(offset) + Int(size))])
}

private func dhtBencodedInteger(_ value: Int64) -> Data {
    Data("i\(value)e".utf8)
}

private func dhtBencodedString(_ value: Data) -> Data {
    Data("\(value.count):".utf8) + value
}

private func dhtBencodedList(_ values: [Data]) -> Data {
    values.reduce(into: Data([UInt8(ascii: "l")])) { result, value in
        result.append(value)
    } + Data([UInt8(ascii: "e")])
}

private func dhtBencodedDictionary(_ fields: [(String, Data)]) -> Data {
    let sorted = fields.sorted { left, right in
        left.0.utf8.lexicographicallyPrecedes(right.0.utf8)
    }
    var result = Data([UInt8(ascii: "d")])
    for (key, value) in sorted {
        result.append(dhtBencodedString(Data(key.utf8)))
        result.append(value)
    }
    result.append(UInt8(ascii: "e"))
    return result
}
