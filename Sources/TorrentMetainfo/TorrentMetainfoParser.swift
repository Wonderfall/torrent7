import CryptoKit
import Foundation
import TorrentEngineModel

package enum TorrentManifestError: LocalizedError, Equatable, Sendable {
    case metadataEmpty
    case metadataTooLarge
    case malformedBencoding
    case nestingLimitExceeded
    case valueLimitExceeded
    case stringLimitExceeded
    case missingInfoDictionary
    case invalidInfoHashes
    case advertisedInfoHashMismatch
    case unsupportedMetadataVersion
    case missingName
    case invalidName
    case invalidPieceLength
    case invalidPieceHashes
    case missingFileTree
    case missingFiles
    case tooManyFiles
    case invalidFileLength
    case invalidFilePath
    case symlinkNotSupported
    case invalidV2PiecesRoot
    case invalidPieceLayers
    case unsupportedSSLTorrent
    case unsupportedMutableTorrent
    case invalidHumanReadableField
    case workLimitExceeded
    case invalidSourceURL
    case tooManyTrackers
    case tooManyWebSeeds
    case duplicatePath
    case conflictingPath
    case inconsistentHybridLayout
    case emptyPayload

    package var errorDescription: String? {
        switch self {
        case .metadataEmpty: "The torrent metadata is empty."
        case .metadataTooLarge: "The torrent metadata exceeds the safe size limit."
        case .malformedBencoding: "The torrent metadata is not canonical bencoding."
        case .nestingLimitExceeded: "The torrent metadata is nested too deeply."
        case .valueLimitExceeded: "The torrent metadata contains too many values."
        case .stringLimitExceeded: "The torrent metadata contains an oversized string."
        case .missingInfoDictionary: "The torrent metadata has no info dictionary."
        case .invalidInfoHashes: "The torrent metadata has no applicable info hash."
        case .advertisedInfoHashMismatch: "The received metadata does not match the advertised info hash."
        case .unsupportedMetadataVersion: "The torrent metadata version is unsupported."
        case .missingName: "The torrent has no usable name."
        case .invalidName: "The torrent name is unsafe."
        case .invalidPieceLength: "The torrent piece length is invalid."
        case .invalidPieceHashes: "The torrent piece hashes do not match its layout."
        case .missingFileTree: "The v2 torrent has no file tree."
        case .missingFiles: "The torrent has no files."
        case .tooManyFiles: "The torrent contains too many files."
        case .invalidFileLength: "A torrent file has an invalid length."
        case .invalidFilePath: "A torrent file has an unsafe path."
        case .symlinkNotSupported: "Torrent symlinks are not supported."
        case .invalidV2PiecesRoot: "A v2 torrent file has an invalid pieces root."
        case .invalidPieceLayers: "The v2 torrent contains invalid or incomplete piece layers."
        case .unsupportedSSLTorrent: "SSL torrents are not supported."
        case .unsupportedMutableTorrent: "Mutable torrent metadata is not supported."
        case .invalidHumanReadableField: "A descriptive torrent field is invalid."
        case .workLimitExceeded: "The torrent metadata exceeds the safe parsing work limit."
        case .invalidSourceURL: "The torrent contains an invalid tracker or web seed URL."
        case .tooManyTrackers: "The torrent contains too many trackers."
        case .tooManyWebSeeds: "The torrent contains too many web seeds."
        case .duplicatePath: "The torrent contains duplicate or equivalent file paths."
        case .conflictingPath: "A torrent file path conflicts with another file or directory."
        case .inconsistentHybridLayout: "The v1 and v2 torrent layouts do not match."
        case .emptyPayload: "The torrent payload is empty."
        }
    }
}

package struct TorrentAdvertisedInfoHashes: Equatable, Sendable {
    package let v1: Data?
    package let v2: Data?

    package init(v1: Data? = nil, v2: Data? = nil) throws {
        guard v1 == nil || v1?.count == Insecure.SHA1.byteCount,
              v2 == nil || v2?.count == SHA256.byteCount,
              v1 != nil || v2 != nil else {
            throw TorrentManifestError.invalidInfoHashes
        }
        self.v1 = v1
        self.v2 = v2
    }
}

