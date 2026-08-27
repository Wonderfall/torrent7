import Darwin
import Foundation
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
}

private struct SwarmParserInvocation {
    let status: Int32
    let capsule: Data?
    let transferredPointerWasNil: Bool
    let transferredSize: Int32
}

private func invokeSwarmParser(_ input: Data) -> SwarmParserInvocation {
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
