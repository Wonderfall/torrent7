import Foundation
import TorrentBridge
import UniformTypeIdentifiers

let bittorrentFileType = UTType(importedAs: "org.bittorrent.torrent", conformingTo: .data)

enum FileImportMode {
    case torrentFiles
    case downloadFolder

    var allowedContentTypes: [UTType] {
        switch self {
        case .torrentFiles:
            return [bittorrentFileType]
        case .downloadFolder:
            return [.folder]
        }
    }

    var allowsMultipleSelection: Bool {
        self == .torrentFiles
    }
}

struct TorrentAddDraft: Identifiable, Equatable {
    enum Source: Equatable {
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

enum TorrentAddSourceParser {
    static func magnetDraft(from value: String) -> TorrentAddDraft? {
        let magnet = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard magnet.utf8.count <= TorrentInputLimits.maxMagnetURIBytes else {
            return nil
        }
        guard magnet.range(of: "magnet:?", options: [.caseInsensitive, .anchored]) != nil else {
            return nil
        }

        let canonicalMagnet = "magnet:" + String(magnet.dropFirst("magnet:".count))
        return TorrentAddDraft(source: .magnet(canonicalMagnet))
    }

    static func torrentFileDrafts(from urls: [URL]) -> [TorrentAddDraft] {
        urls
            .filter { $0.pathExtension.caseInsensitiveCompare("torrent") == .orderedSame }
            .map { TorrentAddDraft(source: .torrentFile($0)) }
    }
}

struct TorrentAddOptions {
    let downloadFolder: URL
    let torrentData: Data?
    let filePriorities: [Int32: TorrentFilePriority]?
    let movesTorrentFileToTrash: Bool
    let setsDownloadFolderAsDefault: Bool
    let startsPaused: Bool
    let queuePriority: TorrentQueuePriority
    let labelIDs: Set<TorrentLabel.ID>
    let allowsPreMetadataDHT: Bool
}

struct TorrentSourceSecuritySummary: Equatable, Sendable {
    let trackerCount: Int
    let httpsTrackerCount: Int
    let webSeedCount: Int
    let httpsWebSeedCount: Int

    var sourceCount: Int {
        trackerCount + webSeedCount
    }

    var httpsSourceCount: Int {
        httpsTrackerCount + httpsWebSeedCount
    }

    var nonHTTPSSourceCount: Int {
        max(0, sourceCount - httpsSourceCount)
    }

    var nonHTTPSTrackerCount: Int {
        max(0, trackerCount - httpsTrackerCount)
    }

    var nonHTTPSWebSeedCount: Int {
        max(0, webSeedCount - httpsWebSeedCount)
    }

    var hasHTTPSSources: Bool {
        httpsSourceCount > 0
    }

    var hasNonHTTPSSources: Bool {
        nonHTTPSSourceCount > 0
    }

    var hasNonHTTPSTrackers: Bool {
        nonHTTPSTrackerCount > 0
    }

    var hasNonHTTPSWebSeeds: Bool {
        nonHTTPSWebSeedCount > 0
    }

    var needsTrackerExceptionPrompt: Bool {
        trackerCount > 0 && httpsTrackerCount == 0
    }

    var needsWebSeedExceptionPrompt: Bool {
        webSeedCount > 0 && httpsWebSeedCount == 0
    }

    static let empty = TorrentSourceSecuritySummary(
        trackerCount: 0,
        httpsTrackerCount: 0,
        webSeedCount: 0,
        httpsWebSeedCount: 0
    )
}

enum TorrentSourceSecurityInspector {
    static func summary(magnetURI: String) -> TorrentSourceSecuritySummary {
        var inspection = TTorrentSourceSecurityInspection()
        let result = unsafe magnetURI.withCString { magnetPointer in
            unsafe TorrentBridgeInspectMagnetSources(magnetPointer, &inspection)
        }
        guard result == 0 else {
            return .empty
        }

        return TorrentSourceSecuritySummary(
            trackerCount: Int(inspection.tracker_count),
            httpsTrackerCount: Int(inspection.https_tracker_count),
            webSeedCount: Int(inspection.web_seed_count),
            httpsWebSeedCount: Int(inspection.https_web_seed_count)
        )
    }
}
