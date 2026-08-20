import Foundation
import TorrentEngineModel

package enum TorrentEngineIPCProtocol {
    package static let version: UInt64 = 9
}

package enum TorrentEngineIPCLimits {
    // A request may carry a bounded JSON payload and a separately bounded raw
    // attachment. Their combined wire size must fit this admission limit.
    package static let maximumPayloadBytes = 66 * 1_024 * 1_024
    package static let maximumSmallPayloadBytes = 64 * 1_024
    package static let maximumErrorBytes = 4 * 1_024
    package static let maximumBookmarkBytes = 1 * 1_024 * 1_024
    package static let maximumBookmarkAggregateBytes = 20 * 1_024 * 1_024
    // Base64 is four-thirds the source size. The fixed allowance covers JSON
    // keys and independent padding for every authorized folder.
    package static let maximumBookmarkJSONPayloadBytes =
        ((maximumBookmarkAggregateBytes + 2) / 3) * 4 + 64 * 1_024
    package static let maximumSingleBookmarkJSONPayloadBytes =
        ((maximumBookmarkBytes + 2) / 3) * 4 + 16 * 1_024
    package static let maximumDatasetPageBytes = 1 * 1_024 * 1_024
    package static let maximumDatasetPageJSONReplyBytes =
        ((maximumDatasetPageBytes + 2) / 3) * 4 + 64 * 1_024
    package static let maximumDatasetPageItemCount = 256
    package static let maximumJSONNestingDepthLimit = 32
    package static let maximumJSONValueNodeCountLimit = 384 * 1_024
    package static let maximumJSONStringByteCountLimit =
        ((maximumBookmarkBytes + 2) / 3) * 4
    package static let maximumJSONPrimitiveByteCountLimit = 128

    package static let smallJSONLimits = TorrentEngineIPCJSONLimits(
        maximumNestingDepth: 8,
        maximumValueNodeCount: 256,
        maximumStringByteCount: 8 * 1_024,
        maximumPrimitiveByteCount: maximumJSONPrimitiveByteCountLimit
    )
    package static let folderCapabilityRequestJSONLimits = TorrentEngineIPCJSONLimits(
        maximumNestingDepth: 6,
        maximumValueNodeCount: 256,
        maximumStringByteCount: maximumJSONStringByteCountLimit,
        maximumPrimitiveByteCount: maximumJSONPrimitiveByteCountLimit
    )
    package static let magnetRequestJSONLimits = TorrentEngineIPCJSONLimits(
        maximumNestingDepth: 8,
        maximumValueNodeCount: 256,
        maximumStringByteCount: TorrentInputLimits.maxMagnetURIBytes * 6,
        maximumPrimitiveByteCount: maximumJSONPrimitiveByteCountLimit
    )
    package static let settingsRequestJSONLimits = TorrentEngineIPCJSONLimits(
        maximumNestingDepth: 8,
        maximumValueNodeCount: 256,
        maximumStringByteCount: 128 * 1_024,
        maximumPrimitiveByteCount: maximumJSONPrimitiveByteCountLimit
    )
    package static let filePriorityRequestJSONLimits = TorrentEngineIPCJSONLimits(
        maximumNestingDepth: 8,
        maximumValueNodeCount: 128 * 1_024,
        maximumStringByteCount: 8 * 1_024,
        maximumPrimitiveByteCount: maximumJSONPrimitiveByteCountLimit
    )
    package static let pollReplyJSONLimits = TorrentEngineIPCJSONLimits(
        maximumNestingDepth: 8,
        maximumValueNodeCount: 2 * 1_024,
        maximumStringByteCount: 128 * 1_024,
        maximumPrimitiveByteCount: maximumJSONPrimitiveByteCountLimit
    )
    package static let datasetPageJSONLimits = TorrentEngineIPCJSONLimits(
        maximumNestingDepth: 8,
        maximumValueNodeCount: 32 * 1_024,
        maximumStringByteCount: 8 * 1_024,
        maximumPrimitiveByteCount: maximumJSONPrimitiveByteCountLimit
    )
    package static let datasetPageEnvelopeJSONLimits = TorrentEngineIPCJSONLimits(
        maximumNestingDepth: 6,
        maximumValueNodeCount: 256,
        maximumStringByteCount: ((maximumDatasetPageBytes + 2) / 3) * 4,
        maximumPrimitiveByteCount: maximumJSONPrimitiveByteCountLimit
    )
    package static let fileMetadataReplyJSONLimits = TorrentEngineIPCJSONLimits(
        maximumNestingDepth: 8,
        maximumValueNodeCount: 320 * 1_024,
        maximumStringByteCount: 8 * 1_024,
        maximumPrimitiveByteCount: maximumJSONPrimitiveByteCountLimit
    )
    package static let trackerReplyJSONLimits = TorrentEngineIPCJSONLimits(
        maximumNestingDepth: 8,
        maximumValueNodeCount: 64 * 1_024,
        maximumStringByteCount: 8 * 1_024,
        maximumPrimitiveByteCount: maximumJSONPrimitiveByteCountLimit
    )
    package static let webSeedReplyJSONLimits = TorrentEngineIPCJSONLimits(
        maximumNestingDepth: 8,
        maximumValueNodeCount: 8 * 1_024,
        maximumStringByteCount: 8 * 1_024,
        maximumPrimitiveByteCount: maximumJSONPrimitiveByteCountLimit
    )
    package static let pieceMapReplyJSONLimits = TorrentEngineIPCJSONLimits(
        maximumNestingDepth: 8,
        maximumValueNodeCount: 256,
        maximumStringByteCount:
            (((TorrentEngineLimits.maximumPieceMapCount + 7) / 8 + 2) / 3) * 4,
        maximumPrimitiveByteCount: maximumJSONPrimitiveByteCountLimit
    )
    package static let maximumJSONLimits = TorrentEngineIPCJSONLimits(
        maximumNestingDepth: maximumJSONNestingDepthLimit,
        maximumValueNodeCount: maximumJSONValueNodeCountLimit,
        maximumStringByteCount: maximumJSONStringByteCountLimit,
        maximumPrimitiveByteCount: maximumJSONPrimitiveByteCountLimit
    )

    package static let maximumMagnetRequestBytes = 512 * 1_024
    package static let maximumSettingsRequestBytes = 128 * 1_024
    package static let maximumFilePriorityRequestBytes = 1 * 1_024 * 1_024
    package static let maximumPollReplyBytes = 4 * 1_024 * 1_024
    package static let maximumTrackerReplyBytes = 8 * 1_024 * 1_024
    package static let maximumWebSeedReplyBytes = 8 * 1_024 * 1_024
    package static let maximumPieceMapReplyBytes = 1 * 1_024 * 1_024
    // Dataset pages are fetched serially. Bound the number independently of
    // item count so a hostile descriptor cannot amplify one poll into tens of
    // thousands of XPC round trips.
    package static let maximumDatasetPageCount = 256
    // This is an intentional storage quota across open encoded datasets, not
    // a promise that every Cartesian product of item and string maxima fits.
    package static let maximumDatasetAggregateBytes = 128 * 1_024 * 1_024
    package static let maximumFileMetadataReplyBytes = 48 * 1_024 * 1_024
    package static let maximumFolderCapabilityReplyBytes = 256 * 1_024
    package static let maximumOpenDatasets = 4
    package static let maximumAlertErrorsPerPoll = 16
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

    case changeHint = 100

    package var maximumRequestPayloadBytes: Int {
        switch self {
        case .handshake, .replaceFolderCapabilities:
            TorrentEngineIPCLimits.maximumBookmarkJSONPayloadBytes
        case .grantFolderCapability:
            TorrentEngineIPCLimits.maximumSingleBookmarkJSONPayloadBytes
        case .previewTorrentFile:
            0
        case .addMagnet:
            TorrentEngineIPCLimits.maximumMagnetRequestBytes
        case .addTorrentFile:
            TorrentEngineIPCLimits.maximumFilePriorityRequestBytes
        case .applySettings:
            TorrentEngineIPCLimits.maximumSettingsRequestBytes
        default:
            TorrentEngineIPCLimits.maximumSmallPayloadBytes
        }
    }

    package var maximumRequestAttachmentBytes: Int {
        switch self {
        case .previewTorrentFile, .addTorrentFile:
            TorrentInputLimits.maxTorrentFileBytes
        default:
            0
        }
    }

    package var requestJSONLimits: TorrentEngineIPCJSONLimits {
        switch self {
        case .handshake, .grantFolderCapability, .replaceFolderCapabilities:
            TorrentEngineIPCLimits.folderCapabilityRequestJSONLimits
        case .addMagnet:
            TorrentEngineIPCLimits.magnetRequestJSONLimits
        case .addTorrentFile:
            TorrentEngineIPCLimits.filePriorityRequestJSONLimits
        case .applySettings:
            TorrentEngineIPCLimits.settingsRequestJSONLimits
        default:
            TorrentEngineIPCLimits.smallJSONLimits
        }
    }

    package var replyJSONLimits: TorrentEngineIPCJSONLimits {
        switch self {
        case .previewTorrentFile, .fileBatch:
            TorrentEngineIPCLimits.fileMetadataReplyJSONLimits
        case .poll:
            TorrentEngineIPCLimits.pollReplyJSONLimits
        case .trackerBatch:
            TorrentEngineIPCLimits.trackerReplyJSONLimits
        case .webSeedBatch:
            TorrentEngineIPCLimits.webSeedReplyJSONLimits
        case .pieceMapBatch:
            TorrentEngineIPCLimits.pieceMapReplyJSONLimits
        case .readDataset:
            TorrentEngineIPCLimits.datasetPageEnvelopeJSONLimits
        default:
            TorrentEngineIPCLimits.smallJSONLimits
        }
    }

    package var maximumReplyPayloadBytes: Int {
        switch self {
        case .previewTorrentFile:
            TorrentEngineIPCLimits.maximumFileMetadataReplyBytes
        case .poll:
            TorrentEngineIPCLimits.maximumPollReplyBytes
        case .trackerBatch:
            TorrentEngineIPCLimits.maximumTrackerReplyBytes
        case .webSeedBatch:
            TorrentEngineIPCLimits.maximumWebSeedReplyBytes
        case .pieceMapBatch:
            TorrentEngineIPCLimits.maximumPieceMapReplyBytes
        case .fileBatch:
            TorrentEngineIPCLimits.maximumFileMetadataReplyBytes
        case .readDataset:
            TorrentEngineIPCLimits.maximumDatasetPageJSONReplyBytes
        case .handshake, .replaceFolderCapabilities:
            TorrentEngineIPCLimits.maximumFolderCapabilityReplyBytes
        default:
            TorrentEngineIPCLimits.maximumSmallPayloadBytes
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

package struct TorrentEngineIPCRequest: Equatable, Sendable {
    package let header: TorrentEngineIPCHeader
    package let payload: Data?
    package let attachment: Data?

    package init(
        header: TorrentEngineIPCHeader,
        payload: Data? = nil,
        attachment: Data? = nil
    ) {
        self.header = header
        self.payload = payload
        self.attachment = attachment
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
    case requestMetadataMismatch
    case jsonEncodingFailed
    case jsonDecodingFailed
}
