import Foundation
import Synchronization
package import TorrentEngineModel
import TorrentMetainfo
import TorrentStorageAuthority

/// One dialog-owned metadata request. Engine snapshots wake the waiter; it
/// never consumes the engine's single wake stream or polls a second session.
package final class TorrentMagnetPreviewOperation: Sendable {
    private let interruption = Mutex<(any Error)?>(nil)
    private let events: AsyncThrowingStream<Void, any Error>
    private let continuation: AsyncThrowingStream<Void, any Error>.Continuation

    package init() {
        (events, continuation) = AsyncThrowingStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    package func cancel() {
        fail(CancellationError())
    }

    package func fail(_ error: any Error) {
        interruption.withLock { if $0 == nil { $0 = error } }
        continuation.finish(throwing: error)
    }

    package func observe(_ torrent: TorrentItem) {
        if !torrent.error.isEmpty {
            fail(TorrentEngineError.bridgeError(torrent.error))
        } else if torrent.hasMetadata {
            continuation.yield()
        }
    }

    package func checkCancellation() throws {
        if let error = interruption.withLock({ $0 }) { throw error }
        try Task.checkCancellation()
    }

    package func load(
        magnet: String,
        torrentID: String,
        engine: any TorrentEngineServicing
    ) async throws -> TorrentFilePreview {
        defer { continuation.finish() }
        try checkCancellation()
        if let info = try await engine.torrentMetadata(id: torrentID) {
            return try await prepare(magnet: magnet, info: info)
        }
        for try await _ in events {
            try checkCancellation()
            if let info = try await engine.torrentMetadata(id: torrentID) {
                return try await prepare(magnet: magnet, info: info)
            }
        }
        throw CancellationError()
    }

    @concurrent
    private func prepare(magnet: String, info: Data) async throws -> TorrentFilePreview {
        try checkCancellation()
        let descriptor = try ParsedMagnet.parse(magnet, checkCancellation: checkCancellation)
        let data = try descriptor.torrentFile(exactInfoDictionary: info)
        let parsed = try TorrentManifestParser().parse(
            data,
            advertisedHashes: descriptor.advertisedInfoHashes,
            checkCancellation: checkCancellation
        )
        let preview = parsed.filePreview(
            torrentData: data,
            fileSelections: descriptor.fileSelections
        )
        try checkCancellation()
        return preview
    }
}
