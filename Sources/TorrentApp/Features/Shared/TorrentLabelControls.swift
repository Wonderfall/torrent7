import SwiftUI

struct TorrentLabelSelectionRow: View {
    let labels: [TorrentLabel]
    @Binding var selectedLabelIDs: Set<TorrentLabel.ID>
    let createLabel: (String) -> TorrentLabel?

    @State private var labelEditor: TorrentLabelEditorRequest?

    var body: some View {
        LabeledContent("Labels") {
            Menu {
                if labels.isEmpty {
                    Text("No Labels")
                } else {
                    ForEach(labels) { label in
                        Button {
                            toggle(label)
                        } label: {
                            Label(label.name, systemImage: selectedLabelIDs.contains(label.id) ? "checkmark" : "circle")
                        }
                    }

                    Divider()
                }

                Button {
                    labelEditor = .create
                } label: {
                    Label("New Label…", systemImage: "plus")
                }
            } label: {
                Text(summaryText)
            }
            .fixedSize()
        }
        .sheet(item: $labelEditor) { request in
            TorrentLabelEditorView(
                title: request.title,
                initialName: "",
                saveTitle: "Create"
            ) { name in
                if let label = createLabel(name) {
                    selectedLabelIDs.insert(label.id)
                }
                labelEditor = nil
            } cancel: {
                labelEditor = nil
            }
        }
    }

    private var summaryText: String {
        let selectedLabels = labels.filter { selectedLabelIDs.contains($0.id) }
        switch selectedLabels.count {
        case 0:
            return "None"
        case 1:
            return selectedLabels[0].name
        default:
            return "\(selectedLabels.count) labels"
        }
    }

    private func toggle(_ label: TorrentLabel) {
        if selectedLabelIDs.contains(label.id) {
            selectedLabelIDs.remove(label.id)
        } else {
            selectedLabelIDs.insert(label.id)
        }
    }
}

struct TorrentLabelPillStrip: View {
    let labels: [TorrentLabel]
    var limit = 2

    var body: some View {
        HStack(spacing: 4) {
            ForEach(visibleLabels) { label in
                Text(label.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
            }

            if hiddenCount > 0 {
                Text("+\(hiddenCount)")
                    .font(.caption2)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var visibleLabels: [TorrentLabel] {
        Array(labels.prefix(limit))
    }

    private var hiddenCount: Int {
        max(0, labels.count - limit)
    }
}

struct TorrentLabelEditorRequest: Identifiable, Equatable {
    enum Mode: Equatable {
        case create
        case rename(TorrentLabel)
    }

    let mode: Mode

    static let create = TorrentLabelEditorRequest(mode: .create)

    var id: String {
        switch mode {
        case .create:
            return "create"
        case .rename(let label):
            return "rename:\(label.id)"
        }
    }

    var title: String {
        switch mode {
        case .create:
            return "New Label"
        case .rename:
            return "Rename Label"
        }
    }

    var initialName: String {
        switch mode {
        case .create:
            return ""
        case .rename(let label):
            return label.name
        }
    }
}

struct TorrentLabelEditorView: View {
    let title: String
    let saveTitle: String
    let save: (String) -> Void
    let cancel: () -> Void

    @State private var name: String

    init(
        title: String,
        initialName: String,
        saveTitle: String,
        save: @escaping (String) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.title = title
        self.saveTitle = saveTitle
        self.save = save
        self.cancel = cancel
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))

            TextField("Label name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
                .onSubmit(saveTrimmedName)

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button(saveTitle, action: saveTrimmedName)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(24)
    }

    private var trimmedName: String {
        TorrentLabel.normalizedName(name)
    }

    private func saveTrimmedName() {
        guard !trimmedName.isEmpty else {
            return
        }
        save(trimmedName)
    }
}
