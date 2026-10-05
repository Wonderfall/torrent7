import SwiftUI
import TorrentAppInfrastructure
import TorrentEngineModel

/// The same native outline table is used before adding and during a transfer.
struct TorrentFileOutline: View {
    let tree: TorrentFileTree
    @Binding var sortOrder: [TorrentFileTree.Sort]
    var showsProgress = false
    var isEditing = false
    let setPriority: (TorrentFilePriorityChange) -> Void
    var revealInFinder: ((TorrentFileTree.Node.ID) -> Void)?

    @State private var selection = Set<TorrentFileTree.Node.ID>()
    @State private var expansion = [TorrentFileTree.Node.ID: Bool]()
    @State private var searchExpansion = [TorrentFileTree.Node.ID: Bool]()
    @State private var images = TorrentFileIconImages()
    @FocusState private var isFocused: Bool

    var body: some View {
        Table(of: TorrentFileTree.Node.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", sortUsing: TorrentFileTree.Sort(.name)) { node in
                let isSkipped = node.priority == .skip
                HStack(spacing: 6) {
                    FileItemIcon(source: iconSource(for: node), images: images)
                        .saturation(isSkipped ? 0 : 1)
                        .opacity(isSkipped ? 0.5 : 1)
                    Text(node.name)
                        .foregroundStyle(isSkipped ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(revealInFinder != nil
                    ? "\(node.path)\nDouble-click to reveal in Finder." : node.path)
            }
            .width(min: 120, max: .infinity)
            .disabledCustomizationBehavior(.resize)

            TableColumn("Size", sortUsing: TorrentFileTree.Sort(.size)) { node in
                Text(ByteFormat.size(node.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(72)

            if showsProgress {
                TableColumn("Progress", sortUsing: TorrentFileTree.Sort(.progress)) { node in
                    TorrentFileProgressLabel(node: node)
                }
                .width(72)
            }

            TableColumn("Priority", sortUsing: TorrentFileTree.Sort(.priority)) { node in
                TorrentFilePriorityPicker(priority: node.priority) { priority in
                    applyPriority(priority, to: [node.id])
                }
                .disabled(isEditing)
                .accessibilityLabel("Priority for \(node.path)")
                .help(node.children == nil ? "File priority" : tree.query.isEmpty
                    ? "Set priority for all \(node.fileIndices.count) files in this folder"
                    : "Set priority for \(node.fileIndices.count) matching files in this folder")
            }
            .width(86)
        } rows: {
            TorrentFileOutlineRows(
                nodes: tree.roots, isRoot: true, expandsMatches: !tree.query.isEmpty,
                expansion: tree.query.isEmpty ? $expansion : $searchExpansion
            )
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds()
        .controlSize(.small)
        // Grouped forms don't activate embedded tables on click.
        .focused($isFocused)
        .simultaneousGesture(TapGesture().onEnded { isFocused = true })
        .accessibilityLabel("Torrent files")
        // A grouped Form owns scrolling for its embedded tables. Let the table
        // size itself to its rows so the form can scroll the entire hierarchy.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, tree.fileCount == 0 ? 48 : 0)
        .overlay(alignment: .bottom) {
            if tree.fileCount == 0 {
                Text("No Matching Files")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
            }
        }
        .onChange(of: tree.query) { _, _ in
            searchExpansion.removeAll()
            selection.removeAll()
        }
        .contextMenu(forSelectionType: TorrentFileTree.Node.ID.self) { ids in
            if ids.count == 1, let id = ids.first, let revealInFinder {
                Button("Reveal in Finder") { revealInFinder(id) }
                Divider()
            }
            if !ids.isEmpty {
                Menu("Priority") {
                    ForEach(TorrentFilePriority.allCases) { priority in
                        Button(priority.title) { applyPriority(priority, to: ids) }
                    }
                }
                .disabled(isEditing)
            }
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first else { return }
            revealInFinder?(id)
        }
        .task(id: tree.filenameExtensions) {
            guard let loaded = try? await FileIconService.shared.icons(for: tree.filenameExtensions),
                  !Task.isCancelled else { return }
            images.icons = loaded
        }
    }

    private func iconSource(for node: TorrentFileTree.Node) -> TorrentFileIconSource {
        if node.children != nil { return .folder }
        return node.filenameExtension.isEmpty ? .genericFile : .fileExtension(node.filenameExtension)
    }

    private func applyPriority(_ priority: TorrentFilePriority, to ids: Set<TorrentFileTree.Node.ID>) {
        guard !isEditing, let change = tree.priorityChange(for: ids, priority: priority) else { return }
        setPriority(change)
    }
}

enum TorrentFileTransferState: Sendable {
    case active, paused, queued

    init(torrent: TorrentItem) {
        if torrent.manuallyPaused { self = .paused }
        else if torrent.queued { self = .queued }
        else { self = .active }
    }
}

extension EnvironmentValues {
    @Entry var torrentFileTransferState = TorrentFileTransferState.active
}

private struct TorrentFileProgressLabel: View {
    let node: TorrentFileTree.Node
    // Read the changing torrent state in each cell, even when Table caches its
    // column content and no file progress has changed since pausing or resuming.
    @Environment(\.torrentFileTransferState) private var transferState

    var body: some View {
        let progress = node.progress.formatted(.percent.precision(.fractionLength(0)))
        let description = "\(status) · \(ByteFormat.size(node.downloaded)) of \(ByteFormat.size(node.size))"
        Text(progress)
            .monospacedDigit()
            .foregroundStyle(node.priority == .skip ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(description)
            .accessibilityLabel("Progress")
            .accessibilityValue("\(progress), \(description)")
    }

    private var status: String {
        if node.priority == .skip { return "Skipped" }
        if node.progress >= 1 { return "Finished" }
        switch transferState {
        case .paused: return "Paused"
        case .queued: return "Queued"
        case .active: return node.downloaded > 0 ? "Downloading" : "Waiting"
        }
    }
}

private struct TorrentFileOutlineRows: TableRowContent {
    let nodes: [TorrentFileTree.Node]
    var isRoot = false
    var expandsMatches = false
    @Binding var expansion: [TorrentFileTree.Node.ID: Bool]

    var tableRowBody: some TableRowContent<TorrentFileTree.Node> {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureTableRow(node, isExpanded: Binding(
                    get: { expansion[node.id] ?? (isRoot || expandsMatches) },
                    set: { expansion[node.id] = $0 }
                )) {
                    Self(nodes: children, expandsMatches: expandsMatches, expansion: $expansion)
                }
            } else {
                TableRow(node)
            }
        }
    }
}

struct TorrentFilePriorityPicker: View {
    let priority: TorrentFilePriority?
    let setPriority: (TorrentFilePriority) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Picker("Priority", selection: Binding(
            get: { priority },
            set: { if let priority = $0 { setPriority(priority) } }
        )) {
            if priority == nil {
                Text("Mixed").tag(Optional<TorrentFilePriority>.none).disabled(true)
            }
            ForEach(TorrentFilePriority.allCases) { priority in
                Text(priority.title).tag(Optional(priority))
            }
        }
        .pickerStyle(.menu)
        .buttonStyle(.borderless)
        .labelsHidden()
        .background(.quaternary.opacity(isHovering && isEnabled ? 1 : 0), in: .rect(cornerRadius: 5))
        .onHover { isHovering = $0 }
    }
}
