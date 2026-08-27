import CryptoKit
import Darwin
import Foundation
import TorrentMetainfo
import TorrentStorageAuthority

private struct StorageAuthorityByteCursor {
    private let bytes: Data
    private var offset = 0

    init(_ bytes: Data) {
        self.bytes = bytes
    }

    mutating func byte() -> UInt8 {
        guard offset < bytes.count else {
            return 0
        }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint64() -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 56, by: 8) {
            value |= UInt64(byte()) << UInt64(shift)
        }
        return value
    }
}

private enum StorageClaimFuzzer {
    private static let claimID = UUID(
        uuidString: "A1020304-0506-4708-890A-0B0C0D0E0F10"
    )!
    private static let operationNonce = UUID(
        uuidString: "B1020304-0506-4708-890A-0B0C0D0E0F10"
    )!

    static func exercise(_ data: Data) {
        var cursor = StorageAuthorityByteCursor(data)
        let validDirectory = makeDirectoryClaim(mutation: nil)
        fuzzAssert(TorrentStorageClaimValidation.isValid(validDirectory))

        switch cursor.byte() % 7 {
        case 0:
            exerciseCodableRoundTrip(validDirectory)
        case 1:
            let validSingle = makeSingleFileClaim()
            fuzzAssert(TorrentStorageClaimValidation.isValid(validSingle))
        case 2:
            exerciseValidLifecycleState(validDirectory, selector: cursor.byte())
        case 3:
            exerciseOwnershipTag(cursor: &cursor)
        case 4:
            exercisePathPredicate(data)
        case 5:
            exerciseDecodedClaim(Data(data.dropFirst()))
        default:
            exerciseMutatedJSON(validDirectory, cursor: &cursor)
        }

        let mutation = Int(cursor.byte() % 36)
        let invalid = makeDirectoryClaim(mutation: mutation)
        fuzzAssert(!TorrentStorageClaimValidation.isValid(invalid))
    }

