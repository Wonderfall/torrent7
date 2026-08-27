import CryptoKit
import Foundation
import Testing
import TorrentBridge
import TorrentMetainfo
@testable import TorrentEngineCore

@Suite("Torrent metainfo bridge capsule")
struct TorrentMetainfoBridgeCapsuleTests {
    @Test("Local v1 capsule preserves exact info and a narrow envelope")
    func encodesLocalV1Metainfo() throws {
        let pieceHashes = Data(repeating: 0x11, count: Insecure.SHA1.byteCount)
        let info = CapsuleBencode.dictionary([
            capsuleKey("attr", .string("hx")),
            capsuleKey("length", .integer(5)),
            capsuleKey("name", .string("sample.bin")),
            capsuleKey("piece length", .integer(16_384)),
            capsuleKey("pieces", .bytes(pieceHashes)),
            capsuleKey("private", .integer(1)),
        ])
        let tracker = "HTTPS://tracker.example/announce"
        let webSeed = "HTTPS://seed.example/sample.bin"
        let metadata = capsuleTorrent(info: info, topLevel: [
            capsuleKey("announce", .string(tracker)),
            capsuleKey("comment", .string("capsule comment")),
            capsuleKey("created by", .string("Torrent7 tests")),
            capsuleKey("creation date", .integer(1_700_000_000)),
            capsuleKey("url-list", .string(webSeed)),
        ])
        let parsed = try TorrentMetainfoParser().parse(metadata)
        let capsule = try TorrentMetainfoBridgeCapsule(parsed)
        let view = CapsuleView(capsule.bytes)

        #expect(view.u32(0) == UInt32(TTORRENT_METAINFO_CAPSULE_MAGIC))
        #expect(view.u16(4) == UInt16(TTORRENT_METAINFO_CAPSULE_SCHEMA_VERSION))
        #expect(view.u16(6) == UInt16(TTORRENT_METAINFO_CAPSULE_HEADER_SIZE))
        #expect(view.u32(8) == UInt32(capsule.bytes.count))
        #expect(view.u8(12) == UInt8(TTORRENT_METAINFO_INPUT_TORRENT_FILE))
        #expect(view.u8(13) == UInt8(TTORRENT_METAINFO_KIND_V1))
        #expect(view.u8(14) == UInt8(TTORRENT_CONTENT_KIND_SINGLE_FILE))
        #expect(view.u8(15) == UInt8(TTORRENT_METAINFO_PRIVATE))
        #expect(view.u16(16) == parsed.envelope.presentFields.rawValue)
        #expect(view.u16(18) == 0)
        #expect(view.u32(20) == 16_384)
        #expect(view.i64(128) == 1_700_000_000)
        #expect(view.u32(140) == 0)
        #expect(view.bytes[154..<160].allSatisfy { $0 == 0 })

        let files = view.table(64)
        let components = view.table(72)
        let trackers = view.table(80)
        let webSeeds = view.table(88)
        let layers = view.table(96)
        let layerFileIndices = view.table(104)
        #expect(files == CapsuleTable(offset: 160, count: 1))
        #expect(components == CapsuleTable(offset: 192, count: 1))
        #expect(trackers == CapsuleTable(offset: 200, count: 1))
        #expect(webSeeds == CapsuleTable(offset: 216, count: 1))
        #expect(layers == CapsuleTable(offset: 224, count: 0))
        #expect(layerFileIndices == CapsuleTable(offset: 224, count: 0))
        #expect(view.u32(136) == 224)

        let infoRange = view.range(24)
        let pieceHashesRange = view.range(56)
        #expect(view.data(24) == Data(parsed.infoDictionary))
        #expect(view.data(32) == Data("sample.bin".utf8))
        #expect(view.data(40) == parsed.infoCore.v1InfoHash)
        #expect(view.range(48).isEmpty)
        #expect(infoRange.contains(pieceHashesRange))
        #expect(Data(view.bytes[pieceHashesRange]) == pieceHashes)

        #expect(view.i32(files.offset) == 0)
        #expect(view.u32(files.offset + 4) == 0)
        #expect(view.u32(files.offset + 8) == 1)
        #expect(view.u32(files.offset + 12)
            == UInt32(TTORRENT_METAINFO_FILE_EXECUTABLE | TTORRENT_METAINFO_FILE_HIDDEN))
        #expect(view.i64(files.offset + 16) == 5)
        #expect(view.range(files.offset + 24).isEmpty)
        #expect(view.data(components.offset) == Data("sample.bin".utf8))
        #expect(view.data(trackers.offset) == Data(tracker.utf8))
        #expect(view.u8(trackers.offset + 8) == 0)
        #expect(view.bytes[(trackers.offset + 9)..<(trackers.offset + 16)]
            .allSatisfy { $0 == 0 })
        #expect(view.data(webSeeds.offset) == Data(webSeed.utf8))
        #expect(view.data(112) == Data("capsule comment".utf8))
        #expect(view.data(120) == Data("Torrent7 tests".utf8))
    }

    @Test("V2 capsule maps shared piece layers to every typed file")
    func encodesV2PieceLayers() throws {
        let pieceLength: Int64 = 32 * 1_024
        let pieceHashes = [
            Data(repeating: 0x11, count: SHA256.byteCount),
            Data(repeating: 0x22, count: SHA256.byteCount),
            Data(repeating: 0x33, count: SHA256.byteCount),
        ]
        let padding = capsuleSHA256Pair(
            Data(repeating: 0, count: SHA256.byteCount),
            Data(repeating: 0, count: SHA256.byteCount)
        )
        let root = capsuleSHA256Pair(
            capsuleSHA256Pair(pieceHashes[0], pieceHashes[1]),
            capsuleSHA256Pair(pieceHashes[2], padding)
        )
        let hashes = pieceHashes.reduce(into: Data()) { $0.append($1) }
        let fileTree = ["a.bin", "b.bin"].map { name in
            capsuleKey(name, .dictionary([
                (Data(), .dictionary([
                    capsuleKey("attr", .string("hx")),
                    capsuleKey("length", .integer(pieceLength * 3)),
                    capsuleKey("pieces root", .bytes(root)),
                ]))
            ]))
        }
        let info = CapsuleBencode.dictionary([
            capsuleKey("file tree", .dictionary(fileTree)),
            capsuleKey("meta version", .integer(2)),
            capsuleKey("name", .string("payload")),
            capsuleKey("piece length", .integer(pieceLength)),
        ])
        let parsed = try TorrentMetainfoParser().parse(capsuleTorrent(
            info: info,
            topLevel: [(
                Data("piece layers".utf8),
                .dictionary([(root, .bytes(hashes))])
            )]
        ))
        let view = CapsuleView(try TorrentMetainfoBridgeCapsule(parsed).bytes)

        #expect(view.u8(12) == UInt8(TTORRENT_METAINFO_INPUT_TORRENT_FILE))
        #expect(view.u8(13) == UInt8(TTORRENT_METAINFO_KIND_V2))
        #expect(view.u8(14) == UInt8(TTORRENT_CONTENT_KIND_DIRECTORY))
        #expect(view.u16(16) == UInt16(TTORRENT_METAINFO_FIELD_PIECE_LAYERS))
        #expect(view.data(24) == Data(parsed.infoDictionary))
        #expect(view.range(40).isEmpty)
        #expect(view.data(48) == parsed.infoCore.v2InfoHash)
        #expect(view.range(56).isEmpty)

        let infoRange = view.range(24)
        let files = view.table(64)
        let components = view.table(72)
        let layers = view.table(96)
        let layerFileIndices = view.table(104)
        #expect(files.count == 2)
        #expect(components.count == 2)
        #expect(layers.count == 1)
        #expect(layerFileIndices.count == 2)

        let firstRoot = view.range(files.offset + 24)
        let secondRecord = files.offset + Int(TTORRENT_METAINFO_CAPSULE_FILE_RECORD_SIZE)
        let secondRoot = view.range(secondRecord + 24)
        #expect(firstRoot != secondRoot)
        #expect(infoRange.contains(firstRoot))
        #expect(infoRange.contains(secondRoot))
        #expect(Data(view.bytes[firstRoot]) == root)
        #expect(Data(view.bytes[secondRoot]) == root)
        #expect(view.u32(files.offset + 12)
            == UInt32(TTORRENT_METAINFO_FILE_EXECUTABLE | TTORRENT_METAINFO_FILE_HIDDEN))
        #expect(view.data(components.offset) == Data("a.bin".utf8))
        #expect(view.data(components.offset + Int(TTORRENT_METAINFO_CAPSULE_RANGE_RECORD_SIZE))
            == Data("b.bin".utf8))

        #expect(view.data(layers.offset) == root)
        #expect(view.data(layers.offset + 8) == hashes)
        #expect(view.u32(layers.offset + 16) == 0)
        #expect(view.u32(layers.offset + 20) == 2)
        #expect(view.i32(layerFileIndices.offset) == 0)
        #expect(view.i32(layerFileIndices.offset + 4) == 1)
        #expect(view.i64(128) == -1)
    }

    @Test("Bare hybrid info capsule carries no torrent envelope")
    func encodesBareHybridInfoDictionary() throws {
        let root = Data(repeating: 0x55, count: SHA256.byteCount)
        let pieceHashes = Data(repeating: 0x44, count: Insecure.SHA1.byteCount)
        let info = CapsuleBencode.dictionary([
            capsuleKey("file tree", .dictionary([
                capsuleKey("tiny.bin", .dictionary([
                    (Data(), .dictionary([
                        capsuleKey("length", .integer(3)),
                        capsuleKey("pieces root", .bytes(root)),
                    ]))
                ]))
            ])),
            capsuleKey("length", .integer(3)),
            capsuleKey("meta version", .integer(2)),
            capsuleKey("name", .string("tiny.bin")),
            capsuleKey("piece length", .integer(16_384)),
            capsuleKey("pieces", .bytes(pieceHashes)),
        ]).encoded()
        let parsed = try TorrentMetainfoParser().parseInfoDictionary(info)
        let view = CapsuleView(try TorrentMetainfoBridgeCapsule(parsed).bytes)

        #expect(view.u8(12) == UInt8(TTORRENT_METAINFO_INPUT_INFO_DICTIONARY))
        #expect(view.u8(13) == UInt8(TTORRENT_METAINFO_KIND_HYBRID))
        #expect(view.u8(14) == UInt8(TTORRENT_CONTENT_KIND_SINGLE_FILE))
        #expect(view.u16(16) == 0)
        #expect(view.data(24) == info)
        #expect(view.data(40) == parsed.infoCore.v1InfoHash)
        #expect(view.data(48) == parsed.infoCore.v2InfoHash)
        #expect(view.range(24).contains(view.range(56)))
        #expect(view.data(56) == pieceHashes)
        #expect(view.table(64).count == 1)
        #expect(view.table(80).count == 0)
        #expect(view.table(88).count == 0)
        #expect(view.table(96).count == 0)
        #expect(view.table(104).count == 0)
        #expect(view.range(112).isEmpty)
        #expect(view.range(120).isEmpty)
        #expect(view.i64(128) == -1)
    }
}

