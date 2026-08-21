import AppKit
import SwiftUI
import TorrentEngineModel

struct ContentView: View {
    private static let maximumPendingTorrentAddCount = 64

    @Environment(TorrentStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    let commandActions: TorrentCommandActions
    let commandState: TorrentCommandState
    let selectionState: TorrentSelectionState
    let torrentState: TorrentListState

    @State private var isAddingMagnet = false
    @State private var magnetURI = ""
    @State private var isChoosingFile = false
    @State private var fileImportMode: FileImportMode = .torrentFiles
    @State private var removalConfirmationRequest: TorrentRemovalConfirmationRequest?
    @State private var pendingRemovalIDs: Set<TorrentItem.ID>?
    @State private var queuedTorrentAddDrafts = [TorrentAddDraft]()
    @State private var activeTorrentAddDraft: TorrentAddDraft?
    @State private var pendingTorrentFileIntakeRequests =
        [TorrentFileIntakeRequest]()
    @State private var pendingMagnetIntakeRequests =
        [TorrentMagnetPreparationRequest]()
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var selectedSidebarSelection = TorrentSidebarSelection.all
    @State private var browserFilterState = TorrentBrowserFilterState()
    @State private var didPlayDropHoverHaptic = false
    @State private var pendingDownloadFolderURL: URL?
    @State private var sceneSaveTask: Task<Void, Never>?
    @State private var sceneSaveTaskID: UUID?
    @State private var addDraftPresentationTask: Task<Void, Never>?
    @State private var addDraftPresentationTaskID: UUID?
    @State private var fileImporterResetTask: Task<Void, Never>?
    @State private var fileImporterResetTaskID: UUID?
    @State private var searchResetTask: Task<Void, Never>?
    @State private var searchResetTaskID: UUID?

    var body: some View {
        NavigationSplitView {
            TorrentSidebar(
                sidebarState: store.sidebarState,
                selectedSelection: $selectedSidebarSelection,
                createLabel: { store.createLabel(named: $0) },
                renameLabel: { store.renameLabel(id: $0, to: $1) },
                deleteLabel: { store.deleteLabel(id: $0) }
            )
        } detail: {
            VStack(spacing: 0) {
                TorrentBrowser(
                    torrentState: torrentState,
                    selectionState: selectionState,
                    filterState: browserFilterState,
                    selection: selectedSidebarSelection,
                    labels: store.labels,
                    labelAssignments: store.labelAssignments,
                    showInfo: showTorrentInfo,
                    pause: store.pauseTorrents,
                    resume: store.resumeTorrents,
                    reannounce: store.reannounceTorrents,
                    forceRecheck: store.forceRecheckTorrents,
                    togglePause: store.togglePauseTorrent,
                    revealInFinder: store.revealTorrentsInFinder,
                    setQueuePriority: store.setQueuePriority,
                    moveInQueue: store.moveTorrentsInQueue,
                    toggleLabel: store.toggleLabel,
                    requestRemoval: requestTorrentRemoval,
                    addTorrent: { beginFileImport(.torrentFiles) }
                )

                FooterBarContainer(
                    torrentState: torrentState,
                    selectionState: selectionState,
                    displayedTorrentCount: browserFilterState.rows.count,
                    openNetworkSettings: openNetworkSettings,
                    openTransfersSettings: openTransfersSettings
                )
            }
        }
        .frame(minWidth: 1040, minHeight: 540)
        .searchable(
            text: boundedSearchText,
            isPresented: $isSearchPresented,
            placement: .toolbar,
            prompt: "Search Torrents"
        )
        .toolbar(removing: .title)
        .onAppear {
            store.clearCompletionBadge()
            configureCommandActions()
            presentNextTorrentAddDraftIfNeeded()
        }
        .onDisappear {
            commandActions.removeAllHandlers()
            sceneSaveTask?.cancel()
            addDraftPresentationTask?.cancel()
            fileImporterResetTask?.cancel()
            searchResetTask?.cancel()
        }
        .task(id: browserFilterRequestID) {
            let requestID = browserFilterRequestID
            browserFilterState.begin(requestID)
            do {
                let projection = try await TorrentBrowserProjection.prepare(
                    rows: torrentState.rows,
                    selection: requestID.selection,
                    query: requestID.query,
                    labels: store.labels,
                    labelAssignments: store.labelAssignments,
                    trackerHostsByTorrentID: store.trackerHostsByTorrentID
                )
                try Task.checkCancellation()
                while true {
                    let selectionRevision = selectionState.revision
                    let selectedIDs = selectionState.ids
                    let visibleSelection =
                        try await TorrentVisibleSelectionProjection.prepare(
                            selectedIDs: selectedIDs,
                            visibleIDs: projection.ids
                        )
                    try Task.checkCancellation()
                    guard requestID == browserFilterRequestID else {
                        return
                    }
                    guard selectionRevision == selectionState.revision else {
                        continue
                    }
                    guard browserFilterState.apply(
                        projection,
                        for: requestID
                    ) else {
                        return
                    }
                    selectionState.ids = visibleSelection.ids
                    break
                }
            } catch {
                return
            }
        }
        .task(id: pendingDownloadFolderURL) {
            guard let url = pendingDownloadFolderURL else {
                return
            }
            _ = await store.chooseDownloadFolder(url)
            guard !Task.isCancelled,
                  pendingDownloadFolderURL == url else {
                return
            }
            pendingDownloadFolderURL = nil
        }
        .task(id: nextTorrentFileIntakeRequestID) {
            guard let request = pendingTorrentFileIntakeRequests.first else {
                return
            }
            do {
                let batch = try await TorrentAddSourceParser.torrentFileDrafts(
                    from: request.urls,
                    maximumCount: request.urls.count
                )
                try Task.checkCancellation()
                guard pendingTorrentFileIntakeRequests.first?.id == request.id else {
                    return
                }
                pendingTorrentFileIntakeRequests.removeFirst()
                guard !batch.drafts.isEmpty else {
                    store.reportError("Only .torrent files can be added.")
                    return
                }
                enqueueTorrentAddDrafts(batch.drafts)
            } catch {
                return
            }
        }
        .task(id: nextMagnetIntakeRequestID) {
            guard let request = pendingMagnetIntakeRequests.first else {
                return
            }
            do {
                let preparation =
                    try await TorrentAddSourceParser.prepareMagnetDraft(
                        from: request.value
                    )
                try Task.checkCancellation()
                guard pendingMagnetIntakeRequests.first?.id == request.id else {
                    return
                }
                pendingMagnetIntakeRequests.removeFirst()
                if preparation.isTooLarge {
                    store.reportError(
                        TorrentStoreError.magnetTooLarge
                            .localizedDescription
                    )
                    return
                }
                guard let draft = preparation.draft else {
                    store.reportError("The magnet link is invalid.")
                    return
                }
                enqueuePreparedMagnet(draft)
            } catch {
                return
            }
        }
        .task(id: pendingRemovalIDs) {
            guard let ids = pendingRemovalIDs else {
                return
            }
            do {
                let downloadLocationPaths = store.downloadLocationPaths(
                    for: ids
                )
                let request =
                    try await TorrentRemovalConfirmationRequest.prepare(
                        requestedIDs: ids,
                        torrents: torrentState.torrents,
                        downloadLocationPaths: downloadLocationPaths
                    )
                try Task.checkCancellation()
                guard pendingRemovalIDs == ids else {
                    return
                }
                removalConfirmationRequest = request
                pendingRemovalIDs = nil
            } catch {
                return
            }
        }
        .toolbar {
            TorrentToolbar(
                commandState: commandState,
                addTorrent: { beginFileImport(.torrentFiles) },
                addMagnet: beginAddingMagnet,
                showInfo: showSelectedTorrentInfo,
                showOptions: showSelectedTorrentOptions,
                revealInFinder: store.revealSelectedTorrentsInFinder,
                pause: store.pauseSelectedTorrents,
                resume: store.resumeSelectedTorrents,
                remove: requestSelectedTorrentRemoval,
                setSortOrder: store.setSortOrder,
                setSortDirection: store.setSortDirection,
                openSettings: openSettings.callAsFunction
            )
        }
        .sheet(isPresented: $isAddingMagnet) {
            AddMagnetView(magnetURI: $magnetURI) {
                magnetURI = ""
                isAddingMagnet = false
            } add: { draft in
                enqueuePreparedMagnet(draft)
            }
        }
        .sheet(item: $activeTorrentAddDraft, onDismiss: presentNextTorrentAddDraftIfNeeded) { draft in
            AddTorrentConfirmationView(draft: draft) { options in
                confirmTorrentAdd(draft, options: options)
            } cancel: {
                activeTorrentAddDraft = nil
            }
            .environment(store)
        }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: fileImportMode.allowedContentTypes,
            allowsMultipleSelection: fileImportMode.allowsMultipleSelection
        ) { result in
            handleFileImport(result)
        }
        .fileDialogMessage(fileDialogMessage)
        .fileDialogConfirmationLabel(fileDialogConfirmationLabel)
        .alert("Torrent Error", isPresented: errorBinding) {
            Button("OK") {
                store.dismissLastError()
            }
        } message: {
            Text(store.lastError ?? "")
        }
        .confirmationDialog(removalConfirmationTitle, isPresented: removalConfirmationBinding) {
            Button(removeTorrentButtonTitle, role: .destructive) {
                guard let removalConfirmationRequest else {
                    return
                }
                store.removeTorrents(ids: removalConfirmationRequest.ids, deleteFiles: false)
                self.removalConfirmationRequest = nil
            }
            Button(removeTorrentAndDataButtonTitle, role: .destructive) {
                guard let removalConfirmationRequest else {
                    return
                }
                store.removeTorrents(ids: removalConfirmationRequest.ids, deleteFiles: true)
                self.removalConfirmationRequest = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalConfirmationMessage)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                scheduleSceneSave()
            } else {
                store.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.clearCompletionBadge()
            store.refresh()
        }
        .onOpenURL { url in
            handleOpenedURL(url)
        }
        .dropDestination(for: URL.self) { urls, _ in
            queueTorrentFiles(urls)
        }
        .onDropSessionUpdated { session in
            switch session.phase {
            case .entering:
                guard !didPlayDropHoverHaptic else {
                    return
                }
                didPlayDropHoverHaptic = true
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)

            case .exiting, .ended, .dataTransferCompleted:
                didPlayDropHoverHaptic = false

            case .active:
                break

            @unknown default:
                didPlayDropHoverHaptic = false
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            store.lastError != nil
        } set: { isPresented in
            if !isPresented {
                store.dismissLastError()
            }
        }
    }

