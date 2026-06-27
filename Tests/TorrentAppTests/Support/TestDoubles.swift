import Foundation
@testable import TorrentApp

final class RecordingCompletionHistoryStore: TorrentCompletionHistoryStoring {
    private(set) var completedIDs: Set<TorrentItem.ID>
    private(set) var rememberedIDs = [Set<TorrentItem.ID>]()
    private(set) var forgottenIDs = [Set<TorrentItem.ID>]()
    private(set) var prunedRetainedIDs = [Set<TorrentItem.ID>]()

    init(completedIDs: Set<TorrentItem.ID> = []) {
        self.completedIDs = completedIDs
    }

    func contains(_ id: TorrentItem.ID) -> Bool {
        completedIDs.contains(id)
    }

    func remember(_ ids: Set<TorrentItem.ID>) {
        rememberedIDs.append(ids)
        completedIDs.formUnion(ids)
    }

    func forget(_ ids: Set<TorrentItem.ID>) {
        forgottenIDs.append(ids)
        completedIDs.subtract(ids)
    }

    func prune(retaining activeIDs: Set<TorrentItem.ID>) {
        prunedRetainedIDs.append(activeIDs)
        completedIDs.formIntersection(activeIDs)
    }
}

actor RecordingNotificationService: TorrentNotificationServicing {
    struct Notification: Equatable, Sendable {
        let torrentName: String?
        let playsSound: Bool
    }

    private(set) var notifications = [Notification]()
    private(set) var clearBadgeCount = 0

    nonisolated func configure() {}

    func notifyDownloadFinished(torrentName: String?, playsSound: Bool) async {
        notifications.append(Notification(torrentName: torrentName, playsSound: playsSound))
    }

    func clearBadge() async {
        clearBadgeCount += 1
    }
}

@MainActor
final class RecordingDockTileService: TorrentDockTileServicing {
    private(set) var transferRateUpdates = [(downloadRate: Int64, uploadRate: Int64)]()
    private(set) var completionBadgeUpdates = [Int]()

    func updateTransferRates(downloadRate: Int64, uploadRate: Int64) {
        transferRateUpdates.append((downloadRate, uploadRate))
    }

    func updateCompletionBadge(count: Int) {
        completionBadgeUpdates.append(count)
    }
}

@MainActor
struct FixedApplicationActivationProvider: ApplicationActivationProviding {
    let isApplicationActive: Bool
}

final class RecordingSleepPreventionService: SleepPreventionServicing {
    private(set) var updates = [(isEnabled: Bool, hasActiveTransfers: Bool)]()

    func update(isEnabled: Bool, hasActiveTransfers: Bool) {
        updates.append((isEnabled, hasActiveTransfers))
    }
}

final class FakeNetworkInterfaceMonitor: NetworkInterfaceMonitoring, @unchecked Sendable {
    private(set) var cancelCount = 0

    func updates() -> AsyncStream<[NetworkInterfaceOption]> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func cancel() {
        cancelCount += 1
    }
}

final class RecordingDownloadFolderAccessStore: DownloadFolderAccessStoring {
    var defaultURL: URL?
    var restoreDefaultResult: Result<URL?, Error> = .success(nil)
    var validateSelectionResult: Result<Void, Error> = .success(())
    var setDefaultResult: Result<URL, Error>?
    var prepareForAddResult: Result<PreparedDownloadFolder, Error>?
    private(set) var clearedDefaultCount = 0
    private(set) var clearDefaultCalls = [[TorrentItem]]()
    private(set) var setDefaultCalls = [(url: URL, activeTorrents: [TorrentItem])]()
    private(set) var prepareForAddCalls = [(url: URL, setsDefault: Bool, activeTorrents: [TorrentItem])]()
    private(set) var pruneCalls = [[TorrentItem]]()

    func restoreDefault() throws -> URL? {
        try restoreDefaultResult.get()
    }

    func clearDefaultBookmarkAndAccess() {
        clearedDefaultCount += 1
        defaultURL = nil
    }

    func validateSelection(_ url: URL) throws {
        try validateSelectionResult.get()
    }

