import Foundation

package struct TorrentEngineIPCPropertyListDecodingLimits: Equatable, Sendable {
    package static let standard = Self(
        maximumContainerElementCount: 20_000,
        maximumCollectionReferenceCount: 128 * 1_024
    )

    package let maximumContainerElementCount: Int
    package let maximumCollectionReferenceCount: Int

    package init(
        maximumContainerElementCount: Int,
        maximumCollectionReferenceCount: Int
    ) {
        self.maximumContainerElementCount = maximumContainerElementCount
        self.maximumCollectionReferenceCount = maximumCollectionReferenceCount
    }
}

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
        maximumBytes: Int,
        decodingLimits: TorrentEngineIPCPropertyListDecodingLimits = .standard
    ) throws -> Value {
        try TorrentEngineIPCPayloadBounds.validateMaximum(maximumBytes)
        try TorrentEngineIPCPayloadBounds.validate(data, maximumBytes: maximumBytes)

        do {
            try TorrentEngineIPCBinaryPropertyListPreflight.validate(
                data,
                limits: decodingLimits
            )
            return try PropertyListDecoder().decode(type, from: data)
        } catch {
            throw TorrentEngineIPCError.propertyListDecodingFailed
        }
    }
}

private enum TorrentEngineIPCBinaryPropertyListPreflight {
    private static let header = Data("bplist00".utf8)
    private static let trailerByteCount = 32

    static func validate(
        _ data: Data,
        limits: TorrentEngineIPCPropertyListDecodingLimits
    ) throws {
        guard limits.maximumContainerElementCount >= 0,
              limits.maximumCollectionReferenceCount >= 0,
              data.starts(with: header),
              data.count >= header.count + trailerByteCount else {
            throw TorrentEngineIPCError.propertyListDecodingFailed
        }

        let trailerOffset = data.count - trailerByteCount
        let offsetIntegerByteCount = Int(data[trailerOffset + 6])
        let objectReferenceByteCount = Int(data[trailerOffset + 7])
        guard (1...8).contains(offsetIntegerByteCount),
              (1...8).contains(objectReferenceByteCount) else {
            throw TorrentEngineIPCError.propertyListDecodingFailed
        }

        let objectCountValue = try readUnsignedInteger(
            from: data,
            offset: trailerOffset + 8,
            byteCount: 8
        )
        let topObjectValue = try readUnsignedInteger(
            from: data,
            offset: trailerOffset + 16,
            byteCount: 8
        )
        let offsetTableValue = try readUnsignedInteger(
            from: data,
            offset: trailerOffset + 24,
            byteCount: 8
        )
        guard objectCountValue > 0,
              objectCountValue <= UInt64(limits.maximumCollectionReferenceCount) + 1,
              topObjectValue < objectCountValue,
              offsetTableValue <= UInt64(Int.max) else {
            throw TorrentEngineIPCError.propertyListDecodingFailed
        }

        let objectCount = Int(objectCountValue)
        let offsetTableOffset = Int(offsetTableValue)
        guard offsetTableOffset >= header.count,
              offsetTableOffset < trailerOffset,
              objectCount <= (trailerOffset - offsetTableOffset) / offsetIntegerByteCount else {
            throw TorrentEngineIPCError.propertyListDecodingFailed
        }

        var collectionReferenceCount = 0
        for objectIndex in 0..<objectCount {
            let tableEntryOffset = offsetTableOffset
                + objectIndex * offsetIntegerByteCount
            let objectOffsetValue = try readUnsignedInteger(
                from: data,
                offset: tableEntryOffset,
                byteCount: offsetIntegerByteCount
            )
            guard objectOffsetValue <= UInt64(Int.max) else {
                throw TorrentEngineIPCError.propertyListDecodingFailed
            }
            let objectOffset = Int(objectOffsetValue)
            guard objectOffset >= header.count,
                  objectOffset < offsetTableOffset else {
                throw TorrentEngineIPCError.propertyListDecodingFailed
            }

            let marker = data[objectOffset]
            let objectType = marker >> 4
            guard objectType == 0xA || objectType == 0xB
                    || objectType == 0xC || objectType == 0xD else {
                continue
            }
            let (elementCount, payloadOffset) = try collectionLength(
                in: data,
                markerOffset: objectOffset,
                objectTableEnd: offsetTableOffset
            )
            guard elementCount <= limits.maximumContainerElementCount else {
                throw TorrentEngineIPCError.propertyListDecodingFailed
            }
            let referenceMultiplier = objectType == 0xD ? 2 : 1
            guard elementCount <= Int.max / referenceMultiplier else {
                throw TorrentEngineIPCError.propertyListDecodingFailed
            }
            let referenceCount = elementCount * referenceMultiplier
            guard referenceCount <= (offsetTableOffset - payloadOffset)
                    / objectReferenceByteCount,
                  referenceCount <= limits.maximumCollectionReferenceCount
                    - collectionReferenceCount else {
                throw TorrentEngineIPCError.propertyListDecodingFailed
            }
            collectionReferenceCount += referenceCount
        }
    }

    private static func collectionLength(
        in data: Data,
        markerOffset: Int,
        objectTableEnd: Int
    ) throws -> (count: Int, payloadOffset: Int) {
        let inlineLength = Int(data[markerOffset] & 0x0F)
        if inlineLength < 0x0F {
            return (inlineLength, markerOffset + 1)
        }

        let lengthMarkerOffset = markerOffset + 1
        guard lengthMarkerOffset < objectTableEnd else {
            throw TorrentEngineIPCError.propertyListDecodingFailed
        }
        let lengthMarker = data[lengthMarkerOffset]
        guard lengthMarker >> 4 == 0x1 else {
            throw TorrentEngineIPCError.propertyListDecodingFailed
        }
        let byteCountExponent = Int(lengthMarker & 0x0F)
        guard byteCountExponent <= 3 else {
            throw TorrentEngineIPCError.propertyListDecodingFailed
        }
        let byteCount = 1 << byteCountExponent
        let lengthValue = try readUnsignedInteger(
            from: data,
            offset: lengthMarkerOffset + 1,
            byteCount: byteCount
        )
        guard lengthValue <= UInt64(Int.max) else {
            throw TorrentEngineIPCError.propertyListDecodingFailed
        }
        return (Int(lengthValue), lengthMarkerOffset + 1 + byteCount)
    }

    private static func readUnsignedInteger(
        from data: Data,
        offset: Int,
        byteCount: Int
    ) throws -> UInt64 {
        guard byteCount > 0,
              byteCount <= 8,
              offset >= 0,
              offset <= data.count - byteCount else {
            throw TorrentEngineIPCError.propertyListDecodingFailed
        }
        var value: UInt64 = 0
        for index in offset..<(offset + byteCount) {
            value = (value << 8) | UInt64(data[index])
        }
        return value
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
