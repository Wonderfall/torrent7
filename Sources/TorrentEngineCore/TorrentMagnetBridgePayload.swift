import Foundation
import TorrentBridge
import TorrentEngineModel
import TorrentMetainfo

struct TorrentMagnetBridgePayload: Sendable {
    let header: TTorrentMagnetImport
    let blob: [UInt8]
    let trackers: [TTorrentMagnetTracker]
    let webSeeds: [TTorrentByteRange]
    let fileSelections: [TTorrentFileSelectionRange]

    init(_ magnet: ParsedMagnet) throws {
        var blob = [UInt8]()
        var header = TTorrentMagnetImport()
        header.schema_version = UInt32(TTORRENT_MAGNET_IMPORT_SCHEMA_VERSION)

        if let v1InfoHash = magnet.v1InfoHash {
            header.flags |= UInt32(TTORRENT_MAGNET_HAS_V1)
            // SAFETY: Ownership/lifetime: `header` and the Data value live through the
            // synchronous copy; bounds/alignment: validated v1 hashes are exactly the
            // imported 20-byte field size; synchronization: both values are local;
            // safe alternative: the imported fixed C array has no mutable Swift collection API.
            _ = unsafe withUnsafeMutableBytes(of: &header.v1_info_hash) { destination in
                _ = unsafe v1InfoHash.copyBytes(to: destination)
            }
        }
        if let v2InfoHash = magnet.v2InfoHash {
            header.flags |= UInt32(TTORRENT_MAGNET_HAS_V2)
            // SAFETY: Ownership/lifetime: `header` and the Data value live through the
            // synchronous copy; bounds/alignment: validated v2 hashes are exactly the
            // imported 32-byte field size; synchronization: both values are local;
            // safe alternative: the imported fixed C array has no mutable Swift collection API.
            _ = unsafe withUnsafeMutableBytes(of: &header.v2_info_hash) { destination in
                _ = unsafe v2InfoHash.copyBytes(to: destination)
            }
        }
        if let displayName = magnet.displayName {
            let range = try Self.append(displayName, to: &blob)
            header.display_name_offset = range.offset
            header.display_name_size = range.size
        }

        var trackerRecords = [TTorrentMagnetTracker]()
        trackerRecords.reserveCapacity(magnet.trackers.count)
        for tracker in magnet.trackers {
            let range = try Self.append(tracker.url, to: &blob)
            var record = TTorrentMagnetTracker()
            record.url_offset = range.offset
            record.url_size = range.size
            record.tier = tracker.tier
            trackerRecords.append(record)
        }

        var webSeedRecords = [TTorrentByteRange]()
        webSeedRecords.reserveCapacity(magnet.webSeeds.count)
        for webSeed in magnet.webSeeds {
            let range = try Self.append(webSeed, to: &blob)
            webSeedRecords.append(TTorrentByteRange(
                offset: range.offset,
                size: range.size
            ))
        }

        let selectionRecords: [TTorrentFileSelectionRange]
        if let selections = magnet.fileSelections {
            header.flags |= UInt32(TTORRENT_MAGNET_HAS_FILE_SELECTION)
            selectionRecords = selections.map {
                TTorrentFileSelectionRange(
                    first_index: $0.firstIndex,
                    last_index: $0.lastIndex
                )
            }
        } else {
            selectionRecords = []
        }

        self.header = header
        self.blob = blob
        trackers = trackerRecords
        webSeeds = webSeedRecords
        fileSelections = selectionRecords
    }

    private static func append(
        _ value: String,
        to blob: inout [UInt8]
    ) throws -> (offset: UInt32, size: UInt32) {
        guard let offset = UInt32(exactly: blob.count),
              let size = UInt32(exactly: value.utf8.count) else {
            throw TorrentEngineError.bridgeError(
                "The parsed magnet exceeds the native import range."
            )
        }
        blob.append(contentsOf: value.utf8)
        return (offset, size)
    }
}
