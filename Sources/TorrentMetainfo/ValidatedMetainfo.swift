import Foundation
import TorrentEngineModel

package enum ValidatedMetainfoKind: UInt8, Equatable, Sendable {
    case v1
    case v2
    case hybrid
}

package enum ValidatedMetainfoContentKind: UInt8, Equatable, Sendable {
    case singleFile
    case directory
}

/// A byte range into immutable bytes owned by `ValidatedMetainfo` or
/// `ValidatedInfoDictionary`. Fixed-width fields keep later capsule lowering
/// from silently narrowing an unbounded native `Int`.
package struct ValidatedMetainfoRange: Equatable, Sendable {
    package let offset: UInt32
    package let size: UInt32

    package var range: Range<Int> {
        let lowerBound = Int(offset)
        return lowerBound..<(lowerBound + Int(size))
    }

    init?(_ range: Range<Int>) {
        guard range.lowerBound >= 0,
              range.upperBound >= range.lowerBound,
              let offset = UInt32(exactly: range.lowerBound),
              let size = UInt32(exactly: range.count) else {
            return nil
        }
        self.offset = offset
        self.size = size
    }
}

package struct ValidatedMetainfoFile: Equatable, Sendable {
    package let index: Int32
    package let pathComponents: [String]
    package let expectedSize: Int64
    package let isPadding: Bool
    package let isExecutable: Bool
    package let isHidden: Bool
    package let piecesRootRange: ValidatedMetainfoRange?

    init(
        index: Int32,
        pathComponents: [String],
        expectedSize: Int64,
        isPadding: Bool,
        isExecutable: Bool,
        isHidden: Bool,
        piecesRootRange: ValidatedMetainfoRange?
    ) {
        self.index = index
        self.pathComponents = pathComponents
        self.expectedSize = expectedSize
        self.isPadding = isPadding
        self.isExecutable = isExecutable
        self.isHidden = isHidden
        self.piecesRootRange = piecesRootRange
    }
}

/// The hash-defining and layout-defining subset of metainfo. This deliberately
/// contains no save path, priorities, peers, resume state, or runtime flags.
package struct ValidatedInfoCore: Equatable, Sendable {
    package let kind: ValidatedMetainfoKind
    package let infoDictionaryRange: ValidatedMetainfoRange
    package let wireName: String?
    package let effectiveName: String
    package let contentKind: ValidatedMetainfoContentKind
    package let v1InfoHash: Data?
    package let v2InfoHash: Data?
    package let pieceLength: Int64
    package let totalSize: Int64
    package let isPrivate: Bool
    package let files: [ValidatedMetainfoFile]
    package let v1PieceHashesRange: ValidatedMetainfoRange?

    init(
        kind: ValidatedMetainfoKind,
        infoDictionaryRange: ValidatedMetainfoRange,
        wireName: String?,
        effectiveName: String,
        contentKind: ValidatedMetainfoContentKind,
        v1InfoHash: Data?,
        v2InfoHash: Data?,
        pieceLength: Int64,
        totalSize: Int64,
        isPrivate: Bool,
        files: [ValidatedMetainfoFile],
        v1PieceHashesRange: ValidatedMetainfoRange?
    ) {
        self.kind = kind
        self.infoDictionaryRange = infoDictionaryRange
        self.wireName = wireName
        self.effectiveName = effectiveName
        self.contentKind = contentKind
        self.v1InfoHash = v1InfoHash
        self.v2InfoHash = v2InfoHash
        self.pieceLength = pieceLength
        self.totalSize = totalSize
        self.isPrivate = isPrivate
        self.files = files
        self.v1PieceHashesRange = v1PieceHashesRange
    }
}

package struct ValidatedMetainfoTracker: Equatable, Sendable {
    package let url: String
    package let tier: UInt8

    package init(url: String, tier: UInt8) {
        self.url = url
        self.tier = tier
    }
}

