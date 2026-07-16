import AppKit
import Darwin
import Foundation
import Observation
import System
import TorrentBridge

private struct AppliedNetworkBinding: Equatable {
    var interfaceName: String
    var interfaceFingerprint: String
    var vpnServiceID: String
    var networkBlocked: Bool
}

private enum TorrentStoreErrorSource {
    case settingsApply
    case userAction
}

private typealias TorrentStoreUserOperation = @MainActor @Sendable (TorrentStore) async -> Void

private struct TorrentStorePendingSettingsApplication {
    var settings: TorrentSettings
    var networkBinding: AppliedNetworkBinding
    var refreshes: Bool
    var notifiesCompletions: Bool
}

private enum TorrentStorePendingOperation {
    case applySettings(TorrentStorePendingSettingsApplication)
    case user(TorrentStoreUserOperation)
}

@MainActor
@Observable
final class TorrentStore {
    private static let maximumPendingUserOperationCount = 64
    private static let maximumPendingOperationCount = maximumPendingUserOperationCount * 2 + 1

    let commandState = TorrentCommandState()
    let selectionState = TorrentSelectionState()
    let torrentState = TorrentListState()
    let sidebarState = TorrentSidebarState()
    let settingsState: TorrentSettingsState

    private(set) var torrents: [TorrentItem] = [] {
        didSet {
            torrentsByID = Dictionary(torrents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            torrentInfoTabRequests = torrentInfoTabRequests.filter { torrentsByID[$0.key] != nil }
            torrentState.update(torrents)
            updateCommandState()
            updateSidebarState()
        }
    }
    private(set) var downloadFolder: URL?
    private(set) var lastError: String?
    private(set) var settings: TorrentSettings
    private(set) var sortOrder: TorrentSortOrder
    private(set) var sortDirection: TorrentSortDirection
    private(set) var networkInterfaces: [NetworkInterfaceOption] = []
    private(set) var networkStatus: TorrentNetworkStatus = .empty
    private(set) var bridgeHealth: TorrentBridgeHealth = .unavailable
    private(set) var torrentInfoTabRequests = [TorrentItem.ID: TorrentInfoTabRequest]()
    private(set) var labels: [TorrentLabel] = []
    private(set) var labelAssignments: [TorrentItem.ID: Set<TorrentLabel.ID>] = [:]
    private(set) var trackerHostsByTorrentID: [TorrentItem.ID: Set<String>] = [:]

    let libtorrentVersion: String

    private let engine: any TorrentEngineServicing
    private let dockTileService: TorrentDockTileServicing
    private let completionNotifier: TorrentCompletionNotifier
    private let sleepPreventionService: SleepPreventionServicing
    private let networkInterfaceMonitor: NetworkInterfaceMonitoring
    private let downloadFolderAccessStore: DownloadFolderAccessStoring
    private let fileLocationService: TorrentFileLocationServicing
    private let labelStore: TorrentLabelStore
    private let defaults: UserDefaults
    private var refreshTask: Task<Void, Never>?
    private var wakeRefreshTask: Task<Void, Never>?
    private var networkInterfaceTask: Task<Void, Never>?
    @ObservationIgnored
    private var operationDrainTask: Task<Void, Never>?
    @ObservationIgnored
    private var immediateNetworkBlockTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingOperations = [TorrentStorePendingOperation]()
    private var appliedNetworkBinding: AppliedNetworkBinding?
    private var appliedPeerExchangePluginEnabled: Bool?
    private var immediateNetworkBlockBinding: AppliedNetworkBinding?
    private var immediateNetworkBlockGeneration: UInt64 = 0
    private var torrentsByID = [TorrentItem.ID: TorrentItem]()
    private var lastErrorGeneration = 0
    private var lastErrorSource: TorrentStoreErrorSource?
    private var lastSnapshotRevision: UInt64?
    private var lastTrackerHostRevision: UInt64?
    private var pendingTrackerHostRefresh = false
    private var refreshGeneration = 0
    private var nextTorrentInfoTabRequestToken = 0

    init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults
        let loadedSettings = TorrentSettings.load(defaults: defaults)
        let loadedSortOrder = TorrentSortOrder.load(defaults: defaults)
        settings = loadedSettings
        sortOrder = loadedSortOrder
        sortDirection = TorrentSortDirection.load(for: loadedSortOrder, defaults: defaults)
        let dockTileService = TorrentDockTileService()
        self.dockTileService = dockTileService
        completionNotifier = TorrentCompletionNotifier(dockTileService: dockTileService)
        sleepPreventionService = SleepPreventionService()
        networkInterfaceMonitor = NetworkInterfaceMonitor()
        downloadFolderAccessStore = DownloadFolderAccessStore()
        fileLocationService = TorrentFileLocationService()
        labelStore = TorrentLabelStore(defaults: defaults)
        let loadedLabels = labelStore.load()
        labels = loadedLabels.labels
        labelAssignments = loadedLabels.assignments
        var restoredDownloadFolder: URL?
        var restoredFolderError: String?

        do {
            restoredDownloadFolder = try downloadFolderAccessStore.restoreDefault()
            downloadFolder = restoredDownloadFolder
        } catch {
            downloadFolderAccessStore.clearDefaultBookmarkAndAccess()
            downloadFolder = nil
            restoredFolderError = "The saved download folder could not be restored. Choose a download folder again."
        }
        settingsState = TorrentSettingsState(settings: loadedSettings, downloadFolder: restoredDownloadFolder)

        var engineStartupError: String?
        let createdEngine: TorrentEngine
        do {
            let stateDirectory = try Self.makeStateDirectory()
            do {
                createdEngine = try TorrentEngine(
                    stateDirectory: stateDirectory,
                    enablePeerExchangePlugin: loadedSettings.enablePeerExchangePlugin
                )
            } catch {
                let message = Self.engineStartupErrorMessage(error)
                engineStartupError = message
                createdEngine = TorrentEngine(startupFailureMessage: message)
            }
        } catch {
            let message = Self.engineStartupErrorMessage(error)
            engineStartupError = message
            createdEngine = TorrentEngine(startupFailureMessage: message)
        }

        engine = createdEngine
        appliedPeerExchangePluginEnabled = loadedSettings.enablePeerExchangePlugin
        libtorrentVersion = createdEngine.libtorrentVersion
        selectionState.didChange = { [weak self] in
            self?.updateCommandState()
        }
        updateSidebarState()
        completionNotifier.configure()
        startMonitoringNetworkInterfaces()

        let startupErrors = [restoredFolderError, engineStartupError.map { TorrentEngineError.startupFailed($0).localizedDescription }]
            .compactMap { $0 }
        if !startupErrors.isEmpty {
            setLastError(startupErrors.joined(separator: "\n\n"), source: .userAction)
        }

        if createdEngine.isAvailable {
            startInitialEngineSync()
            startRefreshing()
        }
    }

