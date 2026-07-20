import Darwin
import Foundation
import System
import Testing
@testable import TorrentEngineServiceSupport

@Suite("Torrent legacy state migration")
struct TorrentLegacyStateMigrationTests {
    @Test("Allowlisted resume and tombstone descriptors stage before one atomic marker")
    func stagesAndCommitsAllowlistedFiles() throws {
        let temporary = try MigrationTemporaryDirectory()
        let oldStateURL = try temporary.makeDirectory("OldState")
        let newStateURL = try temporary.makeDirectory("NewState")
        let resumeName = "v1:\(String(repeating: "a", count: 40)).fastresume"
        let tombstoneName = "removal-\(String(repeating: "b", count: 32)).fastresume.remove"
        let resumeSource = oldStateURL.appending(path: resumeName)
        let tombstoneSource = oldStateURL.appending(path: tombstoneName)
        let resumeBytes = Data("resume-state".utf8)
        let tombstoneBytes = Data("tombstone-state".utf8)
        try resumeBytes.write(to: resumeSource)
        try tombstoneBytes.write(to: tombstoneSource)

        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let coordinator = try TorrentLegacyStateMigrationCoordinator(
            engineEpoch: epoch,
            stateDirectoryURL: newStateURL
        )
        #expect(try coordinator.hasCompletedMigration() == false)
        let existingName = "v1:\(String(repeating: "c", count: 40)).fastresume"
        let existingURL = coordinator.resumeDataURL.appending(path: existingName)
        let existingBytes = Data("existing-state".utf8)
        try existingBytes.write(to: existingURL)
        let existingIdentity = try regularFileIdentity(existingURL)
        let migration = try coordinator.begin(scope: scope)
        let resumeDescriptor = try openRegularFile(resumeSource)
        let tombstoneDescriptor = try openRegularFile(tombstoneSource)

        try coordinator.importFile(
            migrationID: migration.id,
            scope: scope,
            filename: resumeName,
            fileDescriptor: resumeDescriptor.rawValue
        )
        #expect(!descriptorStillReferences(resumeDescriptor.rawValue, url: resumeSource))
        try coordinator.importFile(
            migrationID: migration.id,
            scope: scope,
            filename: tombstoneName,
            fileDescriptor: tombstoneDescriptor.rawValue
        )
        #expect(!descriptorStillReferences(tombstoneDescriptor.rawValue, url: tombstoneSource))
        #expect(try coordinator.migration(migrationID: migration.id, scope: scope)?.stagedFileCount == 2)
        #expect(try coordinator.migration(migrationID: migration.id, scope: scope)?.stagedByteCount
            == resumeBytes.count + tombstoneBytes.count)

        let markerURL = coordinator.resumeDataURL.appending(
            path: ".legacy-migration-\(migration.id.uuidString.lowercased()).commit"
        )
        #expect(!FileManager.default.fileExists(atPath: markerURL.path(percentEncoded: false)))

