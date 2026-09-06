// SAFETY: Ownership/lifetime: ExtensionFoundation objects remain strongly owned by
// their Swift wrappers; bounds/alignment: no raw buffers are imported; synchronization:
// Monitor and AppExtensionProcess access is isolated to dedicated actors; safe alternative:
// the SDK module lacks strict concurrency and strict-memory-safety annotations.
@preconcurrency @unsafe import ExtensionFoundation
import Foundation
import TorrentEngineIPC
import XPC

extension AppExtensionPoint {
    @Definition
    package static var torrentEngine: AppExtensionPoint {
        Name("torrent-engine")
        Scope(restriction: .application)
        UserInterface(false)
        EnhancedSecurity(true)
    }
}

package struct TorrentEngineExtensionIdentityDescriptor: Equatable, Sendable {
    package let id: String
    package let bundleIdentifier: String
    package let extensionPointIdentifier: String

    package init(
        id: String,
        bundleIdentifier: String,
        extensionPointIdentifier: String
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.extensionPointIdentifier = extensionPointIdentifier
    }
}

package enum TorrentEngineExtensionIdentitySelection: Equatable, Sendable {
    case selected(String)
    case unavailable
    case ambiguous
}

// SAFETY: Ownership/lifetime: this wrapper strongly owns the launched process while the
// coordinator retains the handle; bounds/alignment: no raw memory is accessed; synchronization:
// all process API access is generation-validated and serialized by the single-flight actor;
// safe alternative: AppExtensionProcess does not declare Sendable, so the framework value
// cannot be transferred into its owning actor with a checked conformance.
private final class TorrentEngineExtensionProcessHandle: @unchecked Sendable {
    private let process: AppExtensionProcess

    init(process: AppExtensionProcess) {
        self.process = process
    }

    func makeXPCSession() throws -> XPCSession {
        try process.makeXPCSession()
    }
}

/// Owns the one system-managed engine process for this app invocation.
///
/// Controller replacement creates a fresh XPC session against the retained
/// process. Interruption, identity replacement, or failed session creation can
/// forget that reference; ordinary session cancellation alone must not race
/// ExtensionFoundation teardown.
package actor TorrentEngineExtensionProcessCoordinator {
    package static let shared = TorrentEngineExtensionProcessCoordinator()

    private let monitorStore = TorrentEngineExtensionAcquisition<
        AppExtensionPoint.Monitor, ContinuousClock
    >(clock: ContinuousClock())
    private let processStore = TorrentEngineExtensionAcquisition<
        TorrentEngineExtensionProcessHandle, ContinuousClock
    >(clock: ContinuousClock())

    package init() {}

    package func makeSession(
        configuration: TorrentEngineXPCConfiguration,
        deadline: ContinuousClock.Instant
    ) async throws -> XPCSession {
        let extensionPoint = AppExtensionPoint.torrentEngine
        guard extensionPoint.id == configuration.extensionPointIdentifier else {
            throw TorrentEngineClientError.connectionFailed
        }

        let monitorState = try await extensionMonitorState(for: extensionPoint, deadline: deadline)
        let identities = monitorState.identities
        let descriptors = identities.map {
            TorrentEngineExtensionIdentityDescriptor(
                id: $0.id,
                bundleIdentifier: $0.bundleIdentifier,
                extensionPointIdentifier: $0.extensionPointIdentifier
            )
        }
        let selection = Self.selectIdentity(
            descriptors,
            expectedBundleIdentifier: configuration.serviceIdentifier,
            expectedExtensionPointIdentifier: configuration.extensionPointIdentifier,
            disabledCount: monitorState.disabledCount,
            unapprovedCount: monitorState.unapprovedCount
        )
        guard case .selected(let selectedID) = selection,
              let identity = identities.first(where: { $0.id == selectedID }) else {
            throw TorrentEngineClientError.connectionFailed
        }

        let processStore = processStore
        let lease: TorrentEngineExtensionAcquisition<
            TorrentEngineExtensionProcessHandle, ContinuousClock
        >.Lease
        do {
            lease = try await processStore.acquire(
                identityID: identity.id, deadline: deadline
            ) { [weak processStore] generation in
                let process = try await AppExtensionProcess(
                    configuration: .init(
                        appExtensionIdentity: identity,
                        onInterruption: { [weak processStore] in
                            guard let processStore else {
                                return
                            }
                            Task {
                                await processStore.invalidate(generation: generation)
                            }
                        }
                    )
                )
                return TorrentEngineExtensionProcessHandle(process: process)
            }
        } catch let error as CancellationError {
            throw error
        } catch let error as TorrentEngineClientError {
            throw error
        } catch {
            throw TorrentEngineClientError.connectionFailed
        }
        do {
            return try await processStore.perform(lease: lease, deadline: deadline) { handle in
                try handle.makeXPCSession()
            }
        } catch let error as CancellationError {
            throw error
        } catch let error as TorrentEngineClientError {
            throw error
        } catch {
            // A failed inactive-session creation can mean the retained process
            // has already exited and its interruption callback is still queued.
            // Drop only our reference; bounded connection retry rediscovers or
            // relaunches it without treating invalidate() as a restart primitive.
            throw TorrentEngineClientError.connectionFailed
        }
    }

    package static func selectIdentity(
        _ identities: [TorrentEngineExtensionIdentityDescriptor],
        expectedBundleIdentifier: String,
        expectedExtensionPointIdentifier: String,
        disabledCount: Int,
        unapprovedCount: Int
    ) -> TorrentEngineExtensionIdentitySelection {
        guard disabledCount == 0, unapprovedCount == 0 else {
            return .unavailable
        }
        let matches = identities.filter {
            $0.bundleIdentifier == expectedBundleIdentifier
                && $0.extensionPointIdentifier == expectedExtensionPointIdentifier
        }
        guard matches.count == 1 else {
            return matches.isEmpty ? .unavailable : .ambiguous
        }
        guard identities.count == 1 else {
            return .ambiguous
        }
        return .selected(matches[0].id)
    }

    private func extensionMonitorState(
        for extensionPoint: AppExtensionPoint,
        deadline: ContinuousClock.Instant
    ) async throws -> AppExtensionPoint.Monitor.State {
        do {
            let lease = try await monitorStore.acquire(
                identityID: extensionPoint.id, deadline: deadline
            ) { _ in
                try await AppExtensionPoint.Monitor(appExtensionPoint: extensionPoint)
            }
            return try await monitorStore.perform(lease: lease, deadline: deadline) { $0.state }
        } catch let error as CancellationError {
            throw error
        } catch let error as TorrentEngineClientError {
            throw error
        } catch {
            throw TorrentEngineClientError.connectionFailed
        }
    }
}
