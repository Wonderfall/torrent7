import CryptoKit
import Foundation
import Testing
import TorrentAppInfrastructure
import TorrentEngineModel
import TorrentMetainfo
import TorrentStorageAuthority

@Suite("Storage restoration benchmark", .serialized)
struct StorageRestorationBenchmarkTests {
    struct Workload: Sendable {
        let name: String
        let torrentCount: Int
        let filesPerTorrent: Int
        let directoryDepth: Int
    }

    static let workloads: [Workload] = [
        .init(name: "ordinary", torrentCount: 100, filesPerTorrent: 100, directoryDepth: 2),
        .init(name: "file-limit", torrentCount: 1, filesPerTorrent: 20_000, directoryDepth: 2),
        .init(name: "component-limit", torrentCount: 1, filesPerTorrent: 20_000, directoryDepth: 9),
        .init(name: "depth-limit", torrentCount: 1, filesPerTorrent: 6_250, directoryDepth: 31),
        .init(name: "torrent-limit", torrentCount: 20_000, filesPerTorrent: 1, directoryDepth: 0),
        .init(name: "large-library", torrentCount: 1_000, filesPerTorrent: 100, directoryDepth: 2),
        .init(name: "dense-library", torrentCount: 10, filesPerTorrent: 20_000, directoryDepth: 2),
        .init(name: "journal-dense", torrentCount: 28, filesPerTorrent: 20_000, directoryDepth: 2),
        .init(name: "journal-deep", torrentCount: 32, filesPerTorrent: 6_250, directoryDepth: 31),
    ]

    @Test("Opt-in release startup verification timings", arguments: workloads)
    func measure(_ workload: Workload) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_STORAGE_RESTORATION_BENCHMARK"] == "1" else { return }
        if let selected = environment["STORAGE_RESTORATION_WORKLOAD"],
           !selected.isEmpty, selected != workload.name { return }
        let samples = try #require(Int(environment["STORAGE_RESTORATION_SAMPLES"] ?? "5"))
        try #require((1...20).contains(samples))
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Torrent7RestorationBenchmark-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        try emit("preparing \(workload.name)")
        let fixture = try await Self.makeFixture(workload, root: root)
        let claimBytes = try JSONEncoder().encode(Dictionary(
            uniqueKeysWithValues: fixture.claims.map { ($0.manifest.claimID, $0) }
        )).count
        // Leave room for the journal's other fields below its 128 MiB limit.
        try #require(claimBytes < 120 * 1_024 * 1_024)
        let expectedIDs = Set(fixture.claims.map(\.manifest.claimID))
        let clock = ContinuousClock()
        // Characterize valid slow cases beyond the production cutoff. Only the
        // measurement ceiling changes; this calls the actual restoration path.
        let restorer = TorrentStorageRestorer(maximumDuration: .seconds(600))
        var observations = [Double]()
        for sample in 0...samples {
            let start = clock.now
            let restored = try await restorer.restore(leases: [fixture.lease], claims: fixture.claims)
            let elapsed = start.duration(to: clock.now)
            try #require(restored.registry.installedClaimIDs() == expectedIDs)
            try #require(restored.registry.locationsByTorrentID().count == workload.torrentCount)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            observations.append(seconds)
            try emit("\(workload.name) sample=\(sample) seconds=\(seconds)")
        }

        let result = Measurement(
            workload: workload.name,
            torrents: workload.torrentCount,
            files: workload.torrentCount * workload.filesPerTorrent,
            directoryDepth: workload.directoryDepth,
            claimJSONBytes: claimBytes,
            firstPassSeconds: observations[0],
            repeatedPassSeconds: Array(observations.dropFirst())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try emit(String(decoding: encoder.encode(result), as: UTF8.self))
    }

    private struct Fixture: Sendable {
        let lease: DownloadFolderAccessLease
        let claims: [TorrentStorageClaim]
    }

    private struct Measurement: Encodable {
        let workload: String
        let torrents: Int
        let files: Int
        let directoryDepth: Int
        let claimJSONBytes: Int
        let firstPassSeconds: Double
        let repeatedPassSeconds: [Double]
    }

    @concurrent
    private static func makeFixture(_ workload: Workload, root: URL) async throws -> Fixture {
        let limits = TorrentMetainfoParser.Limits.standard
        try #require((1...TorrentEngineLimits.maximumTorrentSnapshotCount).contains(workload.torrentCount))
        let lease = DownloadFolderAccessLease(access: FakeDownloadFolderAccess(url: root))
        let parent = try TorrentStorageParentAuthority(lease: lease)
        let planner = TorrentStorageDestinationPlanner()
        var claims = [TorrentStorageClaim]()
        for torrent in 0..<workload.torrentCount {
            try Task.checkCancellation()
            let name = "torrent-\(torrent)"
            let kind: TorrentStorageContentKind = workload.filesPerTorrent == 1 ? .singleFile : .directory
            let files = (0..<workload.filesPerTorrent).map { index in
                let directories = (0..<workload.directoryDepth).map { level in
                    level == 0 ? "group-\(index / 100)" : "level-\(level)"
                }
                return TorrentLogicalFile(
                    index: Int32(index),
                    pathComponents: directories + [kind == .singleFile ? name : "file-\(index).bin"],
                    expectedSize: 16 * 1_024 * 1_024,
                    isPadding: false
                )
            }
            // Mirror the admitted metainfo workload bounds, not just the
            // authority validator, which also accepts internal fixture values.
            try #require(files.count <= limits.maximumFileCount)
            try #require(files.allSatisfy { $0.pathComponents.count <= limits.maximumPathDepth })
            try #require(files.reduce(0) { $0 + $1.pathComponents.count }
                <= limits.maximumPathComponentCount)
            let pieceLength: Int64 = 1_048_576
            let payloadBytes = files.reduce(Int64(0)) { $0 + $1.expectedSize }
            try #require((payloadBytes + pieceLength - 1) / pieceLength <= Int64(limits.maximumPieceCount))
            let hashes = try TorrentStorageInfoHashes(
                v1: Data(SHA256.hash(data: Data(name.utf8)).prefix(20)), v2: nil
            )
            let manifest = TorrentLogicalManifest(
                name: name, contentKind: kind, infoHashes: hashes,
                pieceLength: pieceLength, files: files,
                sourceManifestDigest: TorrentManifestDigest.source(
                    name: name, contentKind: kind, infoHashes: hashes,
                    pieceLength: pieceLength, files: files
                )
            )
            let reservation = try planner.reserve(
                manifest: manifest, in: parent, claimID: UUID(), generation: 1,
                ownershipKey: TorrentStorageDestinationPlanner.randomOwnershipKey()
            )
            claims.append(TorrentStorageClaim(
                manifest: reservation.storageManifest,
                lease: TorrentStorageLease(
                    state: .active,
                    availabilityRevision: reservation.initialLease.availabilityRevision,
                    fileAvailability: reservation.initialLease.fileAvailability
                ),
                torrentID: name, operationNonce: UUID(),
                removalIntent: nil, deletionEvidence: nil
            ))
        }
        return Fixture(lease: lease, claims: claims)
    }

    private func emit(_ message: String) throws {
        try FileHandle.standardOutput.write(contentsOf: Data("STORAGE_RESTORATION \(message)\n".utf8))
    }
}
