package import Foundation
import TorrentEngineModel
package import TorrentMetainfo
package import TorrentStorageAuthority

package enum TorrentMagnetEnvelopeError: LocalizedError, Equatable, Sendable {
    case promotedMetadataTooLarge

    package var errorDescription: String? {
        "The promoted torrent metadata exceeds the safe size limit."
    }
}

package extension ParsedMagnet {
    var storageInfoHashes: TorrentStorageInfoHashes {
        get throws {
            try TorrentStorageInfoHashes(v1: v1InfoHash, v2: v2InfoHash)
        }
    }

    var advertisedInfoHashes: TorrentAdvertisedInfoHashes {
        get throws {
            try TorrentAdvertisedInfoHashes(v1: v1InfoHash, v2: v2InfoHash)
        }
    }

    /// Builds a canonical top-level torrent dictionary while inserting the
    /// exact received info bytes verbatim. This is temporary promotion glue;
    /// the typed metainfo importer will remove this synthetic envelope.
    func torrentFile(exactInfoDictionary info: Data) throws -> Data {
        guard !info.isEmpty else {
            throw TorrentManifestError.metadataEmpty
        }
        var output = Data()
        output.reserveCapacity(min(
            TorrentInputLimits.maxTorrentFileBytes,
            info.count + trackers.reduce(0) { $0 + $1.url.utf8.count + 32 }
                + webSeeds.reduce(0) { $0 + $1.utf8.count + 16 }
                + 128
        ))
        output.append(UInt8(ascii: "d"))
        if let firstTracker = trackers.first {
            Self.appendBencoded("announce", to: &output)
            Self.appendBencoded(firstTracker.url, to: &output)
            Self.appendBencoded("announce-list", to: &output)
            output.append(UInt8(ascii: "l"))
            for tracker in trackers {
                output.append(UInt8(ascii: "l"))
                Self.appendBencoded(tracker.url, to: &output)
                output.append(UInt8(ascii: "e"))
            }
            output.append(UInt8(ascii: "e"))
        }
        Self.appendBencoded("info", to: &output)
        output.append(info)
        if !webSeeds.isEmpty {
            Self.appendBencoded("url-list", to: &output)
            output.append(UInt8(ascii: "l"))
            for webSeed in webSeeds {
                Self.appendBencoded(webSeed, to: &output)
            }
            output.append(UInt8(ascii: "e"))
        }
        output.append(UInt8(ascii: "e"))
        guard output.count <= TorrentInputLimits.maxTorrentFileBytes else {
            throw TorrentMagnetEnvelopeError.promotedMetadataTooLarge
        }
        return output
    }

    private static func appendBencoded(_ value: String, to output: inout Data) {
        let bytes = Data(value.utf8)
        output.append(Data("\(bytes.count):".utf8))
        output.append(bytes)
    }
}
