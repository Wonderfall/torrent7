import AppKit
import Darwin
import Foundation
import Observation
import Synchronization
import System
import TorrentEngineClient
import TorrentEngineIPC
import TorrentEngineModel

private typealias AppliedNetworkBinding = TorrentNetworkBinding

private enum TorrentStoreErrorSource {
    case settingsApply
    case userAction
}

private enum TorrentMagnetPromotionError: LocalizedError {
    case metadataNotReady
    case inconsistentFileMetadata
    case removalUncertain(String)
    case identityChanged

    var errorDescription: String? {
        switch self {
        case .metadataNotReady:
            "Magnet metadata is not ready for promotion."
        case .inconsistentFileMetadata:
            "The engine's file metadata did not match the independently parsed torrent manifest."
        case .removalUncertain(let detail):
            "Magnet promotion paused because engine removal was not cleanly acknowledged. \(detail)"
        case .identityChanged:
            "Magnet promotion did not preserve the torrent identity."
        }
    }
}

private typealias TorrentStoreUserOperation = @MainActor @Sendable (TorrentStore) async -> Void

private struct TorrentStorePendingUserOperation {
    let id: UUID?
    let perform: TorrentStoreUserOperation
}

private struct TorrentStorePendingSettingsApplication {
    var settings: TorrentSettings
    var networkBinding: AppliedNetworkBinding
    var refreshes: Bool
    var notifiesCompletions: Bool
}

private enum TorrentStorePendingOperation {
    case applySettings(TorrentStorePendingSettingsApplication)
    case user(TorrentStorePendingUserOperation)
}

@MainActor
private final class TorrentStoreQueuedOperationState<Result: Sendable> {
    private enum State {
        case idle
        case pending(CheckedContinuation<Result, any Error>)
        case running(CheckedContinuation<Result, any Error>)
        case completed
    }

    private var state = State.idle

    func install(_ continuation: CheckedContinuation<Result, any Error>) {
        switch state {
        case .idle:
            state = .pending(continuation)
        case .completed:
            continuation.resume(throwing: CancellationError())
        case .pending, .running:
            preconditionFailure("A queued operation continuation can only be installed once")
        }
    }

    func begin() -> Bool {
        switch state {
        case .pending(let continuation):
            state = .running(continuation)
            return true
        case .completed:
            return false
        case .idle, .running:
            preconditionFailure("A queued operation can only begin from the pending state")
        }
    }

    func resume(returning result: Result) {
        finish(with: .success(result))
    }

    func resume(throwing error: any Error) {
        finish(with: .failure(error))
    }

    func cancel() {
        switch state {
        case .idle:
            state = .completed
        case .pending(let continuation), .running(let continuation):
            state = .completed
            continuation.resume(throwing: CancellationError())
        case .completed:
            break
        }
    }

