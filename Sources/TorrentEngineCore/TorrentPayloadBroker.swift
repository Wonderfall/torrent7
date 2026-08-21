import Darwin
import Foundation
import TorrentBridge

package struct TorrentPayloadBrokerCallError: Error, Sendable {
    package let errorNumber: Int32

    package init(errorNumber: Int32) {
        self.errorNumber = errorNumber > 0 ? errorNumber : EIO
    }
}

/// Synchronous disk-worker surface implemented by the engine-side XPC broker
/// client. Calls must be bounded and cancellation must wake blocked workers.
package protocol TorrentPayloadBrokerAccess: AnyObject, Sendable {
    nonisolated func openPayload(
        claimID: UUID,
        generation: UInt64,
        fileIndex: Int32,
        writable: Bool
    ) throws -> Int32

    nonisolated func payloadSize(
        claimID: UUID,
        generation: UInt64,
        fileIndex: Int32
    ) throws -> Int64
}

@safe package final class TorrentPayloadBrokerBridgeContext: Sendable {
    package let broker: any TorrentPayloadBrokerAccess

    package init(broker: any TorrentPayloadBrokerAccess) {
        self.broker = broker
    }
}

package func torrentPayloadContextRetainCallback(
    _ context: UnsafeMutableRawPointer?
) -> UInt8 {
    guard let context = unsafe context else {
        return 0
    }
    _ = unsafe Unmanaged<TorrentPayloadBrokerBridgeContext>
        .fromOpaque(context)
        .retain()
    return 1
}

package func torrentPayloadContextReleaseCallback(
    _ context: UnsafeMutableRawPointer?
) {
    guard let context = unsafe context else {
        return
    }
    unsafe Unmanaged<TorrentPayloadBrokerBridgeContext>
        .fromOpaque(context)
        .release()
}

private func claimUUID(_ bytes: UnsafePointer<UInt8>) -> UUID {
    let value: uuid_t = unsafe (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    )
    return UUID(uuid: value)
}

package func torrentPayloadOpenCallback(
    _ context: UnsafeMutableRawPointer?,
    _ claimIDBytes: UnsafePointer<UInt8>,
    _ generation: UInt64,
    _ fileIndex: Int32,
    _ writable: UInt8,
    _ descriptorOut: UnsafeMutablePointer<Int32>
) -> Int32 {
    guard let context = unsafe context,
          generation > 0,
          fileIndex >= 0,
          writable <= 1 else {
        return EINVAL
    }
    let claimID = unsafe claimUUID(claimIDBytes)
    let bridgeContext = unsafe Unmanaged<TorrentPayloadBrokerBridgeContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    do {
        let descriptor = try bridgeContext.broker.openPayload(
            claimID: claimID,
            generation: generation,
            fileIndex: fileIndex,
            writable: writable == 1
        )
        guard descriptor >= 0 else {
            return EBADF
        }
        unsafe descriptorOut.pointee = descriptor
        return 0
    } catch let error as TorrentPayloadBrokerCallError {
        return error.errorNumber
    } catch {
        return EIO
    }
}

package func torrentPayloadSizeCallback(
    _ context: UnsafeMutableRawPointer?,
    _ claimIDBytes: UnsafePointer<UInt8>,
    _ generation: UInt64,
    _ fileIndex: Int32,
    _ sizeOut: UnsafeMutablePointer<Int64>
) -> Int32 {
    guard let context = unsafe context,
          generation > 0,
          fileIndex >= 0 else {
        return EINVAL
    }
    let claimID = unsafe claimUUID(claimIDBytes)
    let bridgeContext = unsafe Unmanaged<TorrentPayloadBrokerBridgeContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    do {
        let size = try bridgeContext.broker.payloadSize(
            claimID: claimID,
            generation: generation,
            fileIndex: fileIndex
        )
        guard size >= 0 else {
            return EIO
        }
        unsafe sizeOut.pointee = size
        return 0
    } catch let error as TorrentPayloadBrokerCallError {
        return error.errorNumber
    } catch {
        return EIO
    }
}
