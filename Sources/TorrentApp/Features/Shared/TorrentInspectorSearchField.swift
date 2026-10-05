import SwiftUI
import TorrentAppInfrastructure

extension FocusedValues {
    @Entry var inspectorSearchFocus: FocusState<Bool>.Binding?
}

/// An inline filter leaves the inspector's tab toolbar and window geometry intact.
struct TorrentInspectorSearchField: View {
    let prompt: String
    @Binding var text: String
    @Environment(\.appearsActive) private var appearsActive
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: Binding(
                get: { text },
                set: { text = TorrentSearchQuery.boundedInput($0) }
            ), prompt: Text(prompt))
            .textFieldStyle(.plain)
            .labelsHidden()
            .focused($isFocused)
            .onExitCommand {
                if text.isEmpty { isFocused = false }
                else { text = "" }
            }
            if !text.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    text = ""
                    isFocused = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
            }
        }
        .font(.body.weight(.regular))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isFocused && appearsActive ? Color.accentColor : .clear, lineWidth: 2)
        }
        .focusedSceneValue(\.inspectorSearchFocus, $isFocused)
    }
}
