import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
import TorrentBridge
@testable import TorrentEngineCore

@Suite("Swift swarm metainfo callback")
struct TorrentSwarmMetainfoParserTests {
    @Test("Valid bare info becomes an owned info-dictionary capsule")
    func encodesValidBareInfo() throws {
        let info = validV1Info()
        let invocation = invokeSwarmParser(info)
        #expect(invocation.status == 0)
        #expect(invocation.transferredSize > 0)
        #expect(invocation.transferredPointerWasNil == false)
        let capsule = try #require(invocation.capsule)

        #expect(capsule[12] == UInt8(TTORRENT_METAINFO_INPUT_INFO_DICTIONARY))
        let infoOffset = Int(littleEndianUInt32(capsule, at: 24))
        let infoSize = Int(littleEndianUInt32(capsule, at: 28))
        #expect(infoSize == info.count)
        #expect(capsule[infoOffset ..< infoOffset + infoSize] == info[info.startIndex...])
    }

    @Test("Invalid bare info fails without transferring ownership")
    func rejectsInvalidBareInfo() {
        let input = Data("not-bencoded-info".utf8)
        let invocation = invokeSwarmParser(input)

        #expect(invocation.status == EINVAL)
        #expect(invocation.transferredPointerWasNil)
        #expect(invocation.transferredSize == 0)
        #expect(invocation.capsule == nil)
    }

    @Test("Concurrent swarm callbacks transfer independent allocations before teardown")
    func supportsConcurrentOwnedResultsBeforeTeardown() {
        // SAFETY: Ownership/lifetime: immutable input/context outlive concurrentPerform and each
        // successful malloc result is released once in its invocation; bounds/alignment: nonempty
        // bytes bind to alignment-1 CChar with exact count and the callback owns result layout;
        // synchronization: only immutable input is shared and failures use Mutex; safe alternative:
        // allocation transfer/concurrency must be tested through the C callback ABI.
        let info = validV1Info()
        let context = SwarmConcurrentTestContext()
        let failures = Mutex(0)

        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            var result = unsafe TTorrentOwnedMetainfoCapsule()
            let status = unsafe info.withUnsafeBytes { rawInfo in
                unsafe torrentSwarmMetainfoParseCallback(
                    context.pointer,
                    rawInfo.bindMemory(to: CChar.self).baseAddress!,
                    Int32(rawInfo.count),
                    &result
                )
            }
            let valid = unsafe status == 0 && result.bytes != nil && result.size > 0
            unsafe torrentSwarmMetainfoCapsuleReleaseCallback(context.pointer, result)
            if !valid {
                failures.withLock { count in
                    count += 1
                }
            }
        }

        #expect(failures.withLock { $0 == 0 })
        withExtendedLifetime(context) {}
    }
}

/// Each callback result has its own malloc allocation; the shared immutable
/// context remains retained until all synchronous invocations have joined.
// SAFETY: Ownership/lifetime: the single retained context outlives the whole concurrent batch;
// bounds/alignment: pointer is the exact aligned opaque class address and is not byte-indexed;
// synchronization: the pointer is immutable, the parser context is stateless, and all callbacks
// join before deinit; safe alternative: UnsafeMutableRawPointer is not Sendable, but the C ABI
// requires the same opaque context address for every callback.
@safe private final class SwarmConcurrentTestContext: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer

    init() {
        // SAFETY: Ownership/lifetime: passRetained creates the unique retain released after all
        // callbacks join; bounds/alignment: this is the exact aligned class address with no byte
        // access; synchronization: context is immutable; safe alternative: C callbacks accept
        // only an opaque context pointer.
        unsafe pointer = Unmanaged.passRetained(TorrentSwarmMetainfoParserBridgeContext())
            .toOpaque()
    }

    deinit {
        // SAFETY: Ownership/lifetime: this balances init's retain after concurrent work joined;
        // bounds/alignment: pointer is the exact class address with no byte access;
        // synchronization: teardown follows concurrentPerform; safe alternative: opaque C
        // ownership must be modeled with Unmanaged.
        unsafe Unmanaged<TorrentSwarmMetainfoParserBridgeContext>
            .fromOpaque(pointer)
            .release()
    }
}

private struct SwarmParserInvocation {
    let status: Int32
    let capsule: Data?
    let transferredPointerWasNil: Bool
    let transferredSize: Int32
}

private func invokeSwarmParser(_ input: Data) -> SwarmParserInvocation {
    // SAFETY: Ownership/lifetime: retained context and input live through the synchronous callback,
    // returned malloc storage is copied before one release callback, and defer balances context;
    // bounds/alignment: nonempty input binds to alignment-1 CChar with exact count and returned
    // size governs the copy; synchronization: all state is local; safe alternative: ownership
    // transfer can only be exercised through the raw C callback.
    let context = TorrentSwarmMetainfoParserBridgeContext()
    let retained = unsafe Unmanaged.passRetained(context)
    defer {
        unsafe retained.release()
    }
    var result = unsafe TTorrentOwnedMetainfoCapsule()
    let status = unsafe input.withUnsafeBytes { rawBuffer in
        let bytes = unsafe rawBuffer.bindMemory(to: CChar.self)
        return unsafe torrentSwarmMetainfoParseCallback(
            retained.toOpaque(),
            bytes.baseAddress!,
            Int32(bytes.count),
            &result
        )
    }
    let transferredSize = unsafe result.size
    let transferredPointerWasNil = unsafe result.bytes == nil
    let capsule: Data?
    if let output = unsafe result.bytes, transferredSize > 0 {
        capsule = unsafe Data(bytes: output, count: Int(transferredSize))
    } else {
        capsule = nil
    }
    unsafe torrentSwarmMetainfoCapsuleReleaseCallback(
        retained.toOpaque(),
        result
    )
    return SwarmParserInvocation(
        status: status,
        capsule: capsule,
        transferredPointerWasNil: transferredPointerWasNil,
        transferredSize: transferredSize
    )
}

private func validV1Info() -> Data {
    var bytes = Data("d6:lengthi4e4:name8:file.bin12:piece lengthi16384e6:pieces20:".utf8)
    bytes.append(Data(repeating: 0x70, count: 20))
    bytes.append(Data("7:privatei1ee".utf8))
    return bytes
}

private func littleEndianUInt32(_ bytes: Data, at offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | UInt32(bytes[offset + 1]) << 8
        | UInt32(bytes[offset + 2]) << 16
        | UInt32(bytes[offset + 3]) << 24
}
