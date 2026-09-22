package import Foundation

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

package enum TorrentHTTPSTrackerPolicy: Int, Codable, CaseIterable, Identifiable, Sendable {
    case original = 1
    case prefer = 2
    case require = 3

    package var id: Self { self }

    package var title: String {
        switch self {
        case .original:
            "Original"
        case .prefer:
            "Prefer HTTPS"
        case .require:
            "Require HTTPS"
        }
    }
}

package enum TorrentHTTPSWebSeedPolicy: Int, Codable, CaseIterable, Identifiable, Sendable {
    case original = 1
    case require = 3

    package var id: Self { self }

    package var title: String {
        switch self {
        case .original:
            "Original"
        case .require:
            "Require HTTPS"
        }
    }
}

package enum TorrentDHTDiscoveryPolicy: Int, Codable, CaseIterable, Identifiable, Sendable {
    case alongsideTrackers = 0
    case afterAllTrackersFail = 1

    package var id: Self { self }

    package var title: String {
        switch self {
        case .alongsideTrackers:
            "Alongside trackers"
        case .afterAllTrackersFail:
            "After all trackers fail"
        }
    }
}

package enum TorrentSettingsLoadError: Error, Equatable {
    case invalidStoredSettings
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
    package var acceptIncomingConnections = false
    package var usePortForwarding = false
    package var enableDHTNetwork = true
    package var useDHTByDefault = true
    package var dhtDiscoveryPolicy = TorrentDHTDiscoveryPolicy.alongsideTrackers
    package var dhtPrivacyLookups = true
    package var reduceDHTContribution = false
    package var enablePeerExchangePlugin = false
    package var usePeerExchangeByDefault = false
    package var httpsTrackerPolicy = TorrentHTTPSTrackerPolicy.prefer
    package var httpsWebSeedPolicy = TorrentHTTPSWebSeedPolicy.require
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

    package var libtorrentRequiredNetworkInterfaceName: String {
        requireNetworkInterface ? requiredNetworkInterfaceName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// Only an absent record means first launch. Existing records must be complete
    /// and canonical; filling missing fields or clamping corruption can relax policy.
    package static func load(
        defaults: UserDefaults = .standard
    ) throws(TorrentSettingsLoadError) -> TorrentSettings {
        guard let storedValue = defaults.object(forKey: defaultsKey) else {
            return TorrentSettings()
        }
        guard let data = storedValue as? Data else {
            throw .invalidStoredSettings
        }
        do {
            let settings = try JSONDecoder().decode(TorrentSettings.self, from: data)
            guard settings == settings.clamped() else {
                throw TorrentSettingsLoadError.invalidStoredSettings
            }
            return settings
        } catch {
            throw .invalidStoredSettings
        }
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
