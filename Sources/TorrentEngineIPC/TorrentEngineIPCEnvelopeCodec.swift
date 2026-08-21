import Foundation
import XPC

package enum TorrentEngineIPCField {
    package static let version = "version"
    package static let requestID = "requestID"
    package static let controllerID = "controllerID"
    package static let sequence = "sequence"
    package static let operation = "operation"
    package static let operationID = "operationID"
    package static let expectedEpoch = "expectedEpoch"
    package static let engineEpoch = "engineEpoch"
    package static let status = "status"
    package static let failureCode = "failureCode"
    package static let errorMessage = "error"
    package static let payload = "payload"
    package static let attachment = "attachment"
    package static let brokerEndpoint = "brokerEndpoint"
}

package struct TorrentEngineIPCRequestMetadata: Equatable, Sendable {
    package let header: TorrentEngineIPCHeader
    package let hasPayload: Bool
    package let payloadByteCount: Int
    package let hasAttachment: Bool
    package let attachmentByteCount: Int
    package let brokerEndpoint: XPCEndpoint?
    package let totalByteCount: Int

    package init(
        header: TorrentEngineIPCHeader,
        hasPayload: Bool,
        payloadByteCount: Int,
        hasAttachment: Bool,
        attachmentByteCount: Int,
        brokerEndpoint: XPCEndpoint? = nil,
        totalByteCount: Int
    ) {
        self.header = header
        self.hasPayload = hasPayload
        self.payloadByteCount = payloadByteCount
        self.hasAttachment = hasAttachment
        self.attachmentByteCount = attachmentByteCount
        self.brokerEndpoint = brokerEndpoint
        self.totalByteCount = totalByteCount
    }
}

