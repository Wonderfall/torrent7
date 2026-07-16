import Foundation
import TorrentEngineModel

package enum TorrentNetworkBindingBlockReason: String, Codable, Error, Sendable {
    case controllerRequested
    case monitorNotReady
    case malformedBinding
    case unexpectedUnboundIdentity
    case missingRequiredInterfaceName
    case interfaceNameMismatch
    case interfaceUnavailable
    case ambiguousInterface
    case interfaceFingerprintMismatch
    case vpnServiceIdentityMismatch
    case activeVPNRequired
    case authorizationReplaced
    case monitorChanged
    case monitorStopped
    case controllerDisconnected

    package var userMessage: String {
        switch self {
        case .controllerRequested:
            return "Network access was blocked by the controller."
        case .monitorNotReady:
            return "Network access remains blocked until the engine service has observed the local interfaces."
        case .malformedBinding:
            return "The requested network binding is malformed."
        case .unexpectedUnboundIdentity:
            return "An unrestricted network request included an unexpected interface identity."
        case .missingRequiredInterfaceName:
            return "A required network interface was not selected."
        case .interfaceNameMismatch:
            return "The selected network interface does not match the settings request."
        case .interfaceUnavailable:
            return "The selected network interface is unavailable."
        case .ambiguousInterface:
            return "The selected network interface could not be identified uniquely."
        case .interfaceFingerprintMismatch:
            return "The selected network interface changed."
        case .vpnServiceIdentityMismatch:
            return "The VPN service associated with the selected interface changed."
        case .activeVPNRequired:
            return "The selected interface is not backed by an active VPN service."
        case .authorizationReplaced:
            return "Network access was blocked while the binding authorization was replaced."
        case .monitorChanged:
            return "Network access was blocked because the engine service observed a network change."
        case .monitorStopped:
            return "Network access was blocked because interface monitoring stopped."
        case .controllerDisconnected:
            return "Network access was blocked because the controller disconnected."
        }
    }
}

package enum TorrentNetworkBindingValidation: Equatable, Sendable {
    case blocked(TorrentNetworkBindingBlockReason)
    case unrestricted
    case constrained
}

/// Validates a controller-provided binding against an independently observed
/// service-side interface snapshot. No controller-provided availability result
/// is trusted as authority to unblock the engine.
package enum TorrentNetworkBindingValidator {
    private static let maximumInterfaceNameBytes = 64
    private static let maximumFingerprintBytes = 16 * 1_024
    private static let maximumVPNServiceIDBytes = 1_024

    package static func validate(
        settings: TorrentSettings,
        binding: TorrentNetworkBinding,
        availableInterfaces: [NetworkInterfaceOption]?
    ) -> TorrentNetworkBindingValidation {
        guard !binding.networkBlocked else {
            return .blocked(.controllerRequested)
        }

        let settings = settings.clamped()
        let expectedInterfaceName = settings.libtorrentRequiredNetworkInterfaceName

        guard isWithinUTF8Bound(binding.interfaceName, maximum: maximumInterfaceNameBytes),
              isWithinUTF8Bound(binding.interfaceFingerprint, maximum: maximumFingerprintBytes),
              binding.vpnServiceID.map({
                  isWithinUTF8Bound($0, maximum: maximumVPNServiceIDBytes)
              }) ?? true else {
            return .blocked(.malformedBinding)
        }

        guard settings.requireNetworkInterface else {
            guard binding.interfaceName.isEmpty,
                  binding.interfaceFingerprint.isEmpty,
                  binding.vpnServiceID == nil else {
                return .blocked(.unexpectedUnboundIdentity)
            }
            return .unrestricted
        }

        guard !expectedInterfaceName.isEmpty else {
            return .blocked(.missingRequiredInterfaceName)
        }
        guard binding.interfaceName == expectedInterfaceName else {
            return .blocked(.interfaceNameMismatch)
        }
        guard !binding.interfaceFingerprint.isEmpty else {
            return .blocked(.malformedBinding)
        }
        guard let availableInterfaces else {
            return .blocked(.monitorNotReady)
        }

        let matches = availableInterfaces.filter { $0.name == expectedInterfaceName }
        guard !matches.isEmpty else {
            return .blocked(.interfaceUnavailable)
        }
        guard matches.count == 1, let interface = matches.first else {
            return .blocked(.ambiguousInterface)
        }
        guard interface.fingerprint == binding.interfaceFingerprint else {
            return .blocked(.interfaceFingerprintMismatch)
        }
        guard interface.vpnServiceID == binding.vpnServiceID else {
            return .blocked(.vpnServiceIdentityMismatch)
        }
        guard !settings.showOnlyVPNInterfaces || interface.vpnServiceID != nil else {
            return .blocked(.activeVPNRequired)
        }

        return .constrained
    }

    private static func isWithinUTF8Bound(_ value: String, maximum: Int) -> Bool {
        value.utf8.count <= maximum
    }
}

/// A generation-bound authorization produced from one service-side interface
/// snapshot. It is deliberately opaque to callers except for equality checks.
package struct TorrentNetworkBindingLease: Equatable, Sendable {
    fileprivate let id: UUID
    fileprivate let monitorGeneration: UInt64

    fileprivate init(monitorGeneration: UInt64) {
        id = UUID()
        self.monitorGeneration = monitorGeneration
    }
}

