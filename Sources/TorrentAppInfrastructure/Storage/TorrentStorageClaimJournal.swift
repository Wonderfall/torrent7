import Darwin
import CryptoKit
import Foundation
import System
import TorrentEngineModel
import TorrentMetainfo
import TorrentStorageAuthority

package enum TorrentStorageJournalError: LocalizedError, Equatable, Sendable {
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

    package var errorDescription: String? {
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

package struct TorrentStoragePreparation: Codable, Equatable, Sendable {
    package let claimID: UUID
    package let generation: UInt64
    package let parentID: TorrentStorageParentID
    package let preferredTopLevelName: String
    package let ownershipKey: Data?
    package let operationNonce: UUID
    package var reservedTopLevelName: String?

    package init(
        claimID: UUID,
        generation: UInt64,
        parentID: TorrentStorageParentID,
        preferredTopLevelName: String,
        ownershipKey: Data?,
        operationNonce: UUID,
        reservedTopLevelName: String?
    ) {
        self.claimID = claimID
        self.generation = generation
        self.parentID = parentID
        self.preferredTopLevelName = preferredTopLevelName
        self.ownershipKey = ownershipKey
        self.operationNonce = operationNonce
        self.reservedTopLevelName = reservedTopLevelName
    }
}

package enum TorrentMagnetPromotionState: String, Codable, Sendable {
    case awaitingMetadata
    case metadataReady
    case awaitingDestination
    case promoting
    case outcomeUnknown
}

package struct TorrentMagnetPromotionRuntimeState: Codable, Equatable, Sendable {
    package let wasPaused: Bool
    package let queuePosition: Int32
    package let options: TorrentOptions
    package let sourcePolicy: TorrentSourcePolicy
    package let filePriorities: [Int32: TorrentFilePriority]
    package let labelIDs: Set<TorrentLabel.ID>

    package init(
        wasPaused: Bool,
        queuePosition: Int32,
        options: TorrentOptions,
        sourcePolicy: TorrentSourcePolicy,
        filePriorities: [Int32: TorrentFilePriority],
        labelIDs: Set<TorrentLabel.ID>
    ) {
        self.wasPaused = wasPaused
        self.queuePosition = queuePosition
        self.options = options
        self.sourcePolicy = sourcePolicy
        self.filePriorities = filePriorities
        self.labelIDs = labelIDs
    }
}

package struct TorrentMagnetPromotionActivation: Codable, Equatable, Sendable {
    package let claimID: UUID
    package let claimOperationNonce: UUID
    package let runtime: TorrentMagnetPromotionRuntimeState

    package init(
        claimID: UUID,
        claimOperationNonce: UUID,
        runtime: TorrentMagnetPromotionRuntimeState
    ) {
        self.claimID = claimID
        self.claimOperationNonce = claimOperationNonce
        self.runtime = runtime
    }
}

package struct TorrentMagnetPromotion: Codable, Equatable, Sendable {
    package let id: UUID
    package let torrentID: String
    package let originalMagnet: String
    package let advertisedInfoHashes: TorrentStorageInfoHashes
    package var destinationPath: String
    package let operationNonce: UUID
    package var state: TorrentMagnetPromotionState
    package var exactInfoDictionary: Data?
    package var activation: TorrentMagnetPromotionActivation?

    package init(
        id: UUID,
        torrentID: String,
        originalMagnet: String,
        advertisedInfoHashes: TorrentStorageInfoHashes,
        destinationPath: String,
        operationNonce: UUID,
        state: TorrentMagnetPromotionState,
        exactInfoDictionary: Data?,
        activation: TorrentMagnetPromotionActivation?
    ) {
        self.id = id
        self.torrentID = torrentID
        self.originalMagnet = originalMagnet
        self.advertisedInfoHashes = advertisedInfoHashes
        self.destinationPath = destinationPath
        self.operationNonce = operationNonce
        self.state = state
        self.exactInfoDictionary = exactInfoDictionary
        self.activation = activation
    }
}

package enum TorrentStorageRemovalContext: Sendable {
    case claim(
        TorrentStorageClaim,
        linkedPromotion: TorrentMagnetPromotion?
    )
    case stagedMagnet(TorrentMagnetPromotion)
    case missingOrAmbiguous
}

package actor TorrentStorageClaimJournal {
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

    package init(directory: URL) throws {
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

    package func allClaims() -> [TorrentStorageClaim] {
        snapshot.claims.values.sorted {
            $0.manifest.claimID.uuidString < $1.manifest.claimID.uuidString
        }
    }

    package func unresolvedPreparations() -> [TorrentStoragePreparation] {
        snapshot.preparations.values.sorted {
            $0.claimID.uuidString < $1.claimID.uuidString
        }
    }

    package func allPromotions() -> [TorrentMagnetPromotion] {
        snapshot.promotions.values.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
    }

    package func removalContext(for torrentID: String) -> TorrentStorageRemovalContext {
        let matchingClaims = snapshot.claims.values.filter {
            $0.torrentID == torrentID
        }
        let matchingPromotions = snapshot.promotions.values.filter {
            $0.torrentID == torrentID
        }
        guard matchingClaims.count <= 1,
              matchingPromotions.count <= 1 else {
            return .missingOrAmbiguous
        }

        let promotion = matchingPromotions.first
        if let claim = matchingClaims.first {
            guard let promotion else {
                let linkedPromotions = snapshot.promotions.values.filter {
                    $0.activation?.claimID == claim.manifest.claimID
                }
                return linkedPromotions.isEmpty
                    ? .claim(claim, linkedPromotion: nil)
                    : .missingOrAmbiguous
            }
            let promotionLinksClaim = switch promotion.state {
            case .promoting, .outcomeUnknown:
                promotion.activation?.claimID == claim.manifest.claimID
            case .awaitingMetadata, .metadataReady, .awaitingDestination:
                false
            }
            let linkedPromotions = snapshot.promotions.values.filter {
                $0.activation?.claimID == claim.manifest.claimID
            }
            guard promotionLinksClaim,
                  linkedPromotions.count == 1,
                  linkedPromotions.first?.id == promotion.id else {
                return .missingOrAmbiguous
            }
            return .claim(claim, linkedPromotion: promotion)
        }

        guard let promotion else {
            return .missingOrAmbiguous
        }
        switch promotion.state {
        case .awaitingMetadata, .metadataReady:
            return .stagedMagnet(promotion)
        case .promoting, .outcomeUnknown:
            guard let claimID = promotion.activation?.claimID,
                  let claim = snapshot.claims[claimID],
                  claim.lease.state == .activationUnknown,
                  claim.torrentID == nil else {
                return .missingOrAmbiguous
            }
            let linkedPromotions = snapshot.promotions.values.filter {
                $0.activation?.claimID == claimID
            }
            guard linkedPromotions.count == 1,
                  linkedPromotions.first?.id == promotion.id else {
                return .missingOrAmbiguous
            }
            return .claim(claim, linkedPromotion: promotion)
        case .awaitingDestination:
            return .missingOrAmbiguous
        }
    }

    package func requiredFolderAccess() -> (
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

    package func promotion(id: UUID) -> TorrentMagnetPromotion? {
        snapshot.promotions[id]
    }

    package func claim(id: UUID) -> TorrentStorageClaim? {
        snapshot.claims[id]
    }

    package func beginPreparation(_ preparation: TorrentStoragePreparation) throws {
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

    package func beginPromotion(_ promotion: TorrentMagnetPromotion) throws {
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
    package func recordPromotionMetadata(
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
    package func beginPromotionActivation(
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
    package func markPromotionAwaitingDestination(
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
    package func replacePromotionDestination(
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
    package func beginPromotionDestinationActivation(
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
    package func markPromotionOutcomeUnknown(
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

    package func retirePromotion(
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

    package func noteReservation(
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

    package func commitReserved(_ claim: TorrentStorageClaim) throws {
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
    package func transition(
        claimID: UUID,
        generation: UInt64,
        operationNonce: UUID,
        from expectedStates: Set<TorrentStorageClaimState>,
        to newState: TorrentStorageClaimState,
        torrentID: String? = nil,
        removalIntent: TorrentStorageRemovalIntent? = nil,
        linkedPromotionToRetire: TorrentMagnetPromotion? = nil
    ) throws -> TorrentStorageClaim {
        guard var claim = snapshot.claims[claimID] else {
            throw TorrentStorageJournalError.unknownClaim
        }
        guard claim.manifest.generation == generation else {
            throw TorrentStorageJournalError.generationMismatch
        }
        if linkedPromotionToRetire != nil,
           newState != .deletionPending {
            throw TorrentStorageJournalError.invalidTransition
        }
        if claim.operationNonce == operationNonce,
           claim.lease.state == newState {
            guard let linkedPromotionToRetire else {
                return claim
            }
            var updated = snapshot
            try Self.retireLinkedPromotion(
                linkedPromotionToRetire,
                claimID: claimID,
                from: &updated
            )
            try persist(updated)
            snapshot = updated
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
        try Self.retireLinkedPromotion(
            linkedPromotionToRetire,
            claimID: claimID,
            from: &updated
        )
        try persist(updated)
        snapshot = updated
        return claim
    }

    @discardableResult
    package func replaceAvailability(
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
    package func recordDeletionEvidence(
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

    package func completeClaimRemoval(
        claimID: UUID,
        generation: UInt64,
        operationNonce: UUID,
        linkedPromotionToRetire: TorrentMagnetPromotion? = nil
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
        try Self.retireLinkedPromotion(
            linkedPromotionToRetire,
            claimID: claimID,
            from: &updated
        )
        try persist(updated)
        snapshot = updated
    }

    private static func retireLinkedPromotion(
        _ promotion: TorrentMagnetPromotion?,
        claimID: UUID,
        from snapshot: inout Snapshot
    ) throws {
        guard let promotion else {
            return
        }
        let hasLinkedState = switch promotion.state {
        case .promoting, .outcomeUnknown:
            true
        case .awaitingMetadata, .metadataReady, .awaitingDestination:
            false
        }
        guard hasLinkedState,
              promotion.activation?.claimID == claimID else {
            throw TorrentStorageJournalError.invalidTransition
        }
        let linkedPromotions = snapshot.promotions.values.filter {
            $0.activation?.claimID == claimID
        }
        guard let stored = snapshot.promotions[promotion.id] else {
            guard linkedPromotions.isEmpty else {
                throw TorrentStorageJournalError.invalidTransition
            }
            return
        }
        guard linkedPromotions.count == 1,
              linkedPromotions.first?.id == stored.id,
              stored.operationNonce == promotion.operationNonce,
              stored.torrentID == promotion.torrentID,
              stored.activation?.claimID == claimID else {
            throw TorrentStorageJournalError.invalidTransition
        }
        switch stored.state {
        case .promoting, .outcomeUnknown:
            break
        case .awaitingMetadata, .metadataReady, .awaitingDestination:
            throw TorrentStorageJournalError.invalidTransition
        }
        snapshot.promotions.removeValue(forKey: promotion.id)
    }

    /// Relinquishes broker authority without asserting that any payload was
    /// removed. Generation binding prevents stale recovery work from retiring
    /// a replacement claim.
    package func retireClaimPreservingPayload(
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

    package func cancelPreparation(
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

    // SAFETY: Ownership/lifetime: temporary/target Strings pin C strings per synchronous
    // syscall and the created descriptor is closed exactly once; bounds/alignment: validated
    // NUL-free names are passed as NUL-terminated bytes with no raw indexing; synchronization:
    // the journal actor serializes persistence and rename publishes atomically; safe alternative:
    // openat/renameat/unlinkat are required for descriptor-relative, race-resistant replacement.
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

    // SAFETY: Ownership/lifetime: the filename pins its C string for openat, the opened
    // descriptor is deferred-closed, and local stat storage spans fstat; bounds/alignment:
    // the C string is NUL-terminated and `stat` is exact aligned storage; synchronization:
    // the journal actor serializes reads/writes; safe alternative: openat plus fstat verifies
    // the no-follow object itself and avoids Foundation pathname races.
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

    // SAFETY: Ownership/lifetime: Data pins its immutable storage for the entire synchronous
    // loop and the caller keeps the descriptor open; bounds/alignment: offsets advance only
    // by successful byte counts and each remaining length stays inside the buffer;
    // synchronization: actor serialization prevents concurrent journal writes; safe alternative:
    // Darwin write is required for explicit EINTR handling and descriptor durability.
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

    // SAFETY: Ownership/lifetime: mutable Data storage is pinned for the synchronous loop
    // and the caller keeps the descriptor open; bounds/alignment: offsets advance only by
    // successful reads within the exact allocated byte count; synchronization: actor
    // serialization prevents concurrent journal access; safe alternative: Darwin read is
    // required for bounded exact-length reads with explicit EINTR handling.
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
