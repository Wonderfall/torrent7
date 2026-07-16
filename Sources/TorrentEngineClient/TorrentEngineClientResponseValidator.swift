import Foundation
import TorrentEngineIPC
import TorrentEngineModel

/// Validates values received from the engine process before they become app state.
///
/// The engine is isolated because native parsing may be compromised, so a valid
/// code signature and a bounded wire payload are not sufficient trust signals.
/// Every response still has to satisfy the same semantic and resource bounds as
/// an honest bridge-produced value.
enum TorrentEngineClientResponseValidator {
    private static let maximumVersionBytes = 256
    private static let maximumTorrentNameBytes = 511
    private static let maximumTorrentErrorBytes = 511
    private static let maximumTorrentCommentBytes = 1_023
    private static let maximumSourceURLBytes = 1_023
    private static let maximumTrackerMessageBytes = 511
    private static let maximumFilePathBytes = 1_023
    private static let maximumNetworkEndpointBytes = 255
    private static let maximumDiagnosticBytes = 511

    static func validate<Value: Sendable>(_ value: Value) throws {
        switch value {
        case let response as TorrentEngineIPCHandshakeResponse:
            try validate(response)
        case let response as TorrentEngineIPCGrantFolderResponse:
            try validate(response.folder)
        case let response as TorrentEngineIPCReplaceFoldersResponse:
            try validate(folders: response.folders)
        case let response as TorrentEngineIPCPollResponse:
            try validate(response)
        case let preview as TorrentFilePreview:
            try validate(preview)
        case let response as TorrentEngineIPCAddedTorrentResponse:
            guard isCanonicalTorrentID(response.identifier) else {
                throw TorrentEngineClientError.invalidReply
            }
        case let response as TorrentEngineIPCRemovalResponse:
            try validate(response.outcome)
        case let options as TorrentOptions:
            guard options == options.normalized else {
                throw TorrentEngineClientError.invalidReply
            }
        case let batch as TorrentSnapshotBatch:
            try validate(torrents: batch.torrents, authorizedSavePaths: nil)
        case let batch as TorrentTrackerBatch:
            try validate(batch)
        case let batch as TorrentTrackerHostBatch:
            try validate(batch)
        case let batch as TorrentWebSeedBatch:
            try validate(batch)
        case let activity as TorrentWebSeedActivity:
            try validate(activity)
        case let sources as TorrentPeerSources:
            try validate(sources)
        case let batch as TorrentFileBatch:
            try validate(batch)
        case let batch as TorrentPieceMapBatch:
            try validate(batch.pieceMap)
        default:
            break
        }
    }

    static func validateDataset<Value: Sendable>(
        _ values: [Value],
        kind: TorrentEngineIPCDatasetKind,
        authorizedSavePaths: Set<String>
    ) throws {
        switch kind {
        case .torrentSnapshots:
            guard let torrents = values as? [TorrentItem] else {
                throw TorrentEngineClientError.invalidReply
            }
            try validate(torrents: torrents, authorizedSavePaths: authorizedSavePaths)
        case .trackerHosts:
            guard let hosts = values as? [TorrentTrackerHostItem] else {
                throw TorrentEngineClientError.invalidReply
            }
            try validate(hosts: hosts)
        }
    }

    private static func validate(_ response: TorrentEngineIPCHandshakeResponse) throws {
        guard isBoundedText(
            response.libtorrentVersion,
            maximumBytes: maximumVersionBytes,
            allowsEmpty: false
        ),
        response.folders.count <= TorrentEngineLimits.maximumAuthorizedSavePathCount else {
            throw TorrentEngineClientError.invalidReply
        }
        try validate(folders: response.folders)
    }

    private static func validate(folders: [TorrentEngineIPCGrantedFolder]) throws {
        guard folders.count <= TorrentEngineLimits.maximumAuthorizedSavePathCount,
              Set(folders.map(\.capabilityID)).count == folders.count,
              Set(folders.map(\.resolvedPath)).count == folders.count else {
            throw TorrentEngineClientError.invalidReply
        }
        try folders.forEach(validate)
    }

    private static func validate(_ folder: TorrentEngineIPCGrantedFolder) throws {
        guard isCanonicalAbsolutePath(folder.resolvedPath) else {
            throw TorrentEngineClientError.invalidReply
        }
    }

