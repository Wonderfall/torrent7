import Darwin
import CryptoKit
import Foundation

enum TorrentStorageContentKind: String, Codable, Sendable {
    case singleFile
    case directory
}

struct TorrentStorageInfoHashes: Codable, Equatable, Sendable {
    let v1: Data?
    let v2: Data?

    init(v1: Data?, v2: Data?) throws {
        guard v1 == nil || v1?.count == Insecure.SHA1.byteCount,
              v2 == nil || v2?.count == SHA256.byteCount,
              v1 != nil || v2 != nil else {
            throw TorrentManifestError.invalidInfoHashes
        }
        self.v1 = v1
        self.v2 = v2
    }
}

struct TorrentLogicalFile: Codable, Equatable, Sendable {
    let index: Int32
    let pathComponents: [String]
    let expectedSize: Int64
    let isPadding: Bool
}

struct TorrentLogicalManifest: Codable, Equatable, Sendable {
    let name: String
    let contentKind: TorrentStorageContentKind
    let infoHashes: TorrentStorageInfoHashes
    let pieceLength: Int64
    let files: [TorrentLogicalFile]
    let sourceManifestDigest: Data

    var totalSize: Int64 {
        files.reduce(into: 0) { total, file in
            total += file.expectedSize
        }
    }
}

struct ParsedTorrentManifest: Sendable {
    let manifest: TorrentLogicalManifest
    let rawInfoDictionary: Data
}

struct TorrentFilesystemIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let linkCount: UInt64
    let ownerUserID: UInt32
    let fileGeneration: UInt32

    func refersToSameObject(as other: Self) -> Bool {
        device == other.device
            && inode == other.inode
            && ownerUserID == other.ownerUserID
            && fileGeneration == other.fileGeneration
    }
}

struct TorrentStorageParentID: Codable, Equatable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let ownerUserID: UInt32
    let fileGeneration: UInt32

    init(identity: TorrentFilesystemIdentity) {
        device = identity.device
        inode = identity.inode
        ownerUserID = identity.ownerUserID
        fileGeneration = identity.fileGeneration
    }
}

struct TorrentPhysicalDirectoryIdentity: Codable, Equatable, Sendable {
    /// Components relative to the torrent's top-level directory. The root is
    /// represented by an empty array.
    let relativePathComponents: [String]
    let identity: TorrentFilesystemIdentity
}

enum TorrentStorageOwnership: Codable, Equatable, Sendable {
    case appCreated(key: Data)
    case imported

    var ownershipKey: Data? {
        guard case .appCreated(let key) = self else {
            return nil
        }
        return key
    }
}

struct TorrentStorageManifest: Codable, Equatable, Sendable {
    let claimID: UUID
    let generation: UInt64
    let infoHashes: TorrentStorageInfoHashes
    let sourceManifestDigest: Data
    let parentID: TorrentStorageParentID
    let contentKind: TorrentStorageContentKind
    let logicalFiles: [TorrentLogicalFile]
    /// Canonically indexed with `logicalFiles`. Padding files have no identity
    /// and can never receive an FD.
    let physicalFileIdentities: [TorrentFilesystemIdentity?]
    /// Canonically ordered by depth and then lexicographically. Directory
    /// torrents include their top-level root as the empty relative path.
    let physicalDirectoryIdentities: [TorrentPhysicalDirectoryIdentity]
    let collisionSelectedTopLevelName: String
    let authorityDigest: Data
    let ownership: TorrentStorageOwnership

    var topLevelIdentity: TorrentFilesystemIdentity? {
        switch contentKind {
        case .singleFile:
            physicalFileIdentities.first.flatMap { $0 }
        case .directory:
            physicalDirectoryIdentities.first(where: {
                $0.relativePathComponents.isEmpty
            })?.identity
        }
    }

    func relativePathComponents(forFileAt index: Int) -> [String]? {
        guard logicalFiles.indices.contains(index),
              physicalFileIdentities.indices.contains(index),
              !logicalFiles[index].isPadding,
              physicalFileIdentities[index] != nil else {
            return nil
        }
        switch contentKind {
        case .singleFile:
            return [collisionSelectedTopLevelName]
        case .directory:
            return [collisionSelectedTopLevelName]
                + logicalFiles[index].pathComponents
        }
    }
}

enum TorrentStorageOwnershipTag {
    static let keyByteCount = 32
    static let tagByteCount = SHA256.byteCount

    private static let domain = Data("Torrent7.StorageOwnership.v1".utf8)

