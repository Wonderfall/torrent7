import SwiftUI
import TorrentEngineModel

struct TorrentInfoWindow: View {
    @Environment(TorrentStore.self) private var store
    @Binding var torrentID: String?
    let torrentState: TorrentListState

    var body: some View {
        Group {
            if let torrent {
                TorrentInfoView(torrent: torrent, tabRequest: store.torrentInfoTabRequest(for: torrent.id))
            } else {
                ContentUnavailableView("Torrent Unavailable", systemImage: "info.circle")
            }
        }
        .frame(
            minWidth: 500,
            idealWidth: 560,
            maxWidth: .infinity,
            minHeight: 560,
            idealHeight: 640,
            maxHeight: .infinity
        )
    }

    private var torrent: TorrentItem? {
        guard let torrentID else {
            return nil
        }

        return torrentState.torrents.first { $0.id == torrentID }
    }
}

private enum TorrentInfoFileGroup: CaseIterable, Identifiable {
    case complete
    case downloading
    case skipped

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .complete:
            return "Complete"
        case .downloading:
            return "Downloading"
        case .skipped:
            return "Skipped"
        }
    }

    var systemImage: String {
        switch self {
        case .complete:
            return "checkmark.circle"
        case .downloading:
            return "arrow.down.circle"
        case .skipped:
            return "slash.circle"
        }
    }

    func contains(_ file: TorrentFileItem) -> Bool {
        switch self {
        case .complete:
            return !file.isSkipped && file.progress >= 1
        case .downloading:
            return !file.isSkipped && file.progress < 1
        case .skipped:
            return file.isSkipped
        }
    }
}

private struct TorrentInfoView: View {
    private static let sourceListLimit = 20
    private static let fileListLimit = 100

    @Environment(TorrentStore.self) private var store
    let torrent: TorrentItem
    let tabRequest: TorrentInfoTabRequest?
    @State private var selectedTab = TorrentInfoTab.general
    @State private var trackers = [TorrentTrackerItem]()
    @State private var webSeeds = [TorrentWebSeedItem]()
    @State private var webSeedActivity = TorrentWebSeedActivity.empty
    @State private var peerSources = TorrentPeerSources.empty
    @State private var sourcePolicy: TorrentSourcePolicy?
    @State private var sourcePolicyMutationGeneration: UInt64 = 0
    @State private var sourcePolicyMutationTask: Task<Void, Never>?
    @State private var torrentOptions: TorrentOptions?
    @State private var files = [TorrentFileItem]()
    @State private var pieceMap = TorrentPieceMap.empty
    @State private var trackerRevision: UInt64?
    @State private var webSeedRevision: UInt64?
    @State private var fileRevision: UInt64?
    @State private var pieceMapRevision: UInt64?
    @State private var sourcesLoaded = false
    @State private var optionsLoaded = false
    @State private var filesLoaded = false
    @State private var pieceMapLoaded = false
    @State private var sourceError: String?
    @State private var optionsError: String?
    @State private var fileError: String?
    @State private var pieceMapError: String?
    @State private var showsAllTrackers = false
    @State private var showsAllWebSeeds = false
    @State private var showsAllFiles = false

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("General", systemImage: "info.circle", value: .general) {
                generalTab
            }

            Tab("Sources", systemImage: "globe", value: .sources) {
                sourcesTab
            }

            Tab("Files", systemImage: "doc", value: .files) {
                filesTab
            }

            Tab("Pieces", systemImage: "square.grid.3x3", value: .pieces) {
                piecesTab
            }

