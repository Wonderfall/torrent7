import Foundation
import TorrentEngineModel

package enum TorrentEngineIPCProtocol {
    package static let version: UInt64 = 5
}

package enum TorrentEngineIPCLimits {
    // The wire envelope must accommodate the 64 MiB torrent input plus bounded
    // binary-property-list structure and file-priority metadata.
    package static let maximumPayloadBytes = 66 * 1_024 * 1_024
    package static let maximumErrorBytes = 4 * 1_024
    package static let maximumBookmarkBytes = 1 * 1_024 * 1_024
    package static let maximumBookmarkAggregateBytes = 20 * 1_024 * 1_024
    package static let maximumDatasetPageBytes = 1 * 1_024 * 1_024
    package static let maximumDatasetPageItemCount = 256
    // Dataset pages are fetched serially. Bound the number independently of
    // item count so a hostile descriptor cannot amplify one poll into tens of
    // thousands of XPC round trips.
    package static let maximumDatasetPageCount = 256
    package static let maximumDatasetAggregateBytes = 128 * 1_024 * 1_024
    package static let maximumFileMetadataReplyBytes = 32 * 1_024 * 1_024
    // Folder replies remain generously bounded for bookmark and
    // binary-property-list overhead; canonical paths themselves are capped at
    // 32 KiB by the 32-root engine authority budget.
    package static let maximumFolderCapabilityReplyBytes = 32 * 1_024 * 1_024
    package static let maximumOpenDatasets = 4
    package static let maximumAlertErrorsPerPoll = 16
    package static let maximumStateMigrationFileCount = 20_000
}

package enum TorrentEngineIPCOperation: UInt64, CaseIterable, Sendable {
    case handshake = 1
    case restart = 2
    case shutdown = 3
    case poll = 4
    case grantFolderCapability = 5
    case revokeFolderCapability = 6
    case replaceFolderCapabilities = 7

    case previewTorrentFile = 11
    case addMagnet = 12
    case addTorrentFile = 13
    case pause = 14
    case resume = 15
    case reannounce = 16
    case forceRecheck = 17
    case remove = 18

    case applySettings = 20
    case blockNetwork = 21
    case saveAll = 22

    case requestSources = 30
    case sourcePolicy = 31
    case setSourcePolicy = 32
    case torrentOptions = 33
    case setTorrentOptions = 34
    case moveTorrentInQueue = 35
    case requestFiles = 36
    case setFilePriority = 37
    case requestPieceMap = 38

    case trackerBatch = 40
    case webSeedBatch = 42
    case webSeedActivity = 43
    case peerSources = 44
    case fileBatch = 45
    case pieceMapBatch = 46

    case readDataset = 51
    case closeDataset = 52

    case beginStateMigration = 60
    case importStateMigrationFile = 61
    case commitStateMigration = 62
    case abortStateMigration = 63

    case changeHint = 100

    package var maximumRequestPayloadBytes: Int {
        switch self {
        case .handshake, .replaceFolderCapabilities:
            TorrentEngineIPCLimits.maximumBookmarkAggregateBytes
                + TorrentEngineLimits.maximumAuthorizedSavePathCount * 1_024
        case .grantFolderCapability:
            TorrentEngineIPCLimits.maximumBookmarkBytes + 16 * 1_024
        case .addTorrentFile:
            TorrentEngineIPCLimits.maximumPayloadBytes
        case .previewTorrentFile:
            TorrentInputLimits.maxTorrentFileBytes
        case .poll, .readDataset, .closeDataset,
             .beginStateMigration, .importStateMigrationFile,
             .commitStateMigration, .abortStateMigration, .changeHint:
            64 * 1_024
        default:
            2 * 1_024 * 1_024
        }
    }

    package var maximumReplyPayloadBytes: Int {
        switch self {
        case .previewTorrentFile:
            TorrentEngineIPCLimits.maximumFileMetadataReplyBytes
        case .trackerBatch, .webSeedBatch, .pieceMapBatch:
            16 * 1_024 * 1_024
        case .fileBatch:
            TorrentEngineIPCLimits.maximumFileMetadataReplyBytes
        case .readDataset:
            TorrentEngineIPCLimits.maximumDatasetPageBytes + 64 * 1_024
        case .handshake, .replaceFolderCapabilities:
            TorrentEngineIPCLimits.maximumFolderCapabilityReplyBytes
        default:
            2 * 1_024 * 1_024
        }
    }

    package var propertyListDecodingLimits: TorrentEngineIPCPropertyListDecodingLimits {
        switch self {
        case .poll:
            .init(
                maximumContainerElementCount: TorrentEngineLimits.maximumNetworkInterfaceCount,
                maximumCollectionReferenceCount: 8 * 1_024
            )
        case .handshake, .replaceFolderCapabilities:
            .init(
                maximumContainerElementCount: TorrentEngineLimits.maximumAuthorizedSavePathCount,
                maximumCollectionReferenceCount: 128 * 1_024
            )
        case .addTorrentFile, .previewTorrentFile, .fileBatch:
            .init(
                maximumContainerElementCount: TorrentEngineLimits.maximumFileCount,
                maximumCollectionReferenceCount: 512 * 1_024
            )
        case .trackerBatch:
            .init(
                maximumContainerElementCount: TorrentEngineLimits.maximumTrackerCount,
                maximumCollectionReferenceCount: 128 * 1_024
            )
        case .webSeedBatch:
            .init(
                maximumContainerElementCount: TorrentEngineLimits.maximumWebSeedCount,
                maximumCollectionReferenceCount: 128 * 1_024
            )
        case .pieceMapBatch:
            .init(
                maximumContainerElementCount: TorrentEngineLimits.maximumPieceMapCount,
                maximumCollectionReferenceCount: TorrentEngineLimits.maximumPieceMapCount
                    + 64 * 1_024
            )
        default:
            .standard
        }
    }
}