    private func finish(with result: Swift.Result<Result, any Error>) {
        let continuation: CheckedContinuation<Result, any Error>
        switch state {
        case .pending(let pendingContinuation), .running(let pendingContinuation):
            continuation = pendingContinuation
            state = .completed
        case .completed:
            return
        case .idle:
            preconditionFailure("A queued operation cannot finish before installing its continuation")
        }

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private enum TorrentStoreEngineStartupOutcome: Sendable {
    case started(any TorrentEngineServicing, TorrentStorageBrokerServer?)
    case failed(String)
    case cancelled
}

private enum TorrentStoreEngineStartupKind {
    case initial
    case replacesTerminatedController
}

private enum TorrentStoreBulkCommandFilter: Sendable {
    case any
    case pausible
    case resumable
    case hasMetadata
}

private struct TorrentStorePendingLabelMutation {
    let id: UUID?
    let request: TorrentLabelMutationRequest
    let state: TorrentStoreQueuedOperationState<Void>?
}

typealias TorrentStoreEngineStartupFactory = @Sendable (
    _ enablePeerExchangePlugin: Bool
) throws -> any TorrentEngineServicing

@MainActor
@Observable
final class TorrentStore {
    private static let maximumPendingUserOperationCount = 64
    private static let maximumPendingOperationCount = maximumPendingUserOperationCount * 2 + 1
    private static let maximumPendingLabelMutationCount = 64
    private static let engineRestartRefreshDrainTimeout: Duration = .seconds(5)
    static let engineStartupFactoryOverride = Mutex<TorrentStoreEngineStartupFactory?>(nil)

    let commandState = TorrentCommandState()
    let selectionState = TorrentSelectionState()
    let torrentState = TorrentListState()
    let sidebarState = TorrentSidebarState()
    let settingsState: TorrentSettingsState

    private(set) var torrents: [TorrentItem] = []
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
    private(set) var torrentFilterRevision: UInt64 = 0

    private(set) var libtorrentVersion: String

    private var engine: any TorrentEngineServicing
    private let storageBrokerRegistry = TorrentStorageBrokerRegistry()
    private let storageClaimJournal: TorrentStorageClaimJournal?
    private var storageParentAuthorities = [UUID: TorrentStorageParentAuthority]()
    @ObservationIgnored
    private var storageBrokerServer: TorrentStorageBrokerServer?
    private let dockTileService: TorrentDockTileServicing
    private let completionNotifier: TorrentCompletionNotifier
    private let sleepPreventionService: SleepPreventionServicing
    private let downloadFolderAccessStore: DownloadFolderAccessStoring
    private let fileLocationService: TorrentFileLocationServicing
    private let preferencesStore: TorrentPreferencesStore
    private let labelPersistenceStore: any TorrentLabelPersisting
    private var refreshTask: Task<Void, Never>?
    private var wakeRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var activeRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var activeRefreshID: UUID?
    @ObservationIgnored
    private var pendingRefreshNotifiesCompletions: Bool?
    @ObservationIgnored
    private var engineStartupTask: Task<Void, Never>?
    @ObservationIgnored
    private var productionBootstrapID: UUID?
    @ObservationIgnored
    private var magnetPromotionInFlightID: UUID?
    @ObservationIgnored
    private var hasStarted = false
    @ObservationIgnored
    private var operationDrainTask: Task<Void, Never>?
    @ObservationIgnored
    private var immediateNetworkBlockTask: Task<Void, Never>?
    @ObservationIgnored
    private var fileRevealTask: Task<Void, Never>?
    @ObservationIgnored
    private var fileRevealID: UUID?
    @ObservationIgnored
    private var sidebarUpdateTask: Task<Void, Never>?
    @ObservationIgnored
    private var sidebarUpdateID: UUID?
    @ObservationIgnored
    private var commandUpdateTask: Task<Void, Never>?
    @ObservationIgnored
    private var commandUpdateID: UUID?
    @ObservationIgnored
    private var sortUpdateTask: Task<Void, Never>?
    @ObservationIgnored
    private var sortUpdateID: UUID?
    @ObservationIgnored
    private var labelSaveTask: Task<Void, Never>?
    @ObservationIgnored
    private var labelSaveID: UUID?
    @ObservationIgnored
    private var labelMutationDrainTask: Task<Void, Never>?
    @ObservationIgnored
    private var settingsSaveTask: Task<Void, Never>?
    @ObservationIgnored
    private var settingsSaveID: UUID?
    @ObservationIgnored
    private var sortPreferencesSaveTask: Task<Void, Never>?
    @ObservationIgnored
    private var sortPreferencesSaveID: UUID?
    @ObservationIgnored
    private var labelPersistenceRevision: UInt64 = 0
    @ObservationIgnored
    private var settingsPersistenceRevision: UInt64 = 0
    @ObservationIgnored
    private var sortPersistenceRevision: UInt64 = 0
    @ObservationIgnored
    private var torrentPresentationRevision: UInt64 = 0
    @ObservationIgnored
    private var pendingOperations = [TorrentStorePendingOperation]()
    private var pendingLabelMutations =
        [TorrentStorePendingLabelMutation]()
    private var appliedNetworkBinding: AppliedNetworkBinding?
    private var appliedPeerExchangePluginEnabled: Bool?
    private var confirmedNetworkBlockLifecycleGeneration: UInt64?
    private var torrentsByID = [TorrentItem.ID: TorrentItem]()
    private var activeTorrentIDs = Set<TorrentItem.ID>()
    private var unresolvedStorageTorrentIDs = Set<TorrentItem.ID>()
    private var sortDirectionsByOrder = [
        TorrentSortOrder: TorrentSortDirection
    ]()
    private var lastErrorGeneration = 0
    private var lastErrorSource: TorrentStoreErrorSource?
    private var lastSnapshotRevision: UInt64?
    private var lastTrackerHostRevision: UInt64?
    private var trackerHostMutationRevision: UInt64 = 0
    private var lastNetworkInterfaceRevision: UInt64?
    private var pendingTrackerHostRefresh = false
    private var refreshGeneration = 0
    private var refreshesInFlightByLifecycle = [UInt64: Int]()
    private var engineLifecycleGeneration: UInt64 = 0
    private var engineMutationGeneration: UInt64 = 0
    private var nextTorrentInfoTabRequestToken = 0
    private var isEngineStarting = false
    private var isEngineRestarting = false
    private var engineReplacementRequested = false
    private var restoreDefaultsOperationIsPending = false
    private var engineStartupFailed = false
    private var backgroundRefreshesEnabled = false

    init() {
        let defaultsDomain = TorrentDefaultsDomain.standard
        let initialSettings = TorrentSettings().clamped()
        let initialSortOrder = TorrentSortOrder.dateAdded
        settings = initialSettings
        sortOrder = initialSortOrder
        sortDirection = initialSortOrder.defaultDirection
        sortDirectionsByOrder = Dictionary(
            uniqueKeysWithValues: TorrentSortOrder.allCases.map {
                ($0, $0.defaultDirection)
            }
        )
        let dockTileService = TorrentDockTileService()
        self.dockTileService = dockTileService
        completionNotifier = TorrentCompletionNotifier(dockTileService: dockTileService)
        sleepPreventionService = SleepPreventionService()
        downloadFolderAccessStore = DownloadFolderAccessStore(
            domain: defaultsDomain
        )
        storageClaimJournal = try? TorrentStorageClaimJournal(
            directory: Self.storageJournalDirectory()
        )
        fileLocationService = TorrentFileLocationService()
        preferencesStore = TorrentPreferencesStore(domain: defaultsDomain)
        labelPersistenceStore = TorrentLabelPersistenceStore(domain: defaultsDomain)
        settingsState = TorrentSettingsState(
            settings: initialSettings,
            downloadFolder: nil,
            networkInterfacesAreAuthoritative: false
        )

        let startingEngine = TorrentUnavailableEngine(message: "Torrent engine startup is in progress.")
        engine = startingEngine
        appliedPeerExchangePluginEnabled =
            initialSettings.enablePeerExchangePlugin
        libtorrentVersion = startingEngine.libtorrentVersion
        selectionState.didChange = { [weak self] in
            self?.updateCommandState()
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
        downloadFolderAccessStore: DownloadFolderAccessStoring,
        fileLocationService: TorrentFileLocationServicing,
        defaultsDomain: TorrentDefaultsDomain = .standard,
        storageClaimJournal: TorrentStorageClaimJournal? = nil,
        initialLabels: [TorrentLabel] = [],
        initialLabelAssignments: [
            TorrentItem.ID: Set<TorrentLabel.ID>
        ] = [:],
        networkInterfaces: [NetworkInterfaceOption] = [],
        startsTasks: Bool = false
    ) {
        precondition(
            initialLabels.count <= TorrentLabel.maximumCount,
            "Injected label state exceeds the UI capacity."
        )
        self.settings = settings
        self.sortOrder = sortOrder
        self.sortDirection = sortDirection
        self.downloadFolder = downloadFolder
        self.engine = engine
        self.dockTileService = dockTileService
        self.completionNotifier = completionNotifier
        self.sleepPreventionService = sleepPreventionService
        self.downloadFolderAccessStore = downloadFolderAccessStore
        self.storageClaimJournal = storageClaimJournal
        self.fileLocationService = fileLocationService
        preferencesStore = TorrentPreferencesStore(domain: defaultsDomain)
        labelPersistenceStore = TorrentLabelPersistenceStore(domain: defaultsDomain)
        self.networkInterfaces = networkInterfaces
        labels = initialLabels
        labelAssignments = initialLabelAssignments
        sortDirectionsByOrder = Dictionary(
            uniqueKeysWithValues: TorrentSortOrder.allCases.map {
                ($0, $0 == sortOrder ? sortDirection : $0.defaultDirection)
            }
        )
        appliedPeerExchangePluginEnabled = settings.enablePeerExchangePlugin
        settingsState = TorrentSettingsState(
            settings: settings,
            downloadFolder: downloadFolder,
            networkInterfaces: networkInterfaces
        )
        libtorrentVersion = engine.libtorrentVersion
        appliedNetworkBinding = currentNetworkBinding
        backgroundRefreshesEnabled = startsTasks
        hasStarted = startsTasks
        selectionState.didChange = { [weak self] in
            self?.updateCommandState()
        }
        scheduleSidebarUpdate()
        completionNotifier.updateConfiguration(settings)
        if startsTasks, engine.isAvailable {
            completionNotifier.configure()
            startInitialEngineSync()
        }
    }

    isolated deinit {
        engineStartupTask?.cancel()
        refreshTask?.cancel()
        wakeRefreshTask?.cancel()
        activeRefreshTask?.cancel()
        operationDrainTask?.cancel()
        immediateNetworkBlockTask?.cancel()
        fileRevealTask?.cancel()
        sidebarUpdateTask?.cancel()
        commandUpdateTask?.cancel()
        sortUpdateTask?.cancel()
        labelMutationDrainTask?.cancel()
        for mutation in pendingLabelMutations {
            mutation.state?.cancel()
        }
        labelSaveTask?.cancel()
        settingsSaveTask?.cancel()
        sortPreferencesSaveTask?.cancel()
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        isEngineStarting = true
        backgroundRefreshesEnabled = true
        completionNotifier.updateConfiguration(settings)
        completionNotifier.configure()
        startProductionBootstrap()
    }

    var selectedTorrent: TorrentItem? {
        guard selectionState.ids.count == 1, let id = selectionState.ids.first else {
            return nil
        }
        return torrentsByID[id]
    }

    var engineAvailable: Bool {
        !isEngineStarting && engine.isAvailable
    }

    var selectedTorrentIDs: Set<TorrentItem.ID> {
        selectionState.ids
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
        torrentsByID[id]
    }

    func downloadLocationPath(for id: TorrentItem.ID) -> String? {
        storageBrokerRegistry.locationsByTorrentID()[id]?.displayPath
    }

    func downloadLocationPaths(
        for ids: Set<TorrentItem.ID>
    ) -> [TorrentItem.ID: String] {
        let locations = storageBrokerRegistry.locationsByTorrentID()
        return Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            guard let path = locations[id]?.displayPath else {
                return nil
            }
            return (id, path)
        })
    }

    func selectTorrent(id: TorrentItem.ID) {
        selectionState.ids = [id]
    }

    func selectTorrents(ids: Set<TorrentItem.ID>) {
        selectionState.ids = ids
    }

    private func retainSelection(
        in activeIDs: Set<TorrentItem.ID>
    ) async throws {
        while true {
            let revision = selectionState.revision
            let ids = selectionState.ids
            let retainedIDs = try await Self.retainedSelectionIDs(
                ids,
                activeIDs: activeIDs
            )
            try Task.checkCancellation()
            guard revision == selectionState.revision else {
                continue
            }
            if retainedIDs != ids {
                selectionState.ids = retainedIDs
            }
            return
        }
    }

    private func removeFromSelection(
        _ removedIDs: Set<TorrentItem.ID>
    ) async throws {
        while true {
            let revision = selectionState.revision
            let ids = selectionState.ids
            let retainedIDs = try await Self.selectionIDs(
                ids,
                removing: removedIDs
            )
            try Task.checkCancellation()
            guard revision == selectionState.revision else {
                continue
            }
            if retainedIDs != ids {
                selectionState.ids = retainedIDs
            }
            return
        }
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
        guard labels.count < TorrentLabel.maximumCount else {
            setLastError(
                TorrentStoreError.tooManyLabels.localizedDescription,
                source: .userAction
            )
            return nil
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
        scheduleLabelMutation(.delete(labelID: id))
    }

    func setLabels(_ labelIDs: Set<TorrentLabel.ID>, forTorrent id: TorrentItem.ID) {
        scheduleLabelMutation(.set(
            labelIDs: labelIDs,
            torrentID: id,
            requiresActiveTorrent: true
        ))
    }

    func toggleLabel(_ labelID: TorrentLabel.ID, forTorrentIDs torrentIDs: Set<TorrentItem.ID>) {
        guard !torrentIDs.isEmpty else {
            return
        }
        scheduleLabelMutation(.toggle(
            labelID: labelID,
            torrentIDs: torrentIDs
        ))
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
        let requestedEngine = engine
        let lifecycleGeneration = engineLifecycleGeneration
        let policy = try await requestedEngine.sourcePolicy(id: id)
        try Task.checkCancellation()
        guard lifecycleGeneration == engineLifecycleGeneration else {
            throw CancellationError()
        }
        return policy
    }

    func setSourcePolicy(
        for id: TorrentItem.ID,
        mutation: TorrentSourcePolicyMutation
    ) async throws {
        try await performQueuedUserOperation { engine in
            try await engine.setSourcePolicy(id: id, mutation: mutation)
        }
    }

    func torrentOptions(for id: TorrentItem.ID) async throws -> TorrentOptions {
        let requestedEngine = engine
        let lifecycleGeneration = engineLifecycleGeneration
        let options = try await requestedEngine.torrentOptions(id: id)
        try Task.checkCancellation()
        guard lifecycleGeneration == engineLifecycleGeneration else {
            throw CancellationError()
        }
        return options
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
        scheduleBulkOperation(
            requestedIDs: ids,
            filter: .any
        ) { engine, idsToUpdate in
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
        scheduleBulkOperation(
            requestedIDs: ids,
            filter: .any,
            reversesOrder: move == .top || move == .down
        ) { engine, idsToMove in
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
        try await performQueuedStoreOperation { store in
            try await store.setBrokeredFilePriority(
                torrentID: id,
                fileIndex: fileIndex,
                priority: priority
            )
        }
    }

    private func setBrokeredFilePriority(
        torrentID: TorrentItem.ID,
        fileIndex: Int32,
        priority: TorrentFilePriority
    ) async throws {
        guard let storageClaimJournal else {
            try await engine.setFilePriority(
                id: torrentID,
                fileIndex: fileIndex,
                priority: priority
            )
            return
        }
        let claims = await storageClaimJournal.allClaims().filter {
            $0.torrentID == torrentID && $0.lease.state == .active
        }
        guard claims.count <= 1 else {
            throw TorrentStorageJournalError.corrupt
        }
        guard let claim = claims.first,
              let currentPolicy = claim.lease.filePolicies.first(where: {
                  $0.fileIndex == fileIndex
              }) else {
            try await engine.setFilePriority(
                id: torrentID,
                fileIndex: fileIndex,
                priority: priority
            )
            return
        }
        guard fileIndex >= 0,
              Int(fileIndex) < claim.manifest.logicalFiles.count,
              !claim.manifest.logicalFiles[Int(fileIndex)].isPadding else {
            throw TorrentStorageBrokerRegistryError.fileUnavailable
        }

        let enablesPayload = currentPolicy.maximumAccess == .unavailable
            && priority != .skip
        let restrictsPayload = currentPolicy.maximumAccess != .unavailable
            && priority == .skip
        if enablesPayload {
            let updated = try await replacePayloadPolicy(
                claim: claim,
                fileIndex: fileIndex,
                maximumAccess: currentPolicy.provenance == .appCreated
                    ? .appOwnedWritable
                    : (currentPolicy.mayModify
                        ? .explicitlyImportedWritable
                        : .verificationReadOnly)
            )
            do {
                try await engine.setFilePriority(
                    id: torrentID,
                    fileIndex: fileIndex,
                    priority: priority
                )
            } catch {
                _ = try? await replacePayloadPolicy(
                    claim: updated,
                    fileIndex: fileIndex,
                    maximumAccess: .unavailable
                )
                throw error
            }
            return
        }

        try await engine.setFilePriority(
            id: torrentID,
            fileIndex: fileIndex,
            priority: priority
        )
        if restrictsPayload {
            _ = try await replacePayloadPolicy(
                claim: claim,
                fileIndex: fileIndex,
                maximumAccess: .unavailable
            )
        }
    }

    private func replacePayloadPolicy(
        claim: TorrentStorageClaim,
        fileIndex: Int32,
        maximumAccess: TorrentPayloadMaximumAccess
    ) async throws -> TorrentStorageClaim {
        guard let storageClaimJournal else {
            throw TorrentStorageJournalError.unavailable
        }
        let policies = claim.lease.filePolicies.map { policy in
            guard policy.fileIndex == fileIndex else {
                return policy
            }
            return TorrentPayloadFilePolicy(
                fileIndex: policy.fileIndex,
                maximumAccess: maximumAccess,
                provenance: policy.provenance,
                mayModify: policy.mayModify,
                mayDeleteAutomatically: policy.mayDeleteAutomatically
            )
        }
        let updated = try await storageClaimJournal.replacePolicy(
            claimID: claim.manifest.claimID,
            generation: claim.manifest.generation,
            operationNonce: UUID(),
            policies: policies
        )
        try storageBrokerRegistry.replaceLease(
            claimID: claim.manifest.claimID,
            generation: claim.manifest.generation,
            expectedPolicyRevision: claim.lease.policyRevision,
            with: updated.lease
        )
        return updated
    }

    func requestPieceMap(for id: TorrentItem.ID) async throws {
        try await performQueuedUserOperation { engine in
            try await engine.requestPieceMap(id: id)
        }
    }

    func trackerBatch(for id: TorrentItem.ID, since revision: UInt64?) async -> TorrentTrackerBatch? {
        let requestedEngine = engine
        let lifecycleGeneration = engineLifecycleGeneration
        let batch = await requestedEngine.trackerBatch(
            id: id,
            since: revision
        )
        guard !Task.isCancelled,
              lifecycleGeneration == engineLifecycleGeneration else {
            return nil
        }
        return batch
    }

    func webSeedBatch(for id: TorrentItem.ID, since revision: UInt64?) async -> TorrentWebSeedBatch? {
        let requestedEngine = engine
        let lifecycleGeneration = engineLifecycleGeneration
        let batch = await requestedEngine.webSeedBatch(
            id: id,
            since: revision
        )
        guard !Task.isCancelled,
              lifecycleGeneration == engineLifecycleGeneration else {
            return nil
        }
        return batch
    }

    func webSeedActivity(for id: TorrentItem.ID) async -> TorrentWebSeedActivity? {
        let requestedEngine = engine
        let lifecycleGeneration = engineLifecycleGeneration
        let activity = await requestedEngine.webSeedActivity(id: id)
        guard !Task.isCancelled,
              lifecycleGeneration == engineLifecycleGeneration else {
            return nil
        }
        return activity
    }

    func peerSources(for id: TorrentItem.ID) async -> TorrentPeerSources? {
        let requestedEngine = engine
        let lifecycleGeneration = engineLifecycleGeneration
        let sources = await requestedEngine.peerSources(id: id)
        guard !Task.isCancelled,
              lifecycleGeneration == engineLifecycleGeneration else {
            return nil
        }
        return sources
    }

    func fileBatch(for id: TorrentItem.ID, since revision: UInt64?) async -> TorrentFileBatch? {
        let requestedEngine = engine
        let lifecycleGeneration = engineLifecycleGeneration
        let batch = await requestedEngine.fileBatch(
            id: id,
            since: revision
        )
        guard !Task.isCancelled,
              lifecycleGeneration == engineLifecycleGeneration else {
            return nil
        }
        return batch
    }

    func pieceMapBatch(for id: TorrentItem.ID, since revision: UInt64?) async -> TorrentPieceMapBatch? {
        let requestedEngine = engine
        let lifecycleGeneration = engineLifecycleGeneration
        let batch = await requestedEngine.pieceMapBatch(
            id: id,
            since: revision
        )
        guard !Task.isCancelled,
              lifecycleGeneration == engineLifecycleGeneration else {
            return nil
        }
        return batch
    }

    func dismissLastError() {
        setLastError(nil)
    }

    @discardableResult
    func chooseDownloadFolder(
        _ url: URL,
        reportsGlobalError: Bool = true
    ) async -> Result<Void, Error> {
        do {
            try await performQueuedStoreOperation { store in
                try await store.setDownloadFolder(url)
            }
            if reportsGlobalError {
                setLastError(nil)
            }
            return .success(())
        } catch let error as CancellationError {
            return .failure(error)
        } catch {
            if reportsGlobalError {
                setLastError(error.localizedDescription, source: .userAction)
            }
            return .failure(error)
        }
    }

    func validateDownloadFolderSelection(
        _ url: URL
    ) async -> Result<Void, Error> {
        do {
            try await downloadFolderAccessStore.validateSelection(url)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func isCurrentDownloadFolder(_ url: URL?) -> Bool {
        guard let url, let downloadFolder else {
            return false
        }
        return url.torrentFilePath == downloadFolder.torrentFilePath
    }

    func previewTorrentFile(_ url: URL) async throws -> TorrentFilePreview {
        try Task.checkCancellation()
        let torrentData = try await Self.readTorrentFile(url)
        try Task.checkCancellation()
        let previewEngine = engine
        let lifecycleGeneration = engineLifecycleGeneration
        let preview = try await previewEngine.previewTorrentFile(
            data: torrentData
        )
        try Task.checkCancellation()
        guard lifecycleGeneration == engineLifecycleGeneration else {
            throw CancellationError()
        }
        return preview
    }

    @discardableResult
    func addMagnet(
        _ magnet: String,
        savePath explicitSavePath: String? = nil,
        startsPaused: Bool = false,
        queuePriority: TorrentQueuePriority = .normal,
        labelIDs: Set<TorrentLabel.ID> = [],
        httpsTrackerPolicy: TorrentHTTPSTrackerPolicyOverride = .inherit,
        httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicyOverride = .inherit,
        allowPreMetadataDHT: Bool = false
    ) -> Bool {
        _ = explicitSavePath
        guard Self.isMagnetWithinSizeLimit(magnet) else {
            setLastError(TorrentStoreError.magnetTooLarge.localizedDescription, source: .userAction)
            return false
        }

        return scheduleMagnetAdd(
            magnet,
            prepareFolder: nil,
            startsPaused: startsPaused,
            queuePriority: queuePriority,
            labelIDs: labelIDs,
            httpsTrackerPolicy: httpsTrackerPolicy,
            httpsWebSeedPolicy: httpsWebSeedPolicy,
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
        httpsTrackerPolicy: TorrentHTTPSTrackerPolicyOverride = .inherit,
        httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicyOverride = .inherit,
        allowPreMetadataDHT: Bool = false
    ) -> Bool {
        guard Self.isMagnetWithinSizeLimit(magnet) else {
            setLastError(TorrentStoreError.magnetTooLarge.localizedDescription, source: .userAction)
            return false
        }

        return scheduleMagnetAdd(
            magnet,
            prepareFolder: { store in
                try await store.downloadFolderAccessStore.prepareForAdd(
                    downloadFolder,
                    setsDefault: setsDownloadFolderAsDefault,
                    activeTorrents: store.torrents
                )
            },
            startsPaused: startsPaused,
            queuePriority: queuePriority,
            labelIDs: labelIDs,
            httpsTrackerPolicy: httpsTrackerPolicy,
            httpsWebSeedPolicy: httpsWebSeedPolicy,
            allowPreMetadataDHT: allowPreMetadataDHT
        )
    }

    private func scheduleMagnetAdd(
        _ magnet: String,
        prepareFolder: (@MainActor @Sendable (TorrentStore) async throws -> PreparedDownloadFolder)?,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        labelIDs: Set<TorrentLabel.ID>,
        httpsTrackerPolicy: TorrentHTTPSTrackerPolicyOverride,
        httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicyOverride,
        allowPreMetadataDHT: Bool
    ) -> Bool {
        let enablePeerExchange = settings.effectiveUsePeerExchangeByDefault
        let errorGeneration = lastErrorGeneration
        return scheduleUserOperation { store in
            var preparedFolder: PreparedDownloadFolder?
            defer {
                withExtendedLifetime(preparedFolder?.lease) {}
            }
            do {
                preparedFolder = try await prepareFolder?(store)
                if preparedFolder != nil, store.storageClaimJournal == nil {
                    throw TorrentStorageJournalError.unavailable
                }
                let descriptor = try preparedFolder.map { _ in
                    try TorrentMagnetDescriptor.parse(magnet)
                }
                let addedTorrentID = try await store.engine.addMagnet(
                    magnet,
                    startsPaused: startsPaused,
                    queuePriority: queuePriority,
                    enablePeerExchange: enablePeerExchange,
                    httpsTrackerPolicy: httpsTrackerPolicy,
                    httpsWebSeedPolicy: httpsWebSeedPolicy,
                    allowPreMetadataDHT: allowPreMetadataDHT
                )
                if let preparedFolder, let descriptor {
                    guard let storageClaimJournal = store.storageClaimJournal else {
                        throw TorrentStorageJournalError.unavailable
                    }
                    try await storageClaimJournal.beginPromotion(
                        TorrentMagnetPromotion(
                            id: UUID(),
                            torrentID: addedTorrentID,
                            originalMagnet: magnet,
                            advertisedInfoHashes: descriptor.infoHashes,
                            destinationPath: preparedFolder.path,
                            operationNonce: UUID(),
                            state: .awaitingMetadata,
                            exactInfoDictionary: nil,
                            activation: nil
                        )
                    )
                    await store.commitDownloadFolderForAdd(preparedFolder)
                }
                try await store.performLabelMutation(.set(
                    labelIDs: labelIDs,
                    torrentID: addedTorrentID,
                    requiresActiveTorrent: false
                ))
                await store.refreshFromEngine()
                store.clearLastError(ifUnchangedSince: errorGeneration)
            } catch {
                store.setLastError(error.localizedDescription, source: .userAction)
            }
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
        httpsTrackerPolicy: TorrentHTTPSTrackerPolicyOverride = .inherit,
        httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicyOverride = .inherit,
        usesExistingData: Bool = false
    ) -> Bool {
        guard let savePath = explicitSavePath ?? downloadFolder?.torrentFilePath else {
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
            httpsTrackerPolicy: httpsTrackerPolicy,
            httpsWebSeedPolicy: httpsWebSeedPolicy,
            usesExistingData: usesExistingData
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
        httpsTrackerPolicy: TorrentHTTPSTrackerPolicyOverride = .inherit,
        httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicyOverride = .inherit,
        usesExistingData: Bool = false
    ) -> Bool {
        scheduleTorrentFileAdd(
            url,
            torrentData: torrentData,
            savePath: nil,
            prepareFolder: { store in
                try await store.downloadFolderAccessStore.prepareForAdd(
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
            httpsTrackerPolicy: httpsTrackerPolicy,
            httpsWebSeedPolicy: httpsWebSeedPolicy,
            usesExistingData: usesExistingData
        )
    }

    private func scheduleTorrentFileAdd(
        _ url: URL,
        torrentData: Data,
        savePath: String?,
        prepareFolder: (@MainActor @Sendable (TorrentStore) async throws -> PreparedDownloadFolder)?,
        filePriorities: [Int32: TorrentFilePriority]?,
        moveOriginalToTrash: Bool,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        labelIDs: Set<TorrentLabel.ID>,
        httpsTrackerPolicy: TorrentHTTPSTrackerPolicyOverride,
        httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicyOverride,
        usesExistingData: Bool
    ) -> Bool {
        let enablePeerExchange = settings.effectiveUsePeerExchangeByDefault
        let errorGeneration = lastErrorGeneration
        return scheduleUserOperation { store in
            var preparedFolder: PreparedDownloadFolder?
            defer {
                withExtendedLifetime(preparedFolder?.lease) {}
            }

            do {
                preparedFolder = try await prepareFolder?(store)
                let folderLease: DownloadFolderAccessLease
                if let preparedFolder {
                    folderLease = preparedFolder.lease
                } else if let savePath {
                    folderLease = try await store.downloadFolderAccessStore.lease(
                        forSavePath: savePath
                    )
                } else {
                    throw TorrentStoreError.downloadFolderAccessDenied
                }
                let addedTorrentID = try await store.activateKnownTorrent(
                    data: torrentData,
                    folderLease: folderLease,
                    filePriorities: filePriorities,
                    startsPaused: startsPaused,
                    queuePriority: queuePriority,
                    enablePeerExchange: enablePeerExchange,
                    httpsTrackerPolicy: httpsTrackerPolicy,
                    httpsWebSeedPolicy: httpsWebSeedPolicy,
                    usesExistingData: usesExistingData
                )
                if let preparedFolder {
                    await store.commitDownloadFolderForAdd(preparedFolder)
                }
                try await store.performLabelMutation(.set(
                    labelIDs: labelIDs,
                    torrentID: addedTorrentID,
                    requiresActiveTorrent: false
                ))
                if moveOriginalToTrash {
                    try await Self.moveToTrash(url)
                }
                await store.refreshFromEngine()
                store.clearLastError(ifUnchangedSince: errorGeneration)
            } catch {
                store.setLastError(error.localizedDescription, source: .userAction)
            }
        }
    }

    private func activateKnownTorrent(
        data: Data,
        folderLease: DownloadFolderAccessLease,
        filePriorities: [Int32: TorrentFilePriority]?,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        enablePeerExchange: Bool,
        httpsTrackerPolicy: TorrentHTTPSTrackerPolicyOverride,
        httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicyOverride,
        claimID: UUID = UUID(),
        operationNonce: UUID = UUID(),
        preservingTorrentID: String? = nil,
        usesExistingData: Bool = false
    ) async throws -> String {
        guard let storageClaimJournal else {
            throw TorrentStorageJournalError.unavailable
        }

        let parsed = try await Self.parseStorageManifest(data)
        let parent = try await Self.makeStorageParentAuthority(folderLease)
        let generation: UInt64 = 1
        let ownershipKey = TorrentStorageDestinationPlanner.randomOwnershipKey()
        let preparation = TorrentStoragePreparation(
            claimID: claimID,
            generation: generation,
            parentAuthorityID: parent.id,
            preferredTopLevelName: parsed.manifest.name,
            ownershipKey: ownershipKey,
            operationNonce: operationNonce,
            reservedTopLevelName: nil
        )
        let selectedTopLevelName: String
        let inspectedImport: TorrentStorageReservation?
        if usesExistingData {
            selectedTopLevelName = parsed.manifest.name
            inspectedImport = try await Self.importExistingStorage(
                manifest: parsed.manifest,
                parent: parent,
                claimID: claimID,
                generation: generation,
                ownershipKey: ownershipKey,
                selectedTopLevelName: selectedTopLevelName
            )
        } else {
            selectedTopLevelName = try await Self.planStorageTopLevelName(
                manifest: parsed.manifest,
                parent: parent
            )
            inspectedImport = nil
        }

        try await storageClaimJournal.beginPreparation(preparation)
        try await storageClaimJournal.noteReservation(
            claimID: claimID,
            generation: generation,
            operationNonce: operationNonce,
            topLevelName: selectedTopLevelName
        )
        let reservation: TorrentStorageReservation
        if let inspectedImport {
            reservation = inspectedImport
        } else {
            reservation = try await Self.reserveStorage(
                manifest: parsed.manifest,
                parent: parent,
                claimID: claimID,
                generation: generation,
                ownershipKey: ownershipKey,
                selectedTopLevelName: selectedTopLevelName
            )
        }

        let requestedPolicies = reservation.initialLease.filePolicies.map { policy in
            guard filePriorities?[policy.fileIndex] == .skip else {
                return policy
            }
            return TorrentPayloadFilePolicy(
                fileIndex: policy.fileIndex,
                maximumAccess: .unavailable,
                provenance: policy.provenance,
                mayModify: policy.mayModify,
                mayDeleteAutomatically: policy.mayDeleteAutomatically
            )
        }
        var claim = TorrentStorageClaim(
            manifest: reservation.storageManifest,
            lease: TorrentStorageLease(
                state: .reserved,
                policyRevision: reservation.initialLease.policyRevision,
                filePolicies: requestedPolicies
            ),
            torrentID: nil,
            operationNonce: operationNonce
        )
        try await storageClaimJournal.commitReserved(claim)
        claim = try await storageClaimJournal.transition(
            claimID: claimID,
            generation: generation,
            operationNonce: operationNonce,
            from: [.reserved],
            to: .activating
        )

        try storageBrokerRegistry.install(parentAuthority: parent)
        try storageBrokerRegistry.install(claim: claim)
        storageParentAuthorities[parent.id] = parent

        let activation = try TorrentStorageActivation(
            claimID: claimID,
            generation: generation,
            sourceManifestDigest: parsed.manifest.sourceManifestDigest,
            preservedTorrentID: preservingTorrentID
        )
        let torrentID: String
        do {
            torrentID = try await engine.addTorrentFile(
                data: data,
                activation: activation,
                filePriorities: filePriorities,
                startsPaused: startsPaused,
                queuePriority: queuePriority,
                enablePeerExchange: enablePeerExchange,
                httpsTrackerPolicy: httpsTrackerPolicy,
                httpsWebSeedPolicy: httpsWebSeedPolicy
            )
        } catch {
            let failureState: TorrentStorageClaimState =
                Self.storageActivationOutcomeIsUnknown(error)
                    ? .activationUnknown
                    : .orphaned
            let unresolved = try? await storageClaimJournal.transition(
                claimID: claimID,
                generation: generation,
                operationNonce: operationNonce,
                from: [.activating],
                to: failureState
            )
            if let unresolved {
                try? storageBrokerRegistry.install(claim: unresolved)
            }
            throw error
        }

        let active = try await storageClaimJournal.transition(
            claimID: claimID,
            generation: generation,
            operationNonce: operationNonce,
            from: [.activating],
            to: .active,
            torrentID: torrentID
        )
        try storageBrokerRegistry.install(claim: active)
        return torrentID
    }

    @concurrent
    private static func parseStorageManifest(
        _ data: Data,
        advertisedHashes: TorrentAdvertisedInfoHashes? = nil
    ) async throws
        -> ParsedTorrentManifest {
        try TorrentManifestParser().parse(
            data,
            advertisedHashes: advertisedHashes
        )
    }

    nonisolated private static func storageActivationOutcomeIsUnknown(
        _ error: any Error
    ) -> Bool {
        guard let clientError = error as? TorrentEngineClientError else {
            return true
        }
        switch clientError {
        case .serviceRejected, .serviceTemporarilyUnavailable,
             .requestQueueFull, .requestExpiredBeforeSubmission:
            return false
        case .requestTimedOut(let outcomeUnknown):
            return outcomeUnknown
        case .connectionFailed, .connectionCancelled, .invalidReply,
             .engineRestarted, .operationOutcomeUnknown,
             .recoveryDeadlineExceeded:
            return true
        }
    }

    @concurrent
    private static func makeStorageParentAuthority(
        _ lease: DownloadFolderAccessLease,
        id: UUID = UUID()
    ) async throws -> TorrentStorageParentAuthority {
        try TorrentStorageParentAuthority(id: id, lease: lease)
    }

    @concurrent
    private static func reserveStorage(
        manifest: TorrentLogicalManifest,
        parent: TorrentStorageParentAuthority,
        claimID: UUID,
        generation: UInt64,
        ownershipKey: Data,
        selectedTopLevelName: String
    ) async throws -> TorrentStorageReservation {
        try TorrentStorageDestinationPlanner().reserve(
            manifest: manifest,
            in: parent,
            claimID: claimID,
            generation: generation,
            ownershipKey: ownershipKey,
            selectedTopLevelName: selectedTopLevelName
        )
    }

    @concurrent
    private static func importExistingStorage(
        manifest: TorrentLogicalManifest,
        parent: TorrentStorageParentAuthority,
        claimID: UUID,
        generation: UInt64,
        ownershipKey: Data,
        selectedTopLevelName: String
    ) async throws -> TorrentStorageReservation {
        try TorrentStorageDestinationPlanner().importExisting(
            manifest: manifest,
            in: parent,
            claimID: claimID,
            generation: generation,
            ownershipKey: ownershipKey,
            selectedTopLevelName: selectedTopLevelName
        )
    }

    @concurrent
    private static func planStorageTopLevelName(
        manifest: TorrentLogicalManifest,
        parent: TorrentStorageParentAuthority
    ) async throws -> String {
        try TorrentStorageDestinationPlanner().planTopLevelName(
            for: manifest,
            in: parent
        )
    }


    func pauseSelectedTorrents() {
        pauseTorrents(ids: selectedTorrentIDs)
    }

    func pauseAllTorrents() {
        scheduleBulkOperation(
            requestedIDs: nil,
            filter: .pausible,
            operation: Self.pause
        )
    }

    func pauseTorrent(id: TorrentItem.ID) {
        pauseTorrents(ids: [id])
    }

    func pauseTorrents(ids: Set<TorrentItem.ID>) {
        scheduleBulkOperation(
            requestedIDs: ids,
            filter: .pausible,
            operation: Self.pause
        )
    }

    func resumeSelectedTorrents() {
        resumeTorrents(ids: selectedTorrentIDs)
    }

    func resumeAllTorrents() {
        scheduleBulkOperation(
            requestedIDs: nil,
            filter: .resumable,
            excludesUnresolvedStorageActivations: true,
            operation: Self.resume
        )
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
        scheduleBulkOperation(
            requestedIDs: ids,
            filter: .resumable,
            excludesUnresolvedStorageActivations: true,
            operation: Self.resume
        )
    }

    func reannounceTorrents(ids: Set<TorrentItem.ID>) {
        scheduleBulkOperation(
            requestedIDs: ids,
            filter: .any
        ) { engine, idsToReannounce in
            for id in idsToReannounce {
                try await engine.reannounce(id: id)
            }
        }
    }

    func forceRecheckTorrents(ids: Set<TorrentItem.ID>) {
        scheduleBulkOperation(
            requestedIDs: ids,
            filter: .hasMetadata
        ) { engine, idsToRecheck in
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
        guard !ids.isEmpty else {
            return
        }

        let errorGeneration = lastErrorGeneration
        scheduleUserOperation { store in
            var removedIDs = Set<TorrentItem.ID>()
            var removalWarnings = [String]()
            do {
                let torrentsToRemove = try await Self.selectedTorrents(
                    ids: ids,
                    torrents: store.torrents
                )
                guard !torrentsToRemove.isEmpty else {
                    return
                }
                for torrent in torrentsToRemove {
                    let outcome = try await store.removeFromEngine(
                        torrent,
                        deleteFiles: deleteFiles,
                        using: store.engine
                    )
                    removedIDs.insert(torrent.id)
                    if case .removedWithWarning(let message) = outcome {
                        removalWarnings.append(message)
                    }
                    if !store.engine.isAvailable {
                        break
                    }
                }
                try await store.performLabelMutation(
                    .removeAssignments(torrentIDs: removedIDs)
                )
                try await store.removeFromSelection(removedIDs)
                await store.finalizeRemovalPresentation(removedIDs)
                if removalWarnings.isEmpty {
                    store.clearLastError(ifUnchangedSince: errorGeneration)
                } else {
                    store.setLastError(removalWarnings.joined(separator: "\n"), source: .userAction)
                }
            } catch {
                try? await store.performLabelMutation(
                    .removeAssignments(torrentIDs: removedIDs)
                )
                try? await store.removeFromSelection(removedIDs)
                await store.finalizeRemovalPresentation(removedIDs)
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
        guard let storageClaimJournal else {
            let outcome = try await engine.remove(id: torrent.id)
            guard deleteFiles else {
                return outcome
            }
            return .removedWithWarning(
                "The torrent was removed, but its payload was preserved because no authenticated storage claim was available."
            )
        }
        let matchingClaims = await storageClaimJournal.allClaims().filter {
            $0.torrentID == torrent.id && $0.lease.state != .deleted
        }
        guard matchingClaims.count == 1, let storedClaim = matchingClaims.first else {
            let outcome = try await engine.remove(id: torrent.id)
            guard deleteFiles else {
                return outcome
            }
            return .removedWithWarning(
                "The torrent was removed, but its payload was preserved because storage ownership was missing or ambiguous."
            )
        }

        let nonce = UUID()
        var claim = try await storageClaimJournal.transition(
            claimID: storedClaim.manifest.claimID,
            generation: storedClaim.manifest.generation,
            operationNonce: nonce,
            from: [.active, .activationUnknown],
            to: .removing
        )
        try storageBrokerRegistry.install(claim: claim)

        let outcome: TorrentRemovalOutcome
        do {
            outcome = try await engine.remove(id: torrent.id)
        } catch {
            if let orphaned = try? await storageClaimJournal.transition(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation,
                operationNonce: nonce,
                from: [.removing],
                to: .orphaned
            ) {
                try? storageBrokerRegistry.install(claim: orphaned)
            }
            throw error
        }

        guard case .removed = outcome else {
            claim = try await storageClaimJournal.transition(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation,
                operationNonce: nonce,
                from: [.removing],
                to: deleteFiles ? .deletionPending : .orphaned
            )
            try storageBrokerRegistry.install(claim: claim)
            return outcome
        }
        guard deleteFiles else {
            claim = try await storageClaimJournal.transition(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation,
                operationNonce: nonce,
                from: [.removing],
                to: .orphaned
            )
            try storageBrokerRegistry.install(claim: claim)
            return .removed
        }

        let hasAutomaticallyDeletablePayload = claim.lease.filePolicies.contains {
            $0.provenance == .appCreated && $0.mayDeleteAutomatically
        }
        guard hasAutomaticallyDeletablePayload else {
            claim = try await storageClaimJournal.transition(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation,
                operationNonce: nonce,
                from: [.removing],
                to: .deleting
            )
            claim = try await storageClaimJournal.transition(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation,
                operationNonce: nonce,
                from: [.deleting],
                to: .deleted
            )
            try storageBrokerRegistry.removeClaim(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation
            )
            return .removedWithWarning(
                "The torrent was removed, but imported payload data was preserved."
            )
        }

        claim = try await storageClaimJournal.transition(
            claimID: claim.manifest.claimID,
            generation: claim.manifest.generation,
            operationNonce: nonce,
            from: [.removing],
            to: .deleting
        )
        try storageBrokerRegistry.install(claim: claim)
        do {
            guard let parent = storageParentAuthorities[claim.manifest.parentAuthorityID] else {
                throw TorrentStoragePlanningError.deletionNotProvable
            }
            try await Self.deleteStorageClaim(claim, from: parent)
            claim = try await storageClaimJournal.transition(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation,
                operationNonce: nonce,
                from: [.deleting],
                to: .deleted
            )
            try storageBrokerRegistry.removeClaim(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation
            )
            return .removed
        } catch {
            if let pending = try? await storageClaimJournal.transition(
                claimID: claim.manifest.claimID,
                generation: claim.manifest.generation,
                operationNonce: nonce,
                from: [.deleting],
                to: .deletionPending
            ) {
                try? storageBrokerRegistry.install(claim: pending)
            }
            return .removedWithWarning(error.localizedDescription)
        }
    }

    @concurrent
    private static func deleteStorageClaim(
        _ claim: TorrentStorageClaim,
        from parent: TorrentStorageParentAuthority
    ) async throws {
        try TorrentStorageDestinationPlanner().deleteOwnedPayload(
            claim: claim,
            from: parent
        )
    }

    private func finalizeRemovalPresentation(
        _ removedIDs: Set<TorrentItem.ID>
    ) async {
        // A refresh captured before removal may still carry a completed
        // snapshot. Keep completion ownership until that refresh and its
        // coalesced post-removal refresh have drained, then permit a future
        // torrent lifetime with the same ID to notify again.
        await reconcileAfterRemoval(removedIDs)
        await completionNotifier.forget(removedIDs)
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
        let lifecycleGeneration = engineLifecycleGeneration
        let presentationRevision = torrentPresentationRevision
        let currentTorrents = torrents
        let currentRows = torrentState.rows
        let presentation: TorrentListPresentation
        do {
            presentation = try await TorrentListPresentation.prepareRemoving(
                removedIDs,
                from: currentTorrents,
                previousRows: currentRows
            )
        } catch {
            return
        }
        guard !Task.isCancelled,
              lifecycleGeneration == engineLifecycleGeneration,
              presentationRevision == torrentPresentationRevision,
              !engine.isAvailable else {
            return
        }
        applyTorrentPresentation(presentation)
        updateDockTransferRates()
        updateSleepPrevention()
        let appliedPresentationRevision = torrentPresentationRevision
        await pruneDownloadFolderAccess(activeTorrents: torrents)
        guard !Task.isCancelled,
              appliedPresentationRevision == torrentPresentationRevision else {
            return
        }
        try? await pruneTrackerHosts(activeTorrentIDs: presentation.activeIDs)
    }

    func revealSelectedTorrentsInFinder() {
        revealTorrentsInFinder(ids: selectedTorrentIDs)
    }

    func revealTorrentInFinder(id: TorrentItem.ID) {
        revealTorrentsInFinder(ids: [id])
    }

    func revealTorrentFileInFinder(torrent: TorrentItem, file: TorrentFileItem) {
        let location = storageBrokerRegistry
            .locationsByTorrentID()[torrent.id]
        let fileIndex = file.index
        scheduleFileReveal(
            missingLocationMessage: "The file location could not be found."
        ) { service in
            guard let location,
                  let url = try await service.revealURL(
                      for: location,
                      fileIndex: fileIndex
                  ) else {
                return []
            }
            return [url]
        }
    }

    func revealTorrentsInFinder(ids: Set<TorrentItem.ID>) {
        let activeIDs = Set(torrents.map(\.id))
        let locationsByID = storageBrokerRegistry.locationsByTorrentID()
        let locations = ids.intersection(activeIDs).sorted().compactMap {
            locationsByID[$0]
        }
        scheduleFileReveal(
            missingLocationMessage: "The download location could not be found."
        ) { service in
            try await service.revealURLs(for: locations)
        }
    }

    private func scheduleFileReveal(
        missingLocationMessage: String,
        resolve: @escaping @Sendable (
            any TorrentFileLocationServicing
        ) async throws -> [URL]
    ) {
        fileRevealTask?.cancel()
        let revealID = UUID()
        let fileLocationService = fileLocationService
        let errorGeneration = lastErrorGeneration
        fileRevealID = revealID
        fileRevealTask = Task { @MainActor [weak self, fileLocationService] in
            do {
                let urls = try await resolve(fileLocationService)
                try Task.checkCancellation()
                guard let self, self.fileRevealID == revealID else {
                    return
                }
                self.fileRevealTask = nil
                self.fileRevealID = nil
                guard !urls.isEmpty else {
                    if self.lastErrorGeneration == errorGeneration {
                        self.setLastError(missingLocationMessage, source: .userAction)
                    }
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
                self.clearLastError(ifUnchangedSince: errorGeneration)
            } catch is CancellationError {
                guard let self, self.fileRevealID == revealID else {
                    return
                }
                self.fileRevealTask = nil
                self.fileRevealID = nil
            } catch {
                guard let self, self.fileRevealID == revealID else {
                    return
                }
                self.fileRevealTask = nil
                self.fileRevealID = nil
                if self.lastErrorGeneration == errorGeneration {
                    self.setLastError(missingLocationMessage, source: .userAction)
                }
            }
        }
    }

    private func setDownloadFolder(_ url: URL) async throws {
        let update = try await downloadFolderAccessStore.setDefault(
            url,
            activeTorrents: torrents
        )
        downloadFolder = update.url
        settingsState.downloadFolder = downloadFolder
        _ = update.didChange
    }

    private func commitDownloadFolderForAdd(
        _ preparedFolder: PreparedDownloadFolder
    ) async {
        guard let defaultURL = await downloadFolderAccessStore.commitPreparedForAdd(
            preparedFolder,
            activeTorrents: torrents
        ) else {
            return
        }
        downloadFolder = defaultURL
        settingsState.downloadFolder = defaultURL
    }

    private func clearDownloadFolder() async throws {
        await downloadFolderAccessStore.clearDefault(activeTorrents: torrents)
        downloadFolder = nil
        settingsState.downloadFolder = nil
    }

    func saveAll() async {
        let startupTask = engineStartupTask
        await startupTask?.value
        await drainPendingOperations()
        await drainPendingPersistenceWork()
        try? await engine.saveAll()
    }

    @discardableResult
    func saveAllChecked() async -> Bool {
        if let startupTask = engineStartupTask {
            // Application termination must not wait through the bounded XPC
            // cleanup reconnect horizon. No live replacement engine has been
            // installed while startup is pending, so there is no new engine
            // state to save.
            startupTask.cancel()
            await startupTask.value
            await drainPendingPersistenceWork()
            return true
        }
        await drainPendingOperations()
        await drainPendingPersistenceWork()

        if engineStartupFailed {
            return true
        }

        do {
            try await engine.saveAll()
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
        sortDirection = sortDirectionsByOrder[sortOrder]
            ?? sortOrder.defaultDirection
        scheduleSortPreferencesSave()
        applySort()
    }

    func setSortDirection(_ sortDirection: TorrentSortDirection) {
        guard sortDirection != self.sortDirection else {
            return
        }

        self.sortDirection = sortDirection
        sortDirectionsByOrder[sortOrder] = sortDirection
        scheduleSortPreferencesSave()
        applySort()
    }

    func updateSettings(_ settings: TorrentSettings) {
        let clampedSettings = settings.clamped()
        guard clampedSettings != self.settings else {
            return
        }

        self.settings = clampedSettings
        settingsState.settings = clampedSettings
        scheduleSettingsSave()
        completionNotifier.updateConfiguration(clampedSettings)
        updateDockTransferRates()
        updateSleepPrevention()
        scheduleApplySettings(refreshes: true)
    }

    func restoreDefaultSettings() {
        guard !restoreDefaultsOperationIsPending else {
            return
        }
        restoreDefaultsOperationIsPending = true
        schedulePendingRestoreDefaultsIfPossible()
    }

    @discardableResult
    private func schedulePendingRestoreDefaultsIfPossible() -> Bool {
        guard restoreDefaultsOperationIsPending, !isEngineStarting else {
            return false
        }
        let accepted = scheduleUserOperation { store in
            defer {
                store.restoreDefaultsOperationIsPending = false
            }
            do {
                try store.requireRestoreDefaultsQueueCapacity()
                store.updateSettings(TorrentSettings())
                try await store.clearDownloadFolder()
            } catch {
                store.setLastError(error.localizedDescription, source: .userAction)
            }
        }
        if !accepted {
            restoreDefaultsOperationIsPending = false
        }
        return accepted
    }

    var requiredNetworkInterfaceAvailable: Bool {
        guard settings.requireNetworkInterface else {
            return true
        }
        guard settingsState.networkInterfacesAreAuthoritative else {
            return false
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
        guard settingsState.networkInterfacesAreAuthoritative else {
            return "Refreshing interfaces…"
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
        scheduleRefresh(notifiesCompletions: notifiesCompletions)
    }

    func refreshNow(notifiesCompletions: Bool = true) async {
        await refreshFromEngine(notifiesCompletions: notifiesCompletions)
    }

    private func refreshFromEngine(notifiesCompletions: Bool = true) async {
        guard let task = scheduleRefresh(notifiesCompletions: notifiesCompletions) else {
            return
        }
        await task.value
    }

    @discardableResult
    private func scheduleRefresh(
        notifiesCompletions: Bool
    ) -> Task<Void, Never>? {
        guard !isEngineStarting, !isEngineRestarting else {
            return nil
        }
        if let activeRefreshTask {
            pendingRefreshNotifiesCompletions =
                (pendingRefreshNotifiesCompletions ?? false) || notifiesCompletions
            return activeRefreshTask
        }

        let refreshID = UUID()
        activeRefreshID = refreshID
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            var currentNotifiesCompletions = notifiesCompletions
            while !Task.isCancelled {
                await self.performRefreshFromEngine(
                    notifiesCompletions: currentNotifiesCompletions
                )
                guard !Task.isCancelled,
                      self.activeRefreshID == refreshID,
                      let pendingNotifiesCompletions =
                          self.pendingRefreshNotifiesCompletions else {
                    break
                }
                self.pendingRefreshNotifiesCompletions = nil
                currentNotifiesCompletions = pendingNotifiesCompletions
            }
            guard self.activeRefreshID == refreshID else {
                return
            }
            self.activeRefreshTask = nil
            self.activeRefreshID = nil
            self.pendingRefreshNotifiesCompletions = nil
        }
        activeRefreshTask = task
        return task
    }

    private func performRefreshFromEngine(notifiesCompletions: Bool) async {
        guard !isEngineStarting, !isEngineRestarting, !Task.isCancelled else {
            return
        }
        let lifecycleGeneration = engineLifecycleGeneration
        let overlapsAnotherRefresh = beginRefresh(for: lifecycleGeneration)
        defer { endRefresh(for: lifecycleGeneration) }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let mutationGeneration = engineMutationGeneration
        let polledEngine = engine
        let sortOrder = sortOrder
        let sortDirection = sortDirection
        let previousRevision = lastSnapshotRevision
        let poll: TorrentEnginePollResult
        do {
            poll = try await polledEngine.poll(
                since: previousRevision,
                sortedBy: sortOrder,
                direction: sortDirection,
                includeTrackerHosts: shouldRefreshTrackerHosts() || overlapsAnotherRefresh
            )
        } catch {
            guard generation == refreshGeneration,
                  lifecycleGeneration == engineLifecycleGeneration,
                  mutationGeneration == engineMutationGeneration else {
                return
            }
            if polledEngine.isAvailable {
                setLastError(error.localizedDescription, source: .userAction)
            } else {
                handleUnavailableEngine(polledEngine, lifecycleGeneration: lifecycleGeneration)
            }
            return
        }

        guard generation == refreshGeneration,
              lifecycleGeneration == engineLifecycleGeneration,
              mutationGeneration == engineMutationGeneration else {
            return
        }
        guard polledEngine.isAvailable else {
            handleUnavailableEngine(polledEngine, lifecycleGeneration: lifecycleGeneration)
            return
        }
        if poll.bridgeHealth != bridgeHealth {
            bridgeHealth = poll.bridgeHealth
        }
        for alertError in poll.alertErrors where !alertError.isEmpty {
            setLastError(alertError, source: .userAction)
        }
        if let networkInterfaceSnapshot = poll.networkInterfaceSnapshot {
            applyNetworkInterfaceSnapshot(networkInterfaceSnapshot)
        }
        if TorrentEngineDirtySet(rawValue: poll.dirtyMask).contains(.trackerHosts) {
            pendingTrackerHostRefresh = true
        }
        if poll.networkStatus != networkStatus {
            networkStatus = poll.networkStatus
        }
        updateConfirmedNetworkContainment(from: poll.networkStatus)
        if let trackerHostBatch = poll.trackerHostBatch {
            await applyTrackerHostBatch(
                trackerHostBatch,
                generation: generation,
                lifecycleGeneration: lifecycleGeneration,
                mutationGeneration: mutationGeneration
            )
            guard generation == refreshGeneration,
                  lifecycleGeneration == engineLifecycleGeneration,
                  mutationGeneration == engineMutationGeneration else {
                return
            }
        }
        guard let snapshotBatch = poll.snapshotBatch else {
            await scheduleReadyMagnetPromotion(in: torrents)
            return
        }
        let sortedSnapshots = snapshotBatch.torrents
        let previousTorrents = torrents
        let presentationRevision = torrentPresentationRevision
        let presentation: TorrentListPresentation
        do {
            presentation = try await TorrentListPresentation.prepare(
                torrents: sortedSnapshots,
                previousTorrents: previousTorrents,
                previousRows: torrentState.rows
            )
        } catch is CancellationError {
            return
        } catch {
            setLastError(error.localizedDescription, source: .userAction)
            return
        }
        guard generation == refreshGeneration,
              lifecycleGeneration == engineLifecycleGeneration,
              mutationGeneration == engineMutationGeneration,
              presentationRevision == torrentPresentationRevision else {
            return
        }

        // Release stale GUI-held security scopes before publishing the new
        // presentation. The engine never receives these folder authorities.
        do {
            try await pruneDownloadFolderAccesses(
                activeTorrents: sortedSnapshots,
                generation: generation,
                lifecycleGeneration: lifecycleGeneration,
                mutationGeneration: mutationGeneration,
                presentationRevision: presentationRevision
            )
        } catch is CancellationError {
            return
        } catch {
            setLastError(error.localizedDescription, source: .userAction)
            return
        }
        guard generation == refreshGeneration,
              lifecycleGeneration == engineLifecycleGeneration,
              mutationGeneration == engineMutationGeneration,
              presentationRevision == torrentPresentationRevision else {
            return
        }

        if presentation.torrentsChanged {
            applyTorrentPresentation(presentation)
            updateDockTransferRates()
            updateSleepPrevention()
            do {
                try await retainSelection(in: presentation.activeIDs)
            } catch {
                return
            }
        }
        let appliedPresentationRevision = torrentPresentationRevision
        do {
            try await pruneTorrentLabels(activeTorrentIDs: presentation.activeIDs)
        } catch {
            return
        }
        guard generation == refreshGeneration,
              lifecycleGeneration == engineLifecycleGeneration,
              mutationGeneration == engineMutationGeneration,
              appliedPresentationRevision == torrentPresentationRevision,
              !Task.isCancelled else {
            return
        }

        await completionNotifier.observeCompletedDownloads(
            in: presentation.completionProjection,
            previousTorrentsWereEmpty: previousTorrents.isEmpty,
            isEnabled: notifiesCompletions && presentation.torrentsChanged
        )
        guard generation == refreshGeneration,
              lifecycleGeneration == engineLifecycleGeneration,
              mutationGeneration == engineMutationGeneration,
              appliedPresentationRevision == torrentPresentationRevision,
              !Task.isCancelled else {
            return
        }
        do {
            try await pruneTrackerHosts(activeTorrentIDs: presentation.activeIDs)
        } catch {
            return
        }
        guard generation == refreshGeneration,
              lifecycleGeneration == engineLifecycleGeneration,
              mutationGeneration == engineMutationGeneration,
              appliedPresentationRevision == torrentPresentationRevision,
              !Task.isCancelled else {
            return
        }
        lastSnapshotRevision = snapshotBatch.revision
        await scheduleReadyMagnetPromotion(in: sortedSnapshots)
    }

    private func scheduleReadyMagnetPromotion(
        in snapshots: [TorrentItem]
    ) async {
        guard magnetPromotionInFlightID == nil,
              let storageClaimJournal else {
            return
        }
        let promotions = await storageClaimJournal.allPromotions()
        guard !promotions.isEmpty else {
            return
        }
        let snapshotsByID = Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.id, $0) }
        )
        let claimsByID = Dictionary(
            uniqueKeysWithValues: await storageClaimJournal.allClaims().map {
                ($0.manifest.claimID, $0)
            }
        )

        let candidate = promotions.first { promotion in
            switch promotion.state {
            case .awaitingMetadata:
                return snapshotsByID[promotion.torrentID]?.hasMetadata == true
            case .metadataReady:
                return snapshotsByID[promotion.torrentID] != nil
            case .promoting, .outcomeUnknown:
                guard let activation = promotion.activation,
                      let claim = claimsByID[activation.claimID] else {
                    return false
                }
                return claim.lease.state == .active
                    && claim.torrentID == promotion.torrentID
                    && snapshotsByID[promotion.torrentID] != nil
            }
        }
        guard let candidate else {
            return
        }

        magnetPromotionInFlightID = candidate.id
        let accepted = scheduleUserOperation(id: candidate.id) { store in
            defer {
                store.magnetPromotionInFlightID = nil
            }
            do {
                switch candidate.state {
                case .awaitingMetadata, .metadataReady:
                    guard let item = store.torrentsByID[candidate.torrentID] else {
                        throw TorrentMagnetPromotionError.metadataNotReady
                    }
                    try await store.promoteMagnet(candidate, item: item)
                case .promoting, .outcomeUnknown:
                    try await store.finishPromotedMagnet(candidate)
                }
                await store.refreshFromEngine(notifiesCompletions: false)
            } catch TorrentMagnetPromotionError.metadataNotReady {
                return
            } catch {
                store.setLastError(error.localizedDescription, source: .userAction)
            }
        }
        if !accepted {
            magnetPromotionInFlightID = nil
        }
    }

    private func promoteMagnet(
        _ initialPromotion: TorrentMagnetPromotion,
        item: TorrentItem
    ) async throws {
        guard let storageClaimJournal else {
            throw TorrentStorageJournalError.unavailable
        }
        let descriptor = try TorrentMagnetDescriptor.parse(
            initialPromotion.originalMagnet
        )
        guard descriptor.infoHashes == initialPromotion.advertisedInfoHashes else {
            throw TorrentStorageJournalError.corrupt
        }

        var promotion = initialPromotion
        let exactInfo: Data
        if let persisted = promotion.exactInfoDictionary {
            exactInfo = persisted
        } else {
            guard let received = try await engine.torrentMetadata(id: item.id) else {
                throw TorrentMagnetPromotionError.metadataNotReady
            }
            let torrentData = try descriptor.torrentFile(
                exactInfoDictionary: received
            )
            _ = try await Self.parseStorageManifest(
                torrentData,
                advertisedHashes: descriptor.advertisedInfoHashes
            )
            promotion = try await storageClaimJournal.recordPromotionMetadata(
                id: promotion.id,
                operationNonce: promotion.operationNonce,
                exactInfoDictionary: received
            )
            exactInfo = received
        }

        let torrentData = try descriptor.torrentFile(
            exactInfoDictionary: exactInfo
        )
        let parsed = try await Self.parseStorageManifest(
            torrentData,
            advertisedHashes: descriptor.advertisedInfoHashes
        )
        let folderLease = try await downloadFolderAccessStore.lease(
            forSavePath: promotion.destinationPath
        )

        let options = try await engine.torrentOptions(id: item.id)
        let sourcePolicy = try await engine.sourcePolicy(id: item.id)
        try await engine.requestFiles(id: item.id)
        guard let fileBatch = await engine.fileBatch(id: item.id, since: nil) else {
            throw TorrentMagnetPromotionError.metadataNotReady
        }
        let filePriorities = try Self.validatedPromotionFilePriorities(
            fileBatch.files,
            manifest: parsed.manifest
        )
        let activation = TorrentMagnetPromotionActivation(
            claimID: UUID(),
            claimOperationNonce: UUID(),
            runtime: TorrentMagnetPromotionRuntimeState(
                wasPaused: item.paused,
                queuePosition: item.queuePosition,
                options: options,
                sourcePolicy: sourcePolicy,
                filePriorities: filePriorities
            )
        )
        promotion = try await storageClaimJournal.beginPromotionActivation(
            id: promotion.id,
            operationNonce: promotion.operationNonce,
            activation: activation
        )

        do {
            let removal = try await engine.remove(id: item.id)
            guard case .removed = removal else {
                let detail: String
                if case .removedWithWarning(let warning) = removal {
                    detail = warning
                } else {
                    detail = "The removal outcome was not recognized."
                }
                throw TorrentMagnetPromotionError.removalUncertain(detail)
            }

            let promotedID = try await activateKnownTorrent(
                data: torrentData,
                folderLease: folderLease,
                filePriorities: activation.runtime.filePriorities,
                startsPaused: activation.runtime.wasPaused,
                queuePriority: activation.runtime.options.queuePriority,
                enablePeerExchange:
                    activation.runtime.sourcePolicy.isPeerExchangeEnabled,
                httpsTrackerPolicy:
                    activation.runtime.sourcePolicy.httpsTrackerPolicy,
                httpsWebSeedPolicy:
                    activation.runtime.sourcePolicy.httpsWebSeedPolicy,
                claimID: activation.claimID,
                operationNonce: activation.claimOperationNonce,
                preservingTorrentID: promotion.torrentID
            )
            guard promotedID == promotion.torrentID else {
                throw TorrentMagnetPromotionError.identityChanged
            }
            try await restorePromotedRuntime(
                activation.runtime,
                torrentID: promotedID
            )
            try await storageClaimJournal.completePromotion(
                id: promotion.id,
                operationNonce: promotion.operationNonce
            )
        } catch {
            _ = try? await storageClaimJournal.markPromotionOutcomeUnknown(
                id: promotion.id,
                operationNonce: promotion.operationNonce
            )
            throw error
        }
        withExtendedLifetime(folderLease) {}
    }

    private func finishPromotedMagnet(
        _ promotion: TorrentMagnetPromotion
    ) async throws {
        guard let storageClaimJournal,
              let activation = promotion.activation else {
            throw TorrentStorageJournalError.corrupt
        }
        let claim = await storageClaimJournal.claim(id: activation.claimID)
        guard claim?.lease.state == .active,
              claim?.torrentID == promotion.torrentID else {
            throw TorrentStorageJournalError.invalidTransition
        }
        try await restorePromotedRuntime(
            activation.runtime,
            torrentID: promotion.torrentID
        )
        try await storageClaimJournal.completePromotion(
            id: promotion.id,
            operationNonce: promotion.operationNonce
        )
    }

    private func restorePromotedRuntime(
        _ runtime: TorrentMagnetPromotionRuntimeState,
        torrentID: TorrentItem.ID
    ) async throws {
        try await engine.setTorrentOptions(
            id: torrentID,
            options: runtime.options
        )
        var current = try await engine.sourcePolicy(id: torrentID)
        let booleanPolicies: [(TorrentSourcePolicyField, Bool, Bool)] = [
            (.dht, runtime.sourcePolicy.isDHTEnabled, current.isDHTLocked),
            (
                .peerExchange,
                runtime.sourcePolicy.isPeerExchangeEnabled,
                current.isPeerExchangeLocked
            ),
            (
                .localServiceDiscovery,
                runtime.sourcePolicy.isLocalServiceDiscoveryEnabled,
                current.isLocalServiceDiscoveryLocked
            ),
            (
                .preMetadataDHT,
                runtime.sourcePolicy.allowsPreMetadataDHT,
                false
            ),
        ]
        for (field, desired, locked) in booleanPolicies {
            guard current[field] != desired else {
                continue
            }
            guard !locked else {
                throw TorrentStorageJournalError.invalidTransition
            }
            try await engine.setSourcePolicy(
                id: torrentID,
                mutation: .boolean(field: field, enabled: desired)
            )
            current[field] = desired
        }
        if current.httpsTrackerPolicy != runtime.sourcePolicy.httpsTrackerPolicy {
            try await engine.setSourcePolicy(
                id: torrentID,
                mutation: .httpsTracker(runtime.sourcePolicy.httpsTrackerPolicy)
            )
        }
        if current.httpsWebSeedPolicy != runtime.sourcePolicy.httpsWebSeedPolicy {
            try await engine.setSourcePolicy(
                id: torrentID,
                mutation: .httpsWebSeed(runtime.sourcePolicy.httpsWebSeedPolicy)
            )
        }
        if runtime.wasPaused {
            try await engine.pause(id: torrentID)
        } else {
            try await engine.resume(id: torrentID)
        }
    }

    nonisolated private static func validatedPromotionFilePriorities(
        _ files: [TorrentFileItem],
        manifest: TorrentLogicalManifest
    ) throws -> [Int32: TorrentFilePriority] {
        guard files.count == manifest.files.count else {
            throw TorrentMagnetPromotionError.inconsistentFileMetadata
        }
        var priorities = [Int32: TorrentFilePriority]()
        priorities.reserveCapacity(files.count)
        for (logical, engineFile) in zip(manifest.files, files) {
            guard logical.index == engineFile.index,
                  logical.expectedSize == engineFile.size,
                  logical.isPadding == engineFile.isPadFile else {
                throw TorrentMagnetPromotionError.inconsistentFileMetadata
            }
            if !logical.isPadding {
                priorities[logical.index] = engineFile.priority
            }
        }
        return priorities
    }

    private func shouldRefreshTrackerHosts() -> Bool {
        lastTrackerHostRevision == nil || pendingTrackerHostRefresh
    }

    private func applyNetworkInterfaceSnapshot(
        _ snapshot: TorrentNetworkInterfaceSnapshot
    ) {
        if let lastNetworkInterfaceRevision {
            guard snapshot.revision > lastNetworkInterfaceRevision else {
                return
            }
        }
        lastNetworkInterfaceRevision = snapshot.revision
        settingsState.networkInterfacesAreAuthoritative = true
        if snapshot.interfaces != networkInterfaces {
            networkInterfaces = snapshot.interfaces
            settingsState.networkInterfaces = snapshot.interfaces
        }

        // The service revokes the current lease before publishing every new
        // revision, even when the displayable interface list is unchanged.
        scheduleApplySettings(refreshes: true, notifiesCompletions: false)
    }

    private func applyTrackerHostBatch(
        _ batch: TorrentTrackerHostBatch,
        generation: Int,
        lifecycleGeneration: UInt64,
        mutationGeneration: UInt64
    ) async {
        guard generation == refreshGeneration else {
            return
        }
        guard batch.revision != lastTrackerHostRevision else {
            pendingTrackerHostRefresh = false
            return
        }

        let trackerMutationRevision = trackerHostMutationRevision
        let nextHostsByTorrentID: [TorrentItem.ID: Set<String>]?
        do {
            nextHostsByTorrentID = try await Self.makeTrackerHostIndex(
                batch.hosts,
                previous: trackerHostsByTorrentID
            )
        } catch {
            return
        }
        guard generation == refreshGeneration,
              lifecycleGeneration == engineLifecycleGeneration,
              mutationGeneration == engineMutationGeneration,
              trackerMutationRevision == trackerHostMutationRevision else {
            return
        }
        if let nextHostsByTorrentID {
            trackerHostsByTorrentID = nextHostsByTorrentID
            trackerHostMutationRevision &+= 1
            scheduleSidebarUpdate()
        }
        lastTrackerHostRevision = batch.revision
        pendingTrackerHostRefresh = false
    }

    private func pruneTrackerHosts(
        activeTorrentIDs: Set<TorrentItem.ID>
    ) async throws {
        let mutationRevision = trackerHostMutationRevision
        let presentationRevision = torrentPresentationRevision
        let currentHosts = trackerHostsByTorrentID
        let pruned = try await Self.prunedTrackerHostIndex(
            currentHosts,
            activeTorrentIDs: activeTorrentIDs
        )
        try Task.checkCancellation()
        guard mutationRevision == trackerHostMutationRevision,
              presentationRevision == torrentPresentationRevision else {
            throw CancellationError()
        }
        if let pruned {
            trackerHostsByTorrentID = pruned
            trackerHostMutationRevision &+= 1
            scheduleSidebarUpdate()
        }
    }

    private func updateDockTransferRates() {
        guard settings.dockTransferRatesEnabled else {
            dockTileService.updateTransferRates(downloadRate: 0, uploadRate: 0)
            return
        }

        dockTileService.updateTransferRates(
            downloadRate: torrentState.dockDownloadRate,
            uploadRate: torrentState.dockUploadRate
        )
    }

    private func updateSleepPrevention() {
        sleepPreventionService.update(
            isEnabled: settings.preventSleepDuringTransfers,
            hasActiveTransfers: torrentState.hasActiveTransfers
        )
    }

    private func startProductionBootstrap() {
        let bootstrapID = UUID()
        let settingsRevision = settingsPersistenceRevision
        let sortRevision = sortPersistenceRevision
        let labelRevision = labelPersistenceRevision
        let accessStore = downloadFolderAccessStore
        let preferencesStore = preferencesStore
        let labelPersistenceStore = labelPersistenceStore
        productionBootstrapID = bootstrapID
        engineStartupTask = Task { @MainActor [
            weak self,
            accessStore,
            preferencesStore,
            labelPersistenceStore
        ] in
            async let loadedPreferences = preferencesStore.load()
            async let loadedLabels = labelPersistenceStore.load()
            async let folderResult = accessStore.bootstrap()

            let preferences: TorrentPreferencesSnapshot
            let labelSnapshot: TorrentLabelSnapshot
            let folder: DownloadFolderBootstrapResult
            do {
                (preferences, labelSnapshot, folder) = try await (
                    loadedPreferences,
                    loadedLabels,
                    folderResult
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.productionBootstrapID == bootstrapID else {
                    return
                }
                self.productionBootstrapID = nil
                self.engineStartupTask = nil
                self.setLastError(
                    "Saved application state could not be loaded: \(error.localizedDescription)",
                    source: .userAction
                )
                self.startProductionEngine(
                    enablePeerExchangePlugin:
                        self.settings.enablePeerExchangePlugin
                )
                return
            }

            guard let self,
                  !Task.isCancelled,
                  self.productionBootstrapID == bootstrapID else {
                return
            }
            if self.settingsPersistenceRevision == settingsRevision {
                let loadedSettings = preferences.settings.clamped()
                self.settings = loadedSettings
                self.settingsState.settings = loadedSettings
            }
            if self.sortPersistenceRevision == sortRevision {
                self.sortOrder = preferences.sortOrder
                self.sortDirectionsByOrder = preferences.sortDirections
                self.sortDirection = preferences.selectedSortDirection
            }
            if self.labelPersistenceRevision == labelRevision {
                self.labels = labelSnapshot.labels
                self.labelAssignments = labelSnapshot.assignments
                self.torrentFilterRevision &+= 1
                self.scheduleSidebarUpdate()
            }
            self.downloadFolder = folder.defaultURL
            self.settingsState.downloadFolder = folder.defaultURL
            if let storageWarning = await self.restoreStorageClaims() {
                self.setLastError(storageWarning, source: .userAction)
            }
            self.completionNotifier.updateConfiguration(self.settings)
            self.appliedPeerExchangePluginEnabled =
                self.settings.enablePeerExchangePlugin
            if folder.discardedInvalidDefault {
                self.setLastError(
                    "The saved download folder could not be restored. Choose a download folder again.",
                    source: .userAction
                )
            }

            // The bootstrap task has finished owning startup. Clear its handle
            // before the engine task captures and waits for any predecessor.
            self.productionBootstrapID = nil
            self.engineStartupTask = nil
            self.startProductionEngine(
                enablePeerExchangePlugin:
                    self.settings.enablePeerExchangePlugin
            )
        }
    }

    func startProductionEngine(enablePeerExchangePlugin: Bool) {
        startProductionEngine(
            enablePeerExchangePlugin: enablePeerExchangePlugin,
            kind: .initial
        )
    }

    private func restoreStorageClaims() async -> String? {
        guard let storageClaimJournal else {
            return "The storage claim journal is unavailable. Existing payloads were preserved, but brokered torrents cannot be restored."
        }
        let accessSnapshot = await downloadFolderAccessStore.makeAccessSnapshot()
        let claims = await storageClaimJournal.allClaims()
        var unresolvedCount = 0

        for originalClaim in claims {
            var claim = originalClaim
            switch claim.lease.state {
            case .activating:
                if let unresolved = try? await storageClaimJournal.transition(
                    claimID: claim.manifest.claimID,
                    generation: claim.manifest.generation,
                    operationNonce: claim.operationNonce,
                    from: [.activating],
                    to: .activationUnknown
                ) {
                    claim = unresolved
                }
                unresolvedCount += 1
            case .activationUnknown:
                unresolvedCount += 1
            case .removing, .deleting:
                _ = try? await storageClaimJournal.transition(
                    claimID: claim.manifest.claimID,
                    generation: claim.manifest.generation,
                    operationNonce: claim.operationNonce,
                    from: [claim.lease.state],
                    to: .deletionPending
                )
                unresolvedCount += 1
                continue
            case .active:
                break
            case .preparing, .reserved, .deletionPending,
                 .deleted, .orphaned:
                if claim.lease.state != .deleted {
                    unresolvedCount += 1
                }
                continue
            }

            var restoredParent: TorrentStorageParentAuthority?
            for lease in accessSnapshot.leases {
                guard let candidate = try? await Self.makeStorageParentAuthority(
                    lease,
                    id: claim.manifest.parentAuthorityID
                ),
                (try? TorrentStorageDestinationPlanner().validateClaimRoot(
                    claim,
                    in: candidate
                )) != nil else {
                    continue
                }
                do {
                    try storageBrokerRegistry.install(parentAuthority: candidate)
                    try storageBrokerRegistry.install(claim: claim)
                    let indices = claim.manifest.logicalFiles.map(\.index)
                    for start in stride(
                        from: 0,
                        to: indices.count,
                        by: TorrentStorageBrokerProtocol.maximumStatBatchCount
                    ) {
                        let end = min(
                            indices.count,
                            start + TorrentStorageBrokerProtocol.maximumStatBatchCount
                        )
                        _ = try storageBrokerRegistry.statBatch(
                            claimID: claim.manifest.claimID,
                            generation: claim.manifest.generation,
                            fileIndices: Array(indices[start..<end])
                        )
                    }
                    guard restoredParent == nil else {
                        throw TorrentStoragePlanningError.invalidParentAuthority
                    }
                    restoredParent = candidate
                } catch {
                    try? storageBrokerRegistry.removeClaim(
                        claimID: claim.manifest.claimID,
                        generation: claim.manifest.generation
                    )
                }
            }
            guard let restoredParent else {
                _ = try? await storageClaimJournal.transition(
                    claimID: claim.manifest.claimID,
                    generation: claim.manifest.generation,
                    operationNonce: claim.operationNonce,
                    from: [.activating, .active, .activationUnknown],
                    to: .orphaned
                )
                unresolvedCount += 1
                continue
            }
            try? storageBrokerRegistry.install(parentAuthority: restoredParent)
            try? storageBrokerRegistry.install(claim: claim)
            storageParentAuthorities[restoredParent.id] = restoredParent
        }

        let preparationCount = await storageClaimJournal.unresolvedPreparations().count
        unresolvedCount += preparationCount
        guard unresolvedCount > 0 else {
            return nil
        }
        return "\(unresolvedCount) storage operation(s) require review. Their payloads were preserved and no authority was guessed."
    }

    /// Recovered `activationUnknown` claims retain their exact broker
    /// authority so libtorrent can identify the corresponding resume record,
    /// but they must never become network-active without explicit review.
    private func pauseUnresolvedStorageTorrents() async -> Bool {
        guard let storageClaimJournal else {
            unresolvedStorageTorrentIDs.removeAll()
            return true
        }

        let claims = await storageClaimJournal.allClaims().filter {
            $0.lease.state == .activating
                || $0.lease.state == .activationUnknown
        }
        let unresolvedInfoHashes = Set(claims.flatMap {
            Self.resumeIDs(for: $0.manifest.infoHashes)
        })
        var unresolvedIDs = Set(claims.compactMap(\.torrentID))
        for torrent in torrents where unresolvedInfoHashes.contains(torrent.infoHash) {
            unresolvedIDs.insert(torrent.id)
        }
        unresolvedStorageTorrentIDs = unresolvedIDs

        for id in unresolvedIDs.sorted() {
            guard let torrent = torrentsByID[id], !torrent.manuallyPaused else {
                continue
            }
            do {
                try await engine.pause(id: id)
            } catch {
                await engine.terminateConnection(
                    recoveryDisposition: .terminal
                )
                preventAutomaticEngineRecoveryAfterTerminalFailure()
                setLastError(
                    "A torrent with unresolved storage activation could not be kept paused. The torrent engine was stopped. \(error.localizedDescription)",
                    source: .userAction
                )
                return false
            }
        }
        return true
    }

    private static func resumeIDs(
        for infoHashes: TorrentStorageInfoHashes
    ) -> [String] {
        var ids = [String]()
        ids.reserveCapacity(2)
        if let v1 = infoHashes.v1 {
            ids.append(resumeID(prefix: "v1:", digest: v1))
        }
        if let v2 = infoHashes.v2 {
            ids.append(resumeID(prefix: "v2:", digest: v2))
        }
        return ids
    }

    private static func resumeID(prefix: String, digest: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var encoded = Array(prefix.utf8)
        encoded.reserveCapacity(encoded.count + digest.count * 2)
        for byte in digest {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private func startProductionEngine(
        enablePeerExchangePlugin: Bool,
        kind: TorrentStoreEngineStartupKind
    ) {
        backgroundRefreshesEnabled = true
        precondition(operationDrainTask == nil)
        if case .initial = kind {
            precondition(pendingOperations.isEmpty)
            precondition(refreshCount(for: engineLifecycleGeneration) == 0)
        } else {
            // The new controller will be synchronized from current local
            // state. Intermediate settings applications captured for the old
            // controller are stale; queued user operations remain FIFO.
            pendingOperations.removeAll { operation in
                if case .applySettings = operation {
                    return true
                }
                return false
            }
        }
        precondition(!isEngineRestarting)

        let startupFactory = Self.engineStartupFactoryOverride.withLock { $0 }
        let connectionRetryMode: TorrentEngineConnectionRetryMode = switch kind {
        case .initial:
            .initial
        case .replacesTerminatedController:
            .replacingTerminatedController
        }

        let previousStartupTask = engineStartupTask
        previousStartupTask?.cancel()
        let previousEngine = engine
        let previousBrokerServer = storageBrokerServer
        storageBrokerServer = nil
        let previousRefreshTask = refreshTask
        let previousWakeRefreshTask = wakeRefreshTask
        let previousActiveRefreshTask = activeRefreshTask
        refreshTask?.cancel()
        wakeRefreshTask?.cancel()
        refreshTask = nil
        wakeRefreshTask = nil
        cancelActiveRefresh()
        appliedNetworkBinding = nil
        lastNetworkInterfaceRevision = nil
        settingsState.networkInterfacesAreAuthoritative = false
        advanceEngineLifecycleGeneration()
        let startupGeneration = engineLifecycleGeneration
        engine = TorrentUnavailableEngine(message: "Torrent engine startup is in progress.")
        isEngineStarting = true
        engineStartupFailed = false

        engineStartupTask = Task { @MainActor [weak self] in
            await previousStartupTask?.value
            switch kind {
            case .initial:
                await previousEngine.shutdown()
                previousBrokerServer?.cancel()
                await previousRefreshTask?.value
                await previousWakeRefreshTask?.value
                await previousActiveRefreshTask?.value
            case .replacesTerminatedController:
                // The disconnected controller is already fail-closed. Do not
                // let a cancellation-insensitive stale poll prevent recovery;
                // lifecycle generations reject any result it later produces.
                await previousEngine.terminateConnection(
                    recoveryDisposition: .replaceController
                )
                previousBrokerServer?.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  self.engineLifecycleGeneration == startupGeneration else {
                return
            }

            let outcome = await Self.createProductionEngine(
                startupFactory: startupFactory,
                enablePeerExchangePlugin: enablePeerExchangePlugin,
                storageBrokerRegistry: self.storageBrokerRegistry,
                connectionRetryMode: connectionRetryMode
            )

            guard !Task.isCancelled,
                  self.engineLifecycleGeneration == startupGeneration else {
                if case .started(let staleEngine, let staleBroker) = outcome {
                    await staleEngine.shutdown()
                    staleBroker?.cancel()
                }
                return
            }
            self.engineStartupTask = nil
            self.isEngineStarting = false
            switch outcome {
            case .started(let engine, let brokerServer):
                self.engine = engine
                self.storageBrokerServer = brokerServer
                self.libtorrentVersion = engine.libtorrentVersion
                self.appliedPeerExchangePluginEnabled = enablePeerExchangePlugin
                self.engineStartupFailed = false
                // A controller is accepted only after the service has created
                // a fail-closed engine and started authoritative interface
                // observation. Initial synchronization may therefore apply the
                // first policy without redundantly revoking this controller.
                self.confirmedNetworkBlockLifecycleGeneration = startupGeneration
                let restoreMayPrecedeSynchronization = self.pendingOperations.isEmpty
                let scheduledRestore = self.schedulePendingRestoreDefaultsIfPossible()
                self.startInitialEngineSync(
                    afterLeadingOperation: restoreMayPrecedeSynchronization && scheduledRestore
                )
            case .failed(let message):
                self.engine = TorrentUnavailableEngine(message: message)
                self.engineStartupFailed = true
                let startupError = TorrentEngineError.startupFailed(message).localizedDescription
                let messages = [self.lastError, startupError].compactMap { $0 }
                self.setLastError(messages.joined(separator: "\n\n"), source: .userAction)
                // Resolve queued callers deterministically against the
                // unavailable placeholder instead of leaving continuations
                // suspended forever behind a failed replacement.
                self.startOperationDrainIfNeeded()
                self.schedulePendingRestoreDefaultsIfPossible()
            case .cancelled:
                break
            }
        }
    }

    private func startInitialEngineSync(afterLeadingOperation: Bool = false) {
        precondition(!isEngineStarting)
        precondition(pendingOperations.count < Self.maximumPendingOperationCount)
        let operation = TorrentStorePendingOperation.user(TorrentStorePendingUserOperation(
            id: nil,
            perform: { store in
                await store.refreshFromEngine(notifiesCompletions: false)
                guard store.engine.isAvailable, !store.engineReplacementRequested else {
                    return
                }
                guard await store.pauseUnresolvedStorageTorrents() else {
                    return
                }
                store.prioritizeCurrentSettingsApplication(
                    refreshes: true,
                    notifiesCompletions: false
                )
            }
        ))
        // A replacement may have queued user work waiting. Its authoritative
        // interface snapshot and current settings must be established before
        // any engine work can reach the fresh controller. A reset requested
        // during startup may lead because it only updates the desired local
        // configuration while the handshaken controller remains blocked.
        let insertionIndex = afterLeadingOperation
            ? pendingOperations.index(after: pendingOperations.startIndex)
            : pendingOperations.startIndex
        pendingOperations.insert(operation, at: insertionIndex)
        startOperationDrainIfNeeded()
    }

    private func prioritizeCurrentSettingsApplication(
        refreshes: Bool,
        notifiesCompletions: Bool
    ) {
        pendingOperations.removeAll { operation in
            if case .applySettings = operation {
                return true
            }
            return false
        }
        precondition(pendingOperations.count < Self.maximumPendingOperationCount)
        pendingOperations.insert(
            .applySettings(TorrentStorePendingSettingsApplication(
                settings: settings,
                networkBinding: currentNetworkBinding,
                refreshes: refreshes,
                notifiesCompletions: notifiesCompletions
            )),
            at: pendingOperations.startIndex
        )
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        wakeRefreshTask?.cancel()
        let engine = engine
        let lifecycleGeneration = engineLifecycleGeneration
        wakeRefreshTask = Task { @MainActor [weak self] in
            let wakeEvents = await engine.wakeEvents()
            for await _ in wakeEvents {
                guard !Task.isCancelled else {
                    return
                }
                guard let self else {
                    return
                }
                guard self.engineLifecycleGeneration == lifecycleGeneration else {
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
                guard let self,
                      self.engineLifecycleGeneration == lifecycleGeneration else {
                    return
                }
                await self.refreshFromEngine()
            }
        }
    }

    private func startRefreshingIfNeeded() {
        guard backgroundRefreshesEnabled,
              !isEngineStarting,
              !isEngineRestarting,
              engine.isAvailable,
              !engineReplacementRequested,
              operationDrainTask == nil,
              pendingOperations.isEmpty,
              refreshTask == nil,
              wakeRefreshTask == nil else {
            return
        }
        startRefreshing()
    }

    private func perform(_ operation: @escaping @Sendable (any TorrentEngineServicing) async throws -> Void) {
        let errorGeneration = lastErrorGeneration
        scheduleUserOperation { store in
            do {
                try await operation(store.engine)
                await store.refreshFromEngine()
                store.clearLastError(ifUnchangedSince: errorGeneration)
            } catch {
                await store.pruneDownloadFolderAccess(
                    activeTorrents: store.torrents
                )
                store.setLastError(error.localizedDescription, source: .userAction)
            }
        }
    }

    private func scheduleBulkOperation(
        requestedIDs: Set<TorrentItem.ID>?,
        filter: TorrentStoreBulkCommandFilter,
        reversesOrder: Bool = false,
        excludesUnresolvedStorageActivations: Bool = false,
        operation: @escaping @Sendable (
            any TorrentEngineServicing,
            [TorrentItem.ID]
        ) async throws -> Void
    ) {
        if let requestedIDs, requestedIDs.isEmpty {
            return
        }
        let errorGeneration = lastErrorGeneration
        scheduleUserOperation { store in
            do {
                var ids = try await Self.prepareBulkCommandIDs(
                    torrents: store.torrents,
                    requestedIDs: requestedIDs,
                    filter: filter,
                    reversesOrder: reversesOrder
                )
                try Task.checkCancellation()
                if excludesUnresolvedStorageActivations {
                    ids.removeAll {
                        store.unresolvedStorageTorrentIDs.contains($0)
                    }
                }
                guard !ids.isEmpty else {
                    return
                }
                try await operation(store.engine, ids)
                await store.refreshFromEngine()
                store.clearLastError(
                    ifUnchangedSince: errorGeneration
                )
            } catch {
                await store.pruneDownloadFolderAccess(
                    activeTorrents: store.torrents
                )
                store.setLastError(
                    error.localizedDescription,
                    source: .userAction
                )
            }
        }
    }

    private static func pause(
        _ engine: any TorrentEngineServicing,
        _ ids: [TorrentItem.ID]
    ) async throws {
        for id in ids {
            try await engine.pause(id: id)
        }
    }

    private static func resume(
        _ engine: any TorrentEngineServicing,
        _ ids: [TorrentItem.ID]
    ) async throws {
        for id in ids {
            try await engine.resume(id: id)
        }
    }

    private func scheduleLabelMutation(
        _ request: TorrentLabelMutationRequest
    ) {
        guard enqueueLabelMutation(
            TorrentStorePendingLabelMutation(
                id: nil,
                request: request,
                state: nil
            )
        ) else {
            setLastError(
                TorrentStoreError.tooManyPendingOperations
                    .localizedDescription,
                source: .userAction
            )
            return
        }
    }

    private func performLabelMutation(
        _ request: TorrentLabelMutationRequest
    ) async throws {
        try Task.checkCancellation()
        let mutationID = UUID()
        let state = TorrentStoreQueuedOperationState<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation(
                isolation: MainActor.shared
            ) { continuation in
                state.install(continuation)
                guard !Task.isCancelled else {
                    state.cancel()
                    return
                }
                guard enqueueLabelMutation(
                    TorrentStorePendingLabelMutation(
                        id: mutationID,
                        request: request,
                        state: state
                    )
                ) else {
                    state.resume(
                        throwing:
                            TorrentStoreError.tooManyPendingOperations
                    )
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self, state] in
                self?.removePendingLabelMutation(id: mutationID)
                state.cancel()
            }
        }
    }

    @discardableResult
    private func enqueueLabelMutation(
        _ mutation: TorrentStorePendingLabelMutation
    ) -> Bool {
        guard pendingLabelMutations.count
                < Self.maximumPendingLabelMutationCount else {
            return false
        }
        pendingLabelMutations.append(mutation)
        startLabelMutationDrainIfNeeded()
        return true
    }

    private func removePendingLabelMutation(id: UUID) {
        guard let index = pendingLabelMutations.firstIndex(where: {
            $0.id == id
        }) else {
            return
        }
        pendingLabelMutations.remove(at: index)
    }

    private func startLabelMutationDrainIfNeeded() {
        guard labelMutationDrainTask == nil else {
            return
        }
        labelMutationDrainTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                guard !self.pendingLabelMutations.isEmpty else {
                    self.labelMutationDrainTask = nil
                    return
                }
                let mutation = self.pendingLabelMutations.removeFirst()
                await self.executeLabelMutation(mutation)
            }
            self?.labelMutationDrainTask = nil
        }
    }

    private func executeLabelMutation(
        _ mutation: TorrentStorePendingLabelMutation
    ) async {
        guard mutation.state?.begin() ?? true else {
            return
        }
        do {
            try await applyLabelMutation(mutation.request)
            mutation.state?.resume(returning: ())
        } catch {
            mutation.state?.resume(throwing: error)
            if mutation.state == nil, !(error is CancellationError) {
                setLastError(
                    error.localizedDescription,
                    source: .userAction
                )
            }
        }
    }

    private func applyLabelMutation(
        _ request: TorrentLabelMutationRequest
    ) async throws {
        while true {
            let revision = labelPersistenceRevision
            let presentationRevision = torrentPresentationRevision
            let currentLabels = labels
            let currentAssignments = labelAssignments
            let currentActiveTorrentIDs = activeTorrentIDs
            let plan = try await TorrentLabelMutationPlan.prepare(
                request: request,
                labels: currentLabels,
                assignments: currentAssignments,
                activeTorrentIDs: currentActiveTorrentIDs,
                revision: revision
            )
            try Task.checkCancellation()
            guard plan.revision == labelPersistenceRevision,
                  presentationRevision == torrentPresentationRevision else {
                continue
            }
            guard let snapshot = plan.snapshot else {
                return
            }
            labels = snapshot.labels
            labelAssignments = snapshot.assignments
            saveLabels()
            return
        }
    }

    private func drainPendingLabelMutations() async {
        while let task = labelMutationDrainTask {
            await task.value
        }
    }

    private func pruneTorrentLabels(
        activeTorrentIDs: Set<TorrentItem.ID>
    ) async throws {
        let revision = labelPersistenceRevision
        let assignments = labelAssignments
        let plan = try await TorrentLabelPrunePlan.prepare(
            assignments: assignments,
            activeTorrentIDs: activeTorrentIDs,
            revision: revision
        )
        try Task.checkCancellation()
        guard plan.revision == labelPersistenceRevision else {
            throw CancellationError()
        }
        guard let assignments = plan.assignments else {
            return
        }
        labelAssignments = assignments
        saveLabels()
    }

    private func saveLabels() {
        precondition(
            labelPersistenceRevision != UInt64.max,
            "Label persistence revision exhausted"
        )
        labelPersistenceRevision += 1
        let revision = labelPersistenceRevision
        let saveID = UUID()
        let labels = labels
        let assignments = labelAssignments
        let labelPersistenceStore = labelPersistenceStore
        labelSaveTask?.cancel()
        labelSaveID = saveID
        labelSaveTask = Task { @MainActor [weak self, labelPersistenceStore] in
            do {
                try await labelPersistenceStore.save(
                    labels: labels,
                    assignments: assignments,
                    revision: revision
                )
                try Task.checkCancellation()
                guard let self,
                      self.labelSaveID == saveID,
                      self.labelPersistenceRevision == revision else {
                    return
                }
                self.labelSaveTask = nil
                self.labelSaveID = nil
            } catch is CancellationError {
                guard let self, self.labelSaveID == saveID else {
                    return
                }
                self.labelSaveTask = nil
                self.labelSaveID = nil
            } catch {
                guard let self, self.labelSaveID == saveID else {
                    return
                }
                self.labelSaveTask = nil
                self.labelSaveID = nil
                assertionFailure("Failed to encode labels: \(error)")
            }
        }
        scheduleSidebarUpdate()
    }

    private func drainPendingLabelSave() async {
        while let task = labelSaveTask {
            let saveID = labelSaveID
            await task.value
            if labelSaveID == saveID {
                labelSaveTask = nil
                labelSaveID = nil
            }
        }
    }

    private func scheduleSettingsSave() {
        precondition(
            settingsPersistenceRevision != UInt64.max,
            "Settings persistence revision exhausted"
        )
        settingsPersistenceRevision += 1
        let revision = settingsPersistenceRevision
        let settings = settings
        let saveID = UUID()
        let preferencesStore = preferencesStore
        settingsSaveTask?.cancel()
        settingsSaveID = saveID
        settingsSaveTask = Task { @MainActor [weak self, preferencesStore] in
            do {
                try await preferencesStore.saveSettings(
                    settings,
                    revision: revision
                )
                try Task.checkCancellation()
                guard let self,
                      self.settingsSaveID == saveID,
                      self.settingsPersistenceRevision == revision else {
                    return
                }
                self.settingsSaveTask = nil
                self.settingsSaveID = nil
            } catch is CancellationError {
                guard let self, self.settingsSaveID == saveID else {
                    return
                }
                self.settingsSaveTask = nil
                self.settingsSaveID = nil
            } catch {
                guard let self, self.settingsSaveID == saveID else {
                    return
                }
                self.settingsSaveTask = nil
                self.settingsSaveID = nil
                assertionFailure("Failed to save settings: \(error)")
            }
        }
    }

    private func scheduleSortPreferencesSave() {
        precondition(
            sortPersistenceRevision != UInt64.max,
            "Sort persistence revision exhausted"
        )
        sortPersistenceRevision += 1
        let revision = sortPersistenceRevision
        let order = sortOrder
        let direction = sortDirection
        sortDirectionsByOrder[order] = direction
        let saveID = UUID()
        let preferencesStore = preferencesStore
        sortPreferencesSaveTask?.cancel()
        sortPreferencesSaveID = saveID
        sortPreferencesSaveTask = Task { @MainActor [
            weak self,
            preferencesStore
        ] in
            do {
                try await preferencesStore.saveSorting(
                    order: order,
                    direction: direction,
                    revision: revision
                )
                try Task.checkCancellation()
                guard let self,
                      self.sortPreferencesSaveID == saveID,
                      self.sortPersistenceRevision == revision else {
                    return
                }
                self.sortPreferencesSaveTask = nil
                self.sortPreferencesSaveID = nil
            } catch is CancellationError {
                guard let self,
                      self.sortPreferencesSaveID == saveID else {
                    return
                }
                self.sortPreferencesSaveTask = nil
                self.sortPreferencesSaveID = nil
            } catch {
                guard let self,
                      self.sortPreferencesSaveID == saveID else {
                    return
                }
                self.sortPreferencesSaveTask = nil
                self.sortPreferencesSaveID = nil
                assertionFailure("Failed to save sort preferences: \(error)")
            }
        }
    }

    private func drainPendingPreferenceSaves() async {
        while settingsSaveTask != nil || sortPreferencesSaveTask != nil {
            let settingsTask = settingsSaveTask
            let settingsID = settingsSaveID
            let sortTask = sortPreferencesSaveTask
            let sortID = sortPreferencesSaveID
            await settingsTask?.value
            await sortTask?.value
            if settingsSaveID == settingsID {
                settingsSaveTask = nil
                settingsSaveID = nil
            }
            if sortPreferencesSaveID == sortID {
                sortPreferencesSaveTask = nil
                sortPreferencesSaveID = nil
            }
        }
    }

    private func drainPendingPersistenceWork() async {
        while labelMutationDrainTask != nil
                || labelSaveTask != nil
                || settingsSaveTask != nil
                || sortPreferencesSaveTask != nil {
            await drainPendingLabelMutations()
            await drainPendingPreferenceSaves()
            await drainPendingLabelSave()
        }
    }

    private func applyTorrentPresentation(
        _ presentation: TorrentListPresentation,
        supersedesSort: Bool = true,
        updatesSidebar: Bool = true
    ) {
        if supersedesSort {
            cancelSortUpdate()
        }
        torrentPresentationRevision &+= 1
        torrents = presentation.torrents
        torrentsByID = presentation.torrentsByID
        activeTorrentIDs = presentation.activeIDs
        torrentInfoTabRequests = torrentInfoTabRequests.filter {
            presentation.torrentsByID[$0.key] != nil
        }
        torrentState.update(presentation)
        updateCommandState()
        if updatesSidebar && presentation.rowsChanged {
            scheduleSidebarUpdate()
        }
    }

    private func scheduleSidebarUpdate() {
        torrentFilterRevision &+= 1
        sidebarUpdateTask?.cancel()
        let updateID = UUID()
        let torrents = torrents
        let labels = labels
        let labelAssignments = labelAssignments
        let trackerHostsByTorrentID = trackerHostsByTorrentID
        sidebarUpdateID = updateID
        sidebarUpdateTask = Task { @MainActor [weak self] in
            do {
                let snapshot = try await TorrentSidebarSnapshot.prepare(
                    torrents: torrents,
                    labels: labels,
                    labelAssignments: labelAssignments,
                    trackerHostsByTorrentID: trackerHostsByTorrentID
                )
                try Task.checkCancellation()
                guard let self, self.sidebarUpdateID == updateID else {
                    return
                }
                self.sidebarUpdateTask = nil
                self.sidebarUpdateID = nil
                self.sidebarState.update(snapshot)
            } catch {
                guard let self, self.sidebarUpdateID == updateID else {
                    return
                }
                self.sidebarUpdateTask = nil
                self.sidebarUpdateID = nil
            }
        }
    }

    private func updateCommandState() {
        commandUpdateTask?.cancel()
        let updateID = UUID()
        let torrentsByID = torrentsByID
        let selectedIDs = selectionState.ids
        let selectionRevision = selectionState.revision
        let presentationRevision = torrentPresentationRevision
        let sortOrder = sortOrder
        let sortDirection = sortDirection
        let canPauseAnyTorrent = torrentState.canPauseAnyTorrent
        let canResumeAnyTorrent = torrentState.canResumeAnyTorrent
        commandUpdateID = updateID
        commandUpdateTask = Task { @MainActor [weak self] in
            do {
                let snapshot = try await TorrentCommandSnapshot.prepare(
                    torrentsByID: torrentsByID,
                    selectedIDs: selectedIDs,
                    sortOrder: sortOrder,
                    sortDirection: sortDirection,
                    canPauseAnyTorrent: canPauseAnyTorrent,
                    canResumeAnyTorrent: canResumeAnyTorrent
                )
                try Task.checkCancellation()
                guard let self,
                      self.commandUpdateID == updateID,
                      self.selectionState.revision == selectionRevision,
                      self.torrentPresentationRevision
                        == presentationRevision,
                      self.sortOrder == sortOrder,
                      self.sortDirection == sortDirection else {
                    return
                }
                self.commandUpdateTask = nil
                self.commandUpdateID = nil
                self.commandState.update(snapshot)
            } catch {
                guard let self, self.commandUpdateID == updateID else {
                    return
                }
                self.commandUpdateTask = nil
                self.commandUpdateID = nil
            }
        }
    }

    private func applySort() {
        refreshGeneration &+= 1
        updateCommandState()
        sortUpdateTask?.cancel()
        let updateID = UUID()
        let presentationRevision = torrentPresentationRevision
        let torrents = torrents
        let sortOrder = sortOrder
        let sortDirection = sortDirection
        let previousRows = torrentState.rows
        sortUpdateID = updateID
        sortUpdateTask = Task { @MainActor [weak self] in
            do {
                let presentation = try await TorrentListPresentation.prepareSorted(
                    torrents: torrents,
                    sortOrder: sortOrder,
                    sortDirection: sortDirection,
                    previousRows: previousRows
                )
                try Task.checkCancellation()
                guard let self,
                      self.sortUpdateID == updateID,
                      self.torrentPresentationRevision == presentationRevision,
                      self.sortOrder == sortOrder,
                      self.sortDirection == sortDirection else {
                    return
                }
                self.sortUpdateTask = nil
                self.sortUpdateID = nil
                self.applyTorrentPresentation(
                    presentation,
                    supersedesSort: false,
                    updatesSidebar: false
                )
            } catch {
                guard let self, self.sortUpdateID == updateID else {
                    return
                }
                self.sortUpdateTask = nil
                self.sortUpdateID = nil
            }
        }
    }

    private func cancelSortUpdate() {
        sortUpdateTask?.cancel()
        sortUpdateTask = nil
        sortUpdateID = nil
    }

    private func scheduleApplySettings(refreshes: Bool = false, notifiesCompletions: Bool = true) {
        guard !isEngineStarting, engine.isAvailable else {
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
        id: UUID? = nil,
        _ operation: @escaping @MainActor @Sendable (TorrentStore) async -> Void
    ) -> Bool {
        guard !isEngineStarting else {
            setLastError(TorrentStoreError.engineStarting.localizedDescription, source: .userAction)
            return false
        }
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

        pendingOperations.append(.user(TorrentStorePendingUserOperation(
            id: id,
            perform: operation
        )))
        startOperationDrainIfNeeded()
        return true
    }

    private func performQueuedUserOperation<Result: Sendable>(
        _ operation: @escaping @Sendable (any TorrentEngineServicing) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        guard !isEngineStarting else {
            throw TorrentStoreError.engineStarting
        }

        let operationID = UUID()
        let state = TorrentStoreQueuedOperationState<Result>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation(
                isolation: MainActor.shared
            ) { continuation in
                state.install(continuation)
                guard !Task.isCancelled else {
                    state.cancel()
                    return
                }
                let accepted = scheduleUserOperation(id: operationID) { store in
                    guard state.begin() else {
                        return
                    }
                    do {
                        state.resume(returning: try await operation(store.engine))
                    } catch {
                        state.resume(throwing: error)
                    }
                }
                if !accepted {
                    state.resume(throwing: TorrentStoreError.tooManyPendingOperations)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self, state] in
                self?.removePendingUserOperation(id: operationID)
                state.cancel()
            }
        }
    }

    private func performQueuedStoreOperation<Result: Sendable>(
        _ operation: @escaping @MainActor @Sendable (TorrentStore) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        guard !isEngineStarting else {
            throw TorrentStoreError.engineStarting
        }

        let operationID = UUID()
        let state = TorrentStoreQueuedOperationState<Result>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation(
                isolation: MainActor.shared
            ) { continuation in
                state.install(continuation)
                guard !Task.isCancelled else {
                    state.cancel()
                    return
                }
                let accepted = scheduleUserOperation(id: operationID) { store in
                    guard state.begin() else {
                        return
                    }
                    do {
                        state.resume(returning: try await operation(store))
                    } catch {
                        state.resume(throwing: error)
                    }
                }
                if !accepted {
                    state.resume(
                        throwing: TorrentStoreError.tooManyPendingOperations
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self, state] in
                self?.removePendingUserOperation(id: operationID)
                state.cancel()
            }
        }
    }

    private func removePendingUserOperation(id: UUID) {
        guard let index = pendingOperations.firstIndex(where: { operation in
            guard case .user(let userOperation) = operation else {
                return false
            }
            return userOperation.id == id
        }) else {
            return
        }
        pendingOperations.remove(at: index)
    }

    private func startOperationDrainIfNeeded() {
        guard operationDrainTask == nil else {
            return
        }

        operationDrainTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let store = self else {
                    return
                }
                await store.drainImmediateNetworkBlocks()
                if store.pauseOperationDrainForEngineReplacement() {
                    return
                }
                guard let operation = store.takeNextPendingOperation() else {
                    store.operationDrainTask = nil
                    store.startEngineReplacementIfNeeded()
                    store.startRefreshingIfNeeded()
                    return
                }
                await store.execute(operation)
                if store.pauseOperationDrainForEngineReplacement() {
                    return
                }
            }
            self?.operationDrainTask = nil
        }
    }

    private func pauseOperationDrainForEngineReplacement() -> Bool {
        guard engineReplacementRequested else {
            return false
        }
        operationDrainTask = nil
        startEngineReplacementIfNeeded()
        return true
    }

    private func takeNextPendingOperation() -> TorrentStorePendingOperation? {
        guard !pendingOperations.isEmpty else {
            return nil
        }

        return pendingOperations.removeFirst()
    }

    private func execute(_ operation: TorrentStorePendingOperation) async {
        switch operation {
        case .applySettings(let application):
            if !engineReplacementRequested, engine.isAvailable {
                await applySettingsToEngine(
                    application.settings,
                    networkBinding: application.networkBinding
                )
            }
            if application.refreshes, !engineReplacementRequested, engine.isAvailable {
                await refreshFromEngine(notifiesCompletions: application.notifiesCompletions)
            }
        case .user(let operation):
            await operation.perform(self)
        }
    }

    private func drainPendingOperations() async {
        while true {
            let startupTask = engineStartupTask
            let operationTask = operationDrainTask
            let networkBlockTask = immediateNetworkBlockTask
            await networkBlockTask?.value
            await operationTask?.value
            await startupTask?.value
            guard engineStartupTask != nil
                    || operationDrainTask != nil
                    || immediateNetworkBlockTask != nil else {
                return
            }
        }
    }

    private func drainImmediateNetworkBlocks() async {
        while let task = immediateNetworkBlockTask {
            await task.value
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
        let settingsEngine = engine
        var lifecycleGeneration = engineLifecycleGeneration
        var settingsMutationIsInFlight = false

        do {
            if networkMustRemainBlocked || bindingChanged || peerExchangePluginChanged {
                guard await blockNetworkForSettingsTransition() else {
                    return
                }
            }

            if peerExchangePluginChanged {
                completionNotifier.beginBaseline()
                try await restartEngine(enablePeerExchangePlugin: settings.enablePeerExchangePlugin)
                guard !Task.isCancelled, !engineReplacementRequested else {
                    return
                }
                lifecycleGeneration = engineLifecycleGeneration
                lastSnapshotRevision = nil
                lastTrackerHostRevision = nil
                pendingTrackerHostRefresh = true
            }

            // Non-network settings retain FIFO ordering across queued user
            // operations. If this binding became stale while queued, submit it
            // only in its blocked form; a later coalesced application owns the
            // final authorization.
            let submittedNetworkBinding = TorrentNetworkBinding(
                interfaceName: networkBinding.interfaceName,
                interfaceFingerprint: networkBinding.interfaceFingerprint,
                vpnServiceID: networkBinding.vpnServiceID,
                networkBlocked: networkBinding.networkBlocked || networkBinding != currentNetworkBinding
            )
            // Poll results captured before or during a policy transition must
            // not overwrite the containment evidence established by its ack.
            advanceEngineMutationGeneration()
            settingsMutationIsInFlight = true
            try await settingsEngine.applySettings(
                settings,
                networkBinding: submittedNetworkBinding
            )
            guard lifecycleGeneration == engineLifecycleGeneration else {
                return
            }
            advanceEngineMutationGeneration()
            settingsMutationIsInFlight = false
            guard settingsEngine.isAvailable else {
                handleUnavailableEngine(settingsEngine, lifecycleGeneration: lifecycleGeneration)
                return
            }
            appliedNetworkBinding = networkBinding
            appliedPeerExchangePluginEnabled = settings.enablePeerExchangePlugin
            if submittedNetworkBinding.networkBlocked {
                confirmedNetworkBlockLifecycleGeneration = lifecycleGeneration
            } else {
                confirmedNetworkBlockLifecycleGeneration = nil
            }
            clearLastError(from: .settingsApply)
        } catch {
            if settingsMutationIsInFlight,
               lifecycleGeneration == engineLifecycleGeneration {
                advanceEngineMutationGeneration()
            }
            if !settingsEngine.isAvailable {
                handleUnavailableEngine(settingsEngine, lifecycleGeneration: lifecycleGeneration)
            }
            guard !engineStartupFailed else {
                return
            }
            setLastError(error.localizedDescription, source: .settingsApply)
        }
    }

    private func restartEngine(enablePeerExchangePlugin: Bool) async throws {
        let restartedEngine = engine
        let previousLifecycleGeneration = engineLifecycleGeneration
        let previousRefreshTask = refreshTask
        let previousWakeRefreshTask = wakeRefreshTask
        let previousActiveRefreshTask = activeRefreshTask
        refreshTask = nil
        wakeRefreshTask = nil
        cancelActiveRefresh()
        isEngineRestarting = true
        defer {
            isEngineRestarting = false
        }
        let networkWasConfirmedBlocked = networkIsConfirmedBlocked
        advanceEngineLifecycleGeneration()
        let lifecycleGeneration = engineLifecycleGeneration
        if networkWasConfirmedBlocked {
            confirmedNetworkBlockLifecycleGeneration = lifecycleGeneration
        }
        if refreshCount(for: previousLifecycleGeneration) > 0 {
            guard await blockNetworkForSettingsTransition() else {
                return
            }
            try Task.checkCancellation()
            guard lifecycleGeneration == engineLifecycleGeneration else {
                return
            }
        }
        guard await drainRefreshesBeforeEngineRestart(
            lifecycleGeneration: previousLifecycleGeneration
        ) else {
            guard !Task.isCancelled else {
                return
            }
            // A refresh that does not unwind after network containment must
            // never hold the restart lane forever. Closing the controller is
            // the bounded fail-closed escape; recovery uses a fresh handshake.
            await restartedEngine.terminateConnection(
                recoveryDisposition: .replaceController
            )
            requestEngineReplacement()
            return
        }
        previousRefreshTask?.cancel()
        previousWakeRefreshTask?.cancel()
        await previousRefreshTask?.value
        await previousWakeRefreshTask?.value
        await previousActiveRefreshTask?.value
        try Task.checkCancellation()
        guard lifecycleGeneration == engineLifecycleGeneration else {
            return
        }
        do {
            try await restartedEngine.restart(
                enablePeerExchangePlugin: enablePeerExchangePlugin
            )
        } catch {
            if lifecycleGeneration == engineLifecycleGeneration {
                let disposition = recoveryDisposition(
                    for: error,
                    engine: restartedEngine
                )
                let terminationDisposition = disposition == .none
                    ? TorrentEngineRecoveryDisposition.terminal
                    : disposition
                await restartedEngine.terminateConnection(
                    recoveryDisposition: terminationDisposition
                )
                if terminationDisposition == .replaceController {
                    requestEngineReplacement()
                } else {
                    preventAutomaticEngineRecoveryAfterTerminalFailure()
                }
            }
            throw error
        }
        try Task.checkCancellation()
        guard lifecycleGeneration == engineLifecycleGeneration,
              restartedEngine.isAvailable else {
            handleUnavailableEngine(restartedEngine, lifecycleGeneration: lifecycleGeneration)
            return
        }
        confirmedNetworkBlockLifecycleGeneration = lifecycleGeneration
    }

    private func drainRefreshesBeforeEngineRestart(lifecycleGeneration: UInt64) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.engineRestartRefreshDrainTimeout)
        while refreshCount(for: lifecycleGeneration) > 0 {
            guard !Task.isCancelled, clock.now < deadline else {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func beginRefresh(for lifecycleGeneration: UInt64) -> Bool {
        let count = refreshCount(for: lifecycleGeneration)
        precondition(count < Int.max)
        refreshesInFlightByLifecycle[lifecycleGeneration] = count + 1
        return count > 0
    }

    private func endRefresh(for lifecycleGeneration: UInt64) {
        let count = refreshCount(for: lifecycleGeneration)
        precondition(count > 0)
        if count == 1 {
            refreshesInFlightByLifecycle.removeValue(forKey: lifecycleGeneration)
        } else {
            refreshesInFlightByLifecycle[lifecycleGeneration] = count - 1
        }
    }

    private func refreshCount(for lifecycleGeneration: UInt64) -> Int {
        refreshesInFlightByLifecycle[lifecycleGeneration, default: 0]
    }

    private func advanceEngineLifecycleGeneration() {
        precondition(engineLifecycleGeneration != UInt64.max)
        engineLifecycleGeneration += 1
        advanceEngineMutationGeneration()
        refreshGeneration &+= 1
        lastSnapshotRevision = nil
        lastTrackerHostRevision = nil
        pendingTrackerHostRefresh = true
        confirmedNetworkBlockLifecycleGeneration = nil
    }

    private func cancelActiveRefresh() {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        activeRefreshID = nil
        pendingRefreshNotifiesCompletions = nil
    }

    private func advanceEngineMutationGeneration() {
        precondition(engineMutationGeneration != UInt64.max)
        engineMutationGeneration += 1
    }

    private func pruneDownloadFolderAccess(
        activeTorrents: [TorrentItem]
    ) async {
        do {
            while true {
                let snapshot = await downloadFolderAccessStore
                    .makePruneSnapshot()
                let plan = try await DownloadFolderPrunePlan.prepare(
                    snapshot: snapshot,
                    activeTorrents: activeTorrents
                )
                try Task.checkCancellation()
                if await downloadFolderAccessStore.applyPrunePlan(
                    plan,
                    activeTorrents: activeTorrents
                ) {
                    break
                }
            }
        } catch is CancellationError {
            return
        } catch {
            setLastError(error.localizedDescription, source: .userAction)
        }
    }

    private func pruneDownloadFolderAccesses(
        activeTorrents: [TorrentItem],
        generation: Int,
        lifecycleGeneration: UInt64,
        mutationGeneration: UInt64,
        presentationRevision: UInt64
    ) async throws {
        while true {
            let snapshot = await downloadFolderAccessStore.makePruneSnapshot()
            let plan = try await DownloadFolderPrunePlan.prepare(
                snapshot: snapshot,
                activeTorrents: activeTorrents
            )
            try Task.checkCancellation()
            guard generation == refreshGeneration,
                  lifecycleGeneration == engineLifecycleGeneration,
                  mutationGeneration == engineMutationGeneration,
                  presentationRevision == torrentPresentationRevision else {
                throw CancellationError()
            }
            if await downloadFolderAccessStore.applyPrunePlan(
                plan,
                activeTorrents: activeTorrents
            ) {
                return
            }
        }
    }

    private func requireRestoreDefaultsQueueCapacity() throws {
        let pendingUserOperationCount = pendingOperations.reduce(into: 0) { count, operation in
            if case .user = operation {
                count += 1
            }
        }
        let defaultSettings = TorrentSettings().clamped()
        let settingsApplicationNeedsSlot: Bool
        if defaultSettings == settings {
            settingsApplicationNeedsSlot = false
        } else if let lastOperation = pendingOperations.last,
                  case .applySettings = lastOperation {
            settingsApplicationNeedsSlot = false
        } else {
            settingsApplicationNeedsSlot = true
        }
        let requiredSlots = settingsApplicationNeedsSlot ? 1 : 0
        guard pendingUserOperationCount < Self.maximumPendingUserOperationCount,
              pendingOperations.count <= Self.maximumPendingOperationCount - requiredSlots else {
            throw TorrentStoreError.tooManyPendingOperations
        }
    }

    private func applyImmediateNetworkBlockIfNeeded(for networkBinding: AppliedNetworkBinding) {
        let bindingChanged = appliedNetworkBinding.map { $0 != networkBinding } ?? false
        guard networkBinding.networkBlocked || bindingChanged else {
            return
        }

        guard !networkIsConfirmedBlocked, immediateNetworkBlockTask == nil else {
            return
        }
        immediateNetworkBlockTask = Task { @MainActor [weak self] in
            defer {
                self?.immediateNetworkBlockTask = nil
            }
            guard !Task.isCancelled else {
                return
            }
            guard let self else {
                return
            }

            _ = await self.blockNetworkForSettingsTransition()
        }
    }

    private func blockNetworkForSettingsTransition() async -> Bool {
        guard !networkIsConfirmedBlocked else {
            return true
        }
        let blockedEngine = engine
        let lifecycleGeneration = engineLifecycleGeneration
        // Reject any poll that captured pre-containment network status. A
        // second advance below also rejects a poll begun while the block RPC
        // was suspended on the helper.
        advanceEngineMutationGeneration()
        do {
            let disposition = try await blockedEngine.blockNetworkNow()
            guard lifecycleGeneration == engineLifecycleGeneration else {
                return false
            }
            advanceEngineMutationGeneration()
            switch disposition {
            case .engineRemainsAvailable:
                confirmedNetworkBlockLifecycleGeneration = lifecycleGeneration
                return true
            case .engineReplacementRequired:
                if blockedEngine.recoveryDisposition == .terminal {
                    handleUnavailableEngine(
                        blockedEngine,
                        lifecycleGeneration: lifecycleGeneration
                    )
                } else {
                    requestEngineReplacement()
                }
                return false
            }
        } catch {
            // Failure to confirm an immediate block is terminal even if an
            // implementation still reports itself as available. Disconnect
            // containment is the fail-closed fallback.
            let disposition = recoveryDisposition(
                for: error,
                engine: blockedEngine
            )
            await blockedEngine.terminateConnection(
                recoveryDisposition: disposition == .terminal
                    ? .terminal
                    : .replaceController
            )
            guard lifecycleGeneration == engineLifecycleGeneration else {
                return false
            }
            advanceEngineMutationGeneration()
            if disposition == .terminal {
                preventAutomaticEngineRecoveryAfterTerminalFailure()
                let message = error.localizedDescription
                if !message.isEmpty {
                    setLastError(message, source: .settingsApply)
                }
            } else {
                requestEngineReplacement()
            }
            return false
        }
    }

    private func requestEngineReplacement() {
        guard !engineReplacementRequested, !engineStartupFailed else {
            return
        }
        engineReplacementRequested = true
        settingsState.networkInterfacesAreAuthoritative = false
        lastSnapshotRevision = nil
        lastTrackerHostRevision = nil
        pendingTrackerHostRefresh = true
        bridgeHealth = .unavailable
        networkStatus = .empty
        startEngineReplacementIfNeeded()
    }

    private func startEngineReplacementIfNeeded() {
        guard engineReplacementRequested,
              !engineStartupFailed,
              !isEngineStarting,
              !isEngineRestarting,
              operationDrainTask == nil,
              immediateNetworkBlockTask == nil else {
            return
        }
        engineReplacementRequested = false
        startProductionEngine(
            enablePeerExchangePlugin: settings.enablePeerExchangePlugin,
            kind: .replacesTerminatedController
        )
    }

    private var networkIsConfirmedBlocked: Bool {
        confirmedNetworkBlockLifecycleGeneration == engineLifecycleGeneration
    }

    private func updateConfirmedNetworkContainment(from status: TorrentNetworkStatus) {
        if status.networkBlocked {
            confirmedNetworkBlockLifecycleGeneration = engineLifecycleGeneration
        } else {
            confirmedNetworkBlockLifecycleGeneration = nil
        }
    }

    private func handleUnavailableEngine(
        _ unavailableEngine: any TorrentEngineServicing,
        lifecycleGeneration: UInt64
    ) {
        guard lifecycleGeneration == engineLifecycleGeneration,
              !unavailableEngine.isAvailable else {
            return
        }
        switch unavailableEngine.recoveryDisposition {
        case .replaceController:
            requestEngineReplacement()
        case .terminal:
            preventAutomaticEngineRecoveryAfterTerminalFailure()
            if let message = unavailableEngine.startupFailureMessage, !message.isEmpty {
                setLastError(message, source: .userAction)
            }
        case .none:
            break
        }
    }

    private func recoveryDisposition(
        for error: any Error,
        engine: any TorrentEngineServicing
    ) -> TorrentEngineRecoveryDisposition {
        let engineDisposition = engine.recoveryDisposition
        let errorDisposition = (error as? TorrentEngineClientError)?.recoveryDisposition ?? .none
        if engineDisposition == .terminal || errorDisposition == .terminal {
            return .terminal
        }
        if engineDisposition == .replaceController || errorDisposition == .replaceController {
            return .replaceController
        }
        return .none
    }

    private func preventAutomaticEngineRecoveryAfterTerminalFailure() {
        engineReplacementRequested = false
        engineStartupFailed = true
        settingsState.networkInterfacesAreAuthoritative = false
        refreshTask?.cancel()
        wakeRefreshTask?.cancel()
        refreshTask = nil
        wakeRefreshTask = nil
        cancelActiveRefresh()
        bridgeHealth = .unavailable
        networkStatus = .empty
        confirmedNetworkBlockLifecycleGeneration = nil
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
        guard settings.requireNetworkInterface else {
            return .unbound(networkBlocked: false)
        }
        return AppliedNetworkBinding(
            interfaceName: interfaceName,
            interfaceFingerprint: interface?.fingerprint ?? "",
            vpnServiceID: interface?.vpnServiceID,
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

    private nonisolated static func engineStartupErrorMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        return message.isEmpty ? "Unknown startup error." : message
    }

    @concurrent
    private static func createProductionEngine(
        startupFactory: TorrentStoreEngineStartupFactory?,
        enablePeerExchangePlugin: Bool,
        storageBrokerRegistry: TorrentStorageBrokerRegistry,
        connectionRetryMode: TorrentEngineConnectionRetryMode
    ) async -> TorrentStoreEngineStartupOutcome {
        guard !Task.isCancelled else {
            return .cancelled
        }
        do {
            let engine: any TorrentEngineServicing
            if let startupFactory {
                engine = try startupFactory(
                    enablePeerExchangePlugin
                )
            } else {
                let configuration = try TorrentEngineXPCIdentity.configuration()
                let brokerServer = try TorrentStorageBrokerServer(
                    registry: storageBrokerRegistry,
                    engineConfiguration: configuration
                )
                do {
                    engine = try await TorrentXPCClient.connect(
                        enablePeerExchangePlugin: enablePeerExchangePlugin,
                        brokerEndpoint: brokerServer.endpoint,
                        brokerSessionNonce: brokerServer.sessionNonce,
                        retryMode: connectionRetryMode
                    )
                } catch {
                    brokerServer.cancel()
                    throw error
                }
                guard !Task.isCancelled else {
                    await engine.shutdown()
                    brokerServer.cancel()
                    return .cancelled
                }
                return .started(engine, brokerServer)
            }
            guard !Task.isCancelled else {
                await engine.shutdown()
                return .cancelled
            }
            return .started(engine, nil)
        } catch {
            guard !Task.isCancelled else {
                return .cancelled
            }
            return .failed(engineStartupErrorMessage(error))
        }
    }

    private nonisolated static func isMagnetWithinSizeLimit(
        _ magnet: String
    ) -> Bool {
        magnet.utf8.prefix(
            TorrentInputLimits.maxMagnetURIBytes + 1
        ).count <= TorrentInputLimits.maxMagnetURIBytes
    }

    private nonisolated static func storageJournalDirectory() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return root
            .appending(path: Bundle.main.bundleIdentifier ?? "Torrent7", directoryHint: .isDirectory)
            .appending(path: "Storage", directoryHint: .isDirectory)
    }

    @concurrent
    private static func readTorrentFile(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let descriptor = try openTorrentFileDescriptor(url)
        defer {
            try? descriptor.close()
        }

        let fileSize = try validatedTorrentFileSize(descriptor: descriptor)
        let handle = FileHandle(fileDescriptor: descriptor.rawValue, closeOnDealloc: false)
        let maximumChunkSize = 1 * 1_024 * 1_024
        var data = Data()
        data.reserveCapacity(fileSize)
        while data.count < fileSize {
            try Task.checkCancellation()
            let remaining = fileSize - data.count
            guard let chunk = try handle.read(upToCount: min(maximumChunkSize, remaining)),
                  !chunk.isEmpty else {
                throw TorrentStoreError.unreadableTorrentFile
            }
            data.append(chunk)
        }
        try Task.checkCancellation()
        guard data.count == fileSize else {
            throw TorrentStoreError.unreadableTorrentFile
        }
        return data
    }

    @concurrent
    private static func selectedTorrents(
        ids: Set<TorrentItem.ID>,
        torrents: [TorrentItem]
    ) async throws -> [TorrentItem] {
        var selected = [TorrentItem]()
        selected.reserveCapacity(min(ids.count, torrents.count))
        for (index, torrent) in torrents.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if ids.contains(torrent.id) {
                selected.append(torrent)
            }
        }
        try Task.checkCancellation()
        return selected
    }

    @concurrent
    private static func prepareBulkCommandIDs(
        torrents: [TorrentItem],
        requestedIDs: Set<TorrentItem.ID>?,
        filter: TorrentStoreBulkCommandFilter,
        reversesOrder: Bool
    ) async throws -> [TorrentItem.ID] {
        try Task.checkCancellation()
        var ids = [TorrentItem.ID]()
        ids.reserveCapacity(min(requestedIDs?.count ?? torrents.count, torrents.count))
        for (index, torrent) in torrents.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            guard requestedIDs?.contains(torrent.id) ?? true else {
                continue
            }
            let includesTorrent = switch filter {
            case .any:
                true
            case .pausible:
                !torrent.manuallyPaused
            case .resumable:
                torrent.manuallyPaused
            case .hasMetadata:
                torrent.hasMetadata
            }
            if includesTorrent {
                ids.append(torrent.id)
            }
        }
        try Task.checkCancellation()
        if reversesOrder {
            ids.reverse()
        }
        return ids
    }

    @concurrent
    private static func retainedSelectionIDs(
        _ ids: Set<TorrentItem.ID>,
        activeIDs: Set<TorrentItem.ID>
    ) async throws -> Set<TorrentItem.ID> {
        try Task.checkCancellation()
        let candidates = ids.count <= activeIDs.count ? ids : activeIDs
        let membership = ids.count <= activeIDs.count ? activeIDs : ids
        var retainedIDs = Set<TorrentItem.ID>()
        retainedIDs.reserveCapacity(candidates.count)
        for (offset, id) in candidates.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if membership.contains(id) {
                retainedIDs.insert(id)
            }
        }
        try Task.checkCancellation()
        return retainedIDs
    }

    @concurrent
    private static func selectionIDs(
        _ ids: Set<TorrentItem.ID>,
        removing removedIDs: Set<TorrentItem.ID>
    ) async throws -> Set<TorrentItem.ID> {
        try Task.checkCancellation()
        var retainedIDs = Set<TorrentItem.ID>()
        retainedIDs.reserveCapacity(ids.count)
        for (offset, id) in ids.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if !removedIDs.contains(id) {
                retainedIDs.insert(id)
            }
        }
        try Task.checkCancellation()
        return retainedIDs
    }

    @concurrent
    private static func makeTrackerHostIndex(
        _ items: [TorrentTrackerHostItem],
        previous: [TorrentItem.ID: Set<String>]
    ) async throws -> [TorrentItem.ID: Set<String>]? {
        var hostsByTorrentID = [TorrentItem.ID: Set<String>]()
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            guard !item.torrentID.isEmpty, !item.host.isEmpty else {
                continue
            }
            hostsByTorrentID[item.torrentID, default: []].insert(item.host)
        }
        try Task.checkCancellation()
        return hostsByTorrentID == previous ? nil : hostsByTorrentID
    }

    @concurrent
    private static func prunedTrackerHostIndex(
        _ hostsByTorrentID: [TorrentItem.ID: Set<String>],
        activeTorrentIDs: Set<TorrentItem.ID>
    ) async throws -> [TorrentItem.ID: Set<String>]? {
        var pruned = [TorrentItem.ID: Set<String>]()
        pruned.reserveCapacity(min(hostsByTorrentID.count, activeTorrentIDs.count))
        for (index, item) in hostsByTorrentID.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if activeTorrentIDs.contains(item.key) {
                pruned[item.key] = item.value
            }
        }
        try Task.checkCancellation()
        return pruned.count == hostsByTorrentID.count ? nil : pruned
    }

    @concurrent
    private static func moveToTrash(_ url: URL) async throws {
        try Task.checkCancellation()
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let fileManager = FileManager()
        // Foundation imports the unused result parameter as an unsafe
        // Objective-C out pointer. Passing nil keeps that pointer unowned.
        try unsafe fileManager.trashItem(
            at: url,
            resultingItemURL: nil
        )
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
