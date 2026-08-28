import Darwin
import CryptoKit
import Foundation
import System
import TorrentEngineModel
import TorrentMetainfo
import TorrentStorageAuthority

enum TorrentStorageJournalError: LocalizedError, Equatable, Sendable {
    case unavailable
    case corrupt
    case unsupportedVersion(UInt64)
    case capacityExceeded
    case claimAlreadyExists
    case unknownClaim
    case generationMismatch
    case invalidTransition
    case operationNonceMismatch
    case promotionAlreadyExists
    case unknownPromotion

    var errorDescription: String? {
        switch self {
        case .unavailable: "The storage claim journal is unavailable."
        case .corrupt: "The storage claim journal is corrupt and was preserved."
        case .unsupportedVersion:
            "The storage claim journal belongs to an incompatible app version."
        case .capacityExceeded: "The storage claim journal exceeds its safe capacity."
        case .claimAlreadyExists: "The storage claim already exists."
        case .unknownClaim: "The storage claim is unavailable."
        case .generationMismatch: "The storage claim generation changed."
        case .invalidTransition: "The storage claim state transition is invalid."
        case .operationNonceMismatch: "The storage claim operation does not match the active transaction."
        case .promotionAlreadyExists: "The magnet promotion already exists."
        case .unknownPromotion: "The magnet promotion is unavailable."
        }
    }
}

struct TorrentStoragePreparation: Codable, Equatable, Sendable {
    let claimID: UUID
    let generation: UInt64
    let parentID: TorrentStorageParentID
    let preferredTopLevelName: String
    let ownershipKey: Data?
    let operationNonce: UUID
    var reservedTopLevelName: String?
}

enum TorrentMagnetPromotionState: String, Codable, Sendable {
    case awaitingMetadata
    case metadataReady
    case awaitingDestination
    case promoting
    case outcomeUnknown
}

struct TorrentMagnetPromotionRuntimeState: Codable, Equatable, Sendable {
    let wasPaused: Bool
    let queuePosition: Int32
    let options: TorrentOptions
    let sourcePolicy: TorrentSourcePolicy
    let filePriorities: [Int32: TorrentFilePriority]
    let labelIDs: Set<TorrentLabel.ID>
}

struct TorrentMagnetPromotionActivation: Codable, Equatable, Sendable {
    let claimID: UUID
    let claimOperationNonce: UUID
    let runtime: TorrentMagnetPromotionRuntimeState
}

struct TorrentMagnetPromotion: Codable, Equatable, Sendable {
    let id: UUID
    let torrentID: String
    let originalMagnet: String
    let advertisedInfoHashes: TorrentStorageInfoHashes
    var destinationPath: String
    let operationNonce: UUID
    var state: TorrentMagnetPromotionState
    var exactInfoDictionary: Data?
    var activation: TorrentMagnetPromotionActivation?
}