    private static func makeDirectoryClaim(mutation: Int?) -> TorrentStorageClaim {
        let owner = geteuid()
        let differentOwner = owner ^ 1
        var generation: UInt64 = 7
        var sourceDigest = Data(repeating: 0x31, count: SHA256.byteCount)
        var parentID = TorrentStorageParentID(identity: identity(
            device: 11,
            inode: 12,
            owner: owner
        ))
        var contentKind = TorrentStorageContentKind.directory
        var logicalFiles = [
            TorrentLogicalFile(
                index: 0,
                pathComponents: ["alpha", "a.bin"],
                expectedSize: 17,
                isPadding: false
            ),
            TorrentLogicalFile(
                index: 1,
                pathComponents: ["padding", "16"],
                expectedSize: 16,
                isPadding: true
            ),
            TorrentLogicalFile(
                index: 2,
                pathComponents: ["zeta", "b.bin"],
                expectedSize: 23,
                isPadding: false
            ),
        ]
        var fileIdentities: [TorrentFilesystemIdentity?] = [
            identity(device: 21, inode: 22, owner: owner),
            nil,
            identity(device: 23, inode: 24, owner: owner),
        ]
        var directoryIdentities = [
            TorrentPhysicalDirectoryIdentity(
                relativePathComponents: [],
                identity: identity(device: 31, inode: 32, owner: owner)
            ),
            TorrentPhysicalDirectoryIdentity(
                relativePathComponents: ["alpha"],
                identity: identity(device: 31, inode: 33, owner: owner)
            ),
            TorrentPhysicalDirectoryIdentity(
                relativePathComponents: ["zeta"],
                identity: identity(device: 31, inode: 34, owner: owner)
            ),
        ]
        var topLevelName = "Payload"
        var ownership = TorrentStorageOwnership.appCreated(
            key: Data(repeating: 0x52, count: TorrentStorageOwnershipTag.keyByteCount)
        )
        var lease = TorrentStorageLease(
            state: .active,
            availabilityRevision: 1,
            fileAvailability: [true, false, true]
        )
        var torrentID: String? = "v1:0123456789012345678901234567890123456789"
        var removalIntent: TorrentStorageRemovalIntent?
        var deletionEvidence: TorrentStorageDeletionEvidence?
        var corruptAuthorityDigest = false

        switch mutation {
        case nil:
            break
        case 0:
            generation = 0
        case 1:
            sourceDigest.removeLast()
        case 2:
            parentID = TorrentStorageParentID(identity: identity(
                device: 11,
                inode: 12,
                owner: differentOwner
            ))
        case 3:
            directoryIdentities[0] = TorrentPhysicalDirectoryIdentity(
                relativePathComponents: [],
                identity: identity(device: 31, inode: 32, owner: differentOwner)
            )
        case 4:
            logicalFiles[1] = TorrentLogicalFile(
                index: 0,
                pathComponents: ["padding", "16"],
                expectedSize: 16,
                isPadding: true
            )
        case 5:
            fileIdentities.removeLast()
        case 6:
            lease.availabilityRevision = 0
        case 7:
            lease.fileAvailability.removeLast()
        case 8:
            lease.fileAvailability[1] = true
        case 9:
            topLevelName = ".."
        case 10:
            ownership = .appCreated(
                key: Data(repeating: 0x52, count: TorrentStorageOwnershipTag.keyByteCount - 1)
            )
        case 11:
            logicalFiles[0] = TorrentLogicalFile(
                index: 0,
                pathComponents: ["alpha", "a.bin"],
                expectedSize: -1,
                isPadding: false
            )
        case 12:
            logicalFiles[0] = TorrentLogicalFile(
                index: 0,
                pathComponents: [],
                expectedSize: 17,
                isPadding: false
            )
        case 13:
            logicalFiles[0] = TorrentLogicalFile(
                index: 0,
                pathComponents: ["alpha", "../a.bin"],
                expectedSize: 17,
                isPadding: false
            )
        case 14:
            fileIdentities[1] = identity(device: 21, inode: 25, owner: owner)
        case 15:
            fileIdentities[0] = nil
        case 16:
            fileIdentities[0] = identity(
                device: 21,
                inode: 22,
                linkCount: 2,
                owner: owner
            )
        case 17:
            directoryIdentities.reverse()
        case 18:
            directoryIdentities.append(directoryIdentities[0])
        case 19:
            directoryIdentities.removeFirst()
        case 20:
            directoryIdentities.append(TorrentPhysicalDirectoryIdentity(
                relativePathComponents: ["unused"],
                identity: identity(device: 31, inode: 35, owner: owner)
            ))
        case 21:
            directoryIdentities[1] = TorrentPhysicalDirectoryIdentity(
                relativePathComponents: [".."],
                identity: identity(device: 31, inode: 33, owner: owner)
            )
        case 22:
            directoryIdentities[1] = TorrentPhysicalDirectoryIdentity(
                relativePathComponents: ["alpha"],
                identity: identity(device: 31, inode: 33, owner: differentOwner)
            )
        case 23:
            contentKind = .singleFile
        case 24:
            torrentID = nil
        case 25:
            removalIntent = .keepPayload
        case 26:
            deletionEvidence = evidence(owner: owner)
        case 27:
            lease.state = .removing
        case 28:
            lease.state = .deleting
            removalIntent = .keepPayload
        case 29:
            lease.state = .deleting
            removalIntent = .deletePayload
            deletionEvidence = TorrentStorageDeletionEvidence(
                operationNonce: UUID(
                    uuidString: "D1020304-0506-4708-890A-0B0C0D0E0F10"
                )!,
                quarantineIdentity: identity(device: 41, inode: 42, owner: owner),
                entriesIdentity: identity(device: 41, inode: 43, owner: owner)
            )
        case 30:
            lease.state = .deleting
            removalIntent = .deletePayload
            deletionEvidence = evidence(owner: differentOwner)
        case 31:
            corruptAuthorityDigest = true
        case 32:
            topLevelName = "Payload\\child"
        case 33:
            fileIdentities[2] = identity(
                device: 23,
                inode: 24,
                owner: differentOwner
            )
        case 34:
            logicalFiles[2] = TorrentLogicalFile(
                index: 2,
                pathComponents: ["alpha", "a.bin"],
                expectedSize: 23,
                isPadding: false
            )
        case 35:
            lease.state = .deletionPending
            removalIntent = nil
        default:
            Darwin.abort()
        }

        let hashes = try! TorrentStorageInfoHashes(
            v1: Data(repeating: 0x11, count: Insecure.SHA1.byteCount),
            v2: Data(repeating: 0x22, count: SHA256.byteCount)
        )
        var authorityDigest = TorrentManifestDigest.authority(
            claimID: claimID,
            generation: generation,
            infoHashes: hashes,
            sourceManifestDigest: sourceDigest,
            parentID: parentID,
            contentKind: contentKind,
            logicalFiles: logicalFiles,
            topLevelName: topLevelName,
            fileIdentities: fileIdentities,
            directoryIdentities: directoryIdentities,
            ownership: ownership
        )
        if corruptAuthorityDigest {
            authorityDigest[0] ^= 1
        }
        let manifest = TorrentStorageManifest(
            claimID: claimID,
            generation: generation,
            infoHashes: hashes,
            sourceManifestDigest: sourceDigest,
            parentID: parentID,
            contentKind: contentKind,
            logicalFiles: logicalFiles,
            physicalFileIdentities: fileIdentities,
            physicalDirectoryIdentities: directoryIdentities,
            collisionSelectedTopLevelName: topLevelName,
            authorityDigest: authorityDigest,
            ownership: ownership
        )
        return TorrentStorageClaim(
            manifest: manifest,
            lease: lease,
            torrentID: torrentID,
            operationNonce: operationNonce,
            removalIntent: removalIntent,
            deletionEvidence: deletionEvidence
        )
    }