    init(
        settings: TorrentSettings = TorrentSettings(),
        sortOrder: TorrentSortOrder = .dateAdded,
        sortDirection: TorrentSortDirection = .ascending,
        downloadFolder: URL? = nil,
        engine: any TorrentEngineServicing,
        dockTileService: TorrentDockTileServicing,
        completionNotifier: TorrentCompletionNotifier,
        sleepPreventionService: SleepPreventionServicing,
        networkInterfaceMonitor: NetworkInterfaceMonitoring,
        downloadFolderAccessStore: DownloadFolderAccessStoring,
        fileLocationService: TorrentFileLocationServicing,
        defaults: UserDefaults = .standard,
        networkInterfaces: [NetworkInterfaceOption] = [],
        startsTasks: Bool = false
    ) {
        self.settings = settings
        self.sortOrder = sortOrder
        self.sortDirection = sortDirection
        self.downloadFolder = downloadFolder
        self.engine = engine
        self.dockTileService = dockTileService
        self.completionNotifier = completionNotifier
        self.sleepPreventionService = sleepPreventionService
        self.networkInterfaceMonitor = networkInterfaceMonitor
        self.downloadFolderAccessStore = downloadFolderAccessStore
        self.fileLocationService = fileLocationService
        labelStore = TorrentLabelStore(defaults: defaults)
        self.defaults = defaults
        self.networkInterfaces = networkInterfaces
        let loadedLabels = labelStore.load()
        labels = loadedLabels.labels
        labelAssignments = loadedLabels.assignments
        appliedPeerExchangePluginEnabled = settings.enablePeerExchangePlugin
        settingsState = TorrentSettingsState(
            settings: settings,
            downloadFolder: downloadFolder,
            networkInterfaces: networkInterfaces
        )
        libtorrentVersion = engine.libtorrentVersion
        selectionState.didChange = { [weak self] in
            self?.updateCommandState()
        }
        updateSidebarState()
        if startsTasks, engine.isAvailable {
            completionNotifier.configure()
            startMonitoringNetworkInterfaces()
            startInitialEngineSync()
            startRefreshing()
        }
    }

    isolated deinit {
        refreshTask?.cancel()
        wakeRefreshTask?.cancel()
        networkInterfaceTask?.cancel()
        operationDrainTask?.cancel()
        immediateNetworkBlockTask?.cancel()
        networkInterfaceMonitor.cancel()
    }

    var selectedTorrent: TorrentItem? {
        guard selectionState.ids.count == 1, let id = selectionState.ids.first else {
            return nil
        }
        return torrentsByID[id]
    }

    var engineAvailable: Bool {
        engine.isAvailable
    }

    var selectedTorrentIDs: Set<TorrentItem.ID> {
        selectionState.ids
    }

    var selectedTorrents: [TorrentItem] {
        selectionState.ids.compactMap { torrentsByID[$0] }
    }

    var hasSelectedTorrents: Bool {
        !selectionState.ids.isEmpty
    }

    var canPauseSelectedTorrents: Bool {
        selectedTorrents.contains { !$0.manuallyPaused }
    }

    var canResumeSelectedTorrents: Bool {
        selectedTorrents.contains(where: \.manuallyPaused)
    }

    var selectableNetworkInterfaces: [NetworkInterfaceOption] {
        settings.showOnlyVPNInterfaces ? networkInterfaces.filter(\.isVPNBacked) : networkInterfaces
    }

    var selectedSettingsTab: TorrentSettingsTab {
        get {
            settingsState.selectedTab
        }
        set {
            settingsState.selectedTab = newValue
        }
    }

    func torrent(id: TorrentItem.ID) -> TorrentItem? {
        torrents.first { $0.id == id }
    }

    func selectTorrent(id: TorrentItem.ID) {
        selectionState.ids = [id]
    }

    func selectTorrents(ids: Set<TorrentItem.ID>) {
        let validIDs = Set(torrentsByID.keys)
        selectionState.ids = ids.intersection(validIDs)
    }

    func requestTorrentInfoTab(_ tab: TorrentInfoTab, for id: TorrentItem.ID) {
        guard torrentsByID[id] != nil else {
            return
        }
        nextTorrentInfoTabRequestToken &+= 1
        torrentInfoTabRequests[id] = TorrentInfoTabRequest(tab: tab, token: nextTorrentInfoTabRequestToken)
    }

    func torrentInfoTabRequest(for id: TorrentItem.ID) -> TorrentInfoTabRequest? {
        torrentInfoTabRequests[id]
    }

    func labelIDs(for torrentID: TorrentItem.ID) -> Set<TorrentLabel.ID> {
        labelAssignments[torrentID] ?? []
    }

    func labels(for torrentID: TorrentItem.ID) -> [TorrentLabel] {
        let assignedIDs = labelIDs(for: torrentID)
        return labels.filter { assignedIDs.contains($0.id) }
    }

    func trackerHosts(for torrentID: TorrentItem.ID) -> Set<String> {
        trackerHostsByTorrentID[torrentID] ?? []
    }

    @discardableResult
    func createLabel(named name: String) -> TorrentLabel? {
        let normalizedName = TorrentLabel.normalizedName(name)
        guard !normalizedName.isEmpty else {
            return nil
        }
        if let existingLabel = labels.first(where: { $0.matches(name: normalizedName) }) {
            return existingLabel
        }

        let label = TorrentLabel(name: normalizedName)
        labels.append(label)
        saveLabels()
        return label
    }

    func renameLabel(id: TorrentLabel.ID, to name: String) {
        let normalizedName = TorrentLabel.normalizedName(name)
        guard !normalizedName.isEmpty,
              let index = labels.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard !labels.contains(where: { $0.id != id && $0.matches(name: normalizedName) }) else {
            return
        }

        labels[index].name = normalizedName
        saveLabels()
    }

    func deleteLabel(id: TorrentLabel.ID) {
        guard labels.contains(where: { $0.id == id }) else {
            return
        }

        labels.removeAll { $0.id == id }
        for torrentID in Array(labelAssignments.keys) {
            labelAssignments[torrentID]?.remove(id)
            if labelAssignments[torrentID]?.isEmpty == true {
                labelAssignments[torrentID] = nil
            }
        }
        saveLabels()
    }

    func setLabels(_ labelIDs: Set<TorrentLabel.ID>, forTorrent id: TorrentItem.ID) {
        guard torrentsByID[id] != nil else {
            return
        }
        setSanitizedLabels(labelIDs, forTorrent: id)
    }

    func toggleLabel(_ labelID: TorrentLabel.ID, forTorrentIDs torrentIDs: Set<TorrentItem.ID>) {
        guard labels.contains(where: { $0.id == labelID }) else {
            return
        }
        let validTorrentIDs = torrentIDs.intersection(torrentsByID.keys)
        guard !validTorrentIDs.isEmpty else {
            return
        }

        let shouldRemove = validTorrentIDs.allSatisfy { labelAssignments[$0]?.contains(labelID) == true }
        for torrentID in validTorrentIDs {
            var assignedIDs = labelAssignments[torrentID] ?? []
            if shouldRemove {
                assignedIDs.remove(labelID)
            } else {
                assignedIDs.insert(labelID)
            }
            setSanitizedLabels(assignedIDs, forTorrent: torrentID, saves: false)
        }
        saveLabels()
    }

    func reportError(_ message: String) {
        setLastError(message, source: .userAction)
    }

    func requestSources(for id: TorrentItem.ID) async throws {
        try await performQueuedUserOperation { engine in
            try await engine.requestSources(id: id)
        }
    }

    func sourcePolicy(for id: TorrentItem.ID) async throws -> TorrentSourcePolicy {
        try await engine.sourcePolicy(id: id)
    }

    func setSourcePolicy(
        for id: TorrentItem.ID,
        field: TorrentSourcePolicyField,
        enabled: Bool
    ) async throws {
        try await performQueuedUserOperation { engine in
            try await engine.setSourcePolicy(id: id, field: field, enabled: enabled)
        }
    }

