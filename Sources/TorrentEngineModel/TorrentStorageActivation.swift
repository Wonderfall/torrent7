import Foundation

package enum TorrentStorageActivationError: LocalizedError, Sendable {
    case invalidGeneration
    case invalidManifestDigest
    case invalidPreservedTorrentID

    package var errorDescription: String? {
        switch self {
        case .invalidGeneration:
            "The storage claim generation is invalid."
        case .invalidManifestDigest:
            "The storage claim manifest digest is invalid."
        case .invalidPreservedTorrentID:
            "The torrent identity selected for promotion is invalid."
        }
    }
}

/// Immutable, pathless authority identifying the GUI-owned storage claim used
/// for one known torrent activation.
package struct TorrentStorageActivation: Codable, Equatable, Sendable {
    package let claimID: UUID
    package let generation: UInt64
    package let sourceManifestDigest: Data
    package let preservedTorrentID: String?

    package init(
        claimID: UUID,
        generation: UInt64,
        sourceManifestDigest: Data,
        preservedTorrentID: String? = nil
    ) throws {
        guard generation > 0, generation <= UInt64(Int64.max) else {
            throw TorrentStorageActivationError.invalidGeneration
        }
        guard sourceManifestDigest.count == 32,
              sourceManifestDigest.contains(where: { $0 != 0 }) else {
            throw TorrentStorageActivationError.invalidManifestDigest
        }
        if let preservedTorrentID,
           !Self.isCanonicalTorrentID(preservedTorrentID) {
            throw TorrentStorageActivationError.invalidPreservedTorrentID
        }
        self.claimID = claimID
        self.generation = generation
        self.sourceManifestDigest = sourceManifestDigest
        self.preservedTorrentID = preservedTorrentID
    }

    private enum CodingKeys: String, CodingKey {
        case claimID
        case generation
        case sourceManifestDigest
        case preservedTorrentID
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            claimID: container.decode(UUID.self, forKey: .claimID),
            generation: container.decode(UInt64.self, forKey: .generation),
            sourceManifestDigest: container.decode(Data.self, forKey: .sourceManifestDigest),
            preservedTorrentID: container.decodeIfPresent(
                String.self,
                forKey: .preservedTorrentID
            )
        )
    }

    package static func isCanonicalTorrentID(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == 34,
              bytes.starts(with: "t:".utf8) else {
            return false
        }
        return bytes.dropFirst(2).allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }
}
