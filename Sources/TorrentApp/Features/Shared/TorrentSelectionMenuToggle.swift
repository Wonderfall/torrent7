import SwiftUI

/// Projects an aggregate selection into SwiftUI's native off/mixed/on menu state.
struct TorrentSelectionMenuToggle: View {
    let title: String
    let selectedCount: Int
    let totalCount: Int
    let toggle: () -> Void

    var body: some View {
        // The lower (all) and upper (any) bounds encode the aggregate without
        // enumerating thousands of selected torrents on the main actor. Only the
        // all binding writes: one activation must issue exactly one bulk command.
        Toggle(title, sources: [
            Binding(
                get: { totalCount > 0 && selectedCount == totalCount },
                set: { _ in toggle() }
            ),
            .constant(selectedCount > 0)
        ], isOn: \.self)
        .disabled(totalCount == 0)
    }
}