package struct TorrentMetainfoParser: Sendable {
    package struct Limits: Equatable, Sendable {
        // The native importer uses libtorrent's fixed-width file and offset
        // representation. Keep parser admission within those invariants so a
        // validated core cannot fail later solely because of integer width.
        package static let nativeMaximumFileBytes =
            (Int64(Int32.max) / 2) * 16_384 - 1
        package static let nativeMaximumPayloadBytes =
            (Int64(1) << 48) - 1
        package static let nativeMaximumPieceCount = Int(Int32.max) / 2

        package var maximumMetadataBytes = TorrentInputLimits.maxTorrentFileBytes
        package var maximumNestingDepth = 32
        package var maximumValueCount = 400_000
        package var maximumStringBytes = TorrentInputLimits.maxTorrentFileBytes
        package var maximumContainerCount = 100_000
        package var maximumDictionaryKeyBytes = 8 * 1_024 * 1_024
        package var maximumIntegerDigits = 19
        package var maximumStringLengthDigits = 19
        package var maximumPathComponentBytes = 255
        package var maximumPathDepth = 32
        package var maximumFileCount = TorrentEngineLimits.maximumFileCount
        package var maximumTrackerCount = TorrentEngineLimits.maximumTrackerCount
        package var maximumTrackerTierCount = Int(UInt8.max) + 1
        package var maximumWebSeedCount = TorrentEngineLimits.maximumWebSeedCount
        package var maximumSourceURLBytes = 16 * 1_024
        package var maximumAggregateSourceBytes = 1 * 1_024 * 1_024
        package var maximumPathComponentCount = 200_000
        package var maximumPathBytes = 8 * 1_024 * 1_024
        package var maximumFileBytes = nativeMaximumFileBytes
        package var maximumPayloadBytes = nativeMaximumPayloadBytes
        package var maximumPieceCount = 1_000_000
        package var maximumV1PieceHashBytes = 20 * 1_024 * 1_024
        package var maximumPieceLayerHashCount = 1_000_000
        package var maximumPieceLayerBytes = 32 * 1_024 * 1_024
        package var maximumCommentBytes = 16 * 1_024
        package var maximumCreatorBytes = 4 * 1_024
        package var maximumHumanReadableBytes = 32 * 1_024

        package static let standard = Limits()
    }

    private let limits: Limits

    private enum InputKind {
        case torrentFile
        case infoDictionary
    }

    private struct ParsedInput {
        let metadata: Data
        let infoCore: ValidatedInfoCore
        let envelope: TorrentMetainfoEnvelope?
    }

    private final class CancellationPoller {
        private let checkCancellation: @Sendable () throws -> Void
        private var pendingWork = 0

        init(_ checkCancellation: @escaping @Sendable () throws -> Void) {
            self.checkCancellation = checkCancellation
        }

        func recordWork(_ count: Int = 1) throws {
            let next = pendingWork.addingReportingOverflow(count)
            guard !next.overflow else {
                try checkNow()
                return
            }
            pendingWork = next.partialValue
            if pendingWork >= 256 {
                pendingWork %= 256
                try checkCancellation()
            }
        }

        func checkNow() throws {
            pendingWork = 0
            try checkCancellation()
        }
    }

    package init(limits: Limits = .standard) {
        self.limits = limits
    }

    package func parse(
        _ metadata: Data,
        advertisedHashes: TorrentAdvertisedInfoHashes? = nil,
        checkCancellation: @escaping @Sendable () throws -> Void = {}
    ) throws -> ValidatedMetainfo {
        let parsed = try parseInput(
            metadata,
            kind: .torrentFile,
            advertisedHashes: advertisedHashes,
            checkCancellation: checkCancellation
        )
        guard let envelope = parsed.envelope else {
            throw TorrentManifestError.malformedBencoding
        }
        return ValidatedMetainfo(
            metadata: parsed.metadata,
            infoCore: parsed.infoCore,
            envelope: envelope
        )
    }

    package func parseInfoDictionary(
        _ infoDictionary: Data,
        advertisedHashes: TorrentAdvertisedInfoHashes? = nil,
        checkCancellation: @escaping @Sendable () throws -> Void = {}
    ) throws -> ValidatedInfoDictionary {
        let parsed = try parseInput(
            infoDictionary,
            kind: .infoDictionary,
            advertisedHashes: advertisedHashes,
            checkCancellation: checkCancellation
        )
        return ValidatedInfoDictionary(
            bytes: parsed.metadata,
            infoCore: parsed.infoCore
        )
    }

    private func parseInput(
        _ metadata: Data,
        kind: InputKind,
        advertisedHashes: TorrentAdvertisedInfoHashes?,
        checkCancellation: @escaping @Sendable () throws -> Void
    ) throws -> ParsedInput {
        guard limitsAreValid else {
            throw TorrentManifestError.workLimitExceeded
        }
        // Data slices preserve their source indices. Normalize once so all
        // retained offsets are capsule-ready and relative to the owned input.
        let metadata = metadata.startIndex == 0 ? metadata : Data(metadata)
        let cancellation = CancellationPoller(checkCancellation)
        try cancellation.checkNow()
        guard !metadata.isEmpty else {
            throw TorrentManifestError.metadataEmpty
        }
        guard metadata.count <= limits.maximumMetadataBytes else {
            throw TorrentManifestError.metadataTooLarge
        }

        let document: BencodeRangeDocument
        do {
            document = try BencodeRangeDocument.scan(
                metadata,
                limits: BencodeScanLimits(
                    maximumNestingDepth: limits.maximumNestingDepth,
                    maximumValueCount: limits.maximumValueCount,
                    maximumStringBytes: limits.maximumStringBytes,
                    maximumContainerCount: limits.maximumContainerCount,
                    maximumDictionaryKeyBytes: limits.maximumDictionaryKeyBytes,
                    maximumIntegerDigits: limits.maximumIntegerDigits,
                    maximumStringLengthDigits: limits.maximumStringLengthDigits
                ),
                checkCancellation: cancellation.checkNow
            )
        } catch let error as BencodeScanError {
            throw manifestError(for: error)
        }
        let root = document.rootIndex
        guard document.kind(at: root) == .dictionary else {
            throw TorrentManifestError.malformedBencoding
        }
        let topLevel: Int?
        let info: Int
        switch kind {
        case .torrentFile:
            topLevel = root
            guard let nestedInfo = value(named: "info", in: root, document: document),
                  document.kind(at: nestedInfo) == .dictionary else {
                throw TorrentManifestError.missingInfoDictionary
            }
            info = nestedInfo
        case .infoDictionary:
            topLevel = nil
            info = root
        }
        let infoValues = info
        let infoRange = document.encodedRange(at: info)
        if value(named: "ssl-cert", in: infoValues, document: document) != nil {
            throw TorrentManifestError.unsupportedSSLTorrent
        }
        let hasTopLevelMutableFields = if let topLevel {
            value(named: "similar", in: topLevel, document: document) != nil
                || value(named: "collections", in: topLevel, document: document) != nil
        } else {
            false
        }
        if value(named: "similar", in: infoValues, document: document) != nil
            || value(named: "collections", in: infoValues, document: document) != nil
            || hasTopLevelMutableFields {
            throw TorrentManifestError.unsupportedMutableTorrent
        }

        try cancellation.checkNow()
        let version = try optionalInteger(
            named: "meta version",
            in: infoValues,
            document: document
        )
        guard version == nil || version == 2 else {
            throw TorrentManifestError.unsupportedMetadataVersion
        }
        let hasV2 = version == 2
        let hasV1Layout = value(named: "files", in: infoValues, document: document) != nil
            || value(named: "length", in: infoValues, document: document) != nil
        guard hasV1Layout || hasV2 else {
            throw TorrentManifestError.missingFiles
        }

        let rawInfo = metadata[infoRange]
        let v1Hash = hasV1Layout ? Data(Insecure.SHA1.hash(data: rawInfo)) : nil
        let v2Hash = hasV2 ? Data(SHA256.hash(data: rawInfo)) : nil
        try verify(advertisedHashes, v1Hash: v1Hash, v2Hash: v2Hash)

        let pieceLength = try requiredInteger(
            named: "piece length",
            in: infoValues,
            document: document
        )
        guard pieceLength > 0, pieceLength <= 128 * 1_024 * 1_024 else {
            throw TorrentManifestError.invalidPieceLength
        }
        if hasV2 {
            guard pieceLength >= 16 * 1_024,
                  pieceLength.nonzeroBitCount == 1 else {
                throw TorrentManifestError.invalidPieceLength
            }
        }

        let isPrivate = try optionalInteger(
            named: "private",
            in: infoValues,
            document: document
        )
            .map { $0 != 0 } ?? false

        let parsedName = try parseOptionalName(infoValues, document: document)
        let v1Layout = hasV1Layout
            ? try parseV1Layout(
                infoValues,
                name: parsedName,
                document: document,
                cancellation: cancellation
            )
            : nil
        let v2Layout = hasV2
            ? try parseV2Layout(
                infoValues,
                name: parsedName,
                pieceLength: pieceLength,
                document: document,
                cancellation: cancellation
            )
            : nil

        let selected: ParsedLayout
        if let v1Layout, let v2Layout {
            selected = try validateHybrid(
                v1: v1Layout,
                v2: v2Layout,
                cancellation: cancellation
            )
        } else if let v1Layout {
            selected = v1Layout
        } else if let v2Layout {
            selected = v2Layout
        } else {
            throw TorrentManifestError.missingFiles
        }

        guard selected.files.count <= limits.maximumFileCount else {
            throw TorrentManifestError.tooManyFiles
        }
        guard selected.files.contains(where: { $0.expectedSize > 0 && !$0.isPadding }) else {
            throw TorrentManifestError.emptyPayload
        }
        try validatePathSet(selected.files, cancellation: cancellation)
        var totalSize: Int64 = 0
        for file in selected.files {
            try cancellation.recordWork()
            totalSize = try adding(totalSize, file.expectedSize)
            guard totalSize <= limits.maximumPayloadBytes else {
                throw TorrentManifestError.invalidFileLength
            }
        }
        let totalPieceCount64 = totalSize == 0
            ? 0
            : (totalSize - 1) / pieceLength + 1
        guard let totalPieceCount = Int(exactly: totalPieceCount64),
              totalPieceCount <= limits.maximumPieceCount else {
            throw TorrentManifestError.workLimitExceeded
        }
        let v1PieceHashesRange: Range<Int>?
        if hasV1Layout {
            v1PieceHashesRange = try validateV1PieceHashes(
                infoValues,
                pieceCount: totalPieceCount,
                document: document
            )
        } else {
            v1PieceHashesRange = nil
        }

        let name: String
        if let parsedName {
            name = parsedName
        } else if hasV2, let v2Hash {
            name = "Torrent-" + Self.hex(v2Hash.prefix(6))
        } else {
            throw TorrentManifestError.missingName
        }
        try validateComponent(name, isTopLevel: true)

        guard let validatedInfoRange = ValidatedMetainfoRange(infoRange) else {
            throw TorrentManifestError.malformedBencoding
        }
        let validatedPieceHashesRange: ValidatedMetainfoRange?
        if let v1PieceHashesRange {
            guard let range = ValidatedMetainfoRange(v1PieceHashesRange) else {
                throw TorrentManifestError.malformedBencoding
            }
            validatedPieceHashesRange = range
        } else {
            validatedPieceHashesRange = nil
        }
        var coreFiles = [ValidatedMetainfoFile]()
        coreFiles.reserveCapacity(selected.files.count)
        for (offset, file) in selected.files.enumerated() {
            try cancellation.recordWork()
            guard let index = Int32(exactly: offset) else {
                throw TorrentManifestError.tooManyFiles
            }
            let piecesRootRange: ValidatedMetainfoRange?
            if let sourceRange = file.piecesRootRange {
                guard let range = ValidatedMetainfoRange(sourceRange) else {
                    throw TorrentManifestError.malformedBencoding
                }
                piecesRootRange = range
            } else {
                piecesRootRange = nil
            }
            coreFiles.append(ValidatedMetainfoFile(
                index: index,
                pathComponents: file.pathComponents,
                expectedSize: file.expectedSize,
                isPadding: file.isPadding,
                isExecutable: file.isExecutable,
                isHidden: file.isHidden,
                piecesRootRange: piecesRootRange
            ))
        }
        let metainfoKind: ValidatedMetainfoKind = if hasV1Layout && hasV2 {
            .hybrid
        } else if hasV2 {
            .v2
        } else {
            .v1
        }
        let infoCore = ValidatedInfoCore(
            kind: metainfoKind,
            infoDictionaryRange: validatedInfoRange,
            wireName: parsedName,
            effectiveName: name,
            contentKind: selected.contentKind,
            v1InfoHash: v1Hash,
            v2InfoHash: v2Hash,
            pieceLength: pieceLength,
            totalSize: totalSize,
            isPrivate: isPrivate,
            files: coreFiles,
            v1PieceHashesRange: validatedPieceHashesRange
        )
        let envelope: TorrentMetainfoEnvelope?
        if let topLevel {
            envelope = try parseEnvelope(
                topLevel,
                infoCore: infoCore,
                document: document,
                cancellation: cancellation
            )
        } else {
            envelope = nil
        }
        try cancellation.checkNow()
        return ParsedInput(
            metadata: metadata,
            infoCore: infoCore,
            envelope: envelope
        )
    }

    private func parseEnvelope(
        _ topLevel: Int,
        infoCore: ValidatedInfoCore,
        document: BencodeRangeDocument,
        cancellation: CancellationPoller
    ) throws -> TorrentMetainfoEnvelope {
        var aggregateSourceBytes = 0
        let trackers = try parseTrackers(
            topLevel,
            document: document,
            cancellation: cancellation,
            aggregateSourceBytes: &aggregateSourceBytes
        )
        let webSeeds = try parseWebSeeds(
            topLevel,
            document: document,
            cancellation: cancellation,
            aggregateSourceBytes: &aggregateSourceBytes
        )
        let pieceLayers = try parsePieceLayers(
            topLevel,
            infoCore: infoCore,
            document: document,
            cancellation: cancellation
        )
        let comment = try optionalHumanReadableString(
            preferredName: "comment.utf-8",
            fallbackName: "comment",
            maximumBytes: limits.maximumCommentBytes,
            in: topLevel,
            document: document
        )
        let createdBy = try optionalHumanReadableString(
            preferredName: "created by.utf-8",
            fallbackName: "created by",
            maximumBytes: limits.maximumCreatorBytes,
            in: topLevel,
            document: document
        )
        let humanReadableBytes = try addingWork(
            comment?.utf8.count ?? 0,
            createdBy?.utf8.count ?? 0
        )
        guard humanReadableBytes <= limits.maximumHumanReadableBytes else {
            throw TorrentManifestError.workLimitExceeded
        }
        let rawCreationDate = try optionalInteger(
            named: "creation date",
            in: topLevel,
            document: document
        )
        var presentFields = ValidatedTorrentEnvelopeFields()
        if value(named: "announce", in: topLevel, document: document) != nil {
            presentFields.insert(.announce)
        }
        if value(named: "announce-list", in: topLevel, document: document) != nil {
            presentFields.insert(.announceList)
        }
        if value(named: "url-list", in: topLevel, document: document) != nil {
            presentFields.insert(.urlList)
        }
        if value(named: "piece layers", in: topLevel, document: document) != nil {
            presentFields.insert(.pieceLayers)
        }
        if value(named: "comment.utf-8", in: topLevel, document: document) != nil
            || value(named: "comment", in: topLevel, document: document) != nil {
            presentFields.insert(.comment)
        }
        if value(named: "created by.utf-8", in: topLevel, document: document) != nil
            || value(named: "created by", in: topLevel, document: document) != nil {
            presentFields.insert(.createdBy)
        }
        if value(named: "creation date", in: topLevel, document: document) != nil {
            presentFields.insert(.creationDate)
        }
        if value(named: "nodes", in: topLevel, document: document) != nil {
            presentFields.insert(.dhtNodes)
        }
        return TorrentMetainfoEnvelope(
            presentFields: presentFields,
            trackers: trackers,
            webSeeds: webSeeds,
            pieceLayers: pieceLayers,
            comment: comment,
            createdBy: createdBy,
            creationDate: rawCreationDate.flatMap { $0 >= 0 ? $0 : nil }
        )
    }

    private func parseTrackers(
        _ topLevel: Int,
        document: BencodeRangeDocument,
        cancellation: CancellationPoller,
        aggregateSourceBytes: inout Int
    ) throws -> [TorrentMetainfoTracker] {
        var trackers = [TorrentMetainfoTracker]()
        if let announceList = value(
            named: "announce-list",
            in: topLevel,
            document: document
        ) {
            guard document.kind(at: announceList) == .list else {
                throw TorrentManifestError.malformedBencoding
            }
            trackers.reserveCapacity(min(
                document.childCount(of: announceList),
                limits.maximumTrackerCount
            ))
            var tierNode = document.firstChild(of: announceList)
            var tierIndex = 0
            while let currentTier = tierNode {
                try cancellation.recordWork()
                guard tierIndex < limits.maximumTrackerTierCount,
                      let validatedTier = UInt8(exactly: tierIndex) else {
                    throw TorrentManifestError.tooManyTrackers
                }
                guard document.kind(at: currentTier) == .list else {
                    throw TorrentManifestError.malformedBencoding
                }
                var entry = document.firstChild(of: currentTier)
                while let currentEntry = entry {
                    try cancellation.recordWork()
                    guard let range = document.stringRange(at: currentEntry) else {
                        throw TorrentManifestError.malformedBencoding
                    }
                    guard let url = try parsedSourceURL(
                        range,
                        document: document,
                        allowedSchemes: ["http", "https", "udp"]
                    ) else {
                        entry = document.nextSibling(of: currentEntry)
                        continue
                    }
                    guard trackers.count < limits.maximumTrackerCount else {
                        throw TorrentManifestError.tooManyTrackers
                    }
                    try accountSourceBytes(
                        url,
                        aggregateSourceBytes: &aggregateSourceBytes
                    )
                    trackers.append(TorrentMetainfoTracker(
                        url: url,
                        tier: validatedTier
                    ))
                    entry = document.nextSibling(of: currentEntry)
                }
                tierNode = document.nextSibling(of: currentTier)
                tierIndex += 1
            }
        }

        if trackers.isEmpty,
           let announce = value(named: "announce", in: topLevel, document: document) {
            guard let range = document.stringRange(at: announce) else {
                throw TorrentManifestError.malformedBencoding
            }
            if let url = try parsedSourceURL(
                range,
                document: document,
                allowedSchemes: ["http", "https", "udp"]
            ) {
                guard limits.maximumTrackerCount > 0 else {
                    throw TorrentManifestError.tooManyTrackers
                }
                try accountSourceBytes(
                    url,
                    aggregateSourceBytes: &aggregateSourceBytes
                )
                trackers.append(TorrentMetainfoTracker(url: url, tier: 0))
            }
        }
        return trackers
    }

    private func parseWebSeeds(
        _ topLevel: Int,
        document: BencodeRangeDocument,
        cancellation: CancellationPoller,
        aggregateSourceBytes: inout Int
    ) throws -> [String] {
        guard let node = value(named: "url-list", in: topLevel, document: document) else {
            return []
        }

        var seen = Set<String>()
        var webSeeds = [String]()
        webSeeds.reserveCapacity(min(
            document.childCount(of: node),
            limits.maximumWebSeedCount
        ))
        switch document.kind(at: node) {
        case .string:
            if let range = document.stringRange(at: node), !range.isEmpty {
                try appendWebSeed(
                    range,
                    document: document,
                    seen: &seen,
                    webSeeds: &webSeeds,
                    aggregateSourceBytes: &aggregateSourceBytes
                )
            }
        case .list:
            var value = document.firstChild(of: node)
            while let current = value {
                try cancellation.recordWork()
                guard let range = document.stringRange(at: current) else {
                    throw TorrentManifestError.malformedBencoding
                }
                if !range.isEmpty {
                    try appendWebSeed(
                        range,
                        document: document,
                        seen: &seen,
                        webSeeds: &webSeeds,
                        aggregateSourceBytes: &aggregateSourceBytes
                    )
                }
                value = document.nextSibling(of: current)
            }
        default:
            throw TorrentManifestError.malformedBencoding
        }
        return webSeeds
    }

    private func appendWebSeed(
        _ range: Range<Int>,
        document: BencodeRangeDocument,
        seen: inout Set<String>,
        webSeeds: inout [String],
        aggregateSourceBytes: inout Int
    ) throws {
        guard let url = try parsedSourceURL(
            range,
            document: document,
            allowedSchemes: ["http", "https"]
        ), seen.insert(url).inserted else {
            return
        }
        guard webSeeds.count < limits.maximumWebSeedCount else {
            throw TorrentManifestError.tooManyWebSeeds
        }
        try accountSourceBytes(
            url,
            aggregateSourceBytes: &aggregateSourceBytes
        )
        webSeeds.append(url)
    }

    private func accountSourceBytes(
        _ source: String,
        aggregateSourceBytes: inout Int
    ) throws {
        aggregateSourceBytes = try addingWork(
            aggregateSourceBytes,
            source.utf8.count
        )
        guard aggregateSourceBytes <= limits.maximumAggregateSourceBytes else {
            throw TorrentManifestError.workLimitExceeded
        }
    }

    private typealias MerkleHash = SIMD32<UInt8>

    private struct PieceLayerRequirement {
        let expectedHashCount: Int
        var fileIndices: [Int32]
    }

    private func parsePieceLayers(
        _ topLevel: Int,
        infoCore: ValidatedInfoCore,
        document: BencodeRangeDocument,
        cancellation: CancellationPoller
    ) throws -> [ValidatedPieceLayer] {
        guard let dictionary = value(
            named: "piece layers",
            in: topLevel,
            document: document
        ) else {
            // Torrent7 deliberately permits metadata-like v2 torrents whose
            // complete piece layers will be acquired later.
            return []
        }
        guard infoCore.kind != .v1,
              document.kind(at: dictionary) == .dictionary else {
            throw TorrentManifestError.invalidPieceLayers
        }

        var requirements = [MerkleHash: PieceLayerRequirement]()
        var requiredHashCount = 0
        var requiredHashBytes = 0
        for file in infoCore.files
        where !file.isPadding && file.expectedSize > infoCore.pieceLength {
            try cancellation.recordWork()
            guard let rootRange = file.piecesRootRange,
                  rootRange.range.upperBound <= document.data.count else {
                throw TorrentManifestError.invalidPieceLayers
            }
            let pieceCount64 = (file.expectedSize - 1) / infoCore.pieceLength + 1
            guard let pieceCount = Int(exactly: pieceCount64) else {
                throw TorrentManifestError.invalidPieceLayers
            }
            guard pieceCount <= limits.maximumPieceLayerHashCount else {
                throw TorrentManifestError.workLimitExceeded
            }
            guard let root = merkleHash(in: rootRange.range, document: document) else {
                throw TorrentManifestError.invalidPieceLayers
            }
            if var existing = requirements[root] {
                guard existing.expectedHashCount == pieceCount else {
                    throw TorrentManifestError.invalidPieceLayers
                }
                existing.fileIndices.append(file.index)
                requirements[root] = existing
            } else {
                requiredHashCount = try addingWork(requiredHashCount, pieceCount)
                let pieceBytes = pieceCount.multipliedReportingOverflow(
                    by: SHA256.byteCount
                )
                guard !pieceBytes.overflow else {
                    throw TorrentManifestError.workLimitExceeded
                }
                requiredHashBytes = try addingWork(
                    requiredHashBytes,
                    pieceBytes.partialValue
                )
                guard requiredHashCount <= limits.maximumPieceLayerHashCount,
                      requiredHashBytes <= limits.maximumPieceLayerBytes else {
                    throw TorrentManifestError.workLimitExceeded
                }
                requirements[root] = PieceLayerRequirement(
                    expectedHashCount: pieceCount,
                    fileIndices: [file.index]
                )
            }
        }

        var layers = [ValidatedPieceLayer]()
        layers.reserveCapacity(min(
            document.childCount(of: dictionary),
            requirements.count
        ))
        var seenRoots = Set<MerkleHash>()
        var totalHashes = 0
        var totalBytes = 0
        var entry = document.firstChild(of: dictionary)
        while let valueIndex = entry {
            try cancellation.recordWork()
            guard let rootRange = document.dictionaryKeyRange(forChild: valueIndex),
                  rootRange.count == SHA256.byteCount,
                  let hashesRange = document.stringRange(at: valueIndex),
                  hashesRange.count.isMultiple(of: SHA256.byteCount),
                  let validatedRootRange = ValidatedMetainfoRange(rootRange),
                  let validatedHashesRange = ValidatedMetainfoRange(hashesRange) else {
                throw TorrentManifestError.invalidPieceLayers
            }
            guard let root = merkleHash(in: rootRange, document: document) else {
                throw TorrentManifestError.invalidPieceLayers
            }
            guard let requirement = requirements[root],
                  !seenRoots.contains(root),
                  hashesRange.count / SHA256.byteCount
                    == requirement.expectedHashCount else {
                throw TorrentManifestError.invalidPieceLayers
            }
            let nextHashes = totalHashes.addingReportingOverflow(requirement.expectedHashCount)
            let nextBytes = totalBytes.addingReportingOverflow(hashesRange.count)
            guard !nextHashes.overflow,
                  !nextBytes.overflow,
                  nextHashes.partialValue <= limits.maximumPieceLayerHashCount,
                  nextBytes.partialValue <= limits.maximumPieceLayerBytes else {
                throw TorrentManifestError.workLimitExceeded
            }
            guard try verifyPieceLayerRoot(
                hashesRange,
                expectedRoot: root,
                pieceLength: infoCore.pieceLength,
                document: document,
                cancellation: cancellation
            ) else {
                throw TorrentManifestError.invalidPieceLayers
            }
            totalHashes = nextHashes.partialValue
            totalBytes = nextBytes.partialValue
            seenRoots.insert(root)
            layers.append(ValidatedPieceLayer(
                piecesRootRange: validatedRootRange,
                hashesRange: validatedHashesRange,
                fileIndices: requirement.fileIndices
            ))
            entry = document.nextSibling(of: valueIndex)
        }

        guard seenRoots.count == requirements.count else {
            throw TorrentManifestError.invalidPieceLayers
        }
        return layers
    }

    private func verifyPieceLayerRoot(
        _ hashesRange: Range<Int>,
        expectedRoot: MerkleHash,
        pieceLength: Int64,
        document: BencodeRangeDocument,
        cancellation: CancellationPoller
    ) throws -> Bool {
        let hashCount = hashesRange.count / SHA256.byteCount
        guard hashCount > 0,
              pieceLength >= 16 * 1_024,
              pieceLength.isMultiple(of: 16 * 1_024),
              let blocksPerPiece = Int(exactly: pieceLength / (16 * 1_024)) else {
            return false
        }

        var scratch = Data()
        scratch.reserveCapacity(SHA256.byteCount * 2)
        var piecePadding = MerkleHash(repeating: 0)
        var coveredBlocks = 1
        while coveredBlocks < blocksPerPiece {
            piecePadding = combinedSHA256(
                piecePadding,
                piecePadding,
                scratch: &scratch
            )
            let doubled = coveredBlocks.multipliedReportingOverflow(by: 2)
            guard !doubled.overflow else {
                return false
            }
            coveredBlocks = doubled.partialValue
        }
        guard coveredBlocks == blocksPerPiece else {
            return false
        }

        var leafCapacity = 1
        while leafCapacity < hashCount {
            let doubled = leafCapacity.multipliedReportingOverflow(by: 2)
            guard !doubled.overflow else {
                return false
            }
            leafCapacity = doubled.partialValue
        }
        var stack = [MerkleHash?](repeating: nil, count: Int.bitWidth)
        var cursor = hashesRange.lowerBound
        for _ in 0..<hashCount {
            try cancellation.recordWork()
            let end = cursor + SHA256.byteCount
            guard let leaf = merkleHash(in: cursor..<end, document: document) else {
                return false
            }
            addMerkleLeaf(
                leaf,
                to: &stack,
                scratch: &scratch
            )
            cursor = end
        }
        for _ in hashCount..<leafCapacity {
            try cancellation.recordWork()
            addMerkleLeaf(piecePadding, to: &stack, scratch: &scratch)
        }
        var root: MerkleHash?
        for node in stack {
            guard let node else {
                continue
            }
            guard root == nil else {
                return false
            }
            root = node
        }
        return root == expectedRoot
    }

    private func addMerkleLeaf(
        _ leaf: MerkleHash,
        to stack: inout [MerkleHash?],
        scratch: inout Data
    ) {
        var node = leaf
        var level = 0
        while let left = stack[level] {
            stack[level] = nil
            node = combinedSHA256(left, node, scratch: &scratch)
            level += 1
        }
        stack[level] = node
    }

    private func combinedSHA256(
        _ left: MerkleHash,
        _ right: MerkleHash,
        scratch: inout Data
    ) -> MerkleHash {
        scratch.removeAll(keepingCapacity: true)
        for index in 0..<SHA256.byteCount {
            scratch.append(left[index])
        }
        for index in 0..<SHA256.byteCount {
            scratch.append(right[index])
        }
        var result = MerkleHash(repeating: 0)
        for (index, byte) in SHA256.hash(data: scratch).enumerated() {
            result[index] = byte
        }
        return result
    }

    private func merkleHash(
        in range: Range<Int>,
        document: BencodeRangeDocument
    ) -> MerkleHash? {
        guard range.count == SHA256.byteCount,
              range.lowerBound >= 0,
              range.upperBound <= document.data.count else {
            return nil
        }
        var result = MerkleHash(repeating: 0)
        for index in 0..<SHA256.byteCount {
            result[index] = document.data[range.lowerBound + index]
        }
        return result
    }

    private func optionalHumanReadableString(
        preferredName: String,
        fallbackName: String,
        maximumBytes: Int,
        in dictionary: Int,
        document: BencodeRangeDocument
    ) throws -> String? {
        if let preferred = value(
            named: preferredName,
            in: dictionary,
            document: document
        ) {
            let result = try humanReadableString(
                preferred,
                maximumBytes: maximumBytes,
                document: document
            )
            if !result.isEmpty {
                return result
            }
        }
        guard let fallback = value(
            named: fallbackName,
            in: dictionary,
            document: document
        ) else {
            return nil
        }
        let result = try humanReadableString(
            fallback,
            maximumBytes: maximumBytes,
            document: document
        )
        return result.isEmpty ? nil : result
    }

    private func humanReadableString(
        _ node: Int,
        maximumBytes: Int,
        document: BencodeRangeDocument
    ) throws -> String {
        guard let range = document.stringRange(at: node),
              range.count <= maximumBytes,
              let result = String(bytes: document.data[range], encoding: .utf8),
              !result.unicodeScalars.contains(where: {
                  $0.value == 0
                      || ($0.value < 0x20 && $0.value != 0x0a && $0.value != 0x09)
                      || $0.value == 0x7f
              }) else {
            throw TorrentManifestError.invalidHumanReadableField
        }
        return result
    }

    private func parsedSourceURL(
        _ range: Range<Int>,
        document: BencodeRangeDocument,
        allowedSchemes: Set<String>
    ) throws -> String? {
        guard range.count <= limits.maximumSourceURLBytes else {
            throw TorrentManifestError.invalidSourceURL
        }
        guard let url = String(bytes: document.data[range], encoding: .utf8),
              TorrentSourceURLValidator.isValid(
                url,
                maximumBytes: limits.maximumSourceURLBytes,
                allowedSchemes: allowedSchemes
              ) else {
            return nil
        }
        return url
    }

    private struct UnindexedFile: Equatable {
        var pathComponents: [String]
        let expectedSize: Int64
        let isPadding: Bool
        let isExecutable: Bool
        let isHidden: Bool
        let piecesRootRange: Range<Int>?

        init(
            pathComponents: [String],
            expectedSize: Int64,
            isPadding: Bool,
            isExecutable: Bool = false,
            isHidden: Bool = false,
            piecesRootRange: Range<Int>? = nil
        ) {
            self.pathComponents = pathComponents
            self.expectedSize = expectedSize
            self.isPadding = isPadding
            self.isExecutable = isExecutable
            self.isHidden = isHidden
            self.piecesRootRange = piecesRootRange
        }
    }

    private struct ParsedLayout {
        let contentKind: ValidatedMetainfoContentKind
        let files: [UnindexedFile]
    }

    private func parseV1Layout(
        _ info: Int,
        name: String?,
        document: BencodeRangeDocument,
        cancellation: CancellationPoller
    ) throws -> ParsedLayout {
        if let filesNode = value(named: "files", in: info, document: document) {
            guard let name else {
                throw TorrentManifestError.missingName
            }
            try validateComponent(name, isTopLevel: true)
            guard document.kind(at: filesNode) == .list,
                  document.childCount(of: filesNode) > 0 else {
                throw TorrentManifestError.missingFiles
            }
            guard document.childCount(of: filesNode) <= limits.maximumFileCount else {
                throw TorrentManifestError.tooManyFiles
            }
            var files = [UnindexedFile]()
            files.reserveCapacity(document.childCount(of: filesNode))
            var entry = document.firstChild(of: filesNode)
            while let dictionary = entry {
                try cancellation.recordWork()
                guard document.kind(at: dictionary) == .dictionary else {
                    throw TorrentManifestError.malformedBencoding
                }
                let size = try validatedFileSize(requiredInteger(
                    named: "length",
                    in: dictionary,
                    document: document
                ))
                let attributes = try optionalStringRange(
                    named: "attr",
                    in: dictionary,
                    document: document
                )
                if attributes.map({ document.data[$0].contains(UInt8(ascii: "l")) }) == true
                    || value(named: "symlink path", in: dictionary, document: document) != nil {
                    throw TorrentManifestError.symlinkNotSupported
                }
                let isPadding = attributes.map {
                    document.data[$0].contains(UInt8(ascii: "p"))
                } == true
                let isExecutable = attributes.map {
                    document.data[$0].contains(UInt8(ascii: "x"))
                } == true
                let isHidden = attributes.map {
                    document.data[$0].contains(UInt8(ascii: "h"))
                } == true
                let components: [String]
                if isPadding {
                    // Libtorrent canonicalizes padding entries to this
                    // synthetic logical path regardless of the source path.
                    components = [".pad", "\(size)-\(files.count)"]
                } else {
                    let pathNode = value(
                        named: "path.utf-8",
                        in: dictionary,
                        document: document
                    ) ?? value(named: "path", in: dictionary, document: document)
                    guard let pathNode else {
                        throw TorrentManifestError.invalidFilePath
                    }
                    components = try parsePathList(pathNode, document: document)
                }
                files.append(UnindexedFile(
                    pathComponents: components,
                    expectedSize: size,
                    isPadding: isPadding,
                    isExecutable: isExecutable,
                    isHidden: isHidden
                ))
                entry = document.nextSibling(of: dictionary)
            }
            return ParsedLayout(contentKind: .directory, files: files)
        }

        guard let name else {
            throw TorrentManifestError.missingName
        }
        try validateComponent(name, isTopLevel: true)
        let size = try validatedFileSize(requiredInteger(
            named: "length",
            in: info,
            document: document
        ))
        let attributes = try optionalStringRange(
            named: "attr",
            in: info,
            document: document
        )
        if attributes.map({ document.data[$0].contains(UInt8(ascii: "l")) }) == true
            || value(named: "symlink path", in: info, document: document) != nil {
            throw TorrentManifestError.symlinkNotSupported
        }
        guard attributes.map({ document.data[$0].contains(UInt8(ascii: "p")) }) != true else {
            throw TorrentManifestError.invalidFilePath
        }
        return ParsedLayout(
            contentKind: .singleFile,
            files: [UnindexedFile(
                pathComponents: [name],
                expectedSize: size,
                isPadding: false,
                isExecutable: attributes.map {
                    document.data[$0].contains(UInt8(ascii: "x"))
                } == true,
                isHidden: attributes.map {
                    document.data[$0].contains(UInt8(ascii: "h"))
                } == true
            )]
        )
    }

    private func parseV2Layout(
        _ info: Int,
        name: String?,
        pieceLength: Int64,
        document: BencodeRangeDocument,
        cancellation: CancellationPoller
    ) throws -> ParsedLayout {
        guard let tree = value(named: "file tree", in: info, document: document),
              document.kind(at: tree) == .dictionary else {
            throw TorrentManifestError.missingFileTree
        }

        var rawFiles = [UnindexedFile]()
        try walkV2Tree(
            tree,
            document: document,
            files: &rawFiles,
            cancellation: cancellation
        )
        guard !rawFiles.isEmpty else {
            throw TorrentManifestError.missingFiles
        }

        let realFileCount = rawFiles.count
        // Rootless v2 metadata has no libtorrent top-level name. Even a
        // one-leaf tree is therefore a directory layout with a synthetic,
        // digest-derived destination name.
        let isSingleFile = name != nil
            && realFileCount == 1
            && rawFiles[0].pathComponents.count == 1
        if isSingleFile, let name,
           normalizedComponent(name) != normalizedComponent(rawFiles[0].pathComponents[0]) {
            throw TorrentManifestError.inconsistentHybridLayout
        }

        var files = [UnindexedFile]()
        let doubledFileCount = rawFiles.count.multipliedReportingOverflow(by: 2)
        guard !doubledFileCount.overflow else {
            throw TorrentManifestError.tooManyFiles
        }
        files.reserveCapacity(min(
            limits.maximumFileCount,
            doubledFileCount.partialValue
        ))
        for file in rawFiles {
            try cancellation.recordWork()
            guard files.count < limits.maximumFileCount else {
                throw TorrentManifestError.tooManyFiles
            }
            files.append(file)
            let remainder = file.expectedSize % pieceLength
            if remainder != 0 {
                guard files.count < limits.maximumFileCount else {
                    throw TorrentManifestError.tooManyFiles
                }
                let padSize = pieceLength - remainder
                files.append(UnindexedFile(
                    pathComponents: [".pad", "\(padSize)-\(files.count)"],
                    expectedSize: padSize,
                    isPadding: true
                ))
            }
        }

        return ParsedLayout(
            contentKind: isSingleFile ? .singleFile : .directory,
            files: files
        )
    }

    private struct V2TreeFrame {
        var nextEntry: Int?
        let path: [String]
    }

    private func walkV2Tree(
        _ tree: Int,
        document: BencodeRangeDocument,
        files: inout [UnindexedFile],
        cancellation: CancellationPoller
    ) throws {
        var frames = [V2TreeFrame(
            nextEntry: document.firstChild(of: tree),
            path: []
        )]
        frames.reserveCapacity(max(1, limits.maximumPathDepth))

        while !frames.isEmpty {
            try cancellation.recordWork()
            let frameIndex = frames.index(before: frames.endIndex)
            guard let entry = frames[frameIndex].nextEntry else {
                frames.removeLast()
                continue
            }
            frames[frameIndex].nextEntry = document.nextSibling(of: entry)
            guard frames[frameIndex].path.count < limits.maximumPathDepth,
                  let keyRange = document.dictionaryKeyRange(forChild: entry) else {
                throw TorrentManifestError.invalidFilePath
            }
            let component = try string(keyRange, document: document)
            guard !component.isEmpty else {
                throw TorrentManifestError.malformedBencoding
            }
            try validateComponent(component)
            guard document.kind(at: entry) == .dictionary else {
                throw TorrentManifestError.malformedBencoding
            }
            let nextPath = frames[frameIndex].path + [component]
            if document.childCount(of: entry) == 1,
               let marker = document.firstChild(of: entry),
               document.dictionaryKeyRange(forChild: marker)?.isEmpty == true {
                guard document.kind(at: marker) == .dictionary else {
                    throw TorrentManifestError.malformedBencoding
                }
                let properties = marker
                let attributes = try optionalStringRange(
                    named: "attr",
                    in: properties,
                    document: document
                )
                if attributes.map({ document.data[$0].contains(UInt8(ascii: "l")) }) == true
                    || value(
                        named: "symlink path",
                        in: properties,
                        document: document
                    ) != nil {
                    throw TorrentManifestError.symlinkNotSupported
                }
                guard attributes.map({ document.data[$0].contains(UInt8(ascii: "p")) }) != true else {
                    throw TorrentManifestError.invalidFilePath
                }
                let size = try validatedFileSize(requiredInteger(
                    named: "length",
                    in: properties,
                    document: document
                ))
                let declaredPiecesRoot = try optionalStringRange(
                    named: "pieces root",
                    in: properties,
                    document: document
                )
                let piecesRootRange: Range<Int>?
                if size > 0 {
                    guard let root = declaredPiecesRoot,
                          root.count == SHA256.byteCount,
                          document.data[root].contains(where: { $0 != 0 }) else {
                        throw TorrentManifestError.invalidV2PiecesRoot
                    }
                    piecesRootRange = root
                } else {
                    // BEP 52 omits roots for empty files. Validate the shape
                    // when present for compatibility, but do not grant an
                    // unused root semantic meaning in the typed core.
                    if let root = declaredPiecesRoot,
                       root.count != SHA256.byteCount {
                        throw TorrentManifestError.invalidV2PiecesRoot
                    }
                    piecesRootRange = nil
                }
                files.append(UnindexedFile(
                    pathComponents: nextPath,
                    expectedSize: size,
                    isPadding: false,
                    isExecutable: attributes.map {
                        document.data[$0].contains(UInt8(ascii: "x"))
                    } == true,
                    isHidden: attributes.map {
                        document.data[$0].contains(UInt8(ascii: "h"))
                    } == true,
                    piecesRootRange: piecesRootRange
                ))
                guard files.count <= limits.maximumFileCount else {
                    throw TorrentManifestError.tooManyFiles
                }
            } else {
                guard document.childCount(of: entry) > 0 else {
                    throw TorrentManifestError.malformedBencoding
                }
                var child = document.firstChild(of: entry)
                while let current = child {
                    guard document.dictionaryKeyRange(forChild: current)?.isEmpty == false else {
                        throw TorrentManifestError.malformedBencoding
                    }
                    child = document.nextSibling(of: current)
                }
                frames.append(V2TreeFrame(
                    nextEntry: document.firstChild(of: entry),
                    path: nextPath
                ))
            }
        }
    }

    private func validateHybrid(
        v1: ParsedLayout,
        v2: ParsedLayout,
        cancellation: CancellationPoller
    ) throws -> ParsedLayout {
        var v2Files = v2.files
        if v2Files.count == v1.files.count + 1,
           v2Files.last?.isPadding == true {
            v2Files.removeLast()
        }
        guard v1.contentKind == v2.contentKind,
              v1.files.count == v2Files.count else {
            throw TorrentManifestError.inconsistentHybridLayout
        }
        for (left, right) in zip(v1.files, v2Files) {
            try cancellation.recordWork()
            guard left.expectedSize == right.expectedSize,
                  left.isPadding == right.isPadding,
                  left.isExecutable == right.isExecutable,
                  left.isHidden == right.isHidden else {
                throw TorrentManifestError.inconsistentHybridLayout
            }
            if !left.isPadding {
                guard left.pathComponents.count == right.pathComponents.count else {
                    throw TorrentManifestError.inconsistentHybridLayout
                }
                for (leftComponent, rightComponent) in zip(
                    left.pathComponents,
                    right.pathComponents
                ) {
                    try cancellation.recordWork()
                    guard normalizedComponent(leftComponent)
                            == normalizedComponent(rightComponent) else {
                        throw TorrentManifestError.inconsistentHybridLayout
                    }
                }
            }
        }
        return ParsedLayout(contentKind: v2.contentKind, files: v2Files)
    }

    private func validateV1PieceHashes(
        _ info: Int,
        pieceCount: Int,
        document: BencodeRangeDocument
    ) throws -> Range<Int> {
        guard let pieces = try optionalStringRange(
            named: "pieces",
            in: info,
            document: document
        ) else {
            throw TorrentManifestError.invalidPieceHashes
        }
        let expectedBytes = pieceCount.multipliedReportingOverflow(
            by: Insecure.SHA1.byteCount
        )
        guard !expectedBytes.overflow,
              expectedBytes.partialValue <= limits.maximumV1PieceHashBytes else {
            throw TorrentManifestError.workLimitExceeded
        }
        guard pieces.count == expectedBytes.partialValue else {
            throw TorrentManifestError.invalidPieceHashes
        }
        return pieces
    }

    private struct PathTrieNode {
        var children = [String: Int]()
        var isFile = false
    }

    private func validatePathSet(
        _ files: [UnindexedFile],
        cancellation: CancellationPoller
    ) throws {
        var componentCount = 0
        var pathBytes = 0
        var normalizedPathBytes = 0
        var trie = [PathTrieNode()]

        for file in files {
            try cancellation.recordWork()
            guard !file.pathComponents.isEmpty,
                  file.pathComponents.count <= limits.maximumPathDepth else {
                throw TorrentManifestError.invalidFilePath
            }
            for component in file.pathComponents {
                try cancellation.recordWork()
                try validateComponent(component)
                componentCount = try addingWork(componentCount, 1)
                pathBytes = try addingWork(pathBytes, component.utf8.count)
                guard componentCount <= limits.maximumPathComponentCount,
                      pathBytes <= limits.maximumPathBytes else {
                    throw TorrentManifestError.workLimitExceeded
                }
            }

            guard !file.isPadding else {
                continue
            }
            var nodeIndex = 0
            for component in file.pathComponents {
                let normalized = normalizedComponent(component)
                normalizedPathBytes = try addingWork(
                    normalizedPathBytes,
                    normalized.utf8.count
                )
                guard normalizedPathBytes <= limits.maximumPathBytes else {
                    throw TorrentManifestError.workLimitExceeded
                }
                guard !trie[nodeIndex].isFile else {
                    throw TorrentManifestError.conflictingPath
                }
                if let existing = trie[nodeIndex].children[normalized] {
                    nodeIndex = existing
                } else {
                    let childIndex = trie.count
                    trie.append(PathTrieNode())
                    trie[nodeIndex].children[normalized] = childIndex
                    nodeIndex = childIndex
                }
            }
            guard !trie[nodeIndex].isFile else {
                throw TorrentManifestError.duplicatePath
            }
            guard trie[nodeIndex].children.isEmpty else {
                throw TorrentManifestError.conflictingPath
            }
            trie[nodeIndex].isFile = true
        }
    }

    private func parsePathList(
        _ node: Int,
        document: BencodeRangeDocument
    ) throws -> [String] {
        guard document.kind(at: node) == .list,
              document.childCount(of: node) > 0,
              document.childCount(of: node) <= limits.maximumPathDepth else {
            throw TorrentManifestError.invalidFilePath
        }
        var result = [String]()
        result.reserveCapacity(document.childCount(of: node))
        var child = document.firstChild(of: node)
        while let current = child {
            guard let range = document.stringRange(at: current) else {
                throw TorrentManifestError.invalidFilePath
            }
            let component = try string(range, document: document)
            try validateComponent(component)
            result.append(component)
            child = document.nextSibling(of: current)
        }
        return result
    }

    private func parseOptionalName(
        _ info: Int,
        document: BencodeRangeDocument
    ) throws -> String? {
        guard let node = value(named: "name.utf-8", in: info, document: document)
            ?? value(named: "name", in: info, document: document) else {
            return nil
        }
        guard let range = document.stringRange(at: node) else {
            throw TorrentManifestError.invalidName
        }
        guard range.count <= limits.maximumPathComponentBytes,
              let name = String(bytes: document.data[range], encoding: .utf8) else {
            throw TorrentManifestError.invalidName
        }
        try validateComponent(name, isTopLevel: true)
        return name
    }

    private func validateComponent(
        _ component: String,
        isTopLevel: Bool = false
    ) throws {
        let byteCount = component.utf8.count
        guard !component.isEmpty,
              byteCount <= limits.maximumPathComponentBytes,
              component != ".",
              component != "..",
              !component.utf8.contains(0),
              !component.contains("/"),
              !component.contains("\\") else {
            throw isTopLevel
                ? TorrentManifestError.invalidName
                : TorrentManifestError.invalidFilePath
        }
    }

    private func verify(
        _ advertised: TorrentAdvertisedInfoHashes?,
        v1Hash: Data?,
        v2Hash: Data?
    ) throws {
        guard let advertised else {
            return
        }
        if let expected = advertised.v1, v1Hash != expected {
            throw TorrentManifestError.advertisedInfoHashMismatch
        }
        if let expected = advertised.v2, v2Hash != expected {
            throw TorrentManifestError.advertisedInfoHashMismatch
        }
    }

    private func normalizedComponent(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let alphabet = Array("0123456789abcdef".utf8)
        var result = [UInt8]()
        for byte in bytes {
            result.append(alphabet[Int(byte >> 4)])
            result.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: result, as: UTF8.self)
    }

    private func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw TorrentManifestError.invalidFileLength
        }
        return result.partialValue
    }

    private func validatedFileSize(_ size: Int64) throws -> Int64 {
        guard size >= 0, size <= limits.maximumFileBytes else {
            throw TorrentManifestError.invalidFileLength
        }
        return size
    }

    private func addingWork(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw TorrentManifestError.workLimitExceeded
        }
        return result.partialValue
    }

    private var limitsAreValid: Bool {
        limits.maximumMetadataBytes >= 0
            && limits.maximumMetadataBytes < Int(UInt32.max)
            && limits.maximumNestingDepth >= 0
            && limits.maximumValueCount > 0
            && limits.maximumStringBytes >= 0
            && limits.maximumContainerCount >= 0
            && limits.maximumDictionaryKeyBytes >= 0
            && limits.maximumIntegerDigits > 0
            && limits.maximumStringLengthDigits > 0
            && limits.maximumPathComponentBytes > 0
            && limits.maximumPathDepth > 0
            && limits.maximumFileCount > 0
            && limits.maximumFileCount <= Int(Int32.max)
            && limits.maximumTrackerCount >= 0
            && limits.maximumTrackerTierCount >= 0
            && limits.maximumTrackerTierCount <= Int(UInt8.max) + 1
            && limits.maximumWebSeedCount >= 0
            && limits.maximumSourceURLBytes >= 0
            && limits.maximumAggregateSourceBytes >= 0
            && limits.maximumPathComponentCount > 0
            && limits.maximumPathBytes > 0
            && limits.maximumFileBytes >= 0
            && limits.maximumFileBytes <= Limits.nativeMaximumFileBytes
            && limits.maximumPayloadBytes >= 0
            && limits.maximumPayloadBytes <= Limits.nativeMaximumPayloadBytes
            && limits.maximumPieceCount >= 0
            && limits.maximumPieceCount <= Limits.nativeMaximumPieceCount
            && limits.maximumV1PieceHashBytes >= 0
            && limits.maximumPieceLayerHashCount >= 0
            && limits.maximumPieceLayerBytes >= 0
            && limits.maximumCommentBytes >= 0
            && limits.maximumCreatorBytes >= 0
            && limits.maximumHumanReadableBytes >= 0
    }

    private func value(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument
    ) -> Int? {
        document.value(named: name, inDictionaryAt: dictionary)
    }

    private func requiredInteger(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument
    ) throws -> Int64 {
        guard let value = value(named: name, in: dictionary, document: document),
              let integer = document.integer(at: value) else {
            throw TorrentManifestError.malformedBencoding
        }
        return integer
    }

    private func optionalInteger(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument
    ) throws -> Int64? {
        guard let value = value(named: name, in: dictionary, document: document) else {
            return nil
        }
        guard let integer = document.integer(at: value) else {
            throw TorrentManifestError.malformedBencoding
        }
        return integer
    }

    private func optionalStringRange(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument
    ) throws -> Range<Int>? {
        guard let value = value(named: name, in: dictionary, document: document) else {
            return nil
        }
        guard let range = document.stringRange(at: value) else {
            throw TorrentManifestError.malformedBencoding
        }
        return range
    }

    private func string(
        _ range: Range<Int>,
        document: BencodeRangeDocument
    ) throws -> String {
        guard range.count <= limits.maximumPathComponentBytes,
              let string = String(bytes: document.data[range], encoding: .utf8) else {
            throw TorrentManifestError.invalidFilePath
        }
        return string
    }

    private func manifestError(for error: BencodeScanError) -> TorrentManifestError {
        switch error {
        case .nestingLimitExceeded:
            .nestingLimitExceeded
        case .valueLimitExceeded:
            .valueLimitExceeded
        case .containerLimitExceeded, .dictionaryKeyByteLimitExceeded,
             .integerDigitLimitExceeded, .stringLengthDigitLimitExceeded:
            .workLimitExceeded
        case .stringLimitExceeded:
            .stringLimitExceeded
        case .malformed:
            .malformedBencoding
        }
    }
}
