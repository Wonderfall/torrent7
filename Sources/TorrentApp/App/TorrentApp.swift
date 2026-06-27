import AppKit
import SwiftUI

@main
struct TorrentApp: App {
    @NSApplicationDelegateAdaptor(TorrentAppDelegate.self) private var appDelegate
    @State private var store = TorrentStore()
    @State private var commandActions = TorrentCommandActions()

    var body: some Scene {
        Window(AppIdentity.displayName, id: "main") {
            ContentView(
                commandActions: commandActions,
                commandState: store.commandState,
                selectionState: store.selectionState,
                torrentState: store.torrentState
            )
                .environment(store)
                .onAppear {
                    appDelegate.store = store
                }
                .background(WindowMenuRegistrationView())
        }
        .defaultSize(width: 920, height: 620)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarLabelStyle(fixed: .iconOnly)
        .commands {
            TorrentAppCommands(store: store, actions: commandActions, commandState: store.commandState)
        }

        WindowGroup("Torrent Info", for: String.self) { $torrentID in
            TorrentInfoWindow(torrentID: $torrentID, torrentState: store.torrentState)
                .environment(store)
        }
        .defaultSize(width: 500, height: 560)
        .windowToolbarLabelStyle(fixed: .iconOnly)

        Settings {
            TorrentSettingsView(store: store, state: store.settingsState)
        }
        .windowResizability(.contentSize)
    }
}