    func isCurrentDefault(_ url: URL?) -> Bool {
        guard let url, let defaultURL else {
            return false
        }
        return url.path == defaultURL.path
    }

    @discardableResult
    func setDefault(_ url: URL, activeTorrents: [TorrentItem]) throws -> URL {
        setDefaultCalls.append((url, activeTorrents))
        let result = try (setDefaultResult ?? .success(url)).get()
        defaultURL = result
        return result
    }

    func clearDefault(activeTorrents: [TorrentItem]) {
        clearDefaultCalls.append(activeTorrents)
        defaultURL = nil
    }

    func prepareForAdd(_ url: URL, setsDefault: Bool, activeTorrents: [TorrentItem]) throws -> PreparedDownloadFolder {
        prepareForAddCalls.append((url, setsDefault, activeTorrents))
        let result = try (prepareForAddResult ?? .success(PreparedDownloadFolder(path: url.path, defaultURL: setsDefault ? url : nil))).get()
        if let defaultURL = result.defaultURL {
            self.defaultURL = defaultURL
        }
        return result
    }

    func prune(activeTorrents: [TorrentItem]) {
        pruneCalls.append(activeTorrents)
    }
}

final class RecordingTorrentFileLocationService: TorrentFileLocationServicing {
    var revealURLs = [TorrentItem.ID: URL]()
    var downloadedDataURLs = [TorrentItem.ID: URL]()
    var trashError: Error?
    private(set) var trashedURLs = [URL]()

    func revealURL(for torrent: TorrentItem) -> URL? {
        revealURLs[torrent.id]
    }

    func revealURL(for torrent: TorrentItem, filePath: String) -> URL? {
        revealURLs[torrent.id]
    }

    func downloadedDataURL(for torrent: TorrentItem) -> URL? {
        downloadedDataURLs[torrent.id]
    }

    func moveDownloadedDataToTrash(at url: URL) throws {
        if let trashError {
            throw trashError
        }
        trashedURLs.append(url)
    }
}

