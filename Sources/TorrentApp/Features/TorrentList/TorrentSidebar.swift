import SwiftUI

struct TorrentSidebar: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let sidebarState: TorrentSidebarState
    @Binding var selectedSelection: TorrentSidebarSelection
    let createLabel: (String) -> TorrentLabel?
    let renameLabel: (TorrentLabel.ID, String) -> Void
    let deleteLabel: (TorrentLabel.ID) -> Void
    @AppStorage("TorrentSidebar.StatusExpanded") private var statusExpanded = true
    @AppStorage("TorrentSidebar.PriorityExpanded") private var priorityExpanded = false
    @AppStorage("TorrentSidebar.LabelsExpanded") private var labelsExpanded = false
    @AppStorage("TorrentSidebar.TrackersExpanded") private var trackersExpanded = false
    @State private var labelEditor: TorrentLabelEditorRequest?

    var body: some View {
        List(selection: selection) {
            sidebarRow(for: .all)

            DisclosureGroup(isExpanded: $statusExpanded) {
                ForEach(TorrentSidebarScope.statusFilterScopes) { scope in
                    sidebarRow(for: scope)
                }
            } label: {
                disclosureHeader("Status", systemImage: "circle.grid.2x2", isExpanded: $statusExpanded)
            }

            DisclosureGroup(isExpanded: $priorityExpanded) {
                ForEach(TorrentSidebarScope.priorityScopes) { scope in
                    sidebarRow(for: scope)
                }
            } label: {
                disclosureHeader("Priority", systemImage: "flag", isExpanded: $priorityExpanded)
            }

            DisclosureGroup(isExpanded: $labelsExpanded) {
                unlabeledRow

                ForEach(snapshot.labelRows) { row in
                    labelRow(for: row)
                }
            } label: {
                HStack {
                    disclosureHeader("Labels", systemImage: "tag", isExpanded: $labelsExpanded)

                    Button {
                        labelsExpanded = true
                        labelEditor = .create
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel("New Label")
                    .help("New Label")
                }
            }

            DisclosureGroup(isExpanded: $trackersExpanded) {
                noTrackersRow

                ForEach(snapshot.trackerHostRows) { row in
                    trackerHostRow(row)
                }
            } label: {
                disclosureHeader("Trackers", systemImage: "antenna.radiowaves.left.and.right", isExpanded: $trackersExpanded)
            }
        }
        .listStyle(.sidebar)
        .reducedTransparencySidebarBackground(enabled: reduceTransparency)
        .navigationTitle("Torrents")
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        .onAppear {
            statusExpanded = statusExpanded || selectedSelection.isStatusFilterScope
            priorityExpanded = priorityExpanded || selectedSelection.isPriorityScope
            labelsExpanded = labelsExpanded || selectedSelection.isLabelScope
            trackersExpanded = trackersExpanded || selectedSelection.isTrackerScope
            sanitizeSelection(for: snapshot)
        }
        .onChange(of: selectedSelection) { _, selection in
            if selection.isStatusFilterScope {
                statusExpanded = true
            }
            if selection.isPriorityScope {
                priorityExpanded = true
            }
            if selection.isLabelScope {
                labelsExpanded = true
            }
            if selection.isTrackerScope {
                trackersExpanded = true
            }
        }
        .onChange(of: snapshot) { _, snapshot in
            sanitizeSelection(for: snapshot)
        }
        .sheet(item: $labelEditor) { request in
            TorrentLabelEditorView(
                title: request.title,
                initialName: request.initialName,
                saveTitle: request.mode == .create ? "Create" : "Rename"
            ) { name in
                switch request.mode {
                case .create:
                    _ = createLabel(name)
                case .rename(let label):
                    renameLabel(label.id, name)
                }
                labelEditor = nil
            } cancel: {
                labelEditor = nil
            }
        }
    }

    private func disclosureHeader(_ title: String, systemImage: String, isExpanded: Binding<Bool>) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                isExpanded.wrappedValue.toggle()
            }
    }

    private func sidebarRow(for scope: TorrentSidebarScope) -> some View {
        Label {
            Text(scope.title)
        } icon: {
            Image(systemName: scope.systemImage)
                .foregroundStyle(sidebarIconTint(for: scope))
        }
            .badge(snapshot.count(for: scope))
            .tag(TorrentSidebarSelection.scope(scope))
    }

    private func sidebarIconTint(for scope: TorrentSidebarScope) -> Color {
        switch scope {
        case .active:
            return .orange.opacity(0.86)
        case .downloading:
            return .blue
        case .seeding:
            return .green
        case .completed:
            return .green.opacity(0.82)
        case .errors:
            return .red
        case .all, .queued, .paused, .priorityHigh, .priorityNormal, .priorityLow:
            return .secondary
        }
    }

    private var unlabeledRow: some View {
        Label("Unlabeled", systemImage: "tag.slash")
            .badge(snapshot.unlabeledCount)
            .tag(TorrentSidebarSelection.unlabeled)
    }

    private var noTrackersRow: some View {
        Label("No Trackers", systemImage: "antenna.radiowaves.left.and.right.slash")
            .badge(snapshot.noTrackersCount)
            .tag(TorrentSidebarSelection.noTrackers)
    }

    private func labelRow(for row: TorrentSidebarLabelSnapshot) -> some View {
        let label = row.label
        return Label(label.name, systemImage: "tag")
            .badge(row.count)
            .tag(TorrentSidebarSelection.label(label.id))
            .contextMenu {
                Button {
                    labelEditor = TorrentLabelEditorRequest(mode: .rename(label))
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    if selectedSelection == .label(label.id) {
                        selectedSelection = .all
                    }
                    deleteLabel(label.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    private func trackerHostRow(_ row: TorrentSidebarTrackerHostSnapshot) -> some View {
        Label(row.host, systemImage: "network")
            .badge(row.count)
            .tag(TorrentSidebarSelection.trackerHost(row.host))
            .help(row.host)
    }

    private var selection: Binding<TorrentSidebarSelection?> {
        Binding {
            selectedSelection
        } set: { scope in
            selectedSelection = scope ?? .all
        }
    }

    private var snapshot: TorrentSidebarSnapshot {
        sidebarState.snapshot
    }

    private func sanitizeSelection(for snapshot: TorrentSidebarSnapshot) {
        switch selectedSelection {
        case .label(let labelID):
            if !snapshot.labelRows.contains(where: { $0.id == labelID }) {
                selectedSelection = .all
            }
        case .trackerHost(let host):
            if !snapshot.trackerHostRows.contains(where: { $0.host == host }) {
                selectedSelection = .all
            }
        case .scope, .unlabeled, .noTrackers:
            break
        }
    }
}

private extension View {
    @ViewBuilder
    func reducedTransparencySidebarBackground(enabled: Bool) -> some View {
        if enabled {
            self
                .scrollContentBackground(.hidden)
                .background(.bar)
        } else {
            self
        }
    }
}
