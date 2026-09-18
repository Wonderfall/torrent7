import Darwin
import Foundation
import System
import TorrentEngineModel
import TorrentStorageAuthority

private struct TorrentOwnedFileDescriptor: ~Copyable {
    private var descriptor: Int32

    init(taking descriptor: Int32) {
        precondition(descriptor >= 0)
        self.descriptor = descriptor
    }

    var rawValue: Int32 {
        precondition(descriptor >= 0)
        return descriptor
    }

    mutating func relinquish() -> Int32 {
        let result = rawValue
        descriptor = -1
        return result
    }

    deinit {
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }
}

package enum TorrentStoragePlanningError: LocalizedError, Equatable, Sendable {
    case unsafeParentDirectory
    case hiddenTopLevelName
    case invalidParentAuthority
    case destinationNameExhausted
    case reservationFailed
    case filesystemObjectChanged
    case unsupportedFilesystemObject
    case ownershipTagFailed
    case deletionNotProvable
    case existingDataUnavailable
    case existingDataUnsafe

    package var errorDescription: String? {
        switch self {
        case .unsafeParentDirectory:
            "Choose a specific download folder instead of the filesystem root or home directory."
        case .hiddenTopLevelName:
            "Hidden top-level torrent names are not permitted."
        case .invalidParentAuthority:
            "The selected download folder is no longer the authorized directory."
        case .destinationNameExhausted:
            "A unique destination name could not be reserved."
        case .reservationFailed:
            "The torrent destination could not be reserved safely."
        case .filesystemObjectChanged:
            "The torrent destination changed while it was being prepared."
        case .unsupportedFilesystemObject:
            "The torrent destination contains an unsupported filesystem object."
        case .ownershipTagFailed:
            "The torrent destination security tag could not be recorded."
        case .deletionNotProvable:
            "The torrent payload was preserved because app ownership could not be proven."
        case .existingDataUnavailable:
            "The expected existing torrent data could not be found."
        case .existingDataUnsafe:
            "The existing torrent data cannot be modified safely in place."
        }
    }
}

package final class TorrentStorageParentAuthority: Sendable {
    package let id: TorrentStorageParentID
    package let canonicalPath: String
    package let identity: TorrentFilesystemIdentity
    package let descriptor: Int32

    private let accessLifetime: DownloadFolderAccessLease

    // SAFETY: Ownership/lifetime: the security lease outlives the stored descriptor,
    // temporary C strings live through lstat, and local stat values live through calls;
    // bounds/alignment: withCString is NUL-terminated and stat storage is exact/aligned;
    // synchronization: immutable authority is published only after validation;
    // safe alternative: fstat/lstat identity comparison is needed to reject path races.
    package init(lease: DownloadFolderAccessLease) throws {
        let path = lease.url.standardizedFileURL
            .resolvingSymlinksInPath()
            .path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.resolvingSymlinksInPath()
            .path(percentEncoded: false)
        guard path != "/", path != home else {
            throw TorrentStoragePlanningError.unsafeParentDirectory
        }

        let opened: FileDescriptor
        do {
            opened = try FileDescriptor.open(
                FilePath(path),
                .readOnly,
                options: [.closeOnExec, .directory, .noFollow]
            )
        } catch {
            throw TorrentStoragePlanningError.invalidParentAuthority
        }

        var descriptorMetadata = stat()
        var pathMetadata = stat()
        let descriptorStatus = unsafe Darwin.fstat(opened.rawValue, &descriptorMetadata)
        let pathStatus = path.withCString { pointer in
            unsafe Darwin.lstat(pointer, &pathMetadata)
        }
        guard descriptorStatus == 0,
              pathStatus == 0,
              (descriptorMetadata.st_mode & S_IFMT) == S_IFDIR,
              (pathMetadata.st_mode & S_IFMT) == S_IFDIR,
              descriptorMetadata.st_dev == pathMetadata.st_dev,
              descriptorMetadata.st_ino == pathMetadata.st_ino else {
            try? opened.close()
            throw TorrentStoragePlanningError.invalidParentAuthority
        }

        canonicalPath = path
        identity = Self.identity(descriptorMetadata)
        id = TorrentStorageParentID(identity: identity)
        descriptor = opened.rawValue
        accessLifetime = lease
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    package func validate() throws {
        var metadata = stat()
        // SAFETY: Ownership/lifetime: this authority owns the open descriptor and local stat
        // storage spans fstat; bounds/alignment: Swift supplies exact aligned stat storage;
        // synchronization: immutable descriptor identity is only read; safe alternative:
        // fstat must validate the open directory authority without re-resolving a path.
        guard unsafe Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              Self.identity(metadata).refersToSameObject(as: identity) else {
            throw TorrentStoragePlanningError.invalidParentAuthority
        }
    }

    private static func identity(_ metadata: stat) -> TorrentFilesystemIdentity {
        TorrentFilesystemIdentity(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino),
            linkCount: UInt64(truncatingIfNeeded: metadata.st_nlink),
            ownerUserID: metadata.st_uid,
            fileGeneration: metadata.st_gen
        )
    }
}

package struct TorrentStorageLocation: Sendable {
    package let torrentID: String
    package let claim: TorrentStorageClaim
    package let parent: TorrentStorageParentAuthority

    package init?(
        claim: TorrentStorageClaim,
        parent: TorrentStorageParentAuthority
    ) {
        guard let torrentID = claim.torrentID,
              claim.manifest.parentID == parent.id else {
            return nil
        }
        self.torrentID = torrentID
        self.claim = claim
        self.parent = parent
    }

    package var displayURL: URL {
        URL(
            filePath: parent.canonicalPath,
            directoryHint: .isDirectory
        ).appending(
            path: claim.manifest.collisionSelectedTopLevelName,
            directoryHint: claim.manifest.contentKind == .directory
                ? .isDirectory
                : .notDirectory
        )
    }

    package var displayPath: String {
        displayURL.path(percentEncoded: false)
    }
}

package struct TorrentStorageReservation: Sendable {
    package let storageManifest: TorrentStorageManifest
    package let initialLease: TorrentStorageLease
}

package struct TorrentStorageDestinationConflict: Equatable, Sendable {
    package let existingTopLevelName: String
    package let separateCopyTopLevelName: String
    package let parentPath: String
    package let canUseExistingFiles: Bool

    package var parentDisplayName: String {
        URL(filePath: parentPath, directoryHint: .isDirectory)
            .lastPathComponent
    }
}

package enum TorrentStorageDestinationChoice: Equatable, Sendable {
    case preferredName
    case separateCopy(topLevelName: String)
    case useExistingFiles
}