    static func authenticationCode(
        key: Data,
        claimID: UUID,
        claimGeneration: UInt64,
        relativePathComponents: [String],
        identity: TorrentFilesystemIdentity,
        isDirectory: Bool
    ) -> Data? {
        guard key.count == keyByteCount else {
            return nil
        }
        return Data(HMAC<SHA256>.authenticationCode(
            for: authenticatedData(
                claimID: claimID,
                claimGeneration: claimGeneration,
                relativePathComponents: relativePathComponents,
                identity: identity,
                isDirectory: isDirectory
            ),
            using: SymmetricKey(data: key)
        ))
    }

    static func isValid(
        _ tag: Data,
        key: Data,
        claimID: UUID,
        claimGeneration: UInt64,
        relativePathComponents: [String],
        identity: TorrentFilesystemIdentity,
        isDirectory: Bool
    ) -> Bool {
        guard key.count == keyByteCount,
              tag.count == tagByteCount else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            tag,
            authenticating: authenticatedData(
                claimID: claimID,
                claimGeneration: claimGeneration,
                relativePathComponents: relativePathComponents,
                identity: identity,
                isDirectory: isDirectory
            ),
            using: SymmetricKey(data: key)
        )
    }

    private static func authenticatedData(
        claimID: UUID,
        claimGeneration: UInt64,
        relativePathComponents: [String],
        identity: TorrentFilesystemIdentity,
        isDirectory: Bool
    ) -> Data {
        var data = domain
        append(claimID.uuidString.lowercased(), to: &data)
        append(claimGeneration, to: &data)
        data.append(isDirectory ? 1 : 0)
        append(UInt64(relativePathComponents.count), to: &data)
        for component in relativePathComponents {
            append(component, to: &data)
        }
        append(identity.device, to: &data)
        append(identity.inode, to: &data)
        append(UInt64(identity.ownerUserID), to: &data)
        append(UInt64(identity.fileGeneration), to: &data)
        return data
    }

    private static func append(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        append(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 56))
        data.append(UInt8(truncatingIfNeeded: value >> 48))
        data.append(UInt8(truncatingIfNeeded: value >> 40))
        data.append(UInt8(truncatingIfNeeded: value >> 32))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }
}

enum TorrentStorageClaimState: String, Codable, Sendable {
    case reserved
    case activating
    case active
    case activationUnknown
    case removing
    case deleting
    case deletionPending
    case orphaned
}

struct TorrentStorageLease: Codable, Equatable, Sendable {
    var state: TorrentStorageClaimState
    var availabilityRevision: UInt64
    var fileAvailability: [Bool]
}

enum TorrentStorageRemovalIntent: String, Codable, Sendable {
    case keepPayload
    case deletePayload
}

struct TorrentStorageDeletionEvidence: Codable, Equatable, Sendable {
    let operationNonce: UUID
    let quarantineIdentity: TorrentFilesystemIdentity
    let entriesIdentity: TorrentFilesystemIdentity
}

struct TorrentStorageClaim: Codable, Equatable, Sendable {
    let manifest: TorrentStorageManifest
    var lease: TorrentStorageLease
    var torrentID: String?
    var operationNonce: UUID
    var removalIntent: TorrentStorageRemovalIntent?
    var deletionEvidence: TorrentStorageDeletionEvidence?
}

enum TorrentStorageLeaseValidation {
    static func isValid(
        logicalFiles: [TorrentLogicalFile],
        fileAvailability: [Bool]
    ) -> Bool {
        guard fileAvailability.count == logicalFiles.count else {
            return false
        }
        return zip(logicalFiles, fileAvailability).allSatisfy {
            logicalFile, isAvailable in !logicalFile.isPadding || !isAvailable
        }
    }
}

enum TorrentStoragePathComponent {
    static func isSafe(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.utf8.contains(0)
            && !component.contains("/")
            && !component.contains("\\")
    }
}

