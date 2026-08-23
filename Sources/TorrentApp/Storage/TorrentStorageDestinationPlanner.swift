import Darwin
import Foundation
import System

enum TorrentStoragePlanningError: LocalizedError, Equatable, Sendable {
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

    var errorDescription: String? {
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

final class TorrentStorageParentAuthority: @unchecked Sendable {
    let id: UUID
    let canonicalPath: String
    let identity: TorrentFilesystemIdentity
    let descriptor: Int32

    private let accessLifetime: DownloadFolderAccessLease

    init(
        id: UUID = UUID(),
        lease: DownloadFolderAccessLease
    ) throws {
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
        let pathStatus = unsafe path.withCString { pointer in
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

        self.id = id
        canonicalPath = path
        identity = Self.identity(descriptorMetadata)
        descriptor = opened.rawValue
        accessLifetime = lease
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    func validate() throws {
        var metadata = stat()
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

struct TorrentStorageLocation: Sendable {
    let torrentID: String
    let claim: TorrentStorageClaim
    let parent: TorrentStorageParentAuthority

    init?(
        claim: TorrentStorageClaim,
        parent: TorrentStorageParentAuthority
    ) {
        guard let torrentID = claim.torrentID,
              claim.manifest.parentAuthorityID == parent.id else {
            return nil
        }
        self.torrentID = torrentID
        self.claim = claim
        self.parent = parent
    }

    var displayURL: URL {
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

    var displayPath: String {
        displayURL.path(percentEncoded: false)
    }
}

struct TorrentStorageReservation: Sendable {
    let storageManifest: TorrentStorageManifest
    let initialLease: TorrentStorageLease
}

struct TorrentStorageDestinationConflict: Equatable, Sendable {
    let existingTopLevelName: String
    let separateCopyTopLevelName: String
    let parentPath: String
    let canUseExistingFiles: Bool

    var parentDisplayName: String {
        URL(filePath: parentPath, directoryHint: .isDirectory)
            .lastPathComponent
    }
}

enum TorrentStorageDestinationChoice: Equatable, Sendable {
    case preferredName
    case separateCopy(topLevelName: String)
    case useExistingFiles
}

struct TorrentStorageDestinationPlanner: Sendable {
    static let ownershipAttribute = "app.torrent7.storage-claim"
    private static let maximumCollisionAttempts = 10_000
    private static let deletionRenameFlags = UInt32(
        RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
    )

    func planTopLevelName(
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
            let status = unsafe candidate.withCString { pointer in
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

    func inspectDestination(
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

    func reserve(
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

            let mappings: [TorrentPhysicalFileMapping]
            switch logicalManifest.contentKind {
            case .singleFile:
                guard logicalManifest.files.count == 1,
                      logicalManifest.files[0].isPadding == false else {
                    throw TorrentStoragePlanningError.reservationFailed
                }
                mappings = [TorrentPhysicalFileMapping(
                    fileIndex: logicalManifest.files[0].index,
                    relativePathComponents: [reservation.name],
                    identity: reservation.identity
                )]
            case .directory:
                mappings = try createDirectoryPayload(
                    logicalManifest.files,
                    topLevel: reservation,
                    parentDescriptor: parent.descriptor,
                    claimID: claimID,
                    claimGeneration: generation,
                    ownershipKey: ownershipKey,
                    created: &created
                )
            }

            let mappingDigest = TorrentManifestDigest.mapping(
                claimID: claimID,
                generation: generation,
                parentAuthorityID: parent.id,
                topLevelName: reservation.name,
                mappings: mappings
            )
            let storageManifest = TorrentStorageManifest(
                claimID: claimID,
                generation: generation,
                infoHashes: logicalManifest.infoHashes,
                sourceManifestDigest: logicalManifest.sourceManifestDigest,
                parentAuthorityID: parent.id,
                contentKind: logicalManifest.contentKind,
                logicalFiles: logicalManifest.files,
                physicalMappings: mappings,
                collisionSelectedTopLevelName: reservation.name,
                topLevelIdentity: reservation.identity,
                claimMappingDigest: mappingDigest,
                ownershipKey: ownershipKey
            )
            let policies = logicalManifest.files.map { file in
                TorrentPayloadFilePolicy(
                    fileIndex: file.index,
                    maximumAccess: file.isPadding ? .unavailable : .appOwnedWritable,
                    provenance: .appCreated,
                    mayModify: !file.isPadding,
                    mayDeleteAutomatically: !file.isPadding
                )
            }
            return TorrentStorageReservation(
                storageManifest: storageManifest,
                initialLease: TorrentStorageLease(
                    state: .reserved,
                    policyRevision: 1,
                    filePolicies: policies
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
    func importExisting(
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
        let topLevelName = selectedTopLevelName ?? logicalManifest.name
        guard isSafeImportedComponent(topLevelName),
              !topLevelName.hasPrefix(".") else {
            throw TorrentStoragePlanningError.hiddenTopLevelName
        }

        let inspection = try inspectExistingPayload(
            manifest: logicalManifest,
            in: parent,
            topLevelName: topLevelName
        )
        let topLevelIdentity = inspection.topLevelIdentity
        let mappings = inspection.mappings

        let mappingDigest = TorrentManifestDigest.mapping(
            claimID: claimID,
            generation: generation,
            parentAuthorityID: parent.id,
            topLevelName: topLevelName,
            mappings: mappings
        )
        let storageManifest = TorrentStorageManifest(
            claimID: claimID,
            generation: generation,
            infoHashes: logicalManifest.infoHashes,
            sourceManifestDigest: logicalManifest.sourceManifestDigest,
            parentAuthorityID: parent.id,
            contentKind: logicalManifest.contentKind,
            logicalFiles: logicalManifest.files,
            physicalMappings: mappings,
            collisionSelectedTopLevelName: topLevelName,
            topLevelIdentity: topLevelIdentity,
            claimMappingDigest: mappingDigest,
            ownershipKey: ownershipKey
        )
        let policies = logicalManifest.files.map { file in
            TorrentPayloadFilePolicy(
                fileIndex: file.index,
                maximumAccess: file.isPadding
                    ? .unavailable
                    : .explicitlyImportedWritable,
                provenance: .imported,
                mayModify: !file.isPadding,
                mayDeleteAutomatically: false
            )
        }
        return TorrentStorageReservation(
            storageManifest: storageManifest,
            initialLease: TorrentStorageLease(
                state: .reserved,
                policyRevision: 1,
                filePolicies: policies
            )
        )
    }

    static func randomOwnershipKey() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<TorrentStorageOwnershipTag.keyByteCount).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
    }

    func validateClaimRoot(
        _ claim: TorrentStorageClaim,
        in parent: TorrentStorageParentAuthority
    ) throws {
        try parent.validate()
        guard claim.manifest.parentAuthorityID == parent.id,
              claim.manifest.ownershipKey.count
                == TorrentStorageOwnershipTag.keyByteCount else {
            throw TorrentStoragePlanningError.invalidParentAuthority
        }
        let name = claim.manifest.collisionSelectedTopLevelName
        let flags = (claim.manifest.contentKind == .directory
            ? O_RDONLY | O_DIRECTORY
            : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW
        let descriptor = unsafe name.withCString { pointer in
            unsafe Darwin.openat(parent.descriptor, pointer, flags)
        }
        guard descriptor >= 0 else {
            throw TorrentStoragePlanningError.filesystemObjectChanged
        }
        defer { _ = Darwin.close(descriptor) }
        let identity = try claim.manifest.contentKind == .directory
            ? validateDirectoryDescriptor(descriptor)
            : validatePayloadDescriptor(descriptor, writable: true)
        let expectedIdentity = claim.manifest.topLevelIdentity
        guard identity.refersToSameObject(as: expectedIdentity),
              claim.manifest.contentKind == .directory
                || identity.linkCount == expectedIdentity.linkCount else {
            throw TorrentStoragePlanningError.filesystemObjectChanged
        }
        if claim.lease.filePolicies.contains(where: {
            $0.provenance == .appCreated && $0.mayDeleteAutomatically
        }) {
            try verifyOwnershipTag(
                key: claim.manifest.ownershipKey,
                claimID: claim.manifest.claimID,
                claimGeneration: claim.manifest.generation,
                relativePathComponents: [name],
                identity: identity,
                isDirectory: claim.manifest.contentKind == .directory,
                descriptor: descriptor
            )
        }
    }

    /// Resolves a Finder presentation target from GUI-owned claim authority.
    /// The root and any requested file are reopened descriptor-relatively and
    /// checked against their pinned identities before a path is returned to
    /// Finder. Engine-reported save paths and file paths are never consulted.
    func revealURL(
        for location: TorrentStorageLocation,
        fileIndex: Int32? = nil
    ) throws -> URL {
        let claim = location.claim
        let parent = location.parent
        try validateClaimRoot(claim, in: parent)
        let rootURL = location.displayURL
        guard let fileIndex,
              let mapping = claim.manifest.physicalMappings.first(where: {
                  $0.fileIndex == fileIndex
              }),
              let components = mapping.relativePathComponents,
              let expectedIdentity = mapping.identity,
              components.first == claim.manifest.collisionSelectedTopLevelName,
              components.allSatisfy(isSafeImportedComponent) else {
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
            let descriptor = unsafe leaf.withCString { pointer in
                unsafe Darwin.openat(
                    containingDirectory,
                    pointer,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW
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
            if claim.lease.filePolicies.first(where: {
                $0.fileIndex == fileIndex
            })?.provenance == .appCreated {
                try verifyOwnershipTag(
                    key: claim.manifest.ownershipKey,
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

    func deleteClaimedPayload(
        claim: TorrentStorageClaim,
        from parent: TorrentStorageParentAuthority,
        authorizedBy authorization: TorrentPayloadDeletionAuthorization,
        afterCapture: (@Sendable () -> Void)? = nil
    ) throws {
        try parent.validate()
        let manifest = claim.manifest
        guard claim.lease.state == .deleting,
              manifest.parentAuthorityID == parent.id,
              manifest.ownershipKey.count
                == TorrentStorageOwnershipTag.keyByteCount,
              manifest.logicalFiles.map(\.index)
                == manifest.physicalMappings.map(\.fileIndex),
              TorrentStoragePolicyValidation.isValid(
                logicalFiles: manifest.logicalFiles,
                policies: claim.lease.filePolicies
              ) else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }

        let policies = Dictionary(
            uniqueKeysWithValues: claim.lease.filePolicies.map { ($0.fileIndex, $0) }
        )
        var deletableMappings = [TorrentPhysicalFileMapping]()
        deletableMappings.reserveCapacity(manifest.physicalMappings.count)
        for (logicalFile, mapping) in zip(
            manifest.logicalFiles,
            manifest.physicalMappings
        ) {
            if logicalFile.isPadding {
                guard mapping.relativePathComponents == nil,
                      mapping.identity == nil else {
                    throw TorrentStoragePlanningError.deletionNotProvable
                }
                continue
            }
            guard let policy = policies[logicalFile.index],
                  let components = mapping.relativePathComponents,
                  !components.isEmpty,
                  mapping.identity != nil else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
            if policy.permitsDeletion(authorizedBy: authorization) {
                deletableMappings.append(mapping)
            } else if authorization == .explicitUserRequest {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
        }
        guard !deletableMappings.isEmpty else {
            return
        }
        let deletesAppCreatedPayload = deletableMappings.contains { mapping in
            policies[mapping.fileIndex]?.provenance == .appCreated
        }
        let deletesImportedPayload = deletableMappings.contains { mapping in
            policies[mapping.fileIndex]?.provenance == .imported
        }
        guard deletesAppCreatedPayload != deletesImportedPayload else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }

        let quarantine = try makeDeletionQuarantine(
            in: parent.descriptor,
            identifier: claim.operationNonce
        )
        var removedQuarantine = false
        defer {
            if !removedQuarantine {
                _ = try? removeDeletionQuarantine(
                    quarantine,
                    from: parent.descriptor
                )
            }
            _ = Darwin.close(quarantine.descriptor)
        }

        let topLevelName = manifest.collisionSelectedTopLevelName
        let captureName = "payload"
        guard try captureForDeletion(
            named: topLevelName,
            from: parent.descriptor,
            as: captureName,
            in: quarantine.descriptor
        ) else {
            try removeDeletionQuarantine(quarantine, from: parent.descriptor)
            removedQuarantine = true
            return
        }
        afterCapture?()

        var captureExists = true
        do {
            switch manifest.contentKind {
            case .singleFile:
                try deleteCapturedSingleFile(
                    deletableMappings,
                    manifest: manifest,
                    captureName: captureName,
                    quarantineDescriptor: quarantine.descriptor,
                    requiresOwnershipTag: deletesAppCreatedPayload
                )
                captureExists = false
            case .directory:
                let removed = try deleteCapturedDirectoryPayload(
                    deletableMappings,
                    manifest: manifest,
                    captureName: captureName,
                    quarantineDescriptor: quarantine.descriptor,
                    requiresOwnershipTag: deletesAppCreatedPayload,
                    preservesUnrelatedContents: deletesImportedPayload
                )
                if removed {
                    captureExists = false
                } else {
                    try restoreDeletionCapture(
                        named: captureName,
                        from: quarantine.descriptor,
                        as: topLevelName,
                        in: parent.descriptor
                    )
                    captureExists = false
                }
            }
        } catch {
            if captureExists {
                try restoreDeletionCapture(
                    named: captureName,
                    from: quarantine.descriptor,
                    as: topLevelName,
                    in: parent.descriptor
                )
            }
            throw error
        }

        try removeDeletionQuarantine(quarantine, from: parent.descriptor)
        removedQuarantine = true
    }

    private struct DeletionQuarantine {
        let name: String
        let descriptor: Int32
        let identity: TorrentFilesystemIdentity
    }

    /// macOS cannot unlink an already-open descriptor. The fresh directory
    /// turns an exclusive rename into the security boundary: mutable payload
    /// names are captured before validation, and only quarantine names are
    /// subsequently unlinked.
    private func makeDeletionQuarantine(
        in parentDescriptor: Int32,
        identifier: UUID
    ) throws -> DeletionQuarantine {
        let name = ".torrent7-deletion-\(identifier.uuidString.lowercased())"
        let status = unsafe name.withCString { pointer in
            unsafe Darwin.mkdirat(parentDescriptor, pointer, mode_t(0o700))
        }
        guard status == 0 else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }

        let descriptor = unsafe name.withCString { pointer in
            unsafe Darwin.openat(
                parentDescriptor,
                pointer,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        do {
            return DeletionQuarantine(
                name: name,
                descriptor: descriptor,
                identity: try validateDirectoryDescriptor(descriptor)
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func removeDeletionQuarantine(
        _ quarantine: DeletionQuarantine,
        from parentDescriptor: Int32
    ) throws {
        var descriptorMetadata = stat()
        var pathMetadata = stat()
        let descriptorStatus = unsafe Darwin.fstat(
            quarantine.descriptor,
            &descriptorMetadata
        )
        let pathStatus = unsafe quarantine.name.withCString { pointer in
            unsafe Darwin.fstatat(
                parentDescriptor,
                pointer,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard descriptorStatus == 0,
              pathStatus == 0,
              (pathMetadata.st_mode & S_IFMT) == S_IFDIR,
              identity(descriptorMetadata).refersToSameObject(
                as: quarantine.identity
              ),
              identity(pathMetadata).refersToSameObject(
                as: quarantine.identity
              ) else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        let status = unsafe quarantine.name.withCString { pointer in
            unsafe Darwin.unlinkat(
                parentDescriptor,
                pointer,
                AT_REMOVEDIR
            )
        }
        guard status == 0 else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
    }

    private func deleteCapturedSingleFile(
        _ mappings: [TorrentPhysicalFileMapping],
        manifest: TorrentStorageManifest,
        captureName: String,
        quarantineDescriptor: Int32,
        requiresOwnershipTag: Bool
    ) throws {
        guard mappings.count == 1,
              let mapping = mappings.first,
              mapping.relativePathComponents
                == [manifest.collisionSelectedTopLevelName],
              let expectedIdentity = mapping.identity else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        let descriptor = try openCapturedObject(
            named: captureName,
            in: quarantineDescriptor,
            isDirectory: false
        )
        defer { _ = Darwin.close(descriptor) }
        let actualIdentity = try validatePayloadDescriptor(
            descriptor,
            writable: true
        )
        guard actualIdentity == expectedIdentity,
              actualIdentity.refersToSameObject(
                as: manifest.topLevelIdentity
              ) else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        if requiresOwnershipTag {
            try verifyOwnershipTag(
                key: manifest.ownershipKey,
                claimID: manifest.claimID,
                claimGeneration: manifest.generation,
                relativePathComponents: [
                    manifest.collisionSelectedTopLevelName,
                ],
                identity: actualIdentity,
                isDirectory: false,
                descriptor: descriptor
            )
        }
        let status = unsafe captureName.withCString { pointer in
            unsafe Darwin.unlinkat(quarantineDescriptor, pointer, 0)
        }
        guard status == 0 else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
    }

    private func deleteCapturedDirectoryPayload(
        _ mappings: [TorrentPhysicalFileMapping],
        manifest: TorrentStorageManifest,
        captureName: String,
        quarantineDescriptor: Int32,
        requiresOwnershipTag: Bool,
        preservesUnrelatedContents: Bool
    ) throws -> Bool {
        let rootDescriptor = try openCapturedObject(
            named: captureName,
            in: quarantineDescriptor,
            isDirectory: true
        )
        defer { _ = Darwin.close(rootDescriptor) }
        let rootIdentity = try validateDirectoryDescriptor(rootDescriptor)
        let topLevelName = manifest.collisionSelectedTopLevelName
        guard rootIdentity.refersToSameObject(
            as: manifest.topLevelIdentity
        ) else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        if requiresOwnershipTag {
            try verifyOwnershipTag(
                key: manifest.ownershipKey,
                claimID: manifest.claimID,
                claimGeneration: manifest.generation,
                relativePathComponents: [topLevelName],
                identity: rootIdentity,
                isDirectory: true,
                descriptor: rootDescriptor
            )
        }

        var directories = Set<[String]>()
        for mapping in mappings {
            guard let components = mapping.relativePathComponents,
                  components.first == topLevelName,
                  components.count > 1,
                  let expectedIdentity = mapping.identity,
                  let leaf = components.last else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
            let relativeComponents = Array(components.dropFirst())
            for count in 1..<relativeComponents.count {
                directories.insert(Array(relativeComponents.prefix(count)))
            }
            let containingDirectory = try openParentDirectory(
                of: relativeComponents,
                startingAt: rootDescriptor
            )
            defer {
                if containingDirectory != rootDescriptor {
                    _ = Darwin.close(containingDirectory)
                }
            }
            let descriptor = unsafe leaf.withCString { pointer in
                unsafe Darwin.openat(
                    containingDirectory,
                    pointer,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
            }
            if descriptor < 0, errno == ENOENT {
                continue
            }
            guard descriptor >= 0 else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
            do {
                let actualIdentity = try validatePayloadDescriptor(
                    descriptor,
                    writable: true
                )
                guard actualIdentity == expectedIdentity else {
                    throw TorrentStoragePlanningError.deletionNotProvable
                }
                if requiresOwnershipTag {
                    try verifyOwnershipTag(
                        key: manifest.ownershipKey,
                        claimID: manifest.claimID,
                        claimGeneration: manifest.generation,
                        relativePathComponents: components,
                        identity: actualIdentity,
                        isDirectory: false,
                        descriptor: descriptor
                    )
                }
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
            _ = Darwin.close(descriptor)
            let status = unsafe leaf.withCString { pointer in
                unsafe Darwin.unlinkat(containingDirectory, pointer, 0)
            }
            guard status == 0 || errno == ENOENT else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
        }

        let sortedDirectories = directories.sorted { left, right in
            if left.count != right.count {
                return left.count > right.count
            }
            return left.lexicographicallyPrecedes(right)
        }
        for components in sortedDirectories {
            guard let leaf = components.last else {
                continue
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
            let descriptor = unsafe leaf.withCString { pointer in
                unsafe Darwin.openat(
                    containingDirectory,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            if descriptor < 0, errno == ENOENT {
                continue
            }
            guard descriptor >= 0 else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
            do {
                let actualIdentity = try validateDirectoryDescriptor(
                    descriptor
                )
                if requiresOwnershipTag {
                    try verifyOwnershipTag(
                        key: manifest.ownershipKey,
                        claimID: manifest.claimID,
                        claimGeneration: manifest.generation,
                        relativePathComponents: [topLevelName] + components,
                        identity: actualIdentity,
                        isDirectory: true,
                        descriptor: descriptor
                    )
                }
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
            _ = Darwin.close(descriptor)
            let status = unsafe leaf.withCString { pointer in
                unsafe Darwin.unlinkat(
                    containingDirectory,
                    pointer,
                    AT_REMOVEDIR
                )
            }
            guard status == 0
                    || errno == ENOENT
                    || (preservesUnrelatedContents && errno == ENOTEMPTY) else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
        }

        let status = unsafe captureName.withCString { pointer in
            unsafe Darwin.unlinkat(
                quarantineDescriptor,
                pointer,
                AT_REMOVEDIR
            )
        }
        if status == 0 {
            return true
        }
        guard preservesUnrelatedContents,
              errno == ENOTEMPTY else {
            throw TorrentStoragePlanningError.deletionNotProvable
        }
        return false
    }

    private func captureForDeletion(
        named sourceName: String,
        from sourceDirectory: Int32,
        as captureName: String,
        in quarantineDescriptor: Int32
    ) throws -> Bool {
        let status = unsafe sourceName.withCString { source in
            unsafe captureName.withCString { destination in
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

    private func restoreDeletionCapture(
        named captureName: String,
        from quarantineDescriptor: Int32,
        as destinationName: String,
        in destinationDirectory: Int32
    ) throws {
        let status = unsafe captureName.withCString { source in
            unsafe destinationName.withCString { destination in
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

    private func openCapturedObject(
        named name: String,
        in directoryDescriptor: Int32,
        isDirectory: Bool
    ) throws -> Int32 {
        var metadata = stat()
        let status = unsafe name.withCString { pointer in
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
        let descriptor = unsafe name.withCString { pointer in
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
            let descriptor = unsafe candidate.withCString { pointer in
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
            let status = unsafe candidate.withCString { pointer in
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

    private func createDirectoryPayload(
        _ logicalFiles: [TorrentLogicalFile],
        topLevel: ReservedTopLevel,
        parentDescriptor: Int32,
        claimID: UUID,
        claimGeneration: UInt64,
        ownershipKey: Data,
        created: inout [CreatedObject]
    ) throws -> [TorrentPhysicalFileMapping] {
        defer {
            _ = Darwin.close(topLevel.descriptor)
        }
        var directoryIdentities = [String: TorrentFilesystemIdentity]()
        directoryIdentities[""] = topLevel.identity
        var mappings = [TorrentPhysicalFileMapping]()
        mappings.reserveCapacity(logicalFiles.count)

        for logicalFile in logicalFiles {
            if logicalFile.isPadding {
                mappings.append(TorrentPhysicalFileMapping(
                    fileIndex: logicalFile.index,
                    relativePathComponents: nil,
                    identity: nil
                ))
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
            let fileDescriptor = unsafe leaf.withCString { pointer in
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

            mappings.append(TorrentPhysicalFileMapping(
                fileIndex: logicalFile.index,
                relativePathComponents: relativeComponents,
                identity: identity
            ))
        }
        return mappings
    }

    private func prepareDirectories(
        _ components: [String],
        topLevelDescriptor: Int32,
        topLevelName: String,
        claimID: UUID,
        claimGeneration: UInt64,
        ownershipKey: Data,
        identities: inout [String: TorrentFilesystemIdentity],
        created: inout [CreatedObject]
    ) throws -> Int32 {
        guard !components.isEmpty else {
            return topLevelDescriptor
        }
        var current = Darwin.dup(topLevelDescriptor)
        guard current >= 0 else {
            throw TorrentStoragePlanningError.reservationFailed
        }
        var traversed = [String]()
        do {
            for component in components {
                traversed.append(component)
                let key = traversed.joined(separator: "\0")
                let status = unsafe component.withCString { pointer in
                    unsafe Darwin.mkdirat(current, pointer, mode_t(0o700))
                }
                if status == 0 {
                    let next = try openDirectory(named: component, relativeTo: current)
                    do {
                        let identity = try validateDirectoryDescriptor(next)
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
                            descriptor: next
                        )
                        identities[key] = identity
                    } catch {
                        _ = Darwin.close(next)
                        throw error
                    }
                    _ = Darwin.close(current)
                    current = next
                    continue
                }
                guard errno == EEXIST,
                      let expected = identities[key] else {
                    throw TorrentStoragePlanningError.filesystemObjectChanged
                }
                let next = try openDirectory(named: component, relativeTo: current)
                let actual = try validateDirectoryDescriptor(next)
                guard actual.refersToSameObject(as: expected) else {
                    _ = Darwin.close(next)
                    throw TorrentStoragePlanningError.filesystemObjectChanged
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

    private func inspectExistingPayload(
        manifest logicalManifest: TorrentLogicalManifest,
        in parent: TorrentStorageParentAuthority,
        topLevelName: String
    ) throws -> (
        topLevelIdentity: TorrentFilesystemIdentity,
        mappings: [TorrentPhysicalFileMapping]
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
            return (
                identity,
                [TorrentPhysicalFileMapping(
                    fileIndex: logicalFile.index,
                    relativePathComponents: [topLevelName],
                    identity: identity
                )]
            )
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
            let topLevelIdentity = try validateDirectoryDescriptor(
                topLevelDescriptor
            )
            let mappings = try logicalManifest.files.map { logicalFile in
                guard !logicalFile.isPadding else {
                    return TorrentPhysicalFileMapping(
                        fileIndex: logicalFile.index,
                        relativePathComponents: nil,
                        identity: nil
                    )
                }
                let identity = try inspectImportedPayload(
                    logicalFile.pathComponents,
                    startingAt: topLevelDescriptor,
                    maximumSize: logicalFile.expectedSize
                )
                return TorrentPhysicalFileMapping(
                    fileIndex: logicalFile.index,
                    relativePathComponents:
                        [topLevelName] + logicalFile.pathComponents,
                    identity: identity
                )
            }
            return (topLevelIdentity, mappings)
        }
    }

    private func inspectImportedPayload(
        _ components: [String],
        startingAt rootDescriptor: Int32,
        maximumSize: Int64
    ) throws -> TorrentFilesystemIdentity {
        guard !components.isEmpty,
              components.allSatisfy(isSafeImportedComponent) else {
            throw TorrentStoragePlanningError.existingDataUnsafe
        }
        var current = Darwin.dup(rootDescriptor)
        guard current >= 0 else {
            throw TorrentStoragePlanningError.existingDataUnavailable
        }
        do {
            for component in components.dropLast() {
                let next: Int32
                do {
                    next = try openDirectory(
                        named: component,
                        relativeTo: current
                    )
                    _ = try validateDirectoryDescriptor(next)
                } catch {
                    throw TorrentStoragePlanningError.existingDataUnavailable
                }
                _ = Darwin.close(current)
                current = next
            }
            guard let leaf = components.last else {
                throw TorrentStoragePlanningError.existingDataUnsafe
            }
            let payload = try openImportedPayload(
                named: leaf,
                relativeTo: current
            )
            defer { _ = Darwin.close(payload) }
            let identity = try validateImportedPayloadDescriptor(
                payload,
                maximumSize: maximumSize
            )
            _ = Darwin.close(current)
            return identity
        } catch {
            _ = Darwin.close(current)
            throw error
        }
    }

    private func openImportedPayload(
        named name: String,
        relativeTo descriptor: Int32
    ) throws -> Int32 {
        let opened = unsafe name.withCString { pointer in
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

    private func isSafeImportedComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.utf8.contains(0)
            && !component.contains("/")
            && !component.contains("\\")
    }

    private func openDirectory(named name: String, relativeTo descriptor: Int32) throws -> Int32 {
        let opened = unsafe name.withCString { pointer in
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
        let status = unsafe tag.withUnsafeBytes { bytes in
            unsafe Self.ownershipAttribute.withCString { name in
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
        let result = unsafe tag.withUnsafeMutableBytes { bytes in
            unsafe Self.ownershipAttribute.withCString { name in
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
            _ = Darwin.close(quarantine.descriptor)
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
            let status = unsafe captureName.withCString { pointer in
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
        let descriptor = unsafe leaf.withCString { pointer in
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
        let status = unsafe leaf.withCString { pointer in
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