    private var fileDialogMessage: Text? {
        switch fileImportMode {
        case .torrentFiles:
            nil
        case .downloadFolder:
            Text("Choose a dedicated folder. \(AppIdentity.displayName) can access files inside it.")
        }
    }

    private var fileDialogConfirmationLabel: Text? {
        switch fileImportMode {
        case .torrentFiles:
            nil
        case .downloadFolder:
            Text("Use Folder")
        }
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding {
            removalConfirmationRequest != nil
        } set: { isPresented in
            if !isPresented {
                removalConfirmationRequest = nil
            }
        }
    }

    private var removalConfirmationTitle: String {
        let count = removalConfirmationRequest?.count ?? 0
        return count == 1 ? "Remove Torrent?" : "Remove \(count) Torrents?"
    }

    private var browserFilterRequestID: TorrentBrowserFilterRequestID {
        TorrentBrowserFilterRequestID(
            rowRevision: torrentState.rowRevision,
            metadataRevision: store.torrentFilterRevision,
            selection: selectedSidebarSelection,
            query: searchText
        )
    }

    private var boundedSearchText: Binding<String> {
        Binding {
            searchText
        } set: { value in
            searchText = TorrentBrowserProjection.boundedQueryInput(value)
        }
    }

    private var nextTorrentFileIntakeRequestID: UUID? {
        pendingTorrentFileIntakeRequests.first?.id
    }

