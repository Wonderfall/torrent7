import Darwin
import Foundation
import TorrentEngineIPC
import XPC

private struct StorageBrokerByteCursor {
    private let bytes: Data
    private var offset = 0

    init(_ bytes: Data) {
        self.bytes = bytes
    }

    mutating func byte() -> UInt8 {
        guard offset < bytes.count else {
            return 0
        }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint64() -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 56, by: 8) {
            value |= UInt64(byte()) << UInt64(shift)
        }
        return value
    }

    mutating func data(maximumCount: Int) -> Data {
        let requested = Int(byte()) | Int(byte()) << 8
        let count = min(requested, maximumCount, bytes.count - offset)
        defer { offset += count }
        return bytes.subdata(in: offset..<(offset + count))
    }

    mutating func string(maximumCount: Int) -> String {
        String(decoding: data(maximumCount: maximumCount), as: UTF8.self)
    }
}

private enum StorageBrokerIPCFuzzer {
    private static let keys = [
        "v", "r", "e", "n", "d", "o", "c", "g", "i", "a",
        "is", "s", "f", "m", "md", "st", "fd", "path", "..", "",
    ]

    static func exercise(_ data: Data) {
        var requestCursor = StorageBrokerByteCursor(data)
        let requests = canonicalRequests(cursor: &requestCursor)
        for request in requests {
            var canonicalCursor = StorageBrokerByteCursor(data)
            exerciseCanonical(request, cursor: &canonicalCursor)
        }

        var hostileCursor = StorageBrokerByteCursor(data)
        let hostile = hostileDictionary(cursor: &hostileCursor)
        exerciseRequestDecoder(hostile)
        for request in requests {
            exerciseReplyDecoder(hostile, for: request)
        }
    }

    private static func canonicalRequests(
        cursor: inout StorageBrokerByteCursor
    ) -> [TorrentStorageBrokerRequest] {
        let common = TorrentStorageBrokerRequest.Common(
            requestID: UUID(uuidString: "10203040-5060-7080-90A0-B0C0D0E0F001")!,
            engineEpoch: UUID(uuidString: "10203040-5060-7080-90A0-B0C0D0E0F002")!,
            sessionNonce: UUID(uuidString: "10203040-5060-7080-90A0-B0C0D0E0F003")!,
            deadlineUptimeNanoseconds: max(1, cursor.uint64())
        )
        let claimID = UUID(uuidString: "10203040-5060-7080-90A0-B0C0D0E0F004")!
        let indexCount = 1 + Int(cursor.byte() % 16)
        let firstIndex = Int32(cursor.uint64() % 1_024)
        let indices = (0..<indexCount).map { firstIndex + Int32($0) }
        return [
            .handshake(common),
            .openPayload(
                common,
                claimID: claimID,
                generation: max(1, cursor.uint64()),
                fileIndex: Int32(cursor.uint64() % UInt64(Int32.max)),
                access: cursor.byte().isMultiple(of: 2) ? .readOnly : .readWrite
            ),
            .statBatch(
                common,
                claimID: claimID,
                generation: max(1, cursor.uint64()),
                fileIndices: indices
            ),
        ]
    }

    private static func exerciseCanonical(
        _ request: TorrentStorageBrokerRequest,
        cursor: inout StorageBrokerByteCursor
    ) {
        let decodedRequest = try! TorrentStorageBrokerIPCCodec.decodeRequest(
            TorrentStorageBrokerIPCCodec.encode(request)
        )
        fuzzAssert(decodedRequest == request)

        let failure = TorrentStorageBrokerReply.failure(
            requestID: request.common.requestID,
            code: TorrentStorageBrokerFailure(
                rawValue: 1 + cursor.uint64() % 9
            )!,
            message: cursor.string(maximumCount: 2_048)
        )
        roundTrip(failure, for: request)

        switch request {
        case .handshake:
            roundTrip(
                .success(
                    requestID: request.common.requestID,
                    metadata: nil,
                    statistics: [],
                    fileDescriptor: nil
                ),
                for: request
            )
        case .openPayload(_, _, _, let fileIndex, _):
            let descriptor = openNullDescriptor()
            fuzzAssert(descriptor >= 0)
            defer { _ = Darwin.close(descriptor) }
            roundTrip(
                .success(
                    requestID: request.common.requestID,
                    metadata: metadata(fileIndex: fileIndex, cursor: &cursor),
                    statistics: [],
                    fileDescriptor: descriptor
                ),
                for: request
            )
        case .statBatch(_, _, _, let indices):
            roundTrip(
                .success(
                    requestID: request.common.requestID,
                    metadata: nil,
                    statistics: indices.map {
                        metadata(fileIndex: $0, cursor: &cursor)
                    },
                    fileDescriptor: nil
                ),
                for: request
            )
        }
    }

    private static func metadata(
        fileIndex: Int32,
        cursor: inout StorageBrokerByteCursor
    ) -> TorrentStorageBrokerFileMetadata {
        TorrentStorageBrokerFileMetadata(
            fileIndex: fileIndex,
            size: Int64(bitPattern: cursor.uint64() & UInt64(Int64.max)),
            device: cursor.uint64(),
            inode: cursor.uint64(),
            linkCount: cursor.uint64(),
            mode: UInt32(truncatingIfNeeded: cursor.uint64())
        )
    }

