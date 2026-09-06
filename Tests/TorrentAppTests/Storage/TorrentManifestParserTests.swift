import CryptoKit
import Foundation
import Testing
import TorrentEngineModel
import TorrentMetainfo
import TorrentStorageAuthority
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

    @Test("V2 single-file names retain the leaf bytes across equivalent hybrid layouts", arguments: [
        ("A.bin", "a.bin"),
        ("\u{e9}.bin", "e\u{301}.bin"),
        ("e\u{301}.bin", "\u{e9}.bin"),
    ], [false, true])
    func singleFileNamesUseLeafBytes(names: (String, String), includesV1: Bool) throws {
        let (wireName, leafName) = names
        let info = Self.v2Info(name: wireName, path: leafName, size: 3, includesV1: includesV1)
        let parsed = try TorrentManifestParser().parse(Self.torrent(info: info))
        let bare = try TorrentMetainfoParser().parseInfoDictionary(info.encoded())

        #expect(parsed.manifest.contentKind == .singleFile)
        #expect(Data(parsed.manifest.name.utf8) == Data(leafName.utf8))
        #expect(Data(parsed.infoCore.effectiveName.utf8) == Data(leafName.utf8))
        #expect(Data(bare.infoCore.effectiveName.utf8) == Data(leafName.utf8))
        #expect(parsed.infoCore.wireName.map { Data($0.utf8) } == Data(wireName.utf8))
        #expect(Data(parsed.manifest.files[0].pathComponents[0].utf8) == Data(leafName.utf8))
        #expect(parsed.manifest.files.filter(\.isPadding).count == (includesV1 ? 0 : 1))
        #expect(parsed.rawInfoDictionary == info.encoded())
        #expect(parsed.infoCore.v2InfoHash == Data(SHA256.hash(data: info.encoded())))
        #expect(parsed.infoCore.v1InfoHash == (includesV1
            ? Data(Insecure.SHA1.hash(data: info.encoded())) : nil))
    }

    @Test("A pure-v2 advisory name may differ from its leaf while hybrid paths must agree")
    func distinguishesAdvisoryNamesFromHybridPaths() throws {
        let info = Self.v2Info(name: "Display Name", path: "payload.bin", size: 16_384, includesV1: false)
        let parsed = try TorrentManifestParser().parse(Self.torrent(info: info))
        #expect(parsed.infoCore.wireName == "Display Name")
        #expect(parsed.manifest.name == "payload.bin")
        #expect(parsed.manifest.contentKind == .singleFile)
        #expect(parsed.manifest.files[0].pathComponents == ["payload.bin"])

        try expectManifestError(.inconsistentHybridLayout) {
            _ = try TorrentManifestParser().parse(Self.torrent(info: Self.v2Info(
                name: "Display Name", path: "payload.bin", size: 16_384, includesV1: true
            )))
        }
    }

    @Test("Shared metainfo core retains exact hash-defining ranges")
    func retainsExactCoreRanges() throws {
        let v1Metadata = Self.v1SingleFile(name: "sample.bin", size: 5)
        let v1 = try TorrentManifestParser().parse(v1Metadata)
        #expect(v1.infoCore.kind == .v1)
        #expect(v1.infoCore.contentKind == .singleFile)
        #expect(v1.infoCore.wireName == "sample.bin")
        #expect(v1.infoCore.effectiveName == v1.manifest.name)
        #expect(Data(v1.metadata[v1.infoCore.infoDictionaryRange.range])
            == v1.rawInfoDictionary)
        let v1HashesRange = try #require(v1.infoCore.v1PieceHashesRange)
        #expect(Data(v1.metadata[v1HashesRange.range])
            == Data(repeating: 0x11, count: Insecure.SHA1.byteCount))

        let fixture = Self.v2PieceLayerFixture()
        let v2 = try TorrentMetainfoParser().parse(fixture.metadata)
        #expect(v2.infoCore.kind == .v2)
        #expect(v2.infoCore.v1PieceHashesRange == nil)
        #expect(v2.infoCore.files.map(\.index) == [0])
        #expect(v2.infoCore.files[0].isExecutable)
        #expect(v2.infoCore.files[0].isHidden)
        let rootRange = try #require(v2.infoCore.files[0].piecesRootRange)
        #expect(Data(v2.metadata[rootRange.range]) == fixture.root)
        let layer = try #require(v2.envelope.pieceLayers.first)
        #expect(Data(v2.metadata[layer.piecesRootRange.range]) == fixture.root)
        #expect(Data(v2.metadata[layer.hashesRange.range]) == fixture.hashes)
        #expect(layer.fileIndices == [0])
    }

    @Test("Bare BEP 9 info dictionaries use the same shared core parser")
    func parsesBareInfoDictionary() throws {
        let fixture = Self.v2PieceLayerFixture()
        let local = try TorrentMetainfoParser().parse(fixture.metadata)
        let infoBytes = Data(local.infoDictionary)
        let advertised = try TorrentAdvertisedInfoHashes(
            v2: local.infoCore.v2InfoHash
        )

        let swarm = try TorrentMetainfoParser().parseInfoDictionary(
            infoBytes,
            advertisedHashes: advertised
        )
        #expect(swarm.infoCore.infoDictionaryRange.range == infoBytes.indices)
        #expect(swarm.infoDictionary == infoBytes)
        #expect(swarm.infoCore.kind == local.infoCore.kind)
        #expect(swarm.infoCore.effectiveName == local.infoCore.effectiveName)
        #expect(swarm.infoCore.pieceLength == local.infoCore.pieceLength)
        #expect(swarm.infoCore.totalSize == local.infoCore.totalSize)
        #expect(swarm.infoCore.v2InfoHash == local.infoCore.v2InfoHash)
        #expect(swarm.infoCore.files.map(\.pathComponents)
            == local.infoCore.files.map(\.pathComponents))
        let rootRange = try #require(swarm.infoCore.files[0].piecesRootRange)
        #expect(Data(swarm.bytes[rootRange.range]) == fixture.root)

        var wrapped = Data("prefix".utf8)
        wrapped.append(fixture.info.encoded())
        wrapped.append(Data("suffix".utf8))
        let slicedInfo = wrapped[6..<(wrapped.count - 6)]
        #expect(slicedInfo.startIndex == 6)
        let sliced = try TorrentMetainfoParser().parseInfoDictionary(slicedInfo)
        #expect(sliced.bytes.startIndex == 0)
        #expect(sliced.infoCore.infoDictionaryRange.range == sliced.bytes.indices)
        #expect(sliced.infoCore.v2InfoHash == local.infoCore.v2InfoHash)
    }

    @Test("Envelope records field presence and bounded descriptive metadata")
    func parsesEnvelopeMetadataAndPresence() throws {
        let metadata = Self.torrent(
            info: Self.v1SingleFileInfo(name: "sample.bin", size: 5),
            topLevel: [
                Self.key("announce", .string("https://tracker.example/announce")),
                Self.key("announce-list", .list([])),
                Self.key("comment", .string("fallback comment")),
                Self.key("comment.utf-8", .string("")),
                Self.key("created by", .string("Torrent fixture")),
                Self.key("creation date", .integer(1_700_000_000)),
                Self.key("nodes", .list([])),
                Self.key("url-list", .list([])),
            ]
        )

        let envelope = try TorrentManifestParser().parse(metadata).envelope
        #expect(envelope.presentFields.contains(.announce))
        #expect(envelope.presentFields.contains(.announceList))
        #expect(envelope.presentFields.contains(.urlList))
        #expect(envelope.presentFields.contains(.comment))
        #expect(envelope.presentFields.contains(.createdBy))
        #expect(envelope.presentFields.contains(.creationDate))
        #expect(envelope.presentFields.contains(.dhtNodes))
        #expect(!envelope.presentFields.contains(.pieceLayers))
        #expect(envelope.comment == "fallback comment")
        #expect(envelope.createdBy == "Torrent fixture")
        #expect(envelope.creationDate == 1_700_000_000)
        #expect(envelope.hasIgnoredDHTNodesField)
    }

    @Test("Supplied v2 piece layers must be complete and root-valid")
    func validatesPieceLayers() throws {
        let fixture = Self.v2PieceLayerFixture()
        let parsed = try TorrentManifestParser().parse(fixture.metadata)
        #expect(parsed.envelope.presentFields.contains(.pieceLayers))
        #expect(parsed.envelope.pieceLayers.count == 1)

        let sharedFixture = Self.v2PieceLayerFixture(fileNames: ["a.bin", "b.bin"])
        let shared = try TorrentManifestParser().parse(sharedFixture.metadata)
        #expect(shared.envelope.pieceLayers.count == 1)
        #expect(shared.envelope.pieceLayers[0].fileIndices == [0, 1])

        let absent = Self.torrent(info: fixture.info)
        let parsedAbsent = try TorrentManifestParser().parse(absent)
        #expect(parsedAbsent.envelope.pieceLayers.isEmpty)
        #expect(!parsedAbsent.envelope.presentFields.contains(.pieceLayers))

        try expectManifestError(.invalidPieceLayers) {
            _ = try TorrentManifestParser().parse(Self.torrent(
                info: fixture.info,
                topLevel: [Self.key("piece layers", .dictionary([]))]
            ))
        }
        try expectManifestError(.invalidPieceLayers) {
            var wrongHashes = fixture.hashes
            wrongHashes[0] ^= 1
            _ = try TorrentManifestParser().parse(Self.torrent(
                info: fixture.info,
                topLevel: [(
                    Data("piece layers".utf8),
                    .dictionary([(fixture.root, .bytes(wrongHashes))])
                )]
            ))
        }
        try expectManifestError(.invalidPieceLayers) {
            _ = try TorrentManifestParser().parse(Self.torrent(
                info: fixture.info,
                topLevel: [(
                    Data("piece layers".utf8),
                    .dictionary([(
                        Data(repeating: 0x99, count: SHA256.byteCount),
                        .bytes(fixture.hashes)
                    )])
                )]
            ))
        }
    }

    @Test("Empty v2 files do not retain semantically meaningless roots")
    func ignoresEmptyFilePiecesRoot() throws {
        let emptyRoot = Data(repeating: 0xaa, count: SHA256.byteCount)
        let payloadRoot = Data(repeating: 0xbb, count: SHA256.byteCount)
        let info = TestBencode.dictionary([
            Self.key("file tree", .dictionary([
                Self.key("empty.bin", .dictionary([
                    (Data(), .dictionary([
                        Self.key("length", .integer(0)),
                        Self.key("pieces root", .bytes(emptyRoot)),
                    ]))
                ])),
                Self.key("payload.bin", .dictionary([
                    (Data(), .dictionary([
                        Self.key("length", .integer(1)),
                        Self.key("pieces root", .bytes(payloadRoot)),
                    ]))
                ])),
            ])),
            Self.key("meta version", .integer(2)),
            Self.key("name", .string("payload")),
            Self.key("piece length", .integer(16_384)),
        ])

        let parsed = try TorrentMetainfoParser().parse(Self.torrent(info: info))
        #expect(parsed.infoCore.files[0].expectedSize == 0)
        #expect(parsed.infoCore.files[0].piecesRootRange == nil)
        let payloadRange = try #require(parsed.infoCore.files[1].piecesRootRange)
        #expect(Data(parsed.metadata[payloadRange.range]) == payloadRoot)
    }

    @Test("Swift preview uses the validated manifest and source envelope")
    func buildsSwiftPreview() throws {
        let metadata = Self.torrent(
            info: Self.v1SingleFileInfo(name: "sample.bin", size: 5),
            topLevel: [
                Self.key("announce", .string("udp://fallback.example:80/announce")),
                Self.key("announce-list", .list([
                    .list([.string("https://tracker.example/announce")]),
                    .list([.string("udp://tracker.example:80/announce")]),
                    .list([.string("ftp://ignored.example/announce")]),
                ])),
                Self.key("url-list", .list([
                    .string("https://seed.example/sample.bin"),
                    .string("http://seed.example/sample.bin"),
                    .string("https://seed.example/sample.bin"),
                ])),
            ]
        )

        let parsed = try TorrentManifestParser().parse(metadata)
        let preview = parsed.filePreview(torrentData: metadata)

        #expect(parsed.envelope.trackers == [
            TorrentMetainfoTracker(
                url: "https://tracker.example/announce",
                tier: 0
            ),
            TorrentMetainfoTracker(
                url: "udp://tracker.example:80/announce",
                tier: 1
            ),
        ])
        #expect(parsed.envelope.webSeeds == [
            "https://seed.example/sample.bin",
            "http://seed.example/sample.bin",
        ])
        #expect(!parsed.isPrivate)
        #expect(preview.name == "sample.bin")
        #expect(preview.id.hasPrefix("v1:"))
        #expect(preview.totalSize == 5)
        #expect(preview.sourceSecuritySummary == TorrentSourceSecuritySummary(
            trackerCount: 2,
            httpsTrackerCount: 1,
            webSeedCount: 2,
            httpsWebSeedCount: 1
        ))
        #expect(preview.files.map(\.path) == ["sample.bin"])
        #expect(preview.torrentData == metadata)
    }

    @Test("Source envelopes omit malformed IPv6 while retaining valid dotted tails")
    func ipv6SourceEnvelopeSyntax() throws {
        let validSource = "https://[::ffff:192.0.2.1]/content"
        let invalidSources = ["https://[192.0.2.1::]/content", "https://[192.0.2.1::198.51.100.1]/content"]
        let sources = (invalidSources + [validSource]).map(TestBencode.string)
        let parsed = try TorrentManifestParser().parse(Self.torrent(
            info: Self.v1SingleFileInfo(name: "sample.bin", size: 5),
            topLevel: [
                Self.key("announce-list", .list([.list(sources)])),
                Self.key("url-list", .list(sources)),
            ]
        ))
        #expect(parsed.envelope.trackers.map(\.url) == [validSource])
        #expect(parsed.envelope.webSeeds == [validSource])
    }

    @Test("Source envelope parsing enforces independent resource limits")
    func sourceEnvelopeLimits() throws {
        let info = Self.v1SingleFileInfo(
            name: "private.bin",
            size: 5,
            isPrivate: true
        )
        let twoTrackers = Self.torrent(
            info: info,
            topLevel: [Self.key("announce-list", .list([
                .list([.string("https://one.example/announce")]),
                .list([.string("https://two.example/announce")]),
            ]))]
        )
        var limits = TorrentManifestParser.Limits.standard
        limits.maximumTrackerCount = 1
        try expectManifestError(.tooManyTrackers) {
            _ = try TorrentManifestParser(limits: limits).parse(twoTrackers)
        }

        limits = .standard
        limits.maximumTrackerTierCount = 1
        try expectManifestError(.tooManyTrackers) {
            _ = try TorrentManifestParser(limits: limits).parse(twoTrackers)
        }

        let fallbackTracker = Self.torrent(
            info: info,
            topLevel: [Self.key(
                "announce",
                .string("https://fallback.example/announce")
            )]
        )
        limits = .standard
        limits.maximumTrackerCount = 0
        try expectManifestError(.tooManyTrackers) {
            _ = try TorrentManifestParser(limits: limits).parse(fallbackTracker)
        }

        let oversizedSource = Self.torrent(
            info: info,
            topLevel: [Self.key(
                "url-list",
                .string("https://seed.example/private.bin")
            )]
        )
        limits = .standard
        limits.maximumSourceURLBytes = 8
        try expectManifestError(.invalidSourceURL) {
            _ = try TorrentManifestParser(limits: limits).parse(oversizedSource)
        }

        let parsed = try TorrentManifestParser().parse(Self.torrent(info: info))
        #expect(parsed.isPrivate)
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

    @Test("Path components reject every native-invalid control byte")
    func rejectsControlBytesInPaths() throws {
        let controlBytes = Array(UInt8(0)...UInt8(0x1f)) + [UInt8(0x7f)]
        for byte in controlBytes {
            let control = String(decoding: [byte], as: UTF8.self)
            let component = "unsafe\(control)name"
            #expect(!TorrentPathComponentValidation.isSafe(component))

            try expectManifestError(.invalidName) {
                _ = try TorrentManifestParser().parse(
                    Self.v1SingleFile(name: component, size: 1)
                )
            }
            try expectManifestError(.invalidFilePath) {
                _ = try TorrentManifestParser().parse(Self.v1Directory(
                    name: "payload",
                    files: [.init(path: [component], size: 1)]
                ))
            }
        }
    }

    @Test("Synthetic padding paths participate in collision validation")
    func rejectsPaddingPathCollisions() throws {
        try expectManifestError(.duplicatePath) {
            _ = try TorrentManifestParser().parse(Self.v1Directory(
                name: "payload",
                files: [
                    .init(path: [".pad", "3-1"], size: 1),
                    .init(path: ["ignored"], size: 3, attributes: "p"),
                ]
            ))
        }
        try expectManifestError(.duplicatePath) {
            _ = try TorrentManifestParser().parse(Self.v1Directory(
                name: "payload",
                files: [
                    .init(path: ["ignored"], size: 3, attributes: "p"),
                    .init(path: [".pad", "3-0"], size: 1),
                ]
            ))
        }
        try expectManifestError(.conflictingPath) {
            _ = try TorrentManifestParser().parse(Self.v1Directory(
                name: "payload",
                files: [
                    .init(path: [".pad"], size: 1),
                    .init(path: ["ignored"], size: 3, attributes: "p"),
                ]
            ))
        }
        try expectManifestError(.conflictingPath) {
            _ = try TorrentManifestParser().parse(Self.v1Directory(
                name: "payload",
                files: [
                    .init(path: ["ignored"], size: 3, attributes: "p"),
                    .init(path: [".pad", "3-0", "child"], size: 1),
                ]
            ))
        }
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

        let descriptor = try ParsedMagnet.parse(magnet)
        #expect(try descriptor.storageInfoHashes == original.manifest.infoHashes)
        #expect(descriptor.trackers.map(\.url) == [
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
        let descriptor = try ParsedMagnet.parse(
            "magnet:?xt=urn:btih:\(Self.base32(v1).lowercased())"
        )

        #expect(descriptor.v1InfoHash == v1)
        #expect(descriptor.v2InfoHash == nil)
    }

    @Test("Magnet descriptors reject conflicting exact topics")
    func magnetDescriptorsRejectConflictingExactTopics() throws {
        let first = String(repeating: "0", count: 40)
        let second = String(repeating: "1", count: 40)

        #expect(throws: ParsedMagnetError.conflictingInfoHashes) {
            _ = try ParsedMagnet.parse(
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

        for (first, second) in [
            ("stra\u{00df}e.txt", "strasse.txt"),
            ("\u{03c2}.txt", "\u{03c3}.txt"),
            ("\u{fb00}.txt", "ff.txt"),
        ] {
            try expectManifestError(.duplicatePath) {
                _ = try TorrentManifestParser().parse(Self.v1Directory(
                    name: "payload",
                    files: [
                        .init(path: [first], size: 1),
                        .init(path: [second], size: 1),
                    ]
                ))
            }
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
        try expectManifestError(.conflictingPath) {
            _ = try TorrentManifestParser().parse(Self.v1Directory(
                name: "payload",
                files: [
                    .init(path: ["node", "child"], size: 1),
                    .init(path: ["node"], size: 1),
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

        limits = .standard
        limits.maximumPathComponentCount = 1
        try expectManifestError(.workLimitExceeded) {
            _ = try TorrentManifestParser(limits: limits).parse(Self.v1Directory(
                name: "payload",
                files: [.init(path: ["directory", "file.bin"], size: 1)]
            ))
        }

        limits = .standard
        limits.maximumStoragePathBytes = 20
        try expectManifestError(.invalidFilePath) {
            _ = try TorrentManifestParser(limits: limits).parse(Self.v1Directory(
                name: "payload",
                files: [.init(path: ["directory", "file.bin"], size: 1)]
            ))
        }

        limits = .standard
        limits.maximumFileBytes = 4
        try expectManifestError(.invalidFileLength) {
            _ = try TorrentManifestParser(limits: limits).parse(
                Self.v2SingleFile(name: "sample.bin", size: 5)
            )
        }

        limits = .standard
        limits.maximumPayloadBytes = 4
        try expectManifestError(.invalidFileLength) {
            _ = try TorrentManifestParser(limits: limits).parse(
                Self.v2SingleFile(name: "sample.bin", size: 5)
            )
        }

        try expectManifestError(.invalidFileLength) {
            _ = try TorrentManifestParser().parse(Self.v2SingleFile(
                name: "oversized.bin",
                size: TorrentMetainfoParser.Limits.nativeMaximumFileBytes + 1
            ))
        }

        limits = .standard
        limits.maximumPieceCount = 0
        try expectManifestError(.workLimitExceeded) {
            _ = try TorrentManifestParser(limits: limits).parse(
                Self.v1SingleFile(name: "sample.bin", size: 5)
            )
        }

        let layered = Self.v2PieceLayerFixture()
        limits = .standard
        limits.maximumPieceLayerBytes = SHA256.byteCount * 2
        try expectManifestError(.workLimitExceeded) {
            _ = try TorrentManifestParser(limits: limits).parse(layered.metadata)
        }

        let sourced = Self.torrent(
            info: Self.v1SingleFileInfo(name: "sample.bin", size: 5),
            topLevel: [Self.key(
                "announce",
                .string("https://tracker.example/announce")
            )]
        )
        limits = .standard
        limits.maximumAggregateSourceBytes = 8
        try expectManifestError(.workLimitExceeded) {
            _ = try TorrentManifestParser(limits: limits).parse(sourced)
        }
    }

    @Test("Unsupported metainfo features and invalid descriptions are distinct")
    func rejectsUnsupportedFeatures() throws {
        try expectManifestError(.unsupportedSSLTorrent) {
            _ = try TorrentManifestParser().parse(Self.torrent(
                info: Self.v1SingleFileInfo(
                    name: "sample.bin",
                    size: 5,
                    extra: [Self.key("ssl-cert", .string("certificate"))]
                )
            ))
        }
        try expectManifestError(.unsupportedMutableTorrent) {
            _ = try TorrentManifestParser().parse(Self.torrent(
                info: Self.v1SingleFileInfo(name: "sample.bin", size: 5),
                topLevel: [Self.key("similar", .list([]))]
            ))
        }
        try expectManifestError(.invalidHumanReadableField) {
            _ = try TorrentManifestParser().parse(Self.torrent(
                info: Self.v1SingleFileInfo(name: "sample.bin", size: 5),
                topLevel: [Self.key("comment", .string("unsafe\u{0001}comment"))]
            ))
        }
    }

    @Test("Metainfo parsing observes cancellation")
    func observesCancellation() {
        enum Cancelled: Error, Equatable {
            case requested
        }

        #expect(throws: Cancelled.requested) {
            _ = try TorrentManifestParser().parse(
                Self.v1SingleFile(name: "sample.bin", size: 5),
                checkCancellation: { throw Cancelled.requested }
            )
        }
    }

    private struct V1File {
        let path: [String]
        let size: Int64
        var attributes: String?
    }

    private struct V2PieceLayerFixture {
        let info: TestBencode
        let metadata: Data
        let root: Data
        let hashes: Data
    }

    private static func v1SingleFile(name: String, size: Int64) -> Data {
        torrent(info: v1SingleFileInfo(name: name, size: size))
    }

    private static func v1SingleFileInfo(
        name: String,
        size: Int64,
        isPrivate: Bool = false,
        extra: [(Data, TestBencode)] = []
    ) -> TestBencode {
        var values = [
            key("length", .integer(size)),
            key("name", .string(name)),
            key("piece length", .integer(16_384)),
            key("pieces", .bytes(Data(repeating: 0x11, count: 20)))
        ]
        if isPrivate {
            values.append(key("private", .integer(1)))
        }
        values.append(contentsOf: extra)
        return .dictionary(values)
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

    private static func v2PieceLayerFixture(
        fileNames: [String] = ["layered.bin"]
    ) -> V2PieceLayerFixture {
        let pieceLength: Int64 = 32 * 1_024
        let pieceHashes = [
            Data(repeating: 0x11, count: SHA256.byteCount),
            Data(repeating: 0x22, count: SHA256.byteCount),
            Data(repeating: 0x33, count: SHA256.byteCount),
        ]
        let piecePadding = sha256Pair(
            Data(repeating: 0, count: SHA256.byteCount),
            Data(repeating: 0, count: SHA256.byteCount)
        )
        let root = sha256Pair(
            sha256Pair(pieceHashes[0], pieceHashes[1]),
            sha256Pair(pieceHashes[2], piecePadding)
        )
        let hashes = pieceHashes.reduce(into: Data()) { $0.append($1) }
        let fileTree = fileNames.map { fileName in
            key(fileName, .dictionary([
                (Data(), .dictionary([
                    key("attr", .string("hx")),
                    key("length", .integer(pieceLength * 3)),
                    key("pieces root", .bytes(root)),
                ]))
            ]))
        }
        let info = TestBencode.dictionary([
            key("file tree", .dictionary(fileTree)),
            key("meta version", .integer(2)),
            key("name", .string(fileNames.count == 1 ? fileNames[0] : "payload")),
            key("piece length", .integer(pieceLength)),
        ])
        let metadata = torrent(
            info: info,
            topLevel: [(
                Data("piece layers".utf8),
                .dictionary([(root, .bytes(hashes))])
            )]
        )
        return V2PieceLayerFixture(
            info: info,
            metadata: metadata,
            root: root,
            hashes: hashes
        )
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

    private static func torrent(
        info: TestBencode,
        topLevel: [(Data, TestBencode)] = []
    ) -> Data {
        TestBencode.dictionary(topLevel + [key("info", info)]).encoded()
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

    private static func sha256Pair(_ left: Data, _ right: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: left)
        hasher.update(data: right)
        return Data(hasher.finalize())
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