    private static func validate(_ response: TorrentEngineIPCPollResponse) throws {
        guard response.alertErrors.count <= TorrentEngineLimits.maximumAlertErrorsPerPoll else {
            throw TorrentEngineClientError.invalidReply
        }
        for message in response.alertErrors {
            guard isBoundedText(
                message,
                maximumBytes: TorrentEngineIPCLimits.maximumErrorBytes,
                allowsEmpty: false
            ) else {
                throw TorrentEngineClientError.invalidReply
            }
        }
        try validate(response.networkStatus)
        try validate(response.bridgeHealth)
        if let descriptor = response.snapshotDataset {
            try validate(
                descriptor,
                expectedKind: .torrentSnapshots,
                maximumItemCount: TorrentEngineLimits.maximumTorrentSnapshotCount
            )
        }
        if let descriptor = response.trackerHostDataset {
            try validate(
                descriptor,
                expectedKind: .trackerHosts,
                maximumItemCount: TorrentEngineLimits.maximumTrackerHostRowCount
            )
        }
        if let snapshots = response.snapshotDataset,
           let hosts = response.trackerHostDataset,
           snapshots.id == hosts.id {
            throw TorrentEngineClientError.invalidReply
        }
    }

    private static func validate(
        _ descriptor: TorrentEngineIPCDatasetDescriptor,
        expectedKind: TorrentEngineIPCDatasetKind,
        maximumItemCount: Int
    ) throws {
        guard descriptor.kind == expectedKind,
              (0...maximumItemCount).contains(descriptor.itemCount),
              (0...maximumItemCount).contains(descriptor.pageCount),
              (descriptor.itemCount == 0) == (descriptor.pageCount == 0),
              descriptor.pageCount <= descriptor.itemCount else {
            throw TorrentEngineClientError.invalidReply
        }
    }

    private static func validate(_ preview: TorrentFilePreview) throws {
        guard isBoundedLeafName(
            preview.name,
            maximumBytes: maximumTorrentNameBytes
        ),
        isHashKey(preview.id),
        preview.totalSize >= 0,
        !preview.torrentData.isEmpty,
        preview.torrentData.count <= TorrentInputLimits.maxTorrentFileBytes,
        preview.files.count <= TorrentEngineLimits.maximumFileCount else {
            throw TorrentEngineClientError.invalidReply
        }
        try validate(preview.sourceSecuritySummary)
        try validate(files: preview.files)
    }

    private static func validate(_ summary: TorrentSourceSecuritySummary) throws {
        guard (0...TorrentEngineLimits.maximumTrackerCount).contains(summary.trackerCount),
              (0...summary.trackerCount).contains(summary.httpsTrackerCount),
              (0...TorrentEngineLimits.maximumWebSeedCount).contains(summary.webSeedCount),
              (0...summary.webSeedCount).contains(summary.httpsWebSeedCount) else {
            throw TorrentEngineClientError.invalidReply
        }
    }

    private static func validate(_ outcome: TorrentRemovalOutcome) throws {
        guard case .removedWithWarning(let warning) = outcome else {
            return
        }
        guard isBoundedText(
            warning,
            maximumBytes: TorrentEngineLimits.maximumRemovalWarningBytes,
            allowsEmpty: false
        ) else {
            throw TorrentEngineClientError.invalidReply
        }
    }

    private static func validate(
        torrents: [TorrentItem],
        authorizedSavePaths: Set<String>?
    ) throws {
        guard torrents.count <= TorrentEngineLimits.maximumTorrentSnapshotCount else {
            throw TorrentEngineClientError.invalidReply
        }
        let authorizedPathKeys = authorizedSavePaths.map { paths in
            Set(paths.map(canonicalDirectoryPathKey))
        }
        var identifiers = Set<String>(minimumCapacity: torrents.count)
        for torrent in torrents {
            guard isCanonicalTorrentID(torrent.id),
                  identifiers.insert(torrent.id).inserted,
                  isHashKey(torrent.infoHash),
                  isBoundedLeafName(
                      torrent.name,
                      maximumBytes: maximumTorrentNameBytes
                  ),
                  isCanonicalAbsolutePath(torrent.savePath),
                  authorizedPathKeys?.contains(
                      canonicalDirectoryPathKey(torrent.savePath)
                  ) ?? true,
                  isBoundedText(
                      torrent.error,
                      maximumBytes: maximumTorrentErrorBytes,
                      allowsEmpty: true
                  ),
                  isBoundedText(
                      torrent.comment,
                      maximumBytes: maximumTorrentCommentBytes,
                      allowsEmpty: true
                  ),
                  torrent.progress.isFinite,
                  (0...1).contains(torrent.progress),
                  torrent.totalDone >= 0,
                  torrent.totalWanted >= 0,
                  torrent.totalSize >= 0,
                  torrent.totalUpload >= 0,
                  torrent.totalDownload >= 0,
                  torrent.totalPayloadUpload >= 0,
                  torrent.totalPayloadDownload >= 0,
                  torrent.allTimeUpload >= 0,
                  torrent.allTimeDownload >= 0,
                  torrent.addedTime >= 0,
                  torrent.createdTime >= 0,
                  torrent.completedTime >= 0,
                  torrent.downloadRate >= 0,
                  torrent.uploadRate >= 0,
                  torrent.downloadPayloadRate >= 0,
                  torrent.uploadPayloadRate >= 0,
                  torrent.peers >= 0,
                  torrent.knownPeers >= 0,
                  torrent.seeds >= 0,
                  torrent.queuePosition >= -1 else {
                throw TorrentEngineClientError.invalidReply
            }
        }
    }