    func torrentOptions(for id: TorrentItem.ID) async throws -> TorrentOptions {
        try await engine.torrentOptions(id: id)
    }

    func setTorrentOptions(for id: TorrentItem.ID, options: TorrentOptions) async throws {
        try await performQueuedUserOperation { engine in
            try await engine.setTorrentOptions(id: id, options: options)
        }
    }

    func moveTorrentInQueue(for id: TorrentItem.ID, move: TorrentQueueMove) async throws {
        try await performQueuedUserOperation { engine in
            try await engine.moveTorrentInQueue(id: id, move: move)
        }
    }

    func setQueuePriority(for ids: Set<TorrentItem.ID>, priority: TorrentQueuePriority) {
        let idsToUpdate = torrents
            .filter { ids.contains($0.id) }
            .map(\.id)
        guard !idsToUpdate.isEmpty else {
            return
        }

        perform { engine in
            for id in idsToUpdate {
                var options = try await engine.torrentOptions(id: id)
                guard options.queuePriority != priority else {
                    continue
                }
                options.queuePriority = priority
                try await engine.setTorrentOptions(id: id, options: options)
            }
        }
    }

    func moveTorrentsInQueue(ids: Set<TorrentItem.ID>, move: TorrentQueueMove) {
        var orderedIDs = torrents
            .filter { ids.contains($0.id) }
            .map(\.id)
        guard !orderedIDs.isEmpty else {
            return
        }

        if move == .top || move == .down {
            orderedIDs.reverse()
        }
        let idsToMove = orderedIDs

        perform { engine in
            for id in idsToMove {
                try await engine.moveTorrentInQueue(id: id, move: move)
            }
        }
    }

    func requestFiles(for id: TorrentItem.ID) async throws {
        try await performQueuedUserOperation { engine in
            try await engine.requestFiles(id: id)
        }
    }

    func setFilePriority(for id: TorrentItem.ID, fileIndex: Int32, priority: TorrentFilePriority) async throws {
        try await performQueuedUserOperation { engine in
            try await engine.setFilePriority(id: id, fileIndex: fileIndex, priority: priority)
        }
    }

    func requestPieceMap(for id: TorrentItem.ID) async throws {
        try await performQueuedUserOperation { engine in
            try await engine.requestPieceMap(id: id)
        }
    }

    func trackerBatch(for id: TorrentItem.ID, since revision: UInt64?) async -> TorrentTrackerBatch? {
        await engine.trackerBatch(id: id, since: revision)
    }

    func webSeedBatch(for id: TorrentItem.ID, since revision: UInt64?) async -> TorrentWebSeedBatch? {
        await engine.webSeedBatch(id: id, since: revision)
    }

    func webSeedActivity(for id: TorrentItem.ID) async -> TorrentWebSeedActivity {
        await engine.webSeedActivity(id: id)
    }

    func peerSources(for id: TorrentItem.ID) async -> TorrentPeerSources {
        await engine.peerSources(id: id)
    }

    func fileBatch(for id: TorrentItem.ID, since revision: UInt64?) async -> TorrentFileBatch? {
        await engine.fileBatch(id: id, since: revision)
    }

    func pieceMapBatch(for id: TorrentItem.ID, since revision: UInt64?) async -> TorrentPieceMapBatch? {
        await engine.pieceMapBatch(id: id, since: revision)
    }

    func dismissLastError() {
        setLastError(nil)
    }

    @discardableResult
    func chooseDownloadFolder(_ url: URL, reportsGlobalError: Bool = true) -> Result<Void, Error> {
        do {
            try setDownloadFolder(url)
            if reportsGlobalError {
                setLastError(nil)
            }
            return .success(())
        } catch {
            if reportsGlobalError {
                setLastError(error.localizedDescription, source: .userAction)
            }
            return .failure(error)
        }
    }

