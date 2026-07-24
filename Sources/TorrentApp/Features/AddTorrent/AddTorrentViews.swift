import SwiftUI
import TorrentEngineModel
import UniformTypeIdentifiers

struct AddMagnetView: View {
    @Binding var magnetURI: String
    let cancel: () -> Void
    let add: (TorrentAddDraft) -> Void

    @State private var preparation: TorrentMagnetDraftPreparation?
    @State private var preparationRequest: TorrentMagnetPreparationRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Magnet Link")
                .font(.title2.weight(.semibold))

            TextField("magnet:?", text: $magnetURI, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4...8)
                .frame(minWidth: 520)
                .accessibilityLabel("Magnet link")
                .accessibilityHint("Enter a magnet link beginning with magnet:?.")

            if isTooLarge {
                Label(TorrentStoreError.magnetTooLarge.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Add") {
                    guard let draft = preparation?.draft else {
                        return
                    }
                    add(draft)
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(24)
        .onChange(of: magnetURI, initial: true) { _, value in
            preparation = nil
            preparationRequest =
                TorrentMagnetPreparationRequest(value: value)
        }
        .task(id: preparationRequest?.id) {
            guard let request = preparationRequest else {
                return
            }
            do {
                let prepared =
                    try await TorrentAddSourceParser.prepareMagnetDraft(
                        from: request.value
                    )
                try Task.checkCancellation()
                guard preparationRequest?.id == request.id else {
                    return
                }
                preparation = prepared
                preparationRequest = nil
            } catch {
                return
            }
        }
    }

    private var isTooLarge: Bool {
        preparation?.isTooLarge == true
    }

    private var canAdd: Bool {
        preparation?.draft != nil
    }
}

struct TorrentAddFileSelectionPresentation: Sendable {
    let generation: UInt64
    let filePriorities: [Int32: TorrentFilePriority]?
    let selectedFileCount: Int
    let selectedFileSize: Int64

    var hasDownloadableFile: Bool {
        selectedFileCount > 0
    }

    @concurrent
    static func prepare(
        generation: UInt64,
        files: [TorrentFileItem],
        bulkPriority: TorrentFilePriority?,
        overrides: [Int32: TorrentFilePriority]
    ) async throws -> Self {
        try Task.checkCancellation()
        var priorities = [Int32: TorrentFilePriority]()
        priorities.reserveCapacity(
            bulkPriority == nil ? overrides.count : files.count
        )
        var selectedFileCount = 0
        var selectedFileSize: Int64 = 0

        for (offset, file) in files.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            let priority = overrides[file.index]
                ?? bulkPriority
                ?? .normal
            if priority != .normal {
                priorities[file.index] = priority
            }
            guard priority != .skip else {
                continue
            }
            selectedFileCount += 1
            let size = max(0, file.size)
            selectedFileSize = selectedFileSize > Int64.max - size
                ? .max
                : selectedFileSize + size
        }

        try Task.checkCancellation()
        return Self(
            generation: generation,
            filePriorities: priorities.isEmpty ? nil : priorities,
            selectedFileCount: selectedFileCount,
            selectedFileSize: selectedFileSize
        )
    }
}

struct AddTorrentConfirmationView: View {
    private static let fileSelectionPreviewLimit = 5

    @Environment(TorrentStore.self) private var store
    let draft: TorrentAddDraft
    let add: (TorrentAddOptions) -> Bool
    let cancel: () -> Void

