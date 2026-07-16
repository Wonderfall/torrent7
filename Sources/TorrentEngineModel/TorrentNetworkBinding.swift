import Foundation

/// The controller's description of the network identity it expects the engine
/// service to use. The service must compare this value with its own independent
/// network observation before it can unblock libtorrent.
package struct TorrentNetworkBinding: Codable, Equatable, Sendable {
    package let interfaceName: String
    package let interfaceFingerprint: String
    package let vpnServiceID: String?
    package let networkBlocked: Bool

    package init(
        interfaceName: String,
        interfaceFingerprint: String,
        vpnServiceID: String?,
        networkBlocked: Bool
    ) {
        self.interfaceName = interfaceName
        self.interfaceFingerprint = interfaceFingerprint
        self.vpnServiceID = vpnServiceID
        self.networkBlocked = networkBlocked
    }

    package static func unbound(networkBlocked: Bool = false) -> Self {
        Self(
            interfaceName: "",
            interfaceFingerprint: "",
            vpnServiceID: nil,
            networkBlocked: networkBlocked
        )
    }
}