enum TorrentStorageClaimValidation {
    static func isValid(
        _ claim: TorrentStorageClaim,
        ownerUserID: UInt32 = geteuid()
    ) -> Bool {
        let manifest = claim.manifest
        guard manifest.logicalFiles.count <= Int(Int32.max) else {
            return false
        }
        let expectedIndices = manifest.logicalFiles.indices.map(Int32.init)
        guard manifest.generation > 0,
              manifest.infoHashes.v1.map({ $0.count == Insecure.SHA1.byteCount })
                ?? true,
              manifest.infoHashes.v2.map({ $0.count == SHA256.byteCount })
                ?? true,
              manifest.infoHashes.v1 != nil || manifest.infoHashes.v2 != nil,
              manifest.sourceManifestDigest.count == SHA256.byteCount,
              manifest.authorityDigest.count == SHA256.byteCount,
              !manifest.logicalFiles.isEmpty,
              manifest.parentID.ownerUserID == ownerUserID,
              manifest.topLevelIdentity?.ownerUserID == ownerUserID,
              manifest.logicalFiles.map(\.index) == expectedIndices,
              manifest.physicalFileIdentities.count
                == manifest.logicalFiles.count,
              claim.lease.availabilityRevision > 0,
              TorrentStorageLeaseValidation.isValid(
                  logicalFiles: manifest.logicalFiles,
                  fileAvailability: claim.lease.fileAvailability
              ),
              TorrentStoragePathComponent.isSafe(
                  manifest.collisionSelectedTopLevelName
              ),
              hasValidOwnership(manifest.ownership),
              TorrentManifestDigest.authority(
                  claimID: manifest.claimID,
                  generation: manifest.generation,
                  infoHashes: manifest.infoHashes,
                  sourceManifestDigest: manifest.sourceManifestDigest,
                  parentID: manifest.parentID,
                  contentKind: manifest.contentKind,
                  logicalFiles: manifest.logicalFiles,
                  topLevelName: manifest.collisionSelectedTopLevelName,
                  fileIdentities: manifest.physicalFileIdentities,
                  directoryIdentities: manifest.physicalDirectoryIdentities,
                  ownership: manifest.ownership
              ) == manifest.authorityDigest else {
            return false
        }

        guard zip(
            manifest.logicalFiles,
            manifest.physicalFileIdentities
        ).allSatisfy({ logicalFile, fileIdentity in
            logicalFile.expectedSize >= 0
                && !logicalFile.pathComponents.isEmpty
                && logicalFile.pathComponents.allSatisfy(
                    TorrentStoragePathComponent.isSafe
                )
                && logicalFile.isPadding == (fileIdentity == nil)
                && (fileIdentity.map({
                    $0.ownerUserID == ownerUserID && $0.linkCount == 1
                }) ?? true)
        }) else {
            return false
        }

        let directoryPaths = manifest.physicalDirectoryIdentities.map(
            \.relativePathComponents
        )
        let canonicalDirectoryPaths = directoryPaths.sorted { left, right in
            if left.count != right.count {
                return left.count < right.count
            }
            return left.lexicographicallyPrecedes(right)
        }
        guard directoryPaths == canonicalDirectoryPaths,
              Set(directoryPaths).count == directoryPaths.count,
              manifest.physicalDirectoryIdentities.allSatisfy({ directory in
                  directory.relativePathComponents.allSatisfy(
                      TorrentStoragePathComponent.isSafe
                  )
                      && directory.identity.ownerUserID == ownerUserID
              }) else {
            return false
        }

        switch manifest.contentKind {
        case .singleFile:
            guard manifest.logicalFiles.count == 1,
                  manifest.logicalFiles[0].pathComponents.count == 1,
                  !manifest.logicalFiles[0].isPadding,
                  manifest.physicalDirectoryIdentities.isEmpty else {
                return false
            }
        case .directory:
            var expectedDirectoryPaths: Set<[String]> = [[]]
            for logicalFile in manifest.logicalFiles
            where !logicalFile.isPadding {
                for depth in 1..<logicalFile.pathComponents.count {
                    expectedDirectoryPaths.insert(Array(
                        logicalFile.pathComponents.prefix(depth)
                    ))
                }
            }
            guard directoryPaths.first == [],
                  Set(directoryPaths) == expectedDirectoryPaths else {
                return false
            }
        }

        if let evidence = claim.deletionEvidence {
            guard evidence.operationNonce == claim.operationNonce,
                  evidence.quarantineIdentity.ownerUserID == ownerUserID,
                  evidence.entriesIdentity.ownerUserID == ownerUserID else {
                return false
            }
        }
        switch claim.lease.state {
        case .active:
            return claim.torrentID?.isEmpty == false
                && claim.removalIntent == nil
                && claim.deletionEvidence == nil
        case .reserved, .activating, .activationUnknown:
            return claim.removalIntent == nil
                && claim.deletionEvidence == nil
        case .removing:
            return claim.removalIntent != nil
                && claim.deletionEvidence == nil
        case .deleting, .deletionPending:
            return claim.removalIntent == .deletePayload
        case .orphaned:
            return claim.deletionEvidence == nil
        }
    }

