import CryptoKit
import Foundation
import Network
import Darwin
import SystemConfiguration
import TorrentEngineModel

private func interfaceIdentityDigest(
    _ identity: String,
    key: SymmetricKey
) -> String {
    let hexadecimal = Array("0123456789abcdef".utf8)
    let authenticationCode = HMAC<SHA256>.authenticationCode(
        for: Data(identity.utf8),
        using: key
    )
    var encoded = Array("hmac-sha256:".utf8)
    encoded.reserveCapacity(encoded.count + SHA256.byteCount * 2)
    for byte in authenticationCode {
        encoded.append(hexadecimal[Int(byte >> 4)])
        encoded.append(hexadecimal[Int(byte & 0x0f)])
    }
    return String(decoding: encoded, as: UTF8.self)
}

package protocol NetworkInterfaceMonitoring: AnyObject, Sendable {
    func updates() -> AsyncStream<[NetworkInterfaceOption]>
    func cancel()
}

private struct InterfaceSnapshot {
    let name: String
    let index: UInt32
    var flags: UInt32
    var addresses: Set<String>
    var hasIPv4Address: Bool
    var hasIPv6Address: Bool

    func fingerprint(using key: SymmetricKey) -> String {
        let addressList = addresses.sorted().joined(separator: ",")
        return interfaceIdentityDigest(
            "name=\(name);index=\(index);flags=\(flags);ipv4=\(hasIPv4Address);ipv6=\(hasIPv6Address);addresses=\(addressList)",
            key: key
        )
    }
}

private struct VPNService {
    let id: String
    let name: String
}

private struct VPNServiceAssociation {
    let serviceID: String
    let serviceName: String
    let interfaceName: String
}

