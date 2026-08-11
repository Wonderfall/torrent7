import Foundation
import Synchronization
import TorrentEngineModel
@testable import TorrentApp

actor RecordingCompletionHistoryStore: TorrentCompletionHistoryStoring {
    private(set) var completedIDs: Set<TorrentItem.ID>
    private(set) var rememberedIDs = [Set<TorrentItem.ID>]()
    private(set) var forgottenIDs = [Set<TorrentItem.ID>]()
    private(set) var prunedRetainedIDs = [Set<TorrentItem.ID>]()
    private var reservedIDs = Set<TorrentItem.ID>()
    private var reservedIDsByClaim = [UUID: Set<TorrentItem.ID>]()

    init(completedIDs: Set<TorrentItem.ID> = []) {
        self.completedIDs = completedIDs
    }

    func contains(_ id: TorrentItem.ID) async throws -> Bool {
        completedIDs.contains(id)
    }

    func claimNewlyCompleted(
        from candidates: [TorrentCompletionCandidate]
    ) async throws -> TorrentCompletionClaim {
        try Task.checkCancellation()
        let newlyCompleted = candidates.filter {
            !completedIDs.contains($0.id) && !reservedIDs.contains($0.id)
        }
        try Task.checkCancellation()
        let claimID = UUID()
        let claimedIDs = Set(newlyCompleted.map(\.id))
        reservedIDs.formUnion(claimedIDs)
        reservedIDsByClaim[claimID] = claimedIDs
        return TorrentCompletionClaim(
            id: claimID,
            candidates: newlyCompleted
        )
    }

    func finalizeCompletionClaim(
        _ id: UUID,
        remembering completedIDs: Set<TorrentItem.ID>
    ) {
        releaseCompletionClaim(id)
        rememberedIDs.append(completedIDs)
        self.completedIDs.formUnion(completedIDs)
    }

    func abandonCompletionClaim(_ id: UUID) {
        releaseCompletionClaim(id)
    }

    func remember(_ ids: Set<TorrentItem.ID>) async throws {
        try Task.checkCancellation()
        rememberedIDs.append(ids)
        completedIDs.formUnion(ids)
    }

    func forget(_ ids: Set<TorrentItem.ID>) async throws {
        try Task.checkCancellation()
        forgottenIDs.append(ids)
        completedIDs.subtract(ids)
    }

    func prune(retaining activeIDs: Set<TorrentItem.ID>) async throws {
        try Task.checkCancellation()
        prunedRetainedIDs.append(activeIDs)
        completedIDs.formIntersection(activeIDs)
    }

    private func releaseCompletionClaim(_ id: UUID) {
        guard let claimedIDs = reservedIDsByClaim.removeValue(forKey: id) else {
            return
        }
        reservedIDs.subtract(claimedIDs)
    }
}

