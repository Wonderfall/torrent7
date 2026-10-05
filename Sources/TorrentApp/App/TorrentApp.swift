import AppKit
import SwiftUI

@main
struct TorrentApp: App {
    @NSApplicationDelegateAdaptor(TorrentAppDelegate.self) private var appDelegate
    @State private var commandActions = TorrentCommandActions()

    private var store: TorrentStore {
        appDelegate.store
    }

    var body: some Scene {
        Window(AppIdentity.displayName, id: "main") {
            ContentView(
                commandActions: commandActions,
                commandState: store.commandState,
                selectionState: store.selectionState,
                torrentState: store.torrentState
            )
                .environment(store)
                .background {
                    WindowMenuRegistrationView()
                }
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

        WindowGroup("Acknowledgments") {
            AcknowledgmentsView()
                .handlesExternalEvents(
                    preferring: [AppIdentity.acknowledgmentsLink],
                    allowing: [AppIdentity.acknowledgmentsLink]
                )
        }
        .handlesExternalEvents(matching: [AppIdentity.acknowledgmentsLink])
        .defaultSize(width: 760, height: 540)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Settings {
            TorrentSettingsView(store: store, state: store.settingsState)
        }
        .windowResizability(.contentSize)
    }
}