    private static func makeSingleFileClaim() -> TorrentStorageClaim {
        let owner = geteuid()
        let hashes = try! TorrentStorageInfoHashes(
            v1: Data(repeating: 0x61, count: Insecure.SHA1.byteCount),
            v2: nil
        )
        let files = [TorrentLogicalFile(
            index: 0,
            pathComponents: ["single.iso"],
            expectedSize: 47,
            isPadding: false
        )]
        let fileIdentities: [TorrentFilesystemIdentity?] = [
            identity(device: 51, inode: 52, owner: owner),
        ]
        let parent = TorrentStorageParentID(identity: identity(
            device: 53,
            inode: 54,
            owner: owner
        ))
        let sourceDigest = Data(repeating: 0x62, count: SHA256.byteCount)
        let manifest = TorrentStorageManifest(
            claimID: UUID(uuidString: "C1020304-0506-4708-890A-0B0C0D0E0F10")!,
            generation: 3,
            infoHashes: hashes,
            sourceManifestDigest: sourceDigest,
            parentID: parent,
            contentKind: .singleFile,
            logicalFiles: files,
            physicalFileIdentities: fileIdentities,
            physicalDirectoryIdentities: [],
            collisionSelectedTopLevelName: "single.iso",
            authorityDigest: TorrentManifestDigest.authority(
                claimID: UUID(uuidString: "C1020304-0506-4708-890A-0B0C0D0E0F10")!,
                generation: 3,
                infoHashes: hashes,
                sourceManifestDigest: sourceDigest,
                parentID: parent,
                contentKind: .singleFile,
                logicalFiles: files,
                topLevelName: "single.iso",
                fileIdentities: fileIdentities,
                directoryIdentities: [],
                ownership: .imported
            ),
            ownership: .imported
        )
        return TorrentStorageClaim(
            manifest: manifest,
            lease: TorrentStorageLease(
                state: .active,
                availabilityRevision: 1,
                fileAvailability: [true]
            ),
            torrentID: "v1:abcdefabcdefabcdefabcdefabcdefabcdefabcd",
            operationNonce: operationNonce,
            removalIntent: nil,
            deletionEvidence: nil
        )
    }

