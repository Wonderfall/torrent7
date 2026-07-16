import Foundation

package enum TorrentSettingsTab: Hashable, Sendable {
    case general
    case interface
    case transfers
    case network
    case discovery
}


package enum TorrentProtocolEncryption: Int, Codable, CaseIterable, Identifiable, Sendable {
    case allowed = 0
    case required = 1
    case disabled = 2

    package var id: Int {
        rawValue
    }

    package var title: String {
        switch self {
        case .allowed:
            return "Allowed"
        case .required:
            return "Required"
        case .disabled:
            return "Disabled"
        }
    }
}

package struct TorrentSettings: Codable, Equatable, Sendable {
    private static let defaultsKey = "TorrentSettings"
    private static let maximumRateLimitKBps = 1_000_000
    private static let maximumActiveTorrentCount = 1_000
    private static let maximumStopSeedingRatioPercent = 10_000
    private static let maximumStopSeedingHours = 100_000
    package static let minimumManualIncomingPort = 1024
    package static let maximumIncomingPort = 65_535

    package var downloadRateLimitKBps = 0
    package var uploadRateLimitKBps = 0
    package var maximumActiveDownloads = 3
    package var maximumActiveSeeds = 5
    package var stopSeedingRatioPercent = 200
    package var stopSeedingAfterHours = 24
    package var incomingPort = 0
    package var acceptIncomingConnections = true
    package var usePortForwarding = false
    package var enableDHTNetwork = true
    package var useDHTByDefault = true
    package var enablePeerExchangePlugin = true
    package var usePeerExchangeByDefault = true
    package var useHTTPSTrackersOnly = false
    package var useHTTPSWebSeedsOnly = false
    package var enableLocalServiceDiscovery = false
    package var useLocalServiceDiscoveryByDefault = false
    package var protocolEncryption = TorrentProtocolEncryption.allowed
    package var anonymousMode = true
    package var requireNetworkInterface = false
    package var showOnlyVPNInterfaces = false
    package var requiredNetworkInterfaceName = ""
    package var completionNotificationsEnabled = true
    package var completionNotificationSoundEnabled = true
    package var completionNotificationNamesEnabled = false
    package var dockTransferRatesEnabled = true
    package var preventSleepDuringTransfers = false

    package init() {}

    private enum CodingKeys: String, CodingKey {
        case downloadRateLimitKBps
        case uploadRateLimitKBps
        case maximumActiveDownloads
        case maximumActiveSeeds
        case stopSeedingRatioPercent
        case stopSeedingAfterHours
        case incomingPort
        case acceptIncomingConnections
        case usePortForwarding
        case enableDHTNetwork
        case useDHTByDefault
        case enablePeerExchangePlugin
        case usePeerExchangeByDefault
        case useHTTPSTrackersOnly
        case useHTTPSWebSeedsOnly
        case enableLocalServiceDiscovery
        case useLocalServiceDiscoveryByDefault
        case protocolEncryption
        case anonymousMode
        case requireNetworkInterface
        case showOnlyVPNInterfaces
        case requiredNetworkInterfaceName
        case completionNotificationsEnabled
        case completionNotificationSoundEnabled
        case completionNotificationNamesEnabled
        case dockTransferRatesEnabled
        case preventSleepDuringTransfers
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var settings = TorrentSettings()
        settings.downloadRateLimitKBps = try values.decodeIfPresent(Int.self, forKey: .downloadRateLimitKBps) ?? settings.downloadRateLimitKBps
        settings.uploadRateLimitKBps = try values.decodeIfPresent(Int.self, forKey: .uploadRateLimitKBps) ?? settings.uploadRateLimitKBps
        settings.maximumActiveDownloads = try values.decodeIfPresent(Int.self, forKey: .maximumActiveDownloads) ?? settings.maximumActiveDownloads
        settings.maximumActiveSeeds = try values.decodeIfPresent(Int.self, forKey: .maximumActiveSeeds) ?? settings.maximumActiveSeeds
        settings.stopSeedingRatioPercent = try values.decodeIfPresent(Int.self, forKey: .stopSeedingRatioPercent) ?? settings.stopSeedingRatioPercent
        settings.stopSeedingAfterHours = try values.decodeIfPresent(Int.self, forKey: .stopSeedingAfterHours) ?? settings.stopSeedingAfterHours
        settings.incomingPort = try values.decodeIfPresent(Int.self, forKey: .incomingPort) ?? settings.incomingPort
        settings.acceptIncomingConnections = try values.decodeIfPresent(Bool.self, forKey: .acceptIncomingConnections) ?? settings.acceptIncomingConnections
        settings.usePortForwarding = try values.decodeIfPresent(Bool.self, forKey: .usePortForwarding) ?? settings.usePortForwarding
        settings.enableDHTNetwork = try values.decodeIfPresent(Bool.self, forKey: .enableDHTNetwork) ?? settings.enableDHTNetwork
        settings.useDHTByDefault = try values.decodeIfPresent(Bool.self, forKey: .useDHTByDefault) ?? settings.useDHTByDefault
        settings.enablePeerExchangePlugin = try values.decodeIfPresent(Bool.self, forKey: .enablePeerExchangePlugin) ?? settings.enablePeerExchangePlugin
        settings.usePeerExchangeByDefault = try values.decodeIfPresent(Bool.self, forKey: .usePeerExchangeByDefault) ?? settings.usePeerExchangeByDefault
        settings.useHTTPSTrackersOnly = try values.decodeIfPresent(Bool.self, forKey: .useHTTPSTrackersOnly) ?? settings.useHTTPSTrackersOnly
        settings.useHTTPSWebSeedsOnly = try values.decodeIfPresent(Bool.self, forKey: .useHTTPSWebSeedsOnly) ?? settings.useHTTPSWebSeedsOnly
        settings.enableLocalServiceDiscovery = try values.decodeIfPresent(Bool.self, forKey: .enableLocalServiceDiscovery) ?? settings.enableLocalServiceDiscovery
        settings.useLocalServiceDiscoveryByDefault = try values.decodeIfPresent(Bool.self, forKey: .useLocalServiceDiscoveryByDefault) ?? settings.useLocalServiceDiscoveryByDefault
        settings.protocolEncryption = try values.decodeIfPresent(TorrentProtocolEncryption.self, forKey: .protocolEncryption) ?? settings.protocolEncryption
        settings.anonymousMode = try values.decodeIfPresent(Bool.self, forKey: .anonymousMode) ?? settings.anonymousMode
        settings.requireNetworkInterface = try values.decodeIfPresent(Bool.self, forKey: .requireNetworkInterface) ?? settings.requireNetworkInterface
        settings.showOnlyVPNInterfaces = try values.decodeIfPresent(Bool.self, forKey: .showOnlyVPNInterfaces) ?? settings.showOnlyVPNInterfaces
        settings.requiredNetworkInterfaceName = try values.decodeIfPresent(String.self, forKey: .requiredNetworkInterfaceName) ?? settings.requiredNetworkInterfaceName
        settings.completionNotificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .completionNotificationsEnabled) ?? settings.completionNotificationsEnabled
        settings.completionNotificationSoundEnabled = try values.decodeIfPresent(Bool.self, forKey: .completionNotificationSoundEnabled) ?? settings.completionNotificationSoundEnabled
        settings.completionNotificationNamesEnabled = try values.decodeIfPresent(Bool.self, forKey: .completionNotificationNamesEnabled) ?? settings.completionNotificationNamesEnabled
        settings.dockTransferRatesEnabled = try values.decodeIfPresent(Bool.self, forKey: .dockTransferRatesEnabled) ?? settings.dockTransferRatesEnabled
        settings.preventSleepDuringTransfers = try values.decodeIfPresent(Bool.self, forKey: .preventSleepDuringTransfers) ?? settings.preventSleepDuringTransfers
        self = settings.clamped()
    }

    package var libtorrentDownloadRateLimit: Int32 {
        rateLimitBytesPerSecond(downloadRateLimitKBps)
    }

    package var libtorrentUploadRateLimit: Int32 {
        rateLimitBytesPerSecond(uploadRateLimitKBps)
    }

    package var libtorrentActiveDownloads: Int32 {
        activeLimit(maximumActiveDownloads)
    }

    package var libtorrentActiveSeeds: Int32 {
        activeLimit(maximumActiveSeeds)
    }

    package var libtorrentActiveLimit: Int32 {
        let activeDownloads = Self.clampedActiveTorrentCount(maximumActiveDownloads)
        let activeSeeds = Self.clampedActiveTorrentCount(maximumActiveSeeds)
        if activeDownloads == 0 || activeSeeds == 0 {
            return Int32.max
        }
        return Int32(activeDownloads + activeSeeds)
    }

    package var libtorrentSeedTimeLimit: Int32 {
        Int32(Self.clampedStopSeedingHours(stopSeedingAfterHours) * 60 * 60)
    }

    package var libtorrentShareRatioLimit: Int32 {
        Int32(Self.clampedStopSeedingRatioPercent(stopSeedingRatioPercent))
    }

    package var libtorrentIncomingPort: Int32 {
        Int32(Self.clampedIncomingPort(incomingPort))
    }

    package var libtorrentEncryptionPolicy: Int32 {
        Int32(protocolEncryption.rawValue)
    }

    package var effectiveUsePortForwarding: Bool {
        acceptIncomingConnections && !showOnlyVPNInterfaces ? usePortForwarding : false
    }

    package var effectiveEnableLocalServiceDiscovery: Bool {
        showOnlyVPNInterfaces ? false : enableLocalServiceDiscovery
    }

    package var effectiveUseLocalServiceDiscoveryByDefault: Bool {
        effectiveEnableLocalServiceDiscovery && useLocalServiceDiscoveryByDefault
    }

    package var effectiveUseDHTByDefault: Bool {
        enableDHTNetwork && useDHTByDefault
    }

    package var effectiveUsePeerExchangeByDefault: Bool {
        enablePeerExchangePlugin && usePeerExchangeByDefault
    }

    package var effectiveAnonymousMode: Bool {
        showOnlyVPNInterfaces || anonymousMode
    }

    package var libtorrentRequiredNetworkInterfaceName: String {
        requireNetworkInterface ? requiredNetworkInterfaceName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    package static func load(defaults: UserDefaults = .standard) -> TorrentSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(TorrentSettings.self, from: data) else {
            return TorrentSettings()
        }
        return settings.clamped()
    }

    package func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(clamped()) else {
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    package func clamped() -> TorrentSettings {
        var settings = self
        settings.downloadRateLimitKBps = Self.clampedRateLimitKBps(settings.downloadRateLimitKBps)
        settings.uploadRateLimitKBps = Self.clampedRateLimitKBps(settings.uploadRateLimitKBps)
        settings.maximumActiveDownloads = Self.clampedActiveTorrentCount(settings.maximumActiveDownloads)
        settings.maximumActiveSeeds = Self.clampedActiveTorrentCount(settings.maximumActiveSeeds)
        settings.stopSeedingRatioPercent = Self.clampedStopSeedingRatioPercent(settings.stopSeedingRatioPercent)
        settings.stopSeedingAfterHours = Self.clampedStopSeedingHours(settings.stopSeedingAfterHours)
        settings.incomingPort = Self.clampedIncomingPort(settings.incomingPort)
        if !settings.requireNetworkInterface {
            settings.showOnlyVPNInterfaces = false
        }
        settings.requiredNetworkInterfaceName = String(settings.requiredNetworkInterfaceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        return settings
    }

    private func rateLimitBytesPerSecond(_ kilobytesPerSecond: Int) -> Int32 {
        Int32(Self.clampedRateLimitKBps(kilobytesPerSecond) * 1024)
    }

    private func activeLimit(_ value: Int) -> Int32 {
        let clampedValue = Self.clampedActiveTorrentCount(value)
        return clampedValue == 0 ? -1 : Int32(clampedValue)
    }

    private static func clampedRateLimitKBps(_ value: Int) -> Int {
        min(max(value, 0), maximumRateLimitKBps)
    }

    private static func clampedActiveTorrentCount(_ value: Int) -> Int {
        min(max(value, 0), maximumActiveTorrentCount)
    }

    private static func clampedStopSeedingRatioPercent(_ value: Int) -> Int {
        min(max(value, 1), maximumStopSeedingRatioPercent)
    }

    private static func clampedStopSeedingHours(_ value: Int) -> Int {
        min(max(value, 1), maximumStopSeedingHours)
    }

    private static func clampedIncomingPort(_ value: Int) -> Int {
        guard value > 0 else {
            return 0
        }
        return min(max(value, minimumManualIncomingPort), maximumIncomingPort)
    }
}
