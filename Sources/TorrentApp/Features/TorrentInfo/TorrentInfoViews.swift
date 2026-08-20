import SwiftUI
import TorrentEngineModel

struct TorrentTrackerSummary: Equatable, Sendable {
    let text: String?

    @concurrent
    static func prepare(
        trackers: [TorrentTrackerItem]
    ) async throws -> Self {
        try Task.checkCancellation()
        guard !trackers.isEmpty else {
            return Self(text: nil)
        }

        var workingCount = 0
        var updatingCount = 0
        for (offset, tracker) in trackers.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if tracker.enabled && tracker.verified && !tracker.hasError {
                workingCount += 1
            }
            if tracker.enabled && tracker.updating {
                updatingCount += 1
            }
        }
        try Task.checkCancellation()

        var text = "\(workingCount) working"
        if updatingCount > 0 {
            text += " · \(updatingCount) updating"
        }
        return Self(text: text)
    }
}

private struct TorrentTrackerSummaryRequestID: Hashable, Sendable {
    let torrentID: TorrentItem.ID
    let revision: UInt64?
    let count: Int
}

private struct TorrentInfoSourcesRefreshID: Hashable, Sendable {
    let torrentID: TorrentItem.ID
    let isPresented: Bool
}

private struct TorrentInfoMetadataRefreshID: Hashable, Sendable {
    let torrentID: TorrentItem.ID
    let hasMetadata: Bool
    let isPresented: Bool
}

private struct TorrentInfoOptionsRefreshID: Hashable, Sendable {
    let torrentID: TorrentItem.ID
    let hasMetadata: Bool
    let isPresented: Bool
    let enablesDHTNetwork: Bool
    let usesDHTByDefault: Bool
    let enablesPeerExchange: Bool
    let usesPeerExchangeByDefault: Bool
    let enablesLocalServiceDiscovery: Bool
    let usesLocalServiceDiscoveryByDefault: Bool
    let httpsTrackerPolicy: TorrentHTTPSTrackerPolicy
    let httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicy
}

private enum TorrentInfoSourcePolicyMutationKey: Hashable, Sendable {
    case boolean(TorrentSourcePolicyField)
    case httpsTracker
    case httpsWebSeed
}

struct TorrentInfoWindow: View {
    @Environment(TorrentStore.self) private var store
    @Binding var torrentID: String?
    let torrentState: TorrentListState

    var body: some View {
        Group {
            if let torrent {
                TorrentInfoView(torrent: torrent, tabRequest: store.torrentInfoTabRequest(for: torrent.id))
                    .id(torrent.id)
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

        return torrentState.torrent(id: torrentID)
    }
}

enum TorrentInfoFileGroup: CaseIterable, Identifiable, Sendable {
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

}

struct TorrentInfoFileSection: Identifiable, Sendable {
    let group: TorrentInfoFileGroup
    let files: [TorrentFileItem]

    var id: TorrentInfoFileGroup {
        group
    }
}

struct TorrentFileBatchPresentation: Sendable {
    static let visibleFileLimit = 100

    let revision: UInt64
    let sections: [TorrentInfoFileSection]
    let remainingPendingPriorities: [
        Int32: TorrentFilePriority
    ]
    let displayedFileCount: Int
    let hasLimitedSections: Bool

    @concurrent
    static func prepare(
        batch: TorrentFileBatch,
        pendingPriorities: [Int32: TorrentFilePriority]
    ) async throws -> TorrentFileBatchPresentation {
        try Task.checkCancellation()
        var completeFiles = [TorrentFileItem]()
        var downloadingFiles = [TorrentFileItem]()
        var skippedFiles = [TorrentFileItem]()
        var remainingPendingPriorities = pendingPriorities

        for (offset, file) in batch.files.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if pendingPriorities[file.index] == file.priority {
                remainingPendingPriorities.removeValue(forKey: file.index)
            }
            let presentedFile = file.withPriority(
                remainingPendingPriorities[file.index] ?? file.priority
            )
            guard !presentedFile.isPadFile else {
                continue
            }
            switch presentedFile.priority {
            case .skip:
                skippedFiles.append(presentedFile)
            case .low, .normal, .high:
                if presentedFile.progress >= 1 {
                    completeFiles.append(presentedFile)
                } else {
                    downloadingFiles.append(presentedFile)
                }
            }
        }

        try Task.checkCancellation()
        var sections = [TorrentInfoFileSection]()
        sections.reserveCapacity(TorrentInfoFileGroup.allCases.count)
        if !completeFiles.isEmpty {
            sections.append(TorrentInfoFileSection(
                group: .complete,
                files: completeFiles
            ))
        }
        if !downloadingFiles.isEmpty {
            sections.append(TorrentInfoFileSection(
                group: .downloading,
                files: downloadingFiles
            ))
        }
        if !skippedFiles.isEmpty {
            sections.append(TorrentInfoFileSection(
                group: .skipped,
                files: skippedFiles
            ))
        }
        return TorrentFileBatchPresentation(
            revision: batch.revision,
            sections: sections,
            remainingPendingPriorities: remainingPendingPriorities,
            displayedFileCount:
                completeFiles.count
                + downloadingFiles.count
                + skippedFiles.count,
            hasLimitedSections: sections.contains {
                $0.files.count > Self.visibleFileLimit
            }
        )
    }
}

private struct TorrentInfoView: View {
    private static let sourceListLimit = 20
    private static let maximumPendingMutationTaskCount = 64

