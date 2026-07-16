import Foundation
import Synchronization
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
    var leaseResult: Result<DownloadFolderAccessLease, Error>?
    private(set) var clearedDefaultCount = 0
    private(set) var clearDefaultCalls = [[TorrentItem]]()
    private(set) var setDefaultCalls = [(url: URL, activeTorrents: [TorrentItem])]()
    private(set) var prepareForAddCalls = [(url: URL, setsDefault: Bool, activeTorrents: [TorrentItem])]()
    private(set) var commitPreparedForAddCalls = [(folder: PreparedDownloadFolder, activeTorrents: [TorrentItem])]()
    private(set) var leaseCalls = [String]()
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
        let access = FakeDownloadFolderAccess(url: url)
        let fallback = PreparedDownloadFolder(
            access: access,
            defaultURL: setsDefault ? url : nil,
            bookmarkData: try access.bookmarkData()
        )
        let result = try (prepareForAddResult ?? .success(fallback)).get()
        prepareForAddResult = nil
        return result
    }

    func commitPreparedForAdd(
        _ preparedFolder: PreparedDownloadFolder,
        activeTorrents: [TorrentItem]
    ) -> URL? {
        commitPreparedForAddCalls.append((preparedFolder, activeTorrents))
        if let defaultURL = preparedFolder.defaultURL {
            self.defaultURL = defaultURL
        }
        return preparedFolder.defaultURL
    }

    func lease(forSavePath path: String) throws -> DownloadFolderAccessLease {
        leaseCalls.append(path)
        let result = leaseResult ?? .success(DownloadFolderAccessLease(
            access: FakeDownloadFolderAccess(url: URL(fileURLWithPath: path, isDirectory: true))
        ))
        leaseResult = nil
        return try result.get()
    }

    func prune(activeTorrents: [TorrentItem]) {
        pruneCalls.append(activeTorrents)
    }
}

final class RecordingTorrentFileLocationService: TorrentFileLocationServicing {
    var revealURLs = [TorrentItem.ID: URL]()

    func revealURL(for torrent: TorrentItem) -> URL? {
        revealURLs[torrent.id]
    }

    func revealURL(for torrent: TorrentItem, filePath: String) -> URL? {
        revealURLs[torrent.id]
    }
}

enum FakeTorrentEngineOperation: Equatable, Sendable {
    case applySettings(dhtEnabled: Bool, networkBlocked: Bool)
    case addMagnet(appliedDHTEnabled: Bool?, networkBlocked: Bool)
}