package enum TorrentEngineIPCReplyStatus: UInt64, Sendable {
    case success = 0
    case failure = 1
}

package enum TorrentEngineIPCFailureCode: UInt64, Sendable {
    case operationRejected = 1
    case controllerBusy = 2
    case serviceShuttingDown = 3
}

package struct TorrentEngineIPCHeader: Equatable, Sendable {
    package let requestID: UUID
    package let controllerID: UUID
    package let sequence: UInt64
    package let operation: TorrentEngineIPCOperation
    package let operationID: UUID
    package let expectedEpoch: UUID?

    package init(
        requestID: UUID,
        controllerID: UUID,
        sequence: UInt64,
        operation: TorrentEngineIPCOperation,
        operationID: UUID,
        expectedEpoch: UUID?
    ) {
        self.requestID = requestID
        self.controllerID = controllerID
        self.sequence = sequence
        self.operation = operation
        self.operationID = operationID
        self.expectedEpoch = expectedEpoch
    }
}

/// The receiver owns `fileDescriptor` and must close it exactly once.
package struct TorrentEngineIPCRequest: Equatable, Sendable {
    package let header: TorrentEngineIPCHeader
    package let payload: Data?
    package let fileDescriptor: Int32?

    package init(
        header: TorrentEngineIPCHeader,
        payload: Data? = nil,
        fileDescriptor: Int32? = nil
    ) {
        self.header = header
        self.payload = payload
        self.fileDescriptor = fileDescriptor
    }
}

package struct TorrentEngineIPCReply: Equatable, Sendable {
    package let header: TorrentEngineIPCHeader
    package let engineEpoch: UUID
    package let status: TorrentEngineIPCReplyStatus
    package let failureCode: TorrentEngineIPCFailureCode?
    package let errorMessage: String?
    package let payload: Data?

    package init(
        header: TorrentEngineIPCHeader,
        engineEpoch: UUID,
        status: TorrentEngineIPCReplyStatus,
        failureCode: TorrentEngineIPCFailureCode? = nil,
        errorMessage: String? = nil,
        payload: Data? = nil
    ) {
        self.header = header
        self.engineEpoch = engineEpoch
        self.status = status
        self.failureCode = status == .failure
            ? failureCode ?? .operationRejected
            : failureCode
        self.errorMessage = errorMessage
        self.payload = payload
    }
}

package enum TorrentEngineIPCError: Error, Equatable, Sendable {
    case unexpectedField(String)
    case missingField(String)
    case wrongFieldType(field: String, expected: String)
    case unsupportedProtocolVersion(UInt64)
    case unknownOperation(UInt64)
    case unknownReplyStatus(UInt64)
    case unknownFailureCode(UInt64)
    case invalidUUID(field: String)
    case invalidSequence(UInt64)
    case invalidMaximumPayloadSize(Int)
    case payloadTooLarge(actual: Int, maximum: Int)
    case errorMessageEmpty
    case errorMessageContainsNull
    case errorMessageTooLarge(actual: Int, maximum: Int)
    case unexpectedErrorMessage
    case missingErrorMessage
    case unexpectedFailureCode
    case missingFailureCode
    case invalidFileDescriptor
    case fileDescriptorBoxingFailed
    case fileDescriptorDuplicationFailed
    case requestMetadataMismatch
    case propertyListEncodingFailed
    case propertyListDecodingFailed
}