actor TorrentStorageClaimJournal {
    private struct Snapshot: Codable, Sendable {
        static let currentSchemaVersion: UInt64 = 5

        var schemaVersion: UInt64 = Self.currentSchemaVersion
        var preparations = [UUID: TorrentStoragePreparation]()
        var claims = [UUID: TorrentStorageClaim]()
        var promotions = [UUID: TorrentMagnetPromotion]()

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case preparations
            case claims
            case promotions
        }

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(UInt64.self, forKey: .schemaVersion)
            preparations = try container.decode(
                [UUID: TorrentStoragePreparation].self,
                forKey: .preparations
            )
            claims = try container.decode(
                [UUID: TorrentStorageClaim].self,
                forKey: .claims
            )
            promotions = try container.decode(
                [UUID: TorrentMagnetPromotion].self,
                forKey: .promotions
            )
        }
    }

    private struct SchemaProbe: Decodable {
        let schemaVersion: UInt64
    }

    private static let filename = "StorageClaims.json"
    private static let maximumJournalBytes = 128 * 1_024 * 1_024
    private static let maximumClaimCount = 20_000

    private let directoryDescriptor: FileDescriptor
    private var snapshot: Snapshot

    init(directory: URL) throws {
        let path = directory.standardizedFileURL.path(percentEncoded: false)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor: FileDescriptor
        do {
            descriptor = try FileDescriptor.open(
                FilePath(path),
                .readOnly,
                options: [.closeOnExec, .directory, .noFollow]
            )
        } catch {
            throw TorrentStorageJournalError.unavailable
        }
        var shouldCloseDescriptor = true
        defer {
            if shouldCloseDescriptor {
                try? descriptor.close()
            }
        }
        directoryDescriptor = descriptor
        snapshot = try Self.load(from: descriptor.rawValue)
        shouldCloseDescriptor = false
    }

    deinit {
        try? directoryDescriptor.close()
    }

    func allClaims() -> [TorrentStorageClaim] {
        snapshot.claims.values.sorted {
            $0.manifest.claimID.uuidString < $1.manifest.claimID.uuidString
        }
    }

    func unresolvedPreparations() -> [TorrentStoragePreparation] {
        snapshot.preparations.values.sorted {
            $0.claimID.uuidString < $1.claimID.uuidString
        }
    }

    func allPromotions() -> [TorrentMagnetPromotion] {
        snapshot.promotions.values.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
    }

    func requiredFolderAccess() -> (
        parentIDs: Set<TorrentStorageParentID>,
        paths: Set<String>
    ) {
        let parentIDs = Set(snapshot.claims.values.lazy
            .filter { $0.lease.state != .orphaned }
            .map(\.manifest.parentID))
            .union(snapshot.preparations.values.map(\.parentID))
        return (
            parentIDs,
            Set(snapshot.promotions.values.map(\.destinationPath))
        )
    }

    func promotion(id: UUID) -> TorrentMagnetPromotion? {
        snapshot.promotions[id]
    }

    func claim(id: UUID) -> TorrentStorageClaim? {
        snapshot.claims[id]
    }

    func beginPreparation(_ preparation: TorrentStoragePreparation) throws {
        guard snapshot.claims.count + snapshot.preparations.count
                + snapshot.promotions.count
                < Self.maximumClaimCount else {
            throw TorrentStorageJournalError.capacityExceeded
        }
        guard Self.isValid(preparation) else {
            throw TorrentStorageJournalError.invalidTransition
        }
        if let existing = snapshot.preparations[preparation.claimID] {
            guard existing == preparation else {
                throw TorrentStorageJournalError.claimAlreadyExists
            }
            return
        }
        guard snapshot.claims[preparation.claimID] == nil else {
            throw TorrentStorageJournalError.claimAlreadyExists
        }
        var updated = snapshot
        updated.preparations[preparation.claimID] = preparation
        try persist(updated)
        snapshot = updated
    }

    func beginPromotion(_ promotion: TorrentMagnetPromotion) throws {
        guard snapshot.claims.count + snapshot.preparations.count
                + snapshot.promotions.count < Self.maximumClaimCount else {
            throw TorrentStorageJournalError.capacityExceeded
        }
        if let existing = snapshot.promotions[promotion.id] {
            guard existing == promotion else {
                throw TorrentStorageJournalError.promotionAlreadyExists
            }
            return
        }
        guard Self.isValid(promotion),
              promotion.state == .awaitingMetadata,
              promotion.exactInfoDictionary == nil,
              promotion.activation == nil,
              !snapshot.promotions.values.contains(where: {
                  $0.torrentID == promotion.torrentID
              }) else {
            throw TorrentStorageJournalError.invalidTransition
        }
        var updated = snapshot
        updated.promotions[promotion.id] = promotion
        try persist(updated)
        snapshot = updated
    }

    @discardableResult
    func recordPromotionMetadata(
        id: UUID,
        operationNonce: UUID,
        exactInfoDictionary: Data
    ) throws -> TorrentMagnetPromotion {
        guard var promotion = snapshot.promotions[id] else {
            throw TorrentStorageJournalError.unknownPromotion
        }
        guard promotion.operationNonce == operationNonce else {
            throw TorrentStorageJournalError.operationNonceMismatch
        }
        if promotion.state == .metadataReady,
           promotion.exactInfoDictionary == exactInfoDictionary {
            return promotion
        }
        guard promotion.state == .awaitingMetadata,
              promotion.exactInfoDictionary == nil,
              promotion.activation == nil else {
            throw TorrentStorageJournalError.invalidTransition
        }
        promotion.state = .metadataReady
        promotion.exactInfoDictionary = exactInfoDictionary
        guard Self.isValid(promotion) else {
            throw TorrentStorageJournalError.invalidTransition
        }
        var updated = snapshot
        updated.promotions[id] = promotion
        try persist(updated)
        snapshot = updated
        return promotion
    }

    @discardableResult
    func beginPromotionActivation(
        id: UUID,
        operationNonce: UUID,
        activation: TorrentMagnetPromotionActivation
    ) throws -> TorrentMagnetPromotion {
        guard var promotion = snapshot.promotions[id] else {
            throw TorrentStorageJournalError.unknownPromotion
        }
        guard promotion.operationNonce == operationNonce else {
            throw TorrentStorageJournalError.operationNonceMismatch
        }
        if promotion.state == .promoting,
           promotion.activation == activation {
            return promotion
        }
        guard promotion.state == .metadataReady,
              promotion.exactInfoDictionary != nil,
              promotion.activation == nil else {
            throw TorrentStorageJournalError.invalidTransition
        }
        promotion.state = .promoting
        promotion.activation = activation
        guard Self.isValid(promotion) else {
            throw TorrentStorageJournalError.invalidTransition
        }
        var updated = snapshot
        updated.promotions[id] = promotion
        try persist(updated)
        snapshot = updated
        return promotion
    }

    @discardableResult
    func markPromotionAwaitingDestination(
        id: UUID,
        operationNonce: UUID
    ) throws -> TorrentMagnetPromotion {
        guard var promotion = snapshot.promotions[id] else {
            throw TorrentStorageJournalError.unknownPromotion
        }
        guard promotion.operationNonce == operationNonce else {
            throw TorrentStorageJournalError.operationNonceMismatch
        }
        if promotion.state == .awaitingDestination {
            return promotion
        }
        guard promotion.state == .promoting,
              promotion.exactInfoDictionary != nil,
              promotion.activation != nil else {
            throw TorrentStorageJournalError.invalidTransition
        }
        promotion.state = .awaitingDestination
        var updated = snapshot
        updated.promotions[id] = promotion
        try persist(updated)
        snapshot = updated
        return promotion
    }

    @discardableResult
    func replacePromotionDestination(
        id: UUID,
        operationNonce: UUID,
        destinationPath: String
    ) throws -> TorrentMagnetPromotion {
        guard var promotion = snapshot.promotions[id] else {
            throw TorrentStorageJournalError.unknownPromotion
        }
        guard promotion.operationNonce == operationNonce else {
            throw TorrentStorageJournalError.operationNonceMismatch
        }
        guard promotion.state == .awaitingDestination else {
            throw TorrentStorageJournalError.invalidTransition
        }
        if promotion.destinationPath == destinationPath {
            return promotion
        }
        promotion.destinationPath = destinationPath
        guard Self.isValid(promotion) else {
            throw TorrentStorageJournalError.invalidTransition
        }
        var updated = snapshot
        updated.promotions[id] = promotion
        try persist(updated)
        snapshot = updated
        return promotion
    }

    @discardableResult
    func beginPromotionDestinationActivation(
        id: UUID,
        operationNonce: UUID
    ) throws -> TorrentMagnetPromotion {
        guard var promotion = snapshot.promotions[id] else {
            throw TorrentStorageJournalError.unknownPromotion
        }
        guard promotion.operationNonce == operationNonce else {
            throw TorrentStorageJournalError.operationNonceMismatch
        }
        if promotion.state == .promoting {
            return promotion
        }
        guard promotion.state == .awaitingDestination,
              promotion.exactInfoDictionary != nil,
              promotion.activation != nil else {
            throw TorrentStorageJournalError.invalidTransition
        }
        promotion.state = .promoting
        var updated = snapshot
        updated.promotions[id] = promotion
        try persist(updated)
        snapshot = updated
        return promotion
    }

    @discardableResult
    func markPromotionOutcomeUnknown(
        id: UUID,
        operationNonce: UUID
    ) throws -> TorrentMagnetPromotion {
        guard var promotion = snapshot.promotions[id] else {
            throw TorrentStorageJournalError.unknownPromotion
        }
        guard promotion.operationNonce == operationNonce else {
            throw TorrentStorageJournalError.operationNonceMismatch
        }
        if promotion.state == .outcomeUnknown {
            return promotion
        }
        guard promotion.state == .promoting else {
            throw TorrentStorageJournalError.invalidTransition
        }
        promotion.state = .outcomeUnknown
        var updated = snapshot
        updated.promotions[id] = promotion
        try persist(updated)
        snapshot = updated
        return promotion
    }

    func retirePromotion(
        id: UUID,
        operationNonce: UUID
    ) throws {
        guard let promotion = snapshot.promotions[id] else {
            return
        }
        guard promotion.operationNonce == operationNonce else {
            throw TorrentStorageJournalError.operationNonceMismatch
        }
        var updated = snapshot
        updated.promotions.removeValue(forKey: id)
        try persist(updated)
        snapshot = updated
    }

    func noteReservation(
        claimID: UUID,
        generation: UInt64,
        operationNonce: UUID,
        topLevelName: String
    ) throws {
        guard TorrentPathComponentValidation.isSafe(topLevelName) else {
            throw TorrentStorageJournalError.invalidTransition
        }
        guard var preparation = snapshot.preparations[claimID] else {
            throw TorrentStorageJournalError.unknownClaim
        }
        guard preparation.generation == generation else {
            throw TorrentStorageJournalError.generationMismatch
        }
        guard preparation.operationNonce == operationNonce else {
            throw TorrentStorageJournalError.operationNonceMismatch
        }
        if let existing = preparation.reservedTopLevelName {
            guard existing == topLevelName else {
                throw TorrentStorageJournalError.invalidTransition
            }
            return
        }
        preparation.reservedTopLevelName = topLevelName
        var updated = snapshot
        updated.preparations[claimID] = preparation
        try persist(updated)
        snapshot = updated
    }

    func commitReserved(_ claim: TorrentStorageClaim) throws {
        let id = claim.manifest.claimID
        if let existing = snapshot.claims[id] {
            guard existing == claim else {
                throw TorrentStorageJournalError.claimAlreadyExists
            }
            return
        }
        guard let preparation = snapshot.preparations[id] else {
            throw TorrentStorageJournalError.unknownClaim
        }
        guard preparation.generation == claim.manifest.generation else {
            throw TorrentStorageJournalError.generationMismatch
        }
        guard preparation.operationNonce == claim.operationNonce,
              preparation.parentID == claim.manifest.parentID,
              claim.manifest.ownership.ownershipKey == preparation.ownershipKey,
              preparation.reservedTopLevelName
                == claim.manifest.collisionSelectedTopLevelName,
              claim.lease.state == .reserved,
              claim.removalIntent == nil,
              claim.deletionEvidence == nil,
              Self.isValid(claim) else {
            throw TorrentStorageJournalError.invalidTransition
        }
        var updated = snapshot
        updated.preparations.removeValue(forKey: id)
        updated.claims[id] = claim
        try persist(updated)
        snapshot = updated
    }

    @discardableResult
    func transition(
        claimID: UUID,
        generation: UInt64,
        operationNonce: UUID,
        from expectedStates: Set<TorrentStorageClaimState>,
        to newState: TorrentStorageClaimState,
        torrentID: String? = nil,
        removalIntent: TorrentStorageRemovalIntent? = nil
    ) throws -> TorrentStorageClaim {
        guard var claim = snapshot.claims[claimID] else {
            throw TorrentStorageJournalError.unknownClaim
        }
        guard claim.manifest.generation == generation else {
            throw TorrentStorageJournalError.generationMismatch
        }
        if claim.operationNonce == operationNonce,
           claim.lease.state == newState {
            return claim
        }
        guard expectedStates.contains(claim.lease.state),
              Self.transitionIsAllowed(from: claim.lease.state, to: newState),
              !Self.requiresMatchingNonce(from: claim.lease.state)
                || claim.operationNonce == operationNonce else {
            throw TorrentStorageJournalError.invalidTransition
        }
        if newState == .active {
            guard let torrentID, !torrentID.isEmpty else {
                throw TorrentStorageJournalError.invalidTransition
            }
        }
        if newState == .removing {
            guard removalIntent != nil else {
                throw TorrentStorageJournalError.invalidTransition
            }
        } else if removalIntent != nil {
            throw TorrentStorageJournalError.invalidTransition
        }
        if newState == .deleting {
            guard claim.removalIntent == .deletePayload else {
                throw TorrentStorageJournalError.invalidTransition
            }
        }
        claim.operationNonce = operationNonce
        claim.lease.state = newState
        if let removalIntent {
            claim.removalIntent = removalIntent
        }
        if let torrentID {
            claim.torrentID = torrentID
        }
        guard Self.isValid(claim) else {
            throw TorrentStorageJournalError.invalidTransition
        }
        var updated = snapshot
        updated.claims[claimID] = claim
        try persist(updated)
        snapshot = updated
        return claim
    }

    @discardableResult
    func replaceAvailability(
        claimID: UUID,
        generation: UInt64,
        expectedAvailabilityRevision: UInt64,
        fileAvailability: [Bool]
    ) throws -> TorrentStorageClaim {
        guard var claim = snapshot.claims[claimID] else {
            throw TorrentStorageJournalError.unknownClaim
        }
        guard claim.manifest.generation == generation else {
            throw TorrentStorageJournalError.generationMismatch
        }
        let nextRevision = expectedAvailabilityRevision.addingReportingOverflow(1)
        if !nextRevision.overflow,
           claim.lease.availabilityRevision == nextRevision.partialValue,
           claim.lease.fileAvailability == fileAvailability {
            return claim
        }
        guard claim.lease.availabilityRevision == expectedAvailabilityRevision,
              claim.lease.state == .active,
              TorrentStorageLeaseValidation.isValid(
                  logicalFiles: claim.manifest.logicalFiles,
                  fileAvailability: fileAvailability
              ),
              claim.lease.availabilityRevision != UInt64.max else {
            throw TorrentStorageJournalError.invalidTransition
        }
        claim.lease.availabilityRevision += 1
        claim.lease.fileAvailability = fileAvailability
        guard Self.isValid(claim) else {
            throw TorrentStorageJournalError.invalidTransition
        }
        var updated = snapshot
        updated.claims[claimID] = claim
        try persist(updated)
        snapshot = updated
        return claim
    }

    @discardableResult
    func recordDeletionEvidence(
        claimID: UUID,
        generation: UInt64,
        operationNonce: UUID,
        evidence: TorrentStorageDeletionEvidence
    ) throws -> TorrentStorageClaim {
        guard var claim = snapshot.claims[claimID] else {
            throw TorrentStorageJournalError.unknownClaim
        }
        guard claim.manifest.generation == generation else {
            throw TorrentStorageJournalError.generationMismatch
        }
        guard claim.operationNonce == operationNonce,
              claim.lease.state == .deleting,
              claim.removalIntent == .deletePayload else {
            throw TorrentStorageJournalError.invalidTransition
        }
        if let existing = claim.deletionEvidence {
            guard existing == evidence else {
                throw TorrentStorageJournalError.invalidTransition
            }
            return claim
        }
        claim.deletionEvidence = evidence
        guard Self.isValid(claim) else {
            throw TorrentStorageJournalError.invalidTransition
        }
        var updated = snapshot
        updated.claims[claimID] = claim
        try persist(updated)
        snapshot = updated
        return claim
    }

    func completeClaimRemoval(
        claimID: UUID,
        generation: UInt64,
        operationNonce: UUID
    ) throws {
        guard let claim = snapshot.claims[claimID] else {
            return
        }
        guard claim.manifest.generation == generation else {
            throw TorrentStorageJournalError.generationMismatch
        }
        guard claim.operationNonce == operationNonce,
              (claim.lease.state == .removing
                  && claim.removalIntent == .keepPayload
               || claim.lease.state == .deleting
                  && claim.removalIntent == .deletePayload
                  && claim.deletionEvidence != nil) else {
            throw TorrentStorageJournalError.invalidTransition
        }
        var updated = snapshot
        updated.claims.removeValue(forKey: claimID)
        try persist(updated)
        snapshot = updated
    }

    /// Relinquishes broker authority without asserting that any payload was
    /// removed. Generation binding prevents stale recovery work from retiring
    /// a replacement claim.
    func retireClaimPreservingPayload(
        claimID: UUID,
        generation: UInt64
    ) throws {
        guard let claim = snapshot.claims[claimID] else {
            return
        }
        guard claim.manifest.generation == generation else {
            throw TorrentStorageJournalError.generationMismatch
        }
        var updated = snapshot
        updated.claims.removeValue(forKey: claimID)
        try persist(updated)
        snapshot = updated
    }

    func cancelPreparation(
        claimID: UUID,
        generation: UInt64,
        operationNonce: UUID
    ) throws {
        guard let preparation = snapshot.preparations[claimID] else {
            return
        }
        guard preparation.generation == generation else {
            throw TorrentStorageJournalError.generationMismatch
        }
        guard preparation.operationNonce == operationNonce else {
            throw TorrentStorageJournalError.operationNonceMismatch
        }
        var updated = snapshot
        updated.preparations.removeValue(forKey: claimID)
        try persist(updated)
        snapshot = updated
    }

    private func persist(_ value: Snapshot) throws {
        try Self.persist(value, in: directoryDescriptor.rawValue)
    }

    private static func persist(
        _ value: Snapshot,
        in directoryDescriptor: Int32
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumJournalBytes else {
            throw TorrentStorageJournalError.capacityExceeded
        }
        let temporaryName = ".StorageClaims.\(UUID().uuidString).tmp"
        let descriptor = unsafe temporaryName.withCString { pointer in
            unsafe Darwin.openat(
                directoryDescriptor,
                pointer,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw TorrentStorageJournalError.unavailable
        }
        var shouldUnlink = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldUnlink {
                _ = unsafe temporaryName.withCString { pointer in
                    unsafe Darwin.unlinkat(directoryDescriptor, pointer, 0)
                }
            }
        }
        try Self.writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw TorrentStorageJournalError.unavailable
        }
        let renamed = unsafe temporaryName.withCString { source in
            unsafe Self.filename.withCString { destination in
                unsafe Darwin.renameat(
                    directoryDescriptor,
                    source,
                    directoryDescriptor,
                    destination
                )
            }
        }
        guard renamed == 0,
              Darwin.fsync(directoryDescriptor) == 0 else {
            throw TorrentStorageJournalError.unavailable
        }
        shouldUnlink = false
    }

    private static func load(
        from directoryDescriptor: Int32
    ) throws -> Snapshot {
        let descriptor = unsafe filename.withCString { pointer in
            unsafe Darwin.openat(
                directoryDescriptor,
                pointer,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        if descriptor < 0 {
            guard errno == ENOENT else {
                throw TorrentStorageJournalError.unavailable
            }
            return Snapshot()
        }
        defer {
            _ = Darwin.close(descriptor)
        }
        var metadata = stat()
        guard unsafe Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= off_t(maximumJournalBytes) else {
            throw TorrentStorageJournalError.corrupt
        }
        let data = try readAll(
            from: descriptor,
            expectedSize: Int(metadata.st_size)
        )
        let decoder = JSONDecoder()
        let schemaVersion: UInt64
        do {
            schemaVersion = try decoder.decode(
                SchemaProbe.self,
                from: data
            ).schemaVersion
        } catch {
            throw TorrentStorageJournalError.corrupt
        }

        if schemaVersion < Snapshot.currentSchemaVersion {
            let empty = Snapshot()
            try persist(empty, in: directoryDescriptor)
            return empty
        }

        guard schemaVersion == Snapshot.currentSchemaVersion else {
            throw TorrentStorageJournalError.unsupportedVersion(schemaVersion)
        }

        do {
            let decoded = try decoder.decode(Snapshot.self, from: data)
            guard decoded.schemaVersion == Snapshot.currentSchemaVersion,
                  decoded.claims.count + decoded.preparations.count
                    + decoded.promotions.count
                    <= maximumClaimCount,
                  decoded.claims.allSatisfy({ $0.key == $0.value.manifest.claimID }),
                  decoded.preparations.allSatisfy({ $0.key == $0.value.claimID }),
                  decoded.promotions.allSatisfy({ $0.key == $0.value.id }),
                  decoded.claims.values.allSatisfy(isValid),
                  decoded.preparations.values.allSatisfy(isValid),
                  decoded.promotions.values.allSatisfy(isValid),
                  Set(decoded.promotions.values.map(\.torrentID)).count
                    == decoded.promotions.count else {
                throw TorrentStorageJournalError.corrupt
            }
            return decoded
        } catch let error as TorrentStorageJournalError {
            throw error
        } catch {
            throw TorrentStorageJournalError.corrupt
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try unsafe data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let result = unsafe Darwin.write(
                    descriptor,
                    unsafe bytes.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw TorrentStorageJournalError.unavailable
                }
                written += result
            }
        }
    }

    private static func readAll(
        from descriptor: Int32,
        expectedSize: Int
    ) throws -> Data {
        var data = Data(count: expectedSize)
        let count = try unsafe data.withUnsafeMutableBytes { bytes in
            var readCount = 0
            while readCount < bytes.count {
                let result = unsafe Darwin.read(
                    descriptor,
                    unsafe bytes.baseAddress?.advanced(by: readCount),
                    bytes.count - readCount
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result >= 0 else {
                    throw TorrentStorageJournalError.unavailable
                }
                if result == 0 {
                    break
                }
                readCount += result
            }
            return readCount
        }
        guard count == expectedSize else {
            throw TorrentStorageJournalError.corrupt
        }
        return data
    }

    private static func transitionIsAllowed(
        from state: TorrentStorageClaimState,
        to newState: TorrentStorageClaimState
    ) -> Bool {
        switch state {
        case .reserved:
            newState == .activating || newState == .orphaned
        case .activating:
            newState == .active
                || newState == .activationUnknown
                || newState == .orphaned
        case .active:
            newState == .removing || newState == .orphaned
        case .activationUnknown:
            newState == .removing || newState == .orphaned
        case .removing:
            newState == .deleting
                || newState == .deletionPending
                || newState == .orphaned
        case .deleting:
            newState == .deletionPending
        case .deletionPending:
            newState == .deleting || newState == .orphaned
        case .orphaned:
            newState == .deleting
        }
    }

    private static func requiresMatchingNonce(
        from state: TorrentStorageClaimState
    ) -> Bool {
        switch state {
        case .reserved, .activating, .removing, .deleting:
            true
        case .active, .activationUnknown, .deletionPending, .orphaned:
            false
        }
    }

    private static func isValid(_ preparation: TorrentStoragePreparation) -> Bool {
        preparation.generation > 0
            && preparation.parentID.ownerUserID == geteuid()
            && (preparation.ownershipKey?.count
                == TorrentStorageOwnershipTag.keyByteCount
                || preparation.ownershipKey == nil)
            && TorrentPathComponentValidation.isSafe(
                preparation.preferredTopLevelName
            )
            && (preparation.reservedTopLevelName.map(
                TorrentPathComponentValidation.isSafe
            ) ?? true)
    }

    private static func isValid(_ claim: TorrentStorageClaim) -> Bool {
        TorrentStorageClaimValidation.isValid(claim)
    }

    private static func isValid(_ promotion: TorrentMagnetPromotion) -> Bool {
        guard TorrentStorageActivation.isCanonicalTorrentID(promotion.torrentID),
              promotion.originalMagnet.utf8.count
                <= TorrentInputLimits.maxMagnetURIBytes,
              !promotion.originalMagnet.utf8.contains(0),
              promotion.destinationPath.hasPrefix("/"),
              promotion.destinationPath.utf8.count <= 16 * 1_024,
              !promotion.destinationPath.utf8.contains(0),
              (try? ParsedMagnet.parse(promotion.originalMagnet))
                .flatMap({ try? $0.storageInfoHashes }) == promotion.advertisedInfoHashes else {
            return false
        }

        switch promotion.state {
        case .awaitingMetadata:
            return promotion.exactInfoDictionary == nil
                && promotion.activation == nil
        case .metadataReady:
            return promotion.exactInfoDictionary.map {
                exactInfoMatches($0, hashes: promotion.advertisedInfoHashes)
            } == true && promotion.activation == nil
        case .awaitingDestination, .promoting, .outcomeUnknown:
            guard let info = promotion.exactInfoDictionary,
                  exactInfoMatches(info, hashes: promotion.advertisedInfoHashes),
                  let activation = promotion.activation,
                  activation.runtime.queuePosition >= -1,
                  activation.runtime.filePriorities.count
                    <= TorrentEngineLimits.maximumFileCount,
                  activation.runtime.filePriorities.allSatisfy({
                      (0..<Int32(TorrentEngineLimits.maximumFileCount)).contains($0.key)
                  }),
                  activation.runtime.labelIDs.count <= TorrentLabel.maximumCount,
                  activation.runtime.labelIDs.allSatisfy({
                      !$0.isEmpty
                          && $0.utf8.count <= TorrentLabel.maxIDByteCount
                  }) else {
                return false
            }
            return true
        }
    }

    private static func exactInfoMatches(
        _ info: Data,
        hashes: TorrentStorageInfoHashes
    ) -> Bool {
        guard !info.isEmpty,
              info.count <= TorrentInputLimits.maxTorrentFileBytes else {
            return false
        }
        if let v1 = hashes.v1,
           Data(Insecure.SHA1.hash(data: info)) != v1 {
            return false
        }
        if let v2 = hashes.v2,
           Data(SHA256.hash(data: info)) != v2 {
            return false
        }
        return true
    }

}
