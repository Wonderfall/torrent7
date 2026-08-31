import Foundation
import TorrentAppInfrastructure
import TorrentEngineModel
import TorrentMetainfo
import UniformTypeIdentifiers

nonisolated let bittorrentFileType = UTType(
    importedAs: "org.bittorrent.torrent",
    conformingTo: .data
)

nonisolated enum FileImportMode {
    case torrentFiles
    case downloadFolder
    case magnetDestination(promotionID: UUID)

    var allowedContentTypes: [UTType] {
        switch self {
        case .torrentFiles:
            return [bittorrentFileType]
        case .downloadFolder, .magnetDestination:
            return [.folder]
        }
    }

    var allowsMultipleSelection: Bool {
        switch self {
        case .torrentFiles:
            true
        case .downloadFolder, .magnetDestination:
            false
        }
    }
}

nonisolated struct TorrentAddDraft: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case torrentFile(URL)
        case magnet(String)
    }

    let id = UUID()
    let source: Source

    var fileURL: URL? {
        guard case .torrentFile(let url) = source else {
            return nil
        }
        return url
    }

    var magnetURI: String? {
        guard case .magnet(let uri) = source else {
            return nil
        }
        return uri
    }

    var title: String {
        switch source {
        case .torrentFile(let url):
            return url.deletingPathExtension().lastPathComponent
        case .magnet:
            return "Magnet Link"
        }
    }
}

nonisolated struct TorrentFileDraftBatch: Sendable {
    let drafts: [TorrentAddDraft]
    let exceededLimit: Bool
}

nonisolated struct TorrentMagnetDraftPreparation: Sendable {
    let draft: TorrentAddDraft?
    let isTooLarge: Bool
}

nonisolated struct TorrentMagnetPreparationRequest: Identifiable, Sendable {
    let id = UUID()
    let value: String
}

nonisolated enum TorrentAddSourceParser {
    static func magnetDraft(from value: String) -> TorrentAddDraft? {
        magnetDraftPreparation(from: value).draft
    }

    @concurrent
    static func prepareMagnetDraft(
        from value: String
    ) async throws -> TorrentMagnetDraftPreparation {
        try Task.checkCancellation()
        let preparation = magnetDraftPreparation(from: value)
        try Task.checkCancellation()
        return preparation
    }

    private static func magnetDraftPreparation(
        from value: String
    ) -> TorrentMagnetDraftPreparation {
        let boundedUTF8 = value.utf8.prefix(
            TorrentInputLimits.maxMagnetURIBytes + 1
        )
        guard boundedUTF8.count <= TorrentInputLimits.maxMagnetURIBytes else {
            return TorrentMagnetDraftPreparation(
                draft: nil,
                isTooLarge: true
            )
        }
        let magnet = String(decoding: boundedUTF8, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard magnet.range(of: "magnet:?", options: [.caseInsensitive, .anchored]) != nil else {
            return TorrentMagnetDraftPreparation(
                draft: nil,
                isTooLarge: false
            )
        }

        let canonicalMagnet = "magnet:" + String(magnet.dropFirst("magnet:".count))
        return TorrentMagnetDraftPreparation(
            draft: TorrentAddDraft(source: .magnet(canonicalMagnet)),
            isTooLarge: false
        )
    }

    @concurrent
    static func torrentFileDrafts(
        from urls: [URL],
        maximumCount: Int
    ) async throws -> TorrentFileDraftBatch {
        precondition(maximumCount >= 0)
        try Task.checkCancellation()

        var drafts = [TorrentAddDraft]()
        drafts.reserveCapacity(min(urls.count, maximumCount))
        var exceededLimit = false
        for (offset, url) in urls.enumerated() {
            if offset.isMultiple(of: 16) {
                try Task.checkCancellation()
            }
            guard url.pathExtension
                .caseInsensitiveCompare("torrent") == .orderedSame else {
                continue
            }
            guard drafts.count < maximumCount else {
                exceededLimit = true
                continue
            }
            drafts.append(TorrentAddDraft(source: .torrentFile(url)))
        }
        try Task.checkCancellation()
        return TorrentFileDraftBatch(
            drafts: drafts,
            exceededLimit: exceededLimit
        )
    }
}

nonisolated struct TorrentAddOptions {
    let downloadFolder: URL
    let torrentData: Data?
    let filePriorities: [Int32: TorrentFilePriority]?
    let movesTorrentFileToTrash: Bool
    let setsDownloadFolderAsDefault: Bool
    let startsPaused: Bool
    let queuePriority: TorrentQueuePriority
    let labelIDs: Set<TorrentLabel.ID>
    let allowsPreMetadataDHT: Bool
    let destinationChoice: TorrentStorageDestinationChoice
}

nonisolated enum TorrentSourceSecurityInspector {
    static func summary(magnetURI: String) -> TorrentSourceSecuritySummary {
        (try? ParsedMagnet.parse(magnetURI).sourceSecuritySummary) ?? .empty
    }

    @concurrent
    static func prepareSummary(
        magnetURI: String
    ) async throws -> TorrentSourceSecuritySummary {
        do {
            return try ParsedMagnet.parse(
                magnetURI,
                checkCancellation: {
                    try Task.checkCancellation()
                }
            ).sourceSecuritySummary
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .empty
        }
    }
}
