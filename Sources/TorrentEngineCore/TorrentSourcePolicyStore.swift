import TorrentEngineModel

@safe package struct TorrentSourcePolicyStore: Sendable {
    package enum Reconciliation: Equatable, Sendable {
        case unchanged
        case updated
        case rejected
    }

    package enum MutationResult: Equatable, Sendable {
        case unchanged
        case updated
        case unavailable
    }

    package struct NativeState: Equatable, Sendable {
        package let id: TorrentItem.ID
        package let dhtOverride: Bool?
        package let peerExchangeOverride: Bool?
        package let localServiceDiscoveryOverride: Bool?
        package let httpsTrackerPolicy: TorrentHTTPSTrackerPolicyOverride
        package let httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicyOverride
        package let isDHTLocked: Bool
        package let isPeerExchangeLocked: Bool
        package let isLocalServiceDiscoveryLocked: Bool
        package let isMetadataValidationPending: Bool
        package let allowsPreMetadataDHT: Bool
    }

    package struct Application: Equatable, Sendable {
        package let id: TorrentItem.ID
        package let dhtOverride: Bool?
        package let peerExchangeOverride: Bool?
        package let localServiceDiscoveryOverride: Bool?
        package let httpsTrackerPolicy: TorrentHTTPSTrackerPolicyOverride
        package let httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicyOverride
        package let effectiveHTTPSTrackerPolicy: TorrentHTTPSTrackerPolicy
        package let effectiveHTTPSWebSeedPolicy: TorrentHTTPSWebSeedPolicy
        package let enableDHT: Bool
        package let enablePeerExchange: Bool
        package let enableLocalServiceDiscovery: Bool
        package let allowPreMetadataDHT: Bool
    }

    private struct Defaults: Equatable, Sendable {
        var enableDHT = true
        var enablePeerExchange = false
        var enableLocalServiceDiscovery = false
        var httpsTrackerPolicy = TorrentHTTPSTrackerPolicy.prefer
        var httpsWebSeedPolicy = TorrentHTTPSWebSeedPolicy.require
    }

    private struct Entry: Equatable, Sendable {
        var dhtOverride: Bool?
        var peerExchangeOverride: Bool?
        var localServiceDiscoveryOverride: Bool?
        var httpsTrackerPolicy: TorrentHTTPSTrackerPolicyOverride
        var httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicyOverride
        var isDHTLocked: Bool
        var isPeerExchangeLocked: Bool
        var isLocalServiceDiscoveryLocked: Bool
        var isMetadataValidationPending: Bool
        var allowsPreMetadataDHT: Bool
    }

    package private(set) var isInitialized = false
    private var isPeerExchangeAvailable: Bool
    private var defaults = Defaults()
    private var entriesByID = [TorrentItem.ID: Entry]()

    package init(enablePeerExchangePlugin: Bool = false) {
        isPeerExchangeAvailable = enablePeerExchangePlugin
    }

    package mutating func setPeerExchangeAvailability(_ isAvailable: Bool) -> Bool {
        guard isPeerExchangeAvailable != isAvailable else {
            return false
        }
        isPeerExchangeAvailable = isAvailable
        return true
    }

    package mutating func updateDefaults(_ settings: TorrentSettings) -> Bool {
        let previousAvailability = isPeerExchangeAvailable
        isPeerExchangeAvailable = settings.enablePeerExchangePlugin
        let next = Defaults(
            enableDHT: settings.effectiveUseDHTByDefault,
            enablePeerExchange: settings.effectiveUsePeerExchangeByDefault,
            enableLocalServiceDiscovery: settings.effectiveUseLocalServiceDiscoveryByDefault,
            httpsTrackerPolicy: settings.httpsTrackerPolicy,
            httpsWebSeedPolicy: settings.httpsWebSeedPolicy
        )
        guard next != defaults || previousAvailability != isPeerExchangeAvailable else {
            return false
        }
        defaults = next
        return true
    }

    package mutating func registerAddedTorrent(
        id: TorrentItem.ID,
        enablePeerExchange: Bool,
        httpsTrackerPolicy: TorrentHTTPSTrackerPolicyOverride,
        httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicyOverride,
        allowPreMetadataDHT: Bool
    ) {
        entriesByID[id] = Entry(
            dhtOverride: nil,
            peerExchangeOverride: enablePeerExchange,
            localServiceDiscoveryOverride: nil,
            httpsTrackerPolicy: httpsTrackerPolicy,
            httpsWebSeedPolicy: httpsWebSeedPolicy,
            isDHTLocked: false,
            isPeerExchangeLocked: false,
            isLocalServiceDiscoveryLocked: false,
            isMetadataValidationPending: allowPreMetadataDHT,
            allowsPreMetadataDHT: allowPreMetadataDHT
        )
    }

    package mutating func reconcile(
        _ states: [NativeState],
        torrentIDs: Set<TorrentItem.ID>
    ) -> Reconciliation {
        guard states.count <= TorrentEngineLimits.maximumTorrentSnapshotCount,
              states.count == torrentIDs.count,
              Set(states.map(\.id)) == torrentIDs,
              !torrentIDs.contains("") else {
            return .rejected
        }

        let previous = entriesByID
        entriesByID = entriesByID.filter { torrentIDs.contains($0.key) }
        for state in states {
            if var existing = entriesByID[state.id] {
                existing.isDHTLocked = state.isDHTLocked
                existing.isPeerExchangeLocked = state.isPeerExchangeLocked
                existing.isLocalServiceDiscoveryLocked = state.isLocalServiceDiscoveryLocked
                existing.isMetadataValidationPending = state.isMetadataValidationPending
                existing.allowsPreMetadataDHT = state.isMetadataValidationPending
                    && !state.isDHTLocked
                    && existing.allowsPreMetadataDHT
                if state.isDHTLocked {
                    existing.dhtOverride = nil
                }
                if state.isPeerExchangeLocked {
                    existing.peerExchangeOverride = nil
                }
                if state.isLocalServiceDiscoveryLocked {
                    existing.localServiceDiscoveryOverride = nil
                }
                entriesByID[state.id] = existing
            } else {
                entriesByID[state.id] = Entry(
                    dhtOverride: state.dhtOverride,
                    peerExchangeOverride: state.peerExchangeOverride,
                    localServiceDiscoveryOverride: state.localServiceDiscoveryOverride,
                    httpsTrackerPolicy: state.httpsTrackerPolicy,
                    httpsWebSeedPolicy: state.httpsWebSeedPolicy,
                    isDHTLocked: state.isDHTLocked,
                    isPeerExchangeLocked: state.isPeerExchangeLocked,
                    isLocalServiceDiscoveryLocked: state.isLocalServiceDiscoveryLocked,
                    isMetadataValidationPending: state.isMetadataValidationPending,
                    allowsPreMetadataDHT: state.isMetadataValidationPending
                        && !state.isDHTLocked
                        && state.allowsPreMetadataDHT
                )
            }
        }

        isInitialized = true
        return entriesByID == previous ? .unchanged : .updated
    }

    package func policy(for id: TorrentItem.ID) -> TorrentSourcePolicy? {
        guard let entry = entriesByID[id] else {
            return nil
        }
        return policy(for: entry)
    }

    package mutating func mutate(
        id: TorrentItem.ID,
        mutation: TorrentSourcePolicyMutation
    ) -> MutationResult {
        guard var entry = entriesByID[id] else {
            return .unavailable
        }
        let previous = entry

        switch mutation {
        case .boolean(.preMetadataDHT, let enabled):
            guard entry.isMetadataValidationPending else {
                return .unavailable
            }
            entry.allowsPreMetadataDHT = !entry.isDHTLocked && enabled
        case .boolean(.dht, let enabled):
            guard !entry.isMetadataValidationPending else {
                return .unavailable
            }
            entry.dhtOverride = entry.isDHTLocked ? nil : enabled
        case .boolean(.peerExchange, let enabled):
            guard !entry.isMetadataValidationPending else {
                return .unavailable
            }
            entry.peerExchangeOverride = entry.isPeerExchangeLocked ? nil : enabled
        case .boolean(.localServiceDiscovery, let enabled):
            guard !entry.isMetadataValidationPending else {
                return .unavailable
            }
            entry.localServiceDiscoveryOverride = entry.isLocalServiceDiscoveryLocked ? nil : enabled
        case .httpsTracker(let policy):
            entry.httpsTrackerPolicy = policy
        case .httpsWebSeed(let policy):
            entry.httpsWebSeedPolicy = policy
        }

        guard entry != previous else {
            return .unchanged
        }
        entriesByID[id] = entry
        return .updated
    }

    package var applications: [Application] {
        entriesByID.keys.sorted().compactMap { id in
            guard let entry = entriesByID[id] else {
                return nil
            }
            let policy = policy(for: entry)
            return Application(
                id: id,
                dhtOverride: entry.dhtOverride,
                peerExchangeOverride: entry.peerExchangeOverride,
                localServiceDiscoveryOverride: entry.localServiceDiscoveryOverride,
                httpsTrackerPolicy: entry.httpsTrackerPolicy,
                httpsWebSeedPolicy: entry.httpsWebSeedPolicy,
                effectiveHTTPSTrackerPolicy: policy.effectiveHTTPSTrackerPolicy,
                effectiveHTTPSWebSeedPolicy: policy.effectiveHTTPSWebSeedPolicy,
                enableDHT: policy.isDHTEnabled,
                enablePeerExchange: policy.isPeerExchangeEnabled,
                enableLocalServiceDiscovery: policy.isLocalServiceDiscoveryEnabled,
                allowPreMetadataDHT: policy.allowsPreMetadataDHT
            )
        }
    }

    package func addPolicy(
        enablePeerExchange: Bool,
        httpsTrackerPolicy: TorrentHTTPSTrackerPolicyOverride,
        httpsWebSeedPolicy: TorrentHTTPSWebSeedPolicyOverride,
        allowPreMetadataDHT: Bool
    ) -> Application {
        let entry = Entry(
            dhtOverride: nil,
            peerExchangeOverride: enablePeerExchange,
            localServiceDiscoveryOverride: nil,
            httpsTrackerPolicy: httpsTrackerPolicy,
            httpsWebSeedPolicy: httpsWebSeedPolicy,
            isDHTLocked: false,
            isPeerExchangeLocked: false,
            isLocalServiceDiscoveryLocked: false,
            isMetadataValidationPending: allowPreMetadataDHT,
            allowsPreMetadataDHT: allowPreMetadataDHT
        )
        let policy = policy(for: entry)
        return Application(
            id: "",
            dhtOverride: nil,
            peerExchangeOverride: enablePeerExchange,
            localServiceDiscoveryOverride: nil,
            httpsTrackerPolicy: httpsTrackerPolicy,
            httpsWebSeedPolicy: httpsWebSeedPolicy,
            effectiveHTTPSTrackerPolicy: policy.effectiveHTTPSTrackerPolicy,
            effectiveHTTPSWebSeedPolicy: policy.effectiveHTTPSWebSeedPolicy,
            enableDHT: policy.isDHTEnabled,
            enablePeerExchange: policy.isPeerExchangeEnabled,
            enableLocalServiceDiscovery: policy.isLocalServiceDiscoveryEnabled,
            allowPreMetadataDHT: allowPreMetadataDHT
        )
    }

    private func policy(for entry: Entry) -> TorrentSourcePolicy {
        let effectiveTracker = switch entry.httpsTrackerPolicy {
        case .inherit: defaults.httpsTrackerPolicy
        case .original: TorrentHTTPSTrackerPolicy.original
        case .prefer: TorrentHTTPSTrackerPolicy.prefer
        case .require: TorrentHTTPSTrackerPolicy.require
        }
        let effectiveWebSeed = switch entry.httpsWebSeedPolicy {
        case .inherit: defaults.httpsWebSeedPolicy
        case .original: TorrentHTTPSWebSeedPolicy.original
        case .require: TorrentHTTPSWebSeedPolicy.require
        }
        let allowsPreMetadataDHT = entry.isMetadataValidationPending
            && !entry.isDHTLocked
            && entry.allowsPreMetadataDHT
        let enableDHT = !entry.isDHTLocked
            && (entry.isMetadataValidationPending
                ? allowsPreMetadataDHT
                : entry.dhtOverride ?? defaults.enableDHT)
        let enablePeerExchange = !entry.isPeerExchangeLocked
            && !entry.isMetadataValidationPending
            && isPeerExchangeAvailable
            && (entry.peerExchangeOverride ?? defaults.enablePeerExchange)
        let enableLSD = !entry.isLocalServiceDiscoveryLocked
            && !entry.isMetadataValidationPending
            && (entry.localServiceDiscoveryOverride ?? defaults.enableLocalServiceDiscovery)

        return TorrentSourcePolicy(
            isDHTEnabled: enableDHT,
            isPeerExchangeEnabled: enablePeerExchange,
            isLocalServiceDiscoveryEnabled: enableLSD,
            httpsTrackerPolicy: entry.httpsTrackerPolicy,
            httpsWebSeedPolicy: entry.httpsWebSeedPolicy,
            effectiveHTTPSTrackerPolicy: effectiveTracker,
            effectiveHTTPSWebSeedPolicy: effectiveWebSeed,
            isDHTLocked: entry.isDHTLocked,
            isPeerExchangeLocked: entry.isPeerExchangeLocked,
            isLocalServiceDiscoveryLocked: entry.isLocalServiceDiscoveryLocked,
            isMetadataValidationPending: entry.isMetadataValidationPending,
            allowsPreMetadataDHT: allowsPreMetadataDHT
        )
    }
}
