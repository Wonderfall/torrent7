import Foundation
import TorrentEngineIPC

@_cdecl("TorrentEngineIPCJSONPreflightFuzzOneInput")
public func torrentEngineIPCJSONPreflightFuzzOneInput(
    _ bytes: UnsafePointer<UInt8>?,
    _ byteCount: UInt
) {
    guard byteCount <= UInt(Int.max) else {
        return
    }
    let count = Int(byteCount)
    let data: Data
    if let bytes {
        data = Data(bytes: bytes, count: count)
    } else {
        guard count == 0 else {
            return
        }
        data = Data()
    }

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
