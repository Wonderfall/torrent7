import Foundation
import Synchronization
import Testing
@testable import TorrentEngineModel
@testable import TorrentNetworkSecurity

@Suite("Service-authoritative network binding")
struct TorrentNetworkBindingAuthorityTests {
    @Test("Binding is a stable Codable IPC value")
    func bindingCodableRoundTrip() throws {
        let binding = TorrentNetworkBinding(
            interfaceName: "utun7",
            interfaceFingerprint: "fingerprint",
            vpnServiceID: "vpn-service",
            networkBlocked: false
        )

        let encoded = try PropertyListEncoder().encode(binding)
        let decoded = try PropertyListDecoder().decode(
            TorrentNetworkBinding.self,
            from: encoded
        )

        #expect(decoded == binding)
    }

    @Test("Exact independently observed interface identity is required")
    func exactIdentityValidation() {
        let settings = boundSettings(interfaceName: "utun7", vpnOnly: false)
        let interface = networkInterface(
            name: "utun7",
            fingerprint: "fingerprint-1",
            vpnServiceID: "vpn-service-1"
        )
        let binding = TorrentNetworkBinding(
            interfaceName: interface.name,
            interfaceFingerprint: interface.fingerprint,
            vpnServiceID: interface.vpnServiceID,
            networkBlocked: false
        )

        #expect(TorrentNetworkBindingValidator.validate(
            settings: settings,
            binding: binding,
            availableInterfaces: [interface]
        ) == .constrained)
        #expect(TorrentNetworkBindingValidator.validate(
            settings: settings,
            binding: changed(binding, interfaceName: "utun8"),
            availableInterfaces: [interface]
        ) == .blocked(.interfaceNameMismatch))
        #expect(TorrentNetworkBindingValidator.validate(
            settings: settings,
            binding: changed(binding, fingerprint: "fingerprint-2"),
            availableInterfaces: [interface]
        ) == .blocked(.interfaceFingerprintMismatch))
        #expect(TorrentNetworkBindingValidator.validate(
            settings: settings,
            binding: changed(binding, vpnServiceID: "vpn-service-2"),
            availableInterfaces: [interface]
        ) == .blocked(.vpnServiceIdentityMismatch))
        #expect(TorrentNetworkBindingValidator.validate(
            settings: settings,
            binding: binding,
            availableInterfaces: nil
        ) == .blocked(.monitorNotReady))
    }

    @Test("Unavailable and ambiguous interface names fail closed")
    func unavailableAndAmbiguousInterfaces() {
        let settings = boundSettings(interfaceName: "en7", vpnOnly: false)
        let interface = networkInterface(
            name: "en7",
            fingerprint: "fingerprint",
            vpnServiceID: nil
        )
        let binding = TorrentNetworkBinding(
            interfaceName: interface.name,
            interfaceFingerprint: interface.fingerprint,
            vpnServiceID: nil,
            networkBlocked: false
        )

        #expect(TorrentNetworkBindingValidator.validate(
            settings: settings,
            binding: binding,
            availableInterfaces: []
        ) == .blocked(.interfaceUnavailable))
        #expect(TorrentNetworkBindingValidator.validate(
            settings: settings,
            binding: binding,
            availableInterfaces: [interface, interface]
        ) == .blocked(.ambiguousInterface))
    }

    @Test("VPN-only mode requires an exact active VPN service association")
    func vpnOnlyValidation() {
        let settings = boundSettings(interfaceName: "utun7", vpnOnly: true)
        let interface = networkInterface(
            name: "utun7",
            fingerprint: "fingerprint",
            vpnServiceID: nil
        )
        let binding = TorrentNetworkBinding(
            interfaceName: interface.name,
            interfaceFingerprint: interface.fingerprint,
            vpnServiceID: nil,
            networkBlocked: false
        )

        #expect(TorrentNetworkBindingValidator.validate(
            settings: settings,
            binding: binding,
            availableInterfaces: [interface]
        ) == .blocked(.activeVPNRequired))
    }

    @Test("Controller block requests cannot be overridden by a matching identity")
    func controllerBlockRequest() {
        let settings = boundSettings(interfaceName: "utun7", vpnOnly: true)
        let interface = networkInterface(
            name: "utun7",
            fingerprint: "fingerprint",
            vpnServiceID: "vpn-service"
        )
        let binding = TorrentNetworkBinding(
            interfaceName: interface.name,
            interfaceFingerprint: interface.fingerprint,
            vpnServiceID: interface.vpnServiceID,
            networkBlocked: true
        )

        #expect(TorrentNetworkBindingValidator.validate(
            settings: settings,
            binding: binding,
            availableInterfaces: [interface]
        ) == .blocked(.controllerRequested))
    }

    @Test("Malformed identities are rejected before interface lookup")
    func malformedIdentityValidation() {
        let settings = boundSettings(interfaceName: "en7", vpnOnly: false)
        let interface = networkInterface(
            name: "en7",
            fingerprint: "fingerprint",
            vpnServiceID: nil
        )

        #expect(TorrentNetworkBindingValidator.validate(
            settings: settings,
            binding: TorrentNetworkBinding(
                interfaceName: "en7",
                interfaceFingerprint: "",
                vpnServiceID: nil,
                networkBlocked: false
            ),
            availableInterfaces: [interface]
        ) == .blocked(.malformedBinding))
        #expect(TorrentNetworkBindingValidator.validate(
            settings: settings,
            binding: TorrentNetworkBinding(
                interfaceName: String(repeating: "e", count: 65),
                interfaceFingerprint: "fingerprint",
                vpnServiceID: nil,
                networkBlocked: false
            ),
            availableInterfaces: [interface]
        ) == .blocked(.malformedBinding))
    }

    @Test("Unrestricted mode only accepts a canonical empty identity")
    func unrestrictedValidation() {
        let settings = TorrentSettings()

        #expect(TorrentNetworkBindingValidator.validate(
            settings: settings,
            binding: .unbound(),
            availableInterfaces: nil
        ) == .unrestricted)
        #expect(TorrentNetworkBindingValidator.validate(
            settings: settings,
            binding: TorrentNetworkBinding(
                interfaceName: "en0",
                interfaceFingerprint: "fingerprint",
                vpnServiceID: nil,
                networkBlocked: false
            ),
            availableInterfaces: []
        ) == .blocked(.unexpectedUnboundIdentity))
    }

    @Test("Every monitored change invalidates an active constrained lease")
    func monitoredChangeInvalidatesLease() async throws {
        let initialInterface = networkInterface(
            name: "utun7",
            fingerprint: "fingerprint-1",
            vpnServiceID: "vpn-service"
        )
        let monitor = TestNetworkInterfaceMonitor(initialInterfaces: [initialInterface])
        let invalidations = InvalidationRecorder()
        let authority = TorrentNetworkBindingAuthority(monitor: monitor) { reason in
            await invalidations.record(reason)
        }

        await authority.start()
        try await waitForInterfaceSnapshot(authority)

        let decision = await authority.prepare(
            settings: boundSettings(interfaceName: "utun7", vpnOnly: true),
            binding: TorrentNetworkBinding(
                interfaceName: initialInterface.name,
                interfaceFingerprint: initialInterface.fingerprint,
                vpnServiceID: initialInterface.vpnServiceID,
                networkBlocked: false
            )
        )
        guard case .constrained(let lease) = decision else {
            Issue.record("Expected a constrained network lease")
            return
        }

        #expect(await authority.activate(lease))
        #expect(await authority.confirm(lease))

        monitor.send([
            networkInterface(
                name: "utun7",
                fingerprint: "fingerprint-2",
                vpnServiceID: "vpn-service"
            )
        ])
        try await waitForInvalidation(.monitorChanged, in: invalidations)

        #expect(!(await authority.confirm(lease)))
        let state = await authority.state()
        #expect(!state.hasActiveLease)

        await authority.stop()
    }

    @Test("Authority startup waits for the first service-side snapshot")
    func startupWaitsForFirstSnapshot() async throws {
        let interface = networkInterface(
            name: "utun7",
            fingerprint: "fingerprint",
            vpnServiceID: "vpn-service"
        )
        let monitor = TestNetworkInterfaceMonitor(
            initialInterfaces: [],
            emitsInitialSnapshot: false
        )
        let authority = TorrentNetworkBindingAuthority(monitor: monitor) { _ in }
        let startup = Task {
            await authority.start()
        }

        while monitor.updatesCallCount == 0 {
            await Task.yield()
        }
        #expect(!(await authority.state().hasInterfaceSnapshot))

        monitor.send([interface])
        #expect(await startup.value)
        #expect(await authority.interfaceSnapshot() == TorrentNetworkInterfaceSnapshot(
            revision: 1,
            interfaces: [interface]
        ))

        await authority.stop()
    }

    @Test("An empty first snapshot is ready and remains fail-closed for a missing interface")
    func emptyFirstSnapshotIsReady() async {
        let monitor = TestNetworkInterfaceMonitor(initialInterfaces: [])
        let authority = TorrentNetworkBindingAuthority(monitor: monitor) { _ in }

        #expect(await authority.start())
        #expect(await authority.interfaceSnapshot() == TorrentNetworkInterfaceSnapshot(
            revision: 1,
            interfaces: []
        ))
        #expect(await authority.prepare(
            settings: boundSettings(interfaceName: "utun7", vpnOnly: true),
            binding: TorrentNetworkBinding(
                interfaceName: "utun7",
                interfaceFingerprint: "fingerprint",
                vpnServiceID: "vpn-service",
                networkBlocked: false
            )
        ) == .blocked(.interfaceUnavailable))

        await authority.stop()
    }

    @Test("Monitor readiness has a bounded fail-closed timeout")
    func monitorReadinessTimesOut() async {
        let monitor = TestNetworkInterfaceMonitor(
            initialInterfaces: [],
            emitsInitialSnapshot: false
        )
        let invalidations = InvalidationRecorder()
        let authority = TorrentNetworkBindingAuthority(
            monitor: monitor,
            invalidationHandler: { reason in
                await invalidations.record(reason)
            },
            monitorReadinessTimeout: .milliseconds(10)
        )

        #expect(!(await authority.start()))
        #expect(!(await authority.state().hasInterfaceSnapshot))
        #expect(await invalidations.reasons.contains(.monitorNotReady))
    }

    @Test("A monitor race before activation invalidates the pending lease")
    func monitoredChangeInvalidatesPendingLease() async throws {
        let initialInterface = networkInterface(
            name: "en7",
            fingerprint: "fingerprint-1",
            vpnServiceID: nil
        )
        let monitor = TestNetworkInterfaceMonitor(initialInterfaces: [initialInterface])
        let authority = TorrentNetworkBindingAuthority(monitor: monitor) { _ in }

        await authority.start()
        try await waitForInterfaceSnapshot(authority)
        let decision = await authority.prepare(
            settings: boundSettings(interfaceName: "en7", vpnOnly: false),
            binding: TorrentNetworkBinding(
                interfaceName: "en7",
                interfaceFingerprint: "fingerprint-1",
                vpnServiceID: nil,
                networkBlocked: false
            )
        )
        let lease = try #require(decision.constrainedLease)

        let generation = await authority.state().monitorGeneration
        monitor.send([
            networkInterface(
                name: "en7",
                fingerprint: "fingerprint-2",
                vpnServiceID: nil
            )
        ])
        try await waitForGenerationChange(authority, from: generation)

        #expect(!(await authority.activate(lease)))
        await authority.stop()
    }

    @Test("A stopped authority cannot resurrect its canceled monitor")
    func stoppedAuthorityCannotRestart() async throws {
        let monitor = TestNetworkInterfaceMonitor(initialInterfaces: [
            networkInterface(name: "en7", fingerprint: "first", vpnServiceID: nil)
        ])
        let authority = TorrentNetworkBindingAuthority(monitor: monitor) { _ in }

        await authority.start()
        try await waitForInterfaceSnapshot(authority)
        await authority.stop()
        await authority.start()

        #expect(monitor.updatesCallCount == 1)
        #expect(!(await authority.state().hasInterfaceSnapshot))
    }
}