    private static func hostileDictionary(
        cursor: inout StorageBrokerByteCursor
    ) -> XPCDictionary {
        var dictionary = XPCDictionary()
        let entryCount = 1 + Int(cursor.byte() % 20)
        for _ in 0..<entryCount {
            let key = keys[Int(cursor.byte()) % keys.count]
            switch cursor.byte() % 7 {
            case 0:
                dictionary[key] = cursor.uint64()
            case 1:
                dictionary[key] = Int64(bitPattern: cursor.uint64())
            case 2:
                dictionary[key] = !cursor.byte().isMultiple(of: 2)
            case 3:
                dictionary[key] = cursor.string(maximumCount: 2_048)
            case 4:
                dictionary[key] = xpcData(cursor.data(maximumCount: 4_096))
            case 5:
                dictionary[key] = Double(bitPattern: cursor.uint64())
            default:
                let descriptor = openNullDescriptor()
                if descriptor >= 0 {
                    dictionary[key] = xpc_fd_create(descriptor)
                    _ = Darwin.close(descriptor)
                }
            }
        }
        return dictionary
    }

    private static func exerciseRequestDecoder(_ dictionary: XPCDictionary) {
        guard let request = try? TorrentStorageBrokerIPCCodec.decodeRequest(dictionary) else {
            return
        }
        let roundTripped = try! TorrentStorageBrokerIPCCodec.decodeRequest(
            TorrentStorageBrokerIPCCodec.encode(request)
        )
        fuzzAssert(roundTripped == request)
    }

    private static func exerciseReplyDecoder(
        _ dictionary: XPCDictionary,
        for request: TorrentStorageBrokerRequest
    ) {
        guard let reply = try? TorrentStorageBrokerIPCCodec.decodeReply(
            dictionary,
            for: request
        ) else {
            return
        }
        defer { closeDescriptor(in: reply) }
        roundTrip(reply, for: request)
    }

    private static func roundTrip(
        _ reply: TorrentStorageBrokerReply,
        for request: TorrentStorageBrokerRequest
    ) {
        let encoded = try! TorrentStorageBrokerIPCCodec.encode(reply, for: request)
        let decoded = try! TorrentStorageBrokerIPCCodec.decodeReply(encoded, for: request)
        defer { closeDescriptor(in: decoded) }
        fuzzAssert(equivalent(reply, decoded))
    }

    private static func equivalent(
        _ left: TorrentStorageBrokerReply,
        _ right: TorrentStorageBrokerReply
    ) -> Bool {
        switch (left, right) {
        case let (
            .failure(leftID, leftCode, leftMessage),
            .failure(rightID, rightCode, rightMessage)
        ):
            let expectedMessage = boundedError(leftMessage)
            return leftID == rightID
                && leftCode == rightCode
                && expectedMessage == rightMessage
        case let (
            .success(leftID, leftMetadata, leftStatistics, leftDescriptor),
            .success(rightID, rightMetadata, rightStatistics, rightDescriptor)
        ):
            return leftID == rightID
                && leftMetadata == rightMetadata
                && leftStatistics == rightStatistics
                && (leftDescriptor == nil) == (rightDescriptor == nil)
        default:
            return false
        }
    }

    private static func boundedError(_ source: String) -> String {
        var value = String(source.unicodeScalars.filter { $0.value != 0 })
        if value.isEmpty {
            value = "The storage broker rejected the request."
        }
        while value.utf8.count > TorrentStorageBrokerProtocol.maximumErrorBytes {
            value.removeLast()
        }
        return value
    }

    private static func closeDescriptor(in reply: TorrentStorageBrokerReply) {
        guard case .success(_, _, _, let descriptor) = reply,
              let descriptor else {
            return
        }
        _ = Darwin.close(descriptor)
    }

    // SAFETY: Ownership/lifetime: Data pins its bytes for the synchronous call and XPC copies
    // them; bounds/alignment: exact count is passed with byte alignment; synchronization:
    // immutable fuzz input is not mutated; safe alternative: constructing adversarial XPC data
    // requires xpc_data_create's C pointer API.
    private static func xpcData(_ data: Data) -> xpc_object_t {
        unsafe data.withUnsafeBytes { bytes in
            unsafe xpc_data_create(bytes.baseAddress, bytes.count)
        }
    }

    // SAFETY: Ownership/lifetime: the returned descriptor is owned and closed by each caller,
    // while the temporary C string lives through open; bounds/alignment: withCString supplies
    // an aligned NUL-terminated path; synchronization: each invocation creates independent
    // descriptor state; safe alternative: the XPC descriptor codec requires a raw Int32 file
    // descriptor, which Foundation does not expose as a transfer-safe value.
    private static func openNullDescriptor() -> Int32 {
        unsafe "/dev/null".withCString { path in
            unsafe Darwin.open(path, O_RDONLY | O_CLOEXEC)
        }
    }

    private static func fuzzAssert(_ condition: @autoclosure () -> Bool) {
        if !condition() {
            Darwin.abort()
        }
    }
}

// SAFETY: Ownership/lifetime: libFuzzer keeps bytes alive for this synchronous call;
// bounds/alignment: its ABI supplies byteCount readable UInt8 values and the helper checks
// nullability and Int conversion; synchronization: the input is immutable and call-local;
// safe alternative: the @c libFuzzer entry ABI requires a raw pointer/count pair.
@c(TorrentStorageBrokerIPCFuzzOneInput)
public func torrentStorageBrokerIPCFuzzOneInput(
    _ bytes: UnsafePointer<UInt8>?,
    _ byteCount: UInt
) {
    guard let data = unsafe copiedIPCFuzzInput(bytes, byteCount) else {
        return
    }
    autoreleasepool {
        StorageBrokerIPCFuzzer.exercise(data)
    }
}