    private static func exerciseValidLifecycleState(
        _ source: TorrentStorageClaim,
        selector: UInt8
    ) {
        let states: [TorrentStorageClaimState] = [
            .reserved, .activating, .active, .activationUnknown,
            .removing, .deleting, .deletionPending, .orphaned,
        ]
        let state = states[Int(selector) % states.count]
        var lease = source.lease
        lease.state = state
        let torrentID = state == .active ? source.torrentID : nil
        let intent: TorrentStorageRemovalIntent? = switch state {
        case .removing: .keepPayload
        case .deleting, .deletionPending: .deletePayload
        default: nil
        }
        let claim = TorrentStorageClaim(
            manifest: source.manifest,
            lease: lease,
            torrentID: torrentID,
            operationNonce: source.operationNonce,
            removalIntent: intent,
            deletionEvidence: nil
        )
        fuzzAssert(TorrentStorageClaimValidation.isValid(claim))
    }

    private static func exerciseOwnershipTag(
        cursor: inout StorageAuthorityByteCursor
    ) {
        let key = Data(repeating: 0x71, count: TorrentStorageOwnershipTag.keyByteCount)
        let path = ["Payload", "alpha", "a.bin"]
        let objectIdentity = identity(
            device: 101,
            inode: 102,
            owner: geteuid()
        )
        let tag = TorrentStorageOwnershipTag.authenticationCode(
            key: key,
            claimID: claimID,
            claimGeneration: 7,
            relativePathComponents: path,
            identity: objectIdentity,
            isDirectory: false
        )!
        fuzzAssert(TorrentStorageOwnershipTag.isValid(
            tag,
            key: key,
            claimID: claimID,
            claimGeneration: 7,
            relativePathComponents: path,
            identity: objectIdentity,
            isDirectory: false
        ))

        var changedTag = tag
        var changedKey = key
        var changedClaimID = claimID
        var changedGeneration: UInt64 = 7
        var changedPath = path
        var changedIdentity = objectIdentity
        var changedDirectory = false
        switch cursor.byte() % 7 {
        case 0: changedTag[0] ^= 1
        case 1: changedKey[0] ^= 1
        case 2: changedClaimID = operationNonce
        case 3: changedGeneration = 8
        case 4: changedPath.append("child")
        case 5:
            changedIdentity = identity(
                device: objectIdentity.device,
                inode: objectIdentity.inode + 1,
                owner: objectIdentity.ownerUserID
            )
        default: changedDirectory = true
        }
        fuzzAssert(!TorrentStorageOwnershipTag.isValid(
            changedTag,
            key: changedKey,
            claimID: changedClaimID,
            claimGeneration: changedGeneration,
            relativePathComponents: changedPath,
            identity: changedIdentity,
            isDirectory: changedDirectory
        ))
    }

    private static func exercisePathPredicate(_ data: Data) {
        let component = String(
            decoding: data.prefix(4_096),
            as: UTF8.self
        )
        guard TorrentStoragePathComponent.isSafe(component) else {
            return
        }
        fuzzAssert(!component.isEmpty)
        fuzzAssert(component != "." && component != "..")
        fuzzAssert(!component.utf8.contains(0))
        fuzzAssert(!component.contains("/") && !component.contains("\\"))
    }

    private static func exerciseDecodedClaim(_ data: Data) {
        guard let claim = try? JSONDecoder().decode(
            TorrentStorageClaim.self,
            from: data
        ), TorrentStorageClaimValidation.isValid(claim) else {
            return
        }
        exerciseCodableRoundTrip(claim)
    }

