import CryptoKit
import Foundation
import Testing
@testable import TorrentApp

@Suite("Torrent storage manifest parser")
struct TorrentManifestParserTests {
    @Test("Canonical v1, v2, hybrid, and rootless layouts are independent manifests")
    func parsesSupportedLayouts() throws {
        let parser = TorrentManifestParser()

        let v1 = try parser.parse(Self.v1SingleFile(name: "sample.bin", size: 5))
        #expect(v1.manifest.name == "sample.bin")
        #expect(v1.manifest.contentKind == .singleFile)
        #expect(v1.manifest.infoHashes.v1?.count == Insecure.SHA1.byteCount)
        #expect(v1.manifest.infoHashes.v2 == nil)
        #expect(v1.manifest.files == [
            TorrentLogicalFile(
                index: 0,
                pathComponents: ["sample.bin"],
                expectedSize: 5,
                isPadding: false
            )
        ])
        #expect(v1.rawInfoDictionary.first == UInt8(ascii: "d"))

        let v2 = try parser.parse(Self.v2SingleFile(name: "modern.bin", size: 16_384))
        #expect(v2.manifest.name == "modern.bin")
        #expect(v2.manifest.contentKind == .singleFile)
        #expect(v2.manifest.infoHashes.v1 == nil)
        #expect(v2.manifest.infoHashes.v2?.count == SHA256.byteCount)
        #expect(v2.manifest.files.count == 1)

        let hybrid = try parser.parse(Self.hybridSingleFile(name: "hybrid.bin", size: 3))
        #expect(hybrid.manifest.contentKind == .singleFile)
        #expect(hybrid.manifest.infoHashes.v1?.count == Insecure.SHA1.byteCount)
        #expect(hybrid.manifest.infoHashes.v2?.count == SHA256.byteCount)
        #expect(hybrid.manifest.files.count == 1)

        let rootless = try parser.parse(Self.v2Rootless(path: "leaf.bin", size: 16_384))
        #expect(rootless.manifest.name.hasPrefix("Torrent-"))
        #expect(rootless.manifest.name.count == 20)
        #expect(rootless.manifest.contentKind == .directory)
        #expect(rootless.manifest.files[0].pathComponents == ["leaf.bin"])
    }

    @Test("Padding paths use libtorrent's synthetic canonical representation")
    func canonicalizesPaddingPaths() throws {
        let metadata = Self.v1Directory(
            name: "payload",
            files: [
                .init(path: ["a.bin"], size: 1),
                .init(path: ["source-pad-name"], size: 3, attributes: "p"),
                .init(path: ["b.bin"], size: 1),
            ]
        )

        let parsed = try TorrentManifestParser().parse(metadata)

        #expect(parsed.manifest.files[1].isPadding)
        #expect(parsed.manifest.files[1].pathComponents == [".pad", "3-1"])
    }

    @Test("Advertised hashes must match the exact canonical info bytes")
    func advertisedHashesMustMatch() throws {
        let metadata = Self.v1SingleFile(name: "sample.bin", size: 5)
        let parsed = try TorrentManifestParser().parse(metadata)
        let advertised = try TorrentAdvertisedInfoHashes(v1: parsed.manifest.infoHashes.v1)
        _ = try TorrentManifestParser().parse(metadata, advertisedHashes: advertised)

        try expectManifestError(.advertisedInfoHashMismatch) {
            _ = try TorrentManifestParser().parse(
                metadata,
                advertisedHashes: TorrentAdvertisedInfoHashes(
                    v1: Data(repeating: 0, count: Insecure.SHA1.byteCount)
                )
            )
        }
    }

    @Test("Magnet descriptors preserve exact hybrid info bytes and sources")
    func magnetDescriptorsPreserveExactInfoBytes() throws {
        let original = try TorrentManifestParser().parse(
            Self.hybridSingleFile(name: "hybrid.bin", size: 3)
        )
        let v1 = try #require(original.manifest.infoHashes.v1)
        let v2 = try #require(original.manifest.infoHashes.v2)
        let magnet = [
            "magnet:?xt=urn:btih:\(Self.hex(v1))",
            "xt=urn:btmh:1220\(Self.hex(v2))",
            "tr=https%3A%2F%2Ftracker.example%2Fannounce",
            "tr.1=udp%3A%2F%2Ftracker.example%3A80",
            "ws=https%3A%2F%2Fseed.example%2Fhybrid.bin",
        ].joined(separator: "&")

        let descriptor = try TorrentMagnetDescriptor.parse(magnet)
        #expect(descriptor.infoHashes == original.manifest.infoHashes)
        #expect(descriptor.trackers == [
            "https://tracker.example/announce",
            "udp://tracker.example:80",
        ])
        #expect(descriptor.webSeeds == [
            "https://seed.example/hybrid.bin"
        ])

        let promotedData = try descriptor.torrentFile(
            exactInfoDictionary: original.rawInfoDictionary
        )
        let promoted = try TorrentManifestParser().parse(
            promotedData,
            advertisedHashes: descriptor.advertisedInfoHashes
        )
        #expect(promoted.rawInfoDictionary == original.rawInfoDictionary)
        #expect(promoted.manifest == original.manifest)
    }

    @Test("Magnet descriptors accept canonical base32 v1 hashes")
    func magnetDescriptorsAcceptBase32V1Hashes() throws {
        let parsed = try TorrentManifestParser().parse(
            Self.v1SingleFile(name: "sample.bin", size: 5)
        )
        let v1 = try #require(parsed.manifest.infoHashes.v1)
        let descriptor = try TorrentMagnetDescriptor.parse(
            "magnet:?xt=urn:btih:\(Self.base32(v1).lowercased())"
        )

        #expect(descriptor.infoHashes.v1 == v1)
        #expect(descriptor.infoHashes.v2 == nil)
    }

    @Test("Magnet descriptors reject conflicting exact topics")
    func magnetDescriptorsRejectConflictingExactTopics() throws {
        let first = String(repeating: "0", count: 40)
        let second = String(repeating: "1", count: 40)

        #expect(throws: TorrentMagnetDescriptorError.conflictingInfoHashes) {
            _ = try TorrentMagnetDescriptor.parse(
                "magnet:?xt=urn:btih:\(first)&xt=urn:btih:\(second)"
            )
        }
    }

    @Test("Equivalent case and Unicode paths are rejected")
    func rejectsEquivalentPaths() throws {
        try expectManifestError(.duplicatePath) {
            _ = try TorrentManifestParser().parse(Self.v1Directory(
                name: "payload",
                files: [
                    .init(path: ["README"], size: 1),
                    .init(path: ["readme"], size: 1),
                ]
            ))
        }

        try expectManifestError(.duplicatePath) {
            _ = try TorrentManifestParser().parse(Self.v1Directory(
                name: "payload",
                files: [
                    .init(path: ["caf\u{00e9}.txt"], size: 1),
                    .init(path: ["cafe\u{0301}.txt"], size: 1),
                ]
            ))
        }
    }

    @Test("Traversal, symlinks, and file-directory conflicts fail closed")
    func rejectsUnsafeLayouts() throws {
        try expectManifestError(.invalidFilePath) {
            _ = try TorrentManifestParser().parse(Self.v1Directory(
                name: "payload",
                files: [.init(path: ["..", "escape"], size: 1)]
            ))
        }
        try expectManifestError(.symlinkNotSupported) {
            _ = try TorrentManifestParser().parse(Self.v1Directory(
                name: "payload",
                files: [.init(path: ["link"], size: 1, attributes: "l")]
            ))
        }
        try expectManifestError(.conflictingPath) {
            _ = try TorrentManifestParser().parse(Self.v1Directory(
                name: "payload",
                files: [
                    .init(path: ["node"], size: 1),
                    .init(path: ["node", "child"], size: 1),
                ]
            ))
        }
    }

    @Test("Noncanonical bencoding and parser budgets fail closed")
    func rejectsNoncanonicalAndOverBudgetMetadata() throws {
        let unsorted = TestBencode.dictionary([
            (Data("info".utf8), .integer(1)),
            (Data("announce".utf8), .bytes(Data()))
        ]).encoded(sortedDictionaries: false)
        try expectManifestError(.malformedBencoding) {
            _ = try TorrentManifestParser().parse(unsorted)
        }

        var limits = TorrentManifestParser.Limits.standard
        limits.maximumMetadataBytes = 8
        try expectManifestError(.metadataTooLarge) {
            _ = try TorrentManifestParser(limits: limits).parse(
                Self.v1SingleFile(name: "sample.bin", size: 5)
            )
        }
    }

    private struct V1File {
        let path: [String]
        let size: Int64
        var attributes: String?
    }

    private static func v1SingleFile(name: String, size: Int64) -> Data {
        torrent(info: .dictionary([
            key("length", .integer(size)),
            key("name", .string(name)),
            key("piece length", .integer(16_384)),
            key("pieces", .bytes(Data(repeating: 0x11, count: 20)))
        ]))
    }

    private static func v1Directory(name: String, files: [V1File]) -> Data {
        let total = files.reduce(into: Int64(0)) { $0 += $1.size }
        let pieceCount = max(1, Int((total + 16_383) / 16_384))
        return torrent(info: .dictionary([
            key("files", .list(files.map { file in
                var fields = [
                    key("length", .integer(file.size)),
                    key("path", .list(file.path.map { .string($0) }))
                ]
                if let attributes = file.attributes {
                    fields.append(key("attr", .string(attributes)))
                }
                return .dictionary(fields)
            })),
            key("name", .string(name)),
            key("piece length", .integer(16_384)),
            key("pieces", .bytes(Data(repeating: 0x22, count: pieceCount * 20)))
        ]))
    }

    private static func v2SingleFile(name: String, size: Int64) -> Data {
        torrent(info: v2Info(name: name, path: name, size: size, includesV1: false))
    }

    private static func v2Rootless(path: String, size: Int64) -> Data {
        torrent(info: v2Info(name: nil, path: path, size: size, includesV1: false))
    }

    private static func hybridSingleFile(name: String, size: Int64) -> Data {
        torrent(info: v2Info(name: name, path: name, size: size, includesV1: true))
    }

    private static func v2Info(
        name: String?,
        path: String,
        size: Int64,
        includesV1: Bool
    ) -> TestBencode {
        var properties = [key("length", .integer(size))]
        if size > 0 {
            properties.append(key(
                "pieces root",
                .bytes(Data(repeating: 0x33, count: SHA256.byteCount))
            ))
        }
        var values = [
            key("file tree", .dictionary([
                key(path, .dictionary([
                    (Data(), .dictionary(properties))
                ]))
            ])),
            key("meta version", .integer(2)),
            key("piece length", .integer(16_384))
        ]
        if let name {
            values.append(key("name", .string(name)))
        }
        if includesV1 {
            values.append(key("length", .integer(size)))
            values.append(key("pieces", .bytes(Data(repeating: 0x44, count: 20))))
        }
        return .dictionary(values)
    }

    private static func torrent(info: TestBencode) -> Data {
        TestBencode.dictionary([key("info", info)]).encoded()
    }

    private static func key(
        _ key: String,
        _ value: TestBencode
    ) -> (Data, TestBencode) {
        (Data(key.utf8), value)
    }

    private static func hex(_ data: Data) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(data.count * 2)
        for byte in data {
            output.append(alphabet[Int(byte >> 4)])
            output.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func base32(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var output = [UInt8]()
        var accumulator: UInt32 = 0
        var bitCount = 0
        for byte in data {
            accumulator = (accumulator << 8) | UInt32(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                output.append(alphabet[Int((accumulator >> bitCount) & 0x1f)])
                accumulator &= bitCount == 0 ? 0 : (1 << bitCount) - 1
            }
        }
        if bitCount > 0 {
            output.append(alphabet[Int((accumulator << (5 - bitCount)) & 0x1f)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func expectManifestError(
        _ expected: TorrentManifestError,
        _ operation: () throws -> Void
    ) throws {
        do {
            try operation()
            Issue.record("Expected \(expected)")
        } catch let error as TorrentManifestError {
            #expect(error == expected)
        }
    }
}

private indirect enum TestBencode {
    case integer(Int64)
    case bytes(Data)
    case list([TestBencode])
    case dictionary([(Data, TestBencode)])

    static func string(_ value: String) -> Self {
        .bytes(Data(value.utf8))
    }

    func encoded(sortedDictionaries: Bool = true) -> Data {
        var output = Data()
        encode(into: &output, sortedDictionaries: sortedDictionaries)
        return output
    }

    private func encode(into output: inout Data, sortedDictionaries: Bool) {
        switch self {
        case .integer(let value):
            output.append(Data("i\(value)e".utf8))
        case .bytes(let bytes):
            output.append(Data("\(bytes.count):".utf8))
            output.append(bytes)
        case .list(let values):
            output.append(UInt8(ascii: "l"))
            for value in values {
                value.encode(into: &output, sortedDictionaries: sortedDictionaries)
            }
            output.append(UInt8(ascii: "e"))
        case .dictionary(let entries):
            output.append(UInt8(ascii: "d"))
            let ordered = sortedDictionaries
                ? entries.sorted { $0.0.lexicographicallyPrecedes($1.0) }
                : entries
            for (key, value) in ordered {
                TestBencode.bytes(key).encode(
                    into: &output,
                    sortedDictionaries: sortedDictionaries
                )
                value.encode(into: &output, sortedDictionaries: sortedDictionaries)
            }
            output.append(UInt8(ascii: "e"))
        }
    }
}
