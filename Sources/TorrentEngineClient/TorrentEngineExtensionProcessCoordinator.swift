// ExtensionFoundation has not adopted strict concurrency annotations yet.
// Monitor and AppExtensionProcess access remain isolated to dedicated actors.
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

package enum TorrentEngineProcessLaunchError: Error, Equatable, Sendable {
    case invalidated
}

/// Coalesces concurrent process acquisition and rejects stale launch results.
///
/// Invalidation only forgets the retained handle. It intentionally never calls
/// `AppExtensionProcess.invalidate()`, because ordinary controller replacement
/// must not become process termination.
package actor TorrentEngineProcessSingleFlight<Handle: Sendable> {
    package struct Lease: Sendable {
        package let generation: UInt64
    }

    private enum State {
        case idle
        case starting(
            identityID: String,
            generation: UInt64,
            acquisitionCount: Int,
            task: Task<Handle, any Error>
        )
        case running(
            identityID: String,
            generation: UInt64,
            handle: Handle
        )
    }

    private var state = State.idle
    private var nextGeneration: UInt64 = 0

    package init() {}

    package func acquire(
        identityID: String,
        launch: @escaping @Sendable (UInt64) async throws -> Handle
    ) async throws -> Lease {
        while true {
            try Task.checkCancellation()
            switch state {
            case .idle:
                nextGeneration &+= 1
                let generation = nextGeneration
                let task = Task {
                    try await launch(generation)
                }
                state = .starting(
                    identityID: identityID,
                    generation: generation,
                    acquisitionCount: 1,
                    task: task
                )
                return try await resolveForCaller(
                    task,
                    identityID: identityID,
                    generation: generation
                )

            case .starting(
                let activeIdentityID,
                let generation,
                let acquisitionCount,
                let task
            ):
                guard activeIdentityID == identityID else {
                    // A changed ExtensionFoundation identity supersedes the old
                    // acquisition. Its eventual result cannot overwrite the new
                    // generation, and we do not use process invalidation here.
                    state = .idle
                    continue
                }
                state = .starting(
                    identityID: activeIdentityID,
                    generation: generation,
                    acquisitionCount: acquisitionCount + 1,
                    task: task
                )
                return try await resolveForCaller(
                    task,
                    identityID: identityID,
                    generation: generation
                )

            case .running(let activeIdentityID, let generation, _):
                guard activeIdentityID == identityID else {
                    state = .idle
                    continue
                }
                return Lease(generation: generation)
            }
        }
    }

    package func invalidate(generation: UInt64) {
        switch state {
        case .starting(_, let activeGeneration, _, _)
            where activeGeneration == generation:
            state = .idle
        case .running(_, let activeGeneration, _)
            where activeGeneration == generation:
            state = .idle
        default:
            break
        }
    }

    package var pendingAcquisitionCount: Int {
        guard case .starting(_, _, let acquisitionCount, _) = state else {
            return 0
        }
        return acquisitionCount
    }

    /// Validates a lease and uses its handle without an actor-reentrancy gap.
    /// A failed operation forgets only that generation so a later acquisition
    /// can rediscover or relaunch the ExtensionFoundation process.
    package func perform<Output: Sendable>(
        lease: Lease,
        operation: @Sendable (Handle) throws -> Output
    ) throws -> Output {
        try Task.checkCancellation()
        guard case .running(_, let generation, let handle) = state,
              generation == lease.generation else {
            throw TorrentEngineProcessLaunchError.invalidated
        }
        do {
            return try operation(handle)
        } catch {
            state = .idle
            throw error
        }
    }

    private func resolveForCaller(
        _ task: Task<Handle, any Error>,
        identityID: String,
        generation: UInt64
    ) async throws -> Lease {
        let lease = try await resolve(
            task,
            identityID: identityID,
            generation: generation
        )
        // The shared process launch is deliberately not canceled with one
        // waiter. Publish it for other callers, then stop this canceled caller
        // before it can create an XPC session.
        try Task.checkCancellation()
        return lease
    }

    private func resolve(
        _ task: Task<Handle, any Error>,
        identityID: String,
        generation: UInt64
    ) async throws -> Lease {
        do {
            let launchedHandle = try await task.value
            switch state {
            case .starting(
                let activeIdentityID,
                let activeGeneration,
                _,
                _
            ) where activeIdentityID == identityID
                && activeGeneration == generation:
                state = .running(
                    identityID: identityID,
                    generation: generation,
                    handle: launchedHandle
                )
                return Lease(generation: generation)

            case .running(
                let activeIdentityID,
                let activeGeneration,
                _
            ) where activeIdentityID == identityID
                && activeGeneration == generation:
                return Lease(generation: generation)

            default:
                throw TorrentEngineProcessLaunchError.invalidated
            }
        } catch {
            if case .starting(
                let activeIdentityID,
                let activeGeneration,
                _,
                _
            ) = state,
               activeIdentityID == identityID,
               activeGeneration == generation {
                state = .idle
            }
            throw error
        }
    }
}

/// `AppExtensionProcess` is not declared `Sendable`. This private wrapper only
/// moves the launched value into the single-flight actor; all process API access
/// is then generation-validated and serialized by that actor.
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

    private var monitor: AppExtensionPoint.Monitor?
    private var monitorTask: Task<AppExtensionPoint.Monitor, any Error>?
    private let processStore = TorrentEngineProcessSingleFlight<
        TorrentEngineExtensionProcessHandle
    >()

    package init() {}

    package func makeSession(
        configuration: TorrentEngineXPCConfiguration
    ) async throws -> XPCSession {
        let extensionPoint = AppExtensionPoint.torrentEngine
        guard extensionPoint.id == configuration.extensionPointIdentifier else {
            throw TorrentEngineClientError.connectionFailed
        }

        let monitor = try await extensionMonitor(for: extensionPoint)
        let monitorState = monitor.state
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
        let lease: TorrentEngineProcessSingleFlight<
            TorrentEngineExtensionProcessHandle
        >.Lease
        do {
            lease = try await processStore.acquire(identityID: identity.id) { generation in
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
        } catch {
            throw TorrentEngineClientError.connectionFailed
        }
        do {
            return try await processStore.perform(lease: lease) { handle in
                try handle.makeXPCSession()
            }
        } catch let error as CancellationError {
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

    private func extensionMonitor(
        for extensionPoint: AppExtensionPoint
    ) async throws -> AppExtensionPoint.Monitor {
        if let monitor {
            return monitor
        }
        if let monitorTask {
            return try await monitorTask.value
        }

        let task = Task {
            try await AppExtensionPoint.Monitor(
                appExtensionPoint: extensionPoint
            )
        }
        monitorTask = task
        do {
            let monitor = try await task.value
            self.monitor = monitor
            monitorTask = nil
            return monitor
        } catch {
            monitorTask = nil
            throw TorrentEngineClientError.connectionFailed
        }
    }
}
