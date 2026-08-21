import Foundation
import XPC

package enum TorrentStorageBrokerProtocol {
    package static let version: UInt64 = 1
    package static let maximumStatBatchCount = 256
    package static let maximumErrorBytes = 1_024

    static let maximumStatBatchBytes = 4 + maximumStatBatchCount * 4
    static let maximumMetadataBytes = 4 + maximumStatBatchCount * 40
}

package enum TorrentStorageBrokerAccess: UInt64, Sendable {
    case readOnly = 1
    case readWrite = 2
}

package enum TorrentStorageBrokerOperation: UInt64, Sendable {
    case handshake = 1
    case openPayload = 2
    case statBatch = 3
}

package enum TorrentStorageBrokerFailure: UInt64, Error, Sendable {
    case malformedRequest = 1
    case sessionRejected = 2
    case claimUnavailable = 3
    case generationMismatch = 4
    case fileUnavailable = 5
    case accessDenied = 6
    case filesystemObjectChanged = 7
    case deadlineExceeded = 8
    case internalFailure = 9
}

package struct TorrentStorageBrokerFileMetadata: Equatable, Sendable {
    package let fileIndex: Int32
    package let size: Int64
    package let device: UInt64
    package let inode: UInt64
    package let linkCount: UInt64
    package let mode: UInt32

    package init(
        fileIndex: Int32,
        size: Int64,
        device: UInt64,
        inode: UInt64,
        linkCount: UInt64,
        mode: UInt32
    ) {
        self.fileIndex = fileIndex
        self.size = size
        self.device = device
        self.inode = inode
        self.linkCount = linkCount
        self.mode = mode
    }
}

package enum TorrentStorageBrokerRequest: Equatable, Sendable {
    case handshake(Common)
    case openPayload(
        Common,
        claimID: UUID,
        generation: UInt64,
        fileIndex: Int32,
        access: TorrentStorageBrokerAccess
    )
    case statBatch(
        Common,
        claimID: UUID,
        generation: UInt64,
        fileIndices: [Int32]
    )

    package struct Common: Equatable, Sendable {
        package let requestID: UUID
        package let engineEpoch: UUID
        package let sessionNonce: UUID
        package let deadlineUptimeNanoseconds: UInt64

        package init(
            requestID: UUID,
            engineEpoch: UUID,
            sessionNonce: UUID,
            deadlineUptimeNanoseconds: UInt64
        ) {
            self.requestID = requestID
            self.engineEpoch = engineEpoch
            self.sessionNonce = sessionNonce
            self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
        }
    }

    package var common: Common {
        switch self {
        case .handshake(let common),
             .openPayload(let common, _, _, _, _),
             .statBatch(let common, _, _, _):
            common
        }
    }
}

package enum TorrentStorageBrokerReply: Sendable {
    case success(
        requestID: UUID,
        metadata: TorrentStorageBrokerFileMetadata?,
        statistics: [TorrentStorageBrokerFileMetadata],
        fileDescriptor: Int32?
    )
    case failure(requestID: UUID, code: TorrentStorageBrokerFailure, message: String)
}

package enum TorrentStorageBrokerIPCError: Error, Equatable, Sendable {
    case malformedMessage
    case unsupportedVersion
    case requestMismatch
    case invalidFileDescriptor
}

