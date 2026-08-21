import Foundation
import Testing
@testable import TorrentApp

@MainActor
@Suite("Torrent file location service", .serialized)
struct TorrentFileLocationServiceTests {
    @Test("Reveals the collision-selected claimed payload instead of the engine save path")
    func revealsClaimedTopLevelPayload() async throws {
        try await withTemporaryDirectory { root in
            let downloads = root.appending(
                path: "Downloads",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: downloads,
                withIntermediateDirectories: true
            )
            try Data("foreign".utf8).write(
                to: downloads.appending(path: "sample.bin")
            )
            let fixture = try makeLocation(
                downloads: downloads,
                name: "sample.bin",
                contentKind: .singleFile,
                files: [.init(
                    index: 0,
                    pathComponents: ["sample.bin"],
                    expectedSize: 16,
                    isPadding: false
                )]
            )

            let revealed = try await TorrentFileLocationService().revealURL(
                for: fixture.location,
                fileIndex: nil
            )

            #expect(revealed?.path(percentEncoded: false)
                == downloads.appending(path: "sample 2.bin").path(percentEncoded: false))
            #expect(fixture.location.displayPath
                == downloads.appending(path: "sample 2.bin").path(percentEncoded: false))
        }
    }

    @Test("Reveals a file by claimed file index")
    func revealsClaimedFileIndex() async throws {
        try await withTemporaryDirectory { root in
            let downloads = root.appending(
                path: "Downloads",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: downloads,
                withIntermediateDirectories: true
            )
            let fixture = try makeLocation(
                downloads: downloads,
                name: "Videos",
                contentKind: .directory,
                files: [.init(
                    index: 0,
                    pathComponents: ["Season 1", "episode.mkv"],
                    expectedSize: 16,
                    isPadding: false
                )]
            )

            let revealed = try await TorrentFileLocationService().revealURL(
                for: fixture.location,
                fileIndex: 0
            )

            #expect(revealed?.path(percentEncoded: false) == downloads
                .appending(path: "Videos", directoryHint: .isDirectory)
                .appending(path: "Season 1", directoryHint: .isDirectory)
                .appending(path: "episode.mkv")
                .path(percentEncoded: false))
        }
    }

    @Test("A substituted file is not revealed")
    func substitutedFileFallsBackToClaimRoot() async throws {
        try await withTemporaryDirectory { root in
            let downloads = root.appending(
                path: "Downloads",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: downloads,
                withIntermediateDirectories: true
            )
            let fixture = try makeLocation(
                downloads: downloads,
                name: "Bundle",
                contentKind: .directory,
                files: [.init(
                    index: 0,
                    pathComponents: ["payload.bin"],
                    expectedSize: 16,
                    isPadding: false
                )]
            )
            let payload = downloads
                .appending(path: "Bundle", directoryHint: .isDirectory)
                .appending(path: "payload.bin")
            try FileManager.default.removeItem(at: payload)
            try Data().write(to: payload)

            let revealed = try await TorrentFileLocationService().revealURL(
                for: fixture.location,
                fileIndex: 0
            )

            #expect(revealed?.path(percentEncoded: false)
                == fixture.location.displayPath)
        }
    }

    @Test("A substituted claim root fails closed")
    func substitutedRootFailsClosed() async throws {
        try await withTemporaryDirectory { root in
            let downloads = root.appending(
                path: "Downloads",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: downloads,
                withIntermediateDirectories: true
            )
            let fixture = try makeLocation(
                downloads: downloads,
                name: "payload.bin",
                contentKind: .singleFile,
                files: [.init(
                    index: 0,
                    pathComponents: ["payload.bin"],
                    expectedSize: 16,
                    isPadding: false
                )]
            )
            let payload = fixture.location.displayURL
            try FileManager.default.removeItem(at: payload)
            try Data().write(to: payload)

            await #expect(throws: TorrentStoragePlanningError.self) {
                _ = try await TorrentFileLocationService().revealURL(
                    for: fixture.location,
                    fileIndex: nil
                )
            }
        }
    }

    @Test("Batch resolution deduplicates claimed locations")
    func batchResolutionDeduplicatesLocations() async throws {
        try await withTemporaryDirectory { root in
            let downloads = root.appending(
                path: "Downloads",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: downloads,
                withIntermediateDirectories: true
            )
            let fixture = try makeLocation(
                downloads: downloads,
                name: "payload.bin",
                contentKind: .singleFile,
                files: [.init(
                    index: 0,
                    pathComponents: ["payload.bin"],
                    expectedSize: 16,
                    isPadding: false
                )]
            )

            let urls = try await TorrentFileLocationService().revealURLs(
                for: [fixture.location, fixture.location]
            )

            #expect(urls.map { $0.path(percentEncoded: false) }
                == [fixture.location.displayPath])
        }
    }

    private struct LocationFixture {
        let location: TorrentStorageLocation
    }

    private enum FixtureError: Error {
        case invalidLocation
    }

    private func makeLocation(
        downloads: URL,
        name: String,
        contentKind: TorrentStorageContentKind,
        files: [TorrentLogicalFile]
    ) throws -> LocationFixture {
        let parent = try TorrentStorageParentAuthority(
            lease: DownloadFolderAccessLease(
                access: FakeDownloadFolderAccess(url: downloads)
            )
        )
        let hashes = try TorrentStorageInfoHashes(
            v1: Data(repeating: 0x55, count: 20),
            v2: nil
        )
        let pieceLength: Int64 = 16_384
        let logical = TorrentLogicalManifest(
            name: name,
            contentKind: contentKind,
            infoHashes: hashes,
            pieceLength: pieceLength,
            files: files,
            sourceManifestDigest: TorrentManifestDigest.source(
                name: name,
                contentKind: contentKind,
                infoHashes: hashes,
                pieceLength: pieceLength,
                files: files
            )
        )
        let planner = TorrentStorageDestinationPlanner()
        let selected = try planner.planTopLevelName(
            for: logical,
            in: parent
        )
        let reservation = try planner.reserve(
            manifest: logical,
            in: parent,
            claimID: UUID(),
            generation: 1,
            ownershipToken:
                TorrentStorageDestinationPlanner.randomOwnershipToken(),
            selectedTopLevelName: selected
        )
        let claim = TorrentStorageClaim(
            manifest: reservation.storageManifest,
            lease: TorrentStorageLease(
                state: .active,
                policyRevision: reservation.initialLease.policyRevision,
                filePolicies: reservation.initialLease.filePolicies
            ),
            torrentID: "t:\(String(repeating: "a", count: 32))",
            operationNonce: UUID()
        )
        guard let location = TorrentStorageLocation(
            claim: claim,
            parent: parent
        ) else {
            throw FixtureError.invalidLocation
        }
        return LocationFixture(location: location)
    }
}