    private static func exerciseMutatedJSON(
        _ claim: TorrentStorageClaim,
        cursor: inout StorageAuthorityByteCursor
    ) {
        var encoded = try! JSONEncoder().encode(claim)
        guard !encoded.isEmpty else {
            Darwin.abort()
        }
        let mutationCount = 1 + Int(cursor.byte() % 16)
        for _ in 0..<mutationCount {
            let index = Int(cursor.uint64() % UInt64(encoded.count))
            encoded[index] ^= cursor.byte() | 1
        }
        guard let decoded = try? JSONDecoder().decode(
            TorrentStorageClaim.self,
            from: encoded
        ), TorrentStorageClaimValidation.isValid(decoded) else {
            return
        }
        exerciseCodableRoundTrip(decoded)
    }

    private static func exerciseCodableRoundTrip(_ claim: TorrentStorageClaim) {
        let encoded = try! JSONEncoder().encode(claim)
        let decoded = try! JSONDecoder().decode(TorrentStorageClaim.self, from: encoded)
        fuzzAssert(decoded == claim)
        fuzzAssert(TorrentStorageClaimValidation.isValid(decoded))
    }

    private static func evidence(owner: UInt32) -> TorrentStorageDeletionEvidence {
        TorrentStorageDeletionEvidence(
            operationNonce: operationNonce,
            quarantineIdentity: identity(device: 41, inode: 42, owner: owner),
            entriesIdentity: identity(device: 41, inode: 43, owner: owner)
        )
    }

    private static func identity(
        device: UInt64,
        inode: UInt64,
        linkCount: UInt64 = 1,
        owner: UInt32
    ) -> TorrentFilesystemIdentity {
        TorrentFilesystemIdentity(
            device: device,
            inode: inode,
            linkCount: linkCount,
            ownerUserID: owner,
            fileGeneration: 1
        )
    }
}

private enum StorageManifestFuzzer {
    static func exercise(_ data: Data) {
        exerciseCandidate(data)
        if data.last == UInt8(ascii: "\n") {
            exerciseCandidate(Data(data.dropLast()))
        }
    }

    private static func exerciseCandidate(_ data: Data) {
        let standardParser = TorrentManifestParser()
        let standard = try? standardParser.parse(data)
        if let standard {
            verify(standard, metadata: data, parser: standardParser)
        }

        var cursor = StorageAuthorityByteCursor(data)
        var limits = TorrentManifestParser.Limits.standard
        limits.maximumMetadataBytes = 1 + Int(
            cursor.uint64() % UInt64(max(1, data.count + 1_024))
        )
        limits.maximumNestingDepth = Int(cursor.byte() % 33)
        limits.maximumValueCount = 1 + Int(cursor.uint64() % 20_000)
        limits.maximumStringBytes = 1 + Int(cursor.uint64() % 1_048_576)
        limits.maximumContainerCount = 1 + Int(cursor.uint64() % 20_000)
        limits.maximumDictionaryKeyBytes = 1 + Int(cursor.uint64() % 1_048_576)
        limits.maximumIntegerDigits = 1 + Int(cursor.byte() % 19)
        limits.maximumStringLengthDigits = 1 + Int(cursor.byte() % 19)
        limits.maximumPathComponentBytes = 1 + Int(cursor.byte() % 255)
        limits.maximumPathDepth = 1 + Int(cursor.byte() % 32)
        limits.maximumFileCount = 1 + Int(cursor.uint64() % 20_000)
        limits.maximumTrackerTierCount = 1 + Int(cursor.uint64() % 256)
        limits.maximumAggregateSourceBytes = 1 + Int(cursor.uint64() % 1_048_576)
        limits.maximumPathComponentCount = 1 + Int(cursor.uint64() % 200_000)
        limits.maximumPathBytes = 1 + Int(cursor.uint64() % 1_048_576)
        limits.maximumFileBytes = 1 + Int64(
            cursor.uint64() % UInt64(TorrentMetainfoParser.Limits.nativeMaximumFileBytes)
        )
        limits.maximumPayloadBytes = 1 + Int64(
            cursor.uint64() % UInt64(TorrentMetainfoParser.Limits.nativeMaximumPayloadBytes)
        )
        limits.maximumPieceCount = 1 + Int(cursor.uint64() % 100_000)
        limits.maximumV1PieceHashBytes = 1 + Int(cursor.uint64() % 1_048_576)
        limits.maximumPieceLayerHashCount = 1 + Int(cursor.uint64() % 100_000)
        limits.maximumPieceLayerBytes = 1 + Int(cursor.uint64() % 1_048_576)
        limits.maximumCommentBytes = 1 + Int(cursor.uint64() % 16_384)
        limits.maximumCreatorBytes = 1 + Int(cursor.uint64() % 4_096)
        limits.maximumHumanReadableBytes = 1 + Int(cursor.uint64() % 20_480)
        let boundedParser = TorrentManifestParser(limits: limits)
        if let bounded = try? boundedParser.parse(data) {
            guard let standard else {
                Darwin.abort()
            }
            fuzzAssert(equivalent(bounded, standard))
            verify(bounded, metadata: data, parser: boundedParser)
        }
    }

