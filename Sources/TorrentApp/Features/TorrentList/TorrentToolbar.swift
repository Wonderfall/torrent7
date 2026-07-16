import SwiftUI
import TorrentEngineModel

struct TorrentToolbar: ToolbarContent {
    let commandState: TorrentCommandState
    let addTorrent: () -> Void
    let addMagnet: () -> Void
    let showInfo: () -> Void
    let showOptions: () -> Void
    let revealInFinder: () -> Void
    let pause: () -> Void
    let resume: () -> Void
    let remove: () -> Void
    let setSortOrder: (TorrentSortOrder) -> Void
    let setSortDirection: (TorrentSortDirection) -> Void
    let openSettings: () -> Void

    var body: some ToolbarContent {
        ToolbarItem {
            ControlGroup {
                toolbarButton("Add Torrent", systemImage: "doc.badge.plus", action: addTorrent)
                toolbarButton("Add Magnet", systemImage: "link.badge.plus", action: addMagnet)
                toolbarButton("Settings", systemImage: "gearshape", action: openSettings)
            }
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            ControlGroup {
                sortMenu
            }
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            ControlGroup {
                toolbarButton("Torrent Info", systemImage: "info.circle", action: showInfo)
                    .disabled(!commandState.snapshot.hasSingleSelectedTorrent)
                toolbarButton("Torrent Options", systemImage: "slider.horizontal.3", action: showOptions)
                    .disabled(!commandState.snapshot.hasSingleSelectedTorrent)
                toolbarButton("Reveal in Finder", systemImage: "folder", action: revealInFinder)
                    .disabled(!commandState.snapshot.hasSelectedTorrents)
                toolbarButton("Pause", systemImage: "pause.fill", action: pause)
                    .disabled(!commandState.snapshot.canPauseSelectedTorrents)
                toolbarButton("Resume", systemImage: "play.fill", action: resume)
                    .disabled(!commandState.snapshot.canResumeSelectedTorrents)
                toolbarButton("Remove", systemImage: "trash", role: .destructive, action: remove)
                    .disabled(!commandState.snapshot.hasSelectedTorrents)
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(TorrentSortOrder.allCases) { sortOrder in
                Toggle(sortOrder.title, isOn: isSelected(sortOrder))
            }
            Divider()
            ForEach(TorrentSortDirection.allCases) { direction in
                Toggle(direction.title, isOn: isSelected(direction))
            }
        } label: {
            Label("Sort By", systemImage: "arrow.up.arrow.down")
        }
        .disabled(!commandState.snapshot.hasTorrents)
        .accessibilityLabel("Sort By")
        .help("Sort By")
    }

    private func toolbarButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
        }
        .accessibilityLabel(title)
        .help(title)
    }

    private func isSelected(_ sortOrder: TorrentSortOrder) -> Binding<Bool> {
        Binding {
            commandState.snapshot.sortOrder == sortOrder
        } set: { isSelected in
            if isSelected {
                setSortOrder(sortOrder)
            }
        }
    }

    private func isSelected(_ direction: TorrentSortDirection) -> Binding<Bool> {
        Binding {
            commandState.snapshot.sortDirection == direction
        } set: { isSelected in
            if isSelected {
                setSortDirection(direction)
            }
        }
    }
}