    @Environment(TorrentStore.self) private var store
    let torrent: TorrentItem
    let tabRequest: TorrentInfoTabRequest?
    @State private var selectedTab = TorrentInfoTab.general
    @State private var trackers = [TorrentTrackerItem]()
    @State private var trackerSummaryText: String?
    @State private var webSeeds = [TorrentWebSeedItem]()
    @State private var webSeedActivity = TorrentWebSeedActivity.empty
    @State private var peerSources = TorrentPeerSources.empty
    @State private var sourcePolicy: TorrentSourcePolicy?
    @State private var sourcePolicyMutationGeneration: UInt64 = 0
    @State private var sourcePolicyMutationTasks =
        [TorrentInfoSourcePolicyMutationKey: Task<Void, Never>]()
    @State private var sourcePolicyMutationTaskIDs =
        [TorrentInfoSourcePolicyMutationKey: UUID]()
    @State private var torrentOptionsMutationGeneration: UInt64 = 0
    @State private var torrentOptionsMutationTask: Task<Void, Never>?
    @State private var torrentOptionsMutationTaskID: UUID?
    @State private var filePriorityMutationGenerations = [Int32: UInt64]()
    @State private var filePriorityMutationTasks = [Int32: Task<Void, Never>]()
    @State private var filePriorityMutationTaskIDs = [Int32: UUID]()
    @State private var pendingFilePriorities = [Int32: TorrentFilePriority]()
    @State private var filePriorityPresentationGeneration: UInt64 = 0
    @State private var filePresentationTask: Task<Void, Never>?
    @State private var filePresentationTaskID: UUID?
    @State private var queueMoveGeneration: UInt64 = 0
    @State private var queueMoveTasks = [UUID: Task<Void, Never>]()
    @State private var torrentOptions: TorrentOptions?
    @State private var latestFileBatch: TorrentFileBatch?
    @State private var fileSections = [TorrentInfoFileSection]()
    @State private var displayedFileCount = 0
    @State private var hasLimitedFileSections = false
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
    @State private var sourcesRefreshToken: UUID?
    @State private var optionsRefreshToken: UUID?
    @State private var filesRefreshToken: UUID?
    @State private var pieceMapRefreshToken: UUID?

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
            let token = UUID()
            sourcesRefreshToken = token
            guard selectedTab == .sources else {
                return
            }
            await refreshSources(token: token, torrentID: torrent.id)
        }
        .task(id: trackerSummaryRequestID) {
            let requestID = trackerSummaryRequestID
            do {
                let summary = try await TorrentTrackerSummary.prepare(
                    trackers: trackers
                )
                try Task.checkCancellation()
                guard requestID == trackerSummaryRequestID else {
                    return
                }
                trackerSummaryText = summary.text
            } catch {
                return
            }
        }
        .task(id: optionsRefreshID) {
            let token = UUID()
            optionsRefreshToken = token
            guard selectedTab == .options else {
                return
            }
            await refreshOptions(token: token, torrentID: torrent.id)
        }
        .task(id: filesRefreshID) {
            let token = UUID()
            filesRefreshToken = token
            guard selectedTab == .files else {
                return
            }
            await refreshFiles(
                token: token,
                torrentID: torrent.id,
                hasMetadata: torrent.hasMetadata
            )
        }
        .task(id: pieceMapRefreshID) {
            let token = UUID()
            pieceMapRefreshToken = token
            guard selectedTab == .pieces else {
                return
            }
            await refreshPieceMap(
                token: token,
                torrentID: torrent.id,
                hasMetadata: torrent.hasMetadata
            )
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
        .onDisappear {
            for task in sourcePolicyMutationTasks.values {
                task.cancel()
            }
            sourcePolicyMutationTasks.removeAll()
            sourcePolicyMutationTaskIDs.removeAll()
            torrentOptionsMutationTask?.cancel()
            torrentOptionsMutationTask = nil
            torrentOptionsMutationTaskID = nil
            for task in filePriorityMutationTasks.values {
                task.cancel()
            }
            filePriorityMutationTasks.removeAll()
            filePriorityMutationTaskIDs.removeAll()
            filePriorityMutationGenerations.removeAll()
            filePresentationTask?.cancel()
            filePresentationTask = nil
            filePresentationTaskID = nil
            pendingFilePriorities.removeAll()
            for task in queueMoveTasks.values {
                task.cancel()
            }
            queueMoveTasks.removeAll()
            sourcesRefreshToken = nil
            optionsRefreshToken = nil
            filesRefreshToken = nil
            pieceMapRefreshToken = nil
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

                Picker("Tracker policy", selection: httpsTrackerPolicyBinding) {
                    ForEach(TorrentHTTPSTrackerPolicyOverride.allCases) { policy in
                        Text(httpsTrackerPolicyTitle(policy)).tag(policy)
                    }
                }
                .help("Override the global HTTPS tracker policy for this torrent.")

                Picker("Web seed policy", selection: httpsWebSeedPolicyBinding) {
                    ForEach(TorrentHTTPSWebSeedPolicyOverride.allCases) { policy in
                        Text(httpsWebSeedPolicyTitle(policy)).tag(policy)
                    }
                }
                .help("Override the global HTTPS web seed policy for this torrent.")
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
            if displayedFileCount == 0 {
                Section {
                    Label("No Files", systemImage: "doc")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(fileSections) { section in
                    Section {
                        ForEach(visibleFiles(in: section)) { file in
                            TorrentFileRow(file: file) {
                                store.revealTorrentFileInFinder(torrent: torrent, file: file)
                            } setPriority: { priority in
                                setFilePriority(priority, for: file)
                            }
                        }
                    } header: {
                        SourceSectionHeader(
                            title: section.group.title,
                            count: section.files.count,
                            detail: nil,
                            systemImage: section.group.systemImage
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

    private func visibleFiles(
        in section: TorrentInfoFileSection
    ) -> ArraySlice<TorrentFileItem> {
        guard !showsAllFiles else {
            return section.files[...]
        }
        return section.files.prefix(
            TorrentFileBatchPresentation.visibleFileLimit
        )
    }

    private var shouldShowTrackerLimitControl: Bool {
        trackers.count > Self.sourceListLimit
    }

    private var shouldShowWebSeedLimitControl: Bool {
        webSeeds.count > Self.sourceListLimit
    }

    private var shouldShowFileLimitControl: Bool {
        hasLimitedFileSections
    }

    private var filesRefreshID: TorrentInfoMetadataRefreshID {
        TorrentInfoMetadataRefreshID(
            torrentID: torrent.id,
            hasMetadata: torrent.hasMetadata,
            isPresented: selectedTab == .files
        )
    }

    private var pieceMapRefreshID: TorrentInfoMetadataRefreshID {
        TorrentInfoMetadataRefreshID(
            torrentID: torrent.id,
            hasMetadata: torrent.hasMetadata,
            isPresented: selectedTab == .pieces
        )
    }

    private var sourcesRefreshID: TorrentInfoSourcesRefreshID {
        TorrentInfoSourcesRefreshID(
            torrentID: torrent.id,
            isPresented: selectedTab == .sources
        )
    }

    private var trackerSummaryRequestID: TorrentTrackerSummaryRequestID {
        TorrentTrackerSummaryRequestID(
            torrentID: torrent.id,
            revision: trackerRevision,
            count: trackers.count
        )
    }

    private var optionsRefreshID: TorrentInfoOptionsRefreshID {
        let settings = store.settings
        return TorrentInfoOptionsRefreshID(
            torrentID: torrent.id,
            hasMetadata: torrent.hasMetadata,
            isPresented: selectedTab == .options,
            enablesDHTNetwork: settings.enableDHTNetwork,
            usesDHTByDefault: settings.effectiveUseDHTByDefault,
            enablesPeerExchange: settings.enablePeerExchangePlugin,
            usesPeerExchangeByDefault:
                settings.effectiveUsePeerExchangeByDefault,
            enablesLocalServiceDiscovery:
                settings.effectiveEnableLocalServiceDiscovery,
            usesLocalServiceDiscoveryByDefault:
                settings.effectiveUseLocalServiceDiscoveryByDefault,
            httpsTrackerPolicy: settings.httpsTrackerPolicy,
            httpsWebSeedPolicy: settings.httpsWebSeedPolicy
        )
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
            scheduleTorrentOptionsMutation(updatedOptions)
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
            scheduleTorrentOptionsMutation(updatedOptions)
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
            scheduleTorrentOptionsMutation(updatedOptions)
        }
    }

    @MainActor
    private func scheduleTorrentOptionsMutation(_ options: TorrentOptions) {
        precondition(
            torrentOptionsMutationGeneration != UInt64.max,
            "Torrent-options mutation generation exhausted"
        )
        torrentOptionsMutationGeneration += 1
        let generation = torrentOptionsMutationGeneration
        let torrentID = torrent.id
        torrentOptionsMutationTask?.cancel()
        let taskID = UUID()
        torrentOptionsMutationTaskID = taskID
        torrentOptionsMutationTask = Task { @MainActor in
            defer {
                if torrentOptionsMutationTaskID == taskID {
                    torrentOptionsMutationTask = nil
                    torrentOptionsMutationTaskID = nil
                }
            }
            await setTorrentOptions(
                options,
                torrentID: torrentID,
                mutationGeneration: generation
            )
        }
    }

    private func moveTorrentInQueue(_ move: TorrentQueueMove) {
        guard queueMoveTasks.count
                < Self.maximumPendingMutationTaskCount else {
            optionsError =
                TorrentStoreError.tooManyPendingOperations
                    .localizedDescription
            return
        }
        precondition(
            queueMoveGeneration != UInt64.max,
            "Queue-move generation exhausted"
        )
        queueMoveGeneration += 1
        let generation = queueMoveGeneration
        let torrentID = torrent.id
        let taskID = UUID()
        queueMoveTasks[taskID] = Task { @MainActor in
            defer {
                queueMoveTasks.removeValue(forKey: taskID)
            }
            do {
                try await store.moveTorrentInQueue(for: torrentID, move: move)
                guard !Task.isCancelled,
                      generation == queueMoveGeneration else {
                    return
                }
                optionsError = nil
            } catch {
                guard !Task.isCancelled,
                      generation == queueMoveGeneration else {
                    return
                }
                optionsError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func setTorrentOptions(
        _ options: TorrentOptions,
        torrentID: TorrentItem.ID,
        mutationGeneration: UInt64
    ) async {
        do {
            try await store.setTorrentOptions(for: torrentID, options: options)
            guard isCurrentOptionsMutation(mutationGeneration) else {
                return
            }
            let confirmedOptions = try await store.torrentOptions(for: torrentID)
            guard isCurrentOptionsMutation(mutationGeneration) else {
                return
            }
            torrentOptions = confirmedOptions
            optionsLoaded = true
            optionsError = nil
        } catch {
            guard isCurrentOptionsMutation(mutationGeneration) else {
                return
            }
            let errorMessage = error.localizedDescription
            let confirmedOptions = try? await store.torrentOptions(for: torrentID)
            guard isCurrentOptionsMutation(mutationGeneration) else {
                return
            }
            optionsError = errorMessage
            torrentOptions = confirmedOptions
        }
    }

    private func setFilePriority(_ priority: TorrentFilePriority, for file: TorrentFileItem) {
        guard file.priority != priority else {
            return
        }
        guard filePriorityMutationTasks[file.index] != nil
                || filePriorityMutationTasks.count
                    < Self.maximumPendingMutationTaskCount else {
            fileError =
                TorrentStoreError.tooManyPendingOperations
                    .localizedDescription
            return
        }

        let currentGeneration =
            filePriorityMutationGenerations[file.index, default: 0]
        precondition(
            currentGeneration != UInt64.max,
            "File-priority mutation generation exhausted"
        )
        let generation = currentGeneration + 1
        filePriorityMutationGenerations[file.index] = generation
        advanceFilePriorityPresentationGeneration()
        pendingFilePriorities[file.index] = priority
        scheduleFilePresentation()
        filePriorityMutationTasks[file.index]?.cancel()
        let torrentID = torrent.id
        let taskID = UUID()
        filePriorityMutationTaskIDs[file.index] = taskID
        filePriorityMutationTasks[file.index] = Task { @MainActor in
            defer {
                if filePriorityMutationTaskIDs[file.index] == taskID {
                    filePriorityMutationTasks.removeValue(
                        forKey: file.index
                    )
                    filePriorityMutationTaskIDs.removeValue(
                        forKey: file.index
                    )
                    filePriorityMutationGenerations.removeValue(
                        forKey: file.index
                    )
                }
            }
            do {
                try await store.setFilePriority(
                    for: torrentID,
                    fileIndex: file.index,
                    priority: priority
                )
                guard isCurrentFilePriorityMutation(
                    generation,
                    fileIndex: file.index
                ) else {
                    return
                }
                if let authoritativeBatch = await store.fileBatch(
                    for: torrentID,
                    since: nil
                ) {
                    _ = await applyFileBatch(
                        authoritativeBatch,
                        mutationGeneration: generation,
                        fileIndex: file.index
                    )
                }
                guard isCurrentFilePriorityMutation(
                    generation,
                    fileIndex: file.index
                ) else {
                    return
                }
                fileError = nil
            } catch {
                let errorMessage = error.localizedDescription
                guard isCurrentFilePriorityMutation(
                    generation,
                    fileIndex: file.index
                ) else {
                    return
                }
                advanceFilePriorityPresentationGeneration()
                pendingFilePriorities.removeValue(forKey: file.index)
                let authoritativeBatch = await store.fileBatch(
                    for: torrentID,
                    since: nil
                )
                guard isCurrentFilePriorityMutation(
                    generation,
                    fileIndex: file.index
                ) else {
                    return
                }
                if let authoritativeBatch {
                    guard await applyFileBatch(
                        authoritativeBatch,
                        mutationGeneration: generation,
                        fileIndex: file.index
                    ) else {
                        return
                    }
                } else {
                    scheduleFilePresentation()
                }
                fileError = errorMessage
            }
        }
    }

    @MainActor
    private func scheduleFilePresentation() {
        guard let batch = latestFileBatch else {
            return
        }
        filePresentationTask?.cancel()
        let presentationGeneration = filePriorityPresentationGeneration
        let pendingPriorities = pendingFilePriorities
        let taskID = UUID()
        filePresentationTaskID = taskID
        filePresentationTask = Task { @MainActor in
            defer {
                if filePresentationTaskID == taskID {
                    filePresentationTask = nil
                    filePresentationTaskID = nil
                }
            }
            do {
                let presentation = try await TorrentFileBatchPresentation.prepare(
                    batch: batch,
                    pendingPriorities: pendingPriorities
                )
                try Task.checkCancellation()
                guard presentationGeneration
                        == filePriorityPresentationGeneration else {
                    return
                }
                applyFileBatchPresentation(
                    presentation,
                    sourceBatch: batch
                )
            } catch is CancellationError {
                return
            } catch {
                assertionFailure(
                    "Unexpected file presentation error: \(error)"
                )
            }
        }
    }

    @MainActor
    private func applyFileBatch(
        _ batch: TorrentFileBatch,
        mutationGeneration: UInt64,
        fileIndex: Int32
    ) async -> Bool {
        let presentationGeneration = filePriorityPresentationGeneration
        let pendingPriorities = pendingFilePriorities
        do {
            let presentation = try await TorrentFileBatchPresentation.prepare(
                batch: batch,
                pendingPriorities: pendingPriorities
            )
            guard isCurrentFilePriorityMutation(
                mutationGeneration,
                fileIndex: fileIndex
            ),
            presentationGeneration == filePriorityPresentationGeneration else {
                return false
            }
            applyFileBatchPresentation(
                presentation,
                sourceBatch: batch
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            assertionFailure(
                "Unexpected file presentation error: \(error)"
            )
            return false
        }
    }

    @MainActor
    private func refreshOptions(
        token: UUID,
        torrentID: TorrentItem.ID
    ) async {
        guard isCurrentOptionsRefresh(token) else {
            return
        }
        torrentOptions = nil
        sourcePolicy = nil
        optionsLoaded = false
        optionsError = nil

        do {
            let loadedOptions = try await store.torrentOptions(for: torrentID)
            guard isCurrentOptionsRefresh(token) else {
                return
            }
            let loadedSourcePolicy = try await store.sourcePolicy(for: torrentID)
            guard isCurrentOptionsRefresh(token) else {
                return
            }
            torrentOptions = loadedOptions
            sourcePolicy = loadedSourcePolicy
            optionsLoaded = true
        } catch {
            guard isCurrentOptionsRefresh(token) else {
                return
            }
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

    private var httpsTrackerPolicyBinding: Binding<TorrentHTTPSTrackerPolicyOverride> {
        Binding {
            sourcePolicy?.httpsTrackerPolicy ?? .inherit
        } set: { newValue in
            guard var updatedPolicy = sourcePolicy else {
                return
            }
            updatedPolicy.httpsTrackerPolicy = newValue
            updatedPolicy.effectiveHTTPSTrackerPolicy = switch newValue {
            case .inherit:
                store.settings.httpsTrackerPolicy
            case .original:
                .original
            case .prefer:
                .prefer
            case .require:
                .require
            }
            sourcePolicy = updatedPolicy
            scheduleSourcePolicyMutation(
                key: .httpsTracker,
                mutation: .httpsTracker(newValue)
            )
        }
    }

    private var httpsWebSeedPolicyBinding: Binding<TorrentHTTPSWebSeedPolicyOverride> {
        Binding {
            sourcePolicy?.httpsWebSeedPolicy ?? .inherit
        } set: { newValue in
            guard var updatedPolicy = sourcePolicy else {
                return
            }
            updatedPolicy.httpsWebSeedPolicy = newValue
            updatedPolicy.effectiveHTTPSWebSeedPolicy = switch newValue {
            case .inherit:
                store.settings.httpsWebSeedPolicy
            case .original:
                .original
            case .require:
                .require
            }
            sourcePolicy = updatedPolicy
            scheduleSourcePolicyMutation(
                key: .httpsWebSeed,
                mutation: .httpsWebSeed(newValue)
            )
        }
    }

    private func httpsTrackerPolicyTitle(_ policy: TorrentHTTPSTrackerPolicyOverride) -> String {
        policy == .inherit
            ? "Inherit (\(store.settings.httpsTrackerPolicy.title))"
            : policy.title
    }

    private func httpsWebSeedPolicyTitle(_ policy: TorrentHTTPSWebSeedPolicyOverride) -> String {
        policy == .inherit
            ? "Inherit (\(store.settings.httpsWebSeedPolicy.title))"
            : policy.title
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
        scheduleSourcePolicyMutation(
            key: .boolean(field),
            mutation: .boolean(field: field, enabled: newValue)
        )
    }

    @MainActor
    private func scheduleSourcePolicyMutation(
        key: TorrentInfoSourcePolicyMutationKey,
        mutation: TorrentSourcePolicyMutation
    ) {
        precondition(
            sourcePolicyMutationGeneration != UInt64.max,
            "Source-policy mutation generation exhausted"
        )
        sourcePolicyMutationGeneration += 1
        let mutationGeneration = sourcePolicyMutationGeneration
        let torrentID = torrent.id
        let taskID = UUID()
        sourcePolicyMutationTasks[key]?.cancel()
        sourcePolicyMutationTaskIDs[key] = taskID
        sourcePolicyMutationTasks[key] = Task { @MainActor in
            defer {
                if sourcePolicyMutationTaskIDs[key] == taskID {
                    sourcePolicyMutationTasks.removeValue(forKey: key)
                    sourcePolicyMutationTaskIDs.removeValue(forKey: key)
                }
            }
            await setSourcePolicy(
                mutation: mutation,
                torrentID: torrentID,
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
        mutation: TorrentSourcePolicyMutation,
        torrentID: TorrentItem.ID,
        mutationGeneration: UInt64
    ) async {
        do {
            try await store.setSourcePolicy(for: torrentID, mutation: mutation)
            guard isCurrentSourcePolicyMutation(mutationGeneration) else {
                return
            }
            let confirmedPolicy = try await store.sourcePolicy(for: torrentID)
            guard isCurrentSourcePolicyMutation(mutationGeneration) else {
                return
            }
            sourcePolicy = confirmedPolicy
            try? await store.requestSources(for: torrentID)
            guard isCurrentSourcePolicyMutation(mutationGeneration) else {
                return
            }
            let trackerBatch = await store.trackerBatch(for: torrentID, since: nil)
            guard isCurrentSourcePolicyMutation(mutationGeneration) else {
                return
            }
            let webSeedBatch = await store.webSeedBatch(for: torrentID, since: nil)
            guard isCurrentSourcePolicyMutation(mutationGeneration) else {
                return
            }
            let peerSources = await store.peerSources(for: torrentID)
            guard isCurrentSourcePolicyMutation(mutationGeneration) else {
                return
            }
            let refreshedWebSeedActivity = await store.webSeedActivity(for: torrentID)
            guard isCurrentSourcePolicyMutation(mutationGeneration) else {
                return
            }
            if let trackerBatch {
                trackerRevision = trackerBatch.revision
                trackers = trackerBatch.trackers
            }
            if let webSeedBatch {
                webSeedRevision = webSeedBatch.revision
                webSeeds = webSeedBatch.webSeeds
            }
            if let refreshedWebSeedActivity {
                webSeedActivity = refreshedWebSeedActivity
            }
            if let peerSources {
                self.peerSources = peerSources
            }
            sourcesLoaded = true
            sourceError = nil
            optionsError = nil
        } catch {
            guard isCurrentSourcePolicyMutation(mutationGeneration) else {
                return
            }
            let errorMessage = error.localizedDescription
            let confirmedPolicy = try? await store.sourcePolicy(for: torrentID)
            guard isCurrentSourcePolicyMutation(mutationGeneration) else {
                return
            }
            sourceError = errorMessage
            optionsError = errorMessage
            sourcePolicy = confirmedPolicy
        }
    }

    @MainActor
    private func refreshSources(
        token: UUID,
        torrentID: TorrentItem.ID
    ) async {
        guard isCurrentSourcesRefresh(token) else {
            return
        }
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

        while isCurrentSourcesRefresh(token) {
            let mutationGeneration = sourcePolicyMutationGeneration
            let loadedSourcePolicy: TorrentSourcePolicy
            do {
                loadedSourcePolicy = try await store.sourcePolicy(for: torrentID)
                guard isCurrentSourcesRefresh(token) else {
                    return
                }
                guard mutationGeneration == sourcePolicyMutationGeneration else {
                    continue
                }
                try await store.requestSources(for: torrentID)
                guard isCurrentSourcesRefresh(token) else {
                    return
                }
                guard mutationGeneration == sourcePolicyMutationGeneration else {
                    continue
                }
            } catch {
                guard isCurrentSourcesRefresh(token) else {
                    return
                }
                guard mutationGeneration == sourcePolicyMutationGeneration else {
                    continue
                }
                sourceError = error.localizedDescription
                sourcesLoaded = true
                return
            }

            try? await Task.sleep(for: .milliseconds(350))
            guard isCurrentSourcesRefresh(token) else {
                return
            }
            guard mutationGeneration == sourcePolicyMutationGeneration else {
                continue
            }
            let trackerBatch = await store.trackerBatch(
                for: torrentID,
                since: trackerRevision
            )
            guard isCurrentSourcesRefresh(token) else {
                return
            }
            guard mutationGeneration == sourcePolicyMutationGeneration else {
                continue
            }
            let webSeedBatch = await store.webSeedBatch(
                for: torrentID,
                since: webSeedRevision
            )
            guard isCurrentSourcesRefresh(token) else {
                return
            }
            guard mutationGeneration == sourcePolicyMutationGeneration else {
                continue
            }
            let refreshedWebSeedActivity = await store.webSeedActivity(for: torrentID)
            guard isCurrentSourcesRefresh(token) else {
                return
            }
            guard mutationGeneration == sourcePolicyMutationGeneration else {
                continue
            }
            let refreshedPeerSources = await store.peerSources(for: torrentID)
            guard isCurrentSourcesRefresh(token) else {
                return
            }
            guard mutationGeneration == sourcePolicyMutationGeneration else {
                continue
            }

            sourcePolicy = loadedSourcePolicy
            if let trackerBatch {
                trackerRevision = trackerBatch.revision
                trackers = trackerBatch.trackers
            }
            if let webSeedBatch {
                webSeedRevision = webSeedBatch.revision
                webSeeds = webSeedBatch.webSeeds
            }
            if let refreshedWebSeedActivity,
               webSeedActivity != refreshedWebSeedActivity {
                webSeedActivity = refreshedWebSeedActivity
            }
            if let refreshedPeerSources,
               peerSources != refreshedPeerSources {
                peerSources = refreshedPeerSources
            }
            sourcesLoaded = true
            sourceError = nil

            try? await Task.sleep(for: .seconds(3))
            guard isCurrentSourcesRefresh(token) else {
                return
            }
        }
    }

    @MainActor
    private func refreshFiles(
        token: UUID,
        torrentID: TorrentItem.ID,
        hasMetadata: Bool
    ) async {
        guard isCurrentFilesRefresh(token) else {
            return
        }
        latestFileBatch = nil
        fileSections = []
        displayedFileCount = 0
        hasLimitedFileSections = false
        fileRevision = nil
        filesLoaded = false
        fileError = nil
        showsAllFiles = false

        while isCurrentFilesRefresh(token) {
            guard hasMetadata else {
                filesLoaded = true
                try? await Task.sleep(for: .seconds(2))
                guard isCurrentFilesRefresh(token) else {
                    return
                }
                continue
            }

            do {
                try await store.requestFiles(for: torrentID)
                guard isCurrentFilesRefresh(token) else {
                    return
                }
            } catch {
                guard isCurrentFilesRefresh(token) else {
                    return
                }
                fileError = error.localizedDescription
                filesLoaded = true
                return
            }

            try? await Task.sleep(for: .milliseconds(350))
            guard isCurrentFilesRefresh(token) else {
                return
            }
            let fileBatch = await store.fileBatch(
                for: torrentID,
                since: fileRevision
            )
            guard isCurrentFilesRefresh(token) else {
                return
            }
            if let fileBatch {
                let presentationGeneration = filePriorityPresentationGeneration
                let pendingPriorities = pendingFilePriorities
                let presentation: TorrentFileBatchPresentation
                do {
                    presentation = try await TorrentFileBatchPresentation.prepare(
                        batch: fileBatch,
                        pendingPriorities: pendingPriorities
                    )
                } catch is CancellationError {
                    return
                } catch {
                    assertionFailure("Unexpected file presentation error: \(error)")
                    return
                }
                guard isCurrentFilesRefresh(token) else {
                    return
                }
                guard presentationGeneration == filePriorityPresentationGeneration else {
                    continue
                }
                applyFileBatchPresentation(
                    presentation,
                    sourceBatch: fileBatch
                )
                fileError = nil
            }

            try? await Task.sleep(for: .seconds(2))
            guard isCurrentFilesRefresh(token) else {
                return
            }
        }
    }

    @MainActor
    private func applyFileBatchPresentation(
        _ presentation: TorrentFileBatchPresentation,
        sourceBatch: TorrentFileBatch
    ) {
        guard fileRevision.map({ presentation.revision >= $0 }) ?? true else {
            return
        }
        fileRevision = presentation.revision
        latestFileBatch = sourceBatch
        pendingFilePriorities = presentation.remainingPendingPriorities
        fileSections = presentation.sections
        displayedFileCount = presentation.displayedFileCount
        hasLimitedFileSections = presentation.hasLimitedSections
        filesLoaded = true
    }

    @MainActor
    private func refreshPieceMap(
        token: UUID,
        torrentID: TorrentItem.ID,
        hasMetadata: Bool
    ) async {
        guard isCurrentPieceMapRefresh(token) else {
            return
        }
        pieceMap = .empty
        pieceMapRevision = nil
        pieceMapLoaded = false
        pieceMapError = nil

        while isCurrentPieceMapRefresh(token) {
            guard hasMetadata else {
                pieceMapLoaded = true
                try? await Task.sleep(for: .seconds(2))
                guard isCurrentPieceMapRefresh(token) else {
                    return
                }
                continue
            }

            do {
                try await store.requestPieceMap(for: torrentID)
                guard isCurrentPieceMapRefresh(token) else {
                    return
                }
            } catch {
                guard isCurrentPieceMapRefresh(token) else {
                    return
                }
                pieceMapError = error.localizedDescription
                pieceMapLoaded = true
                return
            }

            let pieceMapBatch = await store.pieceMapBatch(
                for: torrentID,
                since: pieceMapRevision
            )
            guard isCurrentPieceMapRefresh(token) else {
                return
            }
            if let pieceMapBatch {
                pieceMapRevision = pieceMapBatch.revision
                pieceMap = pieceMapBatch.pieceMap
                pieceMapLoaded = true
                pieceMapError = nil
            }

            try? await Task.sleep(for: .seconds(1))
            guard isCurrentPieceMapRefresh(token) else {
                return
            }
        }
    }

    @MainActor
    private func isCurrentSourcePolicyMutation(_ generation: UInt64) -> Bool {
        !Task.isCancelled && generation == sourcePolicyMutationGeneration
    }

    @MainActor
    private func isCurrentOptionsMutation(_ generation: UInt64) -> Bool {
        !Task.isCancelled && generation == torrentOptionsMutationGeneration
    }

    @MainActor
    private func isCurrentFilePriorityMutation(
        _ generation: UInt64,
        fileIndex: Int32
    ) -> Bool {
        !Task.isCancelled && filePriorityMutationGenerations[fileIndex] == generation
    }

    @MainActor
    private func advanceFilePriorityPresentationGeneration() {
        precondition(
            filePriorityPresentationGeneration != UInt64.max,
            "File-priority presentation generation exhausted"
        )
        filePriorityPresentationGeneration += 1
    }

    @MainActor
    private func isCurrentSourcesRefresh(_ token: UUID) -> Bool {
        !Task.isCancelled && sourcesRefreshToken == token
    }

    @MainActor
    private func isCurrentOptionsRefresh(_ token: UUID) -> Bool {
        !Task.isCancelled && optionsRefreshToken == token
    }

    @MainActor
    private func isCurrentFilesRefresh(_ token: UUID) -> Bool {
        !Task.isCancelled && filesRefreshToken == token
    }

    @MainActor
    private func isCurrentPieceMapRefresh(_ token: UUID) -> Bool {
        !Task.isCancelled && pieceMapRefreshToken == token
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