    private static func verify(
        _ parsed: ParsedTorrentManifest,
        metadata: Data,
        parser: TorrentManifestParser
    ) {
        let manifest = parsed.manifest
        let core = parsed.infoCore
        fuzzAssert(parsed.metadata == metadata)
        fuzzAssert(!parsed.rawInfoDictionary.isEmpty)
        fuzzAssert(core.infoDictionaryRange.range.upperBound <= metadata.count)
        fuzzAssert(Data(metadata[core.infoDictionaryRange.range]) == parsed.rawInfoDictionary)
        fuzzAssert(core.effectiveName == manifest.name)
        fuzzAssert(core.pieceLength == manifest.pieceLength)
        fuzzAssert(core.v1InfoHash == manifest.infoHashes.v1)
        fuzzAssert(core.v2InfoHash == manifest.infoHashes.v2)
        fuzzAssert(core.files.map(\.index) == manifest.files.map(\.index))
        fuzzAssert(core.files.map(\.pathComponents) == manifest.files.map(\.pathComponents))
        fuzzAssert(core.files.map(\.expectedSize) == manifest.files.map(\.expectedSize))
        fuzzAssert(core.files.map(\.isPadding) == manifest.files.map(\.isPadding))
        fuzzAssert(manifest.files.map(\.index) == manifest.files.indices.map(Int32.init))
        fuzzAssert(manifest.files.allSatisfy {
            $0.expectedSize >= 0
                && !$0.pathComponents.isEmpty
                && $0.pathComponents.allSatisfy(TorrentStoragePathComponent.isSafe)
        })
        fuzzAssert(manifest.pieceLength > 0)
        fuzzAssert(TorrentManifestDigest.source(
            name: manifest.name,
            contentKind: manifest.contentKind,
            infoHashes: manifest.infoHashes,
            pieceLength: manifest.pieceLength,
            files: manifest.files
        ) == manifest.sourceManifestDigest)
        if let v1 = manifest.infoHashes.v1 {
            fuzzAssert(Data(Insecure.SHA1.hash(data: parsed.rawInfoDictionary)) == v1)
            guard let pieces = core.v1PieceHashesRange else {
                Darwin.abort()
            }
            fuzzAssert(pieces.range.upperBound <= metadata.count)
            fuzzAssert(pieces.range.count.isMultiple(of: Insecure.SHA1.byteCount))
        } else {
            fuzzAssert(core.v1PieceHashesRange == nil)
        }
        if let v2 = manifest.infoHashes.v2 {
            fuzzAssert(Data(SHA256.hash(data: parsed.rawInfoDictionary)) == v2)
        }
        for file in core.files {
            if let root = file.piecesRootRange {
                fuzzAssert(root.range.upperBound <= metadata.count)
                fuzzAssert(root.range.count == SHA256.byteCount)
            }
        }
        for layer in parsed.envelope.pieceLayers {
            fuzzAssert(layer.piecesRootRange.range.upperBound <= metadata.count)
            fuzzAssert(layer.piecesRootRange.range.count == SHA256.byteCount)
            fuzzAssert(layer.hashesRange.range.upperBound <= metadata.count)
            fuzzAssert(layer.hashesRange.range.count.isMultiple(of: SHA256.byteCount))
            fuzzAssert(layer.fileIndices.allSatisfy {
                $0 >= 0 && Int($0) < core.files.count && !core.files[Int($0)].isPadding
            })
        }
        fuzzAssert(parsed.envelope.pieceLayers.isEmpty
            || parsed.envelope.presentFields.contains(.pieceLayers))
        fuzzAssert(parsed.envelope.hasIgnoredDHTNodesField
            == parsed.envelope.presentFields.contains(.dhtNodes))

        let advertised = try! TorrentAdvertisedInfoHashes(
            v1: manifest.infoHashes.v1,
            v2: manifest.infoHashes.v2
        )
        let bareInfo = Data(parsed.rawInfoDictionary)
        let bare = try! TorrentMetainfoParser().parseInfoDictionary(
            bareInfo,
            advertisedHashes: advertised
        )
        fuzzAssert(equivalentCore(
            core,
            bytes: metadata,
            bare.infoCore,
            bytes: bareInfo
        ))
        let reparsed = try! parser.parse(metadata, advertisedHashes: advertised)
        fuzzAssert(equivalent(parsed, reparsed))

        var wrongV1 = manifest.infoHashes.v1
        var wrongV2 = manifest.infoHashes.v2
        if wrongV1 != nil {
            wrongV1![0] ^= 1
        } else {
            wrongV2![0] ^= 1
        }
        let wrong = try! TorrentAdvertisedInfoHashes(v1: wrongV1, v2: wrongV2)
        do {
            _ = try parser.parse(metadata, advertisedHashes: wrong)
            Darwin.abort()
        } catch let error as TorrentManifestError {
            fuzzAssert(error == .advertisedInfoHashMismatch)
        } catch {
            Darwin.abort()
        }
    }

