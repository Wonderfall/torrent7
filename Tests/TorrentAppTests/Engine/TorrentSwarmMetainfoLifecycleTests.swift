import CryptoKit
import Darwin
import Foundation
import Testing
import TorrentEngineModel
import TorrentStorageAuthority
@testable import TorrentEngineCore

@Suite("Swift swarm metainfo lifecycle", .serialized)
struct TorrentSwarmMetainfoLifecycleTests {
    @Test("Layered v2 metadata and leaf names survive the real Swift callback and native restart", arguments: [
        ("layered.bin", "layered.bin", false),
        ("A.bin", "a.bin", false),
        ("\u{e9}.bin", "e\u{301}.bin", false),
        ("Display Name", "payload.bin", false),
        ("A.bin", "a.bin", true),
        ("e\u{301}.bin", "\u{e9}.bin", true),
    ])
    func layeredV2MetadataSurvivesRestart(wireName: String, leafName: String, includesV1: Bool) async throws {
        let fixture = layeredV2Torrent(wireName: wireName, leafName: leafName, includesV1: includesV1)
        let stateDirectory = FileManager.default.temporaryDirectory
            .appending(
                path: "TorrentSwarmMetainfoLifecycleTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let manifest = try TorrentManifestParser().parse(fixture.torrent).manifest
        let activation = try TorrentStorageActivation(
            claimID: UUID(),
            generation: 1,
            sourceManifestDigest: manifest.sourceManifestDigest
        )
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: false,
            payloadBroker: SwarmLifecyclePayloadBroker()
        )
        let id = try await engine.addTorrentFile(
            data: fixture.torrent,
            activation: activation,
            startsPaused: true,
            enablePeerExchange: false
        )

        #expect(try await engine.torrentMetadata(id: id) == fixture.info)
        let added = try await engine.snapshots()
        #expect(added.first.map { Data($0.name.utf8) } == Data(leafName.utf8))
        let addedFiles = try #require(await engine.fileBatch(id: id, since: nil))
        #expect(addedFiles.files.map { Data($0.path.utf8) } == [Data(leafName.utf8)])
        try await engine.saveAllChecked()

        // Restart discards the native client. Restoring this torrent requires
        // the production Swift callback because resume data keeps info opaque.
        try await engine.restart(enablePeerExchangePlugin: false)
        let restored = try await engine.snapshots()
        #expect(restored.map(\.id) == [id])
        #expect(restored.first.map { Data($0.name.utf8) } == Data(leafName.utf8))
        let restoredFiles = try #require(await engine.fileBatch(id: id, since: nil))
        #expect(restoredFiles.files.map { Data($0.path.utf8) } == [Data(leafName.utf8)])
        #expect(try await engine.torrentMetadata(id: id) == fixture.info)
        try await engine.saveAllChecked()
        try await engine.shutdownSafely()
    }
}

@safe private final class SwarmLifecyclePayloadBroker: TorrentPayloadBrokerAccess, Sendable {
    nonisolated func openPayload(
        claimID: UUID,
        generation: UInt64,
        fileIndex: Int32,
        writable: Bool
    ) throws -> Int32 {
        throw TorrentPayloadBrokerCallError(errorNumber: ENOENT)
    }

    nonisolated func payloadSize(
        claimID: UUID,
        generation: UInt64,
        fileIndex: Int32
    ) throws -> Int64 {
        throw TorrentPayloadBrokerCallError(errorNumber: ENOENT)
    }
}

private struct LayeredV2TorrentFixture {
    let torrent: Data
    let info: Data
}

private func layeredV2Torrent(wireName: String, leafName: String, includesV1: Bool) -> LayeredV2TorrentFixture {
    let firstPiece = Data(repeating: 0x11, count: SHA256.byteCount)
    let secondPiece = Data(repeating: 0x22, count: SHA256.byteCount)
    let pieceLayer = firstPiece + secondPiece
    let root = Data(SHA256.hash(data: pieceLayer))
    var fields: [(Data, SwarmLifecycleBencode)] = [
        swarmLifecycleKey("file tree", .dictionary([
            swarmLifecycleKey(leafName, .dictionary([
                (Data(), .dictionary([
                    swarmLifecycleKey("length", .integer(32 * 1_024)),
                    swarmLifecycleKey("pieces root", .bytes(root)),
                ]))
            ]))
        ])),
        swarmLifecycleKey("meta version", .integer(2)),
        swarmLifecycleKey("name", .string(wireName)),
        swarmLifecycleKey("piece length", .integer(16 * 1_024)),
    ]
    if includesV1 {
        fields.append(swarmLifecycleKey("length", .integer(32 * 1_024)))
        fields.append(swarmLifecycleKey("pieces", .bytes(Data(repeating: 0x33, count: 40))))
    }
    let infoValue = SwarmLifecycleBencode.dictionary(fields)
    let torrent = SwarmLifecycleBencode.dictionary([
        swarmLifecycleKey("info", infoValue),
        swarmLifecycleKey("piece layers", .dictionary([
            (root, .bytes(pieceLayer))
        ])),
    ]).encoded()
    return LayeredV2TorrentFixture(torrent: torrent, info: infoValue.encoded())
}

private func swarmLifecycleKey(
    _ key: String,
    _ value: SwarmLifecycleBencode
) -> (Data, SwarmLifecycleBencode) {
    (Data(key.utf8), value)
}

private indirect enum SwarmLifecycleBencode {
    case bytes(Data)
    case integer(Int64)
    case list([Self])
    case dictionary([(Data, Self)])

    static func string(_ value: String) -> Self {
        .bytes(Data(value.utf8))
    }

    func encoded() -> Data {
        switch self {
        case .bytes(let value):
            return Data("\(value.count):".utf8) + value
        case .integer(let value):
            return Data("i\(value)e".utf8)
        case .list(let values):
            var result = Data([UInt8(ascii: "l")])
            for value in values {
                result.append(value.encoded())
            }
            result.append(UInt8(ascii: "e"))
            return result
        case .dictionary(let fields):
            var result = Data([UInt8(ascii: "d")])
            for (key, value) in fields.sorted(by: { lhs, rhs in
                lhs.0.lexicographicallyPrecedes(rhs.0)
            }) {
                result.append(Data("\(key.count):".utf8))
                result.append(key)
                result.append(value.encoded())
            }
            result.append(UInt8(ascii: "e"))
            return result
        }
    }
}
