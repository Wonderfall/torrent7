import Foundation

package enum TorrentEngineIPCProtocol {
    package static let version: UInt64 = 1
}

package enum TorrentEngineIPCLimits {
    package static let maximumPayloadBytes = 64 * 1_024 * 1_024
    package static let maximumErrorBytes = 4 * 1_024
}

package enum TorrentEngineIPCOperation: UInt64, CaseIterable, Sendable {
    case handshake = 1
    case restart = 2
    case shutdown = 3
    case poll = 4
    case grantFolderCapability = 5
    case revokeFolderCapability = 6

    case inspectMagnet = 10
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
    case trackerHostBatch = 41
    case webSeedBatch = 42
    case webSeedActivity = 43
    case peerSources = 44
    case fileBatch = 45
    case pieceMapBatch = 46

    case openDataset = 50
    case readDataset = 51
    case closeDataset = 52

    case beginStateMigration = 60
    case importStateMigrationFile = 61
    case commitStateMigration = 62
    case abortStateMigration = 63

    case changeHint = 100
}

package enum TorrentEngineIPCReplyStatus: UInt64, Sendable {
    case success = 0
    case failure = 1
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

/// The receiver owns `fileDescriptor` and must close it exactly once.
package struct TorrentEngineIPCReply: Equatable, Sendable {
    package let header: TorrentEngineIPCHeader
    package let engineEpoch: UUID
    package let status: TorrentEngineIPCReplyStatus
    package let errorMessage: String?
    package let payload: Data?
    package let fileDescriptor: Int32?

    package init(
        header: TorrentEngineIPCHeader,
        engineEpoch: UUID,
        status: TorrentEngineIPCReplyStatus,
        errorMessage: String? = nil,
        payload: Data? = nil,
        fileDescriptor: Int32? = nil
    ) {
        self.header = header
        self.engineEpoch = engineEpoch
        self.status = status
        self.errorMessage = errorMessage
        self.payload = payload
        self.fileDescriptor = fileDescriptor
    }
}

package enum TorrentEngineIPCError: Error, Equatable, Sendable {
    case unexpectedField(String)
    case missingField(String)
    case wrongFieldType(field: String, expected: String)
    case unsupportedProtocolVersion(UInt64)
    case unknownOperation(UInt64)
    case unknownReplyStatus(UInt64)
    case invalidUUID(field: String)
    case invalidSequence(UInt64)
    case invalidMaximumPayloadSize(Int)
    case payloadTooLarge(actual: Int, maximum: Int)
    case errorMessageEmpty
    case errorMessageContainsNull
    case errorMessageTooLarge(actual: Int, maximum: Int)
    case unexpectedErrorMessage
    case missingErrorMessage
    case invalidFileDescriptor
    case fileDescriptorBoxingFailed
    case fileDescriptorDuplicationFailed
    case propertyListEncodingFailed
    case propertyListDecodingFailed
}