actor FakeTorrentEngine: TorrentEngineServicing {
    nonisolated let startupFailureMessage: String? = nil
    nonisolated let libtorrentVersion = "fake-libtorrent"
    nonisolated let isAvailable = true

    var snapshotBatch: TorrentSnapshotBatch?
    var trackerHostBatchValue = TorrentTrackerHostBatch(revision: 0, hosts: [])
    private var trackerHostBatchSuspensionCount = 0
    private var trackerHostBatchContinuations = [CheckedContinuation<Void, Never>]()
    var dirtyMask: UInt32 = 0
    var networkStatusValue = TorrentNetworkStatus.empty
    var alertErrors = [String]()
    var nextAddedMagnetID = "alpha"
    var nextAddedTorrentFileID = "alpha"
    private(set) var restartCount = 0
    private(set) var restartPeerExchangePluginValues = [Bool]()
    private(set) var blockNetworkCount = 0
    private(set) var saveAllCount = 0
    private(set) var saveAllCheckedCount = 0
    private(set) var appliedSettings = [(settings: TorrentSettings, networkBlocked: Bool)]()
    private(set) var previewedTorrentFiles = [Data]()
    private(set) var addedMagnets = [(
        magnet: String,
        savePath: String,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        enablePeerExchange: Bool,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool
    )]()
    private(set) var addedTorrentFiles = [(
        data: Data,
        savePath: String,
        filePriorities: [Int32: TorrentFilePriority]?,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        enablePeerExchange: Bool,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool
    )]()
    private(set) var pausedIDs = [String]()
    private(set) var resumedIDs = [String]()
    private(set) var removed = [(id: String, deleteFiles: Bool, deletePartfile: Bool)]()
    var removeError: Error?
    private(set) var snapshotRequests = [(revision: UInt64?, sortOrder: TorrentSortOrder, direction: TorrentSortDirection)]()
    private(set) var sourcePolicyUpdates = [(id: String, policy: TorrentSourcePolicy)]()
    private(set) var torrentOptionsUpdates = [(id: String, options: TorrentOptions)]()
    private(set) var filePriorityUpdates = [(id: String, fileIndex: Int32, priority: TorrentFilePriority)]()
    private(set) var queueMoves = [(id: String, move: TorrentQueueMove)]()
    private(set) var requestedPieceMapIDs = [String]()
    var sourcePolicyValue = TorrentSourcePolicy(
        isDHTEnabled: true,
        isPeerExchangeEnabled: true,
        isLocalServiceDiscoveryEnabled: true,
        usesHTTPSTrackersOnly: false,
        usesHTTPSWebSeedsOnly: false,
        isDHTLocked: false,
        isPeerExchangeLocked: false,
        isLocalServiceDiscoveryLocked: false
    )
    var torrentOptionsValue = TorrentOptions.unlimited

    func setSnapshotBatch(_ batch: TorrentSnapshotBatch?) {
        snapshotBatch = batch
    }

    func setTrackerHostBatch(_ batch: TorrentTrackerHostBatch) {
        trackerHostBatchValue = batch
    }

    func suspendNextTrackerHostBatchCall() {
        trackerHostBatchSuspensionCount += 1
    }

    func waitForSuspendedTrackerHostBatchCall() async {
        while trackerHostBatchContinuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeSuspendedTrackerHostBatchCalls() {
        let continuations = trackerHostBatchContinuations
        trackerHostBatchContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func setDirtyMask(_ mask: UInt32) {
        dirtyMask = mask
    }

    func setNetworkStatus(_ status: TorrentNetworkStatus) {
        networkStatusValue = status
    }

    func setRemoveError(_ error: Error?) {
        removeError = error
    }

    func setNextAddedMagnetID(_ id: String) {
        nextAddedMagnetID = id
    }

    func setNextAddedTorrentFileID(_ id: String) {
        nextAddedTorrentFileID = id
    }

    func restart(enablePeerExchangePlugin: Bool) async throws {
        restartCount += 1
        restartPeerExchangePluginValues.append(enablePeerExchangePlugin)
    }

    func wakeEvents() async -> AsyncStream<Void> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func addMagnet(
        _ magnet: String,
        savePath: String,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        enablePeerExchange: Bool,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool
    ) async throws -> String {
        addedMagnets.append((magnet, savePath, startsPaused, queuePriority, enablePeerExchange, allowNonHTTPSTrackers, allowNonHTTPSWebSeeds))
        return nextAddedMagnetID
    }

    func addTorrentFile(
        data: Data,
        savePath: String,
        filePriorities: [Int32: TorrentFilePriority]?,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        enablePeerExchange: Bool,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool
    ) async throws -> String {
        addedTorrentFiles.append((data, savePath, filePriorities, startsPaused, queuePriority, enablePeerExchange, allowNonHTTPSTrackers, allowNonHTTPSWebSeeds))
        return nextAddedTorrentFileID
    }

    func previewTorrentFile(data: Data) async throws -> TorrentFilePreview {
        previewedTorrentFiles.append(data)
        return TorrentFilePreview(name: "Preview", id: "preview", totalSize: 0, sourceSecuritySummary: .empty, files: [], torrentData: data)
    }

    func pause(id: String) async throws {
        pausedIDs.append(id)
    }

    func resume(id: String) async throws {
        resumedIDs.append(id)
    }

    func reannounce(id: String) async throws {}

    func forceRecheck(id: String) async throws {}

    func remove(id: String, deleteFiles: Bool, deletePartfile: Bool) async throws {
        if let removeError {
            throw removeError
        }
        removed.append((id, deleteFiles, deletePartfile))
    }

    func applySettings(_ settings: TorrentSettings, networkBlocked: Bool) async throws {
        appliedSettings.append((settings, networkBlocked))
    }

    func blockNetworkNow() async throws {
        blockNetworkCount += 1
    }

    func saveAll() async {
        saveAllCount += 1
    }

    func saveAllChecked() async throws {
        saveAllCheckedCount += 1
    }

    func takeAlertError() async -> String? {
        alertErrors.isEmpty ? nil : alertErrors.removeFirst()
    }

    func takeChanges() async -> UInt32 {
        let mask = dirtyMask
        dirtyMask = 0
        return mask
    }

    func networkStatus() async -> TorrentNetworkStatus {
        networkStatusValue
    }

    func snapshotsIfChanged(
        since revision: UInt64?,
        sortedBy sortOrder: TorrentSortOrder,
        direction: TorrentSortDirection
    ) async -> TorrentSnapshotBatch? {
        snapshotRequests.append((revision, sortOrder, direction))
        return snapshotBatch.map { batch in
            TorrentSnapshotBatch(revision: batch.revision, torrents: sortOrder.sorted(batch.torrents, direction: direction))
        }
    }

    func requestSources(id: String) async throws {}

    func sourcePolicy(id: String) async throws -> TorrentSourcePolicy {
        sourcePolicyValue
    }

    func setSourcePolicy(id: String, policy: TorrentSourcePolicy) async throws {
        sourcePolicyUpdates.append((id, policy))
        sourcePolicyValue = policy
    }

    func torrentOptions(id: String) async throws -> TorrentOptions {
        torrentOptionsValue
    }

    func setTorrentOptions(id: String, options: TorrentOptions) async throws {
        torrentOptionsUpdates.append((id, options))
        torrentOptionsValue = options
    }

    func moveTorrentInQueue(id: String, move: TorrentQueueMove) async throws {
        queueMoves.append((id, move))
    }

    func requestFiles(id: String) async throws {}

    func setFilePriority(id: String, fileIndex: Int32, priority: TorrentFilePriority) async throws {
        filePriorityUpdates.append((id, fileIndex, priority))
    }

    func requestPieceMap(id: String) async throws {
        requestedPieceMapIDs.append(id)
    }

    func trackerBatch(id: String) async -> TorrentTrackerBatch {
        TorrentTrackerBatch(revision: 0, trackers: [])
    }

    func trackerHostBatch() async -> TorrentTrackerHostBatch {
        let batch = trackerHostBatchValue
        if trackerHostBatchSuspensionCount > 0 {
            trackerHostBatchSuspensionCount -= 1
            await withCheckedContinuation { continuation in
                trackerHostBatchContinuations.append(continuation)
            }
        }
        return batch
    }

    func webSeedBatch(id: String) async -> TorrentWebSeedBatch {
        TorrentWebSeedBatch(revision: 0, webSeeds: [])
    }

    func webSeedActivity(id: String) async -> TorrentWebSeedActivity {
        .empty
    }

    func peerSources(id: String) async -> TorrentPeerSources {
        .empty
    }

    func fileBatch(id: String) async -> TorrentFileBatch {
        TorrentFileBatch(revision: 0, files: [])
    }

    func pieceMapBatch(id: String) async -> TorrentPieceMapBatch {
        TorrentPieceMapBatch(revision: 0, pieceMap: .empty)
    }
}

struct FakeBookmarkError: Error {}

final class FakeDownloadFolderAccess: DownloadFolderAccessing {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func bookmarkData() throws -> Data {
        Data(url.path.utf8)
    }
}

struct FakeDownloadFolderAccessProvider: DownloadFolderAccessProviding {
    var rejectedBookmarkData = Set<Data>()

    func createAccess(url: URL, savesBookmark: Bool, defaults: UserDefaults) throws -> DownloadFolderAccessing {
        let access = FakeDownloadFolderAccess(url: url)
        if savesBookmark {
            defaults.set(try access.bookmarkData(), forKey: SecurityScopedFolder.defaultsKey)
        }
        return access
    }

    func restoreDefault(defaults: UserDefaults) throws -> DownloadFolderAccessing? {
        guard let bookmark = defaults.data(forKey: SecurityScopedFolder.defaultsKey) else {
            return nil
        }
        return try restore(from: bookmark)
    }

    func restore(from bookmark: Data) throws -> DownloadFolderAccessing {
        if rejectedBookmarkData.contains(bookmark) {
            throw FakeBookmarkError()
        }
        guard let path = String(data: bookmark, encoding: .utf8), !path.isEmpty else {
            throw FakeBookmarkError()
        }
        return FakeDownloadFolderAccess(url: URL(fileURLWithPath: path, isDirectory: true))
    }

    func clearDefaultBookmark(defaults: UserDefaults) {
        defaults.removeObject(forKey: SecurityScopedFolder.defaultsKey)
    }
}