        let artifact = try coordinator.commit(migrationID: migration.id, scope: scope)
        #expect(try coordinator.hasCompletedMigration() == true)
        #expect(artifact.markerURL == markerURL)
        #expect(artifact.directoryURL == coordinator.resumeDataURL)
        #expect(FileManager.default.fileExists(atPath: markerURL.path(percentEncoded: false)))
        #expect(try Data(contentsOf: artifact.directoryURL.appending(path: resumeName))
            == resumeBytes)
        #expect(try Data(contentsOf: artifact.directoryURL.appending(path: tombstoneName))
            == tombstoneBytes)
        #expect(try Data(contentsOf: resumeSource) == resumeBytes)
        #expect(try Data(contentsOf: tombstoneSource) == tombstoneBytes)
        #expect(try Data(contentsOf: coordinator.resumeDataURL.appending(path: existingName))
            == existingBytes)
        #expect(try regularFileIdentity(
            coordinator.resumeDataURL.appending(path: existingName)
        ) == existingIdentity)

        let marker = try String(contentsOf: markerURL, encoding: .utf8)
        #expect(marker.contains("version=1\n"))
        #expect(marker.contains("file_count=2\n"))
        #expect(marker.contains("byte_count=\(resumeBytes.count + tombstoneBytes.count)\n"))
        #expect(try coordinator.commit(migrationID: migration.id, scope: scope) == artifact)
        expectMigrationError(.migrationAlreadyCommitted) {
            try coordinator.abort(migrationID: migration.id, scope: scope)
        }
    }

    @Test("Malformed completion markers fail closed")
    func malformedCompletionMarkerFailsClosed() throws {
        let temporary = try MigrationTemporaryDirectory()
        let coordinator = try TorrentLegacyStateMigrationCoordinator(
            engineEpoch: UUID(),
            stateDirectoryURL: try temporary.makeDirectory("MalformedMarkerState")
        )
        let markerURL = coordinator.resumeDataURL.appending(
            path: ".legacy-migration-not-a-uuid.commit"
        )
        try Data("version=1\n".utf8).write(to: markerURL)

        expectMigrationError(.destinationStateInvalid) {
            _ = try coordinator.hasCompletedMigration()
        }
    }

    @Test("Startup removes only exact UUID-scoped crash debris")
    func startupRecoversInterruptedArtifacts() throws {
        let temporary = try MigrationTemporaryDirectory()
        let stateURL = try temporary.makeDirectory("RecoveryState")
        var initial: TorrentLegacyStateMigrationCoordinator? = try TorrentLegacyStateMigrationCoordinator(
            engineEpoch: UUID(),
            stateDirectoryURL: stateURL
        )
        let migrationRootURL = try #require(initial?.migrationRootURL)
        initial = nil

        let stagingID = UUID()
        let publicationID = UUID()
        let stagingURL = migrationRootURL.appending(
            path: "migration-\(stagingID.uuidString.lowercased()).staging",
            directoryHint: .isDirectory
        )
        let publicationURL = migrationRootURL.appending(
            path: "migration-\(publicationID.uuidString.lowercased()).publishing",
            directoryHint: .isDirectory
        )
        let nearMatchURL = migrationRootURL.appending(
            path: "migration-\(UUID().uuidString.lowercased()).staging-backup",
            directoryHint: .isDirectory
        )
        for url in [stagingURL, publicationURL, nearMatchURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data("crash-debris".utf8).write(to: url.appending(path: "partial"))
        }

        let recovered = try TorrentLegacyStateMigrationCoordinator(
            engineEpoch: UUID(),
            stateDirectoryURL: stateURL
        )
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: publicationURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: nearMatchURL.path(percentEncoded: false)))
        #expect(try recovered.hasCompletedMigration() == false)
    }

    @Test("Startup rejects an exact crash artifact that is not an owned directory")
    func startupRejectsSymlinkCrashArtifact() throws {
        let temporary = try MigrationTemporaryDirectory()
        let stateURL = try temporary.makeDirectory("SymlinkRecoveryState")
        var initial: TorrentLegacyStateMigrationCoordinator? = try TorrentLegacyStateMigrationCoordinator(
            engineEpoch: UUID(),
            stateDirectoryURL: stateURL
        )
        let migrationRootURL = try #require(initial?.migrationRootURL)
        initial = nil

        let outsideURL = try temporary.makeDirectory("OutsideRecoveryTarget")
        let linkURL = migrationRootURL.appending(
            path: "migration-\(UUID().uuidString.lowercased()).staging",
            directoryHint: .isDirectory
        )
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)

        expectMigrationError(.stagingDirectoryFailed) {
            _ = try TorrentLegacyStateMigrationCoordinator(
                engineEpoch: UUID(),
                stateDirectoryURL: stateURL
            )
        }
        #expect(FileManager.default.fileExists(atPath: linkURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: outsideURL.path(percentEncoded: false)))
    }

    @Test("Post-swap sync failure retains recovery material until the next launch")
    func postSwapDurabilityFailureIsRecoverable() throws {
        let temporary = try MigrationTemporaryDirectory()
        let oldStateURL = try temporary.makeDirectory("DurabilityOldState")
        let stateURL = try temporary.makeDirectory("DurabilityNewState")
        let importedName = "v1:\(String(repeating: "8", count: 40)).fastresume"
        let existingName = "v1:\(String(repeating: "9", count: 40)).fastresume"
        let importedBytes = Data("imported-after-swap".utf8)
        let existingBytes = Data("existing-before-swap".utf8)
        let importedSourceURL = oldStateURL.appending(path: "source")
        try importedBytes.write(to: importedSourceURL)

        let failure = OneShotResumeDataSyncFailure()
        let operations = TorrentLegacyStateMigrationFileOperations { url in
            try failure.syncDirectory(url)
        }
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        var coordinator: TorrentLegacyStateMigrationCoordinator? = try TorrentLegacyStateMigrationCoordinator(
            engineEpoch: epoch,
            stateDirectoryURL: stateURL,
            fileOperations: operations
        )
        let resumeDataURL = try #require(coordinator?.resumeDataURL)
        let migrationRootURL = try #require(coordinator?.migrationRootURL)
        try existingBytes.write(to: resumeDataURL.appending(path: existingName))
        let migration = try #require(coordinator).begin(scope: scope)
        try #require(coordinator).importFile(
            migrationID: migration.id,
            scope: scope,
            filename: importedName,
            fileDescriptor: try openRegularFile(importedSourceURL).rawValue
        )

        let stagingURL = migrationRootURL.appending(
            path: "migration-\(migration.id.uuidString.lowercased()).staging",
            directoryHint: .isDirectory
        )
        let publicationURL = migrationRootURL.appending(
            path: "migration-\(migration.id.uuidString.lowercased()).publishing",
            directoryHint: .isDirectory
        )
        expectMigrationError(.commitFailed) {
            _ = try #require(coordinator).commit(migrationID: migration.id, scope: scope)
        }

        #expect(try #require(coordinator).hasCompletedMigration())
        #expect(try Data(contentsOf: resumeDataURL.appending(path: importedName)) == importedBytes)
        #expect(try Data(contentsOf: resumeDataURL.appending(path: existingName)) == existingBytes)
        #expect(try Data(contentsOf: stagingURL.appending(path: importedName)) == importedBytes)
        #expect(try Data(contentsOf: publicationURL.appending(path: existingName)) == existingBytes)

        coordinator = nil
        let recovered = try TorrentLegacyStateMigrationCoordinator(
            engineEpoch: UUID(),
            stateDirectoryURL: stateURL
        )
        #expect(try recovered.hasCompletedMigration())
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: publicationURL.path(percentEncoded: false)))
        #expect(try Data(contentsOf: recovered.resumeDataURL.appending(path: importedName))
            == importedBytes)
        #expect(try Data(contentsOf: recovered.resumeDataURL.appending(path: existingName))
            == existingBytes)
        #expect(try Data(contentsOf: importedSourceURL) == importedBytes)
    }

    @Test("Commit never overwrites an existing ResumeData filename")
    func existingDestinationCollisionIsAtomic() throws {
        let temporary = try MigrationTemporaryDirectory()
        let oldStateURL = try temporary.makeDirectory("OldCollisionState")
        let newStateURL = try temporary.makeDirectory("NewCollisionState")
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let coordinator = try TorrentLegacyStateMigrationCoordinator(
            engineEpoch: epoch,
            stateDirectoryURL: newStateURL
        )

        let collisionName = "v1:\(String(repeating: "d", count: 40)).fastresume"
        let otherName = "v1:\(String(repeating: "e", count: 40)).fastresume"
        let destinationCollisionURL = coordinator.resumeDataURL.appending(path: collisionName)
        let originalDestinationBytes = Data("new-engine-state".utf8)
        try originalDestinationBytes.write(to: destinationCollisionURL)
        let originalDestinationIdentity = try regularFileIdentity(destinationCollisionURL)

        let oldCollisionURL = oldStateURL.appending(path: "old-collision")
        let oldOtherURL = oldStateURL.appending(path: "old-other")
        try Data("legacy-collision".utf8).write(to: oldCollisionURL)
        try Data("legacy-other".utf8).write(to: oldOtherURL)

        let migration = try coordinator.begin(scope: scope)
        try coordinator.importFile(
            migrationID: migration.id,
            scope: scope,
            filename: collisionName,
            fileDescriptor: try openRegularFile(oldCollisionURL).rawValue
        )
        try coordinator.importFile(
            migrationID: migration.id,
            scope: scope,
            filename: otherName,
            fileDescriptor: try openRegularFile(oldOtherURL).rawValue
        )

        expectMigrationError(.destinationFileExists(collisionName)) {
            _ = try coordinator.commit(migrationID: migration.id, scope: scope)
        }
        #expect(try Data(contentsOf: destinationCollisionURL) == originalDestinationBytes)
        #expect(try regularFileIdentity(destinationCollisionURL) == originalDestinationIdentity)
        #expect(!FileManager.default.fileExists(atPath: coordinator.resumeDataURL
            .appending(path: otherName)
            .path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: coordinator.resumeDataURL
            .appending(
                path: ".legacy-migration-\(migration.id.uuidString.lowercased()).commit"
            )
            .path(percentEncoded: false)))
        #expect(try Data(contentsOf: oldCollisionURL) == Data("legacy-collision".utf8))
        #expect(try Data(contentsOf: oldOtherURL) == Data("legacy-other".utf8))
        #expect(try coordinator.migration(migrationID: migration.id, scope: scope)?.stagedFileCount
            == 2)
    }

    @Test("Filename allowlist is exact and rejected descriptors are still consumed")
    func filenameAllowlist() throws {
        let temporary = try MigrationTemporaryDirectory()
        let coordinator = try TorrentLegacyStateMigrationCoordinator(
            engineEpoch: UUID(),
            stateDirectoryURL: try temporary.makeDirectory("State")
        )
        let scope = TorrentEngineServiceScope(
            engineEpoch: coordinator.engineEpoch,
            controllerID: UUID()
        )
        let migration = try coordinator.begin(scope: scope)

        for invalidName in [
            "../v1:\(String(repeating: "a", count: 40)).fastresume",
            "arbitrary.fastresume",
            "v1:\(String(repeating: "A", count: 40)).fastresume",
            "removal-\(String(repeating: "A", count: 32)).fastresume.remove",
            "removal-\(String(repeating: "a", count: 31)).fastresume.remove",
            "v2:\(String(repeating: "a", count: 64)).fastresume.tmp",
        ] {
            let sourceURL = temporary.url.appending(path: UUID().uuidString)
            try Data("state".utf8).write(to: sourceURL)
            let descriptor = try openRegularFile(sourceURL)
            expectMigrationError(.invalidFilename) {
                try coordinator.importFile(
                    migrationID: migration.id,
                    scope: scope,
                    filename: invalidName,
                    fileDescriptor: descriptor.rawValue
                )
            }
            #expect(!descriptorStillReferences(descriptor.rawValue, url: sourceURL))
        }
        #expect(try coordinator.migration(migrationID: migration.id, scope: scope)?.stagedFileCount == 0)
    }

    @Test("Symlink, FIFO, device, unlinked, empty, and oversized descriptors fail closed")
    func descriptorValidation() throws {
        let temporary = try MigrationTemporaryDirectory()
        let stateURL = try temporary.makeDirectory("State")
        let limits = TorrentLegacyStateMigrationLimits(
            maximumConcurrentMigrationCount: 2,
            maximumFileCount: 8,
            maximumResumeFileBytes: 4,
            maximumTombstoneFileBytes: 4,
            maximumAggregateBytes: 16
        )
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let coordinator = try TorrentLegacyStateMigrationCoordinator(
            engineEpoch: epoch,
            stateDirectoryURL: stateURL,
            limits: limits
        )
        let migration = try coordinator.begin(scope: scope)
        let filename = "t:\(String(repeating: "a", count: 32)).fastresume"

        let emptyURL = temporary.url.appending(path: "empty")
        try Data().write(to: emptyURL)
        let emptyDescriptor = try openRegularFile(emptyURL)
        expectMigrationError(.emptyFile) {
            try coordinator.importFile(
                migrationID: migration.id,
                scope: scope,
                filename: filename,
                fileDescriptor: emptyDescriptor.rawValue
            )
        }
        #expect(!descriptorStillReferences(emptyDescriptor.rawValue, url: emptyURL))

        let oversizedURL = temporary.url.appending(path: "oversized")
        try Data(repeating: 7, count: 5).write(to: oversizedURL)
        let oversizedDescriptor = try openRegularFile(oversizedURL)
        expectMigrationError(.fileTooLarge(actual: 5, maximum: 4)) {
            try coordinator.importFile(
                migrationID: migration.id,
                scope: scope,
                filename: filename,
                fileDescriptor: oversizedDescriptor.rawValue
            )
        }
        #expect(!descriptorStillReferences(oversizedDescriptor.rawValue, url: oversizedURL))

        let targetURL = temporary.url.appending(path: "target")
        let symlinkURL = temporary.url.appending(path: "symlink")
        try Data("ok".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
        let symlinkDescriptor = try FileDescriptor.open(
            FilePath(symlinkURL.path(percentEncoded: false)),
            .readOnly,
            options: [.closeOnExec, .symlink]
        )
        expectMigrationError(.sourceIsNotRegularFile) {
            try coordinator.importFile(
                migrationID: migration.id,
                scope: scope,
                filename: filename,
                fileDescriptor: symlinkDescriptor.rawValue
            )
        }
        #expect(!descriptorStillReferences(symlinkDescriptor.rawValue, url: symlinkURL))

        let fifoURL = temporary.url.appending(path: "fifo")
        let fifoStatus = unsafe fifoURL.path(percentEncoded: false).withCString { pointer in
            unsafe Darwin.mkfifo(pointer, 0o600)
        }
        #expect(fifoStatus == 0)
        let fifoDescriptor = try FileDescriptor.open(
            FilePath(fifoURL.path(percentEncoded: false)),
            .readOnly,
            options: [.closeOnExec, .noFollow, .nonBlocking]
        )
        expectMigrationError(.sourceIsNotRegularFile) {
            try coordinator.importFile(
                migrationID: migration.id,
                scope: scope,
                filename: filename,
                fileDescriptor: fifoDescriptor.rawValue
            )
        }
        #expect(!descriptorStillReferences(fifoDescriptor.rawValue, url: fifoURL))

        let deviceDescriptor = try FileDescriptor.open(
            FilePath("/dev/null"),
            .readOnly,
            options: [.closeOnExec, .noFollow]
        )
        expectMigrationError(.sourceIsNotRegularFile) {
            try coordinator.importFile(
                migrationID: migration.id,
                scope: scope,
                filename: filename,
                fileDescriptor: deviceDescriptor.rawValue
            )
        }
        #expect(!descriptorStillReferences(deviceDescriptor.rawValue, url: URL(filePath: "/dev/null")))

        let unlinkedURL = temporary.url.appending(path: "unlinked")
        try Data("ok".utf8).write(to: unlinkedURL)
        let unlinkedDescriptor = try openRegularFile(unlinkedURL)
        try FileManager.default.removeItem(at: unlinkedURL)
        expectMigrationError(.sourcePathCouldNotBeVerified) {
            try coordinator.importFile(
                migrationID: migration.id,
                scope: scope,
                filename: filename,
                fileDescriptor: unlinkedDescriptor.rawValue
            )
        }
        #expect(!descriptorStillReferences(unlinkedDescriptor.rawValue, url: unlinkedURL))
    }

    @Test("File count and aggregate limits preserve already-staged files")
    func stagedLimits() throws {
        let temporary = try MigrationTemporaryDirectory()
        let stateURL = try temporary.makeDirectory("State")
        let limits = TorrentLegacyStateMigrationLimits(
            maximumConcurrentMigrationCount: 2,
            maximumFileCount: 2,
            maximumResumeFileBytes: 8,
            maximumTombstoneFileBytes: 8,
            maximumAggregateBytes: 5
        )
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let coordinator = try TorrentLegacyStateMigrationCoordinator(
            engineEpoch: epoch,
            stateDirectoryURL: stateURL,
            limits: limits
        )
        let migration = try coordinator.begin(scope: scope)
        let firstName = "v1:\(String(repeating: "1", count: 40)).fastresume"
        let secondName = "v1:\(String(repeating: "2", count: 40)).fastresume"
        let thirdName = "v1:\(String(repeating: "3", count: 40)).fastresume"
        let firstURL = temporary.url.appending(path: "first")
        let secondURL = temporary.url.appending(path: "second")
        try Data("abc".utf8).write(to: firstURL)
        try Data("def".utf8).write(to: secondURL)

        try coordinator.importFile(
            migrationID: migration.id,
            scope: scope,
            filename: firstName,
            fileDescriptor: try openRegularFile(firstURL).rawValue
        )
        let secondDescriptor = try openRegularFile(secondURL)
        expectMigrationError(.aggregateTooLarge(maximum: 5)) {
            try coordinator.importFile(
                migrationID: migration.id,
                scope: scope,
                filename: secondName,
                fileDescriptor: secondDescriptor.rawValue
            )
        }
        #expect(!descriptorStillReferences(secondDescriptor.rawValue, url: secondURL))
        let oneByteURL = temporary.url.appending(path: "one-byte")
        try Data("x".utf8).write(to: oneByteURL)
        try coordinator.importFile(
            migrationID: migration.id,
            scope: scope,
            filename: secondName,
            fileDescriptor: try openRegularFile(oneByteURL).rawValue
        )
        let overCountDescriptor = try openRegularFile(oneByteURL)
        expectMigrationError(.tooManyFiles(maximum: 2)) {
            try coordinator.importFile(
                migrationID: migration.id,
                scope: scope,
                filename: thirdName,
                fileDescriptor: overCountDescriptor.rawValue
            )
        }
        #expect(!descriptorStillReferences(overCountDescriptor.rawValue, url: oneByteURL))
        #expect(try coordinator.migration(migrationID: migration.id, scope: scope)?.stagedFileCount == 2)
        #expect(try coordinator.migration(migrationID: migration.id, scope: scope)?.stagedByteCount == 4)

        let artifact = try coordinator.commit(migrationID: migration.id, scope: scope)
        #expect(artifact.fileCount == 2)
        #expect(try Data(contentsOf: artifact.directoryURL.appending(path: firstName))
            == Data("abc".utf8))
        #expect(try Data(contentsOf: artifact.directoryURL.appending(path: secondName))
            == Data("x".utf8))
    }

    @Test("Abort and disconnect remove only uncommitted staging data")
    func abortAndDisconnectCleanup() throws {
        let temporary = try MigrationTemporaryDirectory()
        let oldURL = try temporary.makeDirectory("Old")
        let stateURL = try temporary.makeDirectory("State")
        let sourceURL = oldURL.appending(path: "source")
        try Data("legacy".utf8).write(to: sourceURL)

        let epoch = UUID()
        let controllerID = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: controllerID)
        let coordinator = try TorrentLegacyStateMigrationCoordinator(
            engineEpoch: epoch,
            stateDirectoryURL: stateURL
        )
        let filename = "v2:\(String(repeating: "3", count: 64)).fastresume"

        let aborted = try coordinator.begin(scope: scope)
        try coordinator.importFile(
            migrationID: aborted.id,
            scope: scope,
            filename: filename,
            fileDescriptor: try openRegularFile(sourceURL).rawValue
        )
        let abortedStagingURL = coordinator.migrationRootURL.appending(
            path: "migration-\(aborted.id.uuidString.lowercased()).staging"
        )
        #expect(FileManager.default.fileExists(atPath: abortedStagingURL.path(percentEncoded: false)))
        try coordinator.abort(migrationID: aborted.id, scope: scope)
        #expect(!FileManager.default.fileExists(atPath: abortedStagingURL.path(percentEncoded: false)))
        #expect(try Data(contentsOf: sourceURL) == Data("legacy".utf8))

        let disconnected = try coordinator.begin(scope: scope)
        try coordinator.importFile(
            migrationID: disconnected.id,
            scope: scope,
            filename: filename,
            fileDescriptor: try openRegularFile(sourceURL).rawValue
        )
        let disconnectedStagingURL = coordinator.migrationRootURL.appending(
            path: "migration-\(disconnected.id.uuidString.lowercased()).staging"
        )
        coordinator.disconnect(scope: scope)
        #expect(!FileManager.default.fileExists(atPath: disconnectedStagingURL.path(percentEncoded: false)))
        expectMigrationError(.controllerDisconnected) {
            _ = try coordinator.migration(migrationID: disconnected.id, scope: scope)
        }
        #expect(try Data(contentsOf: sourceURL) == Data("legacy".utf8))
    }

    @Test("Migration cleanup is generation-exact and permits wire identifier reuse")
    func migrationCleanupUsesExactGeneration() throws {
        let temporary = try MigrationTemporaryDirectory()
        let epoch = UUID()
        let controllerID = UUID()
        let oldScope = TorrentEngineServiceScope(
            engineEpoch: epoch,
            controllerID: controllerID
        )
        let freshScope = TorrentEngineServiceScope(
            engineEpoch: epoch,
            controllerID: controllerID
        )
        let coordinator = try TorrentLegacyStateMigrationCoordinator(
            engineEpoch: epoch,
            stateDirectoryURL: try temporary.makeDirectory("State")
        )
        let oldMigration = try coordinator.begin(scope: oldScope)
        let oldStagingURL = coordinator.migrationRootURL.appending(
            path: "migration-\(oldMigration.id.uuidString.lowercased()).staging"
        )
        let freshMigration = try coordinator.begin(scope: freshScope)
        let freshStagingURL = coordinator.migrationRootURL.appending(
            path: "migration-\(freshMigration.id.uuidString.lowercased()).staging"
        )

        #expect(oldScope.controllerID == freshScope.controllerID)
        #expect(oldScope.generation != freshScope.generation)

        oldScope.invalidate()

        expectMigrationError(.controllerDisconnected) {
            _ = try coordinator.migration(migrationID: oldMigration.id, scope: oldScope)
        }
        #expect(FileManager.default.fileExists(atPath: oldStagingURL.path(percentEncoded: false)))
        #expect(try coordinator.migration(
            migrationID: freshMigration.id,
            scope: freshScope
        ) == freshMigration)

        coordinator.disconnect(scope: oldScope)

        #expect(!FileManager.default.fileExists(atPath: oldStagingURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: freshStagingURL.path(percentEncoded: false)))
        #expect(freshMigration.scope == freshScope)
        expectMigrationError(.controllerDisconnected) {
            _ = try coordinator.migration(migrationID: freshMigration.id, scope: oldScope)
        }
        #expect(try coordinator.migration(
            migrationID: freshMigration.id,
            scope: freshScope
        ) == freshMigration)

        coordinator.disconnect(scope: freshScope)
        #expect(!FileManager.default.fileExists(atPath: freshStagingURL.path(percentEncoded: false)))
    }

    @Test("Migration identifiers are epoch and controller scoped")
    func migrationScope() throws {
        let temporary = try MigrationTemporaryDirectory()
        let epoch = UUID()
        let controllerID = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: controllerID)
        let wrongController = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let wrongEpoch = TorrentEngineServiceScope(engineEpoch: UUID(), controllerID: controllerID)
        let coordinator = try TorrentLegacyStateMigrationCoordinator(
            engineEpoch: epoch,
            stateDirectoryURL: try temporary.makeDirectory("State")
        )
        let migration = try coordinator.begin(scope: scope)

        expectMigrationError(.wrongEngineEpoch) {
            _ = try coordinator.migration(migrationID: migration.id, scope: wrongEpoch)
        }
        expectMigrationError(.unknownMigration) {
            try coordinator.abort(migrationID: migration.id, scope: wrongController)
        }
        #expect(try coordinator.migration(migrationID: migration.id, scope: scope) == migration)
    }
}