package struct ValidatedPieceLayer: Equatable, Sendable {
    package let piecesRootRange: ValidatedMetainfoRange
    package let hashesRange: ValidatedMetainfoRange
    package let fileIndices: [Int32]

    init(
        piecesRootRange: ValidatedMetainfoRange,
        hashesRange: ValidatedMetainfoRange,
        fileIndices: [Int32]
    ) {
        self.piecesRootRange = piecesRootRange
        self.hashesRange = hashesRange
        self.fileIndices = fileIndices
    }
}

package struct ValidatedTorrentEnvelopeFields: OptionSet, Equatable, Sendable {
    package let rawValue: UInt16

    package init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    package static let announce = Self(rawValue: 1 << 0)
    package static let announceList = Self(rawValue: 1 << 1)
    package static let urlList = Self(rawValue: 1 << 2)
    package static let pieceLayers = Self(rawValue: 1 << 3)
    package static let comment = Self(rawValue: 1 << 4)
    package static let createdBy = Self(rawValue: 1 << 5)
    package static let creationDate = Self(rawValue: 1 << 6)
    package static let dhtNodes = Self(rawValue: 1 << 7)
}

package struct ValidatedTorrentEnvelope: Equatable, Sendable {
    package let presentFields: ValidatedTorrentEnvelopeFields
    package let trackers: [ValidatedMetainfoTracker]
    package let webSeeds: [String]
    package let pieceLayers: [ValidatedPieceLayer]
    package let comment: String?
    package let createdBy: String?
    package let creationDate: Int64?

    package var hasIgnoredDHTNodesField: Bool {
        presentFields.contains(.dhtNodes)
    }

    init(
        presentFields: ValidatedTorrentEnvelopeFields = [],
        trackers: [ValidatedMetainfoTracker],
        webSeeds: [String],
        pieceLayers: [ValidatedPieceLayer] = [],
        comment: String? = nil,
        createdBy: String? = nil,
        creationDate: Int64? = nil
    ) {
        self.presentFields = presentFields
        self.trackers = trackers
        self.webSeeds = webSeeds
        self.pieceLayers = pieceLayers
        self.comment = comment
        self.createdBy = createdBy
        self.creationDate = creationDate
    }

    package var sourceSecuritySummary: TorrentSourceSecuritySummary {
        TorrentSourceSecuritySummary(
            trackerCount: trackers.count,
            httpsTrackerCount: trackers.count(where: { Self.isHTTPS($0.url) }),
            webSeedCount: webSeeds.count,
            httpsWebSeedCount: webSeeds.count(where: Self.isHTTPS)
        )
    }

    private static func isHTTPS(_ url: String) -> Bool {
        guard let separator = url.firstIndex(of: ":") else {
            return false
        }
        return url[..<separator].caseInsensitiveCompare("https") == .orderedSame
    }
}

/// One validated metainfo input. The original bytes remain owned here so all
/// ranges in the core and envelope stay valid without copying attacker-sized
/// strings or the hash-defining info dictionary.
package struct ValidatedMetainfo: Equatable, Sendable {
    package let metadata: Data
    package let infoCore: ValidatedInfoCore
    package let envelope: ValidatedTorrentEnvelope

    init(
        metadata: Data,
        infoCore: ValidatedInfoCore,
        envelope: ValidatedTorrentEnvelope
    ) {
        self.metadata = metadata
        self.infoCore = infoCore
        self.envelope = envelope
    }

    package var infoDictionary: Data.SubSequence {
        metadata[infoCore.infoDictionaryRange.range]
    }
}

/// A validated bare info dictionary, as exchanged by BEP 9. It deliberately
/// has no torrent envelope because trackers, web seeds, and piece layers are
/// not part of swarm metadata.
package struct ValidatedInfoDictionary: Equatable, Sendable {
    package let bytes: Data
    package let infoCore: ValidatedInfoCore

    init(bytes: Data, infoCore: ValidatedInfoCore) {
        self.bytes = bytes
        self.infoCore = infoCore
    }

    package var infoDictionary: Data.SubSequence {
        bytes[infoCore.infoDictionaryRange.range]
    }
}

package typealias TorrentMetainfoTracker = ValidatedMetainfoTracker
package typealias TorrentMetainfoEnvelope = ValidatedTorrentEnvelope