            Tab("Options", systemImage: "slider.horizontal.3", value: .options) {
                optionsTab
            }
        }
        .scenePadding()
        .task(id: sourcesRefreshID) {
            guard selectedTab == .sources else {
                return
            }
            await refreshSources()
        }
        .task(id: optionsRefreshID) {
            guard selectedTab == .options else {
                return
            }
            await refreshOptions()
        }
        .task(id: filesRefreshID) {
            guard selectedTab == .files else {
                return
            }
            await refreshFiles()
        }
        .task(id: pieceMapRefreshID) {
            guard selectedTab == .pieces else {
                return
            }
            await refreshPieceMap()
        }
        .onAppear {
            if let tabRequest {
                selectedTab = tabRequest.tab
            }
        }
        .onChange(of: tabRequest) { _, request in
            if let request {
                selectedTab = request.tab
            }
        }
    }

    private var generalTab: some View {
        Form {
            Section {
                AccessibleLabeledValue("Status", value: torrent.statusText)
                AccessibleLabeledValue("Progress", value: torrent.progress.formatted(.percent.precision(.fractionLength(2))))
                AccessibleLabeledValue("Downloaded", value: "\(ByteFormat.size(torrent.totalDone)) of \(ByteFormat.size(torrent.totalWanted))")
                AccessibleLabeledValue("All-time upload", value: ByteFormat.size(torrent.displayedAllTimeUpload))
                AccessibleLabeledValue("All-time download", value: ByteFormat.size(torrent.displayedAllTimeDownload))
                AccessibleLabeledValue("Download rate", value: ByteFormat.rate(torrent.downloadPayloadRate))
                AccessibleLabeledValue("Upload rate", value: ByteFormat.rate(torrent.uploadPayloadRate))
                AccessibleLabeledValue("Peers", value: torrent.peerSummaryText)
                AccessibleLabeledValue("Seeds", value: "\(torrent.seeds)")
            } header: {
                Label("Transfer", systemImage: "arrow.up.arrow.down")
            }

            Section {
                AccessibleLabeledValue("Added on", value: formattedDate(torrent.addedTime, fallback: "Unavailable"))
                AccessibleLabeledValue("Created on", value: formattedDate(torrent.createdTime, fallback: "Unavailable"))
                AccessibleLabeledValue("Completed on", value: formattedDate(torrent.completedTime, fallback: "Not completed"))
                AccessibleLabeledValue("Total size", value: ByteFormat.size(displayedTotalSize))
                AccessibleLabeledValue("Type", value: torrentTypeText)
                if !torrent.comment.isEmpty {
                    InfoDetailRow("Comment") {
                        TorrentCommentValueView(comment: torrent.comment)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Comment")
                    .accessibilityValue(torrent.comment)
                }
                InfoDetailRow("Info hash") {
                    InfoHashValueView(infoHash: torrent.infoHash)
                }
            } header: {
                Label("Information", systemImage: "doc.text")
            }

            Section {
                InfoDetailRow("Download path") {
                    DownloadPathValueView(path: torrent.savePath) {
                        store.revealTorrentInFinder(id: torrent.id)
                    }
                }
            } header: {
                Label("Storage", systemImage: "folder")
            }

            if !torrent.error.isEmpty {
                Section("Error") {
                    Text(torrent.error)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var displayedTotalSize: Int64 {
        max(torrent.totalSize, torrent.totalWanted)
    }

    private var torrentTypeText: String {
        guard torrent.hasMetadata else {
            return "Unknown"
        }
        return torrent.privateTorrent ? "Private" : "Public"
    }

    private func formattedDate(_ timestamp: Int64, fallback: String) -> String {
        guard timestamp > 0 else {
            return fallback
        }

        return Date(timeIntervalSince1970: TimeInterval(timestamp))
            .formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private var optionsTab: some View {
        Form {
            optionsContent
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var sourcesTab: some View {
        Form {
            sourcesContent
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var filesTab: some View {
        Form {
            filesContent
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var piecesTab: some View {
        Form {
            if selectedTab == .pieces {
                piecesContent
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var optionsContent: some View {
        labelOptionsSection

        if let optionsError {
            Section {
                Text(optionsError)
                    .foregroundStyle(.red)
            }
        } else if !optionsLoaded {
            Section {
                HStack {
                    Text("Loading Options")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            }
        } else {
            queueOptionsSection

            discoveryOptionsSection

            Section {
                Toggle("Limit download speed", isOn: optionsLimitBinding(\.downloadRateLimitKBps, defaultValue: 1024))
                if let torrentOptions, torrentOptions.downloadRateLimitKBps > 0 {
                    IntegerFieldRow(
                        "Download speed",
                        value: optionValueBinding(\.downloadRateLimitKBps),
                        range: 1...1_000_000,
                        suffix: "KB/s"
                    )
                }

                Toggle("Limit upload speed", isOn: optionsLimitBinding(\.uploadRateLimitKBps, defaultValue: 1024))
                if let torrentOptions, torrentOptions.uploadRateLimitKBps > 0 {
                    IntegerFieldRow(
                        "Upload speed",
                        value: optionValueBinding(\.uploadRateLimitKBps),
                        range: 1...1_000_000,
                        suffix: "KB/s"
                    )
                }
            } header: {
                Label("Bandwidth", systemImage: "speedometer")
            } footer: {
                Text("Per-torrent limits cannot exceed the global transfer limits.")
            }

            Section {
                Toggle("Limit upload slots", isOn: optionsLimitBinding(\.uploadSlotLimit, defaultValue: 4))
                if let torrentOptions, torrentOptions.uploadSlotLimit > 0 {
                    IntegerFieldRow(
                        "Upload slots",
                        value: optionValueBinding(\.uploadSlotLimit),
                        range: 2...100_000
                    )
                }

                Toggle("Limit connections", isOn: optionsLimitBinding(\.connectionLimit, defaultValue: 50))
                if let torrentOptions, torrentOptions.connectionLimit > 0 {
                    IntegerFieldRow(
                        "Max connections",
                        value: optionValueBinding(\.connectionLimit),
                        range: 2...100_000
                    )
                }
            } header: {
                Label("Connections", systemImage: "network")
            } footer: {
                Text("Per-torrent limits cannot exceed the global connection limits.")
            }
        }
    }

    @ViewBuilder
    private var sourcesContent: some View {
        if let sourceError {
            Section {
                Text(sourceError)
                    .foregroundStyle(.red)
            }
        } else if !sourcesLoaded {
            Section {
                HStack {
                    Label("Loading Sources", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            }
        } else {
            peerSourcesSection

            Section {
                if trackers.isEmpty {
                    Text("No Trackers")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleTrackers) { tracker in
                        TorrentTrackerRow(tracker: tracker)
                    }
                    if shouldShowTrackerLimitControl {
                        SourceLimitButton(isShowingAll: showsAllTrackers) {
                            showsAllTrackers.toggle()
                        }
                    }
                }
            } header: {
                SourceSectionHeader(
                    title: "Trackers",
                    count: trackers.count,
                    detail: trackerSummaryText,
                    systemImage: "antenna.radiowaves.left.and.right"
                )
            }

            Section {
                if webSeeds.isEmpty {
                    Text("No Web Seeds")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleWebSeeds) { webSeed in
                        TorrentWebSeedRow(webSeed: webSeed)
                    }
                    if shouldShowWebSeedLimitControl {
                        SourceLimitButton(isShowingAll: showsAllWebSeeds) {
                            showsAllWebSeeds.toggle()
                        }
                    }
                }
            } header: {
                SourceSectionHeader(
                    title: "Web Seeds",
                    count: webSeeds.count,
                    detail: webSeedActivity.summaryText,
                    systemImage: "globe"
                )
            }
        }
    }

    @ViewBuilder
    private var labelOptionsSection: some View {
        Section {
            TorrentLabelSelectionRow(
                labels: store.labels,
                selectedLabelIDs: Binding {
                    store.labelIDs(for: torrent.id)
                } set: { labelIDs in
                    store.setLabels(labelIDs, forTorrent: torrent.id)
                },
                createLabel: { store.createLabel(named: $0) }
            )
        } header: {
            Label("Labels", systemImage: "tag")
        }
    }

    @ViewBuilder
    private var queueOptionsSection: some View {
        Section {
            if torrentOptions != nil {
                Picker("Priority", selection: queuePriorityBinding) {
                    ForEach(TorrentQueuePriority.allCases) { priority in
                        Text(priority.title).tag(priority)
                    }
                }

                LabeledContent("Move to") {
                    ControlGroup {
                        Button {
                            moveTorrentInQueue(.top)
                        } label: {
                            Label("Top", systemImage: "arrow.up.to.line")
                        }
                        .help("Move to top of this priority")

                        Button {
                            moveTorrentInQueue(.up)
                        } label: {
                            Label("Up", systemImage: "arrow.up")
                        }
                        .help("Move up within this priority")

                        Button {
                            moveTorrentInQueue(.down)
                        } label: {
                            Label("Down", systemImage: "arrow.down")
                        }
                        .help("Move down within this priority")

                        Button {
                            moveTorrentInQueue(.bottom)
                        } label: {
                            Label("Bottom", systemImage: "arrow.down.to.line")
                        }
                        .help("Move to bottom of this priority")
                    }
                    .labelStyle(.iconOnly)
                }
            }
        } header: {
            Label("Queue", systemImage: "arrow.up.arrow.down")
        } footer: {
            Text("Move commands stay within the selected priority.")
        }
    }

    @ViewBuilder
    private var discoveryOptionsSection: some View {
        Section {
            if let sourcePolicy {
                if sourcePolicy.isMetadataValidationPending {
                    Toggle("Use DHT to fetch metadata", isOn: preMetadataDHTBinding)
                        .disabled(isDHTPolicyDisabled(for: sourcePolicy))
                        .foregroundStyle(isDHTPolicyDisabled(for: sourcePolicy) ? Color.secondary : Color.primary)
                        .help("Share this magnet's info hash with the public DHT before its metadata is checked.")

                    Text("PEX and local discovery stay off until the torrent metadata is checked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Use Distributed Hash Table (DHT)", isOn: dhtPolicyBinding)
                        .disabled(isDHTPolicyDisabled(for: sourcePolicy))
                        .foregroundStyle(isDHTPolicyDisabled(for: sourcePolicy) ? Color.secondary : Color.primary)
                        .help(dhtPolicyHelp(for: sourcePolicy))

                    Toggle("Use Peer Exchange (PEX)", isOn: peerExchangePolicyBinding)
                        .disabled(isPeerExchangePolicyDisabled(for: sourcePolicy))
                        .foregroundStyle(isPeerExchangePolicyDisabled(for: sourcePolicy) ? Color.secondary : Color.primary)
                        .help(peerExchangePolicyHelp(for: sourcePolicy))

                    Toggle("Use Local Service Discovery (LSD)", isOn: localServiceDiscoveryPolicyBinding)
                        .disabled(isLocalServiceDiscoveryPolicyDisabled(for: sourcePolicy))
                        .foregroundStyle(isLocalServiceDiscoveryPolicyDisabled(for: sourcePolicy) ? Color.secondary : Color.primary)
                        .help(localServiceDiscoveryPolicyHelp(for: sourcePolicy))
                }

                Toggle("Use HTTPS trackers only", isOn: sourcePolicyBinding(.httpsTrackersOnly))
                    .help("Ignore non-HTTPS trackers for this torrent.")

                Toggle("Use HTTPS web seeds only", isOn: sourcePolicyBinding(.httpsWebSeedsOnly))
                    .help("Ignore non-HTTPS web seeds for this torrent.")
            } else {
                HStack {
                    Text("Loading Policy")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            }
        } header: {
            Label("Discovery", systemImage: "network")
        } footer: {
            Text("Some discovery behavior, such as incoming peer connections, is app-level and applies to all torrents.")
        }
    }

    @ViewBuilder
    private var peerSourcesSection: some View {
        Section {
            if peerSources.hasConnectedPeers {
                PeerSourceRow("Tracker", value: peerSources.tracker, systemImage: "antenna.radiowaves.left.and.right")
                PeerSourceRow("DHT", value: peerSources.dht, systemImage: "network")
                PeerSourceRow("PEX", value: peerSources.peerExchange, systemImage: "person.2")
                PeerSourceRow("LSD", value: peerSources.localServiceDiscovery, systemImage: "dot.radiowaves.left.and.right")
                PeerSourceRow("Resume data", value: peerSources.resumeData, systemImage: "clock.arrow.circlepath")
                PeerSourceRow("Incoming", value: peerSources.incoming, systemImage: "arrow.down.left")
                PeerSourceRow("Web seed", value: peerSources.webSeed, systemImage: "globe")
                PeerSourceRow("Other", value: peerSources.other, systemImage: "questionmark.circle")
            } else {
                Text("No Connected Peers")
                    .foregroundStyle(.secondary)
            }
        } header: {
            SourceSectionHeader(
                title: "Connected Peer Sources",
                count: Int(peerSources.connected),
                detail: nil,
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        } footer: {
            Text("Counts can overlap when a peer is associated with more than one source.")
        }
    }

    @ViewBuilder
    private var filesContent: some View {
        if let fileError {
            Section {
                Text(fileError)
                    .foregroundStyle(.red)
            }
        } else if !torrent.hasMetadata {
            Section {
                Label("Files available after metadata downloads", systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
        } else if !filesLoaded {
            Section {
                HStack {
                    Label("Loading Files", systemImage: "doc")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            }
        } else {
            if displayedFiles.isEmpty {
                Section {
                    Label("No Files", systemImage: "doc")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(fileGroups) { group in
                    Section {
                        ForEach(visibleFiles(for: group)) { file in
                            TorrentFileRow(file: file) {
                                store.revealTorrentFileInFinder(torrent: torrent, file: file)
                            } setPriority: { priority in
                                setFilePriority(priority, for: file)
                            }
                        }
                    } header: {
                        SourceSectionHeader(
                            title: group.title,
                            count: files(for: group).count,
                            detail: nil,
                            systemImage: group.systemImage
                        )
                    }
                }

                if shouldShowFileLimitControl {
                    Section {
                        SourceLimitButton(isShowingAll: showsAllFiles) {
                            showsAllFiles.toggle()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var piecesContent: some View {
        if let pieceMapError {
            Section {
                Text(pieceMapError)
                    .foregroundStyle(.red)
            }
        } else if !torrent.hasMetadata {
            Section {
                Label("Piece map available after metadata downloads", systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
        } else if !pieceMapLoaded {
            Section {
                HStack {
                    Label("Loading Pieces", systemImage: "square.grid.3x3")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            }
        } else if pieceMap.totalPieces <= 0 {
            Section {
                Label("No Pieces", systemImage: "square.grid.3x3")
                    .foregroundStyle(.secondary)
            }
        } else if !pieceMap.isMapAvailable {
            Section {
                Label("Piece map unavailable right now", systemImage: "clock")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Libtorrent may not expose the piece bitfield while this torrent is paused, checking, or still preparing metadata.")
            }
        } else {
            Section {
                TorrentPieceMapView(pieceMap: pieceMap)
            } header: {
                SourceSectionHeader(
                    title: "Piece Map",
                    count: pieceMap.totalPieces,
                    detail: pieceMap.progress.formatted(.percent.precision(.fractionLength(1))),
                    systemImage: "square.grid.3x3"
                )
            } footer: {
                Text(pieceMapFooterText)
            }
        }
    }

    private var pieceMapFooterText: String {
        if pieceMap.isMapTruncated {
            return "Showing the first \(pieceMap.displayedPieces.formatted()) of \(pieceMap.totalPieces.formatted()) pieces. Progress uses the full torrent."
        }
        return "Each cell represents a proportional contiguous slice of the torrent. Green is available locally; blue is partially available."
    }

    private var visibleTrackers: [TorrentTrackerItem] {
        guard !showsAllTrackers else {
            return trackers
        }
        return Array(trackers.prefix(Self.sourceListLimit))
    }

    private var visibleWebSeeds: [TorrentWebSeedItem] {
        guard !showsAllWebSeeds else {
            return webSeeds
        }
        return Array(webSeeds.prefix(Self.sourceListLimit))
    }

    private var displayedFiles: [TorrentFileItem] {
        files.filter { !$0.isPadFile }
    }

    private var fileGroups: [TorrentInfoFileGroup] {
        TorrentInfoFileGroup.allCases.filter { group in
            !files(for: group).isEmpty
        }
    }

    private func files(for group: TorrentInfoFileGroup) -> [TorrentFileItem] {
        displayedFiles.filter { group.contains($0) }
    }

    private func visibleFiles(for group: TorrentInfoFileGroup) -> [TorrentFileItem] {
        let files = files(for: group)
        guard !showsAllFiles else {
            return files
        }
        return Array(files.prefix(Self.fileListLimit))
    }

    private var shouldShowTrackerLimitControl: Bool {
        trackers.count > Self.sourceListLimit
    }

    private var shouldShowWebSeedLimitControl: Bool {
        webSeeds.count > Self.sourceListLimit
    }

    private var shouldShowFileLimitControl: Bool {
        fileGroups.contains { files(for: $0).count > Self.fileListLimit }
    }

    private var filesRefreshID: String {
        "\(torrent.id):\(torrent.hasMetadata):\(selectedTab == .files)"
    }

    private var pieceMapRefreshID: String {
        "\(torrent.id):\(torrent.hasMetadata):\(selectedTab == .pieces)"
    }

    private var sourcesRefreshID: String {
        "\(torrent.id):\(selectedTab == .sources)"
    }

    private var optionsRefreshID: String {
        let settings = store.settings
        return [
            torrent.id,
            String(torrent.hasMetadata),
            String(selectedTab == .options),
            String(settings.enableDHTNetwork),
            String(settings.effectiveUseDHTByDefault),
            String(settings.enablePeerExchangePlugin),
            String(settings.effectiveUsePeerExchangeByDefault),
            String(settings.effectiveEnableLocalServiceDiscovery),
            String(settings.effectiveUseLocalServiceDiscoveryByDefault),
            String(settings.useHTTPSTrackersOnly),
            String(settings.useHTTPSWebSeedsOnly)
        ].joined(separator: ":")
    }

    private var trackerSummaryText: String? {
        guard !trackers.isEmpty else {
            return nil
        }

        var parts = [String]()
        let workingCount = trackers.filter { $0.enabled && $0.verified && !$0.hasError }.count
        parts.append("\(workingCount) working")

        let updatingCount = trackers.filter { $0.enabled && $0.updating }.count
        if updatingCount > 0 {
            parts.append("\(updatingCount) updating")
        }

        return parts.joined(separator: " · ")
    }

    private func optionsLimitBinding(_ keyPath: WritableKeyPath<TorrentOptions, Int>, defaultValue: Int) -> Binding<Bool> {
        Binding {
            guard let torrentOptions else {
                return false
            }
            return torrentOptions[keyPath: keyPath] > 0
        } set: { isEnabled in
            guard var updatedOptions = torrentOptions else {
                return
            }
            updatedOptions[keyPath: keyPath] = isEnabled ? defaultValue : 0
            torrentOptions = updatedOptions
            Task {
                await setTorrentOptions(updatedOptions)
            }
        }
    }

    private func optionValueBinding(_ keyPath: WritableKeyPath<TorrentOptions, Int>) -> Binding<Int> {
        Binding {
            torrentOptions?[keyPath: keyPath] ?? 0
        } set: { newValue in
            guard var updatedOptions = torrentOptions else {
                return
            }
            updatedOptions[keyPath: keyPath] = newValue
            updatedOptions = updatedOptions.normalized
            torrentOptions = updatedOptions
            Task {
                await setTorrentOptions(updatedOptions)
            }
        }
    }

    private var queuePriorityBinding: Binding<TorrentQueuePriority> {
        Binding {
            torrentOptions?.queuePriority ?? .normal
        } set: { newValue in
            guard var updatedOptions = torrentOptions else {
                return
            }
            updatedOptions.queuePriority = newValue
            torrentOptions = updatedOptions
            Task {
                await setTorrentOptions(updatedOptions)
            }
        }
    }

    private func moveTorrentInQueue(_ move: TorrentQueueMove) {
        Task { @MainActor in
            do {
                try await store.moveTorrentInQueue(for: torrent.id, move: move)
                optionsError = nil
            } catch {
                optionsError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func setTorrentOptions(_ options: TorrentOptions) async {
        do {
            try await store.setTorrentOptions(for: torrent.id, options: options)
            torrentOptions = try await store.torrentOptions(for: torrent.id)
            optionsLoaded = true
            optionsError = nil
        } catch {
            optionsError = error.localizedDescription
            torrentOptions = try? await store.torrentOptions(for: torrent.id)
        }
    }

    private func setFilePriority(_ priority: TorrentFilePriority, for file: TorrentFileItem) {
        guard file.priority != priority else {
            return
        }

        let previousFile = file
        if let index = files.firstIndex(where: { $0.id == file.id }) {
            files[index] = file.withPriority(priority)
        }

        Task {
            do {
                try await store.setFilePriority(for: torrent.id, fileIndex: file.index, priority: priority)
                fileError = nil
            } catch {
                if let index = files.firstIndex(where: { $0.id == previousFile.id }) {
                    files[index] = previousFile
                }
                fileError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func refreshOptions() async {
        torrentOptions = nil
        sourcePolicy = nil
        optionsLoaded = false
        optionsError = nil

        do {
            torrentOptions = try await store.torrentOptions(for: torrent.id)
            sourcePolicy = try await store.sourcePolicy(for: torrent.id)
            optionsLoaded = true
        } catch {
            optionsError = error.localizedDescription
            optionsLoaded = true
        }
    }

    private func sourcePolicyBinding(_ field: TorrentSourcePolicyField) -> Binding<Bool> {
        Binding {
            guard let sourcePolicy else {
                return false
            }
            return sourcePolicy[field]
        } set: { newValue in
            updateSourcePolicy(field, to: newValue)
        }
    }

    private var dhtPolicyBinding: Binding<Bool> {
        Binding {
            guard let sourcePolicy, !isDHTPolicyDisabled(for: sourcePolicy) else {
                return false
            }
            return sourcePolicy.isDHTEnabled
        } set: { newValue in
            updateSourcePolicy(.dht, to: newValue)
        }
    }

    private var preMetadataDHTBinding: Binding<Bool> {
        Binding {
            sourcePolicy?.allowsPreMetadataDHT ?? false
        } set: { newValue in
            updateSourcePolicy(.preMetadataDHT, to: newValue)
        }
    }

    private var peerExchangePolicyBinding: Binding<Bool> {
        Binding {
            guard let sourcePolicy, !isPeerExchangePolicyDisabled(for: sourcePolicy) else {
                return false
            }
            return sourcePolicy.isPeerExchangeEnabled
        } set: { newValue in
            updateSourcePolicy(.peerExchange, to: newValue)
        }
    }

    private var localServiceDiscoveryPolicyBinding: Binding<Bool> {
        Binding {
            guard let sourcePolicy, !isLocalServiceDiscoveryPolicyDisabled(for: sourcePolicy) else {
                return false
            }
            return sourcePolicy.isLocalServiceDiscoveryEnabled
        } set: { newValue in
            updateSourcePolicy(.localServiceDiscovery, to: newValue)
        }
    }

    @MainActor
    private func updateSourcePolicy(
        _ field: TorrentSourcePolicyField,
        to newValue: Bool
    ) {
        guard var updatedPolicy = sourcePolicy else {
            return
        }
        updatedPolicy[field] = newValue
        sourcePolicy = updatedPolicy
        sourcePolicyMutationGeneration &+= 1
        let mutationGeneration = sourcePolicyMutationGeneration
        let previousMutation = sourcePolicyMutationTask
        sourcePolicyMutationTask = Task {
            await previousMutation?.value
            await setSourcePolicy(
                field: field,
                enabled: newValue,
                mutationGeneration: mutationGeneration
            )
        }
    }

    private func isDHTPolicyDisabled(for policy: TorrentSourcePolicy) -> Bool {
        policy.isDHTLocked || !store.settings.enableDHTNetwork
    }

    private func isPeerExchangePolicyDisabled(for policy: TorrentSourcePolicy) -> Bool {
        policy.isPeerExchangeLocked || !store.settings.enablePeerExchangePlugin
    }

    private func isLocalServiceDiscoveryPolicyDisabled(for policy: TorrentSourcePolicy) -> Bool {
        policy.isLocalServiceDiscoveryLocked || !store.settings.effectiveEnableLocalServiceDiscovery
    }

    private func dhtPolicyHelp(for policy: TorrentSourcePolicy) -> String {
        if policy.isDHTLocked {
            return "This torrent disables DHT."
        }
        if !store.settings.enableDHTNetwork {
            return "Enable the DHT network in Discovery settings to use DHT for this torrent."
        }
        if !store.settings.useDHTByDefault {
            return "DHT is off by default for new torrents. Enable it here for this torrent."
        }
        return "Use the Distributed Hash Table for this torrent."
    }

    private func peerExchangePolicyHelp(for policy: TorrentSourcePolicy) -> String {
        if policy.isPeerExchangeLocked {
            return "This torrent disables peer exchange."
        }
        if !store.settings.enablePeerExchangePlugin {
            return "Enable Peer Exchange in Discovery settings to use PEX for this torrent."
        }
        if !store.settings.usePeerExchangeByDefault {
            return "PEX is off by default for new torrents. Enable it here for this torrent."
        }
        return "Exchange peer addresses with connected peers for this torrent."
    }

    private func localServiceDiscoveryPolicyHelp(for policy: TorrentSourcePolicy) -> String {
        if policy.isLocalServiceDiscoveryLocked {
            return "This torrent disables local service discovery."
        }
        if !store.settings.effectiveEnableLocalServiceDiscovery {
            return "Enable Local Service Discovery in Discovery settings to use LSD for this torrent."
        }
        if !store.settings.useLocalServiceDiscoveryByDefault {
            return "LSD is off by default for new torrents. Enable it here for this torrent."
        }
        return "Find peers for this torrent on the local network."
    }

    @MainActor
    private func setSourcePolicy(
        field: TorrentSourcePolicyField,
        enabled: Bool,
        mutationGeneration: UInt64
    ) async {
        do {
            try await store.setSourcePolicy(for: torrent.id, field: field, enabled: enabled)
            guard mutationGeneration == sourcePolicyMutationGeneration else {
                return
            }
            let confirmedPolicy = try await store.sourcePolicy(for: torrent.id)
            guard mutationGeneration == sourcePolicyMutationGeneration else {
                return
            }
            sourcePolicy = confirmedPolicy
            try? await store.requestSources(for: torrent.id)
            let trackerBatch = await store.trackerBatch(for: torrent.id, since: nil)
            let webSeedBatch = await store.webSeedBatch(for: torrent.id, since: nil)
            let peerSources = await store.peerSources(for: torrent.id)
            if let trackerBatch {
                trackerRevision = trackerBatch.revision
                trackers = trackerBatch.trackers
            }
            if let webSeedBatch {
                webSeedRevision = webSeedBatch.revision
                webSeeds = webSeedBatch.webSeeds
            }
            if let webSeedActivity = await store.webSeedActivity(for: torrent.id) {
                self.webSeedActivity = webSeedActivity
            }
            if let peerSources {
                self.peerSources = peerSources
            }
            sourcesLoaded = true
            sourceError = nil
            optionsError = nil
        } catch {
            guard mutationGeneration == sourcePolicyMutationGeneration else {
                return
            }
            let confirmedPolicy = try? await store.sourcePolicy(for: torrent.id)
            guard mutationGeneration == sourcePolicyMutationGeneration else {
                return
            }
            sourceError = error.localizedDescription
            optionsError = error.localizedDescription
            sourcePolicy = confirmedPolicy
        }
    }

    @MainActor
    private func refreshSources() async {
        trackers = []
        webSeeds = []
        webSeedActivity = .empty
        peerSources = .empty
        sourcePolicy = nil
        trackerRevision = nil
        webSeedRevision = nil
        sourcesLoaded = false
        sourceError = nil
        showsAllTrackers = false
        showsAllWebSeeds = false

        while !Task.isCancelled {
            do {
                sourcePolicy = try await store.sourcePolicy(for: torrent.id)
                try await store.requestSources(for: torrent.id)
            } catch {
                sourceError = error.localizedDescription
                sourcesLoaded = true
                return
            }

            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else {
                return
            }
            let trackerBatch = await store.trackerBatch(for: torrent.id, since: trackerRevision)
            let webSeedBatch = await store.webSeedBatch(for: torrent.id, since: webSeedRevision)
            let webSeedActivity = await store.webSeedActivity(for: torrent.id)
            let peerSources = await store.peerSources(for: torrent.id)
            if let trackerBatch {
                trackerRevision = trackerBatch.revision
                trackers = trackerBatch.trackers
            }
            if let webSeedBatch {
                webSeedRevision = webSeedBatch.revision
                webSeeds = webSeedBatch.webSeeds
            }
            if let webSeedActivity, self.webSeedActivity != webSeedActivity {
                self.webSeedActivity = webSeedActivity
            }
            if let peerSources, self.peerSources != peerSources {
                self.peerSources = peerSources
            }
            sourcesLoaded = true

            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else {
                return
            }
        }
    }

    @MainActor
    private func refreshFiles() async {
        files = []
        fileRevision = nil
        filesLoaded = false
        fileError = nil
        showsAllFiles = false

        while !Task.isCancelled {
            guard torrent.hasMetadata else {
                filesLoaded = true
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            do {
                try await store.requestFiles(for: torrent.id)
            } catch {
                fileError = error.localizedDescription
                filesLoaded = true
                return
            }

            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else {
                return
            }
            if let fileBatch = await store.fileBatch(for: torrent.id, since: fileRevision) {
                fileRevision = fileBatch.revision
                files = fileBatch.files
                filesLoaded = true
            }

            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else {
                return
            }
        }
    }

    @MainActor
    private func refreshPieceMap() async {
        pieceMap = .empty
        pieceMapRevision = nil
        pieceMapLoaded = false
        pieceMapError = nil

        while !Task.isCancelled {
            guard torrent.hasMetadata else {
                pieceMapLoaded = true
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            do {
                try await store.requestPieceMap(for: torrent.id)
            } catch {
                pieceMapError = error.localizedDescription
                pieceMapLoaded = true
                return
            }

            if let pieceMapBatch = await store.pieceMapBatch(for: torrent.id, since: pieceMapRevision) {
                pieceMapRevision = pieceMapBatch.revision
                pieceMap = pieceMapBatch.pieceMap
                pieceMapLoaded = true
            }

            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else {
                return
            }
        }
    }
}


private struct PeerSourceRow: View {
    private static let iconColumnWidth: CGFloat = 24

    let title: String
    let value: Int32
    let systemImage: String

    init(_ title: String, value: Int32, systemImage: String) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
    }

    var body: some View {
        LabeledContent {
            Text("\(value)")
                .foregroundStyle(value > 0 ? .primary : .secondary)
                .monospacedDigit()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: Self.iconColumnWidth)
                Text(title)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)")
    }
}

private struct TorrentPieceMapView: View {
    private static let maximumMapSide: CGFloat = 380

    let pieceMap: TorrentPieceMap

    var body: some View {
        Canvas { context, size in
            draw(in: context, size: size)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: Self.maximumMapSide)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Piece map")
        .accessibilityValue("\(pieceMap.completedSummary), \(pieceMap.progress.formatted(.percent.precision(.fractionLength(1)))) complete")
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0, pieceMap.displayedPieces > 0 else {
            return
        }

        let layout = PieceMapLayout(size: size, pieceCount: pieceMap.displayedPieces)
        let completedColor = Color.green
        let partialColor = Color.blue
        let missingColor = Color.secondary.opacity(0.16)

        for cell in 0..<layout.cellCount {
            let range = layout.pieceRange(for: cell)
            let completedCount = pieceMap.completedPieceCount(in: range)
            let completion = range.isEmpty ? 0 : Double(completedCount) / Double(range.count)
            let color: Color
            if completion <= 0 {
                color = missingColor
            } else if completion >= 1 {
                color = completedColor
            } else {
                color = partialColor.opacity(0.35 + (0.55 * completion))
            }
            context.fill(layout.path(for: cell), with: .color(color))
        }
    }
}

private struct PieceMapLayout {
    private let spacing: CGFloat
    private let columns: Int
    private let pieceCount: Int
    let cellCount: Int
    private let cellLength: CGFloat
    private let origin: CGPoint

    init(
        size: CGSize,
        pieceCount: Int,
        minimumCellLength: CGFloat = 4,
        spacing: CGFloat = 1
    ) {
        self.spacing = spacing
        self.pieceCount = pieceCount
        let squareLength = max(1, min(size.width, size.height))
        let maximumSideCells = max(1, Int((squareLength + spacing) / (minimumCellLength + spacing)))
        let idealSideCells = max(1, Int(floor(sqrt(Double(max(1, pieceCount))))))
        let sideCells = min(maximumSideCells, idealSideCells)
        columns = sideCells
        cellCount = sideCells * sideCells
        let rows = sideCells
        let widthConstrainedLength = (squareLength - (CGFloat(columns - 1) * spacing)) / CGFloat(columns)
        let heightConstrainedLength = (squareLength - (CGFloat(rows - 1) * spacing)) / CGFloat(rows)
        cellLength = max(1, min(widthConstrainedLength, heightConstrainedLength))

        let gridWidth = (CGFloat(columns) * cellLength) + (CGFloat(columns - 1) * spacing)
        let gridHeight = (CGFloat(rows) * cellLength) + (CGFloat(rows - 1) * spacing)
        origin = CGPoint(
            x: max(0, (size.width - gridWidth) / 2),
            y: max(0, (size.height - gridHeight) / 2)
        )
    }

    func pieceRange(for cell: Int) -> Range<Int> {
        let boundedCell = min(max(0, cell), cellCount)
        let start = (boundedCell * pieceCount) / cellCount
        let end = min(pieceCount, ((boundedCell + 1) * pieceCount) / cellCount)
        return start..<end
    }

    func path(for cell: Int) -> Path {
        let row = cell / columns
        let column = cell % columns
        let rect = CGRect(
            x: origin.x + (CGFloat(column) * (cellLength + spacing)),
            y: origin.y + (CGFloat(row) * (cellLength + spacing)),
            width: cellLength,
            height: cellLength
        )
        return Path(rect)
    }
}

private struct TorrentTrackerRow: View {
    let tracker: TorrentTrackerItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                SourceURLView(url: tracker.url)

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            Label(tracker.statusText, systemImage: tracker.statusSystemImage)
                .font(.caption)
                .foregroundStyle(statusStyle)
                .labelStyle(.titleAndIcon)
                .fixedSize()
        }
        .help(tracker.url)
    }

    private var detailText: String {
        var parts = ["Tier \(tracker.tier + 1)"]
        if let scrapeSummaryText = tracker.scrapeSummaryText {
            parts.append(scrapeSummaryText)
        }
        if tracker.failCount > 0 {
            parts.append("\(tracker.failCount) failed \(tracker.failCount == 1 ? "attempt" : "attempts")")
        }
        if !tracker.message.isEmpty {
            parts.append(tracker.message)
        }
        return parts.joined(separator: " · ")
    }

    private var statusStyle: Color {
        if !tracker.enabled {
            return .secondary
        }
        if tracker.hasError {
            return .red
        }
        if tracker.updating {
            return .blue
        }
        if tracker.verified {
            return .green
        }
        return .secondary
    }
}

private struct TorrentWebSeedRow: View {
    let webSeed: TorrentWebSeedItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            SourceURLView(url: webSeed.url)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            Label("Web Seed", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .fixedSize()
        }
        .help(webSeed.url)
    }
}

private struct TorrentFileRow: View {
    let file: TorrentFileItem
    let revealInFinder: () -> Void
    let setPriority: (TorrentFilePriority) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                FileItemIcon(path: file.path)

                Text(file.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                Button(action: revealInFinder) {
                    Label("Reveal in Finder", systemImage: "folder")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(fileAccessibilityName) in Finder")
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 8) {
                    Text(file.detailText)
                        .monospacedDigit()
                    Text(file.statusText)
                    Text(file.progress.formatted(.percent.precision(.fractionLength(1))))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                Picker("Priority", selection: priorityBinding) {
                    ForEach(TorrentFilePriority.allCases) { priority in
                        Text(priority.title).tag(priority)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("File priority")
                .accessibilityLabel("Priority for \(fileAccessibilityName)")
            }

            ProgressView(value: displayedProgress)
                .controlSize(.small)
                .tint(progressTint)
                .accessibilityLabel("Progress")
                .accessibilityValue(displayedProgress.formatted(.percent.precision(.fractionLength(1))))
        }
        .help(file.path)
    }

    private var priorityBinding: Binding<TorrentFilePriority> {
        Binding {
            file.priority
        } set: { priority in
            setPriority(priority)
        }
    }

    private var displayedProgress: Double {
        file.isSkipped ? 1 : file.progress
    }

    private var progressTint: Color? {
        if file.isSkipped {
            return .secondary
        }
        return file.progress >= 1 ? .green : nil
    }

    private var fileAccessibilityName: String {
        file.path.split(separator: "/").last.map(String.init) ?? file.path
    }
}

private struct AccessibleLabeledValue: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent(title, value: value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(value)
    }
}

private struct TorrentCommentValueView: View {
    let comment: String

    var body: some View {
        Text(comment)
            .lineLimit(4)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .textSelection(.enabled)
            .help(comment)
    }
}
