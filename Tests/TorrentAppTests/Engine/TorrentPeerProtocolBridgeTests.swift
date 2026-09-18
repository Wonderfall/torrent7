import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
import TorrentBridge
@testable import TorrentEngineCore

@Suite("Swift peer protocol callbacks")
struct TorrentPeerProtocolBridgeTests {
    // SAFETY: Ownership/lifetime: retained context, message, and outputs live through the
    // synchronous callback; bounds/alignment: nonempty bytes bind between alignment-1 types
    // and the exact output capacity is supplied; synchronization: locals are unshared;
    // safe alternative: callback behavior must be tested through its C ABI.
    @Test("Extension handshake callback fills only present typed fields", arguments: [Int32(-1), 0, 9, .max])
    func importsExtensionHandshake(completionAge: Int32) {
        var message = Data(
            "d12:complete_agoi\(completionAge)e1:md11:lt_donthavei7e11:upload_onlyi3e12:ut_holepunchi4e11:ut_metadatai2e6:ut_pexi1ee13:metadata_sizei1234e1:pi6881e4:reqqi250e11:upload_onlyi1e1:v9:Torrent 76:yourip4:".utf8
        )
        message.append(contentsOf: [203, 0, 113, 8])
        message.append(UInt8(ascii: "e"))

        unsafe withPeerProtocolContext { context in
            var clientVersion = [UInt8](repeating: 0xcc, count: Int(TTORRENT_MAX_PEER_CLIENT_VERSION_BYTES))
            var result = TTorrentExtensionHandshakeResult()
            let status = unsafe message.withUnsafeBytes { rawMessage in
                clientVersion.withUnsafeMutableBufferPointer { versionBuffer in
                    unsafe torrentExtensionHandshakeParseCallback(
                        context,
                        rawMessage.bindMemory(to: CChar.self).baseAddress!,
                        Int32(rawMessage.count),
                        versionBuffer.baseAddress!,
                        Int32(versionBuffer.count),
                        &result
                    )
                }
            }

            #expect(status == 0)
            #expect(result.ut_metadata_id == 2)
            #expect(result.ut_pex_id == 1)
            #expect(result.upload_only_id == 3)
            #expect(result.holepunch_id == 4)
            #expect(result.dont_have_id == 7)
            #expect(result.metadata_size == 1_234)
            #expect(result.listen_port == 6_881)
            #expect(result.request_queue_limit == 250)
            #expect(result.address_family == UInt8(TTORRENT_PEER_ADDRESS_IPV4))
            #expect(result.address_high == 0)
            #expect(result.address_low == 0xcb00_7108)
            #expect(result.upload_only == 1)
            #expect(result.last_seen_complete == (completionAge == -1 ? 0 : completionAge))
            #expect(result.present_fields == UInt32(
                TTORRENT_HANDSHAKE_HAS_METADATA_SIZE
                    | TTORRENT_HANDSHAKE_HAS_LISTEN_PORT
                    | TTORRENT_HANDSHAKE_HAS_REQUEST_QUEUE
                    | TTORRENT_HANDSHAKE_HAS_CLIENT_VERSION
                    | TTORRENT_HANDSHAKE_HAS_EXTERNAL_ADDRESS
                    | TTORRENT_HANDSHAKE_HAS_UPLOAD_ONLY
                    | (completionAge == -1 ? 0 : TTORRENT_HANDSHAKE_HAS_LAST_SEEN_COMPLETE)
            ))
            #expect(result.client_version_size == 9)
            #expect(Data(clientVersion.prefix(9)) == Data("Torrent 7".utf8))
            #expect(clientVersion[9] == 0xcc)
        }
    }

    // SAFETY: Ownership/lifetime: retained context, message, and result live through the
    // synchronous callback; bounds/alignment: nonempty bytes bind to alignment-1 CChar and
    // exact count is supplied; synchronization: locals are unshared; safe alternative:
    // payload-range behavior must be tested through the raw C callback.
    @Test("Metadata callback preserves the exact binary payload range")
    func importsMetadataMessage() {
        var message = Data("d8:msg_typei1e5:piecei2e10:total_sizei40000ee".utf8)
        let payloadOffset = message.count
        message.append(Data(repeating: 0xa5, count: 16_384))

        unsafe withPeerProtocolContext { context in
            var result = TTorrentMetadataMessageResult()
            let status = unsafe message.withUnsafeBytes { rawMessage in
                unsafe torrentMetadataMessageParseCallback(
                    context,
                    rawMessage.bindMemory(to: CChar.self).baseAddress!,
                    Int32(rawMessage.count),
                    &result
                )
            }

            #expect(status == 0)
            #expect(result.kind == UInt8(TTORRENT_METADATA_MESSAGE_DATA))
            #expect(result.raw_message_type == 1)
            #expect(result.piece == 2)
            #expect(result.has_total_size == 1)
            #expect(result.total_size == 40_000)
            #expect(result.payload_offset == Int32(payloadOffset))
            #expect(result.payload_size == 16_384)
        }
    }

    // SAFETY: Ownership/lifetime: retained context, message, and output array live through the
    // synchronous callback; bounds/alignment: bytes bind to alignment-1 CChar and exact record
    // capacity is supplied; synchronization: locals are unshared; safe alternative:
    // caller-owned record output is a C callback ABI contract.
    @Test("PEX callback emits ordered, bounded caller-owned records")
    func importsPeerExchange() {
        var message = Data("d5:added6:".utf8)
        message.append(contentsOf: [203, 0, 113, 9, 0x1a, 0xe1])
        message.append(Data("7:added.f1:".utf8))
        message.append(0xff)
        message.append(Data("7:dropped6:".utf8))
        message.append(contentsOf: [198, 51, 100, 2, 0x1a, 0xe3])
        message.append(UInt8(ascii: "e"))

        unsafe withPeerProtocolContext { context in
            var records = [TTorrentPeerExchangeRecord](
                repeating: TTorrentPeerExchangeRecord(),
                count: Int(TTORRENT_MAX_PEX_MESSAGE_CONTACTS)
            )
            var result = TTorrentPeerExchangeResult()
            let status = unsafe message.withUnsafeBytes { rawMessage in
                records.withUnsafeMutableBufferPointer { recordBuffer in
                    unsafe torrentPeerExchangeParseCallback(
                        context,
                        rawMessage.bindMemory(to: CChar.self).baseAddress!,
                        Int32(rawMessage.count),
                        recordBuffer.baseAddress!,
                        Int32(recordBuffer.count),
                        &result
                    )
                }
            }

            #expect(status == 0)
            #expect(result.record_count == 2)
            #expect(result.added_count == 1)
            #expect(result.dropped_count == 1)
            #expect(records[0].address_family == UInt8(TTORRENT_PEER_ADDRESS_IPV4))
            #expect(records[0].address_low == 0xcb00_7109)
            #expect(records[0].port == 6_881)
            #expect(records[0].action == UInt8(TTORRENT_PEX_CONTACT_ADD))
            #expect(records[0].flags == 0x1f)
            #expect(records[1].address_low == 0xc633_6402)
            #expect(records[1].port == 6_883)
            #expect(records[1].action == UInt8(TTORRENT_PEX_CONTACT_DROP))
            #expect(records[1].flags == 0)
        }
    }

    // SAFETY: Ownership/lifetime: retained context, message, and outputs live through the
    // synchronous callback; bounds/alignment: bytes bind at alignment 1 and the deliberately
    // invalid declared capacity is not used to index storage; synchronization: locals are
    // unshared; safe alternative: rejection behavior must exercise the raw C callback.
    @Test("PEX capacity failure leaves caller storage and result empty")
    func rejectsInsufficientPeerExchangeCapacityAtomically() {
        let message = Data("d5:added6:".utf8)
            + Data([203, 0, 113, 9, 0x1a, 0xe1])
            + Data("e".utf8)

        unsafe withPeerProtocolContext { context in
            var sentinel = TTorrentPeerExchangeRecord()
            sentinel.address_low = 0xfeed_face
            var result = TTorrentPeerExchangeResult(
                record_count: 9,
                added_count: 9,
                dropped_count: 9,
                reserved: 9
            )
            let status = unsafe message.withUnsafeBytes { rawMessage in
                unsafe torrentPeerExchangeParseCallback(
                    context,
                    rawMessage.bindMemory(to: CChar.self).baseAddress!,
                    Int32(rawMessage.count),
                    &sentinel,
                    Int32(TTORRENT_MAX_PEX_MESSAGE_CONTACTS) - 1,
                    &result
                )
            }

            #expect(status == EINVAL)
            #expect(sentinel.address_low == 0xfeed_face)
            #expect(result.record_count == 0)
            #expect(result.added_count == 0)
            #expect(result.dropped_count == 0)
            #expect(result.reserved == 0)
        }
    }

    // SAFETY: Ownership/lifetime: immutable message/context outlive concurrentPerform and each
    // result is local; bounds/alignment: nonempty bytes bind to alignment-1 CChar with exact
    // count; synchronization: only immutable input is shared and failures use Mutex;
    // safe alternative: callback concurrency must be tested through the C ABI.
    @Test("One retained context serves concurrent peer callbacks before teardown")
    func supportsConcurrentCallbacksBeforeTeardown() {
        let message = Data("d8:msg_typei0e5:piecei0ee".utf8)
        let context = PeerConcurrentTestContext()
        let failures = Mutex(0)

        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            var result = TTorrentMetadataMessageResult()
            let status = unsafe message.withUnsafeBytes { rawMessage in
                unsafe torrentMetadataMessageParseCallback(
                    context.pointer,
                    rawMessage.bindMemory(to: CChar.self).baseAddress!,
                    Int32(rawMessage.count),
                    &result
                )
            }
            if status != 0
                || result.kind != UInt8(TTORRENT_METADATA_MESSAGE_REQUEST)
                || result.piece != 0 {
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
@safe private final class PeerConcurrentTestContext: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer

    // SAFETY: Ownership/lifetime: passRetained creates the unique retain released after all
    // callbacks join; bounds/alignment: this is the exact aligned class address with no byte
    // access; synchronization: context is immutable; safe alternative: C callbacks accept
    // only an opaque context pointer.
    init() {
        unsafe pointer = Unmanaged.passRetained(TorrentPeerProtocolBridgeContext())
            .toOpaque()
    }

    // SAFETY: Ownership/lifetime: this balances init's retain after concurrent work joined;
    // bounds/alignment: pointer is the exact class address with no byte access;
    // synchronization: teardown follows concurrentPerform; safe alternative: opaque C
    // ownership must be modeled with Unmanaged.
    deinit {
        unsafe Unmanaged<TorrentPeerProtocolBridgeContext>
            .fromOpaque(pointer)
            .release()
    }
}

// SAFETY: Ownership/lifetime: the retain spans the nonescaping synchronous body and defer
// balances it; bounds/alignment: the opaque pointer is the exact aligned class address;
// synchronization: helper use is single-threaded unless body joins its work; safe alternative:
// invoking the callback requires an opaque C context pointer.
private func withPeerProtocolContext(
    _ body: (UnsafeMutableRawPointer) -> Void
) {
    let retained = unsafe Unmanaged.passRetained(TorrentPeerProtocolBridgeContext())
    defer {
        unsafe retained.release()
    }
    unsafe body(retained.toOpaque())
}
