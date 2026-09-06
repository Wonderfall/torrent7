import Foundation
import TorrentEngineIPC
import TorrentEngineModel
import XPC

// SAFETY: Ownership/lifetime: libFuzzer owns the input buffer for the synchronous export
// call and Data copies it before returning; bounds/alignment: byteCount must describe the
// readable allocation, UInt8 has alignment one, and conversion to Int is checked;
// synchronization: the immutable input is copied into call-local storage; safe alternative:
// libFuzzer's C ABI provides input only as a pointer/count pair.
func copiedIPCFuzzInput(
    _ bytes: UnsafePointer<UInt8>?,
    _ byteCount: UInt
) -> Data? {
    guard byteCount <= UInt(Int.max) else {
        return nil
    }
    let count = Int(byteCount)
    guard unsafe bytes != nil || count == 0 else {
        return nil
    }
    guard let bytes = unsafe bytes else {
        return Data()
    }
    return unsafe Data(bytes: bytes, count: count)
}

// SAFETY: Ownership/lifetime: libFuzzer keeps bytes alive for this synchronous call;
// bounds/alignment: its ABI supplies byteCount readable UInt8 values and the helper checks
// nullability and Int conversion; synchronization: the input is immutable and call-local;
// safe alternative: the @c libFuzzer entry ABI requires a raw pointer/count pair.
@c(TorrentEngineIPCJSONPreflightFuzzOneInput)
public func torrentEngineIPCJSONPreflightFuzzOneInput(
    _ bytes: UnsafePointer<UInt8>?,
    _ byteCount: UInt
) {
    guard let data = unsafe copiedIPCFuzzInput(bytes, byteCount) else {
        return
    }

    autoreleasepool {
        // Exercise both early operation-sized rejection and the largest profile
        // accepted anywhere in the protocol. The scanner must remain linear and
        // safe for arbitrary bytes whether either profile accepts or rejects.
        _ = try? TorrentEngineIPCJSONCodec.preflightForFuzzing(
            data,
            limits: TorrentEngineIPCLimits.smallJSONLimits
        )
        _ = try? TorrentEngineIPCJSONCodec.preflightForFuzzing(
            data,
            limits: TorrentEngineIPCLimits.maximumJSONLimits
        )
        checkQueueRestoration(data)
        checkEnvelopeKeys(data)
    }
}

private func checkEnvelopeKeys(_ data: Data) {
    let identifier = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    let header = TorrentEngineIPCHeader(
        requestID: identifier, controllerID: identifier, sequence: 1,
        operation: .changeHint, operationID: identifier, expectedEpoch: nil
    )
    do {
        var request = try TorrentEngineIPCEnvelopeCodec.encode(
            TorrentEngineIPCRequest(header: header), maximumPayloadBytes: 0
        )
        var reply = try TorrentEngineIPCEnvelopeCodec.encode(
            TorrentEngineIPCReply(header: header, engineEpoch: identifier, status: .success),
            maximumPayloadBytes: 0
        )
        // The prefix keeps even NUL-containing or replacement-decoded names
        // outside the schema. Vary both name length and dictionary cardinality.
        let key = "unknown-" + String(decoding: data, as: UTF8.self)
        request[key] = true
        reply[key] = true
        for index in 0..<Int(data.first ?? 0) {
            request["unknown-\(index)"] = true
            reply["unknown-\(index)"] = true
        }
        do {
            _ = try TorrentEngineIPCEnvelopeCodec.inspectRequest(request)
            preconditionFailure("An unknown request field was accepted.")
        } catch {
            precondition(error as? TorrentEngineIPCError == .unknownFields)
        }
        do {
            _ = try TorrentEngineIPCEnvelopeCodec.decodeReply(reply, maximumPayloadBytes: 0)
            preconditionFailure("An unknown reply field was accepted.")
        } catch {
            precondition(error as? TorrentEngineIPCError == .unknownFields)
        }
    } catch {
        preconditionFailure("A canonical envelope could not be encoded.")
    }
}

private func checkQueueRestoration(_ data: Data) {
    let operation = TorrentEngineIPCOperation.restoreQueuePosition
    guard let request = try? TorrentEngineIPCJSONCodec.decode(
        TorrentEngineIPCRestoreQueuePositionRequest.self,
        from: data,
        maximumBytes: operation.maximumRequestPayloadBytes,
        limits: operation.requestJSONLimits
    ) else {
        return
    }
    precondition((0..<TorrentEngineLimits.maximumTorrentSnapshotCount)
        .contains(Int(request.position.rawValue)))
    do {
        let encoded = try TorrentEngineIPCJSONCodec.encode(
            request,
            maximumBytes: operation.maximumRequestPayloadBytes,
            limits: operation.requestJSONLimits
        )
        let decoded = try TorrentEngineIPCJSONCodec.decode(
            TorrentEngineIPCRestoreQueuePositionRequest.self,
            from: encoded,
            maximumBytes: operation.maximumRequestPayloadBytes,
            limits: operation.requestJSONLimits
        )
        precondition(decoded == request)
    } catch {
        preconditionFailure("An accepted queue restoration request did not round trip.")
    }
}
