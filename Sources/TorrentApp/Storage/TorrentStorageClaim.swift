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

struct TorrentPhysicalFileMapping: Codable, Equatable, Sendable {
    let fileIndex: Int32
    /// Components relative to the parent-authority descriptor. Padding files
    /// deliberately have no physical mapping and can never receive an FD.
    let relativePathComponents: [String]?
    let identity: TorrentFilesystemIdentity?
}

struct TorrentStorageManifest: Codable, Equatable, Sendable {
    let claimID: UUID
    let generation: UInt64
    let infoHashes: TorrentStorageInfoHashes
    let sourceManifestDigest: Data
    let parentAuthorityID: UUID
    let contentKind: TorrentStorageContentKind
    let logicalFiles: [TorrentLogicalFile]
    let physicalMappings: [TorrentPhysicalFileMapping]
    let collisionSelectedTopLevelName: String
    let topLevelIdentity: TorrentFilesystemIdentity
    let claimMappingDigest: Data
    /// Secret HMAC key stored only in the GUI's protected journal. Payload
    /// xattrs contain object-bound authentication tags, never this key.
    let ownershipKey: Data
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

enum TorrentPayloadMaximumAccess: String, Codable, Sendable {
    case unavailable
    case verificationReadOnly
    case appOwnedWritable
    case explicitlyImportedWritable
}

enum TorrentPayloadProvenance: String, Codable, Sendable {
    case appCreated
    case imported
}

struct TorrentPayloadFilePolicy: Codable, Equatable, Sendable {
    let fileIndex: Int32
    var maximumAccess: TorrentPayloadMaximumAccess
    let provenance: TorrentPayloadProvenance
    let mayModify: Bool
    let mayDeleteAutomatically: Bool
}

enum TorrentStorageClaimState: String, Codable, Sendable {
    case preparing
    case reserved
    case activating
    case active
    case activationUnknown
    case removing
    case deleting
    case deleted
    case deletionPending
    case orphaned
}

struct TorrentStorageLease: Codable, Equatable, Sendable {
    var state: TorrentStorageClaimState
    var policyRevision: UInt64
    var filePolicies: [TorrentPayloadFilePolicy]
}

struct TorrentStorageClaim: Codable, Equatable, Sendable {
    let manifest: TorrentStorageManifest
    var lease: TorrentStorageLease
    var torrentID: String?
    var operationNonce: UUID
}

enum TorrentStoragePolicyValidation {
    static func isValid(
        logicalFiles: [TorrentLogicalFile],
        policies: [TorrentPayloadFilePolicy]
    ) -> Bool {
        guard policies.map(\.fileIndex) == logicalFiles.map(\.index) else {
            return false
        }
        return zip(logicalFiles, policies).allSatisfy { logicalFile, policy in
            if logicalFile.isPadding {
                return policy.maximumAccess == .unavailable
                    && !policy.mayModify
                    && !policy.mayDeleteAutomatically
            }

            switch policy.provenance {
            case .appCreated:
                return policy.mayModify
                    && policy.mayDeleteAutomatically
                    && (policy.maximumAccess == .appOwnedWritable
                        || policy.maximumAccess == .unavailable)
            case .imported:
                guard !policy.mayDeleteAutomatically else {
                    return false
                }
                if policy.mayModify {
                    return policy.maximumAccess == .explicitlyImportedWritable
                        || policy.maximumAccess == .unavailable
                }
                return policy.maximumAccess == .verificationReadOnly
                    || policy.maximumAccess == .unavailable
            }
        }
    }

    static func preservesAuthorityMetadata(
        existing: [TorrentPayloadFilePolicy],
        replacement: [TorrentPayloadFilePolicy]
    ) -> Bool {
        guard existing.count == replacement.count else {
            return false
        }
        return zip(existing, replacement).allSatisfy { current, proposed in
            current.fileIndex == proposed.fileIndex
                && current.provenance == proposed.provenance
                && current.mayModify == proposed.mayModify
                && current.mayDeleteAutomatically == proposed.mayDeleteAutomatically
        }
    }
}

enum TorrentManifestDigest {
    private static let domain = Data("Torrent7 logical storage manifest\0v1".utf8)
    private static let mappingDomain = Data("Torrent7 physical claim mapping\0v1".utf8)

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

    static func mapping(
        claimID: UUID,
        generation: UInt64,
        parentAuthorityID: UUID,
        topLevelName: String,
        mappings: [TorrentPhysicalFileMapping]
    ) -> Data {
        var input = mappingDomain
        append(claimID.uuidString.lowercased(), to: &input)
        append(generation, to: &input)
        append(parentAuthorityID.uuidString.lowercased(), to: &input)
        append(topLevelName, to: &input)
        append(UInt64(mappings.count), to: &input)
        for mapping in mappings {
            append(UInt64(bitPattern: Int64(mapping.fileIndex)), to: &input)
            guard let components = mapping.relativePathComponents,
                  let identity = mapping.identity else {
                input.append(0)
                continue
            }
            input.append(1)
            append(UInt64(components.count), to: &input)
            for component in components {
                append(component, to: &input)
            }
            append(identity.device, to: &input)
            append(identity.inode, to: &input)
            append(identity.linkCount, to: &input)
            append(UInt64(identity.ownerUserID), to: &input)
            append(UInt64(identity.fileGeneration), to: &input)
        }
        return Data(SHA256.hash(data: input))
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
