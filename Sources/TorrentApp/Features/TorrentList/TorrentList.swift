import AppKit
import SwiftUI
import TorrentEngineModel

private enum TorrentCardStyle {
    static let cornerRadius: CGFloat = 16
}

struct TorrentList: View {
    private static let selectionCoordinateSpace = "TorrentListSelection"

    let rows: [TorrentRowSnapshot]
    let selectionState: TorrentSelectionState
    let labels: [TorrentLabel]
    let labelsForTorrent: (TorrentItem.ID) -> [TorrentLabel]
    let labelIDsForTorrent: (TorrentItem.ID) -> Set<TorrentLabel.ID>
    let transferMetricState: (TorrentItem.ID) -> TorrentTransferMetricsState
    @State private var selectionAnchorID: TorrentItem.ID?
    @State private var activeModifiers = EventModifiers()
    @State private var didHandleRowInteraction = false
    @State private var cardFrames = [TorrentItem.ID: CGRect]()
    @State private var dragSelectionStart: CGPoint?
    @State private var dragSelectionBase = Set<TorrentItem.ID>()
    @State private var lastCardClick: TorrentCardClick?
    @State private var selectAllResponderActivation = 0
    @State private var selectionFocusID: TorrentItem.ID?
    @State private var scrollTargetID: TorrentItem.ID?
    @FocusState private var isListFocused: Bool
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

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(rows) { row in
                            torrentCard(for: row)
                                .id(row.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .gesture(dragSelectionGesture)
                    .onTapGesture {
                        activateListFocus()
                        if didHandleRowInteraction {
                            didHandleRowInteraction = false
                        } else {
                            clearSelection()
                        }
                    }
                }
                .coordinateSpace(.named(Self.selectionCoordinateSpace))
                .overlay {
                    ZStack {
                        RightClickSelectionMonitor(cardFrames: cardFrames, select: selectForContextMenu)
                        SelectAllResponder(
                            activation: selectAllResponderActivation,
                            canSelectAll: !rows.isEmpty,
                            canClearSelection: !selectionState.ids.isEmpty,
                            selectAll: selectAllTorrents,
                            clearSelection: clearSelection,
                            moveSelection: moveKeyboardSelection,
                            openInfo: openKeyboardFocusedInfo,
                            togglePause: toggleKeyboardFocusedTorrents,
                            removeSelection: requestKeyboardRemoval
                        )
                    }
                }
                .onChange(of: scrollTargetID) { _, torrentID in
                    guard let torrentID else {
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.16)) {
                        scrollProxy.scrollTo(torrentID, anchor: .center)
                    }
                }
            }
        }
        .focusable()
        .focused($isListFocused)
        .focusEffectDisabled()
        .onModifierKeysChanged(mask: [.command, .shift], initial: true) { _, modifiers in
            activeModifiers = modifiers.intersection([.command, .shift])
        }
        .onPreferenceChange(TorrentCardFramePreferenceKey.self) { frames in
            cardFrames = frames
        }
        .onChange(of: torrentIDs) {
            selectAllResponderActivation &+= 1
        }
        .onKeyPress("a", phases: .down) { keyPress in
            guard isListFocused, keyPress.modifiers.contains(.command), !rows.isEmpty else {
                return .ignored
            }
            selectAllTorrents()
            return .handled
        }
        .onKeyPress(.escape, phases: .down) { _ in
            guard isListFocused, !selectionState.ids.isEmpty else {
                return .ignored
            }
            clearSelection()
            return .handled
        }
        .onKeyPress(.upArrow, phases: .down) { keyPress in
            guard keyPress.modifiers.isSubset(of: [.shift]) else {
                return .ignored
            }
            return moveKeyboardSelection(by: -1, extending: keyPress.modifiers.contains(.shift)) ? .handled : .ignored
        }
        .onKeyPress(.downArrow, phases: .down) { keyPress in
            guard keyPress.modifiers.isSubset(of: [.shift]) else {
                return .ignored
            }
            return moveKeyboardSelection(by: 1, extending: keyPress.modifiers.contains(.shift)) ? .handled : .ignored
        }
        .onKeyPress(.return, phases: .down) { keyPress in
            guard keyPress.modifiers.isEmpty else {
                return .ignored
            }
            return openKeyboardFocusedInfo() ? .handled : .ignored
        }
        .onKeyPress(.space, phases: .down) { keyPress in
            guard keyPress.modifiers.isEmpty else {
                return .ignored
            }
            return toggleKeyboardFocusedTorrents() ? .handled : .ignored
        }
        .onChange(of: selectionState.ids) { _, ids in
            if let currentAnchorID = selectionAnchorID, !ids.contains(currentAnchorID) {
                selectionAnchorID = ids.first
            }
            if let currentFocusID = selectionFocusID, !ids.contains(currentFocusID) {
                selectionFocusID = ids.first
            }
        }
    }

    private var torrentIDs: [TorrentItem.ID] {
        rows.map(\.id)
    }

    private var dragSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.selectionCoordinateSpace))
            .onChanged { value in
                if dragSelectionStart == nil {
                    activateListFocus()
                    dragSelectionStart = value.startLocation
                    dragSelectionBase = currentSelectionModifiers.contains(.command) ? selectionState.ids : []
                }
                updateDragSelection(to: value.location)
            }
            .onEnded { value in
                updateDragSelection(to: value.location)
                if let lastSelectedID = draggedTorrentIDs(to: value.location).last {
                    selectionAnchorID = lastSelectedID
                    selectionFocusID = lastSelectedID
                }
                dragSelectionStart = nil
                dragSelectionBase = []
            }
    }

    private func torrentCard(for row: TorrentRowSnapshot) -> some View {
        let isSelected = selectionState.ids.contains(row.id)
        return HStack(spacing: 8) {
            AccessibleTorrentRow(
                row: row,
                metricsState: transferMetricState(row.id),
                labels: labelsForTorrent(row.id),
                isSelected: isSelected,
                select: {
                    selectTorrentFromAccessibility(row)
                },
                openInfo: {
                    openInfo(for: row)
                },
                showOptions: {
                    openInfo(for: row, tab: .options)
                },
                revealInFinder: {
                    revealInFinder([row.id])
                },
                togglePause: {
                    togglePause(row.id)
                }
            )
                .padding(12)
                .background {
                    cardBackground(isSelected: isSelected)
                }
                .overlay {
                    cardBorder(isSelected: isSelected)
                }
                .contentShape(cardShape)
                .onTapGesture {
                    handleCardClick(row)
                }

            rowButtons(for: row)
        }
        .contentShape(Rectangle())
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TorrentCardFramePreferenceKey.self,
                    value: [row.id: proxy.frame(in: .named(Self.selectionCoordinateSpace))]
                )
            }
        }
        .contextMenu {
            actions(for: row)
        }
    }

    private func clearSelection() {
        lastCardClick = nil
        selectionState.ids = []
        selectionAnchorID = nil
        selectionFocusID = nil
    }

    private func markRowInteraction() {
        didHandleRowInteraction = true
        DispatchQueue.main.async {
            didHandleRowInteraction = false
        }
    }

    private func activateListFocus() {
        isListFocused = true
        selectAllResponderActivation &+= 1
    }

    private func cardBackground(isSelected: Bool) -> some View {
        ZStack {
            cardShape
                .fill(Color.primary.opacity(0.035))

            if isSelected {
                cardShape
                    .fill(Color.accentColor.opacity(0.18))
            }
        }
    }

    private func cardBorder(isSelected: Bool) -> some View {
        cardShape
            .strokeBorder(
                isSelected ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.35),
                lineWidth: 1
            )
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TorrentCardStyle.cornerRadius, style: .continuous)
    }

    private func handleCardClick(_ row: TorrentRowSnapshot) {
        markRowInteraction()
        activateListFocus()

        let now = Date.timeIntervalSinceReferenceDate
        if let lastCardClick,
           lastCardClick.id == row.id,
           now - lastCardClick.time <= NSEvent.doubleClickInterval {
            self.lastCardClick = nil
            openInfo(for: row)
            return
        }

        lastCardClick = TorrentCardClick(id: row.id, time: now)
        select(row)
    }

    private func select(_ row: TorrentRowSnapshot) {
        let modifiers = currentSelectionModifiers
        if modifiers.contains(.shift), let rangeIDs = selectionRange(endingAt: row.id) {
            if modifiers.contains(.command) {
                var updatedSelection = selectionState.ids
                updatedSelection.formUnion(rangeIDs)
                selectionState.ids = updatedSelection
            } else {
                selectionState.ids = rangeIDs
            }
            selectionFocusID = row.id
        } else if modifiers.contains(.command) {
            var updatedSelection = selectionState.ids
            if updatedSelection.contains(row.id) {
                updatedSelection.remove(row.id)
            } else {
                updatedSelection.insert(row.id)
            }
            selectionState.ids = updatedSelection
            selectionAnchorID = row.id
            selectionFocusID = row.id
        } else {
            selectionState.ids = [row.id]
            selectionAnchorID = row.id
            selectionFocusID = row.id
        }
    }

    private func selectTorrentFromAccessibility(_ row: TorrentRowSnapshot) {
        markRowInteraction()
        activateListFocus()
        selectionState.ids = [row.id]
        selectionAnchorID = row.id
        selectionFocusID = row.id
    }

    private func selectForContextMenu(_ torrentID: TorrentItem.ID) {
        activateListFocus()
        lastCardClick = nil
        guard !selectionState.ids.contains(torrentID) else {
            return
        }
        selectionState.ids = [torrentID]
        selectionAnchorID = torrentID
        selectionFocusID = torrentID
    }

    private func selectAllTorrents() {
        selectionState.ids = Set(rows.map(\.id))
        selectionAnchorID = rows.first?.id
        selectionFocusID = rows.first?.id
    }

    private var currentSelectionModifiers: EventModifiers {
        var modifiers = activeModifiers
        let eventModifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if eventModifiers.contains(.command) {
            modifiers.insert(.command)
        }
        if eventModifiers.contains(.shift) {
            modifiers.insert(.shift)
        }
        return modifiers
    }

    private func updateDragSelection(to location: CGPoint) {
        let draggedIDs = Set(draggedTorrentIDs(to: location))
        guard !draggedIDs.isEmpty else {
            selectionState.ids = dragSelectionBase
            return
        }
        selectionState.ids = dragSelectionBase.union(draggedIDs)
    }

    private func draggedTorrentIDs(to location: CGPoint) -> [TorrentItem.ID] {
        guard let dragSelectionStart else {
            return []
        }

        let minY = min(dragSelectionStart.y, location.y)
        let maxY = max(dragSelectionStart.y, location.y)
        return rows.compactMap { row in
            guard let frame = cardFrames[row.id], frame.maxY >= minY, frame.minY <= maxY else {
                return nil
            }
            return row.id
        }
    }

    private func selectionRange(endingAt torrentID: TorrentItem.ID) -> Set<TorrentItem.ID>? {
        guard
            let selectionAnchorID,
            let anchorIndex = rows.firstIndex(where: { $0.id == selectionAnchorID }),
            let targetIndex = rows.firstIndex(where: { $0.id == torrentID })
        else {
            selectionAnchorID = torrentID
            return [torrentID]
        }

        let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        return Set(rows[bounds].map(\.id))
    }

    private func selectionRange(from startID: TorrentItem.ID, to endID: TorrentItem.ID) -> Set<TorrentItem.ID> {
        guard
            let startIndex = rows.firstIndex(where: { $0.id == startID }),
            let endIndex = rows.firstIndex(where: { $0.id == endID })
        else {
            return [endID]
        }

        let bounds = min(startIndex, endIndex)...max(startIndex, endIndex)
        return Set(rows[bounds].map(\.id))
    }

    private func moveKeyboardSelection(by offset: Int, extending: Bool) -> Bool {
        guard !rows.isEmpty else {
            return false
        }

        guard let targetID = keyboardSelectionTargetID(offset: offset) else {
            return true
        }

        lastCardClick = nil
        if extending {
            let anchorID = keyboardSelectionAnchorID(fallback: targetID)
            selectionAnchorID = anchorID
            selectionState.ids = selectionRange(from: anchorID, to: targetID)
        } else {
            selectionState.ids = [targetID]
            selectionAnchorID = targetID
        }

        selectionFocusID = targetID
        scrollTargetID = targetID
        return true
    }

    private func keyboardSelectionTargetID(offset: Int) -> TorrentItem.ID? {
        guard !rows.isEmpty else {
            return nil
        }

        guard let currentID = keyboardSelectionFocusID,
              let currentIndex = rows.firstIndex(where: { $0.id == currentID })
        else {
            return offset < 0 ? rows.last?.id : rows.first?.id
        }

        let targetIndex = min(max(currentIndex + offset, 0), rows.count - 1)
        return rows[targetIndex].id
    }

    private var keyboardSelectionFocusID: TorrentItem.ID? {
        if let selectionFocusID, rows.contains(where: { $0.id == selectionFocusID }) {
            return selectionFocusID
        }

        if let selectionAnchorID, rows.contains(where: { $0.id == selectionAnchorID }) {
            return selectionAnchorID
        }

        return rows.first(where: { selectionState.ids.contains($0.id) })?.id
    }

    private func keyboardSelectionAnchorID(fallback: TorrentItem.ID) -> TorrentItem.ID {
        if let selectionAnchorID, rows.contains(where: { $0.id == selectionAnchorID }) {
            return selectionAnchorID
        }

        return keyboardSelectionFocusID ?? fallback
    }

    private var keyboardActionRows: [TorrentRowSnapshot] {
        rows.filter { selectionState.ids.contains($0.id) }
    }

    private var keyboardFocusedRow: TorrentRowSnapshot? {
        if let selectionFocusID, let row = rows.first(where: { $0.id == selectionFocusID }) {
            return row
        }

        return keyboardActionRows.first
    }

    private func openKeyboardFocusedInfo() -> Bool {
        guard let row = keyboardFocusedRow else {
            return false
        }

        openInfo(for: row)
        return true
    }

    private func toggleKeyboardFocusedTorrents() -> Bool {
        let selectedRows = keyboardActionRows
        guard !selectedRows.isEmpty else {
            return false
        }

        let selectedIDs = Set(selectedRows.map(\.id))
        if selectedRows.contains(where: { !$0.manuallyPaused }) {
            pause(selectedIDs)
        } else {
            resume(selectedIDs)
        }
        return true
    }

    private func requestKeyboardRemoval() -> Bool {
        let selectedRows = keyboardActionRows
        guard !selectedRows.isEmpty else {
            return false
        }

        let selectedIDs = Set(selectedRows.map(\.id))
        selectionState.ids = selectedIDs
        selectionFocusID = selectedRows.first?.id
        requestRemoval(selectedIDs)
        return true
    }

    private func openInfo(for row: TorrentRowSnapshot, tab: TorrentInfoTab = .general) {
        markRowInteraction()
        activateListFocus()
        selectionState.ids = [row.id]
        selectionAnchorID = row.id
        selectionFocusID = row.id
        showInfo(row.id, tab)
    }

    private func rowButtons(for row: TorrentRowSnapshot) -> some View {
        HStack(spacing: 6) {
            rowActionButton("Reveal in Finder", systemImage: "folder") {
                markRowInteraction()
                activateListFocus()
                revealInFinder([row.id])
            }

            rowActionButton(
                row.manuallyPaused ? "Resume" : "Pause",
                systemImage: row.manuallyPaused ? "play.fill" : "pause.fill"
            ) {
                markRowInteraction()
                activateListFocus()
                togglePause(row.id)
            }
        }
    }

    private func rowActionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .accessibilityLabel(title)
        .help(title)
    }

    @ViewBuilder
    private func actions(for row: TorrentRowSnapshot) -> some View {
        let actionIDs = actionIDs(for: row)
        let actionRows = rows.filter { actionIDs.contains($0.id) }
        let actsOnMultipleTorrents = actionIDs.count > 1

        Button {
            selectionState.ids = [row.id]
            selectionAnchorID = row.id
            selectionFocusID = row.id
            showInfo(row.id, .general)
        } label: {
            Label("Get Info", systemImage: "info.circle")
        }
        Button {
            selectionState.ids = [row.id]
            selectionAnchorID = row.id
            selectionFocusID = row.id
            showInfo(row.id, .options)
        } label: {
            Label("Show Options", systemImage: "slider.horizontal.3")
        }
        Button {
            selectionState.ids = actionIDs
            selectionFocusID = row.id
            revealInFinder(actionIDs)
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        Button {
            selectionState.ids = actionIDs
            selectionFocusID = row.id
            reannounce(actionIDs)
        } label: {
            Label(actsOnMultipleTorrents ? "Reannounce Selected" : "Reannounce", systemImage: "arrow.clockwise")
        }
        if actionRows.contains(where: \.hasMetadata) {
            Button {
                selectionState.ids = actionIDs
                selectionFocusID = row.id
                forceRecheck(actionIDs)
            } label: {
                Label(actsOnMultipleTorrents ? "Force Recheck Selected" : "Force Recheck", systemImage: "checkmark.shield")
            }
        }

        Divider()

        if actionRows.contains(where: { !$0.manuallyPaused }) {
            Button {
                selectionState.ids = actionIDs
                selectionFocusID = row.id
                pause(actionIDs)
            } label: {
                Label(actsOnMultipleTorrents ? "Pause Selected" : "Pause", systemImage: "pause.fill")
            }
        }
        if actionRows.contains(where: \.manuallyPaused) {
            Button {
                selectionState.ids = actionIDs
                selectionFocusID = row.id
                resume(actionIDs)
            } label: {
                Label(actsOnMultipleTorrents ? "Resume Selected" : "Resume", systemImage: "play.fill")
            }
        }

        Divider()

        Menu("Labels") {
            if labels.isEmpty {
                Text("No Labels")
            } else {
                ForEach(labels) { label in
                    Button {
                        selectionState.ids = actionIDs
                        selectionFocusID = row.id
                        toggleLabel(label.id, actionIDs)
                    } label: {
                        Label(label.name, systemImage: labelMenuImage(for: label.id, rows: actionRows))
                    }
                }
            }
        }

        Divider()

        Menu("Priority") {
            ForEach(TorrentQueuePriority.allCases) { priority in
                Button {
                    selectionState.ids = actionIDs
                    selectionFocusID = row.id
                    setQueuePriority(actionIDs, priority)
                } label: {
                    Label(priority.title, systemImage: priorityMenuImage(for: priority, rows: actionRows))
                }
            }
        }

        Menu("Move in Queue") {
            Button {
                selectionState.ids = actionIDs
                selectionFocusID = row.id
                moveInQueue(actionIDs, .top)
            } label: {
                Label("Top", systemImage: "arrow.up.to.line")
            }
            Button {
                selectionState.ids = actionIDs
                selectionFocusID = row.id
                moveInQueue(actionIDs, .up)
            } label: {
                Label("Up", systemImage: "arrow.up")
            }
            Button {
                selectionState.ids = actionIDs
                selectionFocusID = row.id
                moveInQueue(actionIDs, .down)
            } label: {
                Label("Down", systemImage: "arrow.down")
            }
            Button {
                selectionState.ids = actionIDs
                selectionFocusID = row.id
                moveInQueue(actionIDs, .bottom)
            } label: {
                Label("Bottom", systemImage: "arrow.down.to.line")
            }
        }

        Divider()

        Button(role: .destructive) {
            selectionState.ids = actionIDs
            selectionFocusID = row.id
            requestRemoval(actionIDs)
        } label: {
            Label(actsOnMultipleTorrents ? "Remove Selected" : "Remove", systemImage: "trash")
        }
    }

    private func actionIDs(for row: TorrentRowSnapshot) -> Set<TorrentItem.ID> {
        selectionState.ids.contains(row.id) ? selectionState.ids : [row.id]
    }

    private func priorityMenuImage(for priority: TorrentQueuePriority, rows: [TorrentRowSnapshot]) -> String {
        rows.allSatisfy { $0.queuePriority == priority } ? "checkmark" : "circle"
    }

    private func labelMenuImage(for labelID: TorrentLabel.ID, rows: [TorrentRowSnapshot]) -> String {
        let labeledCount = rows.filter { labelIDsForTorrent($0.id).contains(labelID) }.count
        if labeledCount == rows.count, !rows.isEmpty {
            return "checkmark"
        }
        return labeledCount > 0 ? "minus" : "circle"
    }

}