package enum TorrentEngineIPCEnvelopeCodec {
    private static let commonFields: Set<String> = [
        TorrentEngineIPCField.version,
        TorrentEngineIPCField.requestID,
        TorrentEngineIPCField.controllerID,
        TorrentEngineIPCField.sequence,
        TorrentEngineIPCField.operation,
        TorrentEngineIPCField.operationID,
        TorrentEngineIPCField.expectedEpoch,
        TorrentEngineIPCField.payload,
    ]

    private static let requestFields = commonFields.union([
        TorrentEngineIPCField.attachment,
        TorrentEngineIPCField.brokerEndpoint,
    ])
    private static let replyFields = commonFields.union([
        TorrentEngineIPCField.engineEpoch,
        TorrentEngineIPCField.status,
        TorrentEngineIPCField.failureCode,
        TorrentEngineIPCField.errorMessage,
    ])

    package static func encode(
        _ request: TorrentEngineIPCRequest,
        maximumPayloadBytes: Int,
        maximumAttachmentBytes: Int = 0
    ) throws -> XPCDictionary {
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumPayloadBytes)
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumAttachmentBytes)
        try validate(request.header)
        try validateRequestResources(
            hasPayload: request.payload != nil,
            payloadByteCount: request.payload?.count ?? 0,
            maximumPayloadBytes: maximumPayloadBytes,
            hasAttachment: request.attachment != nil,
            attachmentByteCount: request.attachment?.count ?? 0,
            maximumAttachmentBytes: maximumAttachmentBytes
        )
        try validateBrokerEndpoint(
            request.brokerEndpoint,
            for: request.header.operation
        )

        var dictionary = encodeHeader(request.header)
        try TorrentEngineIPCXPCValues.insertPayload(
            request.payload,
            into: &dictionary,
            maximumBytes: maximumPayloadBytes
        )
        try TorrentEngineIPCXPCValues.insertPayload(
            request.attachment,
            into: &dictionary,
            maximumBytes: maximumAttachmentBytes,
            field: TorrentEngineIPCField.attachment
        )
        if let brokerEndpoint = request.brokerEndpoint {
            dictionary[TorrentEngineIPCField.brokerEndpoint] = brokerEndpoint
        }
        return dictionary
    }

    package static func decodeRequest(
        _ dictionary: XPCDictionary,
        maximumPayloadBytes: Int,
        maximumAttachmentBytes: Int = 0
    ) throws -> TorrentEngineIPCRequest {
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumPayloadBytes)
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumAttachmentBytes)
        let metadata = try inspectRequest(dictionary)
        try validateRequestResources(
            metadata,
            maximumPayloadBytes: maximumPayloadBytes,
            maximumAttachmentBytes: maximumAttachmentBytes
        )
        return try decodeRequest(
            dictionary,
            metadata: metadata,
            maximumPayloadBytes: maximumPayloadBytes,
            maximumAttachmentBytes: maximumAttachmentBytes
        )
    }

    /// Validates the request envelope and reads only fixed-size header fields and
    /// XPC object metadata. Payload resources are not copied.
    package static func inspectRequest(
        _ dictionary: XPCDictionary
    ) throws -> TorrentEngineIPCRequestMetadata {
        try validateAllowedFields(in: dictionary, allowed: requestFields)
        let header = try decodeHeader(dictionary)
        let payloadByteCount = try TorrentEngineIPCXPCValues.payloadByteCount(
            in: dictionary
        )
        let attachmentByteCount = try TorrentEngineIPCXPCValues.payloadByteCount(
            in: dictionary,
            field: TorrentEngineIPCField.attachment
        )
        let endpointFieldIsPresent = dictionary.keys.contains(
            TorrentEngineIPCField.brokerEndpoint
        )
        let brokerEndpoint = dictionary[
            TorrentEngineIPCField.brokerEndpoint,
            as: XPCEndpoint.self
        ]
        guard !endpointFieldIsPresent || brokerEndpoint != nil else {
            throw TorrentEngineIPCError.wrongFieldType(
                field: TorrentEngineIPCField.brokerEndpoint,
                expected: "endpoint"
            )
        }
        try validateBrokerEndpoint(brokerEndpoint, for: header.operation)
        let totalByteCount = try requestTotalByteCount(
            payloadByteCount: payloadByteCount,
            attachmentByteCount: attachmentByteCount
        )
        return TorrentEngineIPCRequestMetadata(
            header: header,
            hasPayload: dictionary.keys.contains(TorrentEngineIPCField.payload),
            payloadByteCount: payloadByteCount,
            hasAttachment: dictionary.keys.contains(TorrentEngineIPCField.attachment),
            attachmentByteCount: attachmentByteCount,
            brokerEndpoint: brokerEndpoint,
            totalByteCount: totalByteCount
        )
    }

    /// Copies resources only after a caller has admitted the inspected request.
    package static func decodeRequest(
        _ dictionary: XPCDictionary,
        metadata: TorrentEngineIPCRequestMetadata,
        maximumPayloadBytes: Int,
        maximumAttachmentBytes: Int = 0
    ) throws -> TorrentEngineIPCRequest {
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumPayloadBytes)
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumAttachmentBytes)
        guard try inspectRequest(dictionary) == metadata else {
            throw TorrentEngineIPCError.requestMetadataMismatch
        }
        try validateRequestResources(
            metadata,
            maximumPayloadBytes: maximumPayloadBytes,
            maximumAttachmentBytes: maximumAttachmentBytes
        )
        let payload = try TorrentEngineIPCXPCValues.copyPayload(
            from: dictionary,
            maximumBytes: maximumPayloadBytes
        )
        let attachment = try TorrentEngineIPCXPCValues.copyPayload(
            from: dictionary,
            maximumBytes: maximumAttachmentBytes,
            field: TorrentEngineIPCField.attachment
        )
        return TorrentEngineIPCRequest(
            header: metadata.header,
            payload: payload,
            attachment: attachment,
            brokerEndpoint: metadata.brokerEndpoint
        )
    }

    package static func encode(
        _ reply: TorrentEngineIPCReply,
        maximumPayloadBytes: Int
    ) throws -> XPCDictionary {
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumPayloadBytes)
        try validate(reply.header)
        try validateReplyError(
            status: reply.status,
            failureCode: reply.failureCode,
            message: reply.errorMessage
        )

        var dictionary = encodeHeader(reply.header)
        dictionary[TorrentEngineIPCField.engineEpoch] = reply.engineEpoch.uuidString
        dictionary[TorrentEngineIPCField.status] = reply.status.rawValue
        if let failureCode = reply.failureCode {
            dictionary[TorrentEngineIPCField.failureCode] = failureCode.rawValue
        }
        if let errorMessage = reply.errorMessage {
            dictionary[TorrentEngineIPCField.errorMessage] = errorMessage
        }
        try TorrentEngineIPCXPCValues.insertPayload(
            reply.payload,
            into: &dictionary,
            maximumBytes: maximumPayloadBytes
        )
        return dictionary
    }

    package static func decodeReply(
        _ dictionary: XPCDictionary,
        maximumPayloadBytes: Int
    ) throws -> TorrentEngineIPCReply {
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumPayloadBytes)
        try validateAllowedFields(in: dictionary, allowed: replyFields)

        let header = try decodeHeader(dictionary)
        let engineEpoch = try requiredUUID(
            TorrentEngineIPCField.engineEpoch,
            in: dictionary
        )
        let statusValue = try requiredUInt64(
            TorrentEngineIPCField.status,
            in: dictionary
        )
        guard let status = TorrentEngineIPCReplyStatus(rawValue: statusValue) else {
            throw TorrentEngineIPCError.unknownReplyStatus(statusValue)
        }
        let failureCodeValue = try optionalUInt64(
            TorrentEngineIPCField.failureCode,
            in: dictionary
        )
        let failureCode: TorrentEngineIPCFailureCode?
        if let failureCodeValue {
            guard let decoded = TorrentEngineIPCFailureCode(rawValue: failureCodeValue) else {
                throw TorrentEngineIPCError.unknownFailureCode(failureCodeValue)
            }
            failureCode = decoded
        } else {
            failureCode = nil
        }
        let errorMessage = try optionalString(
            TorrentEngineIPCField.errorMessage,
            in: dictionary
        )
        try validateReplyError(
            status: status,
            failureCode: failureCode,
            message: errorMessage
        )

        let payload = try TorrentEngineIPCXPCValues.copyPayload(
            from: dictionary,
            maximumBytes: maximumPayloadBytes
        )
        return TorrentEngineIPCReply(
            header: header,
            engineEpoch: engineEpoch,
            status: status,
            failureCode: failureCode,
            errorMessage: errorMessage,
            payload: payload
        )
    }

    private static func validateRequestResources(
        _ metadata: TorrentEngineIPCRequestMetadata,
        maximumPayloadBytes: Int,
        maximumAttachmentBytes: Int
    ) throws {
        try validateRequestResources(
            hasPayload: metadata.hasPayload,
            payloadByteCount: metadata.payloadByteCount,
            maximumPayloadBytes: maximumPayloadBytes,
            hasAttachment: metadata.hasAttachment,
            attachmentByteCount: metadata.attachmentByteCount,
            maximumAttachmentBytes: maximumAttachmentBytes
        )
        let totalByteCount = try requestTotalByteCount(
            payloadByteCount: metadata.payloadByteCount,
            attachmentByteCount: metadata.attachmentByteCount
        )
        guard metadata.totalByteCount == totalByteCount else {
            throw TorrentEngineIPCError.requestMetadataMismatch
        }
    }

    private static func validateBrokerEndpoint(
        _ endpoint: XPCEndpoint?,
        for operation: TorrentEngineIPCOperation
    ) throws {
        switch operation {
        case .handshake:
            guard endpoint != nil else {
                throw TorrentEngineIPCError.missingField(
                    TorrentEngineIPCField.brokerEndpoint
                )
            }
        default:
            guard endpoint == nil else {
                throw TorrentEngineIPCError.unexpectedField(
                    TorrentEngineIPCField.brokerEndpoint
                )
            }
        }
    }

    private static func validateRequestResources(
        hasPayload: Bool,
        payloadByteCount: Int,
        maximumPayloadBytes: Int,
        hasAttachment: Bool,
        attachmentByteCount: Int,
        maximumAttachmentBytes: Int
    ) throws {
        if hasPayload && maximumPayloadBytes == 0 {
            throw TorrentEngineIPCError.unexpectedField(TorrentEngineIPCField.payload)
        }
        if hasAttachment && maximumAttachmentBytes == 0 {
            throw TorrentEngineIPCError.unexpectedField(TorrentEngineIPCField.attachment)
        }
        guard payloadByteCount <= maximumPayloadBytes else {
            throw TorrentEngineIPCError.payloadTooLarge(
                actual: payloadByteCount,
                maximum: maximumPayloadBytes
            )
        }
        guard attachmentByteCount <= maximumAttachmentBytes else {
            throw TorrentEngineIPCError.payloadTooLarge(
                actual: attachmentByteCount,
                maximum: maximumAttachmentBytes
            )
        }
        _ = try requestTotalByteCount(
            payloadByteCount: payloadByteCount,
            attachmentByteCount: attachmentByteCount
        )
    }

    private static func requestTotalByteCount(
        payloadByteCount: Int,
        attachmentByteCount: Int
    ) throws -> Int {
        let sum = payloadByteCount.addingReportingOverflow(attachmentByteCount)
        guard payloadByteCount >= 0,
              attachmentByteCount >= 0,
              !sum.overflow,
              sum.partialValue <= TorrentEngineIPCLimits.maximumPayloadBytes else {
            throw TorrentEngineIPCError.payloadTooLarge(
                actual: sum.overflow ? Int.max : sum.partialValue,
                maximum: TorrentEngineIPCLimits.maximumPayloadBytes
            )
        }
        return sum.partialValue
    }

    private static func encodeHeader(_ header: TorrentEngineIPCHeader) -> XPCDictionary {
        var dictionary = XPCDictionary()
        dictionary[TorrentEngineIPCField.version] = TorrentEngineIPCProtocol.version
        dictionary[TorrentEngineIPCField.requestID] = header.requestID.uuidString
        dictionary[TorrentEngineIPCField.controllerID] = header.controllerID.uuidString
        dictionary[TorrentEngineIPCField.sequence] = header.sequence
        dictionary[TorrentEngineIPCField.operation] = header.operation.rawValue
        dictionary[TorrentEngineIPCField.operationID] = header.operationID.uuidString
        if let expectedEpoch = header.expectedEpoch {
            dictionary[TorrentEngineIPCField.expectedEpoch] = expectedEpoch.uuidString
        }
        return dictionary
    }

    private static func decodeHeader(
        _ dictionary: XPCDictionary
    ) throws -> TorrentEngineIPCHeader {
        let version = try requiredUInt64(TorrentEngineIPCField.version, in: dictionary)
        guard version == TorrentEngineIPCProtocol.version else {
            throw TorrentEngineIPCError.unsupportedProtocolVersion(version)
        }

        let sequence = try requiredUInt64(TorrentEngineIPCField.sequence, in: dictionary)
        guard sequence > 0 else {
            throw TorrentEngineIPCError.invalidSequence(sequence)
        }

        let operationValue = try requiredUInt64(
            TorrentEngineIPCField.operation,
            in: dictionary
        )
        guard let operation = TorrentEngineIPCOperation(rawValue: operationValue) else {
            throw TorrentEngineIPCError.unknownOperation(operationValue)
        }

        return try TorrentEngineIPCHeader(
            requestID: requiredUUID(TorrentEngineIPCField.requestID, in: dictionary),
            controllerID: requiredUUID(TorrentEngineIPCField.controllerID, in: dictionary),
            sequence: sequence,
            operation: operation,
            operationID: requiredUUID(TorrentEngineIPCField.operationID, in: dictionary),
            expectedEpoch: optionalUUID(TorrentEngineIPCField.expectedEpoch, in: dictionary)
        )
    }

    private static func validate(_ header: TorrentEngineIPCHeader) throws {
        guard header.sequence > 0 else {
            throw TorrentEngineIPCError.invalidSequence(header.sequence)
        }
    }

    private static func validateAllowedFields(
        in dictionary: XPCDictionary,
        allowed: Set<String>
    ) throws {
        if let field = dictionary.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw TorrentEngineIPCError.unexpectedField(field)
        }
    }

    private static func requiredUInt64(
        _ field: String,
        in dictionary: XPCDictionary
    ) throws -> UInt64 {
        guard dictionary.keys.contains(field) else {
            throw TorrentEngineIPCError.missingField(field)
        }
        guard let object = unsafe dictionary[field, as: XPC_TYPE_UINT64] else {
            throw TorrentEngineIPCError.wrongFieldType(field: field, expected: "uint64")
        }
        return xpc_uint64_get_value(object)
    }

    private static func optionalUInt64(
        _ field: String,
        in dictionary: XPCDictionary
    ) throws -> UInt64? {
        guard dictionary.keys.contains(field) else {
            return nil
        }
        return try requiredUInt64(field, in: dictionary)
    }

    private static func requiredString(
        _ field: String,
        in dictionary: XPCDictionary
    ) throws -> String {
        guard dictionary.keys.contains(field) else {
            throw TorrentEngineIPCError.missingField(field)
        }
        guard unsafe dictionary[field, as: XPC_TYPE_STRING] != nil,
              let value = dictionary[field, as: String.self] else {
            throw TorrentEngineIPCError.wrongFieldType(field: field, expected: "string")
        }
        return value
    }

    private static func optionalString(
        _ field: String,
        in dictionary: XPCDictionary
    ) throws -> String? {
        guard dictionary.keys.contains(field) else {
            return nil
        }
        return try requiredString(field, in: dictionary)
    }

    private static func requiredUUID(
        _ field: String,
        in dictionary: XPCDictionary
    ) throws -> UUID {
        let value = try requiredString(field, in: dictionary)
        return try parseUUID(value, field: field)
    }

    private static func optionalUUID(
        _ field: String,
        in dictionary: XPCDictionary
    ) throws -> UUID? {
        guard let value = try optionalString(field, in: dictionary) else {
            return nil
        }
        return try parseUUID(value, field: field)
    }

    private static func parseUUID(_ value: String, field: String) throws -> UUID {
        guard value.utf8.count == 36,
              !value.contains("\0"),
              let uuid = UUID(uuidString: value),
              uuid.uuidString == value.uppercased() else {
            throw TorrentEngineIPCError.invalidUUID(field: field)
        }
        return uuid
    }

    private static func validateReplyError(
        status: TorrentEngineIPCReplyStatus,
        failureCode: TorrentEngineIPCFailureCode?,
        message: String?
    ) throws {
        switch (status, failureCode, message) {
        case (.success, nil, nil):
            return
        case (.success, .some, _):
            throw TorrentEngineIPCError.unexpectedFailureCode
        case (.success, nil, .some):
            throw TorrentEngineIPCError.unexpectedErrorMessage
        case (.failure, nil, _):
            throw TorrentEngineIPCError.missingFailureCode
        case (.failure, .some, nil):
            throw TorrentEngineIPCError.missingErrorMessage
        case (.failure, .some, let message?):
            guard !message.isEmpty else {
                throw TorrentEngineIPCError.errorMessageEmpty
            }
            guard !message.contains("\0") else {
                throw TorrentEngineIPCError.errorMessageContainsNull
            }
            let byteCount = message.utf8.count
            guard byteCount <= TorrentEngineIPCLimits.maximumErrorBytes else {
                throw TorrentEngineIPCError.errorMessageTooLarge(
                    actual: byteCount,
                    maximum: TorrentEngineIPCLimits.maximumErrorBytes
                )
            }
        }
    }
}

