import Foundation
import Testing
@testable import TorrentApp

@Suite("Torrent settings")
struct TorrentSettingsTests {
    @Test("Clamps invalid limits")
    func clampsInvalidLimits() {
        var settings = TorrentSettings()
        settings.downloadRateLimitKBps = -1
        settings.uploadRateLimitKBps = 1_000_001
        settings.maximumActiveDownloads = -3
        settings.maximumActiveSeeds = 2_000
        settings.stopSeedingRatioPercent = 0
        settings.stopSeedingAfterHours = 0
        settings.incomingPort = 70_000
        settings.requiredNetworkInterfaceName = "  \(String(repeating: "x", count: 80))  "
        settings.showOnlyVPNInterfaces = true

        let clamped = settings.clamped()

        #expect(clamped.downloadRateLimitKBps == 0)
        #expect(clamped.uploadRateLimitKBps == 1_000_000)
        #expect(clamped.maximumActiveDownloads == 0)
        #expect(clamped.maximumActiveSeeds == 1_000)
        #expect(clamped.stopSeedingRatioPercent == 1)
        #expect(clamped.stopSeedingAfterHours == 1)
        #expect(clamped.incomingPort == 65_535)
        #expect(clamped.requiredNetworkInterfaceName.count == 64)
        #expect(clamped.showOnlyVPNInterfaces == false)
    }

    @Test("Clamps manual incoming ports to unreserved range")
    func clampsManualIncomingPortsToUnreservedRange() {
        var automatic = TorrentSettings()
        automatic.incomingPort = 0
        #expect(automatic.clamped().incomingPort == 0)

        var lowManual = TorrentSettings()
        lowManual.incomingPort = 1023
        #expect(lowManual.clamped().incomingPort == TorrentSettings.minimumManualIncomingPort)
    }

    @Test("VPN-only network policy remembers local exposure preferences")
    func vpnOnlyNetworkPolicyRemembersLocalExposurePreferences() {
        var settings = TorrentSettings()
        settings.requireNetworkInterface = true
        settings.showOnlyVPNInterfaces = true
        settings.usePortForwarding = true
        settings.enableLocalServiceDiscovery = true
        settings.useLocalServiceDiscoveryByDefault = true
        settings.anonymousMode = false
        settings.requiredNetworkInterfaceName = "  utun4\n"

        let clamped = settings.clamped()

        #expect(clamped.usePortForwarding == true)
        #expect(clamped.enableLocalServiceDiscovery == true)
        #expect(clamped.anonymousMode == false)
        #expect(clamped.effectiveUsePortForwarding == false)
        #expect(clamped.effectiveEnableLocalServiceDiscovery == false)
        #expect(clamped.effectiveUseLocalServiceDiscoveryByDefault == false)
        #expect(clamped.effectiveAnonymousMode == true)
        #expect(clamped.libtorrentRequiredNetworkInterfaceName == "utun4")
    }

    @Test("Anonymous mode is enabled by default")
    func anonymousModeIsEnabledByDefault() {
        let settings = TorrentSettings()

        #expect(settings.anonymousMode == true)
        #expect(settings.effectiveAnonymousMode == true)
    }

    @Test("Removing downloaded data does not use Trash by default")
    func removingDownloadedDataDoesNotUseTrashByDefault() {
        let settings = TorrentSettings()

        #expect(settings.moveRemovedDataToTrash == false)
    }

    @Test("Local Service Discovery is fully off by default")
    func localServiceDiscoveryIsFullyOffByDefault() {
        let settings = TorrentSettings()

        #expect(settings.enableLocalServiceDiscovery == false)
        #expect(settings.useLocalServiceDiscoveryByDefault == false)
        #expect(settings.effectiveEnableLocalServiceDiscovery == false)
        #expect(settings.effectiveUseLocalServiceDiscoveryByDefault == false)
    }

    @Test("Completion notifications hide torrent names by default")
    func completionNotificationsHideTorrentNamesByDefault() {
        let settings = TorrentSettings()

        #expect(settings.completionNotificationNamesEnabled == false)
    }

    @Test("Disabled incoming connections remember port forwarding preference")
    func disabledIncomingConnectionsRememberPortForwardingPreference() {
        var settings = TorrentSettings()
        settings.acceptIncomingConnections = false
        settings.usePortForwarding = true

        let clamped = settings.clamped()

        #expect(clamped.acceptIncomingConnections == false)
        #expect(clamped.usePortForwarding == true)
        #expect(clamped.effectiveUsePortForwarding == false)
    }

    @Test("Discovery defaults are disabled when master service is disabled")
    func discoveryDefaultsAreDisabledWhenMasterServiceIsDisabled() {
        var settings = TorrentSettings()
        settings.enableDHTNetwork = false
        settings.useDHTByDefault = true
        settings.enablePeerExchangePlugin = false
        settings.usePeerExchangeByDefault = true
        settings.enableLocalServiceDiscovery = false
        settings.useLocalServiceDiscoveryByDefault = true

        #expect(settings.effectiveUseDHTByDefault == false)
        #expect(settings.effectiveUsePeerExchangeByDefault == false)
        #expect(settings.effectiveUseLocalServiceDiscoveryByDefault == false)
    }

