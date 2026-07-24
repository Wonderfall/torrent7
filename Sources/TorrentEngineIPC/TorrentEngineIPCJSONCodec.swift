import Foundation

package struct TorrentEngineIPCJSONLimits: Equatable, Sendable {
    package let maximumNestingDepth: Int
    package let maximumValueNodeCount: Int
    package let maximumStringByteCount: Int
    package let maximumPrimitiveByteCount: Int

    package init(
        maximumNestingDepth: Int,
        maximumValueNodeCount: Int,
        maximumStringByteCount: Int,
        maximumPrimitiveByteCount: Int
    ) {
        self.maximumNestingDepth = maximumNestingDepth
        self.maximumValueNodeCount = maximumValueNodeCount
        self.maximumStringByteCount = maximumStringByteCount
        self.maximumPrimitiveByteCount = maximumPrimitiveByteCount
    }
}

package enum TorrentEngineIPCJSONCodec {
    package static func encode<Value: Encodable & Sendable>(
        _ value: Value,
        maximumBytes: Int,
        limits: TorrentEngineIPCJSONLimits
    ) throws -> Data {
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumBytes)

        let data: Data
        do {
            let encoder = JSONEncoder()
            // Foundation otherwise escapes "/" as "\/". Base64 can consist
            // entirely of slashes, so disabling that optional escaping keeps
            // encoded Data at its predictable four-thirds expansion.
            encoder.outputFormatting = [.withoutEscapingSlashes]
            encoder.dataEncodingStrategy = .base64
            encoder.nonConformingFloatEncodingStrategy = .throw
            data = try encoder.encode(value)
            try TorrentEngineIPCJSONPreflight.validate(data, limits: limits)
        } catch {
            throw TorrentEngineIPCError.jsonEncodingFailed
        }
        try TorrentEngineIPCPayloadBounds.validate(data, maximumBytes: maximumBytes)
        return data
    }

    package static func decode<Value: Decodable & Sendable>(
        _ type: Value.Type = Value.self,
        from data: Data,
        maximumBytes: Int,
        limits: TorrentEngineIPCJSONLimits
    ) throws -> Value {
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumBytes)
        try TorrentEngineIPCPayloadBounds.validate(data, maximumBytes: maximumBytes)

        do {
            try TorrentEngineIPCJSONPreflight.validate(data, limits: limits)
            let decoder = JSONDecoder()
            decoder.allowsJSON5 = false
            decoder.dataDecodingStrategy = .base64
            decoder.nonConformingFloatDecodingStrategy = .throw
            return try decoder.decode(type, from: data)
        } catch {
            throw TorrentEngineIPCError.jsonDecodingFailed
        }
    }

    /// Exposes the allocation preflight to the developer-only fuzz harness
    /// without teaching that harness a second version of the scanner.
    package static func preflightForFuzzing(
        _ data: Data,
        limits: TorrentEngineIPCJSONLimits
    ) throws {
        try TorrentEngineIPCJSONPreflight.validate(data, limits: limits)
    }
}

/// JSON has no aliases or object references. Payload bytes bound decoded leaf
/// content, while this scanner bounds the remaining container and scalar
/// allocation dimensions before Foundation parses the payload: a container
/// root, nesting depth, value nodes, and individual string/primitive size.
/// JSONDecoder remains responsible for full grammar and UTF-8 validation.
private enum TorrentEngineIPCJSONPreflight {
    private static let objectStart: UInt8 = 0x7B
    private static let objectEnd: UInt8 = 0x7D
    private static let arrayStart: UInt8 = 0x5B
    private static let arrayEnd: UInt8 = 0x5D
    private static let quotationMark: UInt8 = 0x22
    private static let reverseSolidus: UInt8 = 0x5C
    private static let comma: UInt8 = 0x2C
    private static let colon: UInt8 = 0x3A

