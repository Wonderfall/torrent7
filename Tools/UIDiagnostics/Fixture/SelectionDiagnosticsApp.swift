import SwiftUI

// This host compiles the production menu control, but owns only in-memory state.
// It has no engine, storage grants, user defaults, or application data access.
@main
struct SelectionDiagnosticsApp: App {
    var body: some Scene {
        Window("Torrent Selection Diagnostics", id: "selection-diagnostics") {
            SelectionDiagnosticsView()
                .frame(width: 420, height: 180)
        }
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
    }
}

private struct SelectionDiagnosticsView: View {
    @State private var selectedCount = 1
    @State private var commands = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Selected: \(selectedCount) of 3")
                .accessibilityIdentifier("selection-count")
            Menu("Labels") {
                TorrentSelectionMenuToggle(
                    title: "Linux", selectedCount: selectedCount, totalCount: 3
                ) {
                    selectedCount = selectedCount == 3 ? 0 : 3
                    commands += 1
                }
            }
            .accessibilityIdentifier("labels-menu")
            Text("Commands: \(commands)")
                .accessibilityIdentifier("command-count")
        }
        .padding()
    }
}
