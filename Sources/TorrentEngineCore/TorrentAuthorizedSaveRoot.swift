import Darwin
import Foundation
import Synchronization
import TorrentBridge
import TorrentEngineModel

package func torrentAuthorizedSaveRootRetainCallback(
    _ token: UInt64
) -> UInt8 {
    TorrentAuthorizedRootLifetimeRegistry.retain(token: token) ? 1 : 0
}

package func torrentAuthorizedSaveRootReleaseCallback(
    _ token: UInt64
) {
    TorrentAuthorizedRootLifetimeRegistry.release(token: token)
}

private enum TorrentAuthorizedRootLifetimeRegistry {
    private struct Entry: Sendable {
        let anchor: any AnyObject & Sendable
        var ownerIsAlive = true
        var nativeRetainCount = 0
    }

    private struct State: Sendable {
        var entries: [UInt64: Entry] = [:]
    }

    private static let state = Mutex(State())

    static func register(anchor: any AnyObject & Sendable) -> UInt64 {
        state.withLock { state in
            var token = UInt64.random(in: UInt64(1)..<UInt64.max)
            while state.entries[token] != nil {
                token = UInt64.random(in: UInt64(1)..<UInt64.max)
            }
            state.entries[token] = Entry(anchor: anchor)
            return token
        }
    }

    static func retain(token: UInt64) -> Bool {
        state.withLock { state in
            guard var entry = state.entries[token],
                  entry.ownerIsAlive,
                  entry.nativeRetainCount < Int.max else {
                return false
            }
            entry.nativeRetainCount += 1
            state.entries[token] = entry
            return true
        }
    }

    static func release(token: UInt64) {
        state.withLock { state in
            guard var entry = state.entries[token],
                  entry.nativeRetainCount > 0 else {
                return
            }
            entry.nativeRetainCount -= 1
            if !entry.ownerIsAlive && entry.nativeRetainCount == 0 {
                state.entries.removeValue(forKey: token)
            } else {
                state.entries[token] = entry
            }
        }
    }

    static func releaseOwner(token: UInt64) {
        state.withLock { state in
            guard var entry = state.entries[token] else {
                return
            }
            if entry.nativeRetainCount == 0 {
                state.entries.removeValue(forKey: token)
            } else {
                entry.ownerIsAlive = false
                state.entries[token] = entry
            }
        }
    }
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
    private let lifetimeToken: UInt64

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
        lifetimeToken = TorrentAuthorizedRootLifetimeRegistry.register(
            anchor: lifetimeAnchor
        )
    }

    deinit {
        TorrentAuthorizedRootLifetimeRegistry.releaseOwner(token: lifetimeToken)
        Darwin.close(directoryDescriptor)
    }

    nonisolated func nativeRecord() -> TTorrentAuthorizedSaveRoot {
        TTorrentAuthorizedSaveRoot(
            directory_descriptor: directoryDescriptor,
            device: device,
            inode: inode,
            lifetime_token: lifetimeToken
        )
    }
}
