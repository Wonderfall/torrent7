import AppKit
import SwiftUI
import TorrentEngineModel
import UniformTypeIdentifiers

struct TorrentSettingsView: View {
    private let store: TorrentStore
    @Bindable private var state: TorrentSettingsState
    @State private var isConfirmingRestoreDefaults = false
    @State private var isChoosingDownloadFolder = false
    @State private var defaultApplicationStatus:
        TorrentDefaultApplicationStatus?
    @State private var defaultApplicationRequest:
        TorrentDefaultApplicationRequest? = .refresh()
    @State private var isShowingIncomingConnectionsInfo = false
    @State private var isShowingDHTNetworkInfo = false
    @State private var isShowingDHTEligibilityInfo = false
    @State private var isShowingDHTDiscoveryPolicyInfo = false
    @State private var isShowingDHTContributionInfo = false
    @State private var isShowingPeerExchangeInfo = false
    @State private var isShowingLocalServiceDiscoveryInfo = false
    @State private var isShowingHTTPSTrackerPolicyInfo = false
    @State private var isShowingHTTPSWebSeedPolicyInfo = false
    @State private var isShowingAnonymousModeInfo = false
    @State private var isShowingVPNOnlyInfo = false
    @State private var pendingRequireNetworkInterface: Bool?
    @State private var pendingPeerExchangePlugin: Bool?
    @State private var settingsError: String?
    @State private var pendingDownloadFolderURL: URL?

    init(store: TorrentStore, state: TorrentSettingsState) {
        self.store = store
        self.state = state
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $state.selectedTab) {
                Tab("General", systemImage: "slider.horizontal.3", value: .general) {
                    generalSettings
                }

                Tab("Interface", systemImage: "macwindow", value: .interface) {
                    interfaceSettings
                }

                Tab("Transfers", systemImage: "arrow.up.arrow.down", value: .transfers) {
                    transfersSettings
                }

                Tab("Discovery", systemImage: "dot.radiowaves.left.and.right", value: .discovery) {
                    discoverySettings
                }

                Tab("Network", systemImage: "network", value: .network) {
                    networkSettings
                }
            }
            .scenePadding()

            Divider()