    static func validate(_ data: Data, limits: TorrentEngineIPCJSONLimits) throws {
        guard limits.maximumNestingDepth > 0,
              limits.maximumNestingDepth
                <= TorrentEngineIPCLimits.maximumJSONNestingDepthLimit,
              limits.maximumValueNodeCount > 0,
              limits.maximumValueNodeCount
                <= TorrentEngineIPCLimits.maximumJSONValueNodeCountLimit,
              limits.maximumStringByteCount > 0,
              limits.maximumStringByteCount
                <= TorrentEngineIPCLimits.maximumJSONStringByteCountLimit,
              limits.maximumPrimitiveByteCount > 0,
              limits.maximumPrimitiveByteCount
                <= TorrentEngineIPCLimits.maximumJSONPrimitiveByteCountLimit else {
            throw TorrentEngineIPCError.jsonDecodingFailed
        }

        var containers = [UInt8]()
        containers.reserveCapacity(limits.maximumNestingDepth)
        var rootStarted = false
        var rootCompleted = false
        var isInsideString = false
        var isEscaped = false
        var isInsidePrimitive = false
        var valueNodeCount = 0
        var stringByteCount = 0
        var primitiveByteCount = 0

        for byte in data {
            if rootCompleted {
                guard isWhitespace(byte) else {
                    throw TorrentEngineIPCError.jsonDecodingFailed
                }
                continue
            }

            if isInsideString {
                if isEscaped {
                    try recordByte(
                        &stringByteCount,
                        maximum: limits.maximumStringByteCount
                    )
                    isEscaped = false
                } else if byte == reverseSolidus {
                    try recordByte(
                        &stringByteCount,
                        maximum: limits.maximumStringByteCount
                    )
                    isEscaped = true
                } else if byte == quotationMark {
                    isInsideString = false
                    stringByteCount = 0
                } else {
                    try recordByte(
                        &stringByteCount,
                        maximum: limits.maximumStringByteCount
                    )
                }
                continue
            }

            if !rootStarted {
                if isWhitespace(byte) {
                    continue
                }
                guard byte == objectStart || byte == arrayStart else {
                    throw TorrentEngineIPCError.jsonDecodingFailed
                }
                try recordValueNode(
                    &valueNodeCount,
                    maximum: limits.maximumValueNodeCount
                )
                rootStarted = true
                containers.append(byte)
                continue
            }

            switch byte {
            case quotationMark:
                try recordValueNode(
                    &valueNodeCount,
                    maximum: limits.maximumValueNodeCount
                )
                isInsidePrimitive = false
                primitiveByteCount = 0
                isInsideString = true
                stringByteCount = 0
            case objectStart, arrayStart:
                try recordValueNode(
                    &valueNodeCount,
                    maximum: limits.maximumValueNodeCount
                )
                isInsidePrimitive = false
                primitiveByteCount = 0
                guard containers.count < limits.maximumNestingDepth else {
                    throw TorrentEngineIPCError.jsonDecodingFailed
                }
                containers.append(byte)
            case objectEnd:
                isInsidePrimitive = false
                primitiveByteCount = 0
                guard containers.last == objectStart else {
                    throw TorrentEngineIPCError.jsonDecodingFailed
                }
                containers.removeLast()
                rootCompleted = containers.isEmpty
            case arrayEnd:
                isInsidePrimitive = false
                primitiveByteCount = 0
                guard containers.last == arrayStart else {
                    throw TorrentEngineIPCError.jsonDecodingFailed
                }
                containers.removeLast()
                rootCompleted = containers.isEmpty
            case comma, colon:
                isInsidePrimitive = false
                primitiveByteCount = 0
            default:
                if isWhitespace(byte) {
                    isInsidePrimitive = false
                    primitiveByteCount = 0
                } else if !isInsidePrimitive {
                    try recordValueNode(
                        &valueNodeCount,
                        maximum: limits.maximumValueNodeCount
                    )
                    isInsidePrimitive = true
                    primitiveByteCount = 1
                } else {
                    try recordByte(
                        &primitiveByteCount,
                        maximum: limits.maximumPrimitiveByteCount
                    )
                }
            }
        }

        guard rootStarted,
              rootCompleted,
              containers.isEmpty,
              !isInsideString else {
            throw TorrentEngineIPCError.jsonDecodingFailed
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func recordValueNode(
        _ valueNodeCount: inout Int,
        maximum: Int
    ) throws {
        guard valueNodeCount < maximum else {
            throw TorrentEngineIPCError.jsonDecodingFailed
        }
        valueNodeCount += 1
    }

    private static func recordByte(
        _ byteCount: inout Int,
        maximum: Int
    ) throws {
        guard byteCount < maximum else {
            throw TorrentEngineIPCError.jsonDecodingFailed
        }
        byteCount += 1
    }
}

package enum TorrentEngineIPCPayloadBounds {
    package static func validateMaximum(_ maximumBytes: Int) throws {
        guard (0...TorrentEngineIPCLimits.maximumPayloadBytes).contains(maximumBytes) else {
            throw TorrentEngineIPCError.invalidMaximumPayloadSize(maximumBytes)
        }
    }

    package static func validate(_ data: Data, maximumBytes: Int) throws {
        guard data.count <= maximumBytes else {
            throw TorrentEngineIPCError.payloadTooLarge(
                actual: data.count,
                maximum: maximumBytes
            )
        }
    }
}