    private static func equivalent(
        _ left: ParsedTorrentManifest,
        _ right: ParsedTorrentManifest
    ) -> Bool {
        left.manifest == right.manifest
            && left.rawInfoDictionary == right.rawInfoDictionary
            && left.metadata == right.metadata
            && left.infoCore == right.infoCore
            && left.envelope == right.envelope
    }

    private static func equivalentCore(
        _ left: ValidatedInfoCore,
        bytes leftBytes: Data,
        _ right: ValidatedInfoCore,
        bytes rightBytes: Data
    ) -> Bool {
        guard left.kind == right.kind,
              left.wireName == right.wireName,
              left.effectiveName == right.effectiveName,
              left.contentKind == right.contentKind,
              left.v1InfoHash == right.v1InfoHash,
              left.v2InfoHash == right.v2InfoHash,
              left.pieceLength == right.pieceLength,
              left.totalSize == right.totalSize,
              left.isPrivate == right.isPrivate,
              left.files.count == right.files.count,
              rangedBytes(left.v1PieceHashesRange, in: leftBytes)
                == rangedBytes(right.v1PieceHashesRange, in: rightBytes) else {
            return false
        }
        return zip(left.files, right.files).allSatisfy { leftFile, rightFile in
            leftFile.index == rightFile.index
                && leftFile.pathComponents == rightFile.pathComponents
                && leftFile.expectedSize == rightFile.expectedSize
                && leftFile.isPadding == rightFile.isPadding
                && leftFile.isExecutable == rightFile.isExecutable
                && leftFile.isHidden == rightFile.isHidden
                && rangedBytes(leftFile.piecesRootRange, in: leftBytes)
                    == rangedBytes(rightFile.piecesRootRange, in: rightBytes)
        }
    }

