import AppKit
import SwiftUI

struct TorrentAppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let store: TorrentStore
    let actions: TorrentCommandActions
    let commandState: TorrentCommandState

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppIdentity.displayName)") {
                showAboutPanel()
            }
        }

        CommandGroup(replacing: .newItem) {
            Button {
                actions.addTorrentFile()
            } label: {
                Label("Add Torrent...", systemImage: "doc.badge.plus")
            }
            .keyboardShortcut("o", modifiers: .command)

            Button {
                actions.addMagnetLink()
            } label: {
                Label("Add Magnet Link...", systemImage: "link.badge.plus")
            }
            .keyboardShortcut("u", modifiers: .command)
        }

        CommandGroup(replacing: .importExport) {
            Button {
                actions.chooseDownloadFolder()
            } label: {
                Label("Choose Download Folder...", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .saveItem) {}

        CommandGroup(replacing: .printItem) {}

        CommandGroup(after: .textEditing) {
            Button("Find") {
                actions.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        SidebarCommands()

        CommandGroup(after: .toolbar) {
            Menu("Sort By") {
                ForEach(TorrentSortOrder.allCases) { sortOrder in
                    Toggle(sortOrder.title, isOn: isSelected(sortOrder))
                }
                Divider()
                ForEach(TorrentSortDirection.allCases) { direction in
                    Toggle(direction.title, isOn: isSelected(direction))
                }
            }
            .disabled(!commandState.snapshot.hasTorrents)
        }

        CommandMenu("Transfers") {
            Button {
                actions.showSelectedTorrentInfo()
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(!commandState.snapshot.hasSingleSelectedTorrent)

            Button {
                actions.showSelectedTorrentOptions()
            } label: {
                Label("Show Options", systemImage: "slider.horizontal.3")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!commandState.snapshot.hasSingleSelectedTorrent)

            Button {
                actions.revealSelectedTorrentsInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!commandState.snapshot.hasSelectedTorrents)

            Divider()

            Button {
                actions.pauseSelectedTorrents()
            } label: {
                Label(pauseTitle, systemImage: "pause.fill")
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!commandState.snapshot.canPauseSelectedTorrents)

            Button {
                actions.resumeSelectedTorrents()
            } label: {
                Label(resumeTitle, systemImage: "play.fill")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!commandState.snapshot.canResumeSelectedTorrents)

            Divider()

            Button {
                store.pauseAllTorrents()
            } label: {
                Label("Pause All", systemImage: "pause.fill")
            }
            .keyboardShortcut("k", modifiers: [.command, .option])
            .disabled(!commandState.snapshot.canPauseAnyTorrent)

            Button {
                store.resumeAllTorrents()
            } label: {
                Label("Resume All", systemImage: "play.fill")
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!commandState.snapshot.canResumeAnyTorrent)

            Divider()

            Button {
                store.reannounceTorrents(ids: store.selectedTorrentIDs)
            } label: {
                Label("Reannounce", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command, .control])
            .disabled(!commandState.snapshot.hasSelectedTorrents)

            Button {
                store.forceRecheckTorrents(ids: store.selectedTorrentIDs)
            } label: {
                Label("Force Recheck", systemImage: "checkmark.shield")
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(!commandState.snapshot.canForceRecheckSelectedTorrents)

            Menu {
                ForEach(TorrentQueuePriority.allCases) { priority in
                    Button {
                        store.setQueuePriority(for: store.selectedTorrentIDs, priority: priority)
                    } label: {
                        Label(priority.title, systemImage: prioritySystemImage(priority))
                    }
                    .keyboardShortcut(priorityShortcutKey(priority), modifiers: [.command, .control])
                }
            } label: {
                Label("Priority", systemImage: "flag")
            }
            .disabled(!commandState.snapshot.hasSelectedTorrents)

            Menu {
                Button {
                    store.moveTorrentsInQueue(ids: store.selectedTorrentIDs, move: .top)
                } label: {
                    Label("Move to Top", systemImage: "arrow.up.to.line")
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option, .shift])

                Button {
                    store.moveTorrentsInQueue(ids: store.selectedTorrentIDs, move: .up)
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])

                Button {
                    store.moveTorrentsInQueue(ids: store.selectedTorrentIDs, move: .down)
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])

                Button {
                    store.moveTorrentsInQueue(ids: store.selectedTorrentIDs, move: .bottom)
                } label: {
                    Label("Move to Bottom", systemImage: "arrow.down.to.line")
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
            } label: {
                Label("Queue", systemImage: "arrow.up.arrow.down")
            }
            .disabled(!commandState.snapshot.hasSelectedTorrents)

            Divider()

            Button {
                actions.requestSelectedTorrentRemoval()
            } label: {
                Label(removeTitle, systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!commandState.snapshot.hasSelectedTorrents)
        }

        CommandGroup(after: .windowArrangement) {
            Button("Show Main Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }

    private func isSelected(_ sortOrder: TorrentSortOrder) -> Binding<Bool> {
        Binding {
            commandState.snapshot.sortOrder == sortOrder
        } set: { isSelected in
            if isSelected {
                store.setSortOrder(sortOrder)
            }
        }
    }

    private func isSelected(_ direction: TorrentSortDirection) -> Binding<Bool> {
        Binding {
            commandState.snapshot.sortDirection == direction
        } set: { isSelected in
            if isSelected {
                store.setSortDirection(direction)
            }
        }
    }

    private var pauseTitle: String {
        commandState.snapshot.selectedTorrentCount > 1 ? "Pause Selected Torrents" : "Pause Torrent"
    }

    private var resumeTitle: String {
        commandState.snapshot.selectedTorrentCount > 1 ? "Resume Selected Torrents" : "Resume Torrent"
    }

    private var removeTitle: String {
        commandState.snapshot.selectedTorrentCount > 1 ? "Remove Selected Torrents..." : "Remove Torrent..."
    }

    private func prioritySystemImage(_ priority: TorrentQueuePriority) -> String {
        switch priority {
        case .high:
            "arrow.up.circle"
        case .normal:
            "equal.circle"
        case .low:
            "arrow.down.circle"
        }
    }

    private func priorityShortcutKey(_ priority: TorrentQueuePriority) -> KeyEquivalent {
        switch priority {
        case .high:
            "1"
        case .normal:
            "2"
        case .low:
            "3"
        }
    }

    private func showAboutPanel() {
        let credits = NSAttributedString(string: "libtorrent \(store.libtorrentVersion)")

        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: AppIdentity.displayName,
            .applicationVersion: AppIdentity.marketingVersion,
            .version: AppIdentity.buildVersion,
            .credits: credits
        ])
    }
}
