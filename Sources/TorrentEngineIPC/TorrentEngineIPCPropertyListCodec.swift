import Foundation

package enum TorrentEngineIPCPropertyListCodec {
    package static func encode<Value: Encodable & Sendable>(
        _ value: Value,
        maximumBytes: Int
    ) throws -> Data {
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumBytes)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw TorrentEngineIPCError.propertyListEncodingFailed
        }
        try TorrentEngineIPCPayloadBounds.validate(data, maximumBytes: maximumBytes)
        return data
    }

    package static func decode<Value: Decodable & Sendable>(
        _ type: Value.Type = Value.self,
        from data: Data,
        maximumBytes: Int
    ) throws -> Value {
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumBytes)
        try TorrentEngineIPCPayloadBounds.validate(data, maximumBytes: maximumBytes)

        do {
            return try PropertyListDecoder().decode(type, from: data)
        } catch {
            throw TorrentEngineIPCError.propertyListDecodingFailed
        }
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