    private static func rangedBytes(
        _ range: ValidatedMetainfoRange?,
        in bytes: Data
    ) -> Data? {
        range.map { Data(bytes[$0.range]) }
    }
}

private enum MagnetParserFuzzer {
    static func exercise(_ data: Data) {
        if let strict = String(data: data, encoding: .utf8) {
            exerciseCandidate(strict)
        }
        exerciseCandidate(String(decoding: data, as: UTF8.self))
    }

    private static func exerciseCandidate(_ candidate: String) {
        guard let parsed = try? ParsedMagnet.parse(candidate) else {
            return
        }
        fuzzAssert(parsed.v1InfoHash?.count == nil || parsed.v1InfoHash?.count == 20)
        fuzzAssert(parsed.v2InfoHash?.count == nil || parsed.v2InfoHash?.count == 32)
        fuzzAssert(parsed.v1InfoHash != nil || parsed.v2InfoHash != nil)
        fuzzAssert(parsed.trackers.count <= 2_000)
        fuzzAssert(parsed.webSeeds.count <= 2_000)
        if let selections = parsed.fileSelections {
            var previousLast: Int32?
            for selection in selections {
                fuzzAssert(selection.firstIndex >= 0)
                fuzzAssert(selection.firstIndex <= selection.lastIndex)
                fuzzAssert(selection.lastIndex < 20_000)
                fuzzAssert(previousLast.map { selection.firstIndex > $0 + 1 } ?? true)
                previousLast = selection.lastIndex
            }
        }

        guard let encoded = try? JSONEncoder().encode(parsed),
              let decoded = try? JSONDecoder().decode(ParsedMagnet.self, from: encoded) else {
            Darwin.abort()
        }
        fuzzAssert(decoded == parsed)
        fuzzAssert((try? ParsedMagnet.parse(candidate)) == parsed)
    }
}

private func fuzzData(
    _ bytes: UnsafePointer<UInt8>?,
    _ byteCount: UInt
) -> Data? {
    guard byteCount <= UInt(Int.max) else {
        return nil
    }
    let count = Int(byteCount)
    guard bytes != nil || count == 0 else {
        return nil
    }
    return bytes.map { Data(bytes: $0, count: count) } ?? Data()
}

private func fuzzAssert(_ condition: @autoclosure () -> Bool) {
    if !condition() {
        Darwin.abort()
    }
}

@_cdecl("TorrentStorageClaimFuzzOneInput")
public func torrentStorageClaimFuzzOneInput(
    _ bytes: UnsafePointer<UInt8>?,
    _ byteCount: UInt
) {
    guard let data = fuzzData(bytes, byteCount) else {
        return
    }
    autoreleasepool {
        StorageClaimFuzzer.exercise(data)
    }
}

@_cdecl("TorrentStorageManifestFuzzOneInput")
public func torrentStorageManifestFuzzOneInput(
    _ bytes: UnsafePointer<UInt8>?,
    _ byteCount: UInt
) {
    guard let data = fuzzData(bytes, byteCount) else {
        return
    }
    autoreleasepool {
        StorageManifestFuzzer.exercise(data)
    }
}

@_cdecl("TorrentMagnetParserFuzzOneInput")
public func torrentMagnetParserFuzzOneInput(
    _ bytes: UnsafePointer<UInt8>?,
    _ byteCount: UInt
) {
    guard let data = fuzzData(bytes, byteCount) else {
        return
    }
    autoreleasepool {
        MagnetParserFuzzer.exercise(data)
    }
}