    private var nextMagnetIntakeRequestID: UUID? {
        pendingMagnetIntakeRequests.first?.id
    }

    private var availableTorrentAddCapacity: Int {
        let activeCount = activeTorrentAddDraft == nil ? 0 : 1
        let reservedFileCount =
            pendingTorrentFileIntakeRequests.reduce(into: 0) { count, request in
                count += request.urls.count
            }
        return max(
            0,
            Self.maximumPendingTorrentAddCount
                - activeCount
                - queuedTorrentAddDrafts.count
                - reservedFileCount
                - pendingMagnetIntakeRequests.count
        )
    }

    private var removeTorrentButtonTitle: String {
        removalConfirmationRequest?.count == 1 ? "Remove Torrent" : "Remove Torrents"
    }

    private var removeTorrentAndDataButtonTitle: String {
        removalConfirmationRequest?.count == 1
            ? "Remove Torrent and Delete Data Permanently"
            : "Remove Torrents and Delete Data Permanently"
    }

    private var removalConfirmationMessage: String {
        guard let removalConfirmationRequest else {
            return ""
        }
        if removalConfirmationRequest.count == 1,
           let path = removalConfirmationRequest.singleTorrentDownloadPath {
            return "Choose whether to keep the downloaded data at \(path). If removed, it will be deleted permanently."
        }
        if removalConfirmationRequest.count == 1 {
            return "Choose whether to keep the downloaded data. Data without a verified app-owned storage claim will be preserved."
        }

        return "Choose whether to keep the downloaded data for \(removalConfirmationRequest.count) torrents. If removed, it will be deleted permanently."
    }