    @State private var isChoosingDownloadFolder = false
    @State private var showsAllPreviewFiles = false
    @State private var isLoadingPreview = false
    @State private var preview: TorrentFilePreview?
    @State private var previewError: String?
    @State private var magnetSourceSecuritySummary:
        TorrentSourceSecuritySummary?
    @State private var filePriorities = [Int32: TorrentFilePriority]()
    @State private var bulkFilePriority: TorrentFilePriority?
    @State private var fileSelectionGeneration: UInt64 = 0
    @State private var fileSelectionPresentation:
        TorrentAddFileSelectionPresentation?
    @State private var selectedDownloadFolder: URL?
    @State private var isMagnetLinkExpanded = true
    @State private var movesTorrentFileToTrash = false
    @State private var setsDownloadFolderAsDefault = false
    @State private var queuePriority = TorrentQueuePriority.normal
    @State private var selectedLabelIDs = Set<TorrentLabel.ID>()
    @State private var allowsPreMetadataDHT = false
    @State private var folderError: String?
    @State private var pendingDownloadFolderURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Name", value: displayName)
                    if draft.fileURL != nil {
                        InfoDetailRow("Info hash") {
                            previewInfoHashValue
                        }
                    }

                    InfoDetailRow("Download folder") {
                        DownloadFolderPickerValueView(
                            text: downloadFolderText,
                            isUnset: selectedDownloadFolder == nil
                        ) {
                            isChoosingDownloadFolder = true
                        }
                    }

