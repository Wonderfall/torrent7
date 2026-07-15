import Foundation

enum TorrentSettingsTab: Hashable, Sendable {
    case general
    case interface
    case transfers
    case network
    case discovery
}


enum TorrentProtocolEncryption: Int, Codable, CaseIterable, Identifiable, Sendable {
    case allowed = 0
    case required = 1
    case disabled = 2

    var id: Int {
        rawValue
    }

    var title: String {
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

struct TorrentSettings: Codable, Equatable, Sendable {
    private static let defaultsKey = "TorrentSettings"
    private static let maximumRateLimitKBps = 1_000_000
    private static let maximumActiveTorrentCount = 1_000
    private static let maximumStopSeedingRatioPercent = 10_000
    private static let maximumStopSeedingHours = 100_000
    static let minimumManualIncomingPort = 1024
    static let maximumIncomingPort = 65_535

    var downloadRateLimitKBps = 0
    var uploadRateLimitKBps = 0
    var maximumActiveDownloads = 3
    var maximumActiveSeeds = 5
    var stopSeedingRatioPercent = 200
    var stopSeedingAfterHours = 24
    var incomingPort = 0
    var acceptIncomingConnections = true
    var usePortForwarding = false
    var enableDHTNetwork = true
    var useDHTByDefault = true
    var enablePeerExchangePlugin = true
    var usePeerExchangeByDefault = true
    var useHTTPSTrackersOnly = false
    var useHTTPSWebSeedsOnly = false
    var enableLocalServiceDiscovery = false
    var useLocalServiceDiscoveryByDefault = false
    var protocolEncryption = TorrentProtocolEncryption.allowed
    var anonymousMode = true
    var requireNetworkInterface = false
    var showOnlyVPNInterfaces = false
    var requiredNetworkInterfaceName = ""
    var completionNotificationsEnabled = true
    var completionNotificationSoundEnabled = true
    var completionNotificationNamesEnabled = false
    var dockTransferRatesEnabled = true
    var preventSleepDuringTransfers = false

    init() {}

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

    init(from decoder: Decoder) throws {
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

    var libtorrentDownloadRateLimit: Int32 {
        rateLimitBytesPerSecond(downloadRateLimitKBps)
    }

    var libtorrentUploadRateLimit: Int32 {
        rateLimitBytesPerSecond(uploadRateLimitKBps)
    }

    var libtorrentActiveDownloads: Int32 {
        activeLimit(maximumActiveDownloads)
    }

    var libtorrentActiveSeeds: Int32 {
        activeLimit(maximumActiveSeeds)
    }

    var libtorrentActiveLimit: Int32 {
        let activeDownloads = Self.clampedActiveTorrentCount(maximumActiveDownloads)
        let activeSeeds = Self.clampedActiveTorrentCount(maximumActiveSeeds)
        if activeDownloads == 0 || activeSeeds == 0 {
            return Int32.max
        }
        return Int32(activeDownloads + activeSeeds)
    }

    var libtorrentSeedTimeLimit: Int32 {
        Int32(Self.clampedStopSeedingHours(stopSeedingAfterHours) * 60 * 60)
    }

    var libtorrentShareRatioLimit: Int32 {
        Int32(Self.clampedStopSeedingRatioPercent(stopSeedingRatioPercent))
    }

    var libtorrentIncomingPort: Int32 {
        Int32(Self.clampedIncomingPort(incomingPort))
    }

    var libtorrentEncryptionPolicy: Int32 {
        Int32(protocolEncryption.rawValue)
    }

    var effectiveUsePortForwarding: Bool {
        acceptIncomingConnections && !showOnlyVPNInterfaces ? usePortForwarding : false
    }

    var effectiveEnableLocalServiceDiscovery: Bool {
        showOnlyVPNInterfaces ? false : enableLocalServiceDiscovery
    }

    var effectiveUseLocalServiceDiscoveryByDefault: Bool {
        effectiveEnableLocalServiceDiscovery && useLocalServiceDiscoveryByDefault
    }

    var effectiveUseDHTByDefault: Bool {
        enableDHTNetwork && useDHTByDefault
    }

    var effectiveUsePeerExchangeByDefault: Bool {
        enablePeerExchangePlugin && usePeerExchangeByDefault
    }

    var effectiveAnonymousMode: Bool {
        showOnlyVPNInterfaces || anonymousMode
    }

    var libtorrentRequiredNetworkInterfaceName: String {
        requireNetworkInterface ? requiredNetworkInterfaceName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    static func load(defaults: UserDefaults = .standard) -> TorrentSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(TorrentSettings.self, from: data) else {
            return TorrentSettings()
        }
        return settings.clamped()
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(clamped()) else {
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func clamped() -> TorrentSettings {
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
