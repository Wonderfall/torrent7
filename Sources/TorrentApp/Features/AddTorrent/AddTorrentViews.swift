import SwiftUI
import UniformTypeIdentifiers

struct AddMagnetView: View {
    @Binding var magnetURI: String
    let cancel: () -> Void
    let add: () -> Void

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
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(24)
    }

    private var trimmedMagnetURI: String {
        magnetURI.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isTooLarge: Bool {
        trimmedMagnetURI.utf8.count > TorrentInputLimits.maxMagnetURIBytes
    }

    private var canAdd: Bool {
        trimmedMagnetURI.range(of: "magnet:?", options: [.caseInsensitive, .anchored]) != nil && !isTooLarge
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
    @State private var filePriorities = [Int32: TorrentFilePriority]()
    @State private var selectedDownloadFolder: URL?
    @State private var isMagnetLinkExpanded = true
    @State private var movesTorrentFileToTrash = false
    @State private var setsDownloadFolderAsDefault = false
    @State private var queuePriority = TorrentQueuePriority.normal
    @State private var selectedLabelIDs = Set<TorrentLabel.ID>()
    @State private var allowsPreMetadataDHT = false
    @State private var folderError: String?

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
            await loadPreview()
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
        if let sourceSecuritySummary, showsSourcePolicySection(for: sourceSecuritySummary) {
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
        selectedDownloadFolder?.path ?? "Not set"
    }

    private var sourceSecuritySummary: TorrentSourceSecuritySummary? {
        if let preview {
            return preview.sourceSecuritySummary
        }

        if let magnetURI = draft.magnetURI {
            return TorrentSourceSecurityParser.summary(magnetURI: magnetURI)
        }

        return nil
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
            return false
        }
        return isLoadingPreview || preview == nil || previewError != nil || !hasDownloadablePreviewFile
    }

    private var isSetDefaultToggleDisabled: Bool {
        selectedDownloadFolder == nil || isSelectedDownloadFolderCurrentDefault
    }

    private var isSelectedDownloadFolderCurrentDefault: Bool {
        store.isCurrentDownloadFolder(selectedDownloadFolder)
    }

    private var filePrioritiesForAdd: [Int32: TorrentFilePriority]? {
        guard let preview, draft.fileURL != nil else {
            return nil
        }

        let priorities = Dictionary(uniqueKeysWithValues: preview.visibleFiles.map { file in
            (file.index, filePriority(for: file))
        })
        guard priorities.contains(where: { $0.value != .normal }) else {
            return nil
        }
        return priorities
    }

    private func fileSummary(for preview: TorrentFilePreview) -> String {
        let selectedFiles = preview.visibleFiles.filter { filePriority(for: $0) != .skip }
        let selectedCount = selectedFiles.count
        let totalCount = preview.visibleFileCount
        let fileText = "\(totalCount) \(totalCount == 1 ? "file" : "files")"
        let selectedSize = selectedFiles
            .reduce(Int64(0)) { total, file in
                total + max(0, file.size)
            }

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

    private var hasDownloadablePreviewFile: Bool {
        guard let preview else {
            return false
        }
        return preview.visibleFiles.contains { filePriority(for: $0) != .skip }
    }

    private func filePriority(for file: TorrentFileItem) -> TorrentFilePriority {
        filePriorities[file.index] ?? .normal
    }

    private func setAllFiles(in preview: TorrentFilePreview, to priority: TorrentFilePriority) {
        for file in preview.visibleFiles {
            filePriorities[file.index] = priority
        }
    }

    private func filePriorityBinding(for file: TorrentFileItem) -> Binding<TorrentFilePriority> {
        Binding {
            filePriority(for: file)
        } set: { priority in
            filePriorities[file.index] = priority
        }
    }

    @MainActor
    private func loadPreview() async {
        guard let fileURL = draft.fileURL else {
            return
        }

        isLoadingPreview = true
        previewError = nil
        preview = nil
        showsAllPreviewFiles = false
        filePriorities.removeAll()

        do {
            let loadedPreview = try await store.previewTorrentFile(fileURL)
            preview = loadedPreview
            filePriorities = Dictionary(uniqueKeysWithValues: loadedPreview.visibleFiles.map { file in
                (file.index, TorrentFilePriority.normal)
            })
        } catch {
            previewError = error.localizedDescription
        }
        isLoadingPreview = false
    }

    private func handleDownloadFolderImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            return
        }

        switch store.validateDownloadFolderSelection(url) {
        case .success:
            selectedDownloadFolder = url
            folderError = nil
        case .failure(let error):
            folderError = error.localizedDescription
        }
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