    private static func validate(_ batch: TorrentTrackerBatch) throws {
        guard batch.trackers.count <= TorrentEngineLimits.maximumTrackerCount else {
            throw TorrentEngineClientError.invalidReply
        }
        for tracker in batch.trackers {
            guard isBoundedText(
                tracker.url,
                maximumBytes: maximumSourceURLBytes,
                allowsEmpty: false
            ),
            isBoundedText(
                tracker.message,
                maximumBytes: maximumTrackerMessageBytes,
                allowsEmpty: true
            ),
            tracker.tier >= 0,
            tracker.tier < Int32.max,
            tracker.failCount >= 0,
            tracker.scrapeSeeders >= -1,
            tracker.scrapeLeechers >= -1,
            tracker.scrapeDownloaded >= -1 else {
                throw TorrentEngineClientError.invalidReply
            }
        }
    }

    private static func validate(_ batch: TorrentTrackerHostBatch) throws {
        guard batch.hosts.count <= TorrentEngineLimits.maximumTrackerHostRowCount else {
            throw TorrentEngineClientError.invalidReply
        }
        try validate(hosts: batch.hosts)
    }

    private static func validate(hosts: [TorrentTrackerHostItem]) throws {
        for host in hosts {
            guard isCanonicalTorrentID(host.torrentID),
                  isBoundedText(
                      host.host,
                      maximumBytes: TorrentEngineLimits.trackerHostCapacity - 1,
                      allowsEmpty: false
                  ) else {
                throw TorrentEngineClientError.invalidReply
            }
        }
    }

    private static func validate(_ batch: TorrentWebSeedBatch) throws {
        guard batch.webSeeds.count <= TorrentEngineLimits.maximumWebSeedCount else {
            throw TorrentEngineClientError.invalidReply
        }
        for webSeed in batch.webSeeds {
            guard isBoundedText(
                webSeed.url,
                maximumBytes: maximumSourceURLBytes,
                allowsEmpty: false
            ) else {
                throw TorrentEngineClientError.invalidReply
            }
        }
    }

    private static func validate(_ activity: TorrentWebSeedActivity) throws {
        guard activity.activeCount >= 0,
              activity.downloadRate >= 0,
              activity.totalDownload >= 0 else {
            throw TorrentEngineClientError.invalidReply
        }
    }

    private static func validate(_ sources: TorrentPeerSources) throws {
        guard sources.connected >= 0,
              sources.tracker >= 0,
              sources.dht >= 0,
              sources.peerExchange >= 0,
              sources.localServiceDiscovery >= 0,
              sources.resumeData >= 0,
              sources.incoming >= 0,
              sources.webSeed >= 0,
              sources.other >= 0 else {
            throw TorrentEngineClientError.invalidReply
        }
    }

    private static func validate(_ batch: TorrentFileBatch) throws {
        guard batch.files.count <= TorrentEngineLimits.maximumFileCount else {
            throw TorrentEngineClientError.invalidReply
        }
        try validate(files: batch.files)
    }