    private func configureCommandActions() {
        commandActions.addTorrentFileHandler = { beginFileImport(.torrentFiles) }
        commandActions.addMagnetLinkHandler = beginAddingMagnet
        commandActions.chooseDownloadFolderHandler = { beginFileImport(.downloadFolder) }
        commandActions.showSelectedTorrentInfoHandler = showSelectedTorrentInfo
        commandActions.showSelectedTorrentOptionsHandler = showSelectedTorrentOptions
        commandActions.revealSelectedTorrentsInFinderHandler = store.revealSelectedTorrentsInFinder
        commandActions.pauseSelectedTorrentsHandler = store.pauseSelectedTorrents
        commandActions.resumeSelectedTorrentsHandler = store.resumeSelectedTorrents
        commandActions.requestSelectedTorrentRemovalHandler = requestSelectedTorrentRemoval
        commandActions.focusSearchHandler = focusSearch
    }

    private func handleOpenedURL(_ url: URL) {
        if url.scheme?.caseInsensitiveCompare("magnet") == .orderedSame {
            queueMagnetInput(url.absoluteString)
            return
        }

        queueTorrentFiles([url])
    }

    private func queueMagnetInput(_ magnet: String) {
        guard availableTorrentAddCapacity > 0 else {
            reportTorrentAddCapacityError()
            return
        }
        pendingMagnetIntakeRequests.append(
            TorrentMagnetPreparationRequest(value: magnet)
        )
    }

    private func enqueuePreparedMagnet(_ draft: TorrentAddDraft) {
        guard enqueueTorrentAddDrafts([draft]) else {
            return
        }
        magnetURI = ""
        isAddingMagnet = false
    }

    private func queueTorrentFiles(_ urls: [URL]) {
        guard !urls.isEmpty else {
            store.reportError("Only .torrent files can be added.")
            return
        }
        guard urls.count <= availableTorrentAddCapacity else {
            reportTorrentAddCapacityError()
            return
        }

        pendingTorrentFileIntakeRequests.append(
            TorrentFileIntakeRequest(urls: urls)
        )
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            return
        }

