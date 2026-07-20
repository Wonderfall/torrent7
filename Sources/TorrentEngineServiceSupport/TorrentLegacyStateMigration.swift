import Darwin
import Foundation
import Synchronization
import System

package struct TorrentLegacyStateMigrationLimits: Equatable, Sendable {
    package static let `default` = Self(
        maximumConcurrentMigrationCount: 4,
        maximumFileCount: 20_000,
        maximumResumeFileBytes: 64 * 1_024 * 1_024,
        maximumTombstoneFileBytes: 16 * 1_024,
        maximumAggregateBytes: 256 * 1_024 * 1_024
    )

    package let maximumConcurrentMigrationCount: Int
    package let maximumFileCount: Int
    package let maximumResumeFileBytes: Int
    package let maximumTombstoneFileBytes: Int
    package let maximumAggregateBytes: Int

    package init(
        maximumConcurrentMigrationCount: Int,
        maximumFileCount: Int,
        maximumResumeFileBytes: Int,
        maximumTombstoneFileBytes: Int,
        maximumAggregateBytes: Int
    ) {
        precondition(maximumConcurrentMigrationCount > 0)
        precondition(maximumFileCount > 0)
        precondition(maximumResumeFileBytes > 0)
        precondition(maximumTombstoneFileBytes > 0)
        precondition(maximumAggregateBytes > 0)
        self.maximumConcurrentMigrationCount = maximumConcurrentMigrationCount
        self.maximumFileCount = maximumFileCount
        self.maximumResumeFileBytes = maximumResumeFileBytes
        self.maximumTombstoneFileBytes = maximumTombstoneFileBytes
        self.maximumAggregateBytes = maximumAggregateBytes
    }
}

package struct TorrentLegacyStateMigrationFileOperations: Sendable {
    package static let live = Self(syncDirectory: syncMigrationDirectory)

    package let syncDirectory: @Sendable (URL) throws -> Void

    package init(syncDirectory: @escaping @Sendable (URL) throws -> Void) {
        self.syncDirectory = syncDirectory
    }
}

package enum TorrentLegacyStateMigrationError: Error, Equatable, Sendable {
    case wrongEngineEpoch
    case controllerDisconnected
    case tooManyConcurrentMigrations(maximum: Int)
    case unknownMigration
    case migrationAlreadyCommitted
    case emptyMigration
    case invalidFilename
    case duplicateFilename
    case invalidFileDescriptor
    case sourceIsNotRegularFile
    case sourcePathCouldNotBeVerified
    case emptyFile
    case fileTooLarge(actual: Int, maximum: Int)
    case tooManyFiles(maximum: Int)
    case aggregateTooLarge(maximum: Int)
    case destinationFileExists(String)
    case destinationStateInvalid
    case stagingDirectoryFailed
    case fileCopyFailed
    case commitFailed
}

package struct TorrentLegacyStateMigration: Equatable, Sendable {
    package let id: UUID
    package let scope: TorrentEngineServiceScope
    package let stagedFileCount: Int
    package let stagedByteCount: Int
}

package struct TorrentLegacyStateMigrationCommit: Equatable, Sendable {
    package let migrationID: UUID
    package let directoryURL: URL
    package let markerURL: URL
    package let fileCount: Int
    package let byteCount: Int
}