private final class MigrationTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "TorrentLegacyStateMigrationTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func makeDirectory(_ name: String) throws -> URL {
        let child = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        return child
    }
}

private enum MigrationInjectedFailure: Error {
    case resumeDataSync
}

private final class OneShotResumeDataSyncFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFailed = false

    func syncDirectory(_ url: URL) throws {
        let shouldFail = lock.withLock {
            guard !hasFailed, url.lastPathComponent == "ResumeData" else {
                return false
            }
            hasFailed = true
            return true
        }
        if shouldFail {
            throw MigrationInjectedFailure.resumeDataSync
        }
        try TorrentLegacyStateMigrationFileOperations.live.syncDirectory(url)
    }
}

private func openRegularFile(_ url: URL) throws -> FileDescriptor {
    try FileDescriptor.open(
        FilePath(url.path(percentEncoded: false)),
        .readOnly,
        options: [.closeOnExec, .noFollow]
    )
}

private func descriptorStillReferences(_ descriptor: Int32, url: URL) -> Bool {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let copied = unsafe path.withUnsafeMutableBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return false
        }
        return unsafe Darwin.fcntl(descriptor, F_GETPATH, baseAddress) != -1
    }
    guard copied else {
        return false
    }
    return unsafe path.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return false
        }
        return unsafe String(cString: baseAddress) == url.path(percentEncoded: false)
    }
}

private struct MigrationTestFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

private func regularFileIdentity(_ url: URL) throws -> MigrationTestFileIdentity {
    var metadata = stat()
    let status = unsafe url.path(percentEncoded: false).withCString { pointer in
        unsafe Darwin.lstat(pointer, &metadata)
    }
    guard status == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
        throw CocoaError(.fileReadUnknown)
    }
    return MigrationTestFileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
}

private func expectMigrationError(
    _ expected: TorrentLegacyStateMigrationError,
    performing operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected migration error: \(expected)")
    } catch let error as TorrentLegacyStateMigrationError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