    @Test("Zero active limits map to libtorrent unlimited values")
    func zeroActiveLimitsMapToLibtorrentUnlimitedValues() {
        var settings = TorrentSettings()
        settings.maximumActiveDownloads = 0
        settings.maximumActiveSeeds = 0

        #expect(settings.libtorrentActiveDownloads == -1)
        #expect(settings.libtorrentActiveSeeds == -1)
        #expect(settings.libtorrentActiveLimit == Int32.max)
    }

    @Test("Settings map to libtorrent primitive values")
    func settingsMapToLibtorrentPrimitiveValues() {
        var settings = TorrentSettings()
        settings.downloadRateLimitKBps = 12
        settings.uploadRateLimitKBps = 34
        settings.maximumActiveDownloads = 2
        settings.maximumActiveSeeds = 3
        settings.stopSeedingRatioPercent = 150
        settings.stopSeedingAfterHours = 2
        settings.incomingPort = 51_413
        settings.protocolEncryption = .disabled
        settings.enablePeerExchangePlugin = false
        settings.usePeerExchangeByDefault = false
        settings.enableLocalServiceDiscovery = true
        settings.useLocalServiceDiscoveryByDefault = true
        settings.useHTTPSTrackersOnly = true
        settings.useHTTPSWebSeedsOnly = true
        settings.anonymousMode = false

        #expect(settings.libtorrentDownloadRateLimit == 12 * 1_024)
        #expect(settings.libtorrentUploadRateLimit == 34 * 1_024)
        #expect(settings.libtorrentActiveDownloads == 2)
        #expect(settings.libtorrentActiveSeeds == 3)
        #expect(settings.libtorrentActiveLimit == 5)
        #expect(settings.libtorrentShareRatioLimit == 150)
        #expect(settings.libtorrentSeedTimeLimit == 2 * 60 * 60)
        #expect(settings.libtorrentIncomingPort == 51_413)
        #expect(settings.libtorrentEncryptionPolicy == Int32(TorrentProtocolEncryption.disabled.rawValue))
        #expect(settings.enablePeerExchangePlugin == false)
        #expect(settings.usePeerExchangeByDefault == false)
        #expect(settings.effectiveUseDHTByDefault == true)
        #expect(settings.effectiveUsePeerExchangeByDefault == false)
        #expect(settings.effectiveEnableLocalServiceDiscovery == true)
        #expect(settings.effectiveUseLocalServiceDiscoveryByDefault == true)
        #expect(settings.useHTTPSTrackersOnly == true)
        #expect(settings.useHTTPSWebSeedsOnly == true)
        #expect(settings.anonymousMode == false)
        #expect(settings.effectiveAnonymousMode == false)

        settings.usePeerExchangeByDefault = true
        #expect(settings.effectiveUsePeerExchangeByDefault == false)
    }

    @Test("Anonymous mode uses its explicit persisted name")
    func anonymousModeUsesExplicitPersistedName() throws {
        var settings = TorrentSettings()
        settings.anonymousMode = false

        let data = try JSONEncoder().encode(settings)
        let encoded = String(decoding: data, as: UTF8.self)

        #expect(encoded.contains("\"anonymousMode\":false"))
        #expect(!encoded.contains("privacyMode"))

        let decoded = try JSONDecoder().decode(TorrentSettings.self, from: data)
        #expect(decoded.anonymousMode == false)
    }

    @Test("Disabled network-interface requirement clears libtorrent interface")
    func disabledNetworkInterfaceRequirementClearsLibtorrentInterface() {
        var settings = TorrentSettings()
        settings.requireNetworkInterface = false
        settings.requiredNetworkInterfaceName = "utun4"

        #expect(settings.libtorrentRequiredNetworkInterfaceName == "")
    }

    @Test("Decoding clamps persisted invalid values")
    func decodingClampsPersistedInvalidValues() throws {
        let data = Data("""
        {
          "downloadRateLimitKBps": -1,
          "incomingPort": 70000,
          "requiredNetworkInterfaceName": "  utun4  "
        }
        """.utf8)

        let settings = try JSONDecoder().decode(TorrentSettings.self, from: data)

        #expect(settings.downloadRateLimitKBps == 0)
        #expect(settings.incomingPort == 65_535)
        #expect(settings.requiredNetworkInterfaceName == "utun4")
    }

    @Test("Persists clamped settings in an isolated defaults suite")
    func persistsClampedSettingsInIsolatedDefaultsSuite() throws {
        try withIsolatedDefaults { defaults in
            var settings = TorrentSettings()
            settings.incomingPort = 70_000
            settings.protocolEncryption = .required

            settings.save(defaults: defaults)
            let loadedSettings = TorrentSettings.load(defaults: defaults)

            #expect(loadedSettings.incomingPort == 65_535)
            #expect(loadedSettings.protocolEncryption == .required)
        }
    }
}
