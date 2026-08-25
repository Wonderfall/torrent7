import Darwin
import CryptoKit
import Foundation
import Synchronization
import Testing
import TorrentEngineIPC
import XPC
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
            let key = TorrentStorageDestinationPlanner.randomOwnershipKey()
            let journal = try TorrentStorageClaimJournal(directory: state)
            try await journal.beginPreparation(TorrentStoragePreparation(
                claimID: claimID,
                generation: 1,
                parentID: parent.id,
                preferredTopLevelName: logical.name,
                ownershipKey: key,
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
                ownershipKey: key,
                selectedTopLevelName: selected
            )
            #expect(reservation.storageManifest.collisionSelectedTopLevelName == selected)
            #expect(try Data(contentsOf: downloads.appending(path: "sample.bin")) == Data("foreign".utf8))
        }
    }

    @Test("Destination inspection progressively discloses only safe choices")
    func destinationInspectionReportsSafeChoices() throws {
        try withTemporaryDirectory { root in
            let downloads = root.appending(
                path: "Downloads",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: downloads,
                withIntermediateDirectories: true
            )
            let parent = try makeParent(downloads)
            let logical = try makeLogicalManifest(
                name: "sample.bin",
                contentKind: .singleFile,
                files: [.init(
                    index: 0,
                    pathComponents: ["sample.bin"],
                    expectedSize: 8,
                    isPadding: false
                )]
            )
            let planner = TorrentStorageDestinationPlanner()

            #expect(try planner.inspectDestination(
                for: logical,
                in: parent
            ) == nil)

            let payload = downloads.appending(path: "sample.bin")
            try Data("seed".utf8).write(to: payload)
            let inspectedSafeConflict = try planner.inspectDestination(
                for: logical,
                in: parent
            )
            let safeConflict = try #require(inspectedSafeConflict)
            #expect(safeConflict.existingTopLevelName == "sample.bin")
            #expect(safeConflict.separateCopyTopLevelName == "sample 2.bin")
            #expect(URL(
                filePath: safeConflict.parentPath,
                directoryHint: .isDirectory
            ).standardizedFileURL == downloads.standardizedFileURL)
            #expect(safeConflict.canUseExistingFiles)

            try FileManager.default.linkItem(
                at: payload,
                to: downloads.appending(path: "linked.bin")
            )
            let inspectedUnsafeConflict = try planner.inspectDestination(
                for: logical,
                in: parent
            )
            let unsafeConflict = try #require(inspectedUnsafeConflict)
            #expect(unsafeConflict.separateCopyTopLevelName == "sample 2.bin")
            #expect(!unsafeConflict.canUseExistingFiles)
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
            let key = TorrentStorageDestinationPlanner.randomOwnershipKey()
            let journal = try TorrentStorageClaimJournal(directory: state)
            try await journal.beginPreparation(.init(
                claimID: claimID,
                generation: 1,
                parentID: parent.id,
                preferredTopLevelName: logical.name,
                ownershipKey: key,
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
                    ownershipKey: key,
                    selectedTopLevelName: selected
                )
            }
            #expect(try Data(contentsOf: downloads.appending(path: selected)) == foreign)
            #expect(await journal.unresolvedPreparations().first?.reservedTopLevelName == selected)
        }
    }

    @Test("Failed reservations capture their partial cleanup")
    func failedReservationUsesAtomicCleanup() throws {
        try withTemporaryDirectory { root in
            let downloads = root.appending(
                path: "Downloads",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: downloads,
                withIntermediateDirectories: true
            )
            let parent = try makeParent(downloads)
            let logical = try makeLogicalManifest(
                name: "bundle",
                contentKind: .directory,
                files: [
                    .init(
                        index: 0,
                        pathComponents: ["duplicate.bin"],
                        expectedSize: 8,
                        isPadding: false
                    ),
                    .init(
                        index: 1,
                        pathComponents: ["duplicate.bin"],
                        expectedSize: 8,
                        isPadding: false
                    ),
                ]
            )

            #expect(throws: TorrentStoragePlanningError.self) {
                _ = try TorrentStorageDestinationPlanner().reserve(
                    manifest: logical,
                    in: parent,
                    claimID: UUID(),
                    generation: 1,
                    ownershipKey: TorrentStorageDestinationPlanner.randomOwnershipKey()
                )
            }
            #expect(!FileManager.default.fileExists(
                atPath: downloads.appending(path: "bundle").path()
            ))
            #expect(try deletionQuarantineNames(in: downloads).isEmpty)
        }
    }

    @Test("Broker opens only the exact claimed inode and enforces availability")
    func brokerEnforcesIdentityAndAvailability() throws {
        try withTemporaryDirectory { root in
            let fixture = try reserveSingleFile(in: root, name: "payload.bin", size: 16)
            var availability = fixture.reservation.initialLease.fileAvailability
            availability[0] = false
            let claim = makeClaim(
                fixture.reservation,
                state: .activating,
                availability: availability
            )
            let registry = TorrentStorageBrokerRegistry()
            try registry.install(claim: claim, parent: fixture.parent)

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

    @Test("Broker claims remain isolated by claim and parent authority")
    func brokerClaimsAreIsolated() throws {
        try withTemporaryDirectory { root in
            let firstFixture = try reserveSingleFile(
                in: root,
                name: "first.bin",
                size: 8
            )
            let secondFixture = try reserveSingleFile(
                in: root,
                name: "second.bin",
                size: 8
            )
            let firstClaim = makeClaim(
                firstFixture.reservation,
                state: .active
            )
            let secondClaim = makeClaim(
                secondFixture.reservation,
                state: .active
            )
            let firstPayload = firstFixture.downloads.appending(
                path: firstClaim.manifest.collisionSelectedTopLevelName
            )
            let secondPayload = secondFixture.downloads.appending(
                path: secondClaim.manifest.collisionSelectedTopLevelName
            )
            try Data("first---".utf8).write(to: firstPayload)
            try Data("second--".utf8).write(to: secondPayload)

            let registry = TorrentStorageBrokerRegistry()
            try registry.install(claim: firstClaim, parent: firstFixture.parent)
            try registry.install(claim: secondClaim, parent: secondFixture.parent)

            let first = try registry.openPayload(
                claimID: firstClaim.manifest.claimID,
                generation: firstClaim.manifest.generation,
                fileIndex: 0,
                access: .readOnly
            )
            defer { _ = Darwin.close(first.descriptor) }
            let second = try registry.openPayload(
                claimID: secondClaim.manifest.claimID,
                generation: secondClaim.manifest.generation,
                fileIndex: 0,
                access: .readOnly
            )
            defer { _ = Darwin.close(second.descriptor) }

            #expect(
                try contents(of: first.descriptor, count: 8)
                    == Data("first---".utf8)
            )
            #expect(
                try contents(of: second.descriptor, count: 8)
                    == Data("second--".utf8)
            )

            let unrelatedDirectory = root.appending(
                path: "Other Downloads",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: unrelatedDirectory,
                withIntermediateDirectories: true
            )
            let unrelatedParent = try makeParent(unrelatedDirectory)
            #expect(throws: TorrentStorageBrokerRegistryError.invalidClaim) {
                try TorrentStorageBrokerRegistry().install(
                    claim: firstClaim,
                    parent: unrelatedParent
                )
            }

            try registry.removeClaim(
                claimID: firstClaim.manifest.claimID,
                generation: firstClaim.manifest.generation
            )
            #expect(throws: TorrentStorageBrokerRegistryError.claimUnavailable) {
                _ = try registry.openPayload(
                    claimID: firstClaim.manifest.claimID,
                    generation: firstClaim.manifest.generation,
                    fileIndex: 0,
                    access: .readOnly
                )
            }
            let surviving = try registry.openPayload(
                claimID: secondClaim.manifest.claimID,
                generation: secondClaim.manifest.generation,
                fileIndex: 0,
                access: .readOnly
            )
            defer { _ = Darwin.close(surviving.descriptor) }
            #expect(
                try contents(of: surviving.descriptor, count: 8)
                    == Data("second--".utf8)
            )
        }
    }

    @Test("Authority digest binds logical paths to pinned identities")
    func authorityDigestBindsLogicalMapping() throws {
        try withTemporaryDirectory { root in
            let fixture = try reserveSingleFile(
                in: root,
                name: "payload.bin",
                size: 16
            )
            let claim = makeClaim(fixture.reservation, state: .active)
            let manifest = claim.manifest
            var logicalFiles = manifest.logicalFiles
            logicalFiles[0] = TorrentLogicalFile(
                index: 0,
                pathComponents: ["different.bin"],
                expectedSize: logicalFiles[0].expectedSize,
                isPadding: false
            )
            let forgedManifest = TorrentStorageManifest(
                claimID: manifest.claimID,
                generation: manifest.generation,
                infoHashes: manifest.infoHashes,
                sourceManifestDigest: manifest.sourceManifestDigest,
                parentID: manifest.parentID,
                contentKind: manifest.contentKind,
                logicalFiles: logicalFiles,
                physicalFileIdentities: manifest.physicalFileIdentities,
                physicalDirectoryIdentities:
                    manifest.physicalDirectoryIdentities,
                collisionSelectedTopLevelName:
                    manifest.collisionSelectedTopLevelName,
                authorityDigest: manifest.authorityDigest,
                ownership: manifest.ownership
            )
            let forgedClaim = TorrentStorageClaim(
                manifest: forgedManifest,
                lease: claim.lease,
                torrentID: claim.torrentID,
                operationNonce: claim.operationNonce,
                removalIntent: nil,
                deletionEvidence: nil
            )

            #expect(throws: TorrentStorageBrokerRegistryError.invalidClaim) {
                try TorrentStorageBrokerRegistry().install(
                    claim: forgedClaim,
                    parent: fixture.parent
                )
            }
        }
    }

    @Test("Directory authority contains only logical payload parents")
    func directoryAuthorityRejectsUnrelatedPaths() throws {
        try withTemporaryDirectory { root in
            let downloads = root.appending(
                path: "Downloads",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: downloads,
                withIntermediateDirectories: true
            )
            let parent = try makeParent(downloads)
            let logical = try makeLogicalManifest(
                name: "bundle",
                contentKind: .directory,
                files: [.init(
                    index: 0,
                    pathComponents: ["payload.bin"],
                    expectedSize: 16,
                    isPadding: false
                )]
            )
            let reservation = try TorrentStorageDestinationPlanner().reserve(
                manifest: logical,
                in: parent,
                claimID: UUID(),
                generation: 1,
                ownershipKey: TorrentStorageDestinationPlanner
                    .randomOwnershipKey()
            )
            let claim = makeClaim(reservation, state: .active)
            let manifest = claim.manifest
            let rootIdentity = try #require(manifest.topLevelIdentity)
            let directories = manifest.physicalDirectoryIdentities + [
                TorrentPhysicalDirectoryIdentity(
                    relativePathComponents: ["unrelated"],
                    identity: rootIdentity
                ),
            ]
            let authorityDigest = TorrentManifestDigest.authority(
                claimID: manifest.claimID,
                generation: manifest.generation,
                infoHashes: manifest.infoHashes,
                sourceManifestDigest: manifest.sourceManifestDigest,
                parentID: manifest.parentID,
                contentKind: manifest.contentKind,
                logicalFiles: manifest.logicalFiles,
                topLevelName: manifest.collisionSelectedTopLevelName,
                fileIdentities: manifest.physicalFileIdentities,
                directoryIdentities: directories,
                ownership: manifest.ownership
            )
            let forgedManifest = TorrentStorageManifest(
                claimID: manifest.claimID,
                generation: manifest.generation,
                infoHashes: manifest.infoHashes,
                sourceManifestDigest: manifest.sourceManifestDigest,
                parentID: manifest.parentID,
                contentKind: manifest.contentKind,
                logicalFiles: manifest.logicalFiles,
                physicalFileIdentities: manifest.physicalFileIdentities,
                physicalDirectoryIdentities: directories,
                collisionSelectedTopLevelName:
                    manifest.collisionSelectedTopLevelName,
                authorityDigest: authorityDigest,
                ownership: manifest.ownership
            )
            let forgedClaim = TorrentStorageClaim(
                manifest: forgedManifest,
                lease: claim.lease,
                torrentID: claim.torrentID,
                operationNonce: claim.operationNonce,
                removalIntent: nil,
                deletionEvidence: nil
            )

            #expect(throws: TorrentStorageBrokerRegistryError.invalidClaim) {
                try TorrentStorageBrokerRegistry().install(
                    claim: forgedClaim,
                    parent: parent
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
            try registry.install(claim: claim, parent: fixture.parent)

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
                ownershipKey: TorrentStorageDestinationPlanner.randomOwnershipKey(),
                selectedTopLevelName: selected
            )
            let claim = makeClaim(reservation, state: .active)
            let registry = TorrentStorageBrokerRegistry()
            try registry.install(claim: claim, parent: parent)

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

            try planner.deleteClaimedPayload(
                claim: try makeDeletingClaim(reservation, from: parent),
                from: parent
            )
            #expect(!FileManager.default.fileExists(
                atPath: downloads.appending(path: selected).path()
            ))
            #expect(try deletionQuarantineNames(in: downloads).isEmpty)
        }
    }

    @Test("GUI deletion requires the recorded inode and ownership authentication tag")
    func deletionRequiresProofOfOwnership() throws {
        try withTemporaryDirectory { root in
            let fixture = try reserveSingleFile(in: root, name: "delete.bin", size: 8)
            let claim = try makeDeletingClaim(
                fixture.reservation,
                from: fixture.parent
            )
            let payload = fixture.downloads.appending(path: claim.manifest.collisionSelectedTopLevelName)
            try TorrentStorageDestinationPlanner().deleteClaimedPayload(
                claim: claim,
                from: fixture.parent
            )
            #expect(!FileManager.default.fileExists(atPath: payload.path()))

            let replacement = try reserveSingleFile(in: root, name: "preserve.bin", size: 8)
            let replacementClaim = try makeDeletingClaim(
                replacement.reservation,
                from: replacement.parent
            )
            let replacementPath = replacement.downloads.appending(
                path: replacementClaim.manifest.collisionSelectedTopLevelName
            )
            let original = replacement.downloads.appending(path: "original-preserved")
            try FileManager.default.moveItem(at: replacementPath, to: original)
            let foreign = Data("foreign".utf8)
            try foreign.write(to: replacementPath)

            #expect(throws: TorrentStoragePlanningError.self) {
                try TorrentStorageDestinationPlanner().deleteClaimedPayload(
                    claim: replacementClaim,
                    from: replacement.parent
                )
            }
            #expect(try Data(contentsOf: replacementPath) == foreign)
            #expect(FileManager.default.fileExists(atPath: original.path()))
            #expect(try deletionQuarantineNames(in: replacement.downloads).isEmpty)
        }
    }

    @Test("Atomic deletion capture preserves a replacement file")
    func deletionCapturePreservesReplacementFile() throws {
        try withTemporaryDirectory { root in
            let fixture = try reserveSingleFile(
                in: root,
                name: "replace.bin",
                size: 8
            )
            let payload = fixture.downloads.appending(path: "replace.bin")
            let claimedDescriptor = unsafe payload.path().withCString { pointer in
                unsafe Darwin.open(
                    pointer,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            try #require(claimedDescriptor >= 0)
            defer { _ = Darwin.close(claimedDescriptor) }

            let replacement = Data("foreign".utf8)
            let planner = TorrentStorageDestinationPlanner()
            let deletingClaim = try makeDeletingClaim(
                fixture.reservation,
                from: fixture.parent
            )
            try planner.deleteClaimedPayload(
                claim: deletingClaim,
                from: fixture.parent,
                afterCapture: {
                    try? replacement.write(
                        to: payload,
                        options: .withoutOverwriting
                    )
                }
            )

            #expect(try Data(contentsOf: payload) == replacement)
            var metadata = stat()
            #expect(unsafe Darwin.fstat(claimedDescriptor, &metadata) == 0)
            #expect(metadata.st_nlink == 0)
            #expect(try deletionQuarantineNames(in: fixture.downloads).isEmpty)
        }
    }

    @Test("Deletion recovery distinguishes resumable, completed, and replaced payloads")
    func deletionRecoveryRequiresUnambiguousFilesystemState() throws {
        try withTemporaryDirectory { root in
            let fixture = try reserveSingleFile(
                in: root,
                name: "recover.bin",
                size: 8
            )
            let planner = TorrentStorageDestinationPlanner()
            let claim = try makeDeletingClaim(
                fixture.reservation,
                from: fixture.parent
            )
            let payload = fixture.downloads.appending(path: "recover.bin")

            #expect(try !planner.deletionIsComplete(
                claim: claim,
                in: fixture.parent
            ))
            try planner.deleteClaimedPayload(
                claim: claim,
                from: fixture.parent
            )
            #expect(try planner.deletionIsComplete(
                claim: claim,
                in: fixture.parent
            ))

            let replacement = Data("foreign".utf8)
            try replacement.write(to: payload)
            #expect(throws: TorrentStoragePlanningError.deletionNotProvable) {
                _ = try planner.deletionIsComplete(
                    claim: claim,
                    in: fixture.parent
                )
            }
            #expect(try Data(contentsOf: payload) == replacement)
        }
    }

    @Test("Tampered deletion evidence cannot retire a live payload")
    func tamperedDeletionEvidenceFailsClosed() throws {
        try withTemporaryDirectory { root in
            let fixture = try reserveSingleFile(
                in: root,
                name: "preserve.bin",
                size: 8
            )
            let planner = TorrentStorageDestinationPlanner()
            let claim = try makeDeletingClaim(
                fixture.reservation,
                from: fixture.parent
            )
            let quarantine = fixture.downloads.appending(
                path: ".torrent7-deletion-\(claim.operationNonce.uuidString.lowercased())",
                directoryHint: .isDirectory
            )
            try FileManager.default.removeItem(
                at: quarantine.appending(
                    path: "entries",
                    directoryHint: .isDirectory
                )
            )

            #expect(throws: TorrentStoragePlanningError.deletionNotProvable) {
                _ = try planner.deletionIsComplete(
                    claim: claim,
                    in: fixture.parent
                )
            }
            #expect(FileManager.default.fileExists(
                atPath: fixture.downloads.appending(path: "preserve.bin").path()
            ))
        }
    }

    @Test("Deletion resumes after nested entries were already removed")
    func deletionResumesAfterPartialNestedCleanup() throws {
        try withTemporaryDirectory { root in
            let downloads = root.appending(
                path: "Downloads",
                directoryHint: .isDirectory
            )
            let payloadRoot = downloads.appending(
                path: "bundle",
                directoryHint: .isDirectory
            )
            let nested = payloadRoot.appending(
                path: "nested",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: nested,
                withIntermediateDirectories: true
            )
            try Data("payload".utf8).write(
                to: nested.appending(path: "payload.bin")
            )

            let parent = try makeParent(downloads)
            let logical = try makeLogicalManifest(
                name: "bundle",
                contentKind: .directory,
                files: [
                    .init(
                        index: 0,
                        pathComponents: ["nested", "payload.bin"],
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
                selectedTopLevelName: logical.name
            )
            let claim = try makeDeletingClaim(reservation, from: parent)
            let capturedRoot = downloads.appending(
                path: ".torrent7-deletion-\(claim.operationNonce.uuidString.lowercased())/payload",
                directoryHint: .isDirectory
            )

            try planner.deleteClaimedPayload(
                claim: claim,
                from: parent,
                afterCapture: {
                    try? FileManager.default.removeItem(
                        at: capturedRoot.appending(
                            path: "nested/payload.bin"
                        )
                    )
                    try? FileManager.default.removeItem(
                        at: capturedRoot.appending(
                            path: "nested",
                            directoryHint: .isDirectory
                        )
                    )
                }
            )

            #expect(!FileManager.default.fileExists(atPath: payloadRoot.path()))
            #expect(try deletionQuarantineNames(in: downloads).isEmpty)
        }
    }

    @Test("Atomic directory capture preserves a replacement directory")
    func directoryCapturePreservesReplacementDirectory() throws {
        try withTemporaryDirectory { root in
            let downloads = root.appending(
                path: "Downloads",
                directoryHint: .isDirectory
            )
            let payloadRoot = downloads.appending(
                path: "bundle",
                directoryHint: .isDirectory
            )
            let nested = payloadRoot.appending(
                path: "nested",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: nested,
                withIntermediateDirectories: true
            )
            try Data("payload".utf8).write(
                to: nested.appending(path: "payload.bin")
            )

            let parent = try makeParent(downloads)
            let logical = try makeLogicalManifest(
                name: "bundle",
                contentKind: .directory,
                files: [
                    .init(
                        index: 0,
                        pathComponents: ["nested", "payload.bin"],
                        expectedSize: 8,
                        isPadding: false
                    ),
                ]
            )
            let reservation = try TorrentStorageDestinationPlanner().importExisting(
                manifest: logical,
                in: parent,
                claimID: UUID(),
                generation: 1,
                selectedTopLevelName: logical.name
            )
            let replacement = Data("foreign".utf8)
            let planner = TorrentStorageDestinationPlanner()
            let deletingClaim = try makeDeletingClaim(
                reservation,
                from: parent
            )
            try planner.deleteClaimedPayload(
                claim: deletingClaim,
                from: parent,
                afterCapture: {
                    try? FileManager.default.createDirectory(
                        at: payloadRoot,
                        withIntermediateDirectories: false
                    )
                    try? replacement.write(
                        to: payloadRoot.appending(path: "foreign.txt"),
                        options: .withoutOverwriting
                    )
                }
            )

            #expect(
                try Data(contentsOf: payloadRoot.appending(path: "foreign.txt"))
                    == replacement
            )
            #expect(try deletionQuarantineNames(in: downloads).isEmpty)
        }
    }

    @Test("Nested substitution cannot redirect deletion to a replacement file")
    func nestedDeletionSubstitutionFailsClosed() throws {
        try withTemporaryDirectory { root in
            let downloads = root.appending(
                path: "Downloads",
                directoryHint: .isDirectory
            )
            let payloadRoot = downloads.appending(
                path: "bundle",
                directoryHint: .isDirectory
            )
            let nested = payloadRoot.appending(
                path: "nested",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: nested,
                withIntermediateDirectories: true
            )
            let original = Data("original".utf8)
            try original.write(to: nested.appending(path: "payload.bin"))

            let parent = try makeParent(downloads)
            let logical = try makeLogicalManifest(
                name: "bundle",
                contentKind: .directory,
                files: [
                    .init(
                        index: 0,
                        pathComponents: ["nested", "payload.bin"],
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
                selectedTopLevelName: logical.name
            )
            let claim = try makeDeletingClaim(reservation, from: parent)
            let capturedNested = downloads
                .appending(
                    path: ".torrent7-deletion-\(claim.operationNonce.uuidString.lowercased())",
                    directoryHint: .isDirectory
                )
                .appending(path: "payload", directoryHint: .isDirectory)
                .appending(path: "nested", directoryHint: .isDirectory)
            let replacement = Data("foreign".utf8)

            #expect(throws: TorrentStoragePlanningError.deletionNotProvable) {
                try planner.deleteClaimedPayload(
                    claim: claim,
                    from: parent,
                    afterCapture: {
                        try? FileManager.default.moveItem(
                            at: capturedNested.appending(path: "payload.bin"),
                            to: capturedNested.appending(path: "original.bin")
                        )
                        try? replacement.write(
                            to: capturedNested.appending(path: "payload.bin")
                        )
                    }
                )
            }

            #expect(try Data(
                contentsOf: nested.appending(path: "payload.bin")
            ) == replacement)
            #expect(try Data(
                contentsOf: nested.appending(path: "original.bin")
            ) == original)
            #expect(try deletionQuarantineNames(in: downloads).isEmpty)
        }
    }

    @Test("Explicit imports authorize identity-pinned deletion")
    func explicitImportAuthorizesDeletion() throws {
        try withTemporaryDirectory { root in
            let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: downloads,
                withIntermediateDirectories: true
            )
            let payload = downloads.appending(path: "sample.bin")
            let original = Data("seed".utf8)
            try original.write(to: payload)
            do {
                let descriptor = unsafe payload.path().withCString { path in
                    unsafe Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                }
                try #require(descriptor >= 0)
                defer { _ = Darwin.close(descriptor) }
                let staleTag = Data(
                    repeating: 0xA5,
                    count: TorrentStorageOwnershipTag.tagByteCount
                )
                let status = unsafe staleTag.withUnsafeBytes { bytes in
                    unsafe TorrentStorageDestinationPlanner.ownershipAttribute.withCString { name in
                        unsafe Darwin.fsetxattr(
                            descriptor,
                            name,
                            bytes.baseAddress,
                            bytes.count,
                            0,
                            0
                        )
                    }
                }
                try #require(status == 0)
            }
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
                selectedTopLevelName: logical.name
            )
            #expect(reservation.storageManifest.ownership == .imported)
            #expect(reservation.initialLease.fileAvailability == [true])
            #expect(try Data(contentsOf: payload) == original)

            let activeClaim = makeClaim(reservation, state: .active)
            try planner.validateClaimRoot(activeClaim, in: parent)
            let registry = TorrentStorageBrokerRegistry()
            try registry.install(claim: activeClaim, parent: parent)
            let opened = try registry.openPayload(
                claimID: activeClaim.manifest.claimID,
                generation: activeClaim.manifest.generation,
                fileIndex: 0,
                access: .readWrite
            )
            #expect(opened.metadata.size == original.count)
            _ = Darwin.close(opened.descriptor)

            let deletingClaim = try makeDeletingClaim(
                reservation,
                from: parent
            )
            try planner.deleteClaimedPayload(
                claim: deletingClaim,
                from: parent
            )
            #expect(!FileManager.default.fileExists(atPath: payload.path()))
        }
    }

    @Test("Imported directory deletion preserves unrelated contents")
    func importedDirectoryDeletionIsManifestScoped() throws {
        try withTemporaryDirectory { root in
            let downloads = root.appending(
                path: "Downloads",
                directoryHint: .isDirectory
            )
            let payloadRoot = downloads.appending(
                path: "bundle",
                directoryHint: .isDirectory
            )
            let nested = payloadRoot.appending(
                path: "nested",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: nested,
                withIntermediateDirectories: true
            )
            let payload = nested.appending(path: "payload.bin")
            try Data("payload".utf8).write(to: payload)
            let unrelated = payloadRoot.appending(path: "notes.txt")
            let unrelatedData = Data("keep me".utf8)
            try unrelatedData.write(to: unrelated)

            let parent = try makeParent(downloads)
            let logical = try makeLogicalManifest(
                name: "bundle",
                contentKind: .directory,
                files: [
                    .init(
                        index: 0,
                        pathComponents: ["nested", "payload.bin"],
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
                selectedTopLevelName: logical.name
            )
            let deletingClaim = try makeDeletingClaim(
                reservation,
                from: parent
            )
            try planner.deleteClaimedPayload(
                claim: deletingClaim,
                from: parent
            )

            #expect(!FileManager.default.fileExists(atPath: payload.path()))
            #expect(!FileManager.default.fileExists(atPath: nested.path()))
            #expect(FileManager.default.fileExists(atPath: payloadRoot.path()))
            #expect(try Data(contentsOf: unrelated) == unrelatedData)
            #expect(try planner.deletionIsComplete(
                claim: deletingClaim,
                in: parent
            ))
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
                    selectedTopLevelName: logical.name
                )
            }
        }
    }

    @Test("A brokered FD exposes only an object-bound ownership tag")
    func brokeredDescriptorDoesNotExposeOwnershipKey() throws {
        try withTemporaryDirectory { root in
            let fixture = try reserveSingleFile(in: root, name: "payload.bin", size: 16)
            let claim = makeClaim(fixture.reservation, state: .active)
            let registry = TorrentStorageBrokerRegistry()
            try registry.install(claim: claim, parent: fixture.parent)
            let opened = try registry.openPayload(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation,
                fileIndex: 0,
                access: .readWrite
            )
            defer { _ = Darwin.close(opened.descriptor) }

            let identity = try #require(
                claim.manifest.physicalFileIdentities.first ?? nil
            )
            let components = try #require(
                claim.manifest.relativePathComponents(forFileAt: 0)
            )
            let ownershipKey = try #require(
                claim.manifest.ownership.ownershipKey
            )
            let tag = try #require(ownershipTag(on: opened.descriptor))
            #expect(tag != ownershipKey)
            #expect(TorrentStorageOwnershipTag.isValid(
                tag,
                key: ownershipKey,
                claimID: claim.manifest.claimID,
                claimGeneration: claim.manifest.generation,
                relativePathComponents: components,
                identity: identity,
                isDirectory: false
            ))

            let differentIdentity = TorrentFilesystemIdentity(
                device: identity.device,
                inode: identity.inode &+ 1,
                linkCount: identity.linkCount,
                ownerUserID: identity.ownerUserID,
                fileGeneration: identity.fileGeneration
            )
            #expect(!TorrentStorageOwnershipTag.isValid(
                tag,
                key: ownershipKey,
                claimID: claim.manifest.claimID,
                claimGeneration: claim.manifest.generation,
                relativePathComponents: components,
                identity: differentIdentity,
                isDirectory: false
            ))
            #expect(!TorrentStorageOwnershipTag.isValid(
                tag,
                key: ownershipKey,
                claimID: claim.manifest.claimID,
                claimGeneration: claim.manifest.generation,
                relativePathComponents: ["different.bin"],
                identity: identity,
                isDirectory: false
            ))
        }
    }

    @Test("A brokered file FD cannot act as directory namespace authority")
    func brokeredDescriptorIsNotDirectoryAuthority() throws {
        try withTemporaryDirectory { root in
            let fixture = try reserveSingleFile(
                in: root,
                name: "payload.bin",
                size: 16
            )
            let sibling = fixture.downloads.appending(path: "sibling.bin")
            try Data("sibling".utf8).write(to: sibling)
            let claim = makeClaim(fixture.reservation, state: .active)
            let registry = TorrentStorageBrokerRegistry()
            try registry.install(claim: claim, parent: fixture.parent)
            let opened = try registry.openPayload(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation,
                fileIndex: 0,
                access: .readOnly
            )
            defer { _ = Darwin.close(opened.descriptor) }

            var recoveredPath = [CChar](
                repeating: 0,
                count: Int(MAXPATHLEN)
            )
            let pathStatus = unsafe Darwin.fcntl(
                opened.descriptor,
                F_GETPATH,
                &recoveredPath
            )
            #expect(pathStatus == 0)
            if pathStatus == 0 {
                let terminator = recoveredPath.firstIndex(of: 0)
                    ?? recoveredPath.endIndex
                let path = String(
                    decoding: recoveredPath[..<terminator].map {
                        UInt8(bitPattern: $0)
                    },
                    as: UTF8.self
                )
                let expected = fixture.downloads.appending(
                    path: claim.manifest.collisionSelectedTopLevelName
                )
                #expect(
                    URL(filePath: path).resolvingSymlinksInPath()
                        == expected.resolvingSymlinksInPath()
                )
            }

            let traversal = unsafe "../sibling.bin".withCString { name in
                unsafe Darwin.openat(
                    opened.descriptor,
                    name,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            if traversal >= 0 {
                _ = Darwin.close(traversal)
            }
            #expect(traversal == -1)

            #expect(Darwin.fchdir(opened.descriptor) == -1)
            let mkdirStatus = unsafe "child".withCString { name in
                unsafe Darwin.mkdirat(opened.descriptor, name, 0o700)
            }
            #expect(mkdirStatus == -1)
            let unlinkStatus = unsafe "../sibling.bin".withCString { name in
                unsafe Darwin.unlinkat(opened.descriptor, name, 0)
            }
            #expect(unlinkStatus == -1)
            let renameStatus = unsafe "payload.bin".withCString { source in
                unsafe "renamed.bin".withCString { destination in
                    unsafe Darwin.renameat(
                        opened.descriptor,
                        source,
                        opened.descriptor,
                        destination
                    )
                }
            }
            #expect(renameStatus == -1)
            let linkStatus = unsafe "payload.bin".withCString { source in
                unsafe "linked.bin".withCString { destination in
                    unsafe Darwin.linkat(
                        opened.descriptor,
                        source,
                        opened.descriptor,
                        destination,
                        0
                    )
                }
            }
            #expect(linkStatus == -1)
            #expect(try Data(contentsOf: sibling) == Data("sibling".utf8))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.downloads.appending(path: "child").path()
            ))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.downloads.appending(path: "renamed.bin").path()
            ))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.downloads.appending(path: "linked.bin").path()
            ))
        }
    }

    @Test("A stale issued FD remains bound to its unlinked inode")
    func claimRemovalIsSoftRevocation() throws {
        try withTemporaryDirectory { root in
            let fixture = try reserveSingleFile(
                in: root,
                name: "payload.bin",
                size: 16
            )
            let claim = makeClaim(fixture.reservation, state: .active)
            let registry = TorrentStorageBrokerRegistry()
            try registry.install(claim: claim, parent: fixture.parent)
            let opened = try registry.openPayload(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation,
                fileIndex: 0,
                access: .readWrite
            )
            defer { _ = Darwin.close(opened.descriptor) }

            let retainedBytes = Data("retained".utf8)
            let written = unsafe retainedBytes.withUnsafeBytes { bytes in
                unsafe Darwin.pwrite(
                    opened.descriptor,
                    bytes.baseAddress,
                    bytes.count,
                    0
                )
            }
            #expect(written == retainedBytes.count)

            let removingClaim = makeClaim(
                fixture.reservation,
                state: .removing
            )
            try registry.replace(claim: removingClaim)
            #expect(throws: TorrentStorageBrokerRegistryError.claimInactive) {
                _ = try registry.openPayload(
                    claimID: claim.manifest.claimID,
                    generation: claim.manifest.generation,
                    fileIndex: 0,
                    access: .readOnly
                )
            }

            let payload = fixture.downloads.appending(
                path: claim.manifest.collisionSelectedTopLevelName
            )
            let deletingClaim = try makeDeletingClaim(
                fixture.reservation,
                from: fixture.parent
            )
            try registry.replace(claim: deletingClaim)
            try TorrentStorageDestinationPlanner().deleteClaimedPayload(
                claim: deletingClaim,
                from: fixture.parent
            )
            try registry.removeClaim(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation
            )
            #expect(!FileManager.default.fileExists(atPath: payload.path()))

            var recoveredBytes = Data(count: retainedBytes.count)
            let read = unsafe recoveredBytes.withUnsafeMutableBytes { bytes in
                unsafe Darwin.pread(
                    opened.descriptor,
                    bytes.baseAddress,
                    bytes.count,
                    0
                )
            }
            #expect(read == recoveredBytes.count)
            #expect(recoveredBytes == retainedBytes)

            let replacementBytes = Data("replacement".utf8)
            try replacementBytes.write(to: payload)
            let staleBytes = Data("stale-fd".utf8)
            let staleWrite = unsafe staleBytes.withUnsafeBytes { bytes in
                unsafe Darwin.pwrite(
                    opened.descriptor,
                    bytes.baseAddress,
                    bytes.count,
                    0
                )
            }
            #expect(staleWrite == staleBytes.count)
            #expect(try Data(contentsOf: payload) == replacementBytes)
            #expect(try contents(
                of: opened.descriptor,
                count: staleBytes.count
            ) == staleBytes)
        }
    }

    @Test("Imported payloads revalidate owner and file generation")
    func importedIdentityIncludesOwnerAndGeneration() throws {
        try withTemporaryDirectory { root in
            let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: downloads,
                withIntermediateDirectories: true
            )
            let payload = downloads.appending(path: "sample.bin")
            try Data("seed".utf8).write(to: payload)
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
                selectedTopLevelName: logical.name
            )
            let manifest = reservation.storageManifest
            let identity = try #require(
                manifest.physicalFileIdentities.first ?? nil
            )
            var metadata = stat()
            let statStatus = unsafe payload.path().withCString { pointer in
                unsafe Darwin.lstat(pointer, &metadata)
            }
            #expect(statStatus == 0)
            #expect(identity.ownerUserID == metadata.st_uid)
            #expect(identity.fileGeneration == metadata.st_gen)

            let forgedIdentities = [
                TorrentFilesystemIdentity(
                    device: identity.device,
                    inode: identity.inode,
                    linkCount: identity.linkCount,
                    ownerUserID: identity.ownerUserID &+ 1,
                    fileGeneration: identity.fileGeneration
                ),
                TorrentFilesystemIdentity(
                    device: identity.device,
                    inode: identity.inode,
                    linkCount: identity.linkCount,
                    ownerUserID: identity.ownerUserID,
                    fileGeneration: identity.fileGeneration &+ 1
                ),
            ]
            for forgedIdentity in forgedIdentities {
                let forgedFileIdentities: [TorrentFilesystemIdentity?] = [
                    forgedIdentity,
                ]
                let forgedManifest = TorrentStorageManifest(
                    claimID: manifest.claimID,
                    generation: manifest.generation,
                    infoHashes: manifest.infoHashes,
                    sourceManifestDigest: manifest.sourceManifestDigest,
                    parentID: manifest.parentID,
                    contentKind: manifest.contentKind,
                    logicalFiles: manifest.logicalFiles,
                    physicalFileIdentities: forgedFileIdentities,
                    physicalDirectoryIdentities:
                        manifest.physicalDirectoryIdentities,
                    collisionSelectedTopLevelName:
                        manifest.collisionSelectedTopLevelName,
                    authorityDigest: TorrentManifestDigest.authority(
                        claimID: manifest.claimID,
                        generation: manifest.generation,
                        infoHashes: manifest.infoHashes,
                        sourceManifestDigest:
                            manifest.sourceManifestDigest,
                        parentID: manifest.parentID,
                        contentKind: manifest.contentKind,
                        logicalFiles: manifest.logicalFiles,
                        topLevelName: manifest.collisionSelectedTopLevelName,
                        fileIdentities: forgedFileIdentities,
                        directoryIdentities:
                            manifest.physicalDirectoryIdentities,
                        ownership: manifest.ownership
                    ),
                    ownership: manifest.ownership
                )
                let forgedClaim = TorrentStorageClaim(
                    manifest: forgedManifest,
                    lease: TorrentStorageLease(
                        state: .active,
                        availabilityRevision: reservation.initialLease.availabilityRevision,
                        fileAvailability:
                            reservation.initialLease.fileAvailability
                    ),
                    torrentID: "t:\(String(repeating: "c", count: 32))",
                    operationNonce: UUID(),
                    removalIntent: nil,
                    deletionEvidence: nil
                )
                let registry = TorrentStorageBrokerRegistry()
                if forgedIdentity.ownerUserID != identity.ownerUserID {
                    #expect(throws: TorrentStorageBrokerRegistryError.invalidClaim) {
                        try registry.install(claim: forgedClaim, parent: parent)
                    }
                    continue
                }
                try registry.install(claim: forgedClaim, parent: parent)
                #expect(throws: TorrentStorageBrokerRegistryError.filesystemObjectChanged) {
                    _ = try registry.openPayload(
                        claimID: forgedClaim.manifest.claimID,
                        generation: forgedClaim.manifest.generation,
                        fileIndex: 0,
                        access: .readOnly
                    )
                }
            }
        }
    }

    @Test("A substituted FIFO cannot block a broker worker")
    func brokerRejectsFIFOWithoutBlocking() throws {
        try withTemporaryDirectory { root in
            let fixture = try reserveSingleFile(in: root, name: "payload.bin", size: 16)
            let claim = makeClaim(fixture.reservation, state: .active)
            let registry = TorrentStorageBrokerRegistry()
            try registry.install(claim: claim, parent: fixture.parent)

            let payload = fixture.downloads.appending(
                path: claim.manifest.collisionSelectedTopLevelName
            )
            try FileManager.default.moveItem(
                at: payload,
                to: fixture.downloads.appending(path: "original.bin")
            )
            let fifoStatus = unsafe payload.path().withCString { pointer in
                unsafe Darwin.mkfifo(pointer, 0o600)
            }
            #expect(fifoStatus == 0)

            let outcome = Mutex(FIFOOpenOutcome.pending)
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let opened = try registry.openPayload(
                        claimID: claim.manifest.claimID,
                        generation: claim.manifest.generation,
                        fileIndex: 0,
                        access: .readOnly
                    )
                    _ = Darwin.close(opened.descriptor)
                    outcome.withLock { $0 = .opened }
                } catch let error as TorrentStorageBrokerRegistryError {
                    outcome.withLock { $0 = .rejected(error) }
                } catch {
                    outcome.withLock { $0 = .unexpectedError }
                }
                finished.signal()
            }

            let completedWithoutWriter = finished.wait(
                timeout: .now() + .seconds(1)
            ) == .success
            var releaseDescriptor: Int32 = -1
            if !completedWithoutWriter {
                releaseDescriptor = unsafe payload.path().withCString { pointer in
                    unsafe Darwin.open(pointer, O_RDWR | O_NONBLOCK | O_CLOEXEC)
                }
                _ = finished.wait(timeout: .now() + .seconds(1))
            }
            if releaseDescriptor >= 0 {
                _ = Darwin.close(releaseDescriptor)
            }

            #expect(completedWithoutWriter)
            #expect(outcome.withLock { $0 }
                == .rejected(.filesystemObjectChanged))
        }
    }

    @Test("Malformed broker traffic cancels the session")
    func malformedBrokerTrafficCancelsSession() {
        let nonce = UUID()
        let gate = TorrentStorageBrokerSessionGate(
            registry: TorrentStorageBrokerRegistry(),
            sessionNonce: nonce
        )
        #expect(gate.handle(XPCDictionary()) == nil)
        #expect(gate.handle(handshakeDictionary(nonce: nonce)) == nil)
    }

    @Test("Broker sessions bind the nonce and first engine epoch")
    func brokerSessionRejectsNonceAndEpochReplay() throws {
        let nonce = UUID()
        let engineEpoch = UUID()
        let gate = TorrentStorageBrokerSessionGate(
            registry: TorrentStorageBrokerRegistry(),
            sessionNonce: nonce
        )

        let wrongNonce = handshakeRequest(
            nonce: UUID(),
            engineEpoch: engineEpoch
        )
        let wrongNonceReply = try brokerReply(for: wrongNonce, from: gate)
        guard case .failure(_, let wrongNonceCode, _) = wrongNonceReply else {
            Issue.record("Expected the wrong nonce to be rejected")
            return
        }
        #expect(wrongNonceCode == .sessionRejected)

        let handshake = handshakeRequest(
            nonce: nonce,
            engineEpoch: engineEpoch
        )
        let handshakeReply = try brokerReply(for: handshake, from: gate)
        guard case .success(_, nil, let statistics, nil) = handshakeReply else {
            Issue.record("Expected the matching session to authenticate")
            return
        }
        #expect(statistics.isEmpty)

        let replay = TorrentStorageBrokerRequest.openPayload(
            .init(
                requestID: UUID(),
                engineEpoch: UUID(),
                sessionNonce: nonce,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            ),
            claimID: UUID(),
            generation: 1,
            fileIndex: 0,
            access: .readOnly
        )
        let replayReply = try brokerReply(for: replay, from: gate)
        guard case .failure(_, let replayCode, _) = replayReply else {
            Issue.record("Expected a different engine epoch to be rejected")
            return
        }
        #expect(replayCode == .sessionRejected)

        let unknownClaim = TorrentStorageBrokerRequest.openPayload(
            .init(
                requestID: UUID(),
                engineEpoch: engineEpoch,
                sessionNonce: nonce,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            ),
            claimID: UUID(),
            generation: 1,
            fileIndex: 0,
            access: .readOnly
        )
        let unknownClaimReply = try brokerReply(for: unknownClaim, from: gate)
        guard case .failure(
            _,
            let unknownClaimCode,
            _
        ) = unknownClaimReply else {
            Issue.record("Expected an unknown claim to be rejected")
            return
        }
        #expect(unknownClaimCode == .claimUnavailable)
    }

    @Test("Broker request rate is enforced independently of the client")
    func brokerRateLimitIsEnforced() {
        let nonce = UUID()
        let gate = TorrentStorageBrokerSessionGate(
            registry: TorrentStorageBrokerRegistry(),
            sessionNonce: nonce,
            limits: .init(
                maximumInFlightRequests: 1,
                maximumRequestsPerInterval: 1,
                rateIntervalNanoseconds: 1_000_000_000,
                maximumFutureDeadlineNanoseconds: 6_000_000_000
            )
        )
        #expect(gate.handle(handshakeDictionary(nonce: nonce)) != nil)
        #expect(gate.handle(handshakeDictionary(nonce: nonce)) == nil)
        #expect(gate.handle(handshakeDictionary(nonce: nonce)) == nil)
    }

    @Test("Broker rejects deadlines outside its bounded horizon")
    func brokerDeadlineHorizonIsBounded() throws {
        let nonce = UUID()
        let gate = TorrentStorageBrokerSessionGate(
            registry: TorrentStorageBrokerRegistry(),
            sessionNonce: nonce,
            limits: .init(
                maximumInFlightRequests: 1,
                maximumRequestsPerInterval: 1,
                rateIntervalNanoseconds: 1_000_000_000,
                maximumFutureDeadlineNanoseconds: 1_000_000
            )
        )
        let request = handshakeRequest(
            nonce: nonce,
            deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        )
        let response = try #require(gate.handle(
            TorrentStorageBrokerIPCCodec.encode(request)
        ))
        let reply = try TorrentStorageBrokerIPCCodec.decodeReply(
            response,
            for: request
        )
        guard case .failure(_, let code, _) = reply else {
            Issue.record("Expected the distant deadline to be rejected")
            return
        }
        #expect(code == .deadlineExceeded)
    }

    @Test("Broker batch work observes its request deadline")
    func brokerBatchObservesDeadline() throws {
        try withTemporaryDirectory { root in
            let fixture = try reserveSingleFile(in: root, name: "payload.bin", size: 16)
            let claim = makeClaim(fixture.reservation, state: .active)
            let registry = TorrentStorageBrokerRegistry()
            try registry.install(claim: claim, parent: fixture.parent)

            #expect(throws: TorrentStorageBrokerRegistryError.deadlineExceeded) {
                _ = try registry.statBatch(
                    claimID: claim.manifest.claimID,
                    generation: claim.manifest.generation,
                    fileIndices: [0],
                    deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
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
                parentID: claim.manifest.parentID,
                preferredTopLevelName: "journal.bin",
                ownershipKey: claim.manifest.ownership.ownershipKey,
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
            let removalNonce = UUID()
            _ = try await journal.transition(
                claimID: claim.manifest.claimID,
                generation: 1,
                operationNonce: removalNonce,
                from: [.active],
                to: .removing,
                removalIntent: .keepPayload
            )
            await #expect(throws: TorrentStorageJournalError.self) {
                try await journal.completeClaimRemoval(
                    claimID: claim.manifest.claimID,
                    generation: 1,
                    operationNonce: UUID()
                )
            }

            let reloaded = try TorrentStorageClaimJournal(directory: state)
            #expect(await reloaded.claim(id: claim.manifest.claimID)?.lease.state == .removing)
            #expect(await reloaded.claim(id: claim.manifest.claimID)?.torrentID == active.torrentID)
            try await reloaded.completeClaimRemoval(
                claimID: claim.manifest.claimID,
                generation: 1,
                operationNonce: removalNonce
            )
            #expect(await reloaded.allClaims().isEmpty)
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

    @Test("Obsolete journals are rejected and preserved")
    func obsoleteJournalIsPreserved() throws {
        try withTemporaryDirectory { root in
            let state = root.appending(
                path: "State",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: state,
                withIntermediateDirectories: true
            )
            let journalURL = state.appending(path: "StorageClaims.json")
            let obsolete = try Self.obsoleteJournalData(
                schemaVersion: 2,
                claimState: "deleted"
            )
            try obsolete.write(to: journalURL)

            #expect(throws: TorrentStorageJournalError.unsupportedVersion(2)) {
                _ = try TorrentStorageClaimJournal(directory: state)
            }
            #expect(try Data(contentsOf: journalURL) == obsolete)
        }
    }

    @Test("Obsolete live authority is rejected and preserved")
    func obsoleteLiveJournalIsPreserved() throws {
        try withTemporaryDirectory { root in
            let state = root.appending(
                path: "State",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: state,
                withIntermediateDirectories: true
            )
            let journalURL = state.appending(path: "StorageClaims.json")
            let obsolete = try Self.obsoleteJournalData(
                schemaVersion: 2,
                claimState: TorrentStorageClaimState.active.rawValue
            )
            try obsolete.write(to: journalURL)

            #expect(throws: TorrentStorageJournalError.unsupportedVersion(2)) {
                _ = try TorrentStorageClaimJournal(directory: state)
            }
            #expect(try Data(contentsOf: journalURL) == obsolete)
        }
    }

    @Test("Future journal versions are never retired")
    func futureJournalIsPreserved() throws {
        try withTemporaryDirectory { root in
            let state = root.appending(
                path: "State",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: state,
                withIntermediateDirectories: true
            )
            let journalURL = state.appending(path: "StorageClaims.json")
            let future = try Self.obsoleteJournalData(
                schemaVersion: 6,
                claimState: "deleted"
            )
            try future.write(to: journalURL)

            #expect(throws: TorrentStorageJournalError.unsupportedVersion(6)) {
                _ = try TorrentStorageClaimJournal(directory: state)
            }
            #expect(try Data(contentsOf: journalURL) == future)
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
                    filePriorities: [0: .high],
                    labelIDs: ["linux"]
                )
            )
            _ = try await journal.beginPromotionActivation(
                id: promotionID,
                operationNonce: operationNonce,
                activation: activation
            )
            let awaitingDestination = try await journal
                .markPromotionAwaitingDestination(
                    id: promotionID,
                    operationNonce: operationNonce
                )
            #expect(awaitingDestination.state == .awaitingDestination)
            let moved = try await journal.replacePromotionDestination(
                id: promotionID,
                operationNonce: operationNonce,
                destinationPath: "/Other Downloads"
            )
            #expect(moved.destinationPath == "/Other Downloads")
            _ = try await journal.beginPromotionDestinationActivation(
                id: promotionID,
                operationNonce: operationNonce
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

    private static func obsoleteJournalData(
        schemaVersion: UInt64,
        claimState: String
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": schemaVersion,
            "preparations": [],
            "claims": [
                UUID().uuidString,
                ["lease": ["state": claimState]]
            ],
            "promotions": []
        ])
    }

    private enum FIFOOpenOutcome: Equatable, Sendable {
        case pending
        case opened
        case rejected(TorrentStorageBrokerRegistryError)
        case unexpectedError
    }

    private func handshakeDictionary(nonce: UUID) -> XPCDictionary {
        TorrentStorageBrokerIPCCodec.encode(handshakeRequest(nonce: nonce))
    }

    private func handshakeRequest(
        nonce: UUID,
        engineEpoch: UUID = UUID(),
        deadline: UInt64 = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    ) -> TorrentStorageBrokerRequest {
        .handshake(.init(
            requestID: UUID(),
            engineEpoch: engineEpoch,
            sessionNonce: nonce,
            deadlineUptimeNanoseconds: deadline
        ))
    }

    private func brokerReply(
        for request: TorrentStorageBrokerRequest,
        from gate: TorrentStorageBrokerSessionGate
    ) throws -> TorrentStorageBrokerReply {
        let dictionary = try #require(gate.handle(
            TorrentStorageBrokerIPCCodec.encode(request)
        ))
        return try TorrentStorageBrokerIPCCodec.decodeReply(
            dictionary,
            for: request
        )
    }

    private func contents(of descriptor: Int32, count: Int) throws -> Data {
        var result = Data(count: count)
        let bytesRead = unsafe result.withUnsafeMutableBytes { bytes in
            unsafe Darwin.pread(
                descriptor,
                bytes.baseAddress,
                bytes.count,
                0
            )
        }
        guard bytesRead == count else {
            throw CocoaError(.fileReadUnknown)
        }
        return result
    }

    private func ownershipTag(on descriptor: Int32) -> Data? {
        var tag = Data(count: TorrentStorageOwnershipTag.tagByteCount)
        let count = unsafe tag.withUnsafeMutableBytes { bytes in
            unsafe TorrentStorageDestinationPlanner.ownershipAttribute.withCString { name in
                unsafe Darwin.fgetxattr(
                    descriptor,
                    name,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
        }
        return count == tag.count ? tag : nil
    }

    private func deletionQuarantineNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: directory.path()
        ).filter {
            $0.hasPrefix(".torrent7-deletion-")
        }
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
            ownershipKey: TorrentStorageDestinationPlanner.randomOwnershipKey(),
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
        try registry.install(claim: claim, parent: fixture.parent)
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
        availability: [Bool]? = nil,
        nonce: UUID = UUID()
    ) -> TorrentStorageClaim {
        let removalIntent: TorrentStorageRemovalIntent? = switch state {
        case .removing:
            .keepPayload
        case .deleting, .deletionPending:
            .deletePayload
        case .reserved, .activating, .active, .activationUnknown, .orphaned:
            nil
        }
        return TorrentStorageClaim(
            manifest: reservation.storageManifest,
            lease: TorrentStorageLease(
                state: state,
                availabilityRevision: reservation.initialLease.availabilityRevision,
                fileAvailability:
                    availability ?? reservation.initialLease.fileAvailability
            ),
            torrentID: state == .active ? "t:\(String(repeating: "b", count: 32))" : nil,
            operationNonce: nonce,
            removalIntent: removalIntent,
            deletionEvidence: nil
        )
    }

    private func makeDeletingClaim(
        _ reservation: TorrentStorageReservation,
        from parent: TorrentStorageParentAuthority,
        nonce: UUID = UUID()
    ) throws -> TorrentStorageClaim {
        let planner = TorrentStorageDestinationPlanner()
        var claim = makeClaim(
            reservation,
            state: .deleting,
            nonce: nonce
        )
        claim.deletionEvidence = try planner.prepareDeletion(
            claim: claim,
            from: parent
        )
        return claim
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
