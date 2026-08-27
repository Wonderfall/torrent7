import Darwin
import Foundation
import TorrentBridge
import TorrentEngineModel
import TorrentMetainfo

/// Lifetime anchor for the synchronous Swift parser installed into libtorrent.
/// Parsing itself is stateless and never enters an actor or suspension point.
@safe package final class TorrentSwarmMetainfoParserBridgeContext: Sendable {
    package init() {}
}

package func torrentSwarmMetainfoContextRetainCallback(
    _ context: UnsafeMutableRawPointer?
) -> UInt8 {
    guard let context = unsafe context else {
        return 0
    }
    _ = unsafe Unmanaged<TorrentSwarmMetainfoParserBridgeContext>
        .fromOpaque(context)
        .retain()
    return 1
}

package func torrentSwarmMetainfoContextReleaseCallback(
    _ context: UnsafeMutableRawPointer?
) {
    guard let context = unsafe context else {
        return
    }
    unsafe Unmanaged<TorrentSwarmMetainfoParserBridgeContext>
        .fromOpaque(context)
        .release()
}

package func torrentSwarmMetainfoParseCallback(
    _ context: UnsafeMutableRawPointer?,
    _ info: UnsafePointer<CChar>,
    _ infoSize: Int32,
    _ resultOut: UnsafeMutablePointer<TTorrentOwnedMetainfoCapsule>
) -> Int32 {
    unsafe resultOut.pointee = TTorrentOwnedMetainfoCapsule(bytes: nil, size: 0)
    guard unsafe context != nil,
          infoSize > 0,
          infoSize <= Int32(TorrentInputLimits.maxTorrentFileBytes) else {
        return EINVAL
    }

    do {
        let input = unsafe Data(bytes: info, count: Int(infoSize))
        let parsed = try TorrentMetainfoParser().parseInfoDictionary(input)
        let capsule = try TorrentMetainfoBridgeCapsule(parsed).bytes
        guard !capsule.isEmpty,
              capsule.count <= Int(TTORRENT_METAINFO_CAPSULE_MAX_BYTES),
              let outputSize = Int32(exactly: capsule.count) else {
            return EOVERFLOW
        }
        guard let allocation = unsafe Darwin.malloc(capsule.count) else {
            return ENOMEM
        }
        unsafe capsule.withUnsafeBytes { source in
            unsafe allocation.copyMemory(
                from: source.baseAddress!,
                byteCount: source.count
            )
        }
        unsafe resultOut.pointee = TTorrentOwnedMetainfoCapsule(
            bytes: allocation.assumingMemoryBound(to: UInt8.self),
            size: outputSize
        )
        return 0
    } catch {
        return EINVAL
    }
}

package func torrentSwarmMetainfoCapsuleReleaseCallback(
    _ context: UnsafeMutableRawPointer?,
    _ capsule: TTorrentOwnedMetainfoCapsule
) {
    guard unsafe context != nil,
          let bytes = unsafe capsule.bytes else {
        return
    }
    unsafe Darwin.free(bytes)
}