actor RecordingNotificationService: TorrentNotificationServicing {
    struct Notification: Equatable, Sendable {
        let torrentName: String?
        let playsSound: Bool
    }

    private(set) var notifications = [Notification]()
    private(set) var clearBadgeCount = 0

    @MainActor
    func configure() {}

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

@MainActor
final class RecordingDownloadFolderAccessStore: DownloadFolderAccessStoring {
    var defaultURL: URL?
    private(set) var capabilityRevision: UInt64 = 0
    var capabilityDefaultAccess: DownloadFolderAccessing?
    var capabilityAdditionalAccesses = [DownloadFolderAccessing]()
    var mirrorsCapabilityMutations = false
    var capabilitySnapshot: DownloadFolderCapabilitySnapshot {
        DownloadFolderCapabilitySnapshot(
            revision: capabilityRevision,
            defaultAccess: capabilityDefaultAccess,
            additionalAccesses: capabilityAdditionalAccesses
        )
    }
    var pruneSnapshot: DownloadFolderPruneSnapshot {
        DownloadFolderPruneSnapshot(
            capabilityRevision: capabilityRevision,
            candidateAccessKeys: Set(capabilityAdditionalAccesses.map {
                Self.accessKey($0.url)
            })
        )
    }
    var restoreDefaultResult: Result<URL?, Error> = .success(nil)
    var validateSelectionResult: Result<Void, Error> = .success(())
    var setDefaultResult: Result<URL, Error>?
    var prepareForAddResult: Result<PreparedDownloadFolder, Error>?
    var leaseResult: Result<DownloadFolderAccessLease, Error>?
    var nextCapabilityDelegationBookmarkError: (any Error)?
    private(set) var clearedDefaultCount = 0
    private(set) var clearDefaultCalls = [[TorrentItem]]()
    private(set) var setDefaultCalls = [(url: URL, activeTorrents: [TorrentItem])]()
    private(set) var prepareForAddCalls = [(url: URL, setsDefault: Bool, activeTorrents: [TorrentItem])]()
    private(set) var commitPreparedForAddCalls = [(folder: PreparedDownloadFolder, activeTorrents: [TorrentItem])]()
    private(set) var leaseCalls = [String]()
    private(set) var pruneCalls = [[TorrentItem]]()
    var onPrune: (() -> Void)?
    var onMakeCapabilitySnapshot: (() -> Void)?
    private(set) var bootstrapCount = 0
    private(set) var capabilitySnapshotIsSuspended = false
    private var suspendsNextCapabilitySnapshot = false
    private var capabilitySnapshotContinuation:
        CheckedContinuation<Void, Never>?

    func setCapabilityPaths(_ paths: [String]) {
        capabilityDefaultAccess = nil
        capabilityAdditionalAccesses = paths.map { path in
            FakeDownloadFolderAccess(url: URL(filePath: path, directoryHint: .isDirectory))
        }
        advanceCapabilityRevision()
    }

    func bootstrap() async -> DownloadFolderBootstrapResult {
        bootstrapCount += 1
        do {
            let restoredURL = try restoreDefaultResult.get()
            defaultURL = restoredURL
            return DownloadFolderBootstrapResult(
                defaultURL: restoredURL,
                discardedInvalidDefault: false
            )
        } catch {
            defaultURL = nil
            return DownloadFolderBootstrapResult(
                defaultURL: nil,
                discardedInvalidDefault: true
            )
        }
    }

    func currentDefaultURL() async -> URL? {
        defaultURL
    }

    func currentCapabilityRevision() async -> UInt64 {
        capabilityRevision
    }

    func makeCapabilitySnapshot() async -> DownloadFolderCapabilitySnapshot {
        let snapshot = capabilitySnapshot
        onMakeCapabilitySnapshot?()
        if suspendsNextCapabilitySnapshot {
            suspendsNextCapabilitySnapshot = false
            capabilitySnapshotIsSuspended = true
            await withCheckedContinuation { continuation in
                precondition(capabilitySnapshotContinuation == nil)
                capabilitySnapshotContinuation = continuation
            }
            capabilitySnapshotIsSuspended = false
        }
        return snapshot
    }

    func suspendNextCapabilitySnapshot() {
        precondition(!suspendsNextCapabilitySnapshot)
        precondition(capabilitySnapshotContinuation == nil)
        suspendsNextCapabilitySnapshot = true
    }

    func resumeSuspendedCapabilitySnapshot() {
        guard let capabilitySnapshotContinuation else {
            return
        }
        self.capabilitySnapshotContinuation = nil
        capabilitySnapshotContinuation.resume()
    }

    func makePruneSnapshot() async -> DownloadFolderPruneSnapshot {
        pruneSnapshot
    }

    func clearDefaultBookmarkAndAccess() async {
        clearedDefaultCount += 1
        defaultURL = nil
    }

    func validateSelection(_ url: URL) async throws {
        try validateSelectionResult.get()
    }

    func isCurrentDefault(_ url: URL?) -> Bool {
        guard let url, let defaultURL else {
            return false
        }
        return url.torrentFilePath == defaultURL.torrentFilePath
    }

    @discardableResult
    func setDefault(
        _ url: URL,
        activeTorrents: [TorrentItem]
    ) async throws -> DownloadFolderDefaultUpdate {
        setDefaultCalls.append((url, activeTorrents))
        let previousURL = defaultURL
        let result = try (setDefaultResult ?? .success(url)).get()
        defaultURL = result
        if mirrorsCapabilityMutations {
            let previousDefaultAccess = capabilityDefaultAccess
            capabilityDefaultAccess = FakeDownloadFolderAccess(
                url: result,
                delegationBookmarkError: nextCapabilityDelegationBookmarkError
            )
            nextCapabilityDelegationBookmarkError = nil
            preserveCapabilityIfNeeded(previousDefaultAccess, activeTorrents: activeTorrents)
            capabilityAdditionalAccesses.removeAll {
                Self.accessKey($0.url) == Self.accessKey(result)
            }
            pruneCapabilities(activeTorrents: activeTorrents)
            advanceCapabilityRevision()
        }
        return DownloadFolderDefaultUpdate(
            url: result,
            didChange: previousURL?.torrentFilePath != result.torrentFilePath
        )
    }

    func clearDefault(activeTorrents: [TorrentItem]) async {
        clearDefaultCalls.append(activeTorrents)
        defaultURL = nil
        if mirrorsCapabilityMutations {
            let hadDefaultCapability = capabilityDefaultAccess != nil
            let previousPaths = Set(capabilitySnapshot.paths)
            let previousDefaultAccess = capabilityDefaultAccess
            capabilityDefaultAccess = nil
            preserveCapabilityIfNeeded(previousDefaultAccess, activeTorrents: activeTorrents)
            pruneCapabilities(activeTorrents: activeTorrents)
            if hadDefaultCapability
                || Set(capabilitySnapshot.paths) != previousPaths {
                advanceCapabilityRevision()
            }
        }
    }

    func prepareForAdd(
        _ url: URL,
        setsDefault: Bool,
        activeTorrents: [TorrentItem]
    ) async throws -> PreparedDownloadFolder {
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
    ) async -> URL? {
        commitPreparedForAddCalls.append((preparedFolder, activeTorrents))
        if let defaultURL = preparedFolder.defaultURL {
            self.defaultURL = defaultURL
        }
        if mirrorsCapabilityMutations, preparedFolder.bookmarkData != nil {
            let access = FakeDownloadFolderAccess(
                url: URL(filePath: preparedFolder.path, directoryHint: .isDirectory)
            )
            if preparedFolder.defaultURL != nil {
                capabilityDefaultAccess = access
                capabilityAdditionalAccesses.removeAll {
                    Self.accessKey($0.url) == Self.accessKey(access.url)
                }
                pruneCapabilities(activeTorrents: activeTorrents)
            } else {
                capabilityAdditionalAccesses.removeAll {
                    Self.accessKey($0.url) == Self.accessKey(access.url)
                }
                capabilityAdditionalAccesses.append(access)
            }
            advanceCapabilityRevision()
        }
        return preparedFolder.defaultURL
    }

    func lease(
        forSavePath path: String
    ) async throws -> DownloadFolderAccessLease {
        leaseCalls.append(path)
        let result = leaseResult ?? .success(DownloadFolderAccessLease(
            access: FakeDownloadFolderAccess(url: URL(filePath: path, directoryHint: .isDirectory))
        ))
        leaseResult = nil
        return try result.get()
    }

    @discardableResult
    func applyPrunePlan(
        _ plan: DownloadFolderPrunePlan,
        activeTorrents: [TorrentItem]
    ) async -> Bool {
        guard plan.capabilityRevision == capabilityRevision else {
            return false
        }
        pruneCalls.append(activeTorrents)
        if mirrorsCapabilityMutations {
            let previousPaths = Set(capabilitySnapshot.paths)
            capabilityAdditionalAccesses.removeAll {
                !plan.retainedAccessKeys.contains(Self.accessKey($0.url))
            }
            if Set(capabilitySnapshot.paths) != previousPaths {
                advanceCapabilityRevision()
            }
        }
        onPrune?()
        return true
    }

    private func advanceCapabilityRevision() {
        precondition(capabilityRevision != UInt64.max)
        capabilityRevision += 1
    }

    private func preserveCapabilityIfNeeded(
        _ access: DownloadFolderAccessing?,
        activeTorrents: [TorrentItem]
    ) {
        guard let access else {
            return
        }
        let key = Self.accessKey(access.url)
        guard activeTorrents.contains(where: {
            Self.accessKey(URL(filePath: $0.savePath, directoryHint: .isDirectory)) == key
        }), !capabilityAdditionalAccesses.contains(where: {
            Self.accessKey($0.url) == key
        }) else {
            return
        }
        capabilityAdditionalAccesses.append(access)
    }

    private func pruneCapabilities(activeTorrents: [TorrentItem]) {
        let activeKeys = Set(activeTorrents.map {
            Self.accessKey(URL(filePath: $0.savePath, directoryHint: .isDirectory))
        })
        let defaultKey = capabilityDefaultAccess.map { Self.accessKey($0.url) }
        capabilityAdditionalAccesses.removeAll { access in
            let key = Self.accessKey(access.url)
            return key == defaultKey || !activeKeys.contains(key)
        }
    }

    private static func accessKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().torrentFilePath
    }
}