/// Imports only bytes supplied through owned descriptors. It never traverses or
/// mutates the legacy state tree, so a failed or successful migration leaves the
/// old installation available for rollback.
package final class TorrentLegacyStateMigrationCoordinator: Sendable {
    private struct State: Sendable {
        var sessionsByID = [UUID: TorrentLegacyStateMigrationSession]()
    }

    package let engineEpoch: UUID
    package let stateDirectoryURL: URL
    package let resumeDataURL: URL
    package let migrationRootURL: URL

    private let limits: TorrentLegacyStateMigrationLimits
    private let fileOperations: TorrentLegacyStateMigrationFileOperations
    private let state = Mutex(State())

    package init(
        engineEpoch: UUID,
        stateDirectoryURL: URL,
        limits: TorrentLegacyStateMigrationLimits = .default,
        fileOperations: TorrentLegacyStateMigrationFileOperations = .live
    ) throws {
        self.engineEpoch = engineEpoch
        self.limits = limits
        self.fileOperations = fileOperations
        do {
            let stateDirectory = try Self.prepareOwnedDirectory(stateDirectoryURL)
            self.stateDirectoryURL = stateDirectory
            resumeDataURL = try Self.prepareOwnedDirectory(
                stateDirectory.appending(path: "ResumeData", directoryHint: .isDirectory)
            )
            migrationRootURL = try Self.prepareOwnedDirectory(
                stateDirectory.appending(
                    path: "LegacyStateMigrations",
                    directoryHint: .isDirectory
                )
            )
            try Self.recoverInterruptedArtifacts(
                in: migrationRootURL,
                syncDirectory: fileOperations.syncDirectory
            )
        } catch {
            throw TorrentLegacyStateMigrationError.stagingDirectoryFailed
        }
    }

    deinit {
        cleanupEveryUncommittedSession()
    }

    package func begin(scope: TorrentEngineServiceScope) throws -> TorrentLegacyStateMigration {
        try validate(scope: scope)
        return try state.withLock { state in
            try requireConnectedController(scope: scope)
            guard state.sessionsByID.count < limits.maximumConcurrentMigrationCount else {
                throw TorrentLegacyStateMigrationError.tooManyConcurrentMigrations(
                    maximum: limits.maximumConcurrentMigrationCount
                )
            }

            let id = makeMigrationID(in: state)
            let stagingURL = migrationRootURL.appending(
                path: Self.stagingDirectoryName(id: id),
                directoryHint: .isDirectory
            )
            do {
                try FileManager.default.createDirectory(
                    at: stagingURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                _ = try Self.verifyOwnedDirectory(stagingURL)
            } catch {
                try? FileManager.default.removeItem(at: stagingURL)
                throw TorrentLegacyStateMigrationError.stagingDirectoryFailed
            }

            let session = TorrentLegacyStateMigrationSession(
                id: id,
                scope: scope,
                directoryURL: stagingURL,
                state: .staging,
                filenames: [],
                byteCount: 0
            )
            state.sessionsByID[id] = session
            return session.snapshot
        }
    }

    /// Returns true only for a structurally valid, owner-only commit marker in
    /// the live ResumeData directory. This makes the one-time import idempotent
    /// across service launches without trusting controller-side preferences.
    package func hasCompletedMigration() throws -> Bool {
        try state.withLock { _ in
            do {
                _ = try Self.verifyOwnedDirectory(resumeDataURL)
                let children = try FileManager.default.contentsOfDirectory(
                    at: resumeDataURL,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                for child in children {
                    let filename = child.lastPathComponent
                    guard filename.hasPrefix(Self.commitMarkerPrefix) else {
                        continue
                    }
                    guard let migrationID = Self.migrationID(fromCommitMarker: filename) else {
                        throw TorrentLegacyStateMigrationError.destinationStateInvalid
                    }
                    try Self.validateCommitMarker(
                        at: child,
                        migrationID: migrationID,
                        limits: limits
                    )
                    return true
                }
                return false
            } catch let error as TorrentLegacyStateMigrationError {
                throw error
            } catch {
                throw TorrentLegacyStateMigrationError.destinationStateInvalid
            }
        }
    }

    /// Takes ownership of `fileDescriptor` and closes it exactly once on every path.
    package func importFile(
        migrationID: UUID,
        scope: TorrentEngineServiceScope,
        filename: String,
        fileDescriptor: Int32
    ) throws {
        let source = FileDescriptor(rawValue: fileDescriptor)
        defer {
            try? source.close()
        }

        try validate(scope: scope)
        guard fileDescriptor >= 0 else {
            throw TorrentLegacyStateMigrationError.invalidFileDescriptor
        }
        let kind = try TorrentLegacyStateFilename.classify(filename)

        try state.withLock { state in
            try requireConnectedController(scope: scope)
            guard var session = session(
                migrationID: migrationID,
                scope: scope,
                in: state
            ) else {
                throw TorrentLegacyStateMigrationError.unknownMigration
            }
            guard case .staging = session.state else {
                throw TorrentLegacyStateMigrationError.migrationAlreadyCommitted
            }
            guard !session.filenames.contains(filename) else {
                throw TorrentLegacyStateMigrationError.duplicateFilename
            }
            guard session.filenames.count < limits.maximumFileCount else {
                throw TorrentLegacyStateMigrationError.tooManyFiles(
                    maximum: limits.maximumFileCount
                )
            }

            let metadata = try Self.validatedSourceMetadata(
                descriptor: source,
                maximumBytes: maximumBytes(for: kind)
            )
            guard metadata.byteCount <= limits.maximumAggregateBytes - session.byteCount else {
                throw TorrentLegacyStateMigrationError.aggregateTooLarge(
                    maximum: limits.maximumAggregateBytes
                )
            }

            let destinationURL = session.directoryURL.appending(
                path: filename,
                directoryHint: .notDirectory
            )
            try Self.copyVerifiedSource(
                source,
                metadata: metadata,
                to: destinationURL
            )
            session.filenames.insert(filename)
            session.byteCount += metadata.byteCount
            state.sessionsByID[migrationID] = session
        }
    }

    package func commit(
        migrationID: UUID,
        scope: TorrentEngineServiceScope
    ) throws -> TorrentLegacyStateMigrationCommit {
        try validate(scope: scope)
        return try state.withLock { state in
            try requireConnectedController(scope: scope)
            guard var session = session(
                migrationID: migrationID,
                scope: scope,
                in: state
            ) else {
                throw TorrentLegacyStateMigrationError.unknownMigration
            }

            if case .committed(let artifact) = session.state {
                try finishCommittedMigration(session: session)
                return artifact
            }
            guard !session.filenames.isEmpty else {
                throw TorrentLegacyStateMigrationError.emptyMigration
            }
            guard case .staging = session.state else {
                throw TorrentLegacyStateMigrationError.commitFailed
            }

            let existingFilenames = try Self.allowlistedFilenames(in: resumeDataURL)
            if let collision = session.filenames.intersection(existingFilenames).sorted().first {
                throw TorrentLegacyStateMigrationError.destinationFileExists(collision)
            }
            guard existingFilenames.count <= limits.maximumFileCount - session.filenames.count else {
                throw TorrentLegacyStateMigrationError.tooManyFiles(
                    maximum: limits.maximumFileCount
                )
            }

            let publicationURL = migrationRootURL.appending(
                path: Self.publicationDirectoryName(id: migrationID),
                directoryHint: .isDirectory
            )
            try? FileManager.default.removeItem(at: publicationURL)
            do {
                try FileManager.default.createDirectory(
                    at: publicationURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                _ = try Self.verifyOwnedDirectory(publicationURL)

                var publishedByteCount = 0
                for filename in existingFilenames.sorted() {
                    let copiedByteCount = try preserveStateFile(
                        filename: filename,
                        from: resumeDataURL,
                        to: publicationURL
                    )
                    guard copiedByteCount <= limits.maximumAggregateBytes - publishedByteCount else {
                        throw TorrentLegacyStateMigrationError.aggregateTooLarge(
                            maximum: limits.maximumAggregateBytes
                        )
                    }
                    publishedByteCount += copiedByteCount
                }

                var importedByteCount = 0
                for filename in session.filenames.sorted() {
                    let copiedByteCount = try copyStateFile(
                        filename: filename,
                        from: session.directoryURL,
                        to: publicationURL
                    )
                    guard copiedByteCount <= limits.maximumAggregateBytes - publishedByteCount,
                          copiedByteCount <= limits.maximumAggregateBytes - importedByteCount else {
                        throw TorrentLegacyStateMigrationError.aggregateTooLarge(
                            maximum: limits.maximumAggregateBytes
                        )
                    }
                    publishedByteCount += copiedByteCount
                    importedByteCount += copiedByteCount
                }
                guard importedByteCount == session.byteCount else {
                    throw TorrentLegacyStateMigrationError.destinationStateInvalid
                }

                let stagingContents = try Self.allowlistedFilenames(in: session.directoryURL)
                guard stagingContents == session.filenames else {
                    throw TorrentLegacyStateMigrationError.destinationStateInvalid
                }

                let markerName = Self.commitMarkerName(id: migrationID)
                let publicationMarkerURL = publicationURL.appending(path: markerName)
                let finalMarkerURL = resumeDataURL.appending(path: markerName)
                let artifact = TorrentLegacyStateMigrationCommit(
                    migrationID: migrationID,
                    directoryURL: resumeDataURL,
                    markerURL: finalMarkerURL,
                    fileCount: session.filenames.count,
                    byteCount: session.byteCount
                )
                try Self.writeCommitMarker(
                    artifact: artifact,
                    filenames: session.filenames,
                    markerURL: publicationMarkerURL
                )
                try fileOperations.syncDirectory(publicationURL)
                try fileOperations.syncDirectory(migrationRootURL)
                // Make both directory names participating in the swap durable
                // before exchanging them. This preserves an authoritative
                // ResumeData name even if a later post-swap barrier fails.
                try fileOperations.syncDirectory(stateDirectoryURL)

                try Self.exchangeDirectories(publicationURL, resumeDataURL)

                // The exchange publishes the complete marker and all verified files
                // together. Record it before any cleanup or durability operation.
                session.state = .committed(artifact)
                state.sessionsByID[migrationID] = session
                try finishCommittedMigration(session: session)
                return artifact
            } catch let error as TorrentLegacyStateMigrationError {
                if case .committed = session.state {
                    throw error
                }
                try? FileManager.default.removeItem(at: publicationURL)
                throw error
            } catch {
                try? FileManager.default.removeItem(at: publicationURL)
                throw TorrentLegacyStateMigrationError.commitFailed
            }
        }
    }

    package func abort(
        migrationID: UUID,
        scope: TorrentEngineServiceScope
    ) throws {
        try validate(scope: scope)
        try state.withLock { state in
            try requireConnectedController(scope: scope)
            guard let session = session(
                migrationID: migrationID,
                scope: scope,
                in: state
            ) else {
                throw TorrentLegacyStateMigrationError.unknownMigration
            }
            if case .committed = session.state {
                throw TorrentLegacyStateMigrationError.migrationAlreadyCommitted
            }
            state.sessionsByID.removeValue(forKey: migrationID)
            try? FileManager.default.removeItem(at: session.directoryURL)
            try? FileManager.default.removeItem(at: migrationRootURL.appending(
                path: Self.publicationDirectoryName(id: migrationID),
                directoryHint: .isDirectory
            ))
        }
    }

    package func disconnect(scope: TorrentEngineServiceScope) {
        scope.invalidate()
        state.withLock { state in
            let sessions = state.sessionsByID.values.filter {
                $0.scope == scope
            }
            for session in sessions {
                if case .committed = session.state {
                    continue
                }
                try? FileManager.default.removeItem(at: session.directoryURL)
                try? FileManager.default.removeItem(at: migrationRootURL.appending(
                    path: Self.publicationDirectoryName(id: session.id),
                    directoryHint: .isDirectory
                ))
            }
            state.sessionsByID = state.sessionsByID.filter {
                $0.value.scope != scope
            }
        }
    }

    package func migration(
        migrationID: UUID,
        scope: TorrentEngineServiceScope
    ) throws -> TorrentLegacyStateMigration? {
        try validate(scope: scope)
        return try state.withLock { state in
            try requireConnectedController(scope: scope)
            return session(
                migrationID: migrationID,
                scope: scope,
                in: state
            )?.snapshot
        }
    }

    private func validate(scope: TorrentEngineServiceScope) throws {
        guard scope.engineEpoch == engineEpoch else {
            throw TorrentLegacyStateMigrationError.wrongEngineEpoch
        }
    }

    private func requireConnectedController(scope: TorrentEngineServiceScope) throws {
        guard scope.isActive else {
            throw TorrentLegacyStateMigrationError.controllerDisconnected
        }
    }

    private func maximumBytes(for kind: TorrentLegacyStateFileKind) -> Int {
        switch kind {
        case .resume:
            limits.maximumResumeFileBytes
        case .tombstone:
            limits.maximumTombstoneFileBytes
        }
    }

    private func copyStateFile(
        filename: String,
        from sourceDirectoryURL: URL,
        to destinationDirectoryURL: URL
    ) throws -> Int {
        let kind = try TorrentLegacyStateFilename.classify(filename)
        let sourceURL = sourceDirectoryURL.appending(path: filename, directoryHint: .notDirectory)
        let source: FileDescriptor
        do {
            source = try FileDescriptor.open(
                FilePath(sourceURL.path(percentEncoded: false)),
                .readOnly,
                options: [.closeOnExec, .noFollow]
            )
        } catch {
            throw TorrentLegacyStateMigrationError.destinationStateInvalid
        }
        defer {
            try? source.close()
        }

        let metadata = try Self.validatedSourceMetadata(
            descriptor: source,
            maximumBytes: maximumBytes(for: kind)
        )
        try Self.copyVerifiedSource(
            source,
            metadata: metadata,
            to: destinationDirectoryURL.appending(path: filename, directoryHint: .notDirectory)
        )
        return metadata.byteCount
    }

    private func preserveStateFile(
        filename: String,
        from sourceDirectoryURL: URL,
        to destinationDirectoryURL: URL
    ) throws -> Int {
        let kind = try TorrentLegacyStateFilename.classify(filename)
        let sourceURL = sourceDirectoryURL.appending(path: filename, directoryHint: .notDirectory)
        let source: FileDescriptor
        do {
            source = try FileDescriptor.open(
                FilePath(sourceURL.path(percentEncoded: false)),
                .readOnly,
                options: [.closeOnExec, .noFollow]
            )
        } catch {
            throw TorrentLegacyStateMigrationError.destinationStateInvalid
        }
        defer {
            try? source.close()
        }

        let metadata = try Self.validatedSourceMetadata(
            descriptor: source,
            maximumBytes: maximumBytes(for: kind)
        )
        let destinationURL = destinationDirectoryURL.appending(
            path: filename,
            directoryHint: .notDirectory
        )
        do {
            try FileManager.default.linkItem(at: sourceURL, to: destinationURL)
        } catch {
            throw TorrentLegacyStateMigrationError.destinationStateInvalid
        }

        var destinationMetadata = stat()
        let destinationStatus = unsafe destinationURL.path(percentEncoded: false).withCString {
            pointer in
            unsafe Darwin.lstat(pointer, &destinationMetadata)
        }
        guard destinationStatus == 0,
              (destinationMetadata.st_mode & S_IFMT) == S_IFREG,
              destinationMetadata.st_dev == metadata.device,
              destinationMetadata.st_ino == metadata.inode else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw TorrentLegacyStateMigrationError.destinationStateInvalid
        }
        return metadata.byteCount
    }

    private func session(
        migrationID: UUID,
        scope: TorrentEngineServiceScope,
        in state: State
    ) -> TorrentLegacyStateMigrationSession? {
        guard let session = state.sessionsByID[migrationID], session.scope == scope else {
            return nil
        }
        return session
    }

    private func makeMigrationID(in state: State) -> UUID {
        while true {
            let candidate = UUID()
            guard state.sessionsByID[candidate] == nil else {
                continue
            }
            let paths = [
                migrationRootURL.appending(path: Self.stagingDirectoryName(id: candidate)),
                migrationRootURL.appending(path: Self.publicationDirectoryName(id: candidate)),
                resumeDataURL.appending(path: Self.commitMarkerName(id: candidate)),
            ]
            if paths.allSatisfy({
                !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
            }) {
                return candidate
            }
        }
    }

    private func cleanupEveryUncommittedSession() {
        state.withLock { state in
            for session in state.sessionsByID.values {
                if case .committed = session.state {
                    continue
                }
                try? FileManager.default.removeItem(at: session.directoryURL)
                try? FileManager.default.removeItem(at: migrationRootURL.appending(
                    path: Self.publicationDirectoryName(id: session.id),
                    directoryHint: .isDirectory
                ))
            }
            state.sessionsByID.removeAll()
        }
    }

    private func finishCommittedMigration(
        session: TorrentLegacyStateMigrationSession
    ) throws {
        do {
            _ = try Self.verifyOwnedDirectory(resumeDataURL)
            try fileOperations.syncDirectory(resumeDataURL)
            try fileOperations.syncDirectory(stateDirectoryURL)
            try fileOperations.syncDirectory(migrationRootURL)
        } catch {
            // After RENAME_SWAP, publication names the previous live directory and
            // staging still contains the imported source copy. Preserve both until
            // every durability barrier succeeds so the next launch can reconcile
            // the atomic publication without losing its rollback material.
            throw TorrentLegacyStateMigrationError.commitFailed
        }

        let publicationURL = migrationRootURL.appending(
            path: Self.publicationDirectoryName(id: session.id),
            directoryHint: .isDirectory
        )
        try? FileManager.default.removeItem(at: publicationURL)
        try? FileManager.default.removeItem(at: session.directoryURL)
        // The live directory and its parent are already durable. A cleanup sync is
        // best-effort: if it fails or the process exits, startup recovery removes
        // the exact UUID-scoped debris again without affecting ResumeData.
        try? fileOperations.syncDirectory(migrationRootURL)
    }

    private static func recoverInterruptedArtifacts(
        in migrationRootURL: URL,
        syncDirectory: @Sendable (URL) throws -> Void
    ) throws {
        _ = try verifyOwnedDirectory(migrationRootURL)
        let children = try FileManager.default.contentsOfDirectory(
            at: migrationRootURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        var removedArtifact = false
        for child in children {
            let filename = child.lastPathComponent
            guard recoveryArtifactID(from: filename) != nil else {
                continue
            }

            // RENAME_SWAP is atomic: after a crash, ResumeData is authoritative
            // whether the exchange happened or not. Therefore both staging and
            // publishing names are disposable, but only after validating the exact
            // UUID name and an owned, no-follow directory leaf.
            let expectedURL = migrationRootURL.appending(
                path: filename,
                directoryHint: .isDirectory
            ).standardizedFileURL
            guard child.standardizedFileURL == expectedURL else {
                throw TorrentLegacyStateMigrationError.destinationStateInvalid
            }
            _ = try verifyOwnedDirectory(child)
            try FileManager.default.removeItem(at: child)
            removedArtifact = true
        }
        if removedArtifact {
            try syncDirectory(migrationRootURL)
        }
    }

    private static func prepareOwnedDirectory(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw TorrentLegacyStateMigrationError.stagingDirectoryFailed
        }
        let standardized = url.standardizedFileURL
        try FileManager.default.createDirectory(
            at: standardized,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let leafIdentity = try verifyOwnedDirectory(standardized)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: standardized.path(percentEncoded: false)
        )

        // macOS may spell trusted parent firmlinks as either /var or /private/var.
        // Canonicalize that parent spelling, but require the caller-named leaf and
        // the no-follow canonical descriptor to identify the exact same directory.
        let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
        let canonicalIdentity = try verifyOwnedDirectory(canonical)
        guard leafIdentity == canonicalIdentity else {
            throw TorrentLegacyStateMigrationError.stagingDirectoryFailed
        }
        return canonical
    }

    private static func verifyOwnedDirectory(
        _ url: URL
    ) throws -> TorrentLegacyStateDirectoryIdentity {
        var pathMetadata = stat()
        let pathStatus = unsafe url.path(percentEncoded: false).withCString { pointer in
            unsafe Darwin.lstat(pointer, &pathMetadata)
        }
        guard pathStatus == 0,
              (pathMetadata.st_mode & S_IFMT) == S_IFDIR,
              pathMetadata.st_uid == geteuid(),
              (pathMetadata.st_mode & 0o022) == 0 else {
            throw TorrentLegacyStateMigrationError.stagingDirectoryFailed
        }

        let descriptor = try FileDescriptor.open(
            FilePath(url.path(percentEncoded: false)),
            .readOnly,
            options: [.closeOnExec, .directory, .noFollow]
        )
        defer {
            try? descriptor.close()
        }

        var metadata = stat()
        guard unsafe Darwin.fstat(descriptor.rawValue, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_dev == pathMetadata.st_dev,
              metadata.st_ino == pathMetadata.st_ino else {
            throw TorrentLegacyStateMigrationError.stagingDirectoryFailed
        }
        return TorrentLegacyStateDirectoryIdentity(
            device: metadata.st_dev,
            inode: metadata.st_ino
        )
    }

    private static func validatedSourceMetadata(
        descriptor: FileDescriptor,
        maximumBytes: Int
    ) throws -> TorrentLegacyStateSourceMetadata {
        var metadata = stat()
        guard unsafe Darwin.fstat(descriptor.rawValue, &metadata) == 0 else {
            throw TorrentLegacyStateMigrationError.invalidFileDescriptor
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw TorrentLegacyStateMigrationError.sourceIsNotRegularFile
        }
        guard metadata.st_size > 0 else {
            throw TorrentLegacyStateMigrationError.emptyFile
        }
        guard metadata.st_size <= off_t(maximumBytes) else {
            throw TorrentLegacyStateMigrationError.fileTooLarge(
                actual: metadata.st_size > off_t(Int.max) ? Int.max : Int(metadata.st_size),
                maximum: maximumBytes
            )
        }
        try verifyDescriptorPath(descriptor, matches: metadata)
        return TorrentLegacyStateSourceMetadata(
            byteCount: Int(metadata.st_size),
            device: metadata.st_dev,
            inode: metadata.st_ino
        )
    }

    private static func verifyDescriptorPath(
        _ descriptor: FileDescriptor,
        matches descriptorMetadata: stat
    ) throws {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var pathMetadata = stat()
        let result = unsafe pathBuffer.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress,
                  unsafe Darwin.fcntl(descriptor.rawValue, F_GETPATH, baseAddress) != -1 else {
                return false
            }
            guard unsafe Darwin.lstat(baseAddress, &pathMetadata) == 0 else {
                return false
            }
            return true
        }
        guard result else {
            throw TorrentLegacyStateMigrationError.sourcePathCouldNotBeVerified
        }
        guard (pathMetadata.st_mode & S_IFMT) == S_IFREG,
              pathMetadata.st_dev == descriptorMetadata.st_dev,
              pathMetadata.st_ino == descriptorMetadata.st_ino else {
            throw TorrentLegacyStateMigrationError.sourceIsNotRegularFile
        }
    }

    private static func copyVerifiedSource(
        _ source: FileDescriptor,
        metadata: TorrentLegacyStateSourceMetadata,
        to destinationURL: URL
    ) throws {
        let destination: FileDescriptor
        do {
            destination = try FileDescriptor.open(
                FilePath(destinationURL.path(percentEncoded: false)),
                .writeOnly,
                options: [.closeOnExec, .create, .exclusiveCreate, .noFollow],
                permissions: .ownerReadWrite
            )
        } catch {
            throw TorrentLegacyStateMigrationError.fileCopyFailed
        }

        var destinationIsOpen = true
        defer {
            if destinationIsOpen {
                try? destination.close()
            }
        }

        do {
            var offset = 0
            var buffer = [UInt8](repeating: 0, count: min(metadata.byteCount, 64 * 1_024))
            while offset < metadata.byteCount {
                let requestedCount = min(buffer.count, metadata.byteCount - offset)
                let readCount = try unsafe buffer.withUnsafeMutableBytes { rawBuffer in
                    let boundedBuffer = unsafe UnsafeMutableRawBufferPointer(
                        start: rawBuffer.baseAddress,
                        count: requestedCount
                    )
                    return try unsafe source.read(
                        fromAbsoluteOffset: Int64(offset),
                        into: boundedBuffer
                    )
                }
                guard readCount > 0 else {
                    throw TorrentLegacyStateMigrationError.fileCopyFailed
                }
                let written = try destination.writeAll(buffer.prefix(readCount))
                guard written == readCount else {
                    throw TorrentLegacyStateMigrationError.fileCopyFailed
                }
                offset += readCount
            }

            var trailingByte: UInt8 = 0
            let trailingCount = try unsafe withUnsafeMutableBytes(of: &trailingByte) { rawBuffer in
                try unsafe source.read(
                    fromAbsoluteOffset: Int64(metadata.byteCount),
                    into: rawBuffer
                )
            }
            guard trailingCount == 0 else {
                throw TorrentLegacyStateMigrationError.fileCopyFailed
            }

            var finalMetadata = stat()
            guard unsafe Darwin.fstat(source.rawValue, &finalMetadata) == 0,
                  (finalMetadata.st_mode & S_IFMT) == S_IFREG,
                  finalMetadata.st_dev == metadata.device,
                  finalMetadata.st_ino == metadata.inode,
                  finalMetadata.st_size == off_t(metadata.byteCount) else {
                throw TorrentLegacyStateMigrationError.fileCopyFailed
            }
            guard Darwin.fsync(destination.rawValue) == 0 else {
                throw TorrentLegacyStateMigrationError.fileCopyFailed
            }
            try destination.close()
            destinationIsOpen = false
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            if let migrationError = error as? TorrentLegacyStateMigrationError {
                throw migrationError
            }
            throw TorrentLegacyStateMigrationError.fileCopyFailed
        }
    }

    private static func allowlistedFilenames(in directoryURL: URL) throws -> Set<String> {
        do {
            _ = try verifyOwnedDirectory(directoryURL)
            let children = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: []
            )
            var filenames = Set<String>()
            filenames.reserveCapacity(children.count)
            for child in children {
                let filename = child.lastPathComponent
                _ = try TorrentLegacyStateFilename.classify(filename)
                guard filenames.insert(filename).inserted else {
                    throw TorrentLegacyStateMigrationError.destinationStateInvalid
                }
            }
            return filenames
        } catch {
            throw TorrentLegacyStateMigrationError.destinationStateInvalid
        }
    }

    private static func exchangeDirectories(_ firstURL: URL, _ secondURL: URL) throws {
        let firstPath = firstURL.path(percentEncoded: false)
        let secondPath = secondURL.path(percentEncoded: false)
        let result = unsafe firstPath.withCString { firstPointer in
            unsafe secondPath.withCString { secondPointer in
                unsafe Darwin.renameatx_np(
                    AT_FDCWD,
                    firstPointer,
                    AT_FDCWD,
                    secondPointer,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw TorrentLegacyStateMigrationError.commitFailed
        }
    }

    private static func writeCommitMarker(
        artifact: TorrentLegacyStateMigrationCommit,
        filenames: Set<String>,
        markerURL: URL
    ) throws {
        let temporaryURL = markerURL.deletingLastPathComponent().appending(
            path: ".\(markerURL.lastPathComponent).tmp-\(UUID().uuidString.lowercased())",
            directoryHint: .notDirectory
        )
        let sortedFilenames = filenames.sorted()
        var marker = "version=1\n"
        marker += "migration=\(artifact.migrationID.uuidString.lowercased())\n"
        marker += "file_count=\(artifact.fileCount)\n"
        marker += "byte_count=\(artifact.byteCount)\n"
        for filename in sortedFilenames {
            marker += "file=\(filename)\n"
        }

        let descriptor = try FileDescriptor.open(
            FilePath(temporaryURL.path(percentEncoded: false)),
            .writeOnly,
            options: [.closeOnExec, .create, .exclusiveCreate, .noFollow],
            permissions: .ownerReadWrite
        )
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen {
                try? descriptor.close()
            }
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        let bytes = marker.utf8
        guard try descriptor.writeAll(bytes) == bytes.count,
              Darwin.fsync(descriptor.rawValue) == 0 else {
            throw TorrentLegacyStateMigrationError.commitFailed
        }
        try descriptor.close()
        descriptorIsOpen = false
        try FileManager.default.moveItem(at: temporaryURL, to: markerURL)
    }

    private static func validateCommitMarker(
        at markerURL: URL,
        migrationID: UUID,
        limits: TorrentLegacyStateMigrationLimits
    ) throws {
        let descriptor: FileDescriptor
        do {
            descriptor = try FileDescriptor.open(
                FilePath(markerURL.path(percentEncoded: false)),
                .readOnly,
                options: [.closeOnExec, .noFollow]
            )
        } catch {
            throw TorrentLegacyStateMigrationError.destinationStateInvalid
        }
        defer {
            try? descriptor.close()
        }

        var metadata = stat()
        guard unsafe Darwin.fstat(descriptor.rawValue, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_size > 0,
              metadata.st_size <= off_t(limits.maximumAggregateBytes) else {
            throw TorrentLegacyStateMigrationError.destinationStateInvalid
        }
        do {
            try verifyDescriptorPath(descriptor, matches: metadata)
        } catch {
            throw TorrentLegacyStateMigrationError.destinationStateInvalid
        }

        let byteCount = Int(metadata.st_size)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let readCount: Int
        do {
            readCount = try unsafe bytes.withUnsafeMutableBytes { buffer in
                try unsafe descriptor.read(fromAbsoluteOffset: 0, into: buffer)
            }
        } catch {
            throw TorrentLegacyStateMigrationError.destinationStateInvalid
        }
        guard readCount == byteCount,
              let marker = String(bytes: bytes, encoding: .utf8) else {
            throw TorrentLegacyStateMigrationError.destinationStateInvalid
        }

        let lines = marker.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 5,
              lines[0] == "version=1",
              lines[1] == "migration=\(migrationID.uuidString.lowercased())",
              lines[2].hasPrefix("file_count="),
              let fileCount = Int(lines[2].dropFirst("file_count=".count)),
              (1...limits.maximumFileCount).contains(fileCount),
              lines[3].hasPrefix("byte_count="),
              let importedByteCount = Int(lines[3].dropFirst("byte_count=".count)),
              (1...limits.maximumAggregateBytes).contains(importedByteCount),
              lines.last?.isEmpty == true else {
            throw TorrentLegacyStateMigrationError.destinationStateInvalid
        }
        let fileLines = lines.dropFirst(4).dropLast()
        guard fileLines.count == fileCount else {
            throw TorrentLegacyStateMigrationError.destinationStateInvalid
        }
        var filenames = Set<String>()
        for line in fileLines {
            guard line.hasPrefix("file=") else {
                throw TorrentLegacyStateMigrationError.destinationStateInvalid
            }
            let filename = String(line.dropFirst("file=".count))
            _ = try TorrentLegacyStateFilename.classify(filename)
            guard filenames.insert(filename).inserted else {
                throw TorrentLegacyStateMigrationError.destinationStateInvalid
            }
        }
    }

    private static func stagingDirectoryName(id: UUID) -> String {
        "migration-\(id.uuidString.lowercased()).staging"
    }

    private static func publicationDirectoryName(id: UUID) -> String {
        "migration-\(id.uuidString.lowercased()).publishing"
    }

    private static func commitMarkerName(id: UUID) -> String {
        "\(commitMarkerPrefix)\(id.uuidString.lowercased()).commit"
    }

    private static func recoveryArtifactID(from filename: String) -> UUID? {
        let prefix = "migration-"
        let suffix: String
        if filename.hasSuffix(".staging") {
            suffix = ".staging"
        } else if filename.hasSuffix(".publishing") {
            suffix = ".publishing"
        } else {
            return nil
        }
        guard filename.hasPrefix(prefix) else {
            return nil
        }
        let rawID = filename.dropFirst(prefix.count).dropLast(suffix.count)
        guard rawID.count == 36,
              let id = UUID(uuidString: String(rawID)),
              id.uuidString.lowercased() == rawID else {
            return nil
        }
        return id
    }

    private static let commitMarkerPrefix = ".legacy-migration-"

    private static func migrationID(fromCommitMarker filename: String) -> UUID? {
        guard filename.hasPrefix(commitMarkerPrefix), filename.hasSuffix(".commit") else {
            return nil
        }
        let rawID = filename
            .dropFirst(commitMarkerPrefix.count)
            .dropLast(".commit".count)
        guard rawID.count == 36,
              let id = UUID(uuidString: String(rawID)),
              id.uuidString.lowercased() == rawID else {
            return nil
        }
        return id
    }
}

private func syncMigrationDirectory(_ url: URL) throws {
    let descriptor = try FileDescriptor.open(
        FilePath(url.path(percentEncoded: false)),
        .readOnly,
        options: [.closeOnExec, .directory, .noFollow]
    )
    defer {
        try? descriptor.close()
    }
    guard Darwin.fsync(descriptor.rawValue) == 0 else {
        throw TorrentLegacyStateMigrationError.commitFailed
    }
}

private enum TorrentLegacyStateFileKind {
    case resume
    case tombstone
}

private enum TorrentLegacyStateFilename {
    private static let resumeSuffix = ".fastresume"
    private static let tombstonePrefix = "removal-"
    private static let tombstoneSuffix = ".fastresume.remove"

    static func classify(_ filename: String) throws -> TorrentLegacyStateFileKind {
        guard filename.utf8.count <= 96,
              !filename.isEmpty,
              !filename.contains("/"),
              !filename.contains("\0") else {
            throw TorrentLegacyStateMigrationError.invalidFilename
        }

        if filename.hasPrefix(tombstonePrefix), filename.hasSuffix(tombstoneSuffix) {
            let nonce = filename.dropFirst(tombstonePrefix.count).dropLast(tombstoneSuffix.count)
            guard isLowercaseHex(nonce, count: 32) else {
                throw TorrentLegacyStateMigrationError.invalidFilename
            }
            return .tombstone
        }

        guard filename.hasSuffix(resumeSuffix) else {
            throw TorrentLegacyStateMigrationError.invalidFilename
        }
        let identifier = filename.dropLast(resumeSuffix.count)
        if identifier.hasPrefix("t:") {
            guard isLowercaseHex(identifier.dropFirst(2), count: 32) else {
                throw TorrentLegacyStateMigrationError.invalidFilename
            }
        } else if identifier.hasPrefix("v1:") {
            guard isLowercaseHex(identifier.dropFirst(3), count: 40) else {
                throw TorrentLegacyStateMigrationError.invalidFilename
            }
        } else if identifier.hasPrefix("v2:") {
            guard isLowercaseHex(identifier.dropFirst(3), count: 64) else {
                throw TorrentLegacyStateMigrationError.invalidFilename
            }
        } else {
            throw TorrentLegacyStateMigrationError.invalidFilename
        }
        return .resume
    }

    private static func isLowercaseHex<S: StringProtocol>(
        _ value: S,
        count: Int
    ) -> Bool {
        let bytes = value.utf8
        guard bytes.count == count else {
            return false
        }
        return bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }
    }
}

private struct TorrentLegacyStateSourceMetadata {
    let byteCount: Int
    let device: dev_t
    let inode: ino_t
}

private struct TorrentLegacyStateDirectoryIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

private enum TorrentLegacyStateMigrationSessionState: Sendable {
    case staging
    case committed(TorrentLegacyStateMigrationCommit)
}

private struct TorrentLegacyStateMigrationSession: Sendable {
    let id: UUID
    let scope: TorrentEngineServiceScope
    var directoryURL: URL
    var state: TorrentLegacyStateMigrationSessionState
    var filenames: Set<String>
    var byteCount: Int

    var snapshot: TorrentLegacyStateMigration {
        TorrentLegacyStateMigration(
            id: id,
            scope: scope,
            stagedFileCount: filenames.count,
            stagedByteCount: byteCount
        )
    }
}
