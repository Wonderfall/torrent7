import Foundation
import TorrentEngineIPC

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
    }
}
