import SwiftUI
import TorrentEngineModel

struct TorrentBrowser: View {
    let torrentState: TorrentListState
    let selectionState: TorrentSelectionState
    let selection: TorrentSidebarSelection
    let searchText: String
    let labels: [TorrentLabel]
    let labelIDsForTorrent: (TorrentItem.ID) -> Set<TorrentLabel.ID>
    let labelsForTorrent: (TorrentItem.ID) -> [TorrentLabel]
    let trackerHostsForTorrent: (TorrentItem.ID) -> Set<String>
    let showInfo: (TorrentItem.ID, TorrentInfoTab) -> Void
    let pause: (Set<TorrentItem.ID>) -> Void
    let resume: (Set<TorrentItem.ID>) -> Void
    let reannounce: (Set<TorrentItem.ID>) -> Void
    let forceRecheck: (Set<TorrentItem.ID>) -> Void
    let togglePause: (TorrentItem.ID) -> Void
    let revealInFinder: (Set<TorrentItem.ID>) -> Void
    let setQueuePriority: (Set<TorrentItem.ID>, TorrentQueuePriority) -> Void
    let moveInQueue: (Set<TorrentItem.ID>, TorrentQueueMove) -> Void
    let toggleLabel: (TorrentLabel.ID, Set<TorrentItem.ID>) -> Void
    let requestRemoval: (Set<TorrentItem.ID>) -> Void
    let addTorrent: () -> Void

    var body: some View {
        Group {
            if torrentState.rows.isEmpty {
                ContentUnavailableView("No Torrents", systemImage: "arrow.down.doc", description: Text("Drop or click to add a .torrent file."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: addTorrent)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Add Torrent")
                .accessibilityHint("Opens the file picker.")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    addTorrent()
                }
            } else if filteredRows.isEmpty {
                if hasSearchQuery {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(selection.emptyTitle(labels: labels), systemImage: selection.emptySystemImage(labels: labels))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                TorrentList(
                    rows: filteredRows,
                    selectionState: selectionState,
                    labels: labels,
                    labelsForTorrent: labelsForTorrent,
                    labelIDsForTorrent: labelIDsForTorrent,
                    transferMetricState: torrentState.transferMetricState(for:),
                    showInfo: showInfo,
                    pause: pause,
                    resume: resume,
                    reannounce: reannounce,
                    forceRecheck: forceRecheck,
                    togglePause: togglePause,
                    revealInFinder: revealInFinder,
                    setQueuePriority: setQueuePriority,
                    moveInQueue: moveInQueue,
                    toggleLabel: toggleLabel,
                    requestRemoval: requestRemoval
                )
            }
        }
        .onChange(of: filteredTorrentIDs) { _, ids in
            selectionState.ids.formIntersection(ids)
        }
    }

    private var filteredRows: [TorrentRowSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedRows = torrentState.rows.filter { row in
            selection.contains(
                row,
                labelIDs: labelIDsForTorrent(row.id),
                trackerHosts: trackerHostsForTorrent(row.id)
            )
        }
        guard !query.isEmpty else {
            return scopedRows
        }
        return scopedRows.filter { row in
            row.name.localizedStandardContains(query)
        }
    }

    private var filteredTorrentIDs: Set<TorrentItem.ID> {
        Set(filteredRows.map(\.id))
    }

    private var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