private struct CapsuleTable: Equatable {
    let offset: Int
    let count: Int
}

private struct CapsuleView {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    func u8(_ offset: Int) -> UInt8 {
        bytes[offset]
    }

    func u16(_ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    func u32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(into: UInt32(0)) { value, byte in
            value |= UInt32(bytes[offset + byte]) << UInt32(byte * 8)
        }
    }

    func i32(_ offset: Int) -> Int32 {
        Int32(bitPattern: u32(offset))
    }

    func i64(_ offset: Int) -> Int64 {
        let bits = (0..<8).reduce(into: UInt64(0)) { value, byte in
            value |= UInt64(bytes[offset + byte]) << UInt64(byte * 8)
        }
        return Int64(bitPattern: bits)
    }

    func range(_ offset: Int) -> Range<Int> {
        let lowerBound = Int(u32(offset))
        return lowerBound..<(lowerBound + Int(u32(offset + 4)))
    }

    func table(_ offset: Int) -> CapsuleTable {
        CapsuleTable(offset: Int(u32(offset)), count: Int(u32(offset + 4)))
    }

    func data(_ rangeOffset: Int) -> Data {
        Data(bytes[range(rangeOffset)])
    }
}

private extension Range<Int> {
    func contains(_ other: Range<Int>) -> Bool {
        !other.isEmpty && lowerBound <= other.lowerBound && other.upperBound <= upperBound
    }
}