private extension TorrentNetworkBindingDecision {
    var constrainedLease: TorrentNetworkBindingLease? {
        guard case .constrained(let lease) = self else {
            return nil
        }
        return lease
    }
}

private func boundSettings(interfaceName: String, vpnOnly: Bool) -> TorrentSettings {
    var settings = TorrentSettings()
    settings.requireNetworkInterface = true
    settings.showOnlyVPNInterfaces = vpnOnly
    settings.requiredNetworkInterfaceName = interfaceName
    return settings
}

private func networkInterface(
    name: String,
    fingerprint: String,
    vpnServiceID: String?
) -> NetworkInterfaceOption {
    NetworkInterfaceOption(
        name: name,
        displayName: name,
        fingerprint: fingerprint,
        vpnServiceID: vpnServiceID,
        vpnServiceName: vpnServiceID == nil ? nil : "VPN",
        isLikelyVPN: name.hasPrefix("utun")
    )
}

private func changed(
    _ binding: TorrentNetworkBinding,
    interfaceName: String? = nil,
    fingerprint: String? = nil,
    vpnServiceID: String? = nil
) -> TorrentNetworkBinding {
    TorrentNetworkBinding(
        interfaceName: interfaceName ?? binding.interfaceName,
        interfaceFingerprint: fingerprint ?? binding.interfaceFingerprint,
        vpnServiceID: vpnServiceID ?? binding.vpnServiceID,
        networkBlocked: binding.networkBlocked
    )
}