package enum TorrentEngineIPCXPCValues {
    package static func payloadByteCount(
        in dictionary: XPCDictionary,
        field: String = TorrentEngineIPCField.payload
    ) throws -> Int {
        guard dictionary.keys.contains(field) else {
            return 0
        }
        guard let object = unsafe dictionary[field, as: XPC_TYPE_DATA] else {
            throw TorrentEngineIPCError.wrongFieldType(field: field, expected: "data")
        }
        return xpc_data_get_length(object)
    }

    package static func insertPayload(
        _ payload: Data?,
        into dictionary: inout XPCDictionary,
        maximumBytes: Int,
        field: String = TorrentEngineIPCField.payload
    ) throws {
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumBytes)
        guard let payload else {
            return
        }
        try TorrentEngineIPCPayloadBounds.validate(payload, maximumBytes: maximumBytes)
        let object = unsafe payload.withUnsafeBytes { bytes in
            unsafe xpc_data_create(bytes.baseAddress, bytes.count)
        }
        dictionary[field] = object
    }

    /// Copies XPC's storage after checking the declared per-call byte bound.
    package static func copyPayload(
        from dictionary: XPCDictionary,
        maximumBytes: Int,
        field: String = TorrentEngineIPCField.payload
    ) throws -> Data? {
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumBytes)
        guard dictionary.keys.contains(field) else {
            return nil
        }
        guard let object = unsafe dictionary[field, as: XPC_TYPE_DATA] else {
            throw TorrentEngineIPCError.wrongFieldType(field: field, expected: "data")
        }
        let length = xpc_data_get_length(object)
        guard length <= maximumBytes else {
            throw TorrentEngineIPCError.payloadTooLarge(
                actual: length,
                maximum: maximumBytes
            )
        }
        guard length > 0 else {
            return Data()
        }
        guard let bytes = unsafe xpc_data_get_bytes_ptr(object) else {
            throw TorrentEngineIPCError.wrongFieldType(field: field, expected: "data")
        }
        return unsafe Data(bytes: bytes, count: length)
    }
}
