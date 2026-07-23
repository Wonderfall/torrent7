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
}

package struct TorrentEngineIPCRequestMetadata: Equatable, Sendable {
    package let header: TorrentEngineIPCHeader
    package let hasPayload: Bool
    package let payloadByteCount: Int

    package init(
        header: TorrentEngineIPCHeader,
        hasPayload: Bool,
        payloadByteCount: Int
    ) {
        self.header = header
        self.hasPayload = hasPayload
        self.payloadByteCount = payloadByteCount
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

    private static let requestFields = commonFields
    private static let replyFields = commonFields.union([
        TorrentEngineIPCField.engineEpoch,
        TorrentEngineIPCField.status,
        TorrentEngineIPCField.failureCode,
        TorrentEngineIPCField.errorMessage,
    ])

    package static func encode(
        _ request: TorrentEngineIPCRequest,
        maximumPayloadBytes: Int
    ) throws -> XPCDictionary {
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumPayloadBytes)
        try validate(request.header)

        var dictionary = encodeHeader(request.header)
        try TorrentEngineIPCXPCValues.insertPayload(
            request.payload,
            into: &dictionary,
            maximumBytes: maximumPayloadBytes
        )
        return dictionary
    }

    package static func decodeRequest(
        _ dictionary: XPCDictionary,
        maximumPayloadBytes: Int
    ) throws -> TorrentEngineIPCRequest {
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumPayloadBytes)
        let metadata = try inspectRequest(dictionary)
        guard metadata.payloadByteCount <= maximumPayloadBytes else {
            throw TorrentEngineIPCError.payloadTooLarge(
                actual: metadata.payloadByteCount,
                maximum: maximumPayloadBytes
            )
        }
        return try decodeRequest(
            dictionary,
            metadata: metadata,
            maximumPayloadBytes: maximumPayloadBytes
        )
    }

    /// Validates the request envelope and reads only fixed-size header fields and
    /// XPC object metadata. The payload is not copied.
    package static func inspectRequest(
        _ dictionary: XPCDictionary
    ) throws -> TorrentEngineIPCRequestMetadata {
        try validateAllowedFields(in: dictionary, allowed: requestFields)
        let header = try decodeHeader(dictionary)
        let payloadByteCount = try TorrentEngineIPCXPCValues.payloadByteCount(
            in: dictionary
        )
        return TorrentEngineIPCRequestMetadata(
            header: header,
            hasPayload: dictionary.keys.contains(TorrentEngineIPCField.payload),
            payloadByteCount: payloadByteCount
        )
    }

    /// Copies resources only after a caller has admitted the inspected request.
    package static func decodeRequest(
        _ dictionary: XPCDictionary,
        metadata: TorrentEngineIPCRequestMetadata,
        maximumPayloadBytes: Int
    ) throws -> TorrentEngineIPCRequest {
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumPayloadBytes)
        guard try inspectRequest(dictionary) == metadata else {
            throw TorrentEngineIPCError.requestMetadataMismatch
        }
        guard metadata.payloadByteCount <= maximumPayloadBytes else {
            throw TorrentEngineIPCError.payloadTooLarge(
                actual: metadata.payloadByteCount,
                maximum: maximumPayloadBytes
            )
        }
        let payload = try TorrentEngineIPCXPCValues.copyPayload(
            from: dictionary,
            maximumBytes: maximumPayloadBytes
        )
        return TorrentEngineIPCRequest(
            header: metadata.header,
            payload: payload
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
