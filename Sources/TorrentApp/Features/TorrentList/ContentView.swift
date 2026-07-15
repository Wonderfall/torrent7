import AppKit
import SwiftUI

struct ContentView: View {
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
    @State private var queuedTorrentAddDrafts = [TorrentAddDraft]()
    @State private var activeTorrentAddDraft: TorrentAddDraft?
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var selectedSidebarSelection = TorrentSidebarSelection.all
    @State private var didPlayDropHoverHaptic = false

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
                    selection: selectedSidebarSelection,
                    searchText: searchText,
                    labels: store.labels,
                    labelIDsForTorrent: { store.labelIDs(for: $0) },
                    labelsForTorrent: { store.labels(for: $0) },
                    trackerHostsForTorrent: { store.trackerHosts(for: $0) },
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
                    selection: selectedSidebarSelection,
                    searchText: searchText,
                    labelIDsForTorrent: { store.labelIDs(for: $0) },
                    trackerHostsForTorrent: { store.trackerHosts(for: $0) },
                    openNetworkSettings: openNetworkSettings,
                    openTransfersSettings: openTransfersSettings
                )
            }
        }
        .frame(minWidth: 1040, minHeight: 540)
        .searchable(text: $searchText, isPresented: $isSearchPresented, placement: .toolbar, prompt: "Search Torrents")
        .toolbar(removing: .title)
        .onAppear {
            store.clearCompletionBadge()
            configureCommandActions()
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
            } add: {
                queueMagnet(magnetURI)
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
                Task {
                    await store.saveAll()
                }
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
        .dropDestination(for: URL.self, action: { urls, _ in
            let torrentURLs = urls.filter { $0.pathExtension.caseInsensitiveCompare("torrent") == .orderedSame }
            guard !torrentURLs.isEmpty else {
                return false
            }
            queueTorrentFiles(torrentURLs)
            return true
        }, isTargeted: { isTargeted in
            if isTargeted {
                guard !didPlayDropHoverHaptic else {
                    return
                }
                didPlayDropHoverHaptic = true
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            } else {
                didPlayDropHoverHaptic = false
            }
        })
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
        if removalConfirmationRequest.count == 1, let savePath = removalConfirmationRequest.singleTorrentSavePath {
            return "Choose whether to keep the downloaded data in \(savePath). If removed, it will be deleted permanently."
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
            queueMagnet(url.absoluteString)
            return
        }

        queueTorrentFiles([url])
    }

    private func queueMagnet(_ magnet: String) {
        if magnet.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > TorrentInputLimits.maxMagnetURIBytes {
            store.reportError(TorrentStoreError.magnetTooLarge.localizedDescription)
            return
        }

        guard let draft = TorrentAddSourceParser.magnetDraft(from: magnet) else {
            return
        }

        magnetURI = ""
        isAddingMagnet = false
        enqueueTorrentAddDrafts([draft])
    }

    private func queueTorrentFiles(_ urls: [URL]) {
        let drafts = TorrentAddSourceParser.torrentFileDrafts(from: urls)
        guard !drafts.isEmpty else {
            store.reportError("Only .torrent files can be added.")
            return
        }

        enqueueTorrentAddDrafts(drafts)
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
            _ = store.chooseDownloadFolder(url)
        }
    }

    private func enqueueTorrentAddDrafts(_ drafts: [TorrentAddDraft]) {
        queuedTorrentAddDrafts.append(contentsOf: drafts)
        Task { @MainActor in
            await Task.yield()
            presentNextTorrentAddDraftIfNeeded()
        }
    }

    private func presentNextTorrentAddDraftIfNeeded() {
        guard activeTorrentAddDraft == nil, !queuedTorrentAddDrafts.isEmpty else {
            return
        }

        activeTorrentAddDraft = queuedTorrentAddDrafts.removeFirst()
    }

    private func confirmTorrentAdd(_ draft: TorrentAddDraft, options: TorrentAddOptions) {
        switch draft.source {
        case .torrentFile(let url):
            guard let torrentData = options.torrentData else {
                return
            }
            store.addTorrentFile(
                url,
                torrentData: torrentData,
                downloadFolder: options.downloadFolder,
                filePriorities: options.filePriorities,
                moveOriginalToTrash: options.movesTorrentFileToTrash,
                setsDownloadFolderAsDefault: options.setsDownloadFolderAsDefault,
                startsPaused: options.startsPaused,
                queuePriority: options.queuePriority,
                labelIDs: options.labelIDs
            )
        case .magnet(let uri):
            store.addMagnet(
                uri,
                downloadFolder: options.downloadFolder,
                setsDownloadFolderAsDefault: options.setsDownloadFolderAsDefault,
                startsPaused: options.startsPaused,
                queuePriority: options.queuePriority,
                labelIDs: options.labelIDs,
                allowPreMetadataDHT: options.allowsPreMetadataDHT
            )
        }

        activeTorrentAddDraft = nil
    }

    private func beginFileImport(_ mode: FileImportMode) {
        isSearchPresented = false
        fileImportMode = mode
        if isChoosingFile {
            isChoosingFile = false
            Task { @MainActor in
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
            Task { @MainActor in
                await Task.yield()
                isSearchPresented = true
            }
        } else {
            isSearchPresented = true
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
        let torrents = torrentState.torrents.filter { torrentIDs.contains($0.id) }
        guard !torrents.isEmpty else {
            return
        }
        removalConfirmationRequest = TorrentRemovalConfirmationRequest(
            ids: Set(torrents.map(\.id)),
            count: torrents.count,
            singleTorrentSavePath: torrents.count == 1 ? torrents[0].savePath : nil
        )
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

private struct TorrentRemovalConfirmationRequest {
    let ids: Set<TorrentItem.ID>
    let count: Int
    let singleTorrentSavePath: String?
}
