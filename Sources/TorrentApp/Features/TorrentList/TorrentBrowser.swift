import Observation
import SwiftUI
import TorrentEngineModel

struct TorrentBrowserFilterRequestID: Hashable, Sendable {
    let rowRevision: UInt64
    let metadataRevision: UInt64
    let selection: TorrentSidebarSelection
    let query: String
}

struct TorrentBrowserProjection: Sendable {
    private static let maximumQueryByteCount = 1_024

    let rows: [TorrentRowSnapshot]
    let ids: Set<TorrentItem.ID>
    let orderedIDs: [TorrentItem.ID]
    let rowIndicesByID: [TorrentItem.ID: Int]
    let query: String
    let labelsByTorrentID: [
        TorrentItem.ID: [TorrentLabel]
    ]

    static func boundedQueryInput(_ query: String) -> String {
        String(
            decoding: query.utf8.prefix(maximumQueryByteCount),
            as: UTF8.self
        )
    }

    @concurrent
    static func prepare(
        rows: [TorrentRowSnapshot],
        selection: TorrentSidebarSelection,
        query: String,
        labels: [TorrentLabel],
        labelAssignments: [TorrentItem.ID: Set<TorrentLabel.ID>],
        trackerHostsByTorrentID: [TorrentItem.ID: Set<String>]
    ) async throws -> Self {
        try Task.checkCancellation()
        let boundedQuery = boundedQueryInput(query)
        let normalizedQuery = boundedQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        try Task.checkCancellation()
        var filteredRows = [TorrentRowSnapshot]()
        var filteredIDs = Set<TorrentItem.ID>()
        var orderedIDs = [TorrentItem.ID]()
        var rowIndicesByID = [TorrentItem.ID: Int]()
        var labelsByID = [TorrentLabel.ID: TorrentLabel]()
        var labelIndicesByID = [TorrentLabel.ID: Int]()
        var labelsByTorrentID =
            [TorrentItem.ID: [TorrentLabel]]()
        filteredRows.reserveCapacity(rows.count)
        filteredIDs.reserveCapacity(rows.count)
        orderedIDs.reserveCapacity(rows.count)
        rowIndicesByID.reserveCapacity(rows.count)
        labelsByID.reserveCapacity(labels.count)
        labelIndicesByID.reserveCapacity(labels.count)
        for (index, label) in labels.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            labelsByID[label.id] = label
            labelIndicesByID[label.id] = index
        }
        var visitedAssignmentCount = 0

        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            guard selection.contains(
                row,
                labelIDs: labelAssignments[row.id] ?? [],
                trackerHosts: trackerHostsByTorrentID[row.id] ?? []
            ), normalizedQuery.isEmpty
                || row.name.localizedStandardContains(normalizedQuery) else {
                continue
            }
            rowIndicesByID[row.id] = filteredRows.count
            filteredRows.append(row)
            filteredIDs.insert(row.id)
            orderedIDs.append(row.id)
            if let assignedLabelIDs = labelAssignments[row.id] {
                var assignedLabels = [TorrentLabel]()
                assignedLabels.reserveCapacity(assignedLabelIDs.count)
                for labelID in assignedLabelIDs {
                    visitedAssignmentCount += 1
                    if visitedAssignmentCount.isMultiple(of: 128) {
                        try Task.checkCancellation()
                    }
                    if let label = labelsByID[labelID] {
                        assignedLabels.append(label)
                    }
                }
                assignedLabels.sort {
                    (labelIndicesByID[$0.id] ?? .max)
                        < (labelIndicesByID[$1.id] ?? .max)
                }
                if !assignedLabels.isEmpty {
                    labelsByTorrentID[row.id] = assignedLabels
                }
            }
        }
        try Task.checkCancellation()
        return Self(
            rows: filteredRows,
            ids: filteredIDs,
            orderedIDs: orderedIDs,
            rowIndicesByID: rowIndicesByID,
            query: normalizedQuery,
            labelsByTorrentID: labelsByTorrentID
        )
    }
}