private func waitForInterfaceSnapshot(
    _ authority: TorrentNetworkBindingAuthority
) async throws {
    for _ in 0..<1_000 {
        if await authority.state().hasInterfaceSnapshot {
            return
        }
        await Task.yield()
    }
    throw TestWaitError.timedOut
}

private func waitForGenerationChange(
    _ authority: TorrentNetworkBindingAuthority,
    from initialGeneration: UInt64
) async throws {
    for _ in 0..<1_000 {
        if await authority.state().monitorGeneration != initialGeneration {
            return
        }
        await Task.yield()
    }
    throw TestWaitError.timedOut
}

private func waitForInvalidation(
    _ reason: TorrentNetworkBindingBlockReason,
    in recorder: InvalidationRecorder
) async throws {
    for _ in 0..<1_000 {
        if await recorder.reasons.contains(reason) {
            return
        }
        await Task.yield()
    }
    throw TestWaitError.timedOut
}

private enum TestWaitError: Error {
    case timedOut
}

private actor InvalidationRecorder {
    private(set) var reasons = [TorrentNetworkBindingBlockReason]()

    func record(_ reason: TorrentNetworkBindingBlockReason) {
        reasons.append(reason)
    }
}

private final class TestNetworkInterfaceMonitor: NetworkInterfaceMonitoring, @unchecked Sendable {
    private struct State {
        var continuation: AsyncStream<[NetworkInterfaceOption]>.Continuation?
        var initialInterfaces: [NetworkInterfaceOption]
        var emitsInitialSnapshot: Bool
        var updatesCallCount = 0
    }

    private let state: Mutex<State>

    init(
        initialInterfaces: [NetworkInterfaceOption],
        emitsInitialSnapshot: Bool = true
    ) {
        state = Mutex(State(
            continuation: nil,
            initialInterfaces: initialInterfaces,
            emitsInitialSnapshot: emitsInitialSnapshot
        ))
    }

    func updates() -> AsyncStream<[NetworkInterfaceOption]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let initial = state.withLock { state in
                state.updatesCallCount += 1
                state.continuation = continuation
                return (state.emitsInitialSnapshot, state.initialInterfaces)
            }
            if initial.0 {
                continuation.yield(initial.1)
            }
        }
    }

    var updatesCallCount: Int {
        state.withLock(\.updatesCallCount)
    }

    func send(_ interfaces: [NetworkInterfaceOption]) {
        let continuation = state.withLock { state in
            state.continuation
        }
        continuation?.yield(interfaces)
    }

    func cancel() {
        let continuation = state.withLock { state in
            defer {
                state.continuation = nil
            }
            return state.continuation
        }
        continuation?.finish()
    }
}