            HStack {
                Spacer()

                Button("Restore All Defaults...") {
                    isConfirmingRestoreDefaults = true
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 500, height: 600)
        .confirmationDialog("Restore all settings to defaults?", isPresented: $isConfirmingRestoreDefaults) {
            Button("Restore All Defaults", role: .destructive) {
                store.restoreDefaultSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This resets General, Interface, Transfers, Network, Discovery, and the saved download folder.")
        }
        .fileImporter(
            isPresented: $isChoosingDownloadFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleDownloadFolderImport(result)
        }
        .task(id: pendingDownloadFolderURL) {
            guard let url = pendingDownloadFolderURL else {
                return
            }
            let result = await store.chooseDownloadFolder(
                url,
                reportsGlobalError: false
            )
            guard !Task.isCancelled,
                  pendingDownloadFolderURL == url else {
                return
            }
            switch result {
            case .success:
                settingsError = nil
            case .failure(is CancellationError):
                settingsError = nil
            case .failure(let error):
                settingsError = error.localizedDescription
            }
            pendingDownloadFolderURL = nil
        }
        .task(id: defaultApplicationRequest?.id) {
            guard let request = defaultApplicationRequest else {
                return
            }
            let context = TorrentDefaultApplicationContext(
                bundleURL: Bundle.main.bundleURL,
                bundleIdentifier: Bundle.main.bundleIdentifier,
                runningApplicationBundleURL:
                    NSRunningApplication.current.bundleURL
            )
            do {
                var status = try await TorrentDefaultApplicationService.status(
                    for: context
                )
                if request.action == .setTorrentFileDefault {
                    try await TorrentDefaultApplicationService
                        .setAsTorrentFileDefault(
                            applicationURL: status.applicationURL
                        )
                    status =
                        try await TorrentDefaultApplicationService.status(
                            for: context
                        )
                }
                try Task.checkCancellation()
                guard defaultApplicationRequest?.id == request.id else {
                    return
                }
                defaultApplicationStatus = status
                defaultApplicationRequest = nil
            } catch is CancellationError {
                guard !Task.isCancelled,
                      defaultApplicationRequest?.id
                        == request.id else {
                    return
                }
                defaultApplicationRequest = nil
            } catch {
                guard !Task.isCancelled,
                      defaultApplicationRequest?.id == request.id else {
                    return
                }
                defaultApplicationRequest = nil
                settingsError = error.localizedDescription
            }
        }
        .alert("Settings Error", isPresented: settingsErrorBinding) {
            Button("OK") {
                settingsError = nil
            }
        } message: {
            Text(settingsError ?? "")
        }
        .alert(requireNetworkInterfaceConfirmationTitle, isPresented: requireNetworkInterfaceConfirmationBinding) {
            Button("Cancel", role: .cancel) {
                pendingRequireNetworkInterface = nil
            }
            Button(requireNetworkInterfaceConfirmationAction) {
                if let pendingRequireNetworkInterface {
                    store.setRequireNetworkInterface(pendingRequireNetworkInterface)
                }
                pendingRequireNetworkInterface = nil
            }
        } message: {
            Text(requireNetworkInterfaceConfirmationMessage)
        }
        .alert(peerExchangePluginConfirmationTitle, isPresented: peerExchangePluginConfirmationBinding) {
            Button("Cancel", role: .cancel) {
                pendingPeerExchangePlugin = nil
            }
            Button(peerExchangePluginConfirmationAction) {
                if let pendingPeerExchangePlugin {
                    var settings = state.settings
                    settings.enablePeerExchangePlugin = pendingPeerExchangePlugin
                    store.updateSettings(settings)
                }
                pendingPeerExchangePlugin = nil
            }
        } message: {
            Text(peerExchangePluginConfirmationMessage)
        }
    }

    private var generalSettings: some View {
        Form {
            downloadsSection
            defaultsSection
            powerSection
        }
        .formStyle(.grouped)
    }

    private var interfaceSettings: some View {
        Form {
            notificationsSection
            dockSection
        }
        .formStyle(.grouped)
    }

    private var transfersSettings: some View {
        Form {
            bandwidthSection
            queueSection
            seedingSection
        }
        .formStyle(.grouped)
    }

    private var networkSettings: some View {
        Form {
            networkInterfaceSection
            incomingConnectionsSection
            protocolAndPrivacySection
        }
        .formStyle(.grouped)
    }

    private var discoverySettings: some View {
        Form {
            dhtDiscoverySection
            peerExchangeDiscoverySection
            localDiscoverySection
            httpsSourcePolicySection
        }
        .formStyle(.grouped)
    }

    private var downloadsSection: some View {
        Section("Downloads") {
            HStack(spacing: 12) {
                Text("Download folder")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 16)

                Text(downloadFolderText)
                    .foregroundStyle(state.downloadFolder == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(downloadFolderText)

                Button("Choose...") {
                    isChoosingDownloadFolder = true
                }
                .fixedSize()
            }

            Text("Choose a dedicated folder. \(AppIdentity.displayName) can access files inside this folder to download, verify, and resume torrents.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var defaultsSection: some View {
        Section("Defaults") {
            LabeledContent(".torrent files") {
                defaultHandlerControls(
                    isDefault:
                        defaultApplicationStatus?
                            .isDefaultForTorrentFiles == true,
                    isUpdating: defaultApplicationRequest != nil,
                    action: makeDefaultForTorrentFiles
                )
            }

            LabeledContent("Magnet links") {
                magnetDefaultStatus
            }

            Text("macOS may ask before changing default apps. Magnet defaults are controlled by the system or browser prompt.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Completion notifications and badge", isOn: setting(\.completionNotificationsEnabled))
            Toggle("Play completion sound", isOn: setting(\.completionNotificationSoundEnabled))
                .disabled(!state.settings.completionNotificationsEnabled)
            Toggle("Show torrent names in notifications", isOn: setting(\.completionNotificationNamesEnabled))
                .disabled(!state.settings.completionNotificationsEnabled)
        }
    }

    private var dockSection: some View {
        Section("Dock") {
            Toggle("Show transfer rates", isOn: setting(\.dockTransferRatesEnabled))
        }
    }

    private var powerSection: some View {
        Section("Power") {
            Toggle("Prevent computer sleep during transfers", isOn: setting(\.preventSleepDuringTransfers))
        }
    }

    private var bandwidthSection: some View {
        Section("Bandwidth") {
            Toggle("Limit download speed", isOn: enabled(\.downloadRateLimitKBps, defaultValue: 1024))
            if state.settings.downloadRateLimitKBps > 0 {
                IntegerFieldRow("Download speed", value: setting(\.downloadRateLimitKBps), range: 1...1_000_000, suffix: "KB/s")
            }

            Toggle("Limit upload speed", isOn: enabled(\.uploadRateLimitKBps, defaultValue: 1024))
            if state.settings.uploadRateLimitKBps > 0 {
                IntegerFieldRow("Upload speed", value: setting(\.uploadRateLimitKBps), range: 1...1_000_000, suffix: "KB/s")
            }
        }
    }

    private var queueSection: some View {
        Section("Queue") {
            Toggle("Limit active downloads", isOn: enabled(\.maximumActiveDownloads, defaultValue: 3))
            if state.settings.maximumActiveDownloads > 0 {
                IntegerFieldRow("Active downloads", value: setting(\.maximumActiveDownloads), range: 1...1000)
            }

            Toggle("Limit active uploads/seeds", isOn: enabled(\.maximumActiveSeeds, defaultValue: 5))
            if state.settings.maximumActiveSeeds > 0 {
                IntegerFieldRow("Active uploads/seeds", value: setting(\.maximumActiveSeeds), range: 1...1000)
            }
        }
    }

    private var seedingSection: some View {
        Section("Seeding") {
            IntegerFieldRow(
                "Seeding ratio limit",
                value: setting(\.stopSeedingRatioPercent),
                range: 1...10_000,
                suffix: "%"
            )

            IntegerFieldRow(
                "Seeding time limit",
                value: setting(\.stopSeedingAfterHours),
                range: 1...100_000,
                suffix: "hours"
            )
        }
    }

    private var incomingConnectionsSection: some View {
        Section("Incoming Connections") {
            incomingConnectionsRow

            Toggle(isOn: automaticIncomingPort) {
                disabledAwareLabel("Use automatic incoming port", isDisabled: incomingPortControlsDisabled)
            }
            .disabled(incomingPortControlsDisabled)
            if state.settings.incomingPort > 0 {
                IntegerFieldRow(
                    "Incoming port",
                    value: setting(\.incomingPort),
                    range: TorrentSettings.minimumManualIncomingPort...TorrentSettings.maximumIncomingPort,
                    validationMessage: "Use a port from 1024 to 65535.",
                    isLabelDisabled: incomingPortControlsDisabled
                )
                    .disabled(incomingPortControlsDisabled)
            }

            Toggle(isOn: unavailableAwareToggle(isUnavailable: portForwardingDisabled, keyPath: \.usePortForwarding)) {
                disabledAwareLabel("Use UPnP/NAT-PMP port forwarding", isDisabled: portForwardingDisabled)
            }
            .disabled(portForwardingDisabled)
            .help(portForwardingHelp)
        }
    }

    private var dhtDiscoverySection: some View {
        Section("Distributed Hash Table (DHT)") {
            dhtNetworkRow
            dhtEligibilityRow
            dhtDiscoveryPolicyRow
            dhtContributionRow
        }
    }

    private var peerExchangeDiscoverySection: some View {
        Section("Peer Exchange (PEX)") {
            peerExchangePluginRow
            Toggle(isOn: setting(\.usePeerExchangeByDefault)) {
                disabledAwareLabel("Prefer PEX for eligible torrents", isDisabled: !state.settings.enablePeerExchangePlugin)
            }
            .disabled(!state.settings.enablePeerExchangePlugin)
            .help(state.settings.enablePeerExchangePlugin
                  ? "Eligible torrents use Peer Exchange unless disabled by the torrent or per-torrent policy."
                  : "Enable Peer Exchange first.")
        }
    }

    private var httpsSourcePolicySection: some View {
        Section("HTTPS Source Policies") {
            httpsTrackerPolicyRow
            httpsWebSeedPolicyRow
        }
    }

    private var localDiscoverySection: some View {
        Section("Local Service Discovery (LSD)") {
            localServiceDiscoveryRow

            Toggle(isOn: setting(\.useLocalServiceDiscoveryByDefault)) {
                disabledAwareLabel("Prefer LSD for eligible torrents", isDisabled: !state.settings.effectiveEnableLocalServiceDiscovery)
            }
            .disabled(!state.settings.effectiveEnableLocalServiceDiscovery)
            .help(state.settings.effectiveEnableLocalServiceDiscovery
                  ? "Eligible torrents use Local Service Discovery unless disabled by the torrent or per-torrent policy."
                  : "Enable Local Service Discovery first.")
        }
    }

    private var protocolAndPrivacySection: some View {
        Section("Protocol & Privacy") {
            Picker("Protocol encryption", selection: protocolEncryption) {
                ForEach(TorrentProtocolEncryption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            anonymousModeRow
        }
    }

    private var incomingConnectionsRow: some View {
        HStack {
            HStack(spacing: 5) {
                Text("Accept incoming connections")

                Button {
                    isShowingIncomingConnectionsInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("About incoming connections")
                .accessibilityLabel("About incoming connections")
                .popover(isPresented: $isShowingIncomingConnectionsInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Accept incoming connections")
                            .font(.headline)

                        Text("Allows other peers to connect to this app. This improves connectivity and seeding.")

                        Text("Turning it off rejects incoming peer connections, but outgoing transfers, DHT, and tracker traffic can still work.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(width: 320, alignment: .leading)
                }
            }

            Spacer()

            Toggle("", isOn: setting(\.acceptIncomingConnections))
                .labelsHidden()
                .accessibilityLabel("Accept incoming connections")
        }
        .help("Allow other peers to connect to this app.")
    }

    private var dhtNetworkRow: some View {
        HStack {
            HStack(spacing: 5) {
                Text("Enable DHT network")

                Button {
                    isShowingDHTNetworkInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("About the DHT network")
                .accessibilityLabel("About the DHT network")
                .popover(isPresented: $isShowingDHTNetworkInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("DHT network")
                            .font(.headline)

                        Text("Starts the shared DHT node. Allowed public torrents can then use it to discover peers without relying only on trackers.")

                        Text("Turning this off prevents DHT for every torrent. Starting the node alone does not make every torrent query it.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(width: 340, alignment: .leading)
                }
            }

            Spacer()

            Toggle("", isOn: setting(\.enableDHTNetwork))
                .labelsHidden()
                .accessibilityLabel("Enable DHT network")
        }
        .help("Start the session DHT node.")
    }

    private var dhtEligibilityRow: some View {
        HStack {
            HStack(spacing: 5) {
                disabledAwareLabel(
                    "Allow DHT for eligible torrents",
                    isDisabled: !state.settings.enableDHTNetwork
                )

                Button {
                    isShowingDHTEligibilityInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("About DHT eligibility")
                .accessibilityLabel("About DHT eligibility")
                .popover(isPresented: $isShowingDHTEligibilityInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Eligible torrents")
                            .font(.headline)

                        Text("An eligible torrent is public, has trusted metadata, and is not blocked from DHT by its source or per-torrent setting.")

                        Text("A magnet can use DHT before its metadata is known only with explicit consent.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(width: 340, alignment: .leading)
                }
            }

            Spacer()

            Toggle("", isOn: setting(\.useDHTByDefault))
                .labelsHidden()
                .disabled(!state.settings.enableDHTNetwork)
                .accessibilityLabel("Allow DHT for eligible torrents")
        }
        .help(state.settings.enableDHTNetwork
              ? "Allow eligible torrents to use DHT unless disabled per torrent."
              : "Enable the DHT network first.")
    }

    private var dhtDiscoveryPolicyRow: some View {
        HStack {
            HStack(spacing: 5) {
                disabledAwareLabel(
                    "DHT discovery policy",
                    isDisabled: !state.settings.enableDHTNetwork
                )

                Button {
                    isShowingDHTDiscoveryPolicyInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("About the DHT discovery policy")
                .accessibilityLabel("About the DHT discovery policy")
                .popover(isPresented: $isShowingDHTDiscoveryPolicyInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("DHT discovery policy")
                            .font(.headline)

                        Text("Alongside trackers queries DHT immediately. After all trackers fail waits until every usable tracker has failed or timed out; trackerless torrents use DHT immediately.")

                        Text("Waiting reduces torrent-specific DHT lookups, but peer discovery may be slower while trackers time out.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(width: 340, alignment: .leading)
                }
            }

            Spacer()

            Picker("DHT discovery policy", selection: setting(\.dhtDiscoveryPolicy)) {
                ForEach(TorrentDHTDiscoveryPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .labelsHidden()
            .disabled(!state.settings.enableDHTNetwork)
            .accessibilityLabel("DHT discovery policy")
        }
        .help(state.settings.enableDHTNetwork
              ? "Choose whether DHT runs with trackers or only after every usable tracker fails."
              : "Enable the DHT network first.")
    }

    private var dhtContributionRow: some View {
        HStack {
            HStack(spacing: 5) {
                disabledAwareLabel(
                    "Reduce DHT contribution",
                    isDisabled: !state.settings.enableDHTNetwork
                )

                Button {
                    isShowingDHTContributionInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("About reduced DHT contribution")
                .accessibilityLabel("About reduced DHT contribution")
                .popover(isPresented: $isShowingDHTContributionInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reduced DHT contribution")
                            .font(.headline)

                        Text("Peer-discovery queries still work, but this node does not answer other nodes' requests or remain in their routing tables.")

                        Text("This reduces participation in the shared network; it does not hide this client's own DHT lookups.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(width: 340, alignment: .leading)
                }
            }

            Spacer()

            Toggle("", isOn: setting(\.reduceDHTContribution))
                .labelsHidden()
                .disabled(!state.settings.enableDHTNetwork)
                .accessibilityLabel("Reduce DHT contribution")
        }
        .help(state.settings.enableDHTNetwork
              ? "Query DHT without serving other DHT users."
              : "Enable the DHT network first.")
    }

    private var peerExchangePluginRow: some View {
        HStack {
            HStack(spacing: 5) {
                Text("Enable Peer Exchange (PEX)")

                Button {
                    isShowingPeerExchangeInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("About Peer Exchange")
                .accessibilityLabel("About Peer Exchange")
                .popover(isPresented: $isShowingPeerExchangeInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Peer Exchange")
                            .font(.headline)

                        Text("Loads libtorrent's Peer Exchange extension so peers can share other peer addresses for the same torrent.")

                        Text("Turning this off prevents PEX for all torrents and restarts the session. Private torrents and torrents that disable PEX keep that policy.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(width: 340, alignment: .leading)
                }
            }

            Spacer()

            Toggle("", isOn: peerExchangePlugin)
                .labelsHidden()
                .accessibilityLabel("Enable Peer Exchange (PEX)")
        }
        .help("Enable the Peer Exchange extension.")
    }

    private var localServiceDiscoveryRow: some View {
        HStack {
            HStack(spacing: 5) {
                disabledAwareLabel("Enable Local Service Discovery (LSD)", isDisabled: state.settings.showOnlyVPNInterfaces)

                Button {
                    isShowingLocalServiceDiscoveryInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("About Local Service Discovery")
                .accessibilityLabel("About Local Service Discovery")
                .popover(isPresented: $isShowingLocalServiceDiscoveryInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Local Service Discovery")
                            .font(.headline)

                        Text("Lets eligible torrents find peers announced by other clients on the same local network.")

                        Text("It is unavailable while using VPN interfaces only, because local discovery can expose traffic outside the VPN path.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(width: 340, alignment: .leading)
                }
            }

            Spacer()

            Toggle(
                "",
                isOn: unavailableAwareToggle(
                    isUnavailable: state.settings.showOnlyVPNInterfaces,
                    keyPath: \.enableLocalServiceDiscovery
                )
            )
            .labelsHidden()
            .disabled(state.settings.showOnlyVPNInterfaces)
            .accessibilityLabel("Enable Local Service Discovery (LSD)")
        }
        .help(state.settings.showOnlyVPNInterfaces ? "Unavailable while using VPN interfaces only." : "Enable local peer discovery.")
    }

    private var httpsTrackerPolicyRow: some View {
        HStack {
            HStack(spacing: 5) {
                Text("Tracker policy")

                Button {
                    isShowingHTTPSTrackerPolicyInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("About HTTPS trackers")
                .accessibilityLabel("About HTTPS trackers")
                .popover(isPresented: $isShowingHTTPSTrackerPolicyInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("HTTPS trackers")
                            .font(.headline)

                        Text("Prefer HTTPS moves HTTPS trackers into earlier tiers while retaining HTTP and UDP as fallbacks. Require HTTPS removes every non-HTTPS tracker.")

                        Text("Only Require HTTPS guarantees tracker transport security. This does not affect peer, DHT, or peer exchange traffic.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(width: 340, alignment: .leading)
                }
            }

            Spacer()

            Picker("Tracker policy", selection: setting(\.httpsTrackerPolicy)) {
                ForEach(TorrentHTTPSTrackerPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .labelsHidden()
            .accessibilityLabel("HTTPS tracker policy")
        }
        .help("Choose whether to preserve torrent tiers, prefer HTTPS with fallback, or require HTTPS.")
    }

    private var httpsWebSeedPolicyRow: some View {
        HStack {
            HStack(spacing: 5) {
                Text("Web seed policy")

                Button {
                    isShowingHTTPSWebSeedPolicyInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("About HTTPS web seeds")
                .accessibilityLabel("About HTTPS web seeds")
                .popover(isPresented: $isShowingHTTPSWebSeedPolicyInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("HTTPS web seeds")
                            .font(.headline)

                        Text("Require HTTPS removes non-HTTPS web seeds. Original preserves every web seed advertised by the torrent.")

                        Text("This does not affect trackers, peer, DHT, or peer exchange traffic.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(width: 340, alignment: .leading)
                }
            }

            Spacer()

            Picker("Web seed policy", selection: setting(\.httpsWebSeedPolicy)) {
                ForEach(TorrentHTTPSWebSeedPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .labelsHidden()
            .accessibilityLabel("HTTPS web seed policy")
        }
        .help("Choose whether to preserve torrent web seeds or require HTTPS.")
    }

    private var networkInterfaceSection: some View {
        Section("Network Interface") {
            Toggle("Bind torrent connections to selected interface", isOn: requireNetworkInterface)
                .help("Bind libtorrent sockets to the selected interface. Hostname lookup still uses macOS system DNS.")

            vpnOnlyModeRow

            if state.settings.requireNetworkInterface {
                Picker("Interface", selection: requiredNetworkInterfaceName) {
                    if state.settings.requiredNetworkInterfaceName.isEmpty {
                        Text(interfacePickerPlaceholder)
                            .tag("")
                    }

                    ForEach(state.selectableNetworkInterfaces) { option in
                        Text(option.displayName).tag(option.name)
                    }

                    if shouldShowMissingRequiredInterface {
                        Text("\(state.settings.requiredNetworkInterfaceName) (\(state.settings.showOnlyVPNInterfaces ? "VPN Inactive" : "Unavailable"))")
                            .tag(state.settings.requiredNetworkInterfaceName)
                    }
                }
                .disabled(state.selectableNetworkInterfaces.isEmpty && state.settings.requiredNetworkInterfaceName.isEmpty)

                LabeledContent("Status") {
                    Text(state.networkProtectionStatusText)
                        .foregroundStyle(state.requiredNetworkInterfaceAvailable ? Color.secondary : Color.red)
                }
            }
        }
    }

    private var interfacePickerPlaceholder: String {
        guard state.networkInterfacesAreAuthoritative else {
            return "Refreshing interfaces…"
        }
        guard state.selectableNetworkInterfaces.isEmpty else {
            return "Choose an interface"
        }
        return state.settings.showOnlyVPNInterfaces
            ? "No active VPN interfaces"
            : "No interfaces available"
    }

    private var vpnOnlyModeRow: some View {
        HStack {
            HStack(spacing: 5) {
                disabledAwareLabel("Use VPN interfaces only", isDisabled: !state.settings.requireNetworkInterface)

                Button {
                    isShowingVPNOnlyInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("About using VPN interfaces only")
                .accessibilityLabel("About using VPN interfaces only")
                .popover(isPresented: $isShowingVPNOnlyInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use VPN interfaces only")
                            .font(.headline)

                        Text("Transfers pause unless a VPN-backed interface is selected and available. This enforces reduced client identifiability and disables UPnP/NAT-PMP and local peer discovery.")

                        Text("It only constrains this app. Use your VPN kill switch or firewall for system-wide leak protection.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(width: 320, alignment: .leading)
                }
            }

            Spacer()

            Toggle("", isOn: showOnlyVPNInterfaces)
                .labelsHidden()
                .disabled(!state.settings.requireNetworkInterface)
                .accessibilityLabel("Use VPN interfaces only")
        }
        .help("Only allow transfers through an active VPN-backed interface.")
    }

    private var anonymousModeRow: some View {
        HStack {
            HStack(spacing: 5) {
                Text("Reduce client identifiability")

                Button {
                    isShowingAnonymousModeInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("About reducing client identifiability")
                .accessibilityLabel("About reducing client identifiability")
                .popover(isPresented: $isShowingAnonymousModeInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reduce client identifiability")
                            .font(.headline)

                        Text("Uses libtorrent's anonymous mode to reduce identifying metadata, including client/version details and some local address exposure.")

                        Text("It does not hide your IP address. Use a trusted VPN or network-level protection for that.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(width: 320, alignment: .leading)
                }
            }

            Spacer()

            Toggle(
                "",
                isOn: enforcedOnToggle(
                    isEnforced: state.settings.showOnlyVPNInterfaces,
                    keyPath: \.anonymousMode
                )
            )
                .labelsHidden()
                .disabled(state.settings.showOnlyVPNInterfaces)
                .accessibilityLabel("Reduce client identifiability")
        }
        .help(state.settings.showOnlyVPNInterfaces
              ? "Enforced while using VPN interfaces only."
              : "Reduce client and version details sent by libtorrent.")
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<TorrentSettings, Value>) -> Binding<Value> {
        Binding {
            state.settings[keyPath: keyPath]
        } set: { value in
            var settings = state.settings
            settings[keyPath: keyPath] = value
            store.updateSettings(settings)
        }
    }

    private func unavailableAwareToggle(
        isUnavailable: Bool,
        keyPath: WritableKeyPath<TorrentSettings, Bool>
    ) -> Binding<Bool> {
        Binding {
            isUnavailable ? false : state.settings[keyPath: keyPath]
        } set: { value in
            guard !isUnavailable else {
                return
            }
            var settings = state.settings
            settings[keyPath: keyPath] = value
            store.updateSettings(settings)
        }
    }

    private func enforcedOnToggle(
        isEnforced: Bool,
        keyPath: WritableKeyPath<TorrentSettings, Bool>
    ) -> Binding<Bool> {
        Binding {
            isEnforced ? true : state.settings[keyPath: keyPath]
        } set: { value in
            guard !isEnforced else {
                return
            }
            var settings = state.settings
            settings[keyPath: keyPath] = value
            store.updateSettings(settings)
        }
    }

    private func disabledAwareLabel(_ title: String, isDisabled: Bool) -> some View {
        Text(title)
            .foregroundStyle(isDisabled ? Color.secondary : Color.primary)
    }

    private func enabled(_ keyPath: WritableKeyPath<TorrentSettings, Int>, defaultValue: Int) -> Binding<Bool> {
        Binding {
            state.settings[keyPath: keyPath] > 0
        } set: { isEnabled in
            var settings = state.settings
            settings[keyPath: keyPath] = isEnabled ? max(state.settings[keyPath: keyPath], defaultValue) : 0
            store.updateSettings(settings)
        }
    }

    private var automaticIncomingPort: Binding<Bool> {
        Binding {
            state.settings.incomingPort == 0
        } set: { isAutomatic in
            var settings = state.settings
            settings.incomingPort = isAutomatic ? 0 : 6881
            store.updateSettings(settings)
        }
    }

    private var portForwardingDisabled: Bool {
        !state.settings.acceptIncomingConnections || state.settings.showOnlyVPNInterfaces
    }

    private var portForwardingHelp: String {
        if !state.settings.acceptIncomingConnections {
            return "Unavailable while incoming connections are disabled."
        }
        if state.settings.showOnlyVPNInterfaces {
            return "Unavailable while using VPN interfaces only."
        }
        return ""
    }

    private var incomingPortControlsDisabled: Bool {
        !state.settings.acceptIncomingConnections
    }

    private var protocolEncryption: Binding<TorrentProtocolEncryption> {
        Binding {
            state.settings.protocolEncryption
        } set: { value in
            var settings = state.settings
            settings.protocolEncryption = value
            store.updateSettings(settings)
        }
    }

    private var requireNetworkInterface: Binding<Bool> {
        Binding {
            state.settings.requireNetworkInterface
        } set: { isRequired in
            guard isRequired != state.settings.requireNetworkInterface else {
                return
            }
            pendingRequireNetworkInterface = isRequired
        }
    }

    private var peerExchangePlugin: Binding<Bool> {
        Binding {
            state.settings.enablePeerExchangePlugin
        } set: { isEnabled in
            guard isEnabled != state.settings.enablePeerExchangePlugin else {
                return
            }
            pendingPeerExchangePlugin = isEnabled
        }
    }

    private var requiredNetworkInterfaceName: Binding<String> {
        Binding {
            state.settings.requiredNetworkInterfaceName
        } set: { name in
            store.setRequiredNetworkInterfaceName(name)
        }
    }

    private var showOnlyVPNInterfaces: Binding<Bool> {
        Binding {
            state.settings.showOnlyVPNInterfaces
        } set: { isEnabled in
            store.setShowOnlyVPNInterfaces(isEnabled)
        }
    }

    private var requireNetworkInterfaceConfirmationBinding: Binding<Bool> {
        Binding {
            pendingRequireNetworkInterface != nil
        } set: { isPresented in
            if !isPresented {
                pendingRequireNetworkInterface = nil
            }
        }
    }

    private var requireNetworkInterfaceConfirmationTitle: String {
        pendingRequireNetworkInterface == true ? "Bind torrent connections to selected interface?" : "Stop binding torrent connections?"
    }

    private var requireNetworkInterfaceConfirmationAction: String {
        pendingRequireNetworkInterface == true ? "Bind" : "Stop Binding"
    }

    private var requireNetworkInterfaceConfirmationMessage: String {
        if pendingRequireNetworkInterface == true {
            return "Torrent sockets will bind to the selected interface. Existing peer connections are closed while the binding is applied, and transfers pause whenever that interface is unavailable. Hostname lookup still uses macOS system DNS."
        }
        return "Existing peer connections are closed while the binding is removed, then transfers use the system network route again."
    }

    private var peerExchangePluginConfirmationBinding: Binding<Bool> {
        Binding {
            pendingPeerExchangePlugin != nil
        } set: { isPresented in
            if !isPresented {
                pendingPeerExchangePlugin = nil
            }
        }
    }

    private var peerExchangePluginConfirmationTitle: String {
        pendingPeerExchangePlugin == true ? "Enable Peer Exchange?" : "Disable Peer Exchange?"
    }

    private var peerExchangePluginConfirmationAction: String {
        pendingPeerExchangePlugin == true ? "Enable" : "Disable"
    }

    private var peerExchangePluginConfirmationMessage: String {
        if pendingPeerExchangePlugin == true {
            return "This loads libtorrent's Peer Exchange extension. Applying this restarts the libtorrent session."
        }
        return "This unloads libtorrent's Peer Exchange extension and disables PEX for all torrents. Applying this restarts the libtorrent session."
    }

    private var shouldShowMissingRequiredInterface: Bool {
        let selectedName = state.settings.requiredNetworkInterfaceName
        guard !selectedName.isEmpty else {
            return false
        }
        return !state.selectableNetworkInterfaces.contains { $0.name == selectedName }
    }

    private var downloadFolderText: String {
        state.downloadFolder?.torrentFilePath ?? "Not set"
    }

    private var settingsErrorBinding: Binding<Bool> {
        Binding {
            settingsError != nil
        } set: { isPresented in
            if !isPresented {
                settingsError = nil
            }
        }
    }

    private func handleDownloadFolderImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }
            pendingDownloadFolderURL = url
        case .failure(let error):
            settingsError = error.localizedDescription
        }
    }

    private func defaultHandlerControls(
        isDefault: Bool,
        isUpdating: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            if isDefault {
                Label("Default", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else if isUpdating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Make Default...") {
                    action()
                }
            }
        }
    }

    private var magnetDefaultStatus: some View {
        HStack(spacing: 10) {
            if defaultApplicationStatus?.isDefaultForMagnetLinks == true {
                Label("Default", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else if defaultApplicationStatus == nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("Not Default")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func makeDefaultForTorrentFiles() {
        defaultApplicationRequest = .setTorrentFileDefault()
    }
}

private struct TorrentDefaultApplicationRequest: Identifiable, Sendable {
    enum Action: Equatable, Sendable {
        case refresh
        case setTorrentFileDefault
    }

    let id = UUID()
    let action: Action

    static func refresh() -> Self {
        Self(action: .refresh)
    }

    static func setTorrentFileDefault() -> Self {
        Self(action: .setTorrentFileDefault)
    }
}
