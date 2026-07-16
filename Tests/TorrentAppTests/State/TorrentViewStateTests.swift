import Foundation
import Testing
import TorrentEngineModel
@testable import TorrentApp

@MainActor
@Suite("Torrent view state")
struct TorrentViewStateTests {
    @Test("Filters selectable network interfaces when VPN-only mode is enabled")
    func filtersSelectableNetworkInterfacesWhenVPNOnlyModeIsEnabled() {
        var settings = TorrentSettings()
        settings.requireNetworkInterface = true
        settings.showOnlyVPNInterfaces = true

        let state = TorrentSettingsState(
            settings: settings,
            downloadFolder: nil,
            networkInterfaces: [.ethernet, .vpn]
        )

        #expect(state.selectableNetworkInterfaces == [.vpn])
    }

    @Test("Reports selected VPN interface availability")
    func reportsSelectedVPNInterfaceAvailability() {
        var settings = TorrentSettings()
        settings.requireNetworkInterface = true
        settings.showOnlyVPNInterfaces = true
        settings.requiredNetworkInterfaceName = "utun4"

        let state = TorrentSettingsState(
            settings: settings,
            downloadFolder: nil,
            networkInterfaces: [.ethernet, .vpn]
        )

        #expect(state.requiredNetworkInterfaceAvailable == true)
        #expect(state.networkProtectionStatusText == "Active on Work VPN")
    }

    @Test("Marks selected non-VPN interface inactive in VPN-only mode")
    func marksSelectedNonVPNInterfaceInactiveInVPNOnlyMode() {
        var settings = TorrentSettings()
        settings.requireNetworkInterface = true
        settings.showOnlyVPNInterfaces = true
        settings.requiredNetworkInterfaceName = "en0"

        let state = TorrentSettingsState(
            settings: settings,
            downloadFolder: nil,
            networkInterfaces: [.ethernet, .vpn]
        )

        #expect(state.requiredNetworkInterfaceAvailable == false)
        #expect(state.networkProtectionStatusText == "en0 VPN inactive")
    }

}

private extension NetworkInterfaceOption {
    static let ethernet = NetworkInterfaceOption(
        name: "en0",
        displayName: "Ethernet",
        fingerprint: "ethernet",
        vpnServiceID: nil,
        vpnServiceName: nil,
        isLikelyVPN: false
    )

    static let vpn = NetworkInterfaceOption(
        name: "utun4",
        displayName: "Work VPN",
        fingerprint: "vpn",
        vpnServiceID: "vpn-service",
        vpnServiceName: "Work VPN",
        isLikelyVPN: true
    )
}
