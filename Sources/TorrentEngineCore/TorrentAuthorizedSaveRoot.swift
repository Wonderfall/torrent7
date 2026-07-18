import Darwin
import Foundation
import TorrentBridge
import TorrentEngineModel

package func torrentAuthorizedSaveRootRetainCallback(
    _ context: UnsafeMutableRawPointer?
) {
    guard let context = unsafe context else {
        return
    }
    _ = unsafe Unmanaged<AnyObject>
        .fromOpaque(context)
        .retain()
}

package func torrentAuthorizedSaveRootReleaseCallback(
    _ context: UnsafeMutableRawPointer?
) {
    guard let context = unsafe context else {
        return
    }
    unsafe Unmanaged<AnyObject>
        .fromOpaque(context)
        .release()
}

/// A descriptor-backed download-root authority borrowed by the native bridge.
///
/// Construction duplicates the caller's descriptor before this value can cross
/// an actor boundary. The bridge duplicates it again for native ownership and
/// retains `lifetimeAnchor` for exactly as long as libtorrent can still use the
/// root, including pending-metadata torrents and asynchronous storage work.
@safe package final class TorrentAuthorizedSaveRoot: @unchecked Sendable {
    package let canonicalPath: String
    package let device: UInt64
    package let inode: UInt64

    private let directoryDescriptor: Int32
    private let lifetimeAnchor: any AnyObject & Sendable

    package init(
        canonicalPath: String,
        borrowingDirectoryDescriptor: Int32,
        device: UInt64,
        inode: UInt64,
        retaining lifetimeAnchor: any AnyObject & Sendable
    ) throws {
        let pathBytes = canonicalPath.utf8
        guard !pathBytes.isEmpty,
              pathBytes.count <= Int(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BYTES),
              !pathBytes.contains(0),
              (canonicalPath as NSString).isAbsolutePath,
              URL(filePath: canonicalPath)
                  .standardizedFileURL.path(percentEncoded: false) == canonicalPath else {
            throw TorrentEngineError.bridgeError(
                "An authorized download folder path is invalid."
            )
        }

        let duplicated = Darwin.fcntl(
            borrowingDirectoryDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        guard duplicated >= 0 else {
            if errno == EMFILE || errno == ENFILE {
                throw TorrentEngineError.authorizedRootCapacityReached(
                    "Too many download folders are still in use by active torrents."
                )
            }
            throw TorrentEngineError.bridgeError(
                "The authorized download folder descriptor is unavailable."
            )
        }

        var metadata = stat()
        guard unsafe Darwin.fstat(duplicated, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              device == UInt64(truncatingIfNeeded: metadata.st_dev),
              inode == UInt64(truncatingIfNeeded: metadata.st_ino) else {
            Darwin.close(duplicated)
            throw TorrentEngineError.bridgeError(
                "The authorized download folder descriptor identity does not match."
            )
        }

        self.canonicalPath = canonicalPath
        self.device = device
        self.inode = inode
        directoryDescriptor = duplicated
        self.lifetimeAnchor = lifetimeAnchor
    }

    deinit {
        Darwin.close(directoryDescriptor)
    }

    nonisolated func nativeRecord() -> TTorrentAuthorizedSaveRoot {
        unsafe TTorrentAuthorizedSaveRoot(
            directory_descriptor: directoryDescriptor,
            device: device,
            inode: inode,
            lifetime_context: Unmanaged<AnyObject>
                .passUnretained(lifetimeAnchor)
                .toOpaque()
        )
    }
}
