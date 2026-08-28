import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
import TorrentBridge
@testable import TorrentEngineCore

@Suite("Swift DHT message callback")
struct TorrentDHTMessageBridgeTests {
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
                unsafe nodes.withUnsafeMutableBufferPointer { nodeBuffer in
                    unsafe peers.withUnsafeMutableBufferPointer { peerBuffer in
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
@safe private final class DHTConcurrentTestContext: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer

    init() {
        unsafe pointer = Unmanaged.passRetained(TorrentDHTMessageBridgeContext())
            .toOpaque()
    }

    deinit {
        unsafe Unmanaged<TorrentDHTMessageBridgeContext>
            .fromOpaque(pointer)
            .release()
    }
}

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