    func validateDownloadFolderSelection(_ url: URL) -> Result<Void, Error> {
        do {
            try downloadFolderAccessStore.validateSelection(url)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func isCurrentDownloadFolder(_ url: URL?) -> Bool {
        downloadFolderAccessStore.isCurrentDefault(url)
    }

    func previewTorrentFile(_ url: URL) async throws -> TorrentFilePreview {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let torrentData = try await Task.detached(priority: .userInitiated) {
            try Self.readTorrentFile(url)
        }.value
        return try await engine.previewTorrentFile(data: torrentData)
    }

    @discardableResult
    func addMagnet(
        _ magnet: String,
        savePath explicitSavePath: String? = nil,
        startsPaused: Bool = false,
        queuePriority: TorrentQueuePriority = .normal,
        labelIDs: Set<TorrentLabel.ID> = [],
        allowNonHTTPSTrackers: Bool = false,
        allowNonHTTPSWebSeeds: Bool = false,
        allowPreMetadataDHT: Bool = false
    ) -> Bool {
        guard let savePath = explicitSavePath ?? downloadFolder?.path else {
            setLastError("Choose a download folder first.", source: .userAction)
            return false
        }
        guard magnet.utf8.count <= TorrentInputLimits.maxMagnetURIBytes else {
            setLastError(TorrentStoreError.magnetTooLarge.localizedDescription, source: .userAction)
            return false
        }

        return scheduleMagnetAdd(
            magnet,
            savePath: savePath,
            prepareFolder: nil,
            startsPaused: startsPaused,
            queuePriority: queuePriority,
            labelIDs: labelIDs,
            allowNonHTTPSTrackers: allowNonHTTPSTrackers,
            allowNonHTTPSWebSeeds: allowNonHTTPSWebSeeds,
            allowPreMetadataDHT: allowPreMetadataDHT
        )
    }

    @discardableResult
    func addMagnet(
        _ magnet: String,
        downloadFolder: URL,
        setsDownloadFolderAsDefault: Bool,
        startsPaused: Bool = false,
        queuePriority: TorrentQueuePriority = .normal,
        labelIDs: Set<TorrentLabel.ID> = [],
        allowNonHTTPSTrackers: Bool = false,
        allowNonHTTPSWebSeeds: Bool = false,
        allowPreMetadataDHT: Bool = false
    ) -> Bool {
        guard magnet.utf8.count <= TorrentInputLimits.maxMagnetURIBytes else {
            setLastError(TorrentStoreError.magnetTooLarge.localizedDescription, source: .userAction)
            return false
        }

        return scheduleMagnetAdd(
            magnet,
            savePath: nil,
            prepareFolder: { store in
                try store.downloadFolderAccessStore.prepareForAdd(
                    downloadFolder,
                    setsDefault: setsDownloadFolderAsDefault,
                    activeTorrents: store.torrents
                )
            },
            startsPaused: startsPaused,
            queuePriority: queuePriority,
            labelIDs: labelIDs,
            allowNonHTTPSTrackers: allowNonHTTPSTrackers,
            allowNonHTTPSWebSeeds: allowNonHTTPSWebSeeds,
            allowPreMetadataDHT: allowPreMetadataDHT
        )
    }

    private func scheduleMagnetAdd(
        _ magnet: String,
        savePath: String?,
        prepareFolder: (@MainActor @Sendable (TorrentStore) throws -> PreparedDownloadFolder)?,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        labelIDs: Set<TorrentLabel.ID>,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool,
        allowPreMetadataDHT: Bool
    ) -> Bool {
        let enablePeerExchange = settings.effectiveUsePeerExchangeByDefault
        let sanitizedLabelIDs = sanitizeLabelIDs(labelIDs)
        let engine = engine
        let errorGeneration = lastErrorGeneration
        return scheduleUserOperation { store in
            var preparedFolder: PreparedDownloadFolder?
            do {
                preparedFolder = try prepareFolder?(store)
                guard let resolvedSavePath = preparedFolder?.path ?? savePath else {
                    throw TorrentStoreError.downloadFolderAccessDenied
                }
                let addedTorrentID = try await engine.addMagnet(
                    magnet,
                    savePath: resolvedSavePath,
                    startsPaused: startsPaused,
                    queuePriority: queuePriority,
                    enablePeerExchange: enablePeerExchange,
                    allowNonHTTPSTrackers: allowNonHTTPSTrackers,
                    allowNonHTTPSWebSeeds: allowNonHTTPSWebSeeds,
                    allowPreMetadataDHT: allowPreMetadataDHT
                )
                if let preparedFolder {
                    store.commitDownloadFolderForAdd(preparedFolder)
                }
                store.setSanitizedLabels(sanitizedLabelIDs, forTorrent: addedTorrentID)
                await store.refreshFromEngine()
                store.clearLastError(ifUnchangedSince: errorGeneration)
            } catch {
                store.downloadFolderAccessStore.prune(activeTorrents: store.torrents)
                store.setLastError(error.localizedDescription, source: .userAction)
            }
            withExtendedLifetime(preparedFolder?.lease) {}
        }
    }

    @discardableResult
    func addTorrentFile(
        _ url: URL,
        torrentData: Data,
        savePath explicitSavePath: String? = nil,
        filePriorities: [Int32: TorrentFilePriority]? = nil,
        moveOriginalToTrash: Bool = false,
        startsPaused: Bool = false,
        queuePriority: TorrentQueuePriority = .normal,
        labelIDs: Set<TorrentLabel.ID> = [],
        allowNonHTTPSTrackers: Bool = false,
        allowNonHTTPSWebSeeds: Bool = false
    ) -> Bool {
        guard let savePath = explicitSavePath ?? downloadFolder?.path else {
            setLastError("Choose a download folder first.", source: .userAction)
            return false
        }

        return scheduleTorrentFileAdd(
            url,
            torrentData: torrentData,
            savePath: savePath,
            prepareFolder: nil,
            filePriorities: filePriorities,
            moveOriginalToTrash: moveOriginalToTrash,
            startsPaused: startsPaused,
            queuePriority: queuePriority,
            labelIDs: labelIDs,
            allowNonHTTPSTrackers: allowNonHTTPSTrackers,
            allowNonHTTPSWebSeeds: allowNonHTTPSWebSeeds
        )
    }

    @discardableResult
    func addTorrentFile(
        _ url: URL,
        torrentData: Data,
        downloadFolder: URL,
        filePriorities: [Int32: TorrentFilePriority]? = nil,
        moveOriginalToTrash: Bool = false,
        setsDownloadFolderAsDefault: Bool,
        startsPaused: Bool = false,
        queuePriority: TorrentQueuePriority = .normal,
        labelIDs: Set<TorrentLabel.ID> = [],
        allowNonHTTPSTrackers: Bool = false,
        allowNonHTTPSWebSeeds: Bool = false
    ) -> Bool {
        scheduleTorrentFileAdd(
            url,
            torrentData: torrentData,
            savePath: nil,
            prepareFolder: { store in
                try store.downloadFolderAccessStore.prepareForAdd(
                    downloadFolder,
                    setsDefault: setsDownloadFolderAsDefault,
                    activeTorrents: store.torrents
                )
            },
            filePriorities: filePriorities,
            moveOriginalToTrash: moveOriginalToTrash,
            startsPaused: startsPaused,
            queuePriority: queuePriority,
            labelIDs: labelIDs,
            allowNonHTTPSTrackers: allowNonHTTPSTrackers,
            allowNonHTTPSWebSeeds: allowNonHTTPSWebSeeds
        )
    }

    private func scheduleTorrentFileAdd(
        _ url: URL,
        torrentData: Data,
        savePath: String?,
        prepareFolder: (@MainActor @Sendable (TorrentStore) throws -> PreparedDownloadFolder)?,
        filePriorities: [Int32: TorrentFilePriority]?,
        moveOriginalToTrash: Bool,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        labelIDs: Set<TorrentLabel.ID>,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool
    ) -> Bool {
        let engine = engine
        let enablePeerExchange = settings.effectiveUsePeerExchangeByDefault
        let sanitizedLabelIDs = sanitizeLabelIDs(labelIDs)
        let errorGeneration = lastErrorGeneration
        return scheduleUserOperation { store in
            var didAddTorrent = false
            var preparedFolder: PreparedDownloadFolder?
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
                withExtendedLifetime(preparedFolder?.lease) {}
            }

            do {
                preparedFolder = try prepareFolder?(store)
                guard let resolvedSavePath = preparedFolder?.path ?? savePath else {
                    throw TorrentStoreError.downloadFolderAccessDenied
                }
                let addedTorrentID = try await engine.addTorrentFile(
                    data: torrentData,
                    savePath: resolvedSavePath,
                    filePriorities: filePriorities,
                    startsPaused: startsPaused,
                    queuePriority: queuePriority,
                    enablePeerExchange: enablePeerExchange,
                    allowNonHTTPSTrackers: allowNonHTTPSTrackers,
                    allowNonHTTPSWebSeeds: allowNonHTTPSWebSeeds
                )
                didAddTorrent = true
                if let preparedFolder {
                    store.commitDownloadFolderForAdd(preparedFolder)
                }
                store.setSanitizedLabels(sanitizedLabelIDs, forTorrent: addedTorrentID)
                if moveOriginalToTrash {
                    try unsafe FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
                await store.refreshFromEngine()
                store.clearLastError(ifUnchangedSince: errorGeneration)
            } catch {
                if didAddTorrent {
                    await store.refreshFromEngine()
                }
                store.downloadFolderAccessStore.prune(activeTorrents: store.torrents)
                store.setLastError(error.localizedDescription, source: .userAction)
            }
        }
    }


    func pauseSelectedTorrents() {
        pauseTorrents(ids: selectedTorrentIDs)
    }

    func pauseAllTorrents() {
        pauseTorrents(ids: Set(torrents.map(\.id)))
    }

    func pauseTorrent(id: TorrentItem.ID) {
        pauseTorrents(ids: [id])
    }

    func pauseTorrents(ids: Set<TorrentItem.ID>) {
        let idsToPause = torrents
            .filter { ids.contains($0.id) && !$0.manuallyPaused }
            .map(\.id)
        guard !idsToPause.isEmpty else {
            return
        }

        perform { engine in
            for id in idsToPause {
                try await engine.pause(id: id)
            }
        }
    }

    func resumeSelectedTorrents() {
        resumeTorrents(ids: selectedTorrentIDs)
    }

    func resumeAllTorrents() {
        resumeTorrents(ids: Set(torrents.map(\.id)))
    }

    func resumeTorrent(id: TorrentItem.ID) {
        resumeTorrents(ids: [id])
    }

    func togglePauseTorrent(id: TorrentItem.ID) {
        guard let torrent = torrentsByID[id] else {
            return
        }

        if torrent.manuallyPaused {
            resumeTorrents(ids: [id])
        } else {
            pauseTorrents(ids: [id])
        }
    }

    func resumeTorrents(ids: Set<TorrentItem.ID>) {
        let idsToResume = torrents
            .filter { ids.contains($0.id) && $0.manuallyPaused }
            .map(\.id)
        guard !idsToResume.isEmpty else {
            return
        }

        perform { engine in
            for id in idsToResume {
                try await engine.resume(id: id)
            }
        }
    }

    func reannounceTorrents(ids: Set<TorrentItem.ID>) {
        let idsToReannounce = torrents
            .filter { ids.contains($0.id) }
            .map(\.id)
        guard !idsToReannounce.isEmpty else {
            return
        }

        perform { engine in
            for id in idsToReannounce {
                try await engine.reannounce(id: id)
            }
        }
    }

    func forceRecheckTorrents(ids: Set<TorrentItem.ID>) {
        let idsToRecheck = torrents
            .filter { ids.contains($0.id) && $0.hasMetadata }
            .map(\.id)
        guard !idsToRecheck.isEmpty else {
            return
        }

        perform { engine in
            for id in idsToRecheck {
                try await engine.forceRecheck(id: id)
            }
        }
    }

    func removeSelectedTorrents(deleteFiles: Bool) {
        removeTorrents(ids: selectedTorrentIDs, deleteFiles: deleteFiles)
    }

    func removeTorrent(id: TorrentItem.ID, deleteFiles: Bool) {
        removeTorrents(ids: [id], deleteFiles: deleteFiles)
    }

    func removeTorrents(ids: Set<TorrentItem.ID>, deleteFiles: Bool) {
        let idsToRemove = Set(torrentsByID.keys).intersection(ids)
        guard !idsToRemove.isEmpty else {
            return
        }

        let engine = engine
        let errorGeneration = lastErrorGeneration
        let torrentsToRemove = idsToRemove.compactMap { torrentsByID[$0] }
        scheduleUserOperation { store in
            var removedIDs = Set<TorrentItem.ID>()
            var removalWarnings = [String]()
            do {
                for torrent in torrentsToRemove {
                    let outcome = try await store.removeFromEngine(
                        torrent,
                        deleteFiles: deleteFiles,
                        using: engine
                    )
                    removedIDs.insert(torrent.id)
                    if case .removedWithWarning(let message) = outcome {
                        removalWarnings.append(message)
                    }
                    if !engine.isAvailable {
                        break
                    }
                }
                store.completionNotifier.forget(removedIDs)
                store.removeLabelAssignments(for: removedIDs)
                store.selectionState.ids = store.selectionState.ids.subtracting(removedIDs)
                await store.reconcileAfterRemoval(removedIDs)
                if removalWarnings.isEmpty {
                    store.clearLastError(ifUnchangedSince: errorGeneration)
                } else {
                    store.setLastError(removalWarnings.joined(separator: "\n"), source: .userAction)
                }
            } catch {
                store.completionNotifier.forget(removedIDs)
                store.removeLabelAssignments(for: removedIDs)
                store.selectionState.ids = store.selectionState.ids.subtracting(removedIDs)
                await store.reconcileAfterRemoval(removedIDs)
                removalWarnings.append(error.localizedDescription)
                store.setLastError(removalWarnings.joined(separator: "\n"), source: .userAction)
            }
        }
    }

    private func removeFromEngine(
        _ torrent: TorrentItem,
        deleteFiles: Bool,
        using engine: any TorrentEngineServicing
    ) async throws -> TorrentRemovalOutcome {
        guard deleteFiles else {
            return try await engine.remove(id: torrent.id, deleteFiles: false)
        }

        let folderAccessLease = try downloadFolderAccessStore.lease(forSavePath: torrent.savePath)
        defer {
            withExtendedLifetime(folderAccessLease) {}
        }
        return try await engine.remove(id: torrent.id, deleteFiles: true)
    }

    private func reconcileAfterRemoval(_ removedIDs: Set<TorrentItem.ID>) async {
        guard !engine.isAvailable else {
            await refreshFromEngine()
            return
        }

        lastSnapshotRevision = nil
        guard !removedIDs.isEmpty else {
            return
        }
        torrents.removeAll { removedIDs.contains($0.id) }
        updateDockTransferRates(in: [])
        updateSleepPrevention(in: [])
        downloadFolderAccessStore.prune(activeTorrents: torrents)
        pruneTrackerHosts(activeTorrentIDs: Set(torrents.map(\.id)))
    }

    func revealSelectedTorrentsInFinder() {
        revealTorrentsInFinder(ids: selectedTorrentIDs)
    }

    func revealTorrentInFinder(id: TorrentItem.ID) {
        revealTorrentsInFinder(ids: [id])
    }

    func revealTorrentFileInFinder(torrent: TorrentItem, file: TorrentFileItem) {
        guard let url = fileLocationService.revealURL(for: torrent, filePath: file.path) else {
            setLastError("The file location could not be found.", source: .userAction)
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
        setLastError(nil)
    }

    func revealTorrentsInFinder(ids: Set<TorrentItem.ID>) {
        let urls = torrents
            .filter { ids.contains($0.id) }
            .compactMap(fileLocationService.revealURL(for:))
            .reduce(into: [URL]()) { urls, url in
                if !urls.contains(where: { $0.path == url.path }) {
                    urls.append(url)
                }
            }

        guard !urls.isEmpty else {
            setLastError("The download location could not be found.", source: .userAction)
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting(urls)
        setLastError(nil)
    }

    private func setDownloadFolder(_ url: URL) throws {
        let newURL = try downloadFolderAccessStore.setDefault(url, activeTorrents: torrents)
        downloadFolder = newURL
        settingsState.downloadFolder = downloadFolder
    }

    private func commitDownloadFolderForAdd(_ preparedFolder: PreparedDownloadFolder) {
        guard let defaultURL = downloadFolderAccessStore.commitPreparedForAdd(
            preparedFolder,
            activeTorrents: torrents
        ) else {
            return
        }
        downloadFolder = defaultURL
        settingsState.downloadFolder = defaultURL
    }

    private func clearDownloadFolder() {
        downloadFolderAccessStore.clearDefault(activeTorrents: torrents)
        downloadFolder = nil
        settingsState.downloadFolder = nil
    }

    func saveAll() async {
        await drainPendingOperations()
        await engine.saveAll()
    }

    @discardableResult
    func saveAllChecked() async -> Bool {
        await drainPendingOperations()

        do {
            try await engine.saveAllChecked()
            clearLastError(from: .userAction)
            return true
        } catch {
            setLastError(error.localizedDescription, source: .userAction)
            return false
        }
    }

    func clearCompletionBadge() {
        completionNotifier.clearBadge()
    }

    func setSortOrder(_ sortOrder: TorrentSortOrder) {
        guard sortOrder != self.sortOrder else {
            return
        }

        self.sortOrder = sortOrder
        self.sortOrder.save(defaults: defaults)
        sortDirection = TorrentSortDirection.load(for: sortOrder, defaults: defaults)
        applySort()
    }

    func setSortDirection(_ sortDirection: TorrentSortDirection) {
        guard sortDirection != self.sortDirection else {
            return
        }

        self.sortDirection = sortDirection
        self.sortDirection.save(for: sortOrder, defaults: defaults)
        applySort()
    }

    func updateSettings(_ settings: TorrentSettings) {
        let clampedSettings = settings.clamped()
        guard clampedSettings != self.settings else {
            return
        }

        self.settings = clampedSettings
        settingsState.settings = clampedSettings
        clampedSettings.save(defaults: defaults)
        if !clampedSettings.completionNotificationsEnabled {
            clearCompletionBadge()
        }
        updateDockTransferRates(in: torrents)
        updateSleepPrevention(in: torrents)
        scheduleApplySettings(refreshes: true)
    }

    func restoreDefaultSettings() {
        updateSettings(TorrentSettings())
        clearDownloadFolder()
    }

    var requiredNetworkInterfaceAvailable: Bool {
        guard settings.requireNetworkInterface else {
            return true
        }

        let interfaceName = settings.libtorrentRequiredNetworkInterfaceName
        guard !interfaceName.isEmpty,
              let option = networkInterfaces.first(where: { $0.name == interfaceName }) else {
            return false
        }

        return !settings.showOnlyVPNInterfaces || option.isVPNBacked
    }

    var networkProtectionStatusText: String {
        guard settings.requireNetworkInterface else {
            return "Off"
        }

        let interfaceName = settings.libtorrentRequiredNetworkInterfaceName
        guard !interfaceName.isEmpty else {
            return "Choose an interface"
        }

        guard let option = networkInterfaces.first(where: { $0.name == interfaceName }) else {
            return settings.showOnlyVPNInterfaces ? "\(interfaceName) VPN inactive" : "\(interfaceName) unavailable"
        }
        guard !settings.showOnlyVPNInterfaces || option.isVPNBacked else {
            return "\(interfaceName) VPN inactive"
        }
        return "Active on \(option.displayName)"
    }

    func setRequireNetworkInterface(_ isRequired: Bool) {
        var settings = settings
        settings.requireNetworkInterface = isRequired
        if !isRequired {
            settings.showOnlyVPNInterfaces = false
        }
        if isRequired && settings.requiredNetworkInterfaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.requiredNetworkInterfaceName = defaultRequiredNetworkInterfaceName
        }
        updateSettings(settings)
    }

    func setRequiredNetworkInterfaceName(_ name: String) {
        var settings = settings
        settings.requiredNetworkInterfaceName = name
        updateSettings(settings)
    }

    func setShowOnlyVPNInterfaces(_ isEnabled: Bool) {
        var settings = settings
        guard settings.requireNetworkInterface || !isEnabled else {
            return
        }

        settings.showOnlyVPNInterfaces = isEnabled

        if isEnabled {
            let vpnBackedNames = Set(networkInterfaces.filter(\.isVPNBacked).map(\.name))
            if !vpnBackedNames.contains(settings.requiredNetworkInterfaceName) {
                settings.requiredNetworkInterfaceName = networkInterfaces.first(where: \.isVPNBacked)?.name ?? ""
            }
        } else if settings.requireNetworkInterface && settings.requiredNetworkInterfaceName.isEmpty {
            settings.requiredNetworkInterfaceName = defaultRequiredNetworkInterfaceName(for: settings)
        }

        updateSettings(settings)
    }

    func refresh(notifiesCompletions: Bool = true) {
        Task { @MainActor [weak self] in
            await self?.refreshFromEngine(notifiesCompletions: notifiesCompletions)
        }
    }

    func refreshNow(notifiesCompletions: Bool = true) async {
        await refreshFromEngine(notifiesCompletions: notifiesCompletions)
    }

    private func refreshFromEngine(notifiesCompletions: Bool = true) async {
        let currentBridgeHealth = await engine.bridgeHealth()
        if currentBridgeHealth != bridgeHealth {
            bridgeHealth = currentBridgeHealth
        }
        guard engine.isAvailable else {
            return
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let sortOrder = sortOrder
        let sortDirection = sortDirection
        let previousRevision = lastSnapshotRevision
        let dirtyMask = await engine.takeChanges()
        while let alertError = await engine.takeAlertError(), !alertError.isEmpty {
            setLastError(alertError, source: .userAction)
        }
        if (dirtyMask & UInt32(TTORRENT_DIRTY_TRACKER_HOSTS)) != 0 {
            pendingTrackerHostRefresh = true
        }
        let currentNetworkStatus = await engine.networkStatus()
        if currentNetworkStatus != networkStatus {
            networkStatus = currentNetworkStatus
        }
        if shouldRefreshTrackerHosts() {
            await refreshTrackerHostsFromEngine(generation: generation)
        }
        guard let snapshotBatch = await engine.snapshotsIfChanged(since: previousRevision, sortedBy: sortOrder, direction: sortDirection) else {
            return
        }
        guard engine.isAvailable else {
            return
        }
        guard generation == refreshGeneration else {
            return
        }

        let sortedSnapshots = snapshotBatch.torrents
        lastSnapshotRevision = snapshotBatch.revision
        completionNotifier.observeCompletedDownloads(
            in: sortedSnapshots,
            previousTorrents: torrents,
            settings: settings,
            isEnabled: notifiesCompletions && sortedSnapshots != torrents
        )
        guard sortedSnapshots != torrents else {
            downloadFolderAccessStore.prune(activeTorrents: sortedSnapshots)
            pruneTorrentLabels(activeTorrentIDs: Set(sortedSnapshots.map(\.id)))
            pruneTrackerHosts(activeTorrentIDs: Set(sortedSnapshots.map(\.id)))
            return
        }
        updateDockTransferRates(in: sortedSnapshots)
        updateSleepPrevention(in: sortedSnapshots)
        torrents = sortedSnapshots
        downloadFolderAccessStore.prune(activeTorrents: sortedSnapshots)
        pruneTorrentLabels(activeTorrentIDs: Set(sortedSnapshots.map(\.id)))
        pruneTrackerHosts(activeTorrentIDs: Set(sortedSnapshots.map(\.id)))

        let validTorrentIDs = Set(sortedSnapshots.map(\.id))
        let updatedSelection = selectionState.ids.intersection(validTorrentIDs)
        if updatedSelection != selectionState.ids {
            selectionState.ids = updatedSelection
        }
    }

    private func shouldRefreshTrackerHosts() -> Bool {
        lastTrackerHostRevision == nil || pendingTrackerHostRefresh
    }

    private func refreshTrackerHostsFromEngine(generation: Int) async {
        let batch = await engine.trackerHostBatch()
        guard generation == refreshGeneration else {
            return
        }
        guard batch.revision != lastTrackerHostRevision else {
            pendingTrackerHostRefresh = false
            return
        }

        var nextHostsByTorrentID = [TorrentItem.ID: Set<String>]()
        for item in batch.hosts where !item.torrentID.isEmpty && !item.host.isEmpty {
            nextHostsByTorrentID[item.torrentID, default: []].insert(item.host)
        }
        if nextHostsByTorrentID != trackerHostsByTorrentID {
            trackerHostsByTorrentID = nextHostsByTorrentID
            updateSidebarState()
        }
        lastTrackerHostRevision = batch.revision
        pendingTrackerHostRefresh = false
    }

    private func pruneTrackerHosts(activeTorrentIDs: Set<TorrentItem.ID>) {
        let pruned = trackerHostsByTorrentID.filter { activeTorrentIDs.contains($0.key) }
        if pruned != trackerHostsByTorrentID {
            trackerHostsByTorrentID = pruned
            updateSidebarState()
        }
    }

    private func updateDockTransferRates(in snapshots: [TorrentItem]) {
        guard settings.dockTransferRatesEnabled else {
            dockTileService.updateTransferRates(downloadRate: 0, uploadRate: 0)
            return
        }

        let downloadRate = snapshots.reduce(Int64(0)) { total, torrent in
            total + Int64(max(0, torrent.downloadPayloadRate))
        }
        let uploadRate = snapshots.reduce(Int64(0)) { total, torrent in
            total + Int64(max(0, torrent.uploadPayloadRate))
        }
        dockTileService.updateTransferRates(downloadRate: downloadRate, uploadRate: uploadRate)
    }

    private func updateSleepPrevention(in snapshots: [TorrentItem]) {
        let hasActiveTransfers = snapshots.contains { torrent in
            torrent.downloadPayloadRate > 0 || torrent.uploadPayloadRate > 0
        }
        sleepPreventionService.update(
            isEnabled: settings.preventSleepDuringTransfers,
            hasActiveTransfers: hasActiveTransfers
        )
    }

    private func startInitialEngineSync() {
        scheduleApplySettings(refreshes: true, notifiesCompletions: false)
    }

    private func startRefreshing() {
        let engine = engine
        wakeRefreshTask = Task { @MainActor [weak self] in
            let wakeEvents = await engine.wakeEvents()
            for await _ in wakeEvents {
                guard !Task.isCancelled else {
                    return
                }
                guard let self else {
                    return
                }
                await self.refreshFromEngine()
            }
        }

        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else {
                    return
                }
                await self?.refreshFromEngine()
            }
        }
    }

    private func startMonitoringNetworkInterfaces() {
        let networkInterfaceMonitor = networkInterfaceMonitor
        networkInterfaceTask = Task { @MainActor [weak self] in
            for await interfaces in networkInterfaceMonitor.updates() {
                guard !Task.isCancelled else {
                    return
                }
                guard let self else {
                    return
                }

                self.networkInterfaces = interfaces
                self.settingsState.networkInterfaces = interfaces
                self.scheduleApplySettings(refreshes: true)
            }
        }
    }

    private func perform(_ operation: @escaping @Sendable (any TorrentEngineServicing) async throws -> Void) {
        let engine = engine
        let errorGeneration = lastErrorGeneration
        scheduleUserOperation { store in
            do {
                try await operation(engine)
                await store.refreshFromEngine()
                store.clearLastError(ifUnchangedSince: errorGeneration)
            } catch {
                store.downloadFolderAccessStore.prune(activeTorrents: store.torrents)
                store.setLastError(error.localizedDescription, source: .userAction)
            }
        }
    }

    private func sanitizeLabelIDs(_ labelIDs: Set<TorrentLabel.ID>) -> Set<TorrentLabel.ID> {
        labelIDs.intersection(labels.map(\.id))
    }

    private func setSanitizedLabels(
        _ labelIDs: Set<TorrentLabel.ID>,
        forTorrent torrentID: TorrentItem.ID,
        saves: Bool = true
    ) {
        let sanitizedLabelIDs = sanitizeLabelIDs(labelIDs)
        if sanitizedLabelIDs.isEmpty {
            labelAssignments[torrentID] = nil
        } else {
            labelAssignments[torrentID] = sanitizedLabelIDs
        }
        if saves {
            saveLabels()
        }
    }

    private func removeLabelAssignments(for torrentIDs: Set<TorrentItem.ID>) {
        guard torrentIDs.contains(where: { labelAssignments[$0] != nil }) else {
            return
        }
        for torrentID in torrentIDs {
            labelAssignments[torrentID] = nil
        }
        saveLabels()
    }

    private func pruneTorrentLabels(activeTorrentIDs: Set<TorrentItem.ID>) {
        let staleTorrentIDs = Set(labelAssignments.keys).subtracting(activeTorrentIDs)
        guard !staleTorrentIDs.isEmpty else {
            return
        }
        removeLabelAssignments(for: staleTorrentIDs)
    }

    private func saveLabels() {
        labelStore.save(labels: labels, assignments: labelAssignments)
        updateSidebarState()
    }

    private func updateSidebarState() {
        sidebarState.update(TorrentSidebarSnapshot.make(
            torrents: torrents,
            labels: labels,
            labelAssignments: labelAssignments,
            trackerHostsByTorrentID: trackerHostsByTorrentID
        ))
    }

    private func updateCommandState() {
        let rows = torrentState.rows
        let selectedRows = rows.filter { selectionState.ids.contains($0.id) }
        commandState.update(TorrentCommandSnapshot(
            hasTorrents: !rows.isEmpty,
            sortOrder: sortOrder,
            sortDirection: sortDirection,
            selectedTorrentCount: selectedRows.count,
            hasSingleSelectedTorrent: selectedRows.count == 1,
            canPauseSelectedTorrents: selectedRows.contains { !$0.manuallyPaused },
            canResumeSelectedTorrents: selectedRows.contains(where: \.manuallyPaused),
            canPauseAnyTorrent: rows.contains { !$0.manuallyPaused },
            canResumeAnyTorrent: rows.contains(where: \.manuallyPaused),
            canForceRecheckSelectedTorrents: selectedRows.contains(where: \.hasMetadata)
        ))
    }

    private func applySort() {
        refreshGeneration &+= 1
        torrents = sortOrder.sorted(torrents, direction: sortDirection)
    }

    private func scheduleApplySettings(refreshes: Bool = false, notifiesCompletions: Bool = true) {
        guard engine.isAvailable else {
            return
        }

        let networkBinding = currentNetworkBinding
        applyImmediateNetworkBlockIfNeeded(for: networkBinding)

        if let lastIndex = pendingOperations.indices.last,
           case .applySettings(var application) = pendingOperations[lastIndex] {
            application.settings = settings
            application.networkBinding = networkBinding
            application.refreshes = application.refreshes || refreshes
            application.notifiesCompletions = application.notifiesCompletions && notifiesCompletions
            pendingOperations[lastIndex] = .applySettings(application)
        } else {
            guard pendingOperations.count < Self.maximumPendingOperationCount else {
                assertionFailure("The bounded operation queue invariant was violated")
                return
            }
            pendingOperations.append(.applySettings(TorrentStorePendingSettingsApplication(
                settings: settings,
                networkBinding: networkBinding,
                refreshes: refreshes,
                notifiesCompletions: notifiesCompletions
            )))
        }
        startOperationDrainIfNeeded()
    }

    @discardableResult
    private func scheduleUserOperation(
        _ operation: @escaping @MainActor @Sendable (TorrentStore) async -> Void
    ) -> Bool {
        let pendingUserOperationCount = pendingOperations.reduce(into: 0) { count, operation in
            if case .user = operation {
                count += 1
            }
        }
        guard pendingUserOperationCount < Self.maximumPendingUserOperationCount,
              pendingOperations.count < Self.maximumPendingOperationCount else {
            setLastError(TorrentStoreError.tooManyPendingOperations.localizedDescription, source: .userAction)
            return false
        }

        pendingOperations.append(.user(operation))
        startOperationDrainIfNeeded()
        return true
    }

    private func performQueuedUserOperation<Result: Sendable>(
        _ operation: @escaping @Sendable (any TorrentEngineServicing) async throws -> Result
    ) async throws -> Result {
        let engine = engine
        return try await withCheckedThrowingContinuation(isolation: MainActor.shared) { continuation in
            let accepted = scheduleUserOperation { _ in
                do {
                    continuation.resume(returning: try await operation(engine))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            if !accepted {
                continuation.resume(throwing: TorrentStoreError.tooManyPendingOperations)
            }
        }
    }

    private func startOperationDrainIfNeeded() {
        guard operationDrainTask == nil else {
            return
        }

        operationDrainTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let operation = self?.takeNextPendingOperation() else {
                    self?.operationDrainTask = nil
                    return
                }
                guard let store = self else {
                    return
                }
                await store.execute(operation)
            }
            self?.operationDrainTask = nil
        }
    }

    private func takeNextPendingOperation() -> TorrentStorePendingOperation? {
        guard !pendingOperations.isEmpty else {
            return nil
        }

        return pendingOperations.removeFirst()
    }

    private func execute(_ operation: TorrentStorePendingOperation) async {
        await drainImmediateNetworkBlocks()
        switch operation {
        case .applySettings(let application):
            await applySettingsToEngine(
                application.settings,
                networkBinding: application.networkBinding
            )
            if application.refreshes {
                await refreshFromEngine(notifiesCompletions: application.notifiesCompletions)
            }
        case .user(let operation):
            await operation(self)
        }
    }

    private func drainPendingOperations() async {
        while true {
            let operationTask = operationDrainTask
            let networkBlockTask = immediateNetworkBlockTask
            await networkBlockTask?.value
            await operationTask?.value
            guard operationDrainTask != nil || immediateNetworkBlockTask != nil else {
                return
            }
        }
    }

    private func drainImmediateNetworkBlocks() async {
        while let task = immediateNetworkBlockTask {
            let generation = immediateNetworkBlockGeneration
            await task.value
            if generation == immediateNetworkBlockGeneration {
                return
            }
        }
    }

    private func applySettingsToEngine(
        _ settings: TorrentSettings,
        networkBinding: AppliedNetworkBinding
    ) async {
        let previousNetworkBinding = appliedNetworkBinding
        let bindingChanged = previousNetworkBinding.map { $0 != networkBinding } ?? false
        let networkMustRemainBlocked = networkBinding.networkBlocked || networkBinding != currentNetworkBinding
        let peerExchangePluginChanged = appliedPeerExchangePluginEnabled.map {
            $0 != settings.enablePeerExchangePlugin
        } ?? false

        do {
            if networkMustRemainBlocked || bindingChanged || peerExchangePluginChanged {
                try await engine.blockNetworkNow()
            }

            if bindingChanged || peerExchangePluginChanged {
                completionNotifier.beginBaseline()
                try await engine.restart(enablePeerExchangePlugin: settings.enablePeerExchangePlugin)
                lastSnapshotRevision = nil
                lastTrackerHostRevision = nil
                pendingTrackerHostRefresh = true
            }

            try await engine.applySettings(
                settings,
                networkBlocked: networkBinding.networkBlocked || networkBinding != currentNetworkBinding
            )
            appliedNetworkBinding = networkBinding
            appliedPeerExchangePluginEnabled = settings.enablePeerExchangePlugin
            clearLastError(from: .settingsApply)
        } catch {
            setLastError(error.localizedDescription, source: .settingsApply)
        }
    }

    private func applyImmediateNetworkBlockIfNeeded(for networkBinding: AppliedNetworkBinding) {
        let bindingChanged = appliedNetworkBinding.map { $0 != networkBinding } ?? false
        guard networkBinding.networkBlocked || bindingChanged else {
            immediateNetworkBlockBinding = nil
            return
        }

        guard immediateNetworkBlockBinding != networkBinding else {
            return
        }
        immediateNetworkBlockBinding = networkBinding

        immediateNetworkBlockGeneration &+= 1
        let generation = immediateNetworkBlockGeneration
        let previousTask = immediateNetworkBlockTask
        let engine = engine
        immediateNetworkBlockTask = Task { @MainActor [weak self] in
            await previousTask?.value
            defer {
                if let self, self.immediateNetworkBlockGeneration == generation {
                    self.immediateNetworkBlockTask = nil
                }
            }
            guard !Task.isCancelled else {
                return
            }

            do {
                try await engine.blockNetworkNow()
                guard let self else {
                    return
                }
                self.lastSnapshotRevision = nil
                await self.refreshFromEngine(notifiesCompletions: false)
            } catch {
                self?.setLastError(error.localizedDescription, source: .settingsApply)
            }
        }
    }

    private func setLastError(_ message: String?, source: TorrentStoreErrorSource? = nil) {
        lastErrorGeneration &+= 1
        lastError = message
        lastErrorSource = message == nil ? nil : source
    }

    private func clearLastError(ifUnchangedSince generation: Int) {
        guard lastErrorGeneration == generation else {
            return
        }
        setLastError(nil)
    }

    private func clearLastError(from source: TorrentStoreErrorSource) {
        guard lastErrorSource == source else {
            return
        }
        setLastError(nil)
    }

    private var currentNetworkBinding: AppliedNetworkBinding {
        let interfaceName = settings.libtorrentRequiredNetworkInterfaceName
        let interface = networkInterfaces.first { $0.name == interfaceName }
        return AppliedNetworkBinding(
            interfaceName: interfaceName,
            interfaceFingerprint: interface?.fingerprint ?? "",
            vpnServiceID: interface?.vpnServiceID ?? "",
            networkBlocked: !requiredNetworkInterfaceAvailable
        )
    }

    private var defaultRequiredNetworkInterfaceName: String {
        defaultRequiredNetworkInterfaceName(for: settings)
    }

    private func defaultRequiredNetworkInterfaceName(for settings: TorrentSettings) -> String {
        if settings.showOnlyVPNInterfaces {
            return networkInterfaces.first(where: \.isVPNBacked)?.name ?? ""
        }

        return networkInterfaces.first(where: \.isVPNBacked)?.name
            ?? networkInterfaces.first { $0.isLikelyVPN }?.name
            ?? networkInterfaces.first?.name
            ?? ""
    }

    private static func makeStateDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("TorrentApp", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func engineStartupErrorMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        return message.isEmpty ? "Unknown startup error." : message
    }

    private nonisolated static func readTorrentFile(_ url: URL) throws -> Data {
        let descriptor = try openTorrentFileDescriptor(url)
        defer {
            try? descriptor.close()
        }

        let fileSize = try validatedTorrentFileSize(descriptor: descriptor)
        let handle = FileHandle(fileDescriptor: descriptor.rawValue, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: fileSize) else {
            throw TorrentStoreError.unreadableTorrentFile
        }
        guard data.count == fileSize else {
            throw TorrentStoreError.unreadableTorrentFile
        }
        return data
    }

    private nonisolated static func openTorrentFileDescriptor(_ url: URL) throws -> FileDescriptor {
        do {
            return try FileDescriptor.open(
                FilePath(url.path(percentEncoded: false)),
                .readOnly,
                options: [.closeOnExec, .noFollow]
            )
        } catch {
            throw TorrentStoreError.unreadableTorrentFile
        }
    }

    private nonisolated static func validatedTorrentFileSize(descriptor: FileDescriptor) throws -> Int {
        var metadata = stat()
        guard unsafe Darwin.fstat(descriptor.rawValue, &metadata) == 0 else {
            throw TorrentStoreError.unreadableTorrentFile
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw TorrentStoreError.unreadableTorrentFile
        }
        guard metadata.st_size > 0 else {
            throw TorrentStoreError.emptyTorrentFile
        }
        guard metadata.st_size <= off_t(TorrentInputLimits.maxTorrentFileBytes) else {
            throw TorrentStoreError.torrentFileTooLarge
        }
        return Int(metadata.st_size)
    }
}