private struct AccessibleTorrentRow: View {
    let row: TorrentRowSnapshot
    let metricsState: TorrentTransferMetricsState
    let labels: [TorrentLabel]
    let isSelected: Bool
    let select: () -> Void
    let openInfo: () -> Void
    let showOptions: () -> Void
    let revealInFinder: () -> Void
    let togglePause: () -> Void

    var body: some View {
        TorrentRow(row: row, metricsState: metricsState, labels: labels)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Selects this torrent")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction {
                select()
            }
            .accessibilityAction(named: "Select", select)
            .accessibilityAction(named: "Get Info", openInfo)
            .accessibilityAction(named: "Show Options", showOptions)
            .accessibilityAction(named: "Reveal in Finder", revealInFinder)
            .accessibilityAction(named: row.manuallyPaused ? "Resume" : "Pause", togglePause)
    }

    private var metrics: TorrentTransferMetrics {
        metricsState.metrics
    }

    private var accessibilityLabel: String {
        var parts = [
            row.name,
            row.statusText,
        ]

        if !row.error.isEmpty {
            parts.append(row.error)
        }
        if !labels.isEmpty {
            parts.append("Labels \(labels.map(\.name).joined(separator: ", "))")
        }

        return parts.joined(separator: ", ")
    }

    private var accessibilityValue: String {
        var parts = [
            isSelected ? "Selected" : "Not selected",
            metrics.progress.formatted(.percent.precision(.fractionLength(1))),
        ]

        if metrics.totalWanted > 0 {
            parts.append("\(ByteFormat.size(metrics.totalDone)) of \(ByteFormat.size(metrics.totalWanted))")
        }
        parts.append(metrics.peerSummaryText)
        if metrics.downloadPayloadRate > 0, !row.seeding, !row.finished {
            parts.append("Downloading \(ByteFormat.rate(metrics.downloadPayloadRate))")
        }
        if metrics.uploadPayloadRate > 0 || row.seeding || row.finished {
            parts.append("Uploading \(ByteFormat.rate(metrics.uploadPayloadRate))")
        }
        return parts.joined(separator: ", ")
    }
}