        switch fileImportMode {
        case .torrentFiles:
            queueTorrentFiles(urls)
        case .downloadFolder:
            guard let url = urls.first else {
                return
            }
            pendingDownloadFolderURL = url
        }
    }

    @discardableResult
    private func enqueueTorrentAddDrafts(_ drafts: [TorrentAddDraft]) -> Bool {
        guard !drafts.isEmpty else {
            return true
        }
        guard drafts.count <= availableTorrentAddCapacity else {
            reportTorrentAddCapacityError()
            return false
        }

        queuedTorrentAddDrafts.append(contentsOf: drafts)
        addDraftPresentationTask?.cancel()
        let taskID = UUID()
        addDraftPresentationTaskID = taskID
        addDraftPresentationTask = Task { @MainActor in
            defer {
                if addDraftPresentationTaskID == taskID {
                    addDraftPresentationTask = nil
                    addDraftPresentationTaskID = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  addDraftPresentationTaskID == taskID else {
                return
            }
            presentNextTorrentAddDraftIfNeeded()
        }
        return true
    }

    private func reportTorrentAddCapacityError() {
        store.reportError(
            "At most \(Self.maximumPendingTorrentAddCount) torrent additions can be pending."
        )
    }

    private func presentNextTorrentAddDraftIfNeeded() {
        guard activeTorrentAddDraft == nil, !queuedTorrentAddDrafts.isEmpty else {
            return
        }

        activeTorrentAddDraft = queuedTorrentAddDrafts.removeFirst()
    }

    private func confirmTorrentAdd(_ draft: TorrentAddDraft, options: TorrentAddOptions) -> Bool {
        let accepted: Bool
        switch draft.source {
        case .torrentFile(let url):
            guard let torrentData = options.torrentData else {
                return false
            }
            accepted = store.addTorrentFile(
                url,
                torrentData: torrentData,
                downloadFolder: options.downloadFolder,
                filePriorities: options.filePriorities,
                moveOriginalToTrash: options.movesTorrentFileToTrash,
                setsDownloadFolderAsDefault: options.setsDownloadFolderAsDefault,
                startsPaused: options.startsPaused,
                queuePriority: options.queuePriority,
                labelIDs: options.labelIDs,
                usesExistingData: options.storageMode == .useExistingData
            )
        case .magnet(let uri):
            accepted = store.addMagnet(
                uri,
                downloadFolder: options.downloadFolder,
                setsDownloadFolderAsDefault: options.setsDownloadFolderAsDefault,
                startsPaused: options.startsPaused,
                queuePriority: options.queuePriority,
                labelIDs: options.labelIDs,
                allowPreMetadataDHT: options.allowsPreMetadataDHT
            )
        }

        if accepted {
            activeTorrentAddDraft = nil
        }
        return accepted
    }

    private func beginFileImport(_ mode: FileImportMode) {
        isSearchPresented = false
        fileImportMode = mode
        if isChoosingFile {
            isChoosingFile = false
            fileImporterResetTask?.cancel()
            let taskID = UUID()
            fileImporterResetTaskID = taskID
            fileImporterResetTask = Task { @MainActor in
                defer {
                    if fileImporterResetTaskID == taskID {
                        fileImporterResetTask = nil
                        fileImporterResetTaskID = nil
                    }
                }
                await Task.yield()
                guard !Task.isCancelled,
                      fileImporterResetTaskID == taskID else {
                    return
                }
                fileImportMode = mode
                isChoosingFile = true
            }
        } else {
            isChoosingFile = true
        }
    }

    private func beginAddingMagnet() {
        isSearchPresented = false
        isAddingMagnet = true
    }

    private func focusSearch() {
        if isSearchPresented {
            isSearchPresented = false
            searchResetTask?.cancel()
            let taskID = UUID()
            searchResetTaskID = taskID
            searchResetTask = Task { @MainActor in
                defer {
                    if searchResetTaskID == taskID {
                        searchResetTask = nil
                        searchResetTaskID = nil
                    }
                }
                await Task.yield()
                guard !Task.isCancelled,
                      searchResetTaskID == taskID else {
                    return
                }
                isSearchPresented = true
            }
        } else {
            isSearchPresented = true
        }
    }

    private func scheduleSceneSave() {
        guard sceneSaveTask == nil else {
            return
        }
        let taskID = UUID()
        sceneSaveTaskID = taskID
        sceneSaveTask = Task { @MainActor in
            defer {
                if sceneSaveTaskID == taskID {
                    sceneSaveTask = nil
                    sceneSaveTaskID = nil
                }
            }
            await store.saveAll()
        }
    }

    private func showSelectedTorrentInfo() {
        guard let selectedTorrentID = store.selectedTorrent?.id else {
            return
        }
        showTorrentInfo(selectedTorrentID, tab: .general)
    }

    private func showSelectedTorrentOptions() {
        guard let selectedTorrentID = store.selectedTorrent?.id else {
            return
        }
        showTorrentInfo(selectedTorrentID, tab: .options)
    }

    private func showTorrentInfo(_ torrentID: TorrentItem.ID, tab: TorrentInfoTab) {
        store.selectTorrent(id: torrentID)
        store.requestTorrentInfoTab(tab, for: torrentID)
        openWindow(value: torrentID)
    }

    private func requestSelectedTorrentRemoval() {
        guard commandState.snapshot.hasSelectedTorrents else {
            return
        }
        requestTorrentRemoval(store.selectedTorrentIDs)
    }

    private func requestTorrentRemoval(_ torrentIDs: Set<TorrentItem.ID>) {
        store.selectTorrents(ids: torrentIDs)
        pendingRemovalIDs = torrentIDs
    }

    private func openNetworkSettings() {
        store.selectedSettingsTab = .network
        openSettings()
    }

    private func openTransfersSettings() {
        store.selectedSettingsTab = .transfers
        openSettings()
    }
}

private struct TorrentFileIntakeRequest: Identifiable, Sendable {
    let id = UUID()
    let urls: [URL]
}

private struct TorrentRemovalConfirmationRequest: Sendable {
    let ids: Set<TorrentItem.ID>
    let count: Int
    let singleTorrentDownloadPath: String?

    @concurrent
    static func prepare(
        requestedIDs: Set<TorrentItem.ID>,
        torrents: [TorrentItem],
        downloadLocationPaths: [TorrentItem.ID: String]
    ) async throws -> Self? {
        try Task.checkCancellation()
        var retainedIDs = Set<TorrentItem.ID>()
        retainedIDs.reserveCapacity(min(requestedIDs.count, torrents.count))
        var singleTorrentDownloadPath: String?
        for (offset, torrent) in torrents.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            guard requestedIDs.contains(torrent.id) else {
                continue
            }
            retainedIDs.insert(torrent.id)
            singleTorrentDownloadPath = retainedIDs.count == 1
                ? downloadLocationPaths[torrent.id]
                : nil
        }
        try Task.checkCancellation()
        guard !retainedIDs.isEmpty else {
            return nil
        }
        return Self(
            ids: retainedIDs,
            count: retainedIDs.count,
            singleTorrentDownloadPath: retainedIDs.count == 1
                ? singleTorrentDownloadPath
                : nil
        )
    }
}
