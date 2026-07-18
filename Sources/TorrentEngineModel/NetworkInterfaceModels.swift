import Foundation

/// A displayable interface identity observed inside the network-entitled
/// engine service. The GUI may use this value to construct a binding request,
/// but the service always validates that request against its current snapshot.
package struct NetworkInterfaceOption: Codable, Hashable, Identifiable, Sendable {
    package let name: String
    package let displayName: String
    package let fingerprint: String
    package let vpnServiceID: String?
    package let vpnServiceName: String?
    package let isLikelyVPN: Bool

    package init(
        name: String,
        displayName: String,
        fingerprint: String,
        vpnServiceID: String?,
        vpnServiceName: String?,
        isLikelyVPN: Bool
    ) {
        self.name = name
        self.displayName = displayName
        self.fingerprint = fingerprint
        self.vpnServiceID = vpnServiceID
        self.vpnServiceName = vpnServiceName
        self.isLikelyVPN = isLikelyVPN
    }

    package var id: String {
        name
    }

    package var isVPNBacked: Bool {
        vpnServiceID != nil
    }
}

/// A generation-bound snapshot from the service-side interface monitor.
package struct TorrentNetworkInterfaceSnapshot: Codable, Equatable, Sendable {
    package let revision: UInt64
    package let interfaces: [NetworkInterfaceOption]

    package init(revision: UInt64, interfaces: [NetworkInterfaceOption]) {
        self.revision = revision
        self.interfaces = interfaces
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case interfaces
    }

    package init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let revision = try values.decode(UInt64.self, forKey: .revision)
        let interfaces = try values.decode([NetworkInterfaceOption].self, forKey: .interfaces)
        guard interfaces.count <= TorrentEngineLimits.maximumNetworkInterfaceCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .interfaces,
                in: values,
                debugDescription: "The network interface snapshot exceeds its item limit."
            )
        }
        self.revision = revision
        self.interfaces = interfaces
    }
}

/// Shared semantic checks for values that cross the engine trust boundary.
package enum TorrentNetworkInterfaceSnapshotValidator {
    package static func isValid(_ snapshot: TorrentNetworkInterfaceSnapshot) -> Bool {
        snapshot.revision > 0
            && snapshot.interfaces.count <= TorrentEngineLimits.maximumNetworkInterfaceCount
            && Set(snapshot.interfaces.map(\.name)).count == snapshot.interfaces.count
            && snapshot.interfaces.allSatisfy(isValid)
    }

    package static func isValid(_ interface: NetworkInterfaceOption) -> Bool {
        isValidInterfaceName(interface.name)
            && isBoundedText(
                interface.displayName,
                maximumBytes: TorrentEngineLimits.maximumNetworkInterfaceDisplayNameBytes
            )
            && isBoundedText(
                interface.fingerprint,
                maximumBytes: TorrentEngineLimits.maximumNetworkInterfaceFingerprintBytes
            )
            && isValidVPNIdentity(interface)
    }

    package static func isValidInterfaceName(_ name: String) -> Bool {
        !name.isEmpty
            && name.utf8.count <= TorrentEngineLimits.maximumNetworkInterfaceNameBytes
            && name.utf8.allSatisfy { byte in
                (byte >= Character("a").asciiValue! && byte <= Character("z").asciiValue!)
                    || (byte >= Character("A").asciiValue! && byte <= Character("Z").asciiValue!)
                    || (byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!)
                    || byte == Character("_").asciiValue!
                    || byte == Character("-").asciiValue!
                    || byte == Character(".").asciiValue!
            }
    }

    private static func isValidVPNIdentity(_ interface: NetworkInterfaceOption) -> Bool {
        switch (interface.vpnServiceID, interface.vpnServiceName) {
        case (nil, nil):
            return true
        case (.some(let serviceID), .some(let serviceName)):
            return interface.isLikelyVPN
                && isBoundedText(
                    serviceID,
                    maximumBytes: TorrentEngineLimits.maximumVPNServiceIDBytes
                )
                && isBoundedText(
                    serviceName,
                    maximumBytes: TorrentEngineLimits.maximumVPNServiceNameBytes
                )
        case (.some, nil), (nil, .some):
            return false
        }
    }

    private static func isBoundedText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && !value.contains("\0")
    }
}