private struct TorrentCardFramePreferenceKey: PreferenceKey {
    static let defaultValue: [TorrentItem.ID: CGRect] = [:]

    static func reduce(value: inout [TorrentItem.ID: CGRect], nextValue: () -> [TorrentItem.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct TorrentCardClick {
    let id: TorrentItem.ID
    let time: TimeInterval
}

private struct RightClickSelectionMonitor: NSViewRepresentable {
    let cardFrames: [TorrentItem.ID: CGRect]
    let select: (TorrentItem.ID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(cardFrames: cardFrames, select: select)
    }

    func makeNSView(context: Context) -> RightClickSelectionNSView {
        let view = RightClickSelectionNSView()
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ view: RightClickSelectionNSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.cardFrames = cardFrames
        context.coordinator.select = select
    }

    static func dismantleNSView(_ view: RightClickSelectionNSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var view: RightClickSelectionNSView?
        var cardFrames: [TorrentItem.ID: CGRect]
        var select: (TorrentItem.ID) -> Void
        private var monitor: Any?

        init(cardFrames: [TorrentItem.ID: CGRect], select: @escaping (TorrentItem.ID) -> Void) {
            self.cardFrames = cardFrames
            self.select = select
        }

        func installMonitor() {
            guard monitor == nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let view, let window = unsafe view.window, event.window === window else {
                return
            }

            let point = view.convert(event.locationInWindow, from: nil)
            guard let torrentID = cardFrames.first(where: { _, frame in frame.contains(point) })?.key else {
                return
            }

            select(torrentID)
        }
    }
}

private final class RightClickSelectionNSView: NSView {
    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct SelectAllResponder: NSViewRepresentable {
    let activation: Int
    let canSelectAll: Bool
    let canClearSelection: Bool
    let selectAll: () -> Void
    let clearSelection: () -> Void
    let moveSelection: (_ offset: Int, _ extending: Bool) -> Bool
    let openInfo: () -> Bool
    let togglePause: () -> Bool
    let removeSelection: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SelectAllNSView {
        SelectAllNSView()
    }

    func updateNSView(_ view: SelectAllNSView, context: Context) {
        view.canSelectAll = canSelectAll
        view.canClearSelection = canClearSelection
        view.selectAllAction = selectAll
        view.clearSelectionAction = clearSelection
        view.moveSelectionAction = moveSelection
        view.openInfoAction = openInfo
        view.togglePauseAction = togglePause
        view.removeSelectionAction = removeSelection

        guard context.coordinator.activation != activation else {
            return
        }

        context.coordinator.activation = activation
        DispatchQueue.main.async { [weak view] in
            view?.becomeSelectAllResponderIfPossible()
        }
    }

    final class Coordinator {
        var activation = Int.min
    }
}

private final class SelectAllNSView: NSView, NSUserInterfaceValidations {
    var canSelectAll = false
    var canClearSelection = false
    var selectAllAction: (() -> Void)?
    var clearSelectionAction: (() -> Void)?
    var moveSelectionAction: ((_ offset: Int, _ extending: Bool) -> Bool)?
    var openInfoAction: (() -> Bool)?
    var togglePauseAction: (() -> Bool)?
    var removeSelectionAction: (() -> Bool)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func selectAll(_ sender: Any?) {
        guard canSelectAll else {
            return
        }
        selectAllAction?()
    }

    override func cancelOperation(_ sender: Any?) {
        guard canClearSelection else {
            return
        }
        clearSelectionAction?()
    }

    override func keyDown(with event: NSEvent) {
        guard handleTorrentListKey(event) else {
            super.keyDown(with: event)
            return
        }
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(selectAll(_:)) {
            return canSelectAll
        }
        return true
    }

    func becomeSelectAllResponderIfPossible() {
        guard
            let window = unsafe self.window,
            canBecomeSelectAllResponder(in: window)
        else {
            return
        }
        window.makeFirstResponder(self)
    }

    func canBecomeSelectAllResponder(in window: NSWindow) -> Bool {
        guard canSelectAll else {
            return false
        }

        guard let responder = window.firstResponder else {
            return true
        }

        if responder === self {
            return true
        }

        if responder is NSTextView || responder is NSTextField {
            return false
        }

        if let responderView = responder as? NSView,
           responderView.hasAncestorOrSelf(where: { view in
               view is NSTableView || view is NSOutlineView || view is NSCollectionView
           }) {
            return false
        }

        return true
    }

    private func handleTorrentListKey(_ event: NSEvent) -> Bool {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let disallowedModifiers = modifierFlags.intersection([.command, .control, .option])
        guard disallowedModifiers.isEmpty else {
            return false
        }

        let isExtending = modifierFlags.contains(.shift)
        switch event.keyCode {
        case 126:
            return moveSelectionAction?(-1, isExtending) ?? false
        case 125:
            return moveSelectionAction?(1, isExtending) ?? false
        case 36, 76:
            guard !isExtending else {
                return false
            }
            return openInfoAction?() ?? false
        case 49:
            guard !isExtending else {
                return false
            }
            return togglePauseAction?() ?? false
        case 51, 117:
            guard !isExtending else {
                return false
            }
            return removeSelectionAction?() ?? false
        case 53:
            guard !isExtending, canClearSelection else {
                return false
            }
            clearSelectionAction?()
            return true
        default:
            return false
        }
    }
}

private extension NSView {
    func hasAncestorOrSelf(where matches: (NSView) -> Bool) -> Bool {
        if matches(self) {
            return true
        }

        guard let superview = unsafe self.superview else {
            return false
        }

        return superview.hasAncestorOrSelf(where: matches)
    }
}