package struct TorrentStorageDestinationPlanner: Sendable {
    package static let ownershipAttribute = "app.torrent7.storage-claim"
    private static let maximumCollisionAttempts = 10_000
    private static let deletionRenameFlags = UInt32(
        RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
    )

    package init() {}

    // SAFETY: Ownership/lifetime: candidate Strings pin their C strings per synchronous
    // fstatat and the parent owns its descriptor; bounds/alignment: validated candidates
    // are NUL-terminated and stat storage is exact/aligned; synchronization: no filesystem
    // state is cached as authority; safe alternative: descriptor-relative fstatat with
    // AT_SYMLINK_NOFOLLOW is needed for race-resistant collision inspection.
    package func planTopLevelName(
        for logicalManifest: TorrentLogicalManifest,
        in parent: TorrentStorageParentAuthority
    ) throws -> String {
        try parent.validate()
        guard !logicalManifest.name.hasPrefix(".") else {
            throw TorrentStoragePlanningError.hiddenTopLevelName
        }
        for attempt in 1...Self.maximumCollisionAttempts {
            let candidate = collisionName(
                logicalManifest.name,
                attempt: attempt,
                isDirectory: logicalManifest.contentKind == .directory
            )
            var metadata = stat()
            let status = candidate.withCString { pointer in
                unsafe Darwin.fstatat(
                    parent.descriptor,
                    pointer,
                    &metadata,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            if status != 0, errno == ENOENT {
                return candidate
            }
            guard status == 0 else {
                throw TorrentStoragePlanningError.reservationFailed
            }
        }
        throw TorrentStoragePlanningError.destinationNameExhausted
    }

    package func inspectDestination(
        for logicalManifest: TorrentLogicalManifest,
        in parent: TorrentStorageParentAuthority
    ) throws -> TorrentStorageDestinationConflict? {
        let separateCopyName = try planTopLevelName(
            for: logicalManifest,
            in: parent
        )
        guard separateCopyName != logicalManifest.name else {
            return nil
        }

        let canUseExistingFiles = (try? inspectExistingPayload(
            manifest: logicalManifest,
            in: parent,
            topLevelName: logicalManifest.name
        )) != nil
        return TorrentStorageDestinationConflict(
            existingTopLevelName: logicalManifest.name,
            separateCopyTopLevelName: separateCopyName,
            parentPath: parent.canonicalPath,
            canUseExistingFiles: canUseExistingFiles
        )
    }

    package func reserve(
        manifest logicalManifest: TorrentLogicalManifest,
        in parent: TorrentStorageParentAuthority,
        claimID: UUID,
        generation: UInt64,
        ownershipKey: Data,
        selectedTopLevelName: String? = nil
    ) throws -> TorrentStorageReservation {
        guard ownershipKey.count == TorrentStorageOwnershipTag.keyByteCount else {
            throw TorrentStoragePlanningError.ownershipTagFailed
        }
        try parent.validate()
        guard !logicalManifest.name.hasPrefix(".") else {
            throw TorrentStoragePlanningError.hiddenTopLevelName
        }
        if let selectedTopLevelName {
            guard (1...Self.maximumCollisionAttempts).contains(where: { attempt in
                collisionName(
                    logicalManifest.name,
                    attempt: attempt,
                    isDirectory: logicalManifest.contentKind == .directory
                ) == selectedTopLevelName
            }) else {
                throw TorrentStoragePlanningError.reservationFailed
            }
        }

        var created = [CreatedObject]()
        do {
            let reservation: ReservedTopLevel
            switch logicalManifest.contentKind {
            case .singleFile:
                reservation = try reserveSingleFile(
                    preferredName: logicalManifest.name,
                    selectedName: selectedTopLevelName,
                    parentDescriptor: parent.descriptor,
                    claimID: claimID,
                    claimGeneration: generation,
                    ownershipKey: ownershipKey,
                    created: &created
                )
            case .directory:
                reservation = try reserveDirectory(
                    preferredName: logicalManifest.name,
                    selectedName: selectedTopLevelName,
                    parentDescriptor: parent.descriptor,
                    claimID: claimID,
                    claimGeneration: generation,
                    ownershipKey: ownershipKey,
                    created: &created
                )
            }
            defer {
                if logicalManifest.contentKind == .singleFile {
                    _ = Darwin.close(reservation.descriptor)
                }
            }

            let fileIdentities: [TorrentFilesystemIdentity?]
            let directoryIdentities: [TorrentPhysicalDirectoryIdentity]
            switch logicalManifest.contentKind {
            case .singleFile:
                guard logicalManifest.files.count == 1,
                      logicalManifest.files[0].isPadding == false else {
                    throw TorrentStoragePlanningError.reservationFailed
                }
                fileIdentities = [reservation.identity]
                directoryIdentities = []
            case .directory:
                let physicalLayout = try createDirectoryPayload(
                    logicalManifest.files,
                    topLevel: reservation,
                    parentDescriptor: parent.descriptor,
                    claimID: claimID,
                    claimGeneration: generation,
                    ownershipKey: ownershipKey,
                    created: &created
                )
                fileIdentities = physicalLayout.fileIdentities
                directoryIdentities = physicalLayout.directoryIdentities
            }

            let ownership = TorrentStorageOwnership.appCreated(key: ownershipKey)
            let authorityDigest = TorrentManifestDigest.authority(
                claimID: claimID,
                generation: generation,
                infoHashes: logicalManifest.infoHashes,
                sourceManifestDigest: logicalManifest.sourceManifestDigest,
                parentID: parent.id,
                contentKind: logicalManifest.contentKind,
                logicalFiles: logicalManifest.files,
                topLevelName: reservation.name,
                fileIdentities: fileIdentities,
                directoryIdentities: directoryIdentities,
                ownership: ownership
            )
            let storageManifest = TorrentStorageManifest(
                claimID: claimID,
                generation: generation,
                infoHashes: logicalManifest.infoHashes,
                sourceManifestDigest: logicalManifest.sourceManifestDigest,
                parentID: parent.id,
                contentKind: logicalManifest.contentKind,
                logicalFiles: logicalManifest.files,
                physicalFileIdentities: fileIdentities,
                physicalDirectoryIdentities: directoryIdentities,
                collisionSelectedTopLevelName: reservation.name,
                authorityDigest: authorityDigest,
                ownership: ownership
            )
            return TorrentStorageReservation(
                storageManifest: storageManifest,
                initialLease: TorrentStorageLease(
                    state: .reserved,
                    availabilityRevision: 1,
                    fileAvailability: logicalManifest.files.map {
                        !$0.isPadding
                    }
                )
            )
        } catch {
            cleanUp(
                created,
                parentDescriptor: parent.descriptor,
                claimID: claimID
            )
            throw error
        }
    }

    /// Inspects an explicitly selected existing payload without creating,
    /// truncating, renaming, or marking any filesystem object. Imported
    /// writable files must be regular, owned by this user, no larger than the
    /// torrent layout, and have exactly one hard link before their identities
    /// are pinned into the claim.
    package func importExisting(
        manifest logicalManifest: TorrentLogicalManifest,
        in parent: TorrentStorageParentAuthority,
        claimID: UUID,
        generation: UInt64,
        selectedTopLevelName: String? = nil
    ) throws -> TorrentStorageReservation {
        try parent.validate()
        let topLevelName = selectedTopLevelName ?? logicalManifest.name
        guard TorrentPathComponentValidation.isSafe(topLevelName),
              !topLevelName.hasPrefix(".") else {
            throw TorrentStoragePlanningError.hiddenTopLevelName
        }

        let inspection = try inspectExistingPayload(
            manifest: logicalManifest,
            in: parent,
            topLevelName: topLevelName
        )
        let ownership = TorrentStorageOwnership.imported
        let authorityDigest = TorrentManifestDigest.authority(
            claimID: claimID,
            generation: generation,
            infoHashes: logicalManifest.infoHashes,
            sourceManifestDigest: logicalManifest.sourceManifestDigest,
            parentID: parent.id,
            contentKind: logicalManifest.contentKind,
            logicalFiles: logicalManifest.files,
            topLevelName: topLevelName,
            fileIdentities: inspection.fileIdentities,
            directoryIdentities: inspection.directoryIdentities,
            ownership: ownership
        )
        let storageManifest = TorrentStorageManifest(
            claimID: claimID,
            generation: generation,
            infoHashes: logicalManifest.infoHashes,
            sourceManifestDigest: logicalManifest.sourceManifestDigest,
            parentID: parent.id,
            contentKind: logicalManifest.contentKind,
            logicalFiles: logicalManifest.files,
            physicalFileIdentities: inspection.fileIdentities,
            physicalDirectoryIdentities: inspection.directoryIdentities,
            collisionSelectedTopLevelName: topLevelName,
            authorityDigest: authorityDigest,
            ownership: ownership
        )
        return TorrentStorageReservation(
            storageManifest: storageManifest,
            initialLease: TorrentStorageLease(
                state: .reserved,
                availabilityRevision: 1,
                fileAvailability: logicalManifest.files.map { !$0.isPadding }
            )
        )
    }

    package static func randomOwnershipKey() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<TorrentStorageOwnershipTag.keyByteCount).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
    }

    // SAFETY: Ownership/lifetime: the parent owns its descriptor, the name pins its C
    // string for openat, and the returned descriptor is deferred-closed; bounds/alignment:
    // the manifest name is validated and NUL-terminated; synchronization: immutable claim
    // evidence is checked before use; safe alternative: openat with O_NOFOLLOW must bind
    // validation to the opened object instead of a race-prone pathname.
    package func validateClaimRoot(
        _ claim: TorrentStorageClaim,
        in parent: TorrentStorageParentAuthority
    ) throws {
        try parent.validate()
        guard claim.manifest.parentID == parent.id,
              let expectedIdentity = claim.manifest.topLevelIdentity else {
            throw TorrentStoragePlanningError.invalidParentAuthority
        }
        let name = claim.manifest.collisionSelectedTopLevelName
        let flags = (claim.manifest.contentKind == .directory
            ? O_RDONLY | O_DIRECTORY
            : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        let descriptor = name.withCString { pointer in
            unsafe Darwin.openat(parent.descriptor, pointer, flags)
        }
        guard descriptor >= 0 else {
            throw TorrentStoragePlanningError.filesystemObjectChanged
        }
        defer { _ = Darwin.close(descriptor) }
        let identity = try claim.manifest.contentKind == .directory
            ? validateDirectoryDescriptor(descriptor)
            : validatePayloadDescriptor(descriptor, writable: true)
        guard identity.refersToSameObject(as: expectedIdentity),
              claim.manifest.contentKind == .directory
                || identity.linkCount == expectedIdentity.linkCount else {
            throw TorrentStoragePlanningError.filesystemObjectChanged
        }
        if case .appCreated(let key) = claim.manifest.ownership {
            try verifyOwnershipTag(
                key: key,
                claimID: claim.manifest.claimID,
                claimGeneration: claim.manifest.generation,
                relativePathComponents: [name],
                identity: identity,
                isDirectory: claim.manifest.contentKind == .directory,
                descriptor: descriptor
            )
        }
    }

    // SAFETY: Ownership/lifetime: parent/containing descriptors stay open while the leaf
    // String pins its C form, and the leaf descriptor is deferred-closed; bounds/alignment:
    // manifest indices/components are checked before NUL-terminated openat; synchronization:
    // immutable claim identities are verified before returning a path; safe alternative:
    // descriptor-relative O_NOFOLLOW reopening is required to prevent Finder path races.
    /// Resolves a Finder presentation target from GUI-owned claim authority.
    /// The root and any requested file are reopened descriptor-relatively and
    /// checked against their pinned identities before a path is returned to
    /// Finder. Engine-reported save paths and file paths are never consulted.
    package func revealURL(
        for location: TorrentStorageLocation,
        fileIndex: Int32? = nil
    ) throws -> URL {
        let claim = location.claim
        let parent = location.parent
        try validateClaimRoot(claim, in: parent)
        let rootURL = location.displayURL
        guard let fileIndex,
              fileIndex >= 0,
              claim.manifest.logicalFiles.indices.contains(Int(fileIndex)),
              let components = claim.manifest.relativePathComponents(
                  forFileAt: Int(fileIndex)
              ),
              let expectedIdentity = claim.manifest.physicalFileIdentities[
                  Int(fileIndex)
              ],
              components.allSatisfy(TorrentPathComponentValidation.isSafe) else {
            return rootURL
        }

        do {
            let containingDirectory = try openParentDirectory(
                of: components,
                startingAt: parent.descriptor
            )
            defer {
                if containingDirectory != parent.descriptor {
                    _ = Darwin.close(containingDirectory)
                }
            }
            guard let leaf = components.last else {
                return rootURL
            }
            let descriptor = leaf.withCString { pointer in
                unsafe Darwin.openat(
                    containingDirectory,
                    pointer,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
            }
            guard descriptor >= 0 else {
                return rootURL
            }
            defer { _ = Darwin.close(descriptor) }
            let actualIdentity = try validatePayloadDescriptor(
                descriptor,
                writable: false
            )
            guard actualIdentity == expectedIdentity else {
                return rootURL
            }
            if case .appCreated(let key) = claim.manifest.ownership {
                try verifyOwnershipTag(
                    key: key,
                    claimID: claim.manifest.claimID,
                    claimGeneration: claim.manifest.generation,
                    relativePathComponents: components,
                    identity: actualIdentity,
                    isDirectory: false,
                    descriptor: descriptor
                )
            }
            return components.reduce(URL(
                filePath: parent.canonicalPath,
                directoryHint: .isDirectory
            )) { url, component in
                url.appending(path: component)
            }
        } catch {
            return rootURL
        }
    }

    package func prepareDeletion(
        claim: TorrentStorageClaim,
        from parent: TorrentStorageParentAuthority
    ) throws -> TorrentStorageDeletionEvidence {
        try validateDeletionClaim(claim, parent: parent, requiresEvidence: false)
        let quarantine = try makeDeletionQuarantine(
            in: parent.descriptor,
            identifier: claim.operationNonce
        )
        defer { quarantine.close() }
        return quarantine.evidence
    }

    /// Returns true only when durable deletion evidence and the current
    /// descriptor-relative filesystem state prove that no deletion work
    /// remains. Any ambiguous or replaced object fails closed.
    package func deletionIsComplete(
        claim: TorrentStorageClaim,
        in parent: TorrentStorageParentAuthority
    ) throws -> Bool {
        try validateDeletionClaim(claim, parent: parent, requiresEvidence: true)
        guard let evidence = claim.deletionEvidence else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        let quarantineName = deletionQuarantineName(claim.operationNonce)
        guard try objectExists(
            named: quarantineName,
            in: parent.descriptor
        ) else {
            guard try deletionPayloadIsComplete(
                manifest: claim.manifest,
                in: parent.descriptor
            ) else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
            return true
        }

        let quarantineDescriptor = try openVerifiedDirectory(
            named: quarantineName,
            in: parent.descriptor,
            expectedIdentity: evidence.quarantineIdentity
        )
        defer { _ = Darwin.close(quarantineDescriptor) }
        if try objectExists(named: "entries", in: quarantineDescriptor) {
            let entriesDescriptor = try openVerifiedDirectory(
                named: "entries",
                in: quarantineDescriptor,
                expectedIdentity: evidence.entriesIdentity
            )
            _ = Darwin.close(entriesDescriptor)
            return false
        }

        guard !(try objectExists(named: "payload", in: quarantineDescriptor)),
              try deletionPayloadIsComplete(
                  manifest: claim.manifest,
                  in: parent.descriptor
              ) else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        guard try unlinkCapturedObject(
            named: quarantineName,
            in: parent.descriptor,
            descriptor: quarantineDescriptor,
            expectedIdentity: evidence.quarantineIdentity,
            isDirectory: true
        ) == .removed else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        return true
    }

    private func deletionPayloadIsComplete(
        manifest: TorrentStorageManifest,
        in parentDescriptor: Int32
    ) throws -> Bool {
        let topLevelName = manifest.collisionSelectedTopLevelName
        guard try objectExists(
            named: topLevelName,
            in: parentDescriptor
        ) else {
            return true
        }
        guard case .imported = manifest.ownership,
              manifest.contentKind == .directory,
              let expectedRoot = manifest.topLevelIdentity else {
            return false
        }

        let rootDescriptor = try openCapturedObject(
            named: topLevelName,
            in: parentDescriptor,
            isDirectory: true
        )
        defer { _ = Darwin.close(rootDescriptor) }
        let actualRoot = try validateDirectoryDescriptor(rootDescriptor)
        guard actualRoot.refersToSameObject(as: expectedRoot) else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }

        for logicalFile in manifest.logicalFiles where !logicalFile.isPadding {
            guard let leaf = logicalFile.pathComponents.last else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
            guard let containingDirectory = try
                openVerifiedParentDirectoryIfPresent(
                    of: logicalFile.pathComponents,
                    startingAt: rootDescriptor,
                    manifest: manifest
                ) else {
                continue
            }
            let stillExists: Bool
            do {
                defer { _ = Darwin.close(containingDirectory) }
                stillExists = try objectExists(
                    named: leaf,
                    in: containingDirectory
                )
            }
            if stillExists {
                return false
            }
        }
        return true
    }

    /// Deletes only objects captured out of mutable payload directories. The
    /// quarantine identity must already be durable before this method moves the
    /// top-level payload.
    package func deleteClaimedPayload(
        claim: TorrentStorageClaim,
        from parent: TorrentStorageParentAuthority,
        afterCapture: (@Sendable () -> Void)? = nil
    ) throws {
        try validateDeletionClaim(claim, parent: parent, requiresEvidence: true)
        guard let evidence = claim.deletionEvidence else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        let quarantine = try openDeletionQuarantine(
            in: parent.descriptor,
            identifier: claim.operationNonce,
            evidence: evidence
        )
        defer { quarantine.close() }

        let manifest = claim.manifest
        let topLevelName = manifest.collisionSelectedTopLevelName
        let captureName = "payload"
        let alreadyCaptured = try objectExists(
            named: captureName,
            in: quarantine.descriptor
        )
        if !alreadyCaptured {
            guard try captureForDeletion(
                named: topLevelName,
                from: parent.descriptor,
                as: captureName,
                in: quarantine.descriptor
            ) else {
                try removeDeletionQuarantine(
                    quarantine,
                    from: parent.descriptor
                )
                return
            }
        }
        afterCapture?()

        do {
            switch manifest.contentKind {
            case .singleFile:
                try deleteCapturedSingleFile(
                    manifest: manifest,
                    quarantine: quarantine
                )
            case .directory:
                let removedRoot = try deleteCapturedDirectoryPayload(
                    manifest: manifest,
                    quarantine: quarantine
                )
                if !removedRoot {
                    try restoreDeletionCapture(
                        named: captureName,
                        from: quarantine.descriptor,
                        as: topLevelName,
                        in: parent.descriptor
                    )
                }
            }
        } catch {
            let restoredEntries = (try? restoreStagedEntries(
                manifest: manifest,
                quarantine: quarantine
            )) == true
            var restoredPayload = (try? objectExists(
                named: captureName,
                in: quarantine.descriptor
            )) == false
            if restoredEntries,
               !restoredPayload,
               (try? objectExists(
                   named: captureName,
                   in: quarantine.descriptor
               )) == true {
                restoredPayload = (try? restoreDeletionCapture(
                    named: captureName,
                    from: quarantine.descriptor,
                    as: topLevelName,
                    in: parent.descriptor
                )) != nil
            }
            if restoredEntries, restoredPayload {
                try? removeDeletionQuarantine(
                    quarantine,
                    from: parent.descriptor
                )
            }
            throw error
        }

        try removeDeletionQuarantine(quarantine, from: parent.descriptor)
    }

    private final class DeletionQuarantine {
        let name: String
        private(set) var descriptor: Int32
        private(set) var entriesDescriptor: Int32
        let evidence: TorrentStorageDeletionEvidence

        init(
            name: String,
            descriptor: Int32,
            entriesDescriptor: Int32,
            evidence: TorrentStorageDeletionEvidence
        ) {
            self.name = name
            self.descriptor = descriptor
            self.entriesDescriptor = entriesDescriptor
            self.evidence = evidence
        }

        func close() {
            if entriesDescriptor >= 0 {
                _ = Darwin.close(entriesDescriptor)
                entriesDescriptor = -1
            }
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
                descriptor = -1
            }
        }

        deinit {
            close()
        }
    }

    private enum CapturedUnlinkResult: Equatable {
        case removed
        case directoryNotEmpty
    }

    private func validateDeletionClaim(
        _ claim: TorrentStorageClaim,
        parent: TorrentStorageParentAuthority,
        requiresEvidence: Bool
    ) throws {
        try parent.validate()
        let manifest = claim.manifest
        guard TorrentStorageClaimValidation.isValid(claim),
              claim.lease.state == .deleting,
              claim.removalIntent == .deletePayload,
              manifest.parentID == parent.id,
              !requiresEvidence || claim.deletionEvidence != nil else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
    }

    private func openVerifiedDirectory(
        named name: String,
        in directoryDescriptor: Int32,
        expectedIdentity: TorrentFilesystemIdentity
    ) throws -> Int32 {
        let descriptor = try openCapturedObject(
            named: name,
            in: directoryDescriptor,
            isDirectory: true
        )
        do {
            let actualIdentity = try validateDirectoryDescriptor(descriptor)
            guard actualIdentity.refersToSameObject(as: expectedIdentity) else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    // SAFETY: Ownership/lifetime: names pin C strings for each synchronous syscall and
    // every created descriptor is transferred to DeletionQuarantine or closed on failure;
    // bounds/alignment: fixed validated names are NUL-terminated with no raw indexing;
    // synchronization: exclusive creation plus pinned identities coordinates deletion;
    // safe alternative: mkdirat/openat/unlinkat are required for race-resistant quarantine.
    private func makeDeletionQuarantine(
        in parentDescriptor: Int32,
        identifier: UUID
    ) throws -> DeletionQuarantine {
        let name = deletionQuarantineName(identifier)
        let status = name.withCString { pointer in
            unsafe Darwin.mkdirat(parentDescriptor, pointer, mode_t(0o700))
        }
        guard status == 0 else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }

        let descriptor = name.withCString { pointer in
            unsafe Darwin.openat(
                parentDescriptor,
                pointer,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            _ = name.withCString { pointer in
                unsafe Darwin.unlinkat(
                    parentDescriptor,
                    pointer,
                    AT_REMOVEDIR
                )
            }
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        let quarantineIdentity: TorrentFilesystemIdentity
        do {
            quarantineIdentity = try validateDirectoryDescriptor(descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            _ = name.withCString { pointer in
                unsafe Darwin.unlinkat(
                    parentDescriptor,
                    pointer,
                    AT_REMOVEDIR
                )
            }
            throw error
        }
        let entriesName = "entries"
        let entriesStatus = entriesName.withCString { pointer in
            unsafe Darwin.mkdirat(descriptor, pointer, mode_t(0o700))
        }
        guard entriesStatus == 0 else {
            _ = try? unlinkCapturedObject(
                named: name,
                in: parentDescriptor,
                descriptor: descriptor,
                expectedIdentity: quarantineIdentity,
                isDirectory: true
            )
            _ = Darwin.close(descriptor)
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        let entriesDescriptor = entriesName.withCString { pointer in
            unsafe Darwin.openat(
                descriptor,
                pointer,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard entriesDescriptor >= 0 else {
            discardNewDeletionQuarantine(
                named: name,
                from: parentDescriptor,
                descriptor: descriptor,
                identity: quarantineIdentity,
                entriesDescriptor: nil
            )
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        do {
            let entriesIdentity = try validateDirectoryDescriptor(
                entriesDescriptor
            )
            return DeletionQuarantine(
                name: name,
                descriptor: descriptor,
                entriesDescriptor: entriesDescriptor,
                evidence: TorrentStorageDeletionEvidence(
                    operationNonce: identifier,
                    quarantineIdentity: quarantineIdentity,
                    entriesIdentity: entriesIdentity
                )
            )
        } catch {
            discardNewDeletionQuarantine(
                named: name,
                from: parentDescriptor,
                descriptor: descriptor,
                identity: quarantineIdentity,
                entriesDescriptor: entriesDescriptor
            )
            throw error
        }
    }

    // SAFETY: Ownership/lifetime: the literal C string exists for the synchronous unlinkat
    // and all passed descriptors remain open until cleanup finishes; bounds/alignment:
    // the fixed name is NUL-terminated; synchronization: this handles an unpublished,
    // exclusively owned quarantine; safe alternative: descriptor-relative unlinkat avoids
    // re-resolving attacker-replaceable paths.
    private func discardNewDeletionQuarantine(
        named name: String,
        from parentDescriptor: Int32,
        descriptor: Int32,
        identity: TorrentFilesystemIdentity,
        entriesDescriptor: Int32?
    ) {
        if let entriesDescriptor {
            _ = Darwin.close(entriesDescriptor)
        }
        _ = "entries".withCString { pointer in
            unsafe Darwin.unlinkat(descriptor, pointer, AT_REMOVEDIR)
        }
        _ = try? unlinkCapturedObject(
            named: name,
            in: parentDescriptor,
            descriptor: descriptor,
            expectedIdentity: identity,
            isDirectory: true
        )
        _ = Darwin.close(descriptor)
    }

    private func openDeletionQuarantine(
        in parentDescriptor: Int32,
        identifier: UUID,
        evidence: TorrentStorageDeletionEvidence
    ) throws -> DeletionQuarantine {
        let name = deletionQuarantineName(identifier)
        let descriptor = try openVerifiedDirectory(
            named: name,
            in: parentDescriptor,
            expectedIdentity: evidence.quarantineIdentity
        )
        do {
            let entriesDescriptor = try openVerifiedDirectory(
                named: "entries",
                in: descriptor,
                expectedIdentity: evidence.entriesIdentity
            )
            return DeletionQuarantine(
                name: name,
                descriptor: descriptor,
                entriesDescriptor: entriesDescriptor,
                evidence: evidence
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func deletionQuarantineName(_ identifier: UUID) -> String {
        ".torrent7-deletion-\(identifier.uuidString.lowercased())"
    }

    private func removeDeletionQuarantine(
        _ quarantine: DeletionQuarantine,
        from parentDescriptor: Int32
    ) throws {
        guard try unlinkCapturedObject(
            named: "entries",
            in: quarantine.descriptor,
            descriptor: quarantine.entriesDescriptor,
            expectedIdentity: quarantine.evidence.entriesIdentity,
            isDirectory: true
        ) == .removed,
              try unlinkCapturedObject(
                  named: quarantine.name,
                  in: parentDescriptor,
                  descriptor: quarantine.descriptor,
                  expectedIdentity: quarantine.evidence.quarantineIdentity,
                  isDirectory: true
              ) == .removed else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
    }

    private func deleteCapturedSingleFile(
        manifest: TorrentStorageManifest,
        quarantine: DeletionQuarantine
    ) throws {
        guard manifest.logicalFiles.count == 1,
              manifest.logicalFiles[0].isPadding == false,
              let expectedIdentity = manifest.topLevelIdentity else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        let captureName = "payload"
        let descriptor = try openCapturedObject(
            named: captureName,
            in: quarantine.descriptor,
            isDirectory: false
        )
        defer { _ = Darwin.close(descriptor) }
        let actualIdentity = try validatePayloadDescriptor(
            descriptor,
            writable: true
        )
        guard actualIdentity == expectedIdentity else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        try verifyOwnershipIfRequired(
            manifest: manifest,
            relativePathComponents: [manifest.collisionSelectedTopLevelName],
            identity: actualIdentity,
            isDirectory: false,
            descriptor: descriptor
        )
        guard try unlinkCapturedObject(
            named: captureName,
            in: quarantine.descriptor,
            descriptor: descriptor,
            expectedIdentity: actualIdentity,
            isDirectory: false
        ) == .removed else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
    }

    private func deleteCapturedDirectoryPayload(
        manifest: TorrentStorageManifest,
        quarantine: DeletionQuarantine
    ) throws -> Bool {
        let captureName = "payload"
        let rootDescriptor = try openCapturedObject(
            named: captureName,
            in: quarantine.descriptor,
            isDirectory: true
        )
        defer { _ = Darwin.close(rootDescriptor) }
        guard let expectedRoot = manifest.topLevelIdentity else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        let rootIdentity = try validateDirectoryDescriptor(rootDescriptor)
        guard rootIdentity.refersToSameObject(as: expectedRoot) else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        try verifyOwnershipIfRequired(
            manifest: manifest,
            relativePathComponents: [manifest.collisionSelectedTopLevelName],
            identity: rootIdentity,
            isDirectory: true,
            descriptor: rootDescriptor
        )

        for index in manifest.logicalFiles.indices {
            let logicalFile = manifest.logicalFiles[index]
            guard !logicalFile.isPadding else {
                continue
            }
            guard let expectedIdentity = manifest.physicalFileIdentities[index]
            else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
            try deleteCapturedEntry(
                sourceComponents: logicalFile.pathComponents,
                captureName: "file-\(logicalFile.index)",
                expectedIdentity: expectedIdentity,
                isDirectory: false,
                manifest: manifest,
                rootDescriptor: rootDescriptor,
                quarantine: quarantine
            )
        }

        for (index, directory) in manifest.physicalDirectoryIdentities
            .enumerated()
            .reversed()
        where !directory.relativePathComponents.isEmpty {
            try deleteCapturedEntry(
                sourceComponents: directory.relativePathComponents,
                captureName: "directory-\(index)",
                expectedIdentity: directory.identity,
                isDirectory: true,
                manifest: manifest,
                rootDescriptor: rootDescriptor,
                quarantine: quarantine
            )
        }

        switch try unlinkCapturedObject(
            named: captureName,
            in: quarantine.descriptor,
            descriptor: rootDescriptor,
            expectedIdentity: rootIdentity,
            isDirectory: true
        ) {
        case .removed:
            return true
        case .directoryNotEmpty:
            guard case .imported = manifest.ownership else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
            return false
        }
    }

    private func deleteCapturedEntry(
        sourceComponents: [String],
        captureName: String,
        expectedIdentity: TorrentFilesystemIdentity,
        isDirectory: Bool,
        manifest: TorrentStorageManifest,
        rootDescriptor: Int32,
        quarantine: DeletionQuarantine
    ) throws {
        guard let leaf = sourceComponents.last else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        var containingDirectory: Int32?
        defer {
            if let containingDirectory {
                _ = Darwin.close(containingDirectory)
            }
        }

        func directoryForRestore() throws -> Int32 {
            if let containingDirectory {
                return containingDirectory
            }
            guard let opened = try openVerifiedParentDirectoryIfPresent(
                of: sourceComponents,
                startingAt: rootDescriptor,
                manifest: manifest
            ) else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
            containingDirectory = opened
            return opened
        }

        if !(try objectExists(
            named: captureName,
            in: quarantine.entriesDescriptor
        )) {
            guard let sourceDirectory = try
                openVerifiedParentDirectoryIfPresent(
                    of: sourceComponents,
                    startingAt: rootDescriptor,
                    manifest: manifest
                ) else {
                return
            }
            containingDirectory = sourceDirectory
            guard try captureForDeletion(
                named: leaf,
                from: sourceDirectory,
                as: captureName,
                in: quarantine.entriesDescriptor
            ) else {
                return
            }
        }

        let descriptor = try openCapturedObject(
            named: captureName,
            in: quarantine.entriesDescriptor,
            isDirectory: isDirectory
        )
        defer { _ = Darwin.close(descriptor) }
        do {
            let actualIdentity = try isDirectory
                ? validateDirectoryDescriptor(descriptor)
                : validatePayloadDescriptor(descriptor, writable: true)
            guard isDirectory
                ? actualIdentity.refersToSameObject(as: expectedIdentity)
                : actualIdentity == expectedIdentity else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
            try verifyOwnershipIfRequired(
                manifest: manifest,
                relativePathComponents: [
                    manifest.collisionSelectedTopLevelName,
                ] + sourceComponents,
                identity: actualIdentity,
                isDirectory: isDirectory,
                descriptor: descriptor
            )
            switch try unlinkCapturedObject(
                named: captureName,
                in: quarantine.entriesDescriptor,
                descriptor: descriptor,
                expectedIdentity: actualIdentity,
                isDirectory: isDirectory
            ) {
            case .removed:
                break
            case .directoryNotEmpty:
                guard isDirectory,
                      case .imported = manifest.ownership else {
                    throw TorrentStoragePlanningError.deletionNotProvable
                }
                try restoreDeletionCapture(
                    named: captureName,
                    from: quarantine.entriesDescriptor,
                    as: leaf,
                    in: try directoryForRestore()
                )
                return
            }
        } catch {
            try? restoreDeletionCapture(
                named: captureName,
                from: quarantine.entriesDescriptor,
                as: leaf,
                in: try directoryForRestore()
            )
            throw error
        }
    }

    private func restoreStagedEntries(
        manifest: TorrentStorageManifest,
        quarantine: DeletionQuarantine
    ) throws -> Bool {
        guard try objectExists(named: "payload", in: quarantine.descriptor),
              manifest.contentKind == .directory else {
            return true
        }
        let rootDescriptor = try openCapturedObject(
            named: "payload",
            in: quarantine.descriptor,
            isDirectory: true
        )
        defer { _ = Darwin.close(rootDescriptor) }

        for (index, directory) in manifest.physicalDirectoryIdentities
            .enumerated()
        where !directory.relativePathComponents.isEmpty {
            let captureName = "directory-\(index)"
            guard try objectExists(
                named: captureName,
                in: quarantine.entriesDescriptor
            ),
            let leaf = directory.relativePathComponents.last else {
                continue
            }
            let parent = try openVerifiedParentDirectory(
                of: directory.relativePathComponents,
                startingAt: rootDescriptor,
                manifest: manifest
            )
            defer { _ = Darwin.close(parent) }
            try restoreDeletionCapture(
                named: captureName,
                from: quarantine.entriesDescriptor,
                as: leaf,
                in: parent
            )
        }

        for index in manifest.logicalFiles.indices {
            let logicalFile = manifest.logicalFiles[index]
            let captureName = "file-\(logicalFile.index)"
            guard !logicalFile.isPadding,
                  try objectExists(
                      named: captureName,
                      in: quarantine.entriesDescriptor
                  ),
                  let leaf = logicalFile.pathComponents.last else {
                continue
            }
            let parent = try openVerifiedParentDirectory(
                of: logicalFile.pathComponents,
                startingAt: rootDescriptor,
                manifest: manifest
            )
            defer { _ = Darwin.close(parent) }
            try restoreDeletionCapture(
                named: captureName,
                from: quarantine.entriesDescriptor,
                as: leaf,
                in: parent
            )
        }
        return true
    }

    private func openVerifiedParentDirectory(
        of components: [String],
        startingAt rootDescriptor: Int32,
        manifest: TorrentStorageManifest
    ) throws -> Int32 {
        guard let descriptor = try openVerifiedParentDirectoryIfPresent(
            of: components,
            startingAt: rootDescriptor,
            manifest: manifest
        ) else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        return descriptor
    }

    // SAFETY: Ownership/lifetime: each component pins its C string during openat and the
    // descriptor chain is closed or returned exactly once; bounds/alignment: manifest path
    // components are validated before this helper and withCString NUL-terminates them;
    // synchronization: every opened directory is checked against immutable pinned identity;
    // safe alternative: openat/O_NOFOLLOW traversal is required to resist component swaps.
    private func openVerifiedParentDirectoryIfPresent(
        of components: [String],
        startingAt rootDescriptor: Int32,
        manifest: TorrentStorageManifest
    ) throws -> Int32? {
        var current = Darwin.dup(rootDescriptor)
        guard current >= 0 else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        var traversed = [String]()
        do {
            for component in components.dropLast() {
                traversed.append(component)
                guard let expected = manifest.physicalDirectoryIdentities
                    .first(where: {
                        $0.relativePathComponents == traversed
                    })?.identity else {
                    throw TorrentStoragePlanningError.deletionNotProvable
                }
                let next = component.withCString { pointer in
                    unsafe Darwin.openat(
                        current,
                        pointer,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                            | O_NONBLOCK
                    )
                }
                if next < 0, errno == ENOENT {
                    _ = Darwin.close(current)
                    return nil
                }
                guard next >= 0 else {
                    throw TorrentStoragePlanningError.deletionNotProvable
                }
                do {
                    let actual = try validateDirectoryDescriptor(next)
                    guard actual.refersToSameObject(as: expected) else {
                        throw TorrentStoragePlanningError.deletionNotProvable
                    }
                    try verifyOwnershipIfRequired(
                        manifest: manifest,
                        relativePathComponents: [
                            manifest.collisionSelectedTopLevelName,
                        ] + traversed,
                        identity: actual,
                        isDirectory: true,
                        descriptor: next
                    )
                } catch {
                    _ = Darwin.close(next)
                    throw error
                }
                _ = Darwin.close(current)
                current = next
            }
            return current
        } catch {
            _ = Darwin.close(current)
            throw error
        }
    }

    private func verifyOwnershipIfRequired(
        manifest: TorrentStorageManifest,
        relativePathComponents: [String],
        identity: TorrentFilesystemIdentity,
        isDirectory: Bool,
        descriptor: Int32
    ) throws {
        guard case .appCreated(let key) = manifest.ownership else {
            return
        }
        try verifyOwnershipTag(
            key: key,
            claimID: manifest.claimID,
            claimGeneration: manifest.generation,
            relativePathComponents: relativePathComponents,
            identity: identity,
            isDirectory: isDirectory,
            descriptor: descriptor
        )
    }

    // SAFETY: Ownership/lifetime: the caller keeps both descriptors open, the name pins its
    // C bytes per call, and local stat storage spans each syscall; bounds/alignment: the name
    // is validated/NUL-terminated and stat values are exact/aligned; synchronization: pinned
    // descriptor and path identities are compared immediately before unlink; safe alternative:
    // fstat/fstatat/unlinkat are required to bind deletion to the captured object.
    private func unlinkCapturedObject(
        named name: String,
        in directoryDescriptor: Int32,
        descriptor: Int32,
        expectedIdentity: TorrentFilesystemIdentity,
        isDirectory: Bool
    ) throws -> CapturedUnlinkResult {
        var descriptorMetadata = stat()
        var pathMetadata = stat()
        let descriptorStatus = unsafe Darwin.fstat(descriptor, &descriptorMetadata)
        let pathStatus = name.withCString { pointer in
            unsafe Darwin.fstatat(
                directoryDescriptor,
                pointer,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        let descriptorIdentity = identity(descriptorMetadata)
        let pathIdentity = identity(pathMetadata)
        let expectedType = isDirectory ? S_IFDIR : S_IFREG
        guard descriptorStatus == 0,
              pathStatus == 0,
              (pathMetadata.st_mode & S_IFMT) == expectedType,
              descriptorIdentity.refersToSameObject(as: expectedIdentity),
              pathIdentity.refersToSameObject(as: expectedIdentity) else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        let status = name.withCString { pointer in
            unsafe Darwin.unlinkat(
                directoryDescriptor,
                pointer,
                isDirectory ? AT_REMOVEDIR : 0
            )
        }
        if status == 0 {
            return .removed
        }
        guard isDirectory, errno == ENOTEMPTY else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        return .directoryNotEmpty
    }

    // SAFETY: Ownership/lifetime: both Strings pin C storage for the nested synchronous
    // rename and both descriptors remain open; bounds/alignment: validated names are
    // NUL-terminated; synchronization: RENAME_EXCL|NOFOLLOW_ANY|RESOLVE_BENEATH performs
    // an atomic non-overwriting move; safe alternative: Foundation has no equivalent
    // descriptor-relative hardened rename.
    private func captureForDeletion(
        named sourceName: String,
        from sourceDirectory: Int32,
        as captureName: String,
        in quarantineDescriptor: Int32
    ) throws -> Bool {
        let status = sourceName.withCString { source in
            captureName.withCString { destination in
                unsafe Darwin.renameatx_np(
                    sourceDirectory,
                    source,
                    quarantineDescriptor,
                    destination,
                    Self.deletionRenameFlags
                )
            }
        }
        if status == 0 {
            return true
        }
        guard errno == ENOENT else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        return false
    }

    // SAFETY: Ownership/lifetime: both Strings pin C storage for the nested synchronous
    // rename and descriptors remain open; bounds/alignment: validated names are NUL-terminated;
    // synchronization: hardened rename flags atomically reject replacement and traversal;
    // safe alternative: Foundation has no descriptor-relative hardened rename equivalent.
    private func restoreDeletionCapture(
        named captureName: String,
        from quarantineDescriptor: Int32,
        as destinationName: String,
        in destinationDirectory: Int32
    ) throws {
        let status = captureName.withCString { source in
            destinationName.withCString { destination in
                unsafe Darwin.renameatx_np(
                    quarantineDescriptor,
                    source,
                    destinationDirectory,
                    destination,
                    Self.deletionRenameFlags
                )
            }
        }
        guard status == 0 else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
    }

    // SAFETY: Ownership/lifetime: the String and local stat storage live through fstatat;
    // bounds/alignment: the validated name is NUL-terminated and stat storage exact/aligned;
    // synchronization: this is an immediate descriptor-relative observation; safe alternative:
    // fstatat with AT_SYMLINK_NOFOLLOW avoids following or re-resolving a path.
    private func objectExists(
        named name: String,
        in directoryDescriptor: Int32
    ) throws -> Bool {
        var metadata = stat()
        let status = name.withCString { pointer in
            unsafe Darwin.fstatat(
                directoryDescriptor,
                pointer,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if status == 0 {
            return true
        }
        guard errno == ENOENT else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        return false
    }

    // SAFETY: Ownership/lifetime: the String and stat storage live through each call and
    // the successful descriptor is returned to its owner; bounds/alignment: the validated
    // name is NUL-terminated and stat storage exact/aligned; synchronization: type is checked
    // immediately before no-follow open; safe alternative: fstatat/openat bind access to
    // directory authority and reject symlink traversal.
    private func openCapturedObject(
        named name: String,
        in directoryDescriptor: Int32,
        isDirectory: Bool
    ) throws -> Int32 {
        var metadata = stat()
        let status = name.withCString { pointer in
            unsafe Darwin.fstatat(
                directoryDescriptor,
                pointer,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        let expectedType = isDirectory ? S_IFDIR : S_IFREG
        guard status == 0,
              (metadata.st_mode & S_IFMT) == expectedType else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        let flags = (isDirectory ? O_RDONLY | O_DIRECTORY : O_RDONLY)
            | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        let descriptor = name.withCString { pointer in
            unsafe Darwin.openat(directoryDescriptor, pointer, flags)
        }
        guard descriptor >= 0 else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        return descriptor
    }

    private struct ReservedTopLevel {
        let name: String
        let descriptor: Int32
        let identity: TorrentFilesystemIdentity
    }

    private struct CreatedObject {
        let components: [String]
        let identity: TorrentFilesystemIdentity
        let isDirectory: Bool
    }

    // SAFETY: Ownership/lifetime: each candidate pins its C string for openat and the
    // successful descriptor is returned or closed on failure; bounds/alignment: validated
    // candidate names are NUL-terminated; synchronization: O_EXCL atomically reserves the
    // name before ownership evidence is published; safe alternative: Foundation cannot
    // atomically create relative to trusted directory authority with O_NOFOLLOW.
    private func reserveSingleFile(
        preferredName: String,
        selectedName: String?,
        parentDescriptor: Int32,
        claimID: UUID,
        claimGeneration: UInt64,
        ownershipKey: Data,
        created: inout [CreatedObject]
    ) throws -> ReservedTopLevel {
        let attempts = selectedName == nil ? Self.maximumCollisionAttempts : 1
        for attempt in 1...attempts {
            let candidate = selectedName
                ?? collisionName(preferredName, attempt: attempt, isDirectory: false)
            let descriptor = candidate.withCString { pointer in
                unsafe Darwin.openat(
                    parentDescriptor,
                    pointer,
                    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
            }
            if descriptor < 0 {
                if errno == EEXIST, selectedName == nil {
                    continue
                }
                throw TorrentStoragePlanningError.reservationFailed
            }
            do {
                let identity = try validatePayloadDescriptor(descriptor, writable: true)
                created.append(CreatedObject(
                    components: [candidate],
                    identity: identity,
                    isDirectory: false
                ))
                try setOwnershipTag(
                    key: ownershipKey,
                    claimID: claimID,
                    claimGeneration: claimGeneration,
                    relativePathComponents: [candidate],
                    identity: identity,
                    isDirectory: false,
                    descriptor: descriptor
                )
                return ReservedTopLevel(
                    name: candidate,
                    descriptor: descriptor,
                    identity: identity
                )
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
        throw TorrentStoragePlanningError.destinationNameExhausted
    }

    // SAFETY: Ownership/lifetime: each candidate pins its C string for synchronous mkdirat
    // and the reopened descriptor is returned or closed on failure; bounds/alignment:
    // validated candidate names are NUL-terminated; synchronization: mkdirat atomically
    // reserves the name before identity/tag publication; safe alternative: Foundation has
    // no descriptor-relative directory creation tied to trusted parent authority.
    private func reserveDirectory(
        preferredName: String,
        selectedName: String?,
        parentDescriptor: Int32,
        claimID: UUID,
        claimGeneration: UInt64,
        ownershipKey: Data,
        created: inout [CreatedObject]
    ) throws -> ReservedTopLevel {
        let attempts = selectedName == nil ? Self.maximumCollisionAttempts : 1
        for attempt in 1...attempts {
            let candidate = selectedName
                ?? collisionName(preferredName, attempt: attempt, isDirectory: true)
            let status = candidate.withCString { pointer in
                unsafe Darwin.mkdirat(parentDescriptor, pointer, mode_t(0o700))
            }
            if status != 0 {
                if errno == EEXIST, selectedName == nil {
                    continue
                }
                throw TorrentStoragePlanningError.reservationFailed
            }
            let descriptor = try openDirectory(
                named: candidate,
                relativeTo: parentDescriptor
            )
            do {
                let identity = try validateDirectoryDescriptor(descriptor)
                created.append(CreatedObject(
                    components: [candidate],
                    identity: identity,
                    isDirectory: true
                ))
                try setOwnershipTag(
                    key: ownershipKey,
                    claimID: claimID,
                    claimGeneration: claimGeneration,
                    relativePathComponents: [candidate],
                    identity: identity,
                    isDirectory: true,
                    descriptor: descriptor
                )
                return ReservedTopLevel(
                    name: candidate,
                    descriptor: descriptor,
                    identity: identity
                )
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
        throw TorrentStoragePlanningError.destinationNameExhausted
    }

    // SAFETY: Ownership/lifetime: each leaf pins its C string during openat and every
    // descriptor is closed by the local control flow; bounds/alignment: logical paths were
    // validated by the manifest and withCString NUL-terminates them; synchronization:
    // O_EXCL publishes each file atomically before recording identity; safe alternative:
    // descriptor-relative O_NOFOLLOW creation is required to resist directory substitution.
    private func createDirectoryPayload(
        _ logicalFiles: [TorrentLogicalFile],
        topLevel: ReservedTopLevel,
        parentDescriptor: Int32,
        claimID: UUID,
        claimGeneration: UInt64,
        ownershipKey: Data,
        created: inout [CreatedObject]
    ) throws -> (
        fileIdentities: [TorrentFilesystemIdentity?],
        directoryIdentities: [TorrentPhysicalDirectoryIdentity]
    ) {
        defer {
            _ = Darwin.close(topLevel.descriptor)
        }
        var directoryIdentities = [[String]: TorrentFilesystemIdentity]()
        directoryIdentities[[]] = topLevel.identity
        var fileIdentities = [TorrentFilesystemIdentity?]()
        fileIdentities.reserveCapacity(logicalFiles.count)

        for logicalFile in logicalFiles {
            if logicalFile.isPadding {
                fileIdentities.append(nil)
                continue
            }
            guard let leaf = logicalFile.pathComponents.last else {
                throw TorrentStoragePlanningError.reservationFailed
            }
            let directoryComponents = Array(logicalFile.pathComponents.dropLast())
            let containingDescriptor = try prepareDirectories(
                directoryComponents,
                topLevelDescriptor: topLevel.descriptor,
                topLevelName: topLevel.name,
                claimID: claimID,
                claimGeneration: claimGeneration,
                ownershipKey: ownershipKey,
                identities: &directoryIdentities,
                created: &created
            )
            defer {
                if containingDescriptor != topLevel.descriptor {
                    _ = Darwin.close(containingDescriptor)
                }
            }
            let fileDescriptor = leaf.withCString { pointer in
                unsafe Darwin.openat(
                    containingDescriptor,
                    pointer,
                    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
            }
            guard fileDescriptor >= 0 else {
                throw TorrentStoragePlanningError.reservationFailed
            }
            let identity: TorrentFilesystemIdentity
            let relativeComponents = [topLevel.name] + logicalFile.pathComponents
            do {
                identity = try validatePayloadDescriptor(fileDescriptor, writable: true)
                created.append(CreatedObject(
                    components: relativeComponents,
                    identity: identity,
                    isDirectory: false
                ))
                try setOwnershipTag(
                    key: ownershipKey,
                    claimID: claimID,
                    claimGeneration: claimGeneration,
                    relativePathComponents: relativeComponents,
                    identity: identity,
                    isDirectory: false,
                    descriptor: fileDescriptor
                )
            } catch {
                _ = Darwin.close(fileDescriptor)
                throw error
            }
            _ = Darwin.close(fileDescriptor)

            fileIdentities.append(identity)
        }
        return (
            fileIdentities,
            canonicalDirectoryIdentities(directoryIdentities)
        )
    }

    // SAFETY: Ownership/lifetime: each component pins its C string for mkdirat and the
    // descriptor chain is closed or returned exactly once; bounds/alignment: manifest
    // components are validated and NUL-terminated; synchronization: creation/identity
    // checks occur serially and every existing directory is reopened no-follow;
    // safe alternative: descriptor-relative mkdirat is required to avoid path races.
    private func prepareDirectories(
        _ components: [String],
        topLevelDescriptor: Int32,
        topLevelName: String,
        claimID: UUID,
        claimGeneration: UInt64,
        ownershipKey: Data,
        identities: inout [[String]: TorrentFilesystemIdentity],
        created: inout [CreatedObject]
    ) throws -> Int32 {
        guard !components.isEmpty else {
            return topLevelDescriptor
        }
        let duplicated = Darwin.dup(topLevelDescriptor)
        guard duplicated >= 0 else {
            throw TorrentStoragePlanningError.reservationFailed
        }
        var current = TorrentOwnedFileDescriptor(taking: duplicated)
        var traversed = [String]()
        for component in components {
            traversed.append(component)
            let status = component.withCString { pointer in
                unsafe Darwin.mkdirat(current.rawValue, pointer, mode_t(0o700))
            }
            if status == 0 {
                let next = TorrentOwnedFileDescriptor(taking: try openDirectory(
                    named: component,
                    relativeTo: current.rawValue
                ))
                let identity = try validateDirectoryDescriptor(next.rawValue)
                created.append(CreatedObject(
                    components: [topLevelName] + traversed,
                    identity: identity,
                    isDirectory: true
                ))
                try setOwnershipTag(
                    key: ownershipKey,
                    claimID: claimID,
                    claimGeneration: claimGeneration,
                    relativePathComponents: [topLevelName] + traversed,
                    identity: identity,
                    isDirectory: true,
                    descriptor: next.rawValue
                )
                identities[traversed] = identity
                current = consume next
                continue
            }
            guard errno == EEXIST,
                  let expected = identities[traversed] else {
                throw TorrentStoragePlanningError.filesystemObjectChanged
            }
            let next = TorrentOwnedFileDescriptor(taking: try openDirectory(
                named: component,
                relativeTo: current.rawValue
            ))
            let actual = try validateDirectoryDescriptor(next.rawValue)
            guard actual.refersToSameObject(as: expected) else {
                throw TorrentStoragePlanningError.filesystemObjectChanged
            }
            current = consume next
        }
        return current.relinquish()
    }

    private func inspectExistingPayload(
        manifest logicalManifest: TorrentLogicalManifest,
        in parent: TorrentStorageParentAuthority,
        topLevelName: String
    ) throws -> (
        fileIdentities: [TorrentFilesystemIdentity?],
        directoryIdentities: [TorrentPhysicalDirectoryIdentity]
    ) {
        switch logicalManifest.contentKind {
        case .singleFile:
            guard logicalManifest.files.count == 1,
                  let logicalFile = logicalManifest.files.first,
                  !logicalFile.isPadding else {
                throw TorrentStoragePlanningError.existingDataUnsafe
            }
            let descriptor = try openImportedPayload(
                named: topLevelName,
                relativeTo: parent.descriptor
            )
            defer { _ = Darwin.close(descriptor) }
            let identity = try validateImportedPayloadDescriptor(
                descriptor,
                maximumSize: logicalFile.expectedSize
            )
            return ([identity], [])
        case .directory:
            let topLevelDescriptor: Int32
            do {
                topLevelDescriptor = try openDirectory(
                    named: topLevelName,
                    relativeTo: parent.descriptor
                )
            } catch {
                throw TorrentStoragePlanningError.existingDataUnavailable
            }
            defer { _ = Darwin.close(topLevelDescriptor) }
            var directoryIdentities = [[String]: TorrentFilesystemIdentity]()
            directoryIdentities[[]] = try validateDirectoryDescriptor(
                topLevelDescriptor
            )
            let fileIdentities = try logicalManifest.files.map { logicalFile in
                guard !logicalFile.isPadding else {
                    return nil as TorrentFilesystemIdentity?
                }
                return try inspectImportedPayload(
                    logicalFile.pathComponents,
                    startingAt: topLevelDescriptor,
                    maximumSize: logicalFile.expectedSize,
                    directoryIdentities: &directoryIdentities
                )
            }
            guard TorrentFilesystemIdentity.allPresentObjectsAreDistinct(
                fileIdentities
            ) else {
                throw TorrentStoragePlanningError.existingDataUnsafe
            }
            return (
                fileIdentities,
                canonicalDirectoryIdentities(directoryIdentities)
            )
        }
    }

    private func inspectImportedPayload(
        _ components: [String],
        startingAt rootDescriptor: Int32,
        maximumSize: Int64,
        directoryIdentities: inout [[String]: TorrentFilesystemIdentity]
    ) throws -> TorrentFilesystemIdentity {
        guard !components.isEmpty,
              components.allSatisfy(TorrentPathComponentValidation.isSafe) else {
            throw TorrentStoragePlanningError.existingDataUnsafe
        }
        let duplicated = Darwin.dup(rootDescriptor)
        guard duplicated >= 0 else {
            throw TorrentStoragePlanningError.existingDataUnavailable
        }
        var current = TorrentOwnedFileDescriptor(taking: duplicated)
        var traversed = [String]()
        for component in components.dropLast() {
            traversed.append(component)
            do {
                let next = TorrentOwnedFileDescriptor(taking: try openDirectory(
                    named: component,
                    relativeTo: current.rawValue
                ))
                let actual = try validateDirectoryDescriptor(next.rawValue)
                if let expected = directoryIdentities[traversed] {
                    guard actual.refersToSameObject(as: expected) else {
                        throw TorrentStoragePlanningError.existingDataUnsafe
                    }
                } else {
                    directoryIdentities[traversed] = actual
                }
                current = consume next
            } catch {
                throw TorrentStoragePlanningError.existingDataUnavailable
            }
        }
        guard let leaf = components.last else {
            throw TorrentStoragePlanningError.existingDataUnsafe
        }
        let payload = try openImportedPayload(
            named: leaf,
            relativeTo: current.rawValue
        )
        defer { _ = Darwin.close(payload) }
        return try validateImportedPayloadDescriptor(
            payload,
            maximumSize: maximumSize
        )
    }

    private func canonicalDirectoryIdentities(
        _ identities: [[String]: TorrentFilesystemIdentity]
    ) -> [TorrentPhysicalDirectoryIdentity] {
        identities.map {
            TorrentPhysicalDirectoryIdentity(
                relativePathComponents: $0.key,
                identity: $0.value
            )
        }.sorted { left, right in
            if left.relativePathComponents.count
                != right.relativePathComponents.count {
                return left.relativePathComponents.count
                    < right.relativePathComponents.count
            }
            return left.relativePathComponents.lexicographicallyPrecedes(
                right.relativePathComponents
            )
        }
    }

    // SAFETY: Ownership/lifetime: the name pins its C string for synchronous openat and
    // the successful descriptor is returned to the caller; bounds/alignment: the imported
    // manifest name is validated and NUL-terminated; synchronization: the object is opened
    // no-follow before identity validation; safe alternative: descriptor-relative openat
    // is required to avoid symlink and parent-substitution races.
    private func openImportedPayload(
        named name: String,
        relativeTo descriptor: Int32
    ) throws -> Int32 {
        let opened = name.withCString { pointer in
            unsafe Darwin.openat(
                descriptor,
                pointer,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard opened >= 0 else {
            throw TorrentStoragePlanningError.existingDataUnavailable
        }
        return opened
    }

    private func validateImportedPayloadDescriptor(
        _ descriptor: Int32,
        maximumSize: Int64
    ) throws -> TorrentFilesystemIdentity {
        var metadata = stat()
        // SAFETY: Ownership/lifetime: the caller owns the open descriptor and local stat storage
        // spans fstat; bounds/alignment: Swift supplies exact aligned stat storage;
        // synchronization: validation happens before the imported descriptor is accepted;
        // safe alternative: fstat authenticates the open object without re-resolving a path.
        guard maximumSize >= 0,
              unsafe Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= maximumSize else {
            throw TorrentStoragePlanningError.existingDataUnsafe
        }
        return identity(metadata)
    }

    // SAFETY: Ownership/lifetime: the name pins its C string during synchronous openat and
    // the successful descriptor is returned; bounds/alignment: validated names are
    // NUL-terminated; synchronization: callers validate identity before publishing access;
    // safe alternative: openat with O_NOFOLLOW preserves trusted directory authority.
    private func openDirectory(named name: String, relativeTo descriptor: Int32) throws -> Int32 {
        let opened = name.withCString { pointer in
            unsafe Darwin.openat(
                descriptor,
                pointer,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard opened >= 0 else {
            throw TorrentStoragePlanningError.filesystemObjectChanged
        }
        return opened
    }

    private func validateDirectoryDescriptor(_ descriptor: Int32) throws -> TorrentFilesystemIdentity {
        var metadata = stat()
        // SAFETY: Ownership/lifetime: the caller keeps the descriptor open and local stat storage
        // spans fstat; bounds/alignment: Swift supplies exact aligned stat storage;
        // synchronization: validation precedes use/publication; safe alternative: fstat verifies
        // the opened directory itself without a pathname race.
        guard unsafe Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid() else {
            throw TorrentStoragePlanningError.unsupportedFilesystemObject
        }
        return identity(metadata)
    }

    private func validatePayloadDescriptor(
        _ descriptor: Int32,
        writable: Bool
    ) throws -> TorrentFilesystemIdentity {
        var metadata = stat()
        // SAFETY: Ownership/lifetime: the caller keeps the descriptor open and local stat storage
        // spans fstat; bounds/alignment: Swift supplies exact aligned stat storage;
        // synchronization: validation precedes use/publication; safe alternative: fstat verifies
        // the opened regular file itself without a pathname race.
        guard unsafe Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              !writable || metadata.st_nlink == 1 else {
            throw TorrentStoragePlanningError.unsupportedFilesystemObject
        }
        return identity(metadata)
    }

    private func identity(_ metadata: stat) -> TorrentFilesystemIdentity {
        TorrentFilesystemIdentity(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino),
            linkCount: UInt64(truncatingIfNeeded: metadata.st_nlink),
            ownerUserID: metadata.st_uid,
            fileGeneration: metadata.st_gen
        )
    }

    private func setOwnershipTag(
        key: Data,
        claimID: UUID,
        claimGeneration: UInt64,
        relativePathComponents: [String],
        identity: TorrentFilesystemIdentity,
        isDirectory: Bool,
        descriptor: Int32
    ) throws {
        guard let tag = TorrentStorageOwnershipTag.authenticationCode(
            key: key,
            claimID: claimID,
            claimGeneration: claimGeneration,
            relativePathComponents: relativePathComponents,
            identity: identity,
            isDirectory: isDirectory
        ) else {
            throw TorrentStoragePlanningError.ownershipTagFailed
        }
        // SAFETY: Ownership/lifetime: tag Data and attribute-name String stay alive for
        // synchronous fsetxattr; bounds/alignment: the exact authenticated tag byte count is
        // passed and byte alignment is sufficient; synchronization: the descriptor is exclusively
        // reserved while its tag is installed; safe alternative: descriptor-based xattrs have no
        // safe Swift API and avoid path substitution.
        let status = unsafe tag.withUnsafeBytes { bytes in
            Self.ownershipAttribute.withCString { name in
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
        guard status == 0 else {
            throw TorrentStoragePlanningError.ownershipTagFailed
        }
    }

    private func verifyOwnershipTag(
        key: Data,
        claimID: UUID,
        claimGeneration: UInt64,
        relativePathComponents: [String],
        identity: TorrentFilesystemIdentity,
        isDirectory: Bool,
        descriptor: Int32
    ) throws {
        var tag = Data(count: TorrentStorageOwnershipTag.tagByteCount)
        // SAFETY: Ownership/lifetime: mutable Data and the attribute-name String are pinned for
        // synchronous fgetxattr; bounds/alignment: exact tag capacity is passed, byte alignment
        // is sufficient, and the returned count must match; synchronization: validation only
        // reads the open descriptor; safe alternative: descriptor-based xattrs have no safe Swift
        // API and avoid path substitution.
        let result = unsafe tag.withUnsafeMutableBytes { bytes in
            Self.ownershipAttribute.withCString { name in
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
        guard result == tag.count,
              TorrentStorageOwnershipTag.isValid(
                  tag,
                  key: key,
                  claimID: claimID,
                  claimGeneration: claimGeneration,
                  relativePathComponents: relativePathComponents,
                  identity: identity,
                  isDirectory: isDirectory
              ) else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
    }

    private func collisionName(
        _ preferredName: String,
        attempt: Int,
        isDirectory: Bool
    ) -> String {
        guard attempt > 1 else {
            return preferredName
        }
        guard !isDirectory,
              let dot = preferredName.lastIndex(of: "."),
              dot != preferredName.startIndex,
              preferredName.index(after: dot) != preferredName.endIndex else {
            return "\(preferredName) \(attempt)"
        }
        return "\(preferredName[..<dot]) \(attempt)\(preferredName[dot...])"
    }

    // SAFETY: Ownership/lifetime: the capture name pins its C string for synchronous unlinkat
    // and the quarantine owns open descriptors until deferred close; bounds/alignment: the
    // fixed name is NUL-terminated; synchronization: the object is atomically captured and
    // identity-verified before unlink; safe alternative: descriptor-relative unlinkat is
    // necessary to delete only the proven captured object.
    private func cleanUp(
        _ objects: [CreatedObject],
        parentDescriptor: Int32,
        claimID: UUID
    ) {
        guard let root = objects.first,
              root.components.count == 1,
              let rootName = root.components.first,
              let quarantine = try? makeDeletionQuarantine(
                  in: parentDescriptor,
                  identifier: claimID
              ) else {
            return
        }
        defer {
            _ = try? removeDeletionQuarantine(
                quarantine,
                from: parentDescriptor
            )
            quarantine.close()
        }

        let captureName = "payload"
        guard (try? captureForDeletion(
            named: rootName,
            from: parentDescriptor,
            as: captureName,
            in: quarantine.descriptor
        )) == true else {
            return
        }

        do {
            let rootDescriptor = try openCapturedObject(
                named: captureName,
                in: quarantine.descriptor,
                isDirectory: root.isDirectory
            )
            defer { _ = Darwin.close(rootDescriptor) }
            let actualRoot = try root.isDirectory
                ? validateDirectoryDescriptor(rootDescriptor)
                : validatePayloadDescriptor(rootDescriptor, writable: true)
            guard actualRoot.refersToSameObject(as: root.identity) else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }

            if root.isDirectory {
                for object in objects.dropFirst().reversed() {
                    try deleteCreatedObject(
                        object,
                        relativeTo: rootDescriptor
                    )
                }
            }
            let status = captureName.withCString { pointer in
                unsafe Darwin.unlinkat(
                    quarantine.descriptor,
                    pointer,
                    root.isDirectory ? AT_REMOVEDIR : 0
                )
            }
            guard status == 0 else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
        } catch {
            try? restoreDeletionCapture(
                named: captureName,
                from: quarantine.descriptor,
                as: rootName,
                in: parentDescriptor
            )
        }
    }

    // SAFETY: Ownership/lifetime: the leaf String pins its C bytes for openat/unlinkat and
    // every local descriptor is closed; bounds/alignment: recorded manifest components are
    // validated and NUL-terminated; synchronization: the opened identity is compared with
    // creation evidence immediately before deletion; safe alternative: descriptor-relative
    // no-follow operations are required to resist object substitution.
    private func deleteCreatedObject(
        _ object: CreatedObject,
        relativeTo rootDescriptor: Int32
    ) throws {
        let components = Array(object.components.dropFirst())
        guard !components.isEmpty,
              let leaf = components.last else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        let containingDirectory = try openParentDirectory(
            of: components,
            startingAt: rootDescriptor
        )
        defer {
            if containingDirectory != rootDescriptor {
                _ = Darwin.close(containingDirectory)
            }
        }
        let descriptor = leaf.withCString { pointer in
            unsafe Darwin.openat(
                containingDirectory,
                pointer,
                (object.isDirectory ? O_RDONLY | O_DIRECTORY : O_RDONLY)
                    | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        if descriptor < 0, errno == ENOENT {
            return
        }
        guard descriptor >= 0 else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        let actual: TorrentFilesystemIdentity
        do {
            actual = try object.isDirectory
                ? validateDirectoryDescriptor(descriptor)
                : validatePayloadDescriptor(descriptor, writable: true)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        _ = Darwin.close(descriptor)
        guard actual.refersToSameObject(as: object.identity) else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        let status = leaf.withCString { pointer in
            unsafe Darwin.unlinkat(
                containingDirectory,
                pointer,
                object.isDirectory ? AT_REMOVEDIR : 0
            )
        }
        guard status == 0 || errno == ENOENT else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
    }

    private func openParentDirectory(
        of components: [String],
        startingAt parentDescriptor: Int32
    ) throws -> Int32 {
        let parents = components.dropLast()
        guard !parents.isEmpty else {
            return parentDescriptor
        }
        var current = Darwin.dup(parentDescriptor)
        guard current >= 0 else {
            throw TorrentStoragePlanningError.reservationFailed
        }
        do {
            for component in parents {
                let next = try openDirectory(named: component, relativeTo: current)
                _ = Darwin.close(current)
                current = next
            }
            return current
        } catch {
            _ = Darwin.close(current)
            throw error
        }
    }
}
