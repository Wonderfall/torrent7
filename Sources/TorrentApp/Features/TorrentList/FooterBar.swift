import SwiftUI
import TorrentEngineModel

struct FooterBarContainer: View {
    @Environment(TorrentStore.self) private var store
    let torrentState: TorrentListState
    let selectionState: TorrentSelectionState
    let selection: TorrentSidebarSelection
    let searchText: String
    let labelIDsForTorrent: (TorrentItem.ID) -> Set<TorrentLabel.ID>
    let trackerHostsForTorrent: (TorrentItem.ID) -> Set<String>
    let openNetworkSettings: () -> Void
    let openTransfersSettings: () -> Void

    var body: some View {
        FooterBar(
            networkInterfaceText: networkInterfaceText,
            networkInterfaceIcon: networkInterfaceIcon,
            networkInterfaceIsWarning: networkInterfaceIsWarning,
            networkInterfaceHelp: networkInterfaceHelp,
            totalDownloadRate: torrentState.totalDownloadRate,
            totalUploadRate: torrentState.totalUploadRate,
            torrentCount: torrentState.rows.count,
            displayedTorrentCount: displayedTorrentCount,
            selectedTorrentCount: selectionState.ids.count,
            engineAvailable: store.engineAvailable,
            openNetworkSettings: openNetworkSettings,
            openTransfersSettings: openTransfersSettings
        )
    }

    private var networkInterfaceText: String {
        guard store.settings.requireNetworkInterface else {
            return "Default"
        }

        let interfaceName = store.settings.libtorrentRequiredNetworkInterfaceName
        guard !interfaceName.isEmpty else {
            return "Choose Interface"
        }

        guard let option = store.networkInterfaces.first(where: { $0.name == interfaceName }) else {
            return interfaceName
        }

        return option.displayName
    }

    private var networkInterfaceIsWarning: Bool {
        store.settings.requireNetworkInterface && !store.requiredNetworkInterfaceAvailable
            || (!store.networkStatus.networkBlocked && !store.networkStatus.lastError.isEmpty)
    }

    private var networkInterfaceIcon: String {
        if !store.networkStatus.networkBlocked && !store.networkStatus.lastError.isEmpty {
            return "exclamationmark.triangle"
        }
        guard store.settings.requireNetworkInterface else {
            return "network"
        }

        guard store.settings.showOnlyVPNInterfaces else {
            return "cable.connector.horizontal"
        }

        return store.requiredNetworkInterfaceAvailable ? "lock" : "lock.open"
    }

    private var networkInterfaceHelp: String {
        guard store.engineAvailable else {
            return "The torrent engine could not start."
        }
        if store.networkStatus.networkBlocked {
            return "Network traffic is blocked until the selected interface is available."
        }
        if store.networkStatus.isApplying {
            return "Network settings are being applied."
        }
        if !store.networkStatus.lastError.isEmpty {
            return store.networkStatus.lastError
        }
        if store.networkStatus.hasListener {
            guard !store.networkStatus.endpoint.isEmpty else {
                return "Incoming listener is active."
            }
            return "Incoming listener is active on \(store.networkStatus.endpoint)."
        }
        return "No incoming listener has been observed yet."
    }

    private var displayedTorrentCount: Int {
        let scopedRows = torrentState.rows.filter { row in
            selection.contains(
                row,
                labelIDs: labelIDsForTorrent(row.id),
                trackerHosts: trackerHostsForTorrent(row.id)
            )
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return scopedRows.count
        }
        return scopedRows.filter { row in
            row.name.localizedStandardContains(query)
        }.count
    }
}


private struct FooterBar: View {
    let networkInterfaceText: String
    let networkInterfaceIcon: String
    let networkInterfaceIsWarning: Bool
    let networkInterfaceHelp: String
    let totalDownloadRate: Int64
    let totalUploadRate: Int64
    let torrentCount: Int
    let displayedTorrentCount: Int
    let selectedTorrentCount: Int
    let engineAvailable: Bool
    let openNetworkSettings: () -> Void
    let openTransfersSettings: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 16) {
                Button(action: openNetworkSettings) {
                    Label(networkInterfaceText, systemImage: networkInterfaceIcon)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(networkInterfaceIsWarning ? Color.red : Color.secondary)
                .help(networkInterfaceHelp)
                .accessibilityLabel("Open Network Settings")
                .accessibilityValue(networkInterfaceAccessibilityValue)
                .accessibilityHint("Shows the current network interface policy and opens network settings.")

                Spacer(minLength: 16)

                Label(footerStatusText, systemImage: footerStatusIcon)
                    .lineLimit(1)
                    .foregroundStyle(engineAvailable ? Color.secondary : Color.red)
                    .help(footerStatusHelp)
            }

            Button(action: openTransfersSettings) {
                TransferRatesView(
                    downloadRate: totalDownloadRate,
                    uploadRate: totalUploadRate,
                    showsDownloadRate: true,
                    showsUploadRate: true
                )
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Open Transfer settings. Total network traffic, including torrent payload and protocol overhead.")
            .accessibilityLabel("Open Transfer Settings")
            .accessibilityValue("Download \(ByteFormat.rate(totalDownloadRate)), upload \(ByteFormat.rate(totalUploadRate))")
            .accessibilityHint("Shows total download and upload rates, and opens bandwidth limit settings.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 11)
        .background(.bar)
    }

    private var footerStatusText: String {
        guard engineAvailable else {
            return "Engine unavailable"
        }
        guard selectedTorrentCount > 0 else {
            return displayedTorrentCount == torrentCount ? torrentCountText : "\(displayedTorrentCount) of \(torrentCountText)"
        }
        return "\(selectedTorrentCount) of \(torrentCountText)"
    }

    private var networkInterfaceAccessibilityValue: String {
        switch networkInterfaceText {
        case "Default":
            return "Default interface"
        case "Choose Interface":
            return "No interface selected"
        default:
            return networkInterfaceText
        }
    }

    private var footerStatusHelp: String {
        guard engineAvailable else {
            return "The torrent engine could not start."
        }
        if selectedTorrentCount > 0 {
            return "Selected transfers out of total registered transfers."
        }
        return displayedTorrentCount == torrentCount ? "Total number of registered transfers." : "Displayed transfers out of total registered transfers."
    }

    private var footerStatusIcon: String {
        engineAvailable ? "tray.full" : "exclamationmark.triangle"
    }

    private var torrentCountText: String {
        "\(torrentCount) \(torrentCount == 1 ? "torrent" : "torrents")"
    }
}