package enum TorrentStorageBrokerIPCCodec {
    private enum Field {
        static let version = "v"
        static let requestID = "r"
        static let engineEpoch = "e"
        static let sessionNonce = "n"
        static let deadline = "d"
        static let operation = "o"
        static let claimID = "c"
        static let generation = "g"
        static let fileIndex = "i"
        static let access = "a"
        static let fileIndices = "is"
        static let status = "s"
        static let failure = "f"
        static let message = "m"
        static let metadata = "md"
        static let statistics = "st"
        static let descriptor = "fd"
    }

    package static func encode(_ request: TorrentStorageBrokerRequest) -> XPCDictionary {
        var dictionary = XPCDictionary()
        let common = request.common
        dictionary[Field.version] = TorrentStorageBrokerProtocol.version
        dictionary[Field.requestID] = common.requestID.uuidString
        dictionary[Field.engineEpoch] = common.engineEpoch.uuidString
        dictionary[Field.sessionNonce] = common.sessionNonce.uuidString
        dictionary[Field.deadline] = common.deadlineUptimeNanoseconds

        switch request {
        case .handshake:
            dictionary[Field.operation] = TorrentStorageBrokerOperation.handshake.rawValue
        case .openPayload(_, let claimID, let generation, let fileIndex, let access):
            dictionary[Field.operation] = TorrentStorageBrokerOperation.openPayload.rawValue
            dictionary[Field.claimID] = claimID.uuidString
            dictionary[Field.generation] = generation
            dictionary[Field.fileIndex] = Int64(fileIndex)
            dictionary[Field.access] = access.rawValue
        case .statBatch(_, let claimID, let generation, let fileIndices):
            dictionary[Field.operation] = TorrentStorageBrokerOperation.statBatch.rawValue
            dictionary[Field.claimID] = claimID.uuidString
            dictionary[Field.generation] = generation
            dictionary[Field.fileIndices] = dataObject(encodeIndices(fileIndices))
        }
        return dictionary
    }

    package static func decodeRequest(_ dictionary: XPCDictionary) throws
        -> TorrentStorageBrokerRequest {
        guard dictionary.count <= 10,
              let version: UInt64 = dictionary[Field.version],
              version == TorrentStorageBrokerProtocol.version,
              let requestID = uuid(in: dictionary, forKey: Field.requestID),
              let engineEpoch = uuid(in: dictionary, forKey: Field.engineEpoch),
              let sessionNonce = uuid(in: dictionary, forKey: Field.sessionNonce),
              let deadline: UInt64 = dictionary[Field.deadline],
              deadline > 0,
              let rawOperation: UInt64 = dictionary[Field.operation],
              let operation = TorrentStorageBrokerOperation(rawValue: rawOperation) else {
            throw TorrentStorageBrokerIPCError.malformedMessage
        }
        let common = TorrentStorageBrokerRequest.Common(
            requestID: requestID,
            engineEpoch: engineEpoch,
            sessionNonce: sessionNonce,
            deadlineUptimeNanoseconds: deadline
        )

        switch operation {
        case .handshake:
            try requireKeys(
                dictionary,
                [Field.version, Field.requestID, Field.engineEpoch,
                 Field.sessionNonce, Field.deadline, Field.operation]
            )
            return .handshake(common)
        case .openPayload:
            try requireKeys(
                dictionary,
                [Field.version, Field.requestID, Field.engineEpoch,
                 Field.sessionNonce, Field.deadline, Field.operation,
                 Field.claimID, Field.generation, Field.fileIndex, Field.access]
            )
            guard let claimID = uuid(in: dictionary, forKey: Field.claimID),
                  let generation: UInt64 = dictionary[Field.generation],
                  generation > 0,
                  let rawIndex: Int64 = dictionary[Field.fileIndex],
                  rawIndex >= 0,
                  rawIndex <= Int64(Int32.max),
                  let rawAccess: UInt64 = dictionary[Field.access],
                  let access = TorrentStorageBrokerAccess(rawValue: rawAccess) else {
                throw TorrentStorageBrokerIPCError.malformedMessage
            }
            return .openPayload(
                common,
                claimID: claimID,
                generation: generation,
                fileIndex: Int32(rawIndex),
                access: access
            )
        case .statBatch:
            try requireKeys(
                dictionary,
                [Field.version, Field.requestID, Field.engineEpoch,
                 Field.sessionNonce, Field.deadline, Field.operation,
                 Field.claimID, Field.generation, Field.fileIndices]
            )
            guard let claimID = uuid(in: dictionary, forKey: Field.claimID),
                  let generation: UInt64 = dictionary[Field.generation],
                  generation > 0,
                  let object = unsafe dictionary[Field.fileIndices, as: XPC_TYPE_DATA] else {
                throw TorrentStorageBrokerIPCError.malformedMessage
            }
            let indices = try decodeIndices(data(
                from: object,
                maximumBytes: TorrentStorageBrokerProtocol.maximumStatBatchBytes
            ))
            return .statBatch(
                common,
                claimID: claimID,
                generation: generation,
                fileIndices: indices
            )
        }
    }

    package static func encode(
        _ reply: TorrentStorageBrokerReply,
        for request: TorrentStorageBrokerRequest
    ) throws -> XPCDictionary {
        var dictionary = XPCDictionary()
        dictionary[Field.version] = TorrentStorageBrokerProtocol.version
        switch reply {
        case .success(let requestID, let metadata, let statistics, let descriptor):
            guard requestID == request.common.requestID else {
                throw TorrentStorageBrokerIPCError.requestMismatch
            }
            switch request {
            case .handshake:
                guard metadata == nil, statistics.isEmpty, descriptor == nil else {
                    throw TorrentStorageBrokerIPCError.malformedMessage
                }
            case .openPayload(_, _, _, let fileIndex, _):
                guard metadata?.fileIndex == fileIndex,
                      statistics.isEmpty,
                      descriptor != nil else {
                    throw TorrentStorageBrokerIPCError.malformedMessage
                }
            case .statBatch(_, _, _, let indices):
                guard metadata == nil,
                      descriptor == nil,
                      statistics.map(\.fileIndex) == indices else {
                    throw TorrentStorageBrokerIPCError.malformedMessage
                }
            }
            dictionary[Field.requestID] = requestID.uuidString
            dictionary[Field.status] = UInt64(0)
            if let metadata {
                dictionary[Field.metadata] = dataObject(encodeMetadata([metadata]))
            }
            if !statistics.isEmpty {
                dictionary[Field.statistics] = dataObject(encodeMetadata(statistics))
            }
            if let descriptor {
                guard descriptor >= 0,
                      let object = xpc_fd_create(descriptor) else {
                    throw TorrentStorageBrokerIPCError.invalidFileDescriptor
                }
                dictionary[Field.descriptor] = object
            }
        case .failure(let requestID, let code, let message):
            guard requestID == request.common.requestID else {
                throw TorrentStorageBrokerIPCError.requestMismatch
            }
            let bounded = boundedError(message)
            dictionary[Field.requestID] = requestID.uuidString
            dictionary[Field.status] = UInt64(1)
            dictionary[Field.failure] = code.rawValue
            dictionary[Field.message] = bounded
        }
        return dictionary
    }

    package static func decodeReply(
        _ dictionary: XPCDictionary,
        for request: TorrentStorageBrokerRequest
    ) throws -> TorrentStorageBrokerReply {
        guard dictionary.count <= 7,
              let version: UInt64 = dictionary[Field.version],
              version == TorrentStorageBrokerProtocol.version,
              let requestID = uuid(in: dictionary, forKey: Field.requestID),
              requestID == request.common.requestID,
              let status: UInt64 = dictionary[Field.status] else {
            throw TorrentStorageBrokerIPCError.requestMismatch
        }
        if status == 1 {
            try requireKeys(
                dictionary,
                [Field.version, Field.requestID, Field.status, Field.failure, Field.message]
            )
            guard let rawFailure: UInt64 = dictionary[Field.failure],
                  let failure = TorrentStorageBrokerFailure(rawValue: rawFailure),
                  let message = boundedString(
                      in: dictionary,
                      forKey: Field.message,
                      maximumUTF8Bytes: TorrentStorageBrokerProtocol.maximumErrorBytes
                  ),
                  !message.isEmpty,
                  !message.utf8.contains(0) else {
                throw TorrentStorageBrokerIPCError.malformedMessage
            }
            return .failure(requestID: requestID, code: failure, message: message)
        }
        guard status == 0,
              !containsValue(dictionary, forKey: Field.failure),
              !containsValue(dictionary, forKey: Field.message) else {
            throw TorrentStorageBrokerIPCError.malformedMessage
        }
        let expectedKeys: Set<String>
        switch request {
        case .handshake:
            expectedKeys = [Field.version, Field.requestID, Field.status]
        case .openPayload:
            expectedKeys = [
                Field.version, Field.requestID, Field.status,
                Field.metadata, Field.descriptor,
            ]
        case .statBatch:
            expectedKeys = [
                Field.version, Field.requestID, Field.status, Field.statistics,
            ]
        }
        try requireKeys(dictionary, expectedKeys)
        let metadata: TorrentStorageBrokerFileMetadata?
        if let object = unsafe dictionary[Field.metadata, as: XPC_TYPE_DATA] {
            let values = try decodeMetadata(data(
                from: object,
                maximumBytes: TorrentStorageBrokerProtocol.maximumMetadataBytes
            ))
            guard values.count == 1 else {
                throw TorrentStorageBrokerIPCError.malformedMessage
            }
            metadata = values[0]
        } else {
            metadata = nil
        }
        let statistics: [TorrentStorageBrokerFileMetadata]
        if let object = unsafe dictionary[Field.statistics, as: XPC_TYPE_DATA] {
            statistics = try decodeMetadata(data(
                from: object,
                maximumBytes: TorrentStorageBrokerProtocol.maximumMetadataBytes
            ))
        } else {
            statistics = []
        }
        let descriptor: Int32?
        if let object = unsafe dictionary[Field.descriptor, as: XPC_TYPE_FD] {
            let duplicated = xpc_fd_dup(object)
            guard duplicated >= 0 else {
                throw TorrentStorageBrokerIPCError.invalidFileDescriptor
            }
            descriptor = duplicated
        } else {
            descriptor = nil
        }
        switch request {
        case .handshake:
            guard metadata == nil, statistics.isEmpty, descriptor == nil else {
                if let descriptor { _ = Darwin.close(descriptor) }
                throw TorrentStorageBrokerIPCError.malformedMessage
            }
        case .openPayload(_, _, _, let fileIndex, _):
            guard metadata?.fileIndex == fileIndex,
                  statistics.isEmpty,
                  descriptor != nil else {
                if let descriptor { _ = Darwin.close(descriptor) }
                throw TorrentStorageBrokerIPCError.malformedMessage
            }
        case .statBatch(_, _, _, let indices):
            guard metadata == nil,
                  descriptor == nil,
                  statistics.map(\.fileIndex) == indices else {
                if let descriptor { _ = Darwin.close(descriptor) }
                throw TorrentStorageBrokerIPCError.malformedMessage
            }
        }
        return .success(
            requestID: requestID,
            metadata: metadata,
            statistics: statistics,
            fileDescriptor: descriptor
        )
    }

    private static func encodeIndices(_ indices: [Int32]) -> Data {
        var data = Data()
        append(UInt32(indices.count), to: &data)
        for index in indices {
            append(UInt32(bitPattern: index), to: &data)
        }
        return data
    }

    private static func decodeIndices(_ data: Data) throws -> [Int32] {
        guard data.count >= 4 else {
            throw TorrentStorageBrokerIPCError.malformedMessage
        }
        var offset = 0
        let count = Int(try readUInt32(data, offset: &offset))
        guard count > 0,
              count <= TorrentStorageBrokerProtocol.maximumStatBatchCount,
              data.count == 4 + count * 4 else {
            throw TorrentStorageBrokerIPCError.malformedMessage
        }
        var indices = [Int32]()
        indices.reserveCapacity(count)
        var seen = Set<Int32>()
        for _ in 0..<count {
            let index = Int32(bitPattern: try readUInt32(data, offset: &offset))
            guard index >= 0, seen.insert(index).inserted else {
                throw TorrentStorageBrokerIPCError.malformedMessage
            }
            indices.append(index)
        }
        return indices
    }

    private static func encodeMetadata(
        _ values: [TorrentStorageBrokerFileMetadata]
    ) -> Data {
        var data = Data()
        append(UInt32(values.count), to: &data)
        for value in values {
            append(UInt32(bitPattern: value.fileIndex), to: &data)
            append(UInt64(bitPattern: value.size), to: &data)
            append(value.device, to: &data)
            append(value.inode, to: &data)
            append(value.linkCount, to: &data)
            append(value.mode, to: &data)
        }
        return data
    }

    private static func decodeMetadata(_ data: Data) throws
        -> [TorrentStorageBrokerFileMetadata] {
        guard data.count >= 4 else {
            throw TorrentStorageBrokerIPCError.malformedMessage
        }
        var offset = 0
        let count = Int(try readUInt32(data, offset: &offset))
        let recordSize = 4 + 8 + 8 + 8 + 8 + 4
        guard count <= TorrentStorageBrokerProtocol.maximumStatBatchCount,
              data.count == 4 + count * recordSize else {
            throw TorrentStorageBrokerIPCError.malformedMessage
        }
        var values = [TorrentStorageBrokerFileMetadata]()
        values.reserveCapacity(count)
        for _ in 0..<count {
            let index = Int32(bitPattern: try readUInt32(data, offset: &offset))
            let size = Int64(bitPattern: try readUInt64(data, offset: &offset))
            let device = try readUInt64(data, offset: &offset)
            let inode = try readUInt64(data, offset: &offset)
            let linkCount = try readUInt64(data, offset: &offset)
            let mode = try readUInt32(data, offset: &offset)
            guard index >= 0, size >= 0 else {
                throw TorrentStorageBrokerIPCError.malformedMessage
            }
            values.append(TorrentStorageBrokerFileMetadata(
                fileIndex: index,
                size: size,
                device: device,
                inode: inode,
                linkCount: linkCount,
                mode: mode
            ))
        }
        return values
    }

    private static func dataObject(_ data: Data) -> xpc_object_t {
        unsafe data.withUnsafeBytes { bytes in
            unsafe xpc_data_create(bytes.baseAddress, bytes.count)
        }
    }

    private static func data(
        from object: xpc_object_t,
        maximumBytes: Int
    ) throws -> Data {
        let count = xpc_data_get_length(object)
        guard count > 0,
              count <= maximumBytes,
              let pointer = unsafe xpc_data_get_bytes_ptr(object) else {
            throw TorrentStorageBrokerIPCError.malformedMessage
        }
        return unsafe Data(bytes: pointer, count: count)
    }

    private static func requireKeys(
        _ dictionary: XPCDictionary,
        _ expected: Set<String>
    ) throws {
        guard dictionary.count == expected.count,
              expected.allSatisfy({ containsValue(dictionary, forKey: $0) }) else {
            throw TorrentStorageBrokerIPCError.malformedMessage
        }
    }

    private static func uuid(
        in dictionary: XPCDictionary,
        forKey key: String
    ) -> UUID? {
        guard let value = boundedString(
            in: dictionary,
            forKey: key,
            exactUTF8Bytes: 36
        ),
              let uuid = UUID(uuidString: value),
              uuid.uuidString == value else {
            return nil
        }
        return uuid
    }

    private static func boundedString(
        in dictionary: XPCDictionary,
        forKey key: String,
        exactUTF8Bytes: Int
    ) -> String? {
        guard let object = unsafe dictionary[key, as: XPC_TYPE_STRING],
              xpc_string_get_length(object) == exactUTF8Bytes,
              let pointer = unsafe xpc_string_get_string_ptr(object) else {
            return nil
        }
        return unsafe String(validatingCString: pointer)
    }

    private static func boundedString(
        in dictionary: XPCDictionary,
        forKey key: String,
        maximumUTF8Bytes: Int
    ) -> String? {
        guard let object = unsafe dictionary[key, as: XPC_TYPE_STRING],
              xpc_string_get_length(object) <= maximumUTF8Bytes,
              let pointer = unsafe xpc_string_get_string_ptr(object) else {
            return nil
        }
        return unsafe String(validatingCString: pointer)
    }

    private static func containsValue(
        _ dictionary: XPCDictionary,
        forKey key: String
    ) -> Bool {
        dictionary.withUnsafeUnderlyingDictionary { rawDictionary in
            unsafe key.withCString { pointer in
                unsafe xpc_dictionary_get_value(rawDictionary, pointer) != nil
            }
        }
    }

    private static func boundedError(_ source: String) -> String {
        var value = source.replacingOccurrences(of: "\0", with: "")
        if value.isEmpty {
            value = "The storage broker rejected the request."
        }
        while value.utf8.count > TorrentStorageBrokerProtocol.maximumErrorBytes {
            value.removeLast()
        }
        return value
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        append(UInt32(truncatingIfNeeded: value >> 32), to: &data)
        append(UInt32(truncatingIfNeeded: value), to: &data)
    }

    private static func readUInt32(_ data: Data, offset: inout Int) throws -> UInt32 {
        guard data.count - offset >= 4 else {
            throw TorrentStorageBrokerIPCError.malformedMessage
        }
        let value = UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
        offset += 4
        return value
    }

    private static func readUInt64(_ data: Data, offset: inout Int) throws -> UInt64 {
        let upper = try readUInt32(data, offset: &offset)
        let lower = try readUInt32(data, offset: &offset)
        return UInt64(upper) << 32 | UInt64(lower)
    }
}