    private static func validate(files: [TorrentFileItem]) throws {
        var indices = Set<Int32>(minimumCapacity: files.count)
        for file in files {
            guard isConfinedRelativePath(file.path),
                  file.size >= 0,
                  file.downloaded >= 0,
                  file.downloaded <= file.size,
                  file.progress.isFinite,
                  (0...1).contains(file.progress),
                  (0..<TorrentEngineLimits.maximumFileCount).contains(Int(file.index)),
                  indices.insert(file.index).inserted else {
                throw TorrentEngineClientError.invalidReply
            }
        }
    }

    private static func validate(_ pieceMap: TorrentPieceMap) throws {
        let availableCompletedPieces = pieceMap.pieces.reduce(into: 0) { count, piece in
            count += piece == 0 ? 0 : 1
        }
        guard pieceMap.totalPieces >= 0,
              pieceMap.totalPieces <= Int(Int32.max),
              (0...pieceMap.totalPieces).contains(pieceMap.completedPieces),
              (0...min(
                  pieceMap.totalPieces,
                  TorrentEngineLimits.maximumPieceMapCount
              )).contains(pieceMap.availablePieces),
              pieceMap.pieces.count == pieceMap.availablePieces,
              pieceMap.isMapAvailable == (pieceMap.availablePieces > 0),
              pieceMap.isMapTruncated == (pieceMap.availablePieces < pieceMap.totalPieces),
              pieceMap.pieces.allSatisfy({ $0 <= 1 }),
              availableCompletedPieces <= pieceMap.completedPieces,
              pieceMap.isMapTruncated
                || availableCompletedPieces == pieceMap.completedPieces else {
            throw TorrentEngineClientError.invalidReply
        }
    }

    private static func validate(_ status: TorrentNetworkStatus) throws {
        guard status.submittedRevision <= status.requestedRevision,
              (0...65_535).contains(status.listenPort),
              isBoundedText(
                  status.endpoint,
                  maximumBytes: maximumNetworkEndpointBytes,
                  allowsEmpty: true
              ),
              isBoundedText(
                  status.lastError,
                  maximumBytes: maximumDiagnosticBytes,
                  allowsEmpty: true
              ) else {
            throw TorrentEngineClientError.invalidReply
        }
    }

    private static func validate(_ health: TorrentBridgeHealth) throws {
        guard health.consecutiveAlertWorkerFailures <= health.totalAlertWorkerFailures,
              isBoundedText(
                  health.lastAlertWorkerError,
                  maximumBytes: maximumDiagnosticBytes,
                  allowsEmpty: true
              ) else {
            throw TorrentEngineClientError.invalidReply
        }
    }

    private static func isBoundedText(
        _ value: String,
        maximumBytes: Int,
        allowsEmpty: Bool
    ) -> Bool {
        (allowsEmpty || !value.isEmpty)
            && value.utf8.count <= maximumBytes
            && !value.contains("\0")
    }

    private static func isBoundedLeafName(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        isBoundedText(value, maximumBytes: maximumBytes, allowsEmpty: false)
            && value != "."
            && value != ".."
            && !value.contains("/")
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard isBoundedText(
            path,
            maximumBytes: TorrentEngineLimits.maximumAuthorizedSavePathBytes,
            allowsEmpty: false
        ),
        (path as NSString).isAbsolutePath else {
            return false
        }
        let standardized = (path as NSString).standardizingPath
        return standardized == path
            || (standardized != "/" && "\(standardized)/" == path)
    }

    private static func isConfinedRelativePath(_ path: String) -> Bool {
        guard isBoundedText(
            path,
            maximumBytes: maximumFilePathBytes,
            allowsEmpty: false
        ),
        !(path as NSString).isAbsolutePath else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func canonicalDirectoryPathKey(_ path: String) -> Substring {
        guard path.count > 1, path.hasSuffix("/") else {
            return path[...]
        }
        return path.dropLast()
    }

    private static func isCanonicalTorrentID(_ value: String) -> Bool {
        guard value.utf8.count == 34, value.hasPrefix("t:") else {
            return false
        }
        return isLowercaseHex(value.dropFirst(2), count: 32)
    }

    private static func isHashKey(_ value: String) -> Bool {
        if value.hasPrefix("v1:") {
            return isLowercaseHex(value.dropFirst(3), count: 40)
        }
        if value.hasPrefix("v2:") {
            return isLowercaseHex(value.dropFirst(3), count: 64)
        }
        return false
    }

    private static func isLowercaseHex<S: StringProtocol>(_ value: S, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!)
                || ($0 >= Character("a").asciiValue! && $0 <= Character("f").asciiValue!)
        }
    }
}