struct TorrentListSelectionSummary: Sendable {
    let selectionRevision: UInt64
    let filterRevision: UInt64
    let ids: Set<TorrentItem.ID>
    let firstID: TorrentItem.ID?
    let hasMetadata: Bool
    let canPause: Bool
    let canResume: Bool
    let commonQueuePriority: TorrentQueuePriority?
    let labelCounts: [TorrentLabel.ID: Int]
    let singleTorrentLabelIDs: Set<TorrentLabel.ID>?

    var count: Int {
        ids.count
    }

    func labeledTorrentCount(for labelID: TorrentLabel.ID) -> Int {
        if let singleTorrentLabelIDs {
            return singleTorrentLabelIDs.contains(labelID) ? 1 : 0
        }
        return labelCounts[labelID] ?? 0
    }

    @concurrent
    static func prepare(
        selectionRevision: UInt64,
        filterRevision: UInt64,
        selectedIDs: Set<TorrentItem.ID>,
        rows: [TorrentRowSnapshot],
        rowIndicesByID: [TorrentItem.ID: Int],
        labelAssignments: [
            TorrentItem.ID: Set<TorrentLabel.ID>
        ]
    ) async throws -> Self {
        try Task.checkCancellation()
        var validIDs = Set<TorrentItem.ID>()
        validIDs.reserveCapacity(
            min(selectedIDs.count, rowIndicesByID.count)
        )
        var firstID: TorrentItem.ID?
        var firstIndex = Int.max
        var hasMetadata = false
        var canPause = false
        var canResume = false
        var commonQueuePriority: TorrentQueuePriority?
        var prioritiesDiffer = false
        var labelCounts = [TorrentLabel.ID: Int]()
        var visitedLabelCount = 0

        for (offset, id) in selectedIDs.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            guard let index = rowIndicesByID[id] else {
                continue
            }
            let row = rows[index]
            validIDs.insert(id)
            if index < firstIndex {
                firstIndex = index
                firstID = id
            }
            hasMetadata = hasMetadata || row.hasMetadata
            canPause = canPause || !row.manuallyPaused
            canResume = canResume || row.manuallyPaused
            if let commonQueuePriority {
                prioritiesDiffer =
                    prioritiesDiffer
                    || commonQueuePriority != row.queuePriority
            } else {
                commonQueuePriority = row.queuePriority
            }
            for labelID in labelAssignments[id] ?? [] {
                visitedLabelCount += 1
                if visitedLabelCount.isMultiple(of: 128) {
                    try Task.checkCancellation()
                }
                labelCounts[labelID, default: 0] += 1
            }
        }
        try Task.checkCancellation()
        return Self(
            selectionRevision: selectionRevision,
            filterRevision: filterRevision,
            ids: validIDs,
            firstID: firstID,
            hasMetadata: hasMetadata,
            canPause: canPause,
            canResume: canResume,
            commonQueuePriority:
                prioritiesDiffer ? nil : commonQueuePriority,
            labelCounts: labelCounts,
            singleTorrentLabelIDs: nil
        )
    }

    static func single(
        row: TorrentRowSnapshot,
        selectionRevision: UInt64,
        filterRevision: UInt64,
        labelIDs: Set<TorrentLabel.ID>
    ) -> Self {
        Self(
            selectionRevision: selectionRevision,
            filterRevision: filterRevision,
            ids: [row.id],
            firstID: row.id,
            hasMetadata: row.hasMetadata,
            canPause: !row.manuallyPaused,
            canResume: row.manuallyPaused,
            commonQueuePriority: row.queuePriority,
            labelCounts: [:],
            singleTorrentLabelIDs: labelIDs
        )
    }
}

struct TorrentListSelectionRequest: Identifiable, Sendable {
    enum Members: Sendable {
        case ids(Set<TorrentItem.ID>)
        case range(
            startID: TorrentItem.ID,
            endID: TorrentItem.ID
        )
    }

    let id = UUID()
    let filterRevision: UInt64
    let expectedSelectionRevision: UInt64?
    let baseIDs: Set<TorrentItem.ID>
    let members: Members
    let anchorID: TorrentItem.ID?
    let focusID: TorrentItem.ID?
}

struct TorrentListSelectionProjection: Sendable {
    let ids: Set<TorrentItem.ID>