                    if let folderError {
                        Text(folderError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    setDefaultDownloadFolderToggle
                    TorrentLabelSelectionRow(
                        labels: store.labels,
                        selectedLabelIDs: $selectedLabelIDs,
                        createLabel: store.createLabel
                    )
                }

                if draft.fileURL != nil {
                    Section {
                        queuePriorityPicker
                        Toggle("Move .torrent file to Trash after adding", isOn: $movesTorrentFileToTrash)
                    }

                    sourcePolicySection

                    fileSelectionSection
                } else if let magnetURI = draft.magnetURI {
                    Section {
                        queuePriorityPicker
                    }

                    sourcePolicySection

                    Section("Magnet") {
                        DisclosureGroup("Magnet link", isExpanded: $isMagnetLinkExpanded) {
                            Text(magnetURI)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)
                        }

                        Label(
                            "Files and sizes appear after adding, once metadata is fetched from peers.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Add Paused") {
                    confirmAdd(startsPaused: true)
                }
                .disabled(isAddDisabled)

                Button("Add") {
                    confirmAdd(startsPaused: false)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAddDisabled)
            }
            .padding()
            .background(.bar)
        }
        .frame(width: 620, height: 520)
        .onAppear {
            selectedDownloadFolder = store.downloadFolder
        }
        .task(id: draft.id) {
            await loadDraftPresentation(for: draft.id)
        }
        .task(id: fileSelectionGeneration) {
            guard let preview else {
                fileSelectionPresentation = nil
                return
            }
            let generation = fileSelectionGeneration
            do {
                let presentation =
                    try await TorrentAddFileSelectionPresentation.prepare(
                        generation: generation,
                        files: preview.visibleFiles,
                        bulkPriority: bulkFilePriority,
                        overrides: filePriorities
                    )
                try Task.checkCancellation()
                guard generation == fileSelectionGeneration else {
                    return
                }
                fileSelectionPresentation = presentation
            } catch {
                return
            }
        }
        .task(id: pendingDownloadFolderURL) {
            guard let url = pendingDownloadFolderURL else {
                return
            }
            let result = await store.validateDownloadFolderSelection(url)
            guard !Task.isCancelled,
                  pendingDownloadFolderURL == url else {
                return
            }
            switch result {
            case .success:
                selectedDownloadFolder = url
                folderError = nil
            case .failure(let error):
                folderError = error.localizedDescription
            }
            pendingDownloadFolderURL = nil
        }
        .onChange(of: selectedDownloadFolder) { _, _ in
            if isSetDefaultToggleDisabled {
                setsDownloadFolderAsDefault = false
            }
        }
        .fileImporter(
            isPresented: $isChoosingDownloadFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleDownloadFolderImport(result)
        }
        .fileDialogMessage(Text("Choose a dedicated folder for downloads."))
        .fileDialogConfirmationLabel(Text("Use Folder"))
    }

    @ViewBuilder
    private var sourcePolicySection: some View {
        if draft.magnetURI != nil && magnetSourceSecuritySummary == nil {
            Section {
                HStack {
                    Label("Checking Sources", systemImage: "checkmark.shield")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            }
        } else if let sourceSecuritySummary,
                  showsSourcePolicySection(for: sourceSecuritySummary) {
            Section {
                if store.settings.useHTTPSTrackersOnly && sourceSecuritySummary.hasNonHTTPSTrackers {
                    sourcePolicyRow(
                        count: sourceSecuritySummary.nonHTTPSTrackerCount,
                        singular: "tracker",
                        needsPrompt: sourceSecuritySummary.needsTrackerExceptionPrompt,
                        noHTTPSMessage: "This torrent has no HTTPS trackers. Non-HTTPS trackers will be ignored."
                    )
                }

                if store.settings.useHTTPSWebSeedsOnly && sourceSecuritySummary.hasNonHTTPSWebSeeds {
                    sourcePolicyRow(
                        count: sourceSecuritySummary.nonHTTPSWebSeedCount,
                        singular: "web seed",
                        needsPrompt: sourceSecuritySummary.needsWebSeedExceptionPrompt,
                        noHTTPSMessage: "This torrent has no HTTPS web seeds. Non-HTTPS web seeds will be ignored."
                    )
                }

                if needsPreMetadataDHTConsent(for: sourceSecuritySummary) {
                    Toggle("Use DHT to fetch metadata", isOn: $allowsPreMetadataDHT)
                        .disabled(!store.settings.enableDHTNetwork)

                    Text(store.settings.enableDHTNetwork
                         ? "This magnet has no usable tracker. Enabling DHT shares its info hash with the public DHT before its metadata can be checked."
                         : "This magnet has no usable tracker and the DHT network is disabled in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Label(
                    "After adding, use Get Info > Options to adjust discovery, or Sources to review trackers and web seeds.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func sourcePolicyRow(
        count: Int,
        singular: String,
        needsPrompt: Bool,
        noHTTPSMessage: String
    ) -> some View {
        if needsPrompt {
            Label(noHTTPSMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else {
            Label(
                "\(count) non-HTTPS \(pluralized(singular, count: count)) will be ignored.",
                systemImage: "info.circle"
            )
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var fileSelectionSection: some View {
        Section {
            if let previewError {
                Text(previewError)
                    .foregroundStyle(.red)
            } else if let preview {
                fileSummaryRow(for: preview)

                if preview.visibleFiles.isEmpty {
                    Label("No Files", systemImage: "doc")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visiblePreviewFiles(for: preview)) { file in
                        AddTorrentFilePriorityRow(
                            file: file,
                            priority: filePriorityBinding(for: file)
                        )
                    }

                    if shouldShowPreviewFileLimitControl(for: preview) {
                        SourceLimitButton(isShowingAll: showsAllPreviewFiles) {
                            showsAllPreviewFiles.toggle()
                        }
                    }
                }
            } else {
                HStack {
                    Label("Loading Files", systemImage: "doc")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var previewInfoHashValue: some View {
        if let preview {
            InfoHashValueView(infoHash: preview.id)
        } else if previewError != nil {
            Text("Unavailable")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                Text("Loading")
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func fileSummaryRow(for preview: TorrentFilePreview) -> some View {
        HStack(spacing: 8) {
            Text("Files")

            Spacer(minLength: 12)

            Text(fileSummary(for: preview))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)

            if !preview.visibleFiles.isEmpty {
                Menu {
                    ForEach(TorrentFilePriority.allCases) { priority in
                        Button(priority.title) {
                            setAllFiles(in: preview, to: priority)
                        }
                    }
                } label: {
                    Text("Set All")
                }
                .fixedSize()
                .help("Set priority for all files")
            }
        }
    }

    private var displayName: String {
        if let preview {
            return preview.name
        }
        return draft.title
    }

    private var downloadFolderText: String {
        selectedDownloadFolder?.torrentFilePath ?? "Not set"
    }

    private var sourceSecuritySummary: TorrentSourceSecuritySummary? {
        if let preview {
            return preview.sourceSecuritySummary
        }
        return magnetSourceSecuritySummary
    }

    @ViewBuilder
    private var setDefaultDownloadFolderToggle: some View {
        if isSelectedDownloadFolderCurrentDefault {
            LabeledContent("Set as default folder for future downloads") {
                Label("Already set", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        } else {
            Toggle("Set as default folder for future downloads", isOn: $setsDownloadFolderAsDefault)
                .disabled(selectedDownloadFolder == nil)
                .foregroundStyle(selectedDownloadFolder == nil ? Color.secondary : Color.primary)
                .opacity(selectedDownloadFolder == nil ? 0.55 : 1)
        }
    }

    private var queuePriorityPicker: some View {
        Picker("Queue priority", selection: $queuePriority) {
            ForEach(TorrentQueuePriority.allCases) { priority in
                Text(priority.title).tag(priority)
            }
        }
    }

    private var isAddDisabled: Bool {
        if selectedDownloadFolder == nil {
            return true
        }
        guard draft.fileURL != nil else {
            return magnetSourceSecuritySummary == nil
        }
        return isLoadingPreview
            || preview == nil
            || previewError != nil
            || fileSelectionPresentation?.generation
                != fileSelectionGeneration
            || fileSelectionPresentation?.hasDownloadableFile != true
    }

    private var isSetDefaultToggleDisabled: Bool {
        selectedDownloadFolder == nil || isSelectedDownloadFolderCurrentDefault
    }

    private var isSelectedDownloadFolderCurrentDefault: Bool {
        store.isCurrentDownloadFolder(selectedDownloadFolder)
    }

    private var filePrioritiesForAdd: [Int32: TorrentFilePriority]? {
        guard draft.fileURL != nil,
              fileSelectionPresentation?.generation
                == fileSelectionGeneration else {
            return nil
        }
        return fileSelectionPresentation?.filePriorities
    }

    private func fileSummary(for preview: TorrentFilePreview) -> String {
        let selectedCount =
            fileSelectionPresentation?.selectedFileCount
            ?? preview.visibleFileCount
        let totalCount = preview.visibleFileCount
        let fileText = "\(totalCount) \(totalCount == 1 ? "file" : "files")"
        let selectedSize =
            fileSelectionPresentation?.selectedFileSize
            ?? preview.visibleFileSize

        if selectedCount == 0 {
            return "0 of \(fileText) · Nothing selected"
        }

        let sizeText = ByteFormat.size(selectedSize)
        guard totalCount > 0, selectedCount != totalCount else {
            return "\(fileText) · \(sizeText)"
        }
        return "\(selectedCount) of \(fileText) · \(sizeText) selected"
    }

    private func visiblePreviewFiles(for preview: TorrentFilePreview) -> [TorrentFileItem] {
        guard !showsAllPreviewFiles else {
            return preview.visibleFiles
        }
        return Array(preview.visibleFiles.prefix(Self.fileSelectionPreviewLimit))
    }

    private func shouldShowPreviewFileLimitControl(for preview: TorrentFilePreview) -> Bool {
        preview.visibleFiles.count > Self.fileSelectionPreviewLimit
    }

    private func filePriority(for file: TorrentFileItem) -> TorrentFilePriority {
        filePriorities[file.index] ?? bulkFilePriority ?? .normal
    }

    private func setAllFiles(
        in _: TorrentFilePreview,
        to priority: TorrentFilePriority
    ) {
        bulkFilePriority = priority
        filePriorities.removeAll(keepingCapacity: true)
        advanceFileSelectionGeneration()
    }

    private func filePriorityBinding(for file: TorrentFileItem) -> Binding<TorrentFilePriority> {
        Binding {
            filePriority(for: file)
        } set: { priority in
            if priority == (bulkFilePriority ?? .normal) {
                filePriorities.removeValue(forKey: file.index)
            } else {
                filePriorities[file.index] = priority
            }
            advanceFileSelectionGeneration()
        }
    }

    @MainActor
    private func loadDraftPresentation(
        for draftID: TorrentAddDraft.ID
    ) async {
        magnetSourceSecuritySummary = nil
        guard let magnetURI = draft.magnetURI else {
            await loadPreview(for: draftID)
            return
        }
        do {
            let summary =
                try await TorrentSourceSecurityInspector.prepareSummary(
                    magnetURI: magnetURI
                )
            try Task.checkCancellation()
            guard draft.id == draftID else {
                return
            }
            magnetSourceSecuritySummary = summary
        } catch {
            return
        }
    }

    @MainActor
    private func loadPreview(for draftID: TorrentAddDraft.ID) async {
        guard let fileURL = draft.fileURL else {
            return
        }
        guard draft.id == draftID, !Task.isCancelled else {
            return
        }

        isLoadingPreview = true
        previewError = nil
        preview = nil
        fileSelectionPresentation = nil
        showsAllPreviewFiles = false
        filePriorities.removeAll()
        bulkFilePriority = nil
        advanceFileSelectionGeneration()

        do {
            let loadedPreview = try await store.previewTorrentFile(fileURL)
            guard draft.id == draftID, !Task.isCancelled else {
                return
            }
            preview = loadedPreview
            filePriorities.removeAll(keepingCapacity: true)
            bulkFilePriority = nil
            advanceFileSelectionGeneration()
        } catch is CancellationError {
            return
        } catch {
            guard draft.id == draftID, !Task.isCancelled else {
                return
            }
            previewError = error.localizedDescription
        }
        guard draft.id == draftID, !Task.isCancelled else {
            return
        }
        isLoadingPreview = false
    }

    private func advanceFileSelectionGeneration() {
        precondition(fileSelectionGeneration != UInt64.max)
        fileSelectionGeneration += 1
    }

    private func handleDownloadFolderImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            return
        }

        pendingDownloadFolderURL = url
    }

    private func confirmAdd(startsPaused: Bool) {
        guard let downloadFolder = selectedDownloadFolder else {
            return
        }
        let accepted = add(TorrentAddOptions(
            downloadFolder: downloadFolder,
            torrentData: preview?.torrentData,
            filePriorities: filePrioritiesForAdd,
            movesTorrentFileToTrash: draft.fileURL != nil && movesTorrentFileToTrash,
            setsDownloadFolderAsDefault: setsDownloadFolderAsDefault,
            startsPaused: startsPaused,
            queuePriority: queuePriority,
            labelIDs: selectedLabelIDs,
            allowsPreMetadataDHT: allowsPreMetadataDHT
        ))
        if !accepted {
            folderError = store.lastError ?? TorrentStoreError.tooManyPendingOperations.localizedDescription
        }
    }

    private func showsSourcePolicySection(for summary: TorrentSourceSecuritySummary) -> Bool {
        (store.settings.useHTTPSTrackersOnly && summary.hasNonHTTPSTrackers)
            || (store.settings.useHTTPSWebSeedsOnly && summary.hasNonHTTPSWebSeeds)
            || needsPreMetadataDHTConsent(for: summary)
    }

    private func needsPreMetadataDHTConsent(for summary: TorrentSourceSecuritySummary) -> Bool {
        guard draft.magnetURI != nil else {
            return false
        }
        return store.settings.useHTTPSTrackersOnly
            ? summary.httpsTrackerCount == 0
            : summary.trackerCount == 0
    }

    private func pluralized(_ singular: String, count: Int) -> String {
        count == 1 ? singular : "\(singular)s"
    }
}

private struct AddTorrentFilePriorityRow: View {
    let file: TorrentFileItem
    @Binding var priority: TorrentFilePriority

    var body: some View {
        HStack(spacing: 8) {
            Text(file.path)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            Text(ByteFormat.size(file.size))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()

            Picker("Priority", selection: $priority) {
                ForEach(TorrentFilePriority.allCases) { priority in
                    Text(priority.title).tag(priority)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Priority for \(file.path)")
        }
        .help(file.path)
    }
}
