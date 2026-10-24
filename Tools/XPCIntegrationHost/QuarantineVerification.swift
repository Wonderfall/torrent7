import Darwin
import Foundation
import System
import TorrentAppInfrastructure
import TorrentEngineClient
import TorrentEngineIPC
import TorrentQuarantineProbeSupport
import TorrentStorageAuthority
import XPC

enum QuarantineVerification {
    @concurrent
    static func run() async throws {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appending(path: "Torrent7QuarantineFixtures", directoryHint: .isDirectory)
        // The runner seeds the import in this disposable container before launch.
        // No Powerbox grant is simulated: only this host's private container is used.
        let parent = try TorrentStorageParentAuthority(
            lease: DownloadFolderAccessLease(access: ContainerAccess(url: root))
        )
        let planner = TorrentStorageDestinationPlanner()
        let created = try planner.reserve(
            manifest: manifest(name: "created.bin"), in: parent,
            claimID: UUID(), generation: 1,
            ownershipKey: TorrentStorageDestinationPlanner.randomOwnershipKey()
        )
        let beforeImport = try readAttribute(root.appending(path: "imported.bin"))
        try require(beforeImport == nil, "Runner supplied an already quarantined import")
        let imported = try planner.importExisting(
            manifest: manifest(name: "imported.bin"), in: parent,
            claimID: UUID(), generation: 1
        )
        let claims = [created, imported].map { reservation in
            TorrentStorageClaim(
                manifest: reservation.storageManifest,
                lease: .init(state: .active, availabilityRevision: 1, fileAvailability: [true]),
                torrentID: "fixture", operationNonce: UUID(), removalIntent: nil, deletionEvidence: nil
            )
        }
        let initial = try ["created.bin", "imported.bin"].map { try readAttribute(root.appending(path: $0)) }
        try require(initial[0]?.isEmpty == false, "Created payload has no quarantine attribute")
        print("quarantine.imported.bin.before_import=absent")
        print("quarantine.imported.bin.after_import=\(description(initial[1]))")
        try require(initial[1]?.isEmpty == false, "Writable import did not acquire quarantine")

        let registry = TorrentStorageBrokerRegistry()
        for claim in claims { try registry.install(claim: claim, parent: parent) }
        let configuration = try TorrentEngineXPCIdentity.configuration()
        let broker = try TorrentStorageBrokerServer(registry: registry, engineConfiguration: configuration)
        defer { broker.cancel() }
        let session = try await TorrentEngineExtensionProcessCoordinator.shared.makeSession(
            configuration: configuration, deadline: ContinuousClock.now.advanced(by: .seconds(30))
        )
        defer { session.cancel(reason: "Quarantine verification completed") }
        try session.activate()
        let request = QuarantineProbeRequest(
            endpoint: broker.endpoint, nonce: broker.sessionNonce,
            claims: claims.map(\.manifest.claimID)
        )
        let reply = try await exchange(request, session: session)
        let observations: [QuarantineObservation]
        switch reply {
        case .success(let values): observations = values
        case .failure(let detail): throw QuarantineProbeFailure.failed(detail)
        }
        try require(observations.count == 2, "Missing payload observations")
        for (index, name) in ["created.bin", "imported.bin"].enumerated() {
            let observation = observations[index]
            let url = root.appending(path: name)
            let afterProbe = try readAttribute(url)
            print("quarantine.\(name).before=\(description(initial[index]))")
            print("quarantine.\(name).after_probe=\(description(afterProbe))")
            print("quarantine.\(name).read_errno=\(observation.readError)")
            print("quarantine.\(name).remove_errno=\(observation.removalError)")
            print("quarantine.\(name).overwrite_errno=\(observation.overwriteError)")
            try require(try Data(contentsOf: url) == QuarantineProbe.payload, "Helper did not write \(name)")
            try require([EPERM, EACCES].contains(observation.removalError), "Helper removed quarantine: \(name)")
            try require([EPERM, EACCES].contains(observation.overwriteError), "Helper weakened quarantine: \(name)")
            try require(afterProbe == initial[index], "Host observed changed quarantine: \(name)")
        }
        print("integration.quarantine=pass")
    }

    private static func exchange(
        _ request: QuarantineProbeRequest, session: XPCSession
    ) async throws -> QuarantineProbeReply {
        try await withThrowingTaskGroup(of: QuarantineProbeReply.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    do {
                        try session.send(request) { (result: Result<QuarantineProbeReply, any Error>) in
                            continuation.resume(with: result)
                        }
                    } catch { continuation.resume(throwing: error) }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                session.cancel(reason: "Quarantine probe timed out")
                throw QuarantineProbeFailure.failed("Quarantine probe timed out")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private static func readAttribute(_ url: URL) throws -> Data? {
        let descriptor = try FileDescriptor.open(
            FilePath(url.path(percentEncoded: false)), .readOnly,
            options: [.closeOnExec, .noFollow, .nonBlocking]
        )
        defer { try? descriptor.close() }
        return try QuarantineProbe.read(descriptor.rawValue)
    }

    private static func description(_ data: Data?) -> String {
        data.map { String(decoding: $0, as: UTF8.self) } ?? "absent"
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw QuarantineProbeFailure.failed(message) }
    }

    private static func manifest(name: String) throws -> TorrentLogicalManifest {
        let hashes = try TorrentStorageInfoHashes(v1: Data(repeating: 0x55, count: 20), v2: nil)
        let files = [TorrentLogicalFile(index: 0, pathComponents: [name], expectedSize: 64, isPadding: false)]
        return TorrentLogicalManifest(
            name: name, contentKind: .singleFile, infoHashes: hashes, pieceLength: 16_384,
            files: files, sourceManifestDigest: TorrentManifestDigest.source(
                name: name, contentKind: .singleFile, infoHashes: hashes, pieceLength: 16_384, files: files
            )
        )
    }

    private final class ContainerAccess: DownloadFolderAccessing {
        let url: URL
        init(url: URL) { self.url = url }
        func bookmarkData() throws -> Data { try url.bookmarkData() }
    }
}
