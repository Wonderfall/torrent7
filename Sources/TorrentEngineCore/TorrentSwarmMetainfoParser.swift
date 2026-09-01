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
    // SAFETY: Ownership/lifetime: the pointer came from Unmanaged.passRetained and this
    // callback adds the native owner's requested retain; bounds/alignment: it addresses
    // the exact class instance with no indexed bytes; synchronization: ARC retain is
    // thread-safe; safe alternative: a C callback context cannot carry a Swift reference.
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
    // SAFETY: Ownership/lifetime: native releases exactly one retain previously accepted
    // by the paired callback; bounds/alignment: the opaque pointer still addresses the exact
    // class instance with no indexed bytes; synchronization: ARC release is thread-safe;
    // safe alternative: a C callback context cannot carry a Swift reference.
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
    // SAFETY: Ownership/lifetime: C++ retains the context and input for this synchronous
    // callback, then owns the successful malloc allocation until the paired release callback;
    // bounds/alignment: the typed input size is capped, malloc alignment is sufficient, and
    // exactly capsule.count bytes are copied; synchronization: each allocation is independent;
    // safe alternative: the C ABI requires a malloc-owned result that C++ can release later.
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
        return unsafe capsule.withUnsafeBytes { source in
            guard let sourceAddress = source.baseAddress else {
                return EINVAL
            }
            guard let allocation = unsafe Darwin.malloc(source.count) else {
                return ENOMEM
            }
            unsafe allocation.copyMemory(
                from: sourceAddress,
                byteCount: source.count
            )
            unsafe resultOut.pointee = TTorrentOwnedMetainfoCapsule(
                bytes: allocation.assumingMemoryBound(to: UInt8.self),
                size: outputSize
            )
            return 0
        }
    } catch {
        return EINVAL
    }
}

package func torrentSwarmMetainfoCapsuleReleaseCallback(
    _ context: UnsafeMutableRawPointer?,
    _ capsule: TTorrentOwnedMetainfoCapsule
) {
    // SAFETY: Ownership/lifetime: a nonnil pointer is the unique allocation returned by the
    // paired parse callback and native releases it once; bounds/alignment: free accepts that
    // original malloc pointer without dereferencing it; synchronization: ownership transfer
    // prevents concurrent reuse; safe alternative: the C ABI cannot return Swift-managed Data.
    guard unsafe context != nil,
          let bytes = unsafe capsule.bytes else {
        return
    }
    unsafe Darwin.free(bytes)
}
