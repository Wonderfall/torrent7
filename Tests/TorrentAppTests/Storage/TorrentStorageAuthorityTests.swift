import Darwin
import CryptoKit
import Foundation
import Testing
import TorrentEngineIPC
@testable import TorrentApp

@MainActor
@Suite("Torrent storage authority", .serialized)
struct TorrentStorageAuthorityTests {
    @Test("The journal records the exact destination before reservation")
    func plannedDestinationPrecedesMutation() async throws {
        try await withTemporaryDirectory { root in
            let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
            let state = root.appending(path: "State", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            try Data("foreign".utf8).write(to: downloads.appending(path: "sample.bin"))

            let parent = try makeParent(downloads)
            let logical = try makeLogicalManifest(
                name: "sample.bin",
                contentKind: .singleFile,
                files: [.init(index: 0, pathComponents: ["sample.bin"], expectedSize: 8, isPadding: false)]
            )
            let planner = TorrentStorageDestinationPlanner()
            let selected = try planner.planTopLevelName(for: logical, in: parent)
            #expect(selected == "sample 2.bin")

            let claimID = UUID()
            let nonce = UUID()
            let token = TorrentStorageDestinationPlanner.randomOwnershipToken()
            let journal = try TorrentStorageClaimJournal(directory: state)
            try await journal.beginPreparation(TorrentStoragePreparation(
                claimID: claimID,
                generation: 1,
                parentAuthorityID: parent.id,
                preferredTopLevelName: logical.name,
                ownershipToken: token,
                operationNonce: nonce,
                reservedTopLevelName: nil
            ))
            try await journal.noteReservation(
                claimID: claimID,
                generation: 1,
                operationNonce: nonce,
                topLevelName: selected
            )
            #expect(await journal.unresolvedPreparations().first?.reservedTopLevelName == selected)
            #expect(!FileManager.default.fileExists(
                atPath: downloads.appending(path: selected).path()
            ))

            let reservation = try planner.reserve(
                manifest: logical,
                in: parent,
                claimID: claimID,
                generation: 1,
                ownershipToken: token,
                selectedTopLevelName: selected
            )
            #expect(reservation.storageManifest.collisionSelectedTopLevelName == selected)
            #expect(try Data(contentsOf: downloads.appending(path: "sample.bin")) == Data("foreign".utf8))
        }
    }

    @Test("A collision race preserves the foreign object and durable preparation")
    func reservationRaceFailsClosed() async throws {
        try await withTemporaryDirectory { root in
            let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
            let state = root.appending(path: "State", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let parent = try makeParent(downloads)
            let logical = try makeLogicalManifest(
                name: "race.bin",
                contentKind: .singleFile,
                files: [.init(index: 0, pathComponents: ["race.bin"], expectedSize: 4, isPadding: false)]
            )
            let planner = TorrentStorageDestinationPlanner()
            let selected = try planner.planTopLevelName(for: logical, in: parent)
            let claimID = UUID()
            let nonce = UUID()
            let token = TorrentStorageDestinationPlanner.randomOwnershipToken()
            let journal = try TorrentStorageClaimJournal(directory: state)
            try await journal.beginPreparation(.init(
                claimID: claimID,
                generation: 1,
                parentAuthorityID: parent.id,
                preferredTopLevelName: logical.name,
                ownershipToken: token,
                operationNonce: nonce,
                reservedTopLevelName: nil
            ))
            try await journal.noteReservation(
                claimID: claimID,
                generation: 1,
                operationNonce: nonce,
                topLevelName: selected
            )
            let foreign = Data("won race".utf8)
            try foreign.write(to: downloads.appending(path: selected))

            #expect(throws: TorrentStoragePlanningError.self) {
                _ = try planner.reserve(
                    manifest: logical,
                    in: parent,
                    claimID: claimID,
                    generation: 1,
                    ownershipToken: token,
                    selectedTopLevelName: selected
                )
            }
            #expect(try Data(contentsOf: downloads.appending(path: selected)) == foreign)
            #expect(await journal.unresolvedPreparations().first?.reservedTopLevelName == selected)
        }
    }

    @Test("Broker opens only the exact claimed inode and enforces policy")
    func brokerEnforcesIdentityAndPolicy() throws {
        try withTemporaryDirectory { root in
            let fixture = try reserveSingleFile(in: root, name: "payload.bin", size: 16)
            var policies = fixture.reservation.initialLease.filePolicies
            policies[0] = TorrentPayloadFilePolicy(
                fileIndex: 0,
                maximumAccess: .unavailable,
                provenance: .appCreated,
                mayModify: true,
                mayDeleteAutomatically: true
            )
            let claim = makeClaim(
                fixture.reservation,
                state: .activating,
                policies: policies
            )
            let registry = TorrentStorageBrokerRegistry()
            try registry.install(parentAuthority: fixture.parent)
            try registry.install(claim: claim)

            #expect(throws: TorrentStorageBrokerRegistryError.accessDenied) {
                _ = try registry.openPayload(
                    claimID: claim.manifest.claimID,
                    generation: claim.manifest.generation,
                    fileIndex: 0,
                    access: .readOnly
                )
            }
            #expect(throws: TorrentStorageBrokerRegistryError.generationMismatch) {
                _ = try registry.openPayload(
                    claimID: claim.manifest.claimID,
                    generation: 2,
                    fileIndex: 0,
                    access: .readOnly
                )
            }
        }
    }

    @Test("Symlink, inode replacement, and hard-link substitution fail closed")
    func brokerRejectsFilesystemSubstitution() throws {
        try withTemporaryDirectory { root in
            try assertSubstitutionRejected(in: root.appending(path: "inode")) { payload, backup in
                try FileManager.default.moveItem(at: payload, to: backup)
                try Data().write(to: payload)
            }
            try assertSubstitutionRejected(in: root.appending(path: "symlink")) { payload, backup in
                try FileManager.default.moveItem(at: payload, to: backup)
                try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: backup)
            }
            try assertSubstitutionRejected(in: root.appending(path: "hardlink")) { payload, backup in
                try FileManager.default.linkItem(at: payload, to: backup)
            }
        }
    }

    @Test("Activation-unknown claims retain exact broker access while awaiting review")
    func activationUnknownClaimsRetainBrokerAccess() throws {
        try withTemporaryDirectory { root in
            let fixture = try reserveSingleFile(
                in: root,
                name: "unresolved.bin",
                size: 16
            )
            let claim = makeClaim(
                fixture.reservation,
                state: .activationUnknown
            )
            let registry = TorrentStorageBrokerRegistry()
            try registry.install(parentAuthority: fixture.parent)
            try registry.install(claim: claim)

            let opened = try registry.openPayload(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation,
                fileIndex: 0,
                access: .readWrite
            )
            defer { _ = Darwin.close(opened.descriptor) }
            #expect(opened.metadata.fileIndex == 0)
            #expect(opened.metadata.size <= 16)
            #expect(try registry.statBatch(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation,
                fileIndices: [0]
            ).count == 1)
        }
    }

    @Test("Padding has synthetic statistics and can never receive an FD")
    func paddingNeverReceivesDescriptor() throws {
        try withTemporaryDirectory { root in
            let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let parent = try makeParent(downloads)
            let logical = try makeLogicalManifest(
                name: "bundle",
                contentKind: .directory,
                files: [
                    .init(index: 0, pathComponents: ["file.bin"], expectedSize: 8, isPadding: false),
                    .init(index: 1, pathComponents: [".pad", "8-1"], expectedSize: 8, isPadding: true),
                ]
            )
            let planner = TorrentStorageDestinationPlanner()
            let selected = try planner.planTopLevelName(for: logical, in: parent)
            let reservation = try planner.reserve(
                manifest: logical,
                in: parent,
                claimID: UUID(),
                generation: 1,
                ownershipToken: TorrentStorageDestinationPlanner.randomOwnershipToken(),
                selectedTopLevelName: selected
            )
            let claim = makeClaim(reservation, state: .active)
            let registry = TorrentStorageBrokerRegistry()
            try registry.install(parentAuthority: parent)
            try registry.install(claim: claim)

            #expect(throws: TorrentStorageBrokerRegistryError.fileUnavailable) {
                _ = try registry.openPayload(
                    claimID: claim.manifest.claimID,
                    generation: 1,
                    fileIndex: 1,
                    access: .readOnly
                )
            }
            let statistics = try registry.statBatch(
                claimID: claim.manifest.claimID,
                generation: 1,
                fileIndices: [0, 1]
            )
            #expect(statistics[1].size == 8)
            #expect(statistics[1].device == 0)
            #expect(statistics[1].inode == 0)
        }
    }

    @Test("GUI deletion requires the recorded inode and ownership marker")
    func deletionRequiresProofOfOwnership() throws {
        try withTemporaryDirectory { root in
            let fixture = try reserveSingleFile(in: root, name: "delete.bin", size: 8)
            let claim = makeClaim(fixture.reservation, state: .deleting)
            let payload = fixture.downloads.appending(path: claim.manifest.collisionSelectedTopLevelName)
            try TorrentStorageDestinationPlanner().deleteOwnedPayload(
                claim: claim,
                from: fixture.parent
            )
            #expect(!FileManager.default.fileExists(atPath: payload.path()))

            let replacement = try reserveSingleFile(in: root, name: "preserve.bin", size: 8)
            let replacementClaim = makeClaim(replacement.reservation, state: .deleting)
            let replacementPath = replacement.downloads.appending(
                path: replacementClaim.manifest.collisionSelectedTopLevelName
            )
            let original = replacement.downloads.appending(path: "original-preserved")
            try FileManager.default.moveItem(at: replacementPath, to: original)
            let foreign = Data("foreign".utf8)
            try foreign.write(to: replacementPath)

            #expect(throws: TorrentStoragePlanningError.self) {
                try TorrentStorageDestinationPlanner().deleteOwnedPayload(
                    claim: replacementClaim,
                    from: replacement.parent
                )
            }
            #expect(try Data(contentsOf: replacementPath) == foreign)
            #expect(FileManager.default.fileExists(atPath: original.path()))
        }
    }

    @Test("Explicit imports pin writable data without claiming deletion ownership")
    func explicitImportPreservesUserOwnedPayload() throws {
        try withTemporaryDirectory { root in
            let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: downloads,
                withIntermediateDirectories: true
            )
            let payload = downloads.appending(path: "sample.bin")
            let original = Data("seed".utf8)
            try original.write(to: payload)
            let parent = try makeParent(downloads)
            let logical = try makeLogicalManifest(
                name: "sample.bin",
                contentKind: .singleFile,
                files: [
                    .init(
                        index: 0,
                        pathComponents: ["sample.bin"],
                        expectedSize: 8,
                        isPadding: false
                    ),
                ]
            )
            let planner = TorrentStorageDestinationPlanner()
            let reservation = try planner.importExisting(
                manifest: logical,
                in: parent,
                claimID: UUID(),
                generation: 1,
                ownershipToken: TorrentStorageDestinationPlanner.randomOwnershipToken(),
                selectedTopLevelName: logical.name
            )
            let policy = try #require(reservation.initialLease.filePolicies.first)
            #expect(policy.maximumAccess == .explicitlyImportedWritable)
            #expect(policy.provenance == .imported)
            #expect(policy.mayModify)
            #expect(!policy.mayDeleteAutomatically)
            #expect(try Data(contentsOf: payload) == original)

            let activeClaim = makeClaim(reservation, state: .active)
            try planner.validateClaimRoot(activeClaim, in: parent)
            let registry = TorrentStorageBrokerRegistry()
            try registry.install(parentAuthority: parent)
            try registry.install(claim: activeClaim)
            let opened = try registry.openPayload(
                claimID: activeClaim.manifest.claimID,
                generation: activeClaim.manifest.generation,
                fileIndex: 0,
                access: .readWrite
            )
            #expect(opened.metadata.size == original.count)
            _ = Darwin.close(opened.descriptor)

            try planner.deleteOwnedPayload(
                claim: makeClaim(reservation, state: .deleting),
                from: parent
            )
            #expect(try Data(contentsOf: payload) == original)
        }
    }

    @Test("Explicit imports reject multiply linked payloads")
    func explicitImportRejectsHardLinks() throws {
        try withTemporaryDirectory { root in
            let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: downloads,
                withIntermediateDirectories: true
            )
            let payload = downloads.appending(path: "sample.bin")
            try Data("seed".utf8).write(to: payload)
            try FileManager.default.linkItem(
                at: payload,
                to: downloads.appending(path: "second-link.bin")
            )
            let parent = try makeParent(downloads)
            let logical = try makeLogicalManifest(
                name: "sample.bin",
                contentKind: .singleFile,
                files: [
                    .init(
                        index: 0,
                        pathComponents: ["sample.bin"],
                        expectedSize: 8,
                        isPadding: false
                    ),
                ]
            )

            #expect(throws: TorrentStoragePlanningError.existingDataUnsafe) {
                _ = try TorrentStorageDestinationPlanner().importExisting(
                    manifest: logical,
                    in: parent,
                    claimID: UUID(),
                    generation: 1,
                    ownershipToken: TorrentStorageDestinationPlanner.randomOwnershipToken(),
                    selectedTopLevelName: logical.name
                )
            }
        }
    }

    @Test("Journal transitions are nonce-bound, durable, and centrally validated")
    func journalTransitionsAreDurable() async throws {
        try await withTemporaryDirectory { root in
            let state = root.appending(path: "State", directoryHint: .isDirectory)
            let fixture = try reserveSingleFile(in: root, name: "journal.bin", size: 8)
            let nonce = UUID()
            let claim = makeClaim(fixture.reservation, state: .reserved, nonce: nonce)
            let preparation = TorrentStoragePreparation(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation,
                parentAuthorityID: claim.manifest.parentAuthorityID,
                preferredTopLevelName: "journal.bin",
                ownershipToken: claim.manifest.ownershipToken,
                operationNonce: nonce,
                reservedTopLevelName: claim.manifest.collisionSelectedTopLevelName
            )
            let journal = try TorrentStorageClaimJournal(directory: state)
            try await journal.beginPreparation(preparation)
            try await journal.commitReserved(claim)
            _ = try await journal.transition(
                claimID: claim.manifest.claimID,
                generation: 1,
                operationNonce: nonce,
                from: [.reserved],
                to: .activating
            )
            await #expect(throws: TorrentStorageJournalError.self) {
                _ = try await journal.transition(
                    claimID: claim.manifest.claimID,
                    generation: 1,
                    operationNonce: UUID(),
                    from: [.activating],
                    to: .active,
                    torrentID: "t:\(String(repeating: "a", count: 32))"
                )
            }
            let active = try await journal.transition(
                claimID: claim.manifest.claimID,
                generation: 1,
                operationNonce: nonce,
                from: [.activating],
                to: .active,
                torrentID: "t:\(String(repeating: "a", count: 32))"
            )
            #expect(active.lease.state == .active)
            await #expect(throws: TorrentStorageJournalError.self) {
                _ = try await journal.transition(
                    claimID: claim.manifest.claimID,
                    generation: 1,
                    operationNonce: UUID(),
                    from: [.active],
                    to: .deleted
                )
            }

            let reloaded = try TorrentStorageClaimJournal(directory: state)
            #expect(await reloaded.claim(id: claim.manifest.claimID)?.lease.state == .active)
            #expect(await reloaded.claim(id: claim.manifest.claimID)?.torrentID == active.torrentID)
        }
    }

    @Test("A corrupt journal is preserved and never guessed")
    func corruptJournalIsPreserved() throws {
        try withTemporaryDirectory { root in
            let state = root.appending(path: "State", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            let journalURL = state.appending(path: "StorageClaims.json")
            let corrupt = Data("{not-json".utf8)
            try corrupt.write(to: journalURL)

            #expect(throws: TorrentStorageJournalError.corrupt) {
                _ = try TorrentStorageClaimJournal(directory: state)
            }
            #expect(try Data(contentsOf: journalURL) == corrupt)
        }
    }

    @Test("Magnet promotion metadata and runtime survive ambiguous outcomes")
    func magnetPromotionIsDurableAndNonceBound() async throws {
        try await withTemporaryDirectory { root in
            let state = root.appending(path: "State", directoryHint: .isDirectory)
            let info = Self.singleFileInfoDictionary()
            let v1 = Data(Insecure.SHA1.hash(data: info))
            let hashes = try TorrentStorageInfoHashes(v1: v1, v2: nil)
            let promotionID = UUID()
            let operationNonce = UUID()
            let torrentID = "t:\(String(repeating: "a", count: 32))"
            let promotion = TorrentMagnetPromotion(
                id: promotionID,
                torrentID: torrentID,
                originalMagnet: "magnet:?xt=urn:btih:\(Self.hex(v1))",
                advertisedInfoHashes: hashes,
                destinationPath: "/Downloads",
                operationNonce: operationNonce,
                state: .awaitingMetadata,
                exactInfoDictionary: nil,
                activation: nil
            )
            let journal = try TorrentStorageClaimJournal(directory: state)
            try await journal.beginPromotion(promotion)

            await #expect(throws: TorrentStorageJournalError.self) {
                _ = try await journal.recordPromotionMetadata(
                    id: promotionID,
                    operationNonce: UUID(),
                    exactInfoDictionary: info
                )
            }
            await #expect(throws: TorrentStorageJournalError.self) {
                _ = try await journal.recordPromotionMetadata(
                    id: promotionID,
                    operationNonce: operationNonce,
                    exactInfoDictionary: Data("invalid".utf8)
                )
            }

            let metadataReady = try await journal.recordPromotionMetadata(
                id: promotionID,
                operationNonce: operationNonce,
                exactInfoDictionary: info
            )
            #expect(metadataReady.state == .metadataReady)
            #expect(metadataReady.exactInfoDictionary == info)

            let activation = TorrentMagnetPromotionActivation(
                claimID: UUID(),
                claimOperationNonce: UUID(),
                runtime: TorrentMagnetPromotionRuntimeState(
                    wasPaused: true,
                    queuePosition: 7,
                    options: .unlimited,
                    sourcePolicy: .unavailable,
                    filePriorities: [0: .high]
                )
            )
            _ = try await journal.beginPromotionActivation(
                id: promotionID,
                operationNonce: operationNonce,
                activation: activation
            )
            _ = try await journal.markPromotionOutcomeUnknown(
                id: promotionID,
                operationNonce: operationNonce
            )

            let reloaded = try TorrentStorageClaimJournal(directory: state)
            let durable = try #require(await reloaded.allPromotions().first)
            #expect(durable.state == .outcomeUnknown)
            #expect(durable.exactInfoDictionary == info)
            #expect(durable.activation == activation)

            try await reloaded.completePromotion(
                id: promotionID,
                operationNonce: operationNonce
            )
            #expect(await reloaded.allPromotions().isEmpty)
        }
    }

    private struct SingleFileFixture {
        let downloads: URL
        let parent: TorrentStorageParentAuthority
        let reservation: TorrentStorageReservation
    }

    private func reserveSingleFile(
        in root: URL,
        name: String,
        size: Int64
    ) throws -> SingleFileFixture {
        let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let parent = try makeParent(downloads)
        let logical = try makeLogicalManifest(
            name: name,
            contentKind: .singleFile,
            files: [.init(index: 0, pathComponents: [name], expectedSize: size, isPadding: false)]
        )
        let planner = TorrentStorageDestinationPlanner()
        let selected = try planner.planTopLevelName(for: logical, in: parent)
        let reservation = try planner.reserve(
            manifest: logical,
            in: parent,
            claimID: UUID(),
            generation: 1,
            ownershipToken: TorrentStorageDestinationPlanner.randomOwnershipToken(),
            selectedTopLevelName: selected
        )
        return SingleFileFixture(
            downloads: downloads,
            parent: parent,
            reservation: reservation
        )
    }

    private func assertSubstitutionRejected(
        in root: URL,
        mutate: (URL, URL) throws -> Void
    ) throws {
        let fixture = try reserveSingleFile(in: root, name: "payload.bin", size: 16)
        let claim = makeClaim(fixture.reservation, state: .active)
        let registry = TorrentStorageBrokerRegistry()
        try registry.install(parentAuthority: fixture.parent)
        try registry.install(claim: claim)
        let payload = fixture.downloads.appending(path: claim.manifest.collisionSelectedTopLevelName)
        let backup = fixture.downloads.appending(path: "backup")
        try mutate(payload, backup)

        #expect(throws: TorrentStorageBrokerRegistryError.filesystemObjectChanged) {
            _ = try registry.openPayload(
                claimID: claim.manifest.claimID,
                generation: 1,
                fileIndex: 0,
                access: .readOnly
            )
        }
    }

    private func makeClaim(
        _ reservation: TorrentStorageReservation,
        state: TorrentStorageClaimState,
        policies: [TorrentPayloadFilePolicy]? = nil,
        nonce: UUID = UUID()
    ) -> TorrentStorageClaim {
        TorrentStorageClaim(
            manifest: reservation.storageManifest,
            lease: TorrentStorageLease(
                state: state,
                policyRevision: reservation.initialLease.policyRevision,
                filePolicies: policies ?? reservation.initialLease.filePolicies
            ),
            torrentID: state == .active ? "t:\(String(repeating: "b", count: 32))" : nil,
            operationNonce: nonce
        )
    }

    private func makeParent(_ directory: URL) throws -> TorrentStorageParentAuthority {
        try TorrentStorageParentAuthority(
            lease: DownloadFolderAccessLease(
                access: FakeDownloadFolderAccess(url: directory)
            )
        )
    }

    private func makeLogicalManifest(
        name: String,
        contentKind: TorrentStorageContentKind,
        files: [TorrentLogicalFile]
    ) throws -> TorrentLogicalManifest {
        let hashes = try TorrentStorageInfoHashes(
            v1: Data(repeating: 0x55, count: 20),
            v2: nil
        )
        let digest = TorrentManifestDigest.source(
            name: name,
            contentKind: contentKind,
            infoHashes: hashes,
            pieceLength: 16_384,
            files: files
        )
        return TorrentLogicalManifest(
            name: name,
            contentKind: contentKind,
            infoHashes: hashes,
            pieceLength: 16_384,
            files: files,
            sourceManifestDigest: digest
        )
    }

    private static func singleFileInfoDictionary() -> Data {
        var data = Data(
            "d6:lengthi4e4:name10:sample.bin12:piece lengthi16384e6:pieces20:".utf8
        )
        data.append(Data(repeating: 0, count: 20))
        data.append(UInt8(ascii: "e"))
        return data
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
}