    private static func hasValidOwnership(
        _ ownership: TorrentStorageOwnership
    ) -> Bool {
        switch ownership {
        case .appCreated(let key):
            key.count == TorrentStorageOwnershipTag.keyByteCount
        case .imported:
            true
        }
    }
}

enum TorrentManifestDigest {
    private static let domain = Data("Torrent7 logical storage manifest\0v1".utf8)
    private static let authorityDomain = Data("Torrent7 physical claim authority\0v2".utf8)

    static func source(
        name: String,
        contentKind: TorrentStorageContentKind,
        infoHashes: TorrentStorageInfoHashes,
        pieceLength: Int64,
        files: [TorrentLogicalFile]
    ) -> Data {
        var input = domain
        append(name, to: &input)
        input.append(contentKind == .singleFile ? 0 : 1)
        appendOptional(infoHashes.v1, to: &input)
        appendOptional(infoHashes.v2, to: &input)
        append(UInt64(bitPattern: pieceLength), to: &input)
        append(UInt64(files.count), to: &input)
        for file in files {
            append(UInt64(bitPattern: Int64(file.index)), to: &input)
            append(UInt64(file.pathComponents.count), to: &input)
            for component in file.pathComponents {
                append(component, to: &input)
            }
            append(UInt64(bitPattern: file.expectedSize), to: &input)
            input.append(file.isPadding ? 1 : 0)
        }
        return Data(SHA256.hash(data: input))
    }

    static func authority(
        claimID: UUID,
        generation: UInt64,
        infoHashes: TorrentStorageInfoHashes,
        sourceManifestDigest: Data,
        parentID: TorrentStorageParentID,
        contentKind: TorrentStorageContentKind,
        logicalFiles: [TorrentLogicalFile],
        topLevelName: String,
        fileIdentities: [TorrentFilesystemIdentity?],
        directoryIdentities: [TorrentPhysicalDirectoryIdentity],
        ownership: TorrentStorageOwnership
    ) -> Data {
        var input = authorityDomain
        append(claimID.uuidString.lowercased(), to: &input)
        append(generation, to: &input)
        appendOptional(infoHashes.v1, to: &input)
        appendOptional(infoHashes.v2, to: &input)
        append(UInt64(sourceManifestDigest.count), to: &input)
        input.append(sourceManifestDigest)
        append(parentID.device, to: &input)
        append(parentID.inode, to: &input)
        append(UInt64(parentID.ownerUserID), to: &input)
        append(UInt64(parentID.fileGeneration), to: &input)
        input.append(contentKind == .singleFile ? 0 : 1)
        append(UInt64(logicalFiles.count), to: &input)
        for file in logicalFiles {
            append(UInt64(bitPattern: Int64(file.index)), to: &input)
            append(UInt64(file.pathComponents.count), to: &input)
            for component in file.pathComponents {
                append(component, to: &input)
            }
            append(UInt64(bitPattern: file.expectedSize), to: &input)
            input.append(file.isPadding ? 1 : 0)
        }
        append(topLevelName, to: &input)
        input.append(ownership.ownershipKey == nil ? 0 : 1)
        append(UInt64(fileIdentities.count), to: &input)
        for identity in fileIdentities {
            guard let identity else {
                input.append(0)
                continue
            }
            input.append(1)
            append(identity, to: &input)
        }
        append(UInt64(directoryIdentities.count), to: &input)
        for directory in directoryIdentities {
            append(UInt64(directory.relativePathComponents.count), to: &input)
            for component in directory.relativePathComponents {
                append(component, to: &input)
            }
            append(directory.identity, to: &input)
        }
        return Data(SHA256.hash(data: input))
    }

    private static func append(
        _ identity: TorrentFilesystemIdentity,
        to data: inout Data
    ) {
        append(identity.device, to: &data)
        append(identity.inode, to: &data)
        append(identity.linkCount, to: &data)
        append(UInt64(identity.ownerUserID), to: &data)
        append(UInt64(identity.fileGeneration), to: &data)
    }

    private static func appendOptional(_ value: Data?, to data: inout Data) {
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        append(UInt64(value.count), to: &data)
        data.append(value)
    }

    private static func append(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        append(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 56))
        data.append(UInt8(truncatingIfNeeded: value >> 48))
        data.append(UInt8(truncatingIfNeeded: value >> 40))
        data.append(UInt8(truncatingIfNeeded: value >> 32))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }
}