actor FakeTorrentEngine: TorrentEngineServicing {
    nonisolated let startupFailureMessage: String? = nil
    nonisolated let libtorrentVersion = "fake-libtorrent"
    private nonisolated let availability = Mutex(true)
    private let keepsWakeStreamOpen: Bool
    private var wakeContinuation: AsyncStream<Void>.Continuation?

    nonisolated var isAvailable: Bool {
        availability.withLock { $0 }
    }

    var snapshotBatch: TorrentSnapshotBatch?
    var trackerHostBatchValue = TorrentTrackerHostBatch(revision: 0, hosts: [])
    private var trackerHostBatchSuspensionCount = 0
    private var trackerHostBatchContinuations = [CheckedContinuation<Void, Never>]()
    var dirtyMask: UInt32 = 0
    var networkStatusValue = TorrentNetworkStatus.empty
    var alertErrors = [String]()
    var nextAddedMagnetID = "alpha"
    var addMagnetError: Error?
    var nextAddedTorrentFileID = "alpha"
    private(set) var restartCount = 0
    private(set) var restartPeerExchangePluginValues = [Bool]()
    private(set) var blockNetworkCount = 0
    private var blockNetworkSuspensionCount = 0
    private var blockNetworkContinuations = [CheckedContinuation<Void, Never>]()
    private(set) var currentNetworkBlocked = false
    private(set) var saveAllCount = 0
    private(set) var saveAllCheckedCount = 0
    private(set) var appliedSettings = [(settings: TorrentSettings, networkBlocked: Bool)]()
    private(set) var operations = [FakeTorrentEngineOperation]()
    private(set) var previewedTorrentFiles = [Data]()
    private(set) var addedMagnets = [(
        magnet: String,
        savePath: String,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        enablePeerExchange: Bool,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool,
        allowPreMetadataDHT: Bool
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
    private var addMagnetSuspensionCount = 0
    private var addMagnetContinuations = [CheckedContinuation<Void, Never>]()
    private(set) var pausedIDs = [String]()
    private(set) var pauseAppliedDHTValues = [Bool?]()
    private(set) var pauseNetworkBlockedValues = [Bool]()
    private(set) var resumedIDs = [String]()
    private(set) var removed = [(id: String, deleteFiles: Bool)]()
    var removeError: Error?
    var removeOutcome = TorrentRemovalOutcome.removed
    var becomesUnavailableOnRemove = false
    private var removeSuspensionCount = 0
    private var removeContinuations = [CheckedContinuation<Void, Never>]()
    private(set) var snapshotRequests = [(revision: UInt64?, sortOrder: TorrentSortOrder, direction: TorrentSortDirection)]()
    private(set) var sourcePolicyUpdates = [(id: String, field: TorrentSourcePolicyField, enabled: Bool)]()
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
        isLocalServiceDiscoveryLocked: false,
        isMetadataValidationPending: false,
        allowsPreMetadataDHT: false
    )
    var torrentOptionsValue = TorrentOptions.unlimited

    init(keepsWakeStreamOpen: Bool = false) {
        self.keepsWakeStreamOpen = keepsWakeStreamOpen
    }

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

    func setRemoveOutcome(_ outcome: TorrentRemovalOutcome) {
        removeOutcome = outcome
    }

    func setBecomesUnavailableOnRemove(_ value: Bool) {
        becomesUnavailableOnRemove = value
    }

    func suspendNextRemove() {
        removeSuspensionCount += 1
    }

    func waitForSuspendedRemove() async {
        while removeContinuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeSuspendedRemoves() {
        let continuations = removeContinuations
        removeContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitForNetworkBlock() async {
        while blockNetworkCount == 0 {
            await Task.yield()
        }
    }

    func suspendNextNetworkBlock() {
        blockNetworkSuspensionCount += 1
    }

    func waitForSuspendedNetworkBlock() async {
        while blockNetworkContinuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeSuspendedNetworkBlocks() {
        let continuations = blockNetworkContinuations
        blockNetworkContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func suspendNextAddMagnet() {
        addMagnetSuspensionCount += 1
    }

    func waitForSuspendedAddMagnet() async {
        while addMagnetContinuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeSuspendedAddMagnets() {
        let continuations = addMagnetContinuations
        addMagnetContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func setNextAddedMagnetID(_ id: String) {
        nextAddedMagnetID = id
    }

    func setAddMagnetError(_ error: Error?) {
        addMagnetError = error
    }

    func setNextAddedTorrentFileID(_ id: String) {
        nextAddedTorrentFileID = id
    }

    func restart(enablePeerExchangePlugin: Bool) async throws {
        restartCount += 1
        restartPeerExchangePluginValues.append(enablePeerExchangePlugin)
        availability.withLock { $0 = true }
    }

    func wakeEvents() async -> AsyncStream<Void> {
        if keepsWakeStreamOpen {
            let wakeEvents = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            wakeContinuation = wakeEvents.continuation
            return wakeEvents.stream
        }

        return AsyncStream<Void> { continuation in
            continuation.finish()
        }
    }

    func waitForOpenWakeStream() async {
        while wakeContinuation == nil {
            await Task.yield()
        }
    }

    func finishWakeStream() {
        wakeContinuation?.finish()
        wakeContinuation = nil
    }

    func addMagnet(
        _ magnet: String,
        savePath: String,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        enablePeerExchange: Bool,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool,
        allowPreMetadataDHT: Bool
    ) async throws -> String {
        operations.append(.addMagnet(
            appliedDHTEnabled: appliedSettings.last?.settings.enableDHTNetwork,
            networkBlocked: currentNetworkBlocked
        ))
        addedMagnets.append((
            magnet,
            savePath,
            startsPaused,
            queuePriority,
            enablePeerExchange,
            allowNonHTTPSTrackers,
            allowNonHTTPSWebSeeds,
            allowPreMetadataDHT
        ))
        if addMagnetSuspensionCount > 0 {
            addMagnetSuspensionCount -= 1
            await withCheckedContinuation { continuation in
                addMagnetContinuations.append(continuation)
            }
        }
        if let addMagnetError {
            throw addMagnetError
        }
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
        pauseAppliedDHTValues.append(appliedSettings.last?.settings.enableDHTNetwork)
        pauseNetworkBlockedValues.append(currentNetworkBlocked)
    }

    func resume(id: String) async throws {
        resumedIDs.append(id)
    }

    func reannounce(id: String) async throws {}

    func forceRecheck(id: String) async throws {}

    func remove(
        id: String,
        deleteFiles: Bool
    ) async throws -> TorrentRemovalOutcome {
        if let removeError {
            throw removeError
        }
        removed.append((id, deleteFiles))
        if removeSuspensionCount > 0 {
            removeSuspensionCount -= 1
            await withCheckedContinuation { continuation in
                removeContinuations.append(continuation)
            }
        }
        if becomesUnavailableOnRemove {
            availability.withLock { $0 = false }
        }
        return removeOutcome
    }

    func applySettings(_ settings: TorrentSettings, networkBlocked: Bool) async throws {
        appliedSettings.append((settings, networkBlocked))
        currentNetworkBlocked = networkBlocked
        operations.append(.applySettings(
            dhtEnabled: settings.enableDHTNetwork,
            networkBlocked: networkBlocked
        ))
    }

    func blockNetworkNow() async throws {
        blockNetworkCount += 1
        if blockNetworkSuspensionCount > 0 {
            blockNetworkSuspensionCount -= 1
            await withCheckedContinuation { continuation in
                blockNetworkContinuations.append(continuation)
            }
        }
        currentNetworkBlocked = true
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

    func setSourcePolicy(id: String, field: TorrentSourcePolicyField, enabled: Bool) async throws {
        sourcePolicyUpdates.append((id, field, enabled))
        sourcePolicyValue[field] = enabled
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