@MainActor
final class RecordingTorrentFileLocationService: TorrentFileLocationServicing {
    var revealURLs = [TorrentItem.ID: URL]()
    private var revealURLSuspensionCount = 0
    private var revealURLContinuations = [CheckedContinuation<Void, Never>]()

    func suspendNextRevealURLs() {
        revealURLSuspensionCount += 1
    }

    func waitForSuspendedRevealURLs() async {
        while revealURLContinuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeSuspendedRevealURLs() {
        let continuations = revealURLContinuations
        revealURLContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func revealURL(for torrent: TorrentItem) async throws -> URL? {
        revealURLs[torrent.id]
    }

    func revealURL(for torrent: TorrentItem, filePath: String) async throws -> URL? {
        revealURLs[torrent.id]
    }

    func revealURLs(for torrents: [TorrentItem]) async throws -> [URL] {
        if revealURLSuspensionCount > 0 {
            revealURLSuspensionCount -= 1
            await withCheckedContinuation { continuation in
                revealURLContinuations.append(continuation)
            }
        }
        return torrents.compactMap { revealURLs[$0.id] }
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
    private nonisolated let recovery = Mutex(TorrentEngineRecoveryDisposition.none)
    private let keepsWakeStreamOpen: Bool
    private var wakeContinuation: AsyncStream<Void>.Continuation?
    private(set) var wakeStreamRequestCount = 0

    nonisolated var isAvailable: Bool {
        availability.withLock { $0 }
    }

    nonisolated var recoveryDisposition: TorrentEngineRecoveryDisposition {
        recovery.withLock { $0 }
    }

    var snapshotBatch: TorrentSnapshotBatch?
    var trackerBatchValue = TorrentTrackerBatch(revision: 0, trackers: [])
    var trackerHostBatchValue = TorrentTrackerHostBatch(revision: 0, hosts: [])
    var webSeedBatchValue = TorrentWebSeedBatch(revision: 0, webSeeds: [])
    var fileBatchValue = TorrentFileBatch(revision: 0, files: [])
    var pieceMapBatchValue = TorrentPieceMapBatch(revision: 0, pieceMap: .empty)
    private var trackerBatchSuspensionCount = 0
    private var trackerBatchContinuations =
        [CheckedContinuation<Void, Never>]()
    private var trackerHostBatchSuspensionCount = 0
    private var trackerHostBatchContinuations = [CheckedContinuation<Void, Never>]()
    private var snapshotBatchSuspensionCount = 0
    private var snapshotBatchContinuations = [CheckedContinuation<Void, Never>]()
    private var snapshotFailureDisposition: TorrentEngineRecoveryDisposition?
    private var nextPollError: Error?
    var dirtyMask: UInt32 = 0
    var networkStatusValue = TorrentNetworkStatus(
        requestedRevision: 0,
        submittedRevision: 0,
        listenPort: 0,
        networkBlocked: false,
        hasListener: false,
        endpoint: "",
        lastError: ""
    )
    var bridgeHealthValue = TorrentBridgeHealth.healthy
    var networkInterfaceSnapshotValue: TorrentNetworkInterfaceSnapshot?
    var alertErrors = [String]()
    var nextAddedMagnetID = "alpha"
    var addMagnetError: Error?
    var nextAddedTorrentFileID = "alpha"
    private(set) var restartCount = 0
    private(set) var restartPeerExchangePluginValues = [Bool]()
    private(set) var restartAuthorizedSavePathSnapshots = [[String]]()
    private var restartSuspensionCount = 0
    private var restartContinuations = [CheckedContinuation<Void, Never>]()
    private(set) var blockNetworkCount = 0
    private var nextNetworkBlockDisposition = TorrentNetworkBlockDisposition.engineRemainsAvailable
    private var nextNetworkBlockRecoveryDisposition = TorrentEngineRecoveryDisposition.replaceController
    private var nextNetworkBlockError: Error?
    private var blockNetworkSuspensionCount = 0
    private var blockNetworkContinuations = [CheckedContinuation<Void, Never>]()
    private var applySettingsSuspensionCount = 0
    private var applySettingsContinuations = [CheckedContinuation<Void, Never>]()
    private(set) var currentNetworkBlocked = false
    private(set) var saveAllCount = 0
    private var nextSaveAllError: Error?
    private(set) var shutdownCount = 0
    private(set) var appliedSettings = [(
        settings: TorrentSettings,
        networkBinding: TorrentNetworkBinding,
        networkBlocked: Bool
    )]()
    private(set) var operations = [FakeTorrentEngineOperation]()
    private(set) var previewedTorrentFiles = [Data]()
    private var previewSuspensionCount = 0
    private var previewContinuations = [CheckedContinuation<Void, Never>]()
    private(set) var delegatedFolderAuthorizations = [TorrentFolderAuthorization]()
    private(set) var reconciledFolderAuthorizationSnapshots = [[TorrentFolderAuthorization]]()
    private var folderReconciliationSuspensionCount = 0
    private var folderReconciliationContinuations = [CheckedContinuation<Void, Never>]()
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
    private(set) var trackerBatchRequests = [(id: String, revision: UInt64?)]()
    private(set) var webSeedBatchRequests = [(id: String, revision: UInt64?)]()
    private(set) var fileBatchRequests = [(id: String, revision: UInt64?)]()
    private(set) var pieceMapBatchRequests = [(id: String, revision: UInt64?)]()
    private(set) var sourcePolicyUpdates = [(id: String, field: TorrentSourcePolicyField, enabled: Bool)]()
    private(set) var torrentOptionsUpdates = [(id: String, options: TorrentOptions)]()
    private(set) var filePriorityUpdates = [(id: String, fileIndex: Int32, priority: TorrentFilePriority)]()
    private(set) var queueMoves = [(id: String, move: TorrentQueueMove)]()
    private(set) var requestedPieceMapIDs = [String]()
    private(set) var requestedSourceIDs = [String]()
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

    init(
        keepsWakeStreamOpen: Bool = false,
        networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot? = nil,
        suspendsInitialSnapshotBatch: Bool = false
    ) {
        self.keepsWakeStreamOpen = keepsWakeStreamOpen
        networkInterfaceSnapshotValue = networkInterfaceSnapshot
        snapshotBatchSuspensionCount = suspendsInitialSnapshotBatch ? 1 : 0
    }

    func shutdown() {
        shutdownCount += 1
        availability.withLock { $0 = false }
        wakeContinuation?.finish()
        wakeContinuation = nil
    }

    func terminateConnection(
        recoveryDisposition: TorrentEngineRecoveryDisposition
    ) {
        recovery.withLock { current in
            if current == .terminal || recoveryDisposition == .terminal {
                current = .terminal
            } else if current == .replaceController || recoveryDisposition == .replaceController {
                current = .replaceController
            } else {
                current = .none
            }
        }
        shutdown()
    }

    func setSnapshotBatch(_ batch: TorrentSnapshotBatch?) {
        snapshotBatch = batch
    }

    func setTrackerHostBatch(_ batch: TorrentTrackerHostBatch) {
        trackerHostBatchValue = batch
    }

    func setTrackerBatch(_ batch: TorrentTrackerBatch) {
        trackerBatchValue = batch
    }

    func setWebSeedBatch(_ batch: TorrentWebSeedBatch) {
        webSeedBatchValue = batch
    }

    func setFileBatch(_ batch: TorrentFileBatch) {
        fileBatchValue = batch
    }

    func setPieceMapBatch(_ batch: TorrentPieceMapBatch) {
        pieceMapBatchValue = batch
    }

    func suspendNextTrackerBatchCall() {
        trackerBatchSuspensionCount += 1
    }

    func waitForSuspendedTrackerBatchCall() async {
        while trackerBatchContinuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeSuspendedTrackerBatchCalls() {
        let continuations = trackerBatchContinuations
        trackerBatchContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
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

    func suspendNextSnapshotBatchCall() {
        snapshotBatchSuspensionCount += 1
    }

    func waitForSuspendedSnapshotBatchCall() async {
        while snapshotBatchContinuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeSuspendedSnapshotBatchCalls() {
        let continuations = snapshotBatchContinuations
        snapshotBatchContinuations.removeAll()
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

    func setBridgeHealth(_ health: TorrentBridgeHealth) {
        bridgeHealthValue = health
    }

    func setNetworkInterfaceSnapshot(_ snapshot: TorrentNetworkInterfaceSnapshot?) {
        networkInterfaceSnapshotValue = snapshot
    }

    func failNextSnapshotBatchCall(
        recoveryDisposition: TorrentEngineRecoveryDisposition
    ) {
        snapshotFailureDisposition = recoveryDisposition
    }

    func setNextPollError(_ error: Error?) {
        nextPollError = error
    }

    func setNextSaveAllError(_ error: Error?) {
        nextSaveAllError = error
    }

    func suspendNextTorrentPreview() {
        previewSuspensionCount += 1
    }

    func waitForSuspendedTorrentPreview() async {
        while previewContinuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeSuspendedTorrentPreviews() {
        let continuations = previewContinuations
        previewContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func setRecoveryDisposition(_ disposition: TorrentEngineRecoveryDisposition) {
        recovery.withLock { $0 = disposition }
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

    func waitForNetworkBlockCount(_ expectedCount: Int) async {
        while blockNetworkCount < expectedCount {
            await Task.yield()
        }
    }

    func suspendNextNetworkBlock() {
        blockNetworkSuspensionCount += 1
    }

    func requireControllerReplacementOnNextNetworkBlock(
        recoveryDisposition: TorrentEngineRecoveryDisposition = .replaceController
    ) {
        nextNetworkBlockDisposition = .engineReplacementRequired
        nextNetworkBlockRecoveryDisposition = recoveryDisposition
    }

    func setNextNetworkBlockError(_ error: Error?) {
        nextNetworkBlockError = error
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

    func suspendNextSettingsApplication() {
        applySettingsSuspensionCount += 1
    }

    func waitForSuspendedSettingsApplication() async {
        while applySettingsContinuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeSuspendedSettingsApplications() {
        let continuations = applySettingsContinuations
        applySettingsContinuations.removeAll()
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

    func suspendNextRestart() {
        restartSuspensionCount += 1
    }

    func waitForSuspendedRestart() async {
        while restartContinuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeSuspendedRestarts() {
        let continuations = restartContinuations
        restartContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func suspendNextFolderReconciliation() {
        folderReconciliationSuspensionCount += 1
    }

    func waitForSuspendedFolderReconciliation() async {
        while folderReconciliationContinuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeSuspendedFolderReconciliations() {
        let continuations = folderReconciliationContinuations
        folderReconciliationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func restart(enablePeerExchangePlugin: Bool, authorizedSavePaths: [String]) async throws {
        restartCount += 1
        restartPeerExchangePluginValues.append(enablePeerExchangePlugin)
        restartAuthorizedSavePathSnapshots.append(authorizedSavePaths)
        if restartSuspensionCount > 0 {
            restartSuspensionCount -= 1
            await withCheckedContinuation { continuation in
                restartContinuations.append(continuation)
            }
        }
        currentNetworkBlocked = true
        networkStatusValue = networkStatusValue.withNetworkBlocked(true)
        availability.withLock { $0 = true }
    }

    func delegateFolderAuthorization(_ authorization: TorrentFolderAuthorization) {
        delegatedFolderAuthorizations.append(authorization)
    }

    func reconcileFolderAuthorizations(
        _ authorizations: [TorrentFolderAuthorization]
    ) async {
        reconciledFolderAuthorizationSnapshots.append(authorizations)
        if folderReconciliationSuspensionCount > 0 {
            folderReconciliationSuspensionCount -= 1
            await withCheckedContinuation { continuation in
                folderReconciliationContinuations.append(continuation)
            }
        }
    }

    func wakeEvents() async -> AsyncStream<Void> {
        wakeStreamRequestCount += 1
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

    func emitWake() {
        wakeContinuation?.yield()
    }

    func waitForWakeStreamRequestCount(_ expectedCount: Int) async {
        while wakeStreamRequestCount < expectedCount {
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
        if previewSuspensionCount > 0 {
            previewSuspensionCount -= 1
            await withCheckedContinuation { continuation in
                previewContinuations.append(continuation)
            }
        }
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

    func applySettings(
        _ settings: TorrentSettings,
        networkBinding: TorrentNetworkBinding
    ) async throws {
        if applySettingsSuspensionCount > 0 {
            applySettingsSuspensionCount -= 1
            await withCheckedContinuation { continuation in
                applySettingsContinuations.append(continuation)
            }
        }
        appliedSettings.append((settings, networkBinding, networkBinding.networkBlocked))
        currentNetworkBlocked = networkBinding.networkBlocked
        networkStatusValue = networkStatusValue.withNetworkBlocked(networkBinding.networkBlocked)
        operations.append(.applySettings(
            dhtEnabled: settings.enableDHTNetwork,
            networkBlocked: networkBinding.networkBlocked
        ))
    }

    func blockNetworkNow() async throws -> TorrentNetworkBlockDisposition {
        blockNetworkCount += 1
        if blockNetworkSuspensionCount > 0 {
            blockNetworkSuspensionCount -= 1
            await withCheckedContinuation { continuation in
                blockNetworkContinuations.append(continuation)
            }
        }
        if let nextNetworkBlockError {
            self.nextNetworkBlockError = nil
            throw nextNetworkBlockError
        }
        currentNetworkBlocked = true
        networkStatusValue = networkStatusValue.withNetworkBlocked(true)
        let disposition = nextNetworkBlockDisposition
        nextNetworkBlockDisposition = .engineRemainsAvailable
        if disposition == .engineReplacementRequired {
            recovery.withLock { $0 = nextNetworkBlockRecoveryDisposition }
            nextNetworkBlockRecoveryDisposition = .replaceController
            availability.withLock { $0 = false }
        }
        return disposition
    }

    func saveAll() async throws {
        saveAllCount += 1
        if let nextSaveAllError {
            self.nextSaveAllError = nil
            throw nextSaveAllError
        }
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

    func bridgeHealth() async -> TorrentBridgeHealth {
        bridgeHealthValue
    }

    func networkInterfaceSnapshot() async -> TorrentNetworkInterfaceSnapshot? {
        networkInterfaceSnapshotValue
    }

    func poll(
        since revision: UInt64?,
        sortedBy sortOrder: TorrentSortOrder,
        direction: TorrentSortDirection,
        includeTrackerHosts: Bool
    ) async throws -> TorrentEnginePollResult {
        if let nextPollError {
            self.nextPollError = nil
            throw nextPollError
        }
        let health = bridgeHealthValue
        let changes = dirtyMask
        dirtyMask = 0
        var errors = [String]()
        errors.reserveCapacity(TorrentEngineLimits.maximumAlertErrorsPerPoll)
        for _ in 0..<TorrentEngineLimits.maximumAlertErrorsPerPoll {
            guard !alertErrors.isEmpty else {
                break
            }
            let error = alertErrors.removeFirst()
            if !error.isEmpty {
                errors.append(error)
            }
        }
        let status = networkStatusValue
        let interfaceSnapshot = networkInterfaceSnapshotValue
        let trackerHostsChanged = TorrentEngineDirtySet(rawValue: changes).contains(.trackerHosts)
        let trackerHosts = includeTrackerHosts || trackerHostsChanged
            ? await trackerHostBatch()
            : nil
        let snapshots = await snapshotsIfChanged(
            since: revision,
            sortedBy: sortOrder,
            direction: direction
        )
        return TorrentEnginePollResult(
            dirtyMask: changes,
            alertErrors: errors,
            networkStatus: status,
            bridgeHealth: health,
            snapshotBatch: snapshots,
            trackerHostBatch: trackerHosts,
            networkInterfaceSnapshot: interfaceSnapshot
        )
    }

    func snapshotsIfChanged(
        since revision: UInt64?,
        sortedBy sortOrder: TorrentSortOrder,
        direction: TorrentSortDirection
    ) async -> TorrentSnapshotBatch? {
        snapshotRequests.append((revision, sortOrder, direction))
        let response = snapshotBatch.map { batch in
            TorrentSnapshotBatch(revision: batch.revision, torrents: sortOrder.sorted(batch.torrents, direction: direction))
        }
        if snapshotBatchSuspensionCount > 0 {
            snapshotBatchSuspensionCount -= 1
            await withCheckedContinuation { continuation in
                snapshotBatchContinuations.append(continuation)
            }
        }
        if let snapshotFailureDisposition {
            self.snapshotFailureDisposition = nil
            recovery.withLock { $0 = snapshotFailureDisposition }
            availability.withLock { $0 = false }
        }
        return response
    }

    func requestSources(id: String) async throws {
        requestedSourceIDs.append(id)
    }

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

    func trackerBatch(id: String, since revision: UInt64?) async -> TorrentTrackerBatch? {
        trackerBatchRequests.append((id, revision))
        let response =
            revision == trackerBatchValue.revision
                ? nil
                : trackerBatchValue
        if trackerBatchSuspensionCount > 0 {
            trackerBatchSuspensionCount -= 1
            await withCheckedContinuation { continuation in
                trackerBatchContinuations.append(continuation)
            }
        }
        return response
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

    func webSeedBatch(id: String, since revision: UInt64?) async -> TorrentWebSeedBatch? {
        webSeedBatchRequests.append((id, revision))
        return revision == webSeedBatchValue.revision ? nil : webSeedBatchValue
    }

    func webSeedActivity(id: String) async -> TorrentWebSeedActivity? {
        .empty
    }

    func peerSources(id: String) async -> TorrentPeerSources? {
        .empty
    }

    func fileBatch(id: String, since revision: UInt64?) async -> TorrentFileBatch? {
        fileBatchRequests.append((id, revision))
        return revision == fileBatchValue.revision ? nil : fileBatchValue
    }

    func pieceMapBatch(id: String, since revision: UInt64?) async -> TorrentPieceMapBatch? {
        pieceMapBatchRequests.append((id, revision))
        return revision == pieceMapBatchValue.revision ? nil : pieceMapBatchValue
    }
}

private extension TorrentNetworkStatus {
    func withNetworkBlocked(_ networkBlocked: Bool) -> TorrentNetworkStatus {
        TorrentNetworkStatus(
            requestedRevision: requestedRevision,
            submittedRevision: submittedRevision,
            listenPort: listenPort,
            networkBlocked: networkBlocked,
            hasListener: networkBlocked ? false : hasListener,
            endpoint: networkBlocked ? "" : endpoint,
            lastError: lastError
        )
    }
}

struct FakeBookmarkError: Error {}

final class FakeDownloadFolderAccess: DownloadFolderAccessing {
    let url: URL
    private let delegationBookmarkError: (any Error)?

    init(url: URL, delegationBookmarkError: (any Error)? = nil) {
        self.url = url
        self.delegationBookmarkError = delegationBookmarkError
    }

    func bookmarkData() throws -> Data {
        Data(url.torrentFilePath.utf8)
    }

    func delegationBookmarkData() throws -> Data {
        if let delegationBookmarkError {
            throw delegationBookmarkError
        }
        return Data("delegation:\(url.torrentFilePath)".utf8)
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
        return FakeDownloadFolderAccess(url: URL(filePath: path, directoryHint: .isDirectory))
    }

    func clearDefaultBookmark(defaults: UserDefaults) {
        defaults.removeObject(forKey: SecurityScopedFolder.defaultsKey)
    }
}