package final class NetworkInterfaceMonitor: NetworkInterfaceMonitoring, @unchecked Sendable {
    private static let connectedVPNStatus = SCNetworkConnectionStatus(rawValue: 2)

    private let queue = DispatchQueue(label: "torrent7.network-interface-monitor")
    private let queueKey = DispatchSpecificKey<Void>()
    private let fingerprintKey = SymmetricKey(size: .bits256)
    private var monitor: NWPathMonitor?
    private var dynamicStore: SCDynamicStore?
    private var continuation: AsyncStream<[NetworkInterfaceOption]>.Continuation?
    private var streamID: UUID?
    private var isStarted = false
    private var isCancelled = true
    private var lastEmittedOptions: [NetworkInterfaceOption] = []

    package init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        cancel()
    }

    package func updates() -> AsyncStream<[NetworkInterfaceOption]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let streamID = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.cancel(streamID: streamID)
            }

            queue.async { [weak self] in
                self?.startOnQueue(continuation, streamID: streamID)
            }
        }
    }

    package func cancel() {
        cancel(streamID: nil)
    }

    private func cancel(streamID: UUID?) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            cancelOnQueue(streamID: streamID)
        } else {
            queue.sync {
                cancelOnQueue(streamID: streamID)
            }
        }
    }

    private func startOnQueue(
        _ continuation: AsyncStream<[NetworkInterfaceOption]>.Continuation,
        streamID: UUID
    ) {
        let previousContinuation = self.continuation
        self.continuation = continuation
        self.streamID = streamID
        previousContinuation?.finish()

        if isStarted {
            isCancelled = false
            emitCurrentOptionsOnQueue(force: true)
            return
        }

        let monitor = NWPathMonitor()
        self.monitor = monitor
        isStarted = true
        isCancelled = false
        lastEmittedOptions = []

        monitor.pathUpdateHandler = { [weak self] path in
            self?.emitOptionsOnQueue(pathNames: Self.pathNames(from: path))
        }
        monitor.start(queue: queue)
        startDynamicStoreMonitoringOnQueue()
        emitCurrentOptionsOnQueue(force: true)
    }

    private func cancelOnQueue(streamID: UUID? = nil) {
        guard streamID == nil || streamID == self.streamID else {
            return
        }

        let continuation = self.continuation
        self.continuation = nil
        self.streamID = nil
        isCancelled = true
        lastEmittedOptions = []

        if let dynamicStore {
            SCDynamicStoreSetDispatchQueue(dynamicStore, nil)
        }
        dynamicStore = nil

        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        monitor = nil
        isStarted = false
        continuation?.finish()
    }

    private func emitCurrentOptionsOnQueue(force: Bool = false) {
        let pathNames = monitor.map { Self.pathNames(from: $0.currentPath) } ?? []
        emitOptionsOnQueue(pathNames: pathNames, force: force)
    }

    private func emitOptionsOnQueue(pathNames: Set<String>, force: Bool = false) {
        guard !isCancelled else {
            return
        }

        let options = Self.options(pathNames: pathNames, fingerprintKey: fingerprintKey)
        guard force || options != lastEmittedOptions else {
            return
        }

        lastEmittedOptions = options
        guard let continuation, let streamID else {
            return
        }

        if case .terminated = continuation.yield(options) {
            cancelOnQueue(streamID: streamID)
        }
    }

    private func startDynamicStoreMonitoringOnQueue() {
        var context = unsafe SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let store = unsafe SCDynamicStoreCreate(
            nil,
            "TorrentApp.NetworkInterfaceMonitor" as CFString,
            Self.dynamicStoreCallback,
            &context
        ) else {
            return
        }

        let patterns = [
            "State:/Network/Service/.*/IPv4",
            "State:/Network/Service/.*/IPv6",
            "State:/Network/Service/.*/Interface",
            "Setup:/Network/Service/.*/Interface"
        ] as CFArray

        guard SCDynamicStoreSetNotificationKeys(store, nil, patterns),
              SCDynamicStoreSetDispatchQueue(store, queue) else {
            return
        }

        dynamicStore = store
    }

    private static let dynamicStoreCallback: SCDynamicStoreCallBack = { _, _, info in
        guard let info = unsafe info else {
            return
        }

        let monitor = unsafe Unmanaged<NetworkInterfaceMonitor>.fromOpaque(info).takeUnretainedValue()
        monitor.emitCurrentOptionsOnQueue()
    }

    private static func pathNames(from path: NWPath) -> Set<String> {
        Set(path.availableInterfaces.map(\.name))
    }

    private static func options(
        pathNames: Set<String>,
        fingerprintKey: SymmetricKey
    ) -> [NetworkInterfaceOption] {
        let snapshots = interfaceSnapshots()
        let optionNames = snapshots.isEmpty ? pathNames : Set(snapshots.keys)
        let displayNames = displayNamesByInterfaceName()
        let vpnAssociations = activeVPNAssociationsByInterfaceName()

        return optionNames
            .compactMap { name in
                let vpnAssociation = vpnAssociations[name]
                let option = NetworkInterfaceOption(
                    name: name,
                    displayName: optionDisplayName(for: name, using: displayNames, vpnServiceName: vpnAssociation?.serviceName),
                    fingerprint: snapshots[name]?.fingerprint(using: fingerprintKey)
                        ?? fallbackFingerprint(for: name, fingerprintKey: fingerprintKey),
                    vpnServiceID: vpnAssociation?.serviceID,
                    vpnServiceName: vpnAssociation?.serviceName,
                    isLikelyVPN: vpnAssociation != nil || isLikelyVPN(name)
                )
                guard !TorrentNetworkInterfaceSnapshotValidator.isValid(option) else {
                    return option
                }

                // SystemConfiguration strings are display data, not authority.
                // If an association cannot cross IPC safely, omit that
                // association and keep the interface conservatively VPN-like.
                let conservativeOption = NetworkInterfaceOption(
                    name: name,
                    displayName: name,
                    fingerprint: option.fingerprint,
                    vpnServiceID: nil,
                    vpnServiceName: nil,
                    isLikelyVPN: option.isLikelyVPN
                )
                return TorrentNetworkInterfaceSnapshotValidator.isValid(conservativeOption)
                    ? conservativeOption
                    : nil
            }
            .sorted { lhs, rhs in
                if lhs.isLikelyVPN != rhs.isLikelyVPN {
                    return lhs.isLikelyVPN
                }
                if lhs.isVPNBacked != rhs.isVPNBacked {
                    return lhs.isVPNBacked
                }
                let displayNameOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if displayNameOrder != .orderedSame {
                    return displayNameOrder == .orderedAscending
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private static func interfaceSnapshots() -> [String: InterfaceSnapshot] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard unsafe getifaddrs(&interfaces) == 0, let firstInterface = unsafe interfaces else {
            return [:]
        }
        defer {
            unsafe freeifaddrs(interfaces)
        }

        var snapshots = [String: InterfaceSnapshot]()
        var cursor: UnsafeMutablePointer<ifaddrs>? = unsafe firstInterface
        while let currentInterface = unsafe cursor {
            let interface = unsafe currentInterface.pointee
            defer {
                unsafe cursor = interface.ifa_next
            }

            guard let address = unsafe interface.ifa_addr else {
                continue
            }

            let family = unsafe Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else {
                continue
            }

            let flags = unsafe interface.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0,
                  (flags & UInt32(IFF_RUNNING)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0,
                  let name = unsafe interface.ifa_name else {
                continue
            }

            let interfaceName = unsafe String(cString: name)
            var snapshot = snapshots[interfaceName] ?? InterfaceSnapshot(
                name: interfaceName,
                index: interfaceIndex(for: interfaceName),
                flags: flags,
                addresses: [],
                hasIPv4Address: false,
                hasIPv6Address: false
            )
            snapshot.flags |= flags
            if family == AF_INET {
                snapshot.hasIPv4Address = true
            } else if family == AF_INET6 {
                snapshot.hasIPv6Address = true
            }
            if let address = unsafe numericAddress(from: address) {
                snapshot.addresses.insert(address)
            }
            snapshots[interfaceName] = snapshot
        }

        return snapshots
    }

    private static func interfaceIndex(for name: String) -> UInt32 {
        unsafe name.withCString { pointer in
            unsafe if_nametoindex(pointer)
        }
    }

    private static func fallbackFingerprint(
        for name: String,
        fingerprintKey: SymmetricKey
    ) -> String {
        let identity = "name=\(name);index=\(interfaceIndex(for: name));ipv4=false;ipv6=false;addresses="
        return interfaceIdentityDigest(identity, key: fingerprintKey)
    }

    private static func numericAddress(from address: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = unsafe getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else {
            return nil
        }
        let endIndex = host.firstIndex(of: 0) ?? host.endIndex
        let bytes = host[..<endIndex].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func displayNamesByInterfaceName() -> [String: String] {
        var displayNames = [String: String]()
        addSystemInterfaceDisplayNames(to: &displayNames)
        addNetworkServiceDisplayNames(to: &displayNames)
        addNetworkConnectionDisplayNames(to: &displayNames)
        addDynamicStoreServiceDisplayNames(to: &displayNames)
        return displayNames
    }

    private static func addSystemInterfaceDisplayNames(to displayNames: inout [String: String]) {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return
        }

        for interface in interfaces {
            let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?
            let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            addDisplayName(displayName, for: bsdName, to: &displayNames)
        }
    }

    private static func addNetworkServiceDisplayNames(to displayNames: inout [String: String]) {
        guard let preferences = SCPreferencesCreate(nil, "TorrentApp" as CFString, nil),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            return
        }

        for service in services where SCNetworkServiceGetEnabled(service) {
            guard let interface = SCNetworkServiceGetInterface(service) else {
                continue
            }

            let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?
            let serviceName = SCNetworkServiceGetName(service) as String?
            let interfaceName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            addDisplayName(serviceName ?? interfaceName, for: bsdName, to: &displayNames)
        }
    }

    private static func addNetworkConnectionDisplayNames(to displayNames: inout [String: String]) {
        guard let preferences = SCPreferencesCreate(nil, "TorrentApp" as CFString, nil),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            return
        }

        for service in services where SCNetworkServiceGetEnabled(service) {
            guard let serviceID = SCNetworkServiceGetServiceID(service) as String?,
                  let serviceName = cleanName(SCNetworkServiceGetName(service) as String?) else {
                continue
            }

            var context = unsafe SCNetworkConnectionContext(
                version: 0,
                info: nil,
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            guard let connection = unsafe SCNetworkConnectionCreateWithServiceID(
                nil,
                serviceID as CFString,
                nil,
                &context
            ), let status = SCNetworkConnectionCopyExtendedStatus(connection) as? [String: Any] else {
                continue
            }

            interfaceNames(inConnectionStatus: status).forEach {
                addDisplayName(serviceName, for: $0, to: &displayNames)
            }
        }
    }

    private static func addDynamicStoreServiceDisplayNames(to displayNames: inout [String: String]) {
        guard let store = SCDynamicStoreCreate(nil, "TorrentApp" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/Interface" as CFString) as? [String] else {
            return
        }

        for key in keys {
            guard let interfaceState = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let interfaceName = interfaceState["DeviceName"] as? String else {
                continue
            }

            let serviceName = serviceID(fromDynamicStoreKey: key)
                .flatMap { dynamicStoreServiceName(in: store, serviceID: $0) }
            addDisplayName(serviceName, for: interfaceName, to: &displayNames)
        }
    }

    private static func dynamicStoreServiceName(in store: SCDynamicStore, serviceID: String) -> String? {
        let keys = [
            "Setup:/Network/Service/\(serviceID)",
            "State:/Network/Service/\(serviceID)"
        ]

        for key in keys {
            guard let service = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else {
                continue
            }

            if let name = service["UserDefinedName"] as? String, !name.isEmpty {
                return name
            }
            if let name = service["Name"] as? String, !name.isEmpty {
                return name
            }
        }

        return nil
    }

    private static func serviceID(fromDynamicStoreKey key: String) -> String? {
        let components = key.split(separator: "/").map(String.init)
        guard let serviceIndex = components.firstIndex(of: "Service"),
              serviceIndex + 1 < components.count else {
            return nil
        }
        return components[serviceIndex + 1]
    }

    private static func interfaceNames(inConnectionStatus status: [String: Any]) -> [String] {
        var names = Set<String>()

        for key in ["InterfaceName", "ConfirmedInterfaceName"] {
            if let name = status[key] as? String {
                names.insert(name)
            }
        }

        for protocolKey in ["IPv4", "IPv6"] {
            guard let protocolStatus = status[protocolKey] as? [String: Any] else {
                continue
            }

            for key in ["InterfaceName", "ConfirmedInterfaceName"] {
                if let name = protocolStatus[key] as? String {
                    names.insert(name)
                }
            }
        }

        return Array(names)
    }

    private static func activeVPNAssociationsByInterfaceName() -> [String: VPNServiceAssociation] {
        let services = configuredVPNServices()
        guard !services.isEmpty,
              let store = SCDynamicStoreCreate(nil, "TorrentApp.VPNServiceState" as CFString, nil, nil) else {
            return [:]
        }

        var associations = [String: VPNServiceAssociation]()
        for service in services {
            guard let connection = connectedVPNConnection(for: service.id) else {
                continue
            }

            var interfaceNames = activeInterfaceNames(forConnectedVPNConnection: connection)
            if interfaceNames.isEmpty {
                interfaceNames = activeInterfaceNames(for: service.id, in: store)
            }

            for interfaceName in interfaceNames.sorted() where associations[interfaceName] == nil {
                associations[interfaceName] = VPNServiceAssociation(
                    serviceID: service.id,
                    serviceName: service.name,
                    interfaceName: interfaceName
                )
            }
        }
        return associations
    }

    private static func configuredVPNServices() -> [VPNService] {
        guard let preferences = SCPreferencesCreate(nil, "TorrentApp" as CFString, nil),
              let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            return []
        }

        return services.compactMap { service in
            guard SCNetworkServiceGetEnabled(service),
                  let serviceID = SCNetworkServiceGetServiceID(service) as String?,
                  let interface = SCNetworkServiceGetInterface(service),
                  let interfaceType = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  interfaceType == "VPN" else {
                return nil
            }

            let serviceName = cleanName(SCNetworkServiceGetName(service) as String?) ?? "VPN"
            return VPNService(id: serviceID, name: serviceName)
        }
    }

    private static func connectedVPNConnection(for serviceID: String) -> SCNetworkConnection? {
        var context = unsafe SCNetworkConnectionContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let connection = unsafe SCNetworkConnectionCreateWithServiceID(
            nil,
            serviceID as CFString,
            nil,
            &context
        ), SCNetworkConnectionGetStatus(connection) == connectedVPNStatus else {
            return nil
        }

        return connection
    }

    private static func activeInterfaceNames(forConnectedVPNConnection connection: SCNetworkConnection) -> Set<String> {
        guard let status = SCNetworkConnectionCopyExtendedStatus(connection) as? [String: Any] else {
            return []
        }

        var names = Set(interfaceNames(inNetworkState: status))
        interfaceNames(inConnectionStatus: status).forEach {
            names.insert($0)
        }

        return names
    }

    private static func activeInterfaceNames(for serviceID: String, in store: SCDynamicStore) -> Set<String> {
        let keys = [
            "State:/Network/Service/\(serviceID)/IPv4",
            "State:/Network/Service/\(serviceID)/IPv6",
            "State:/Network/Service/\(serviceID)/Interface"
        ]

        var names = Set<String>()
        for key in keys {
            guard let state = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else {
                continue
            }

            interfaceNames(inNetworkState: state).forEach {
                names.insert($0)
            }
        }

        return names
    }

    private static func interfaceNames(inNetworkState state: [String: Any]) -> [String] {
        var names = Set<String>()
        for key in ["InterfaceName", "ConfirmedInterfaceName", "DeviceName"] {
            if let name = cleanName(state[key] as? String) {
                names.insert(name)
            }
        }
        return Array(names)
    }

    private static func addDisplayName(_ displayName: String?, for interfaceName: String?, to displayNames: inout [String: String]) {
        guard let interfaceName = cleanName(interfaceName),
              let displayName = cleanName(displayName),
              displayName.localizedCaseInsensitiveCompare(interfaceName) != .orderedSame else {
            return
        }

        displayNames[interfaceName] = displayName
    }

    private static func optionDisplayName(
        for interfaceName: String,
        using displayNames: [String: String],
        vpnServiceName: String?
    ) -> String {
        let displayName = vpnServiceName ?? displayNames[interfaceName]
        guard let displayName, !displayName.isEmpty else {
            return interfaceName
        }

        if displayName.localizedCaseInsensitiveContains(interfaceName) {
            return displayName
        }

        return "\(displayName) (\(interfaceName))"
    }

    private static func cleanName(_ name: String?) -> String? {
        let cleanedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleanedName.isEmpty ? nil : cleanedName
    }

    private static func isLikelyVPN(_ name: String) -> Bool {
        let lowercasedName = name.lowercased()
        return lowercasedName.hasPrefix("utun")
            || lowercasedName.hasPrefix("tun")
            || lowercasedName.hasPrefix("tap")
            || lowercasedName.hasPrefix("ppp")
            || lowercasedName.hasPrefix("ipsec")
    }
}
