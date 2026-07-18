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

        guard (binding.interfaceName.isEmpty
                || TorrentNetworkInterfaceSnapshotValidator.isValidInterfaceName(
                    binding.interfaceName
                )),
              isWithinUTF8Bound(
                binding.interfaceFingerprint,
                maximum: TorrentEngineLimits.maximumNetworkInterfaceFingerprintBytes
              ),
              binding.vpnServiceID.map({
                  !$0.isEmpty
                      && !$0.contains("\0")
                      && isWithinUTF8Bound(
                          $0,
                          maximum: TorrentEngineLimits.maximumVPNServiceIDBytes
                      )
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
    package typealias ObservationHandler = @Sendable () async -> Void

    private let monitor: any NetworkInterfaceMonitoring
    private let invalidationHandler: InvalidationHandler
    private let observationHandler: ObservationHandler
    private let monitorReadinessTimeout: Duration
    private var monitorTask: Task<Void, Never>?
    private var monitorReadinessTimeoutTask: Task<Void, Never>?
    private var latestInterfaces: [NetworkInterfaceOption]?
    private var monitorReadinessWaiters = [CheckedContinuation<Void, Never>]()
    private var monitorGeneration: UInt64 = 0
    private var pendingLease: TorrentNetworkBindingLease?
    private var activeLease: TorrentNetworkBindingLease?
    private var isStopped = false

    package init(
        monitor: any NetworkInterfaceMonitoring = NetworkInterfaceMonitor(),
        invalidationHandler: @escaping InvalidationHandler,
        observationHandler: @escaping ObservationHandler = {},
        monitorReadinessTimeout: Duration = .seconds(5)
    ) {
        precondition(monitorReadinessTimeout > .zero)
        self.monitor = monitor
        self.invalidationHandler = invalidationHandler
        self.observationHandler = observationHandler
        self.monitorReadinessTimeout = monitorReadinessTimeout
    }

    /// Starts monitoring and does not report readiness until the first complete
    /// service-side interface snapshot has been installed.
    @discardableResult
    package func start() async -> Bool {
        guard !isStopped else {
            return false
        }

        if monitorTask == nil {
            await failClosed(reason: .monitorNotReady)
            guard !isStopped else {
                return false
            }
            if monitorTask == nil {
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
                monitorReadinessTimeoutTask = Task { [weak self, monitorReadinessTimeout] in
                    do {
                        try await Task.sleep(for: monitorReadinessTimeout)
                    } catch {
                        return
                    }
                    await self?.monitorReadinessDidTimeOut()
                }
            }
        }

        if latestInterfaces == nil, !isStopped {
            await withCheckedContinuation { continuation in
                if latestInterfaces != nil || isStopped {
                    continuation.resume()
                } else {
                    monitorReadinessWaiters.append(continuation)
                }
            }
        }
        return latestInterfaces != nil && !isStopped
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
        monitorReadinessTimeoutTask?.cancel()
        monitorReadinessTimeoutTask = nil
        monitor.cancel()
        latestInterfaces = nil
        incrementGeneration()
        resumeMonitorReadinessWaiters()
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

    package func interfaceSnapshot() -> TorrentNetworkInterfaceSnapshot? {
        guard let latestInterfaces else {
            return nil
        }
        let representableInterfaces = latestInterfaces.lazy
            .filter(TorrentNetworkInterfaceSnapshotValidator.isValid)
            .prefix(TorrentEngineLimits.maximumNetworkInterfaceCount)
        return TorrentNetworkInterfaceSnapshot(
            revision: monitorGeneration,
            interfaces: Array(representableInterfaces)
        )
    }

    private func receive(interfaces: [NetworkInterfaceOption]) async {
        let hadInterfaceSnapshot = latestInterfaces != nil
        latestInterfaces = interfaces
        incrementGeneration()
        pendingLease = nil
        monitorReadinessTimeoutTask?.cancel()
        monitorReadinessTimeoutTask = nil
        resumeMonitorReadinessWaiters()

        if activeLease != nil {
            activeLease = nil
            await invalidationHandler(.monitorChanged)
        }
        if hadInterfaceSnapshot {
            await observationHandler()
        }
    }

    private func monitorDidStop() async {
        isStopped = true
        monitorTask = nil
        monitorReadinessTimeoutTask?.cancel()
        monitorReadinessTimeoutTask = nil
        latestInterfaces = nil
        incrementGeneration()
        resumeMonitorReadinessWaiters()
        await failClosed(reason: .monitorStopped)
    }

    private func monitorReadinessDidTimeOut() async {
        guard latestInterfaces == nil, !isStopped else {
            return
        }
        isStopped = true
        monitorTask?.cancel()
        monitorTask = nil
        monitorReadinessTimeoutTask = nil
        monitor.cancel()
        incrementGeneration()
        resumeMonitorReadinessWaiters()
        await failClosed(reason: .monitorNotReady)
    }

    private func failClosed(reason: TorrentNetworkBindingBlockReason) async {
        pendingLease = nil
        activeLease = nil
        await invalidationHandler(reason)
    }

    private func incrementGeneration() {
        precondition(monitorGeneration != UInt64.max)
        monitorGeneration += 1
    }

    private func resumeMonitorReadinessWaiters() {
        let waiters = monitorReadinessWaiters
        monitorReadinessWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