private indirect enum CapsuleBencode {
    case integer(Int64)
    case bytes(Data)
    case dictionary([(Data, CapsuleBencode)])

    static func string(_ value: String) -> Self {
        .bytes(Data(value.utf8))
    }

    func encoded() -> Data {
        var output = Data()
        encode(into: &output)
        return output
    }

    private func encode(into output: inout Data) {
        switch self {
        case .integer(let value):
            output.append(Data("i\(value)e".utf8))
        case .bytes(let bytes):
            output.append(Data("\(bytes.count):".utf8))
            output.append(bytes)
        case .dictionary(let entries):
            output.append(UInt8(ascii: "d"))
            for (key, value) in entries.sorted(by: {
                $0.0.lexicographicallyPrecedes($1.0)
            }) {
                CapsuleBencode.bytes(key).encode(into: &output)
                value.encode(into: &output)
            }
            output.append(UInt8(ascii: "e"))
        }
    }
}

private func capsuleKey(
    _ key: String,
    _ value: CapsuleBencode
) -> (Data, CapsuleBencode) {
    (Data(key.utf8), value)
}

private func capsuleTorrent(
    info: CapsuleBencode,
    topLevel: [(Data, CapsuleBencode)] = []
) -> Data {
    CapsuleBencode.dictionary(topLevel + [capsuleKey("info", info)]).encoded()
}

private func capsuleSHA256Pair(_ left: Data, _ right: Data) -> Data {
    var hasher = SHA256()
    hasher.update(data: left)
    hasher.update(data: right)
    return Data(hasher.finalize())
}