    @concurrent
    static func prepare(
        request: TorrentListSelectionRequest,
        orderedIDs: [TorrentItem.ID],
        rowIndicesByID: [TorrentItem.ID: Int]
    ) async throws -> Self {
        try Task.checkCancellation()
        var ids = request.baseIDs
        switch request.members {
        case .ids(let additionalIDs):
            for (offset, id) in additionalIDs.enumerated() {
                if offset.isMultiple(of: 128) {
                    try Task.checkCancellation()
                }
                if rowIndicesByID[id] != nil {
                    ids.insert(id)
                }
            }
        case .range(let startID, let endID):
            guard let startIndex = rowIndicesByID[startID],
                  let endIndex = rowIndicesByID[endID] else {
                return Self(ids: [endID])
            }
            let bounds =
                min(startIndex, endIndex)...max(startIndex, endIndex)
            for (offset, index) in bounds.enumerated() {
                if offset.isMultiple(of: 128) {
                    try Task.checkCancellation()
                }
                ids.insert(orderedIDs[index])
            }
        }
        try Task.checkCancellation()
        return Self(ids: ids)
    }
}

struct TorrentVisibleSelectionProjection: Sendable {
    let ids: Set<TorrentItem.ID>

    @concurrent
    static func prepare(
        selectedIDs: Set<TorrentItem.ID>,
        visibleIDs: Set<TorrentItem.ID>
    ) async throws -> Self {
        try Task.checkCancellation()
        let candidates = selectedIDs.count <= visibleIDs.count
            ? selectedIDs
            : visibleIDs
        let membership = selectedIDs.count <= visibleIDs.count
            ? visibleIDs
            : selectedIDs
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
        return Self(ids: retainedIDs)
    }
}

@MainActor
@Observable
final class TorrentBrowserFilterState {
    private(set) var rows = [TorrentRowSnapshot]()
    private(set) var ids = Set<TorrentItem.ID>()
    private(set) var orderedIDs = [TorrentItem.ID]()
    private(set) var rowIndicesByID = [TorrentItem.ID: Int]()
    private(set) var query = ""
    private(set) var labelsByTorrentID =
        [TorrentItem.ID: [TorrentLabel]]()
    private(set) var revision: UInt64 = 0

    @ObservationIgnored
    private var currentRequestID: TorrentBrowserFilterRequestID?

    func begin(_ requestID: TorrentBrowserFilterRequestID) {
        currentRequestID = requestID
    }

    @discardableResult
    func apply(
        _ projection: TorrentBrowserProjection,
        for requestID: TorrentBrowserFilterRequestID
    ) -> Bool {
        guard currentRequestID == requestID else {
            return false
        }
        rows = projection.rows
        ids = projection.ids
        orderedIDs = projection.orderedIDs
        rowIndicesByID = projection.rowIndicesByID
        query = projection.query
        labelsByTorrentID = projection.labelsByTorrentID
        precondition(revision != UInt64.max)
        revision += 1
        return true
    }
}

struct TorrentBrowser: View {
    let torrentState: TorrentListState
    let selectionState: TorrentSelectionState
    let filterState: TorrentBrowserFilterState
    let selection: TorrentSidebarSelection
    let labels: [TorrentLabel]
    let labelAssignments: [
        TorrentItem.ID: Set<TorrentLabel.ID>
    ]
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
            } else if filterState.rows.isEmpty {
                if hasSearchQuery {
                    ContentUnavailableView.search(text: filterState.query)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(selection.emptyTitle(labels: labels), systemImage: selection.emptySystemImage(labels: labels))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                TorrentList(
                    rows: filterState.rows,
                    visibleIDs: filterState.ids,
                    orderedIDs: filterState.orderedIDs,
                    rowIndicesByID: filterState.rowIndicesByID,
                    rowRevision: filterState.revision,
                    torrentState: torrentState,
                    selectionState: selectionState,
                    labels: labels,
                    labelAssignments: labelAssignments,
                    labelsByTorrentID:
                        filterState.labelsByTorrentID,
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
    }

    private var hasSearchQuery: Bool {
        !filterState.query.isEmpty
    }
}