package enum TorrentNetworkBindingDecision: Equatable, Sendable {
    case blocked(TorrentNetworkBindingBlockReason)
    case unrestricted
    case constrained(TorrentNetworkBindingLease)
}

package struct TorrentNetworkBindingAuthorityState: Equatable, Sendable {
    package let monitorGeneration: UInt64
    package let hasInterfaceSnapshot: Bool
    package let hasPendingLease: Bool
    package let hasActiveLease: Bool
}

/// Owns the engine service's independent network observation and invalidates a
/// constrained authorization on every emitted monitor change. A caller must:
///
/// 1. await `prepare`, which first invokes the fail-closed handler;
/// 2. call `activate` immediately before applying settings that unblock native
///    networking; and
/// 3. call `confirm` immediately afterwards, blocking again if it returns false.
///
/// The invalidation handler must not return until native networking is blocked,
/// or until the engine has been made unavailable if blocking fails.
package actor TorrentNetworkBindingAuthority {
    package typealias InvalidationHandler = @Sendable (
        TorrentNetworkBindingBlockReason
    ) async -> Void

    private let monitor: any NetworkInterfaceMonitoring
    private let invalidationHandler: InvalidationHandler
    private var monitorTask: Task<Void, Never>?
    private var latestInterfaces: [NetworkInterfaceOption]?
    private var monitorGeneration: UInt64 = 0
    private var pendingLease: TorrentNetworkBindingLease?
    private var activeLease: TorrentNetworkBindingLease?
    private var isStopped = false

    package init(
        monitor: any NetworkInterfaceMonitoring = NetworkInterfaceMonitor(),
        invalidationHandler: @escaping InvalidationHandler
    ) {
        self.monitor = monitor
        self.invalidationHandler = invalidationHandler
    }

    package func start() async {
        guard !isStopped, monitorTask == nil else {
            return
        }

        await failClosed(reason: .monitorNotReady)
        guard !isStopped, monitorTask == nil else {
            return
        }
        let updates = monitor.updates()
        monitorTask = Task { [weak self] in
            for await interfaces in updates {
                guard let self else {
                    return
                }
                await self.receive(interfaces: interfaces)
            }

            guard !Task.isCancelled, let self else {
                return
            }
            await self.monitorDidStop()
        }
    }

    /// Always blocks the current authorization before evaluating a replacement.
    package func prepare(
        settings: TorrentSettings,
        binding: TorrentNetworkBinding
    ) async -> TorrentNetworkBindingDecision {
        await failClosed(reason: .authorizationReplaced)

        switch TorrentNetworkBindingValidator.validate(
            settings: settings,
            binding: binding,
            availableInterfaces: latestInterfaces
        ) {
        case .blocked(let reason):
            return .blocked(reason)
        case .unrestricted:
            return .unrestricted
        case .constrained:
            let lease = TorrentNetworkBindingLease(
                monitorGeneration: monitorGeneration
            )
            pendingLease = lease
            return .constrained(lease)
        }
    }

    /// Marks a prepared lease active immediately before the native unblock.
    package func activate(_ lease: TorrentNetworkBindingLease) -> Bool {
        guard pendingLease == lease,
              lease.monitorGeneration == monitorGeneration,
              latestInterfaces != nil else {
            pendingLease = nil
            return false
        }

        pendingLease = nil
        activeLease = lease
        return true
    }

    /// Detects a monitor update racing with the native settings application.
    package func confirm(_ lease: TorrentNetworkBindingLease) -> Bool {
        activeLease == lease && lease.monitorGeneration == monitorGeneration
    }

    package func forceBlock(
        reason: TorrentNetworkBindingBlockReason = .controllerDisconnected
    ) async {
        await failClosed(reason: reason)
    }

    package func stop() async {
        guard !isStopped else {
            return
        }
        isStopped = true
        monitorTask?.cancel()
        monitorTask = nil
        monitor.cancel()
        latestInterfaces = nil
        incrementGeneration()
        await failClosed(reason: .monitorStopped)
    }

    package func state() -> TorrentNetworkBindingAuthorityState {
        TorrentNetworkBindingAuthorityState(
            monitorGeneration: monitorGeneration,
            hasInterfaceSnapshot: latestInterfaces != nil,
            hasPendingLease: pendingLease != nil,
            hasActiveLease: activeLease != nil
        )
    }

    private func receive(interfaces: [NetworkInterfaceOption]) async {
        latestInterfaces = interfaces
        incrementGeneration()
        pendingLease = nil

        guard activeLease != nil else {
            return
        }
        activeLease = nil
        await invalidationHandler(.monitorChanged)
    }

    private func monitorDidStop() async {
        isStopped = true
        monitorTask = nil
        latestInterfaces = nil
        incrementGeneration()
        await failClosed(reason: .monitorStopped)
    }

    private func failClosed(reason: TorrentNetworkBindingBlockReason) async {
        pendingLease = nil
        activeLease = nil
        await invalidationHandler(reason)
    }

    private func incrementGeneration() {
        monitorGeneration &+= 1
    }
}
