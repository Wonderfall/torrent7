import Darwin
import Foundation
import Synchronization
import Testing
import TorrentEngineModel
import TorrentMetainfo
import TorrentStorageAuthority
@testable import TorrentEngineCore

@Suite("Torrent engine", .serialized)
struct TorrentEngineTests {
    @Test("Swift snapshot state owns semantic revisions")
    func swiftSnapshotStateOwnsSemanticRevisions() {
        var store = TorrentSnapshotStore()
        let alpha = makeTorrent(id: "alpha", name: "Alpha")
        let beta = makeTorrent(id: "beta", name: "Beta")

        #expect(store.batch(ifChangedSince: 0) == nil)
        #expect(store.reconcile([beta, alpha]) == .updated)
        #expect(store.isInitialized)
        #expect(store.revision == 1)
        #expect(store.torrents.map(\.id) == ["alpha", "beta"])

        #expect(store.reconcile([alpha, beta]) == .unchanged)
        #expect(store.revision == 1)

        let updatedAlpha = makeTorrent(id: "alpha", name: "Updated Alpha")
        #expect(store.reconcile([updatedAlpha, beta]) == .updated)
        #expect(store.revision == 2)
        #expect(store.batch(ifChangedSince: 1)?.torrents.first?.name == "Updated Alpha")

        #expect(store.reconcile([updatedAlpha, updatedAlpha]) == .rejected)
        #expect(store.revision == 2)
        #expect(store.torrents.map(\.id) == ["alpha", "beta"])

        #expect(store.reconcile([]) == .updated)
        #expect(store.revision == 3)
        #expect(store.torrents.isEmpty)
    }

    @Test("Swift snapshot state owns retained presentation metadata")
    func swiftSnapshotStateOwnsPresentationMetadata() {
        var store = TorrentSnapshotStore()
        let raw = makeTorrent(id: "alpha", name: "Alpha")

        let registeredInitialPresentation = store.registerPresentation(
            id: raw.id,
            comment: "Native metadata",
            createdTime: 12_345
        )
        #expect(registeredInitialPresentation)
        #expect(store.reconcile([raw]) == .updated)
        #expect(store.torrents.first?.comment == "Native metadata")
        #expect(store.torrents.first?.createdTime == 12_345)
        #expect(store.reconcile([raw]) == .unchanged)

        let registeredUpdatedPresentation = store.registerPresentation(
            id: raw.id,
            comment: "Updated metadata",
            createdTime: 67_890
        )
        #expect(registeredUpdatedPresentation)
        #expect(store.reconcile([raw]) == .updated)
        #expect(store.revision == 2)
        #expect(store.torrents.first?.comment == "Updated metadata")
        let registeredInvalidPresentation = store.registerPresentation(
            id: raw.id,
            comment: "Invalid",
            createdTime: -1
        )
        #expect(!registeredInvalidPresentation)

        #expect(store.reconcile([]) == .updated)
        #expect(store.reconcile([raw]) == .updated)
        #expect(store.torrents.first?.comment.isEmpty == true)
        #expect(store.torrents.first?.createdTime == 0)
    }

    @Test("Swift queue state owns priority grouping and move decisions")
    func swiftQueueStateOwnsPolicyDecisions() {
        var store = TorrentQueueStore()
        let alpha = makeTorrent(id: "alpha", queuePosition: 0, queuePriority: .normal)
        let beta = makeTorrent(id: "beta", queuePosition: 1, queuePriority: .normal)
        let gamma = makeTorrent(id: "gamma", queuePosition: 2, queuePriority: .high)

        #expect(store.reconcile([beta, gamma, alpha]) == .updated)
        #expect(store.placements.map(\.id) == ["gamma", "alpha", "beta"])

        let movedBeta = store.move("beta", by: .top)
        #expect(movedBeta)
        #expect(store.placements.map(\.id) == ["gamma", "beta", "alpha"])

        let raisedAlpha = store.setPriority(.high, for: "alpha")
        #expect(raisedAlpha)
        #expect(store.placements.map(\.id) == ["gamma", "alpha", "beta"])
        #expect(store.priority(for: "alpha") == .high)
    }

    @Test(
        "Queue position restoration respects priority groups and excludes completed torrents",
        arguments: [Int32(0), 2, Int32(TorrentEngineLimits.maximumTorrentSnapshotCount - 1)]
    )
    func queuePositionRestorationRespectsLiveQueue(_ rawPosition: Int32) throws {
        var store = TorrentQueueStore()
        let queuedIDs: Set<String> = ["high", "alpha", "selected", "beta", "low"]
        #expect(store.reconcile([
            makeTorrent(id: "high", queuePosition: 0, queuePriority: .high),
            makeTorrent(id: "alpha", queuePosition: 1),
            makeTorrent(id: "selected", queuePosition: 2),
            makeTorrent(id: "beta", queuePosition: 3),
            makeTorrent(id: "low", queuePosition: 4, queuePriority: .low),
            makeTorrent(id: "seed", queuePosition: -1, seeding: true),
        ]) == .updated)
        let originalOthers = store.placements.map(\.id).filter { $0 != "selected" }
        let position = try #require(TorrentQueuePosition(rawValue: rawPosition))
        _ = store.restorePosition("selected", to: position, queuedIDs: queuedIDs)
        let expected = switch rawPosition {
        case 0: ["high", "selected", "alpha", "beta", "low"]
        case 2: ["high", "alpha", "selected", "beta", "low"]
        default: ["high", "alpha", "beta", "selected", "low"]
        }
        #expect(store.placements.map(\.id).filter { queuedIDs.contains($0) } == expected)
        #expect(store.placements.map(\.id).filter { $0 != "selected" } == originalOthers)
        let repeated = store.restorePosition("selected", to: position, queuedIDs: queuedIDs)
        let completed = store.restorePosition("seed", to: position, queuedIDs: queuedIDs)
        let missing = store.restorePosition("missing", to: position, queuedIDs: queuedIDs)
        #expect(!repeated)
        #expect(!completed)
        #expect(!missing)
    }

    @Test("Promotion restores native queue order after a poll forgets the removed magnet")
    func promotionRestoresNativeQueueOrder() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: false,
            payloadBroker: TestPayloadBroker()
        )
        var data = Data("d4:infod6:lengthi4e4:name10:sample.bin12:piece lengthi16384e6:pieces20:".utf8)
        data.append(Data(repeating: 0, count: 20))
        data.append(Data("ee".utf8))
        let parsed = try TorrentManifestParser().parse(data)
        let hash = try #require(parsed.manifest.infoHashes.v1).map { byte in
            let digits = String(byte, radix: 16)
            return byte < 16 ? "0" + digits : digits
        }.joined()
        let first = try await engine.addMagnet(
            ParsedMagnet.parse("magnet:?xt=urn:btih:\(hash)"), startsPaused: true
        )
        let second = try await engine.addMagnet(
            ParsedMagnet.parse("magnet:?xt=urn:btih:\(String(repeating: "9", count: 40))"),
            startsPaused: true
        )
        let initial = try await engine.snapshots().sorted { $0.queuePosition < $1.queuePosition }
        #expect(initial.map(\.id) == [first, second])
        let initialItem = try #require(initial.first)
        let position = try #require(TorrentQueuePosition(rawValue: initialItem.queuePosition))
        #expect(try await engine.remove(id: first) == .removed)
        // A normal poll while the GUI waits for destination confirmation.
        #expect(try await engine.snapshots().map(\.id) == [second])
        let activation = try TorrentStorageActivation(
            claimID: UUID(),
            generation: 1,
            sourceManifestDigest: parsed.manifest.sourceManifestDigest,
            preservedTorrentID: first
        )
        #expect(try await engine.addTorrentFile(
            data: data, activation: activation, startsPaused: true
        ) == first)
        try await engine.setTorrentOptions(id: first, options: .unlimited)
        try await engine.restoreQueuePosition(id: first, position: position)
        let restored = try await engine.snapshots().sorted { $0.queuePosition < $1.queuePosition }
        #expect(restored.map(\.id) == [first, second])
        try await engine.restoreQueuePosition(id: first, position: position)
        let repeated = try await engine.snapshots().sorted { $0.queuePosition < $1.queuePosition }
        #expect(repeated.map(\.id) == [first, second])
        await #expect(throws: TorrentEngineError.self) {
            try await engine.restoreQueuePosition(id: "missing", position: position)
        }
        try await engine.shutdownSafely()
    }

    @Test("Swift identity state owns canonical lookup generations and removal state")
    func swiftIdentityStateOwnsLogicalBookkeeping() throws {
        var store = TorrentIdentityStore()
        let alphaID = canonicalTorrentID("a")
        let betaID = canonicalTorrentID("b")
        let alpha = makeTorrent(id: alphaID)
        let beta = makeTorrent(id: betaID)
        let initial = [
            TorrentIdentityStore.NativeSnapshot(nativeToken: 41, torrent: alpha),
            TorrentIdentityStore.NativeSnapshot(nativeToken: 42, torrent: beta),
        ]

        #expect(store.reconcile(initial) == .updated)
        #expect(store.isInitialized)
        #expect(store.nativeToken(for: alphaID) == 41)
        #expect(store.id(forNativeToken: 42) == betaID)
        #expect(store.reconcile(Array(initial.reversed())) == .unchanged)

        let removalToken = store.beginRemoval(id: alphaID)
        #expect(removalToken == 41)
        #expect(store.nativeToken(for: alphaID) == nil)
        store.cancelRemoval(id: alphaID, nativeToken: removalToken ?? 0)
        #expect(store.nativeToken(for: alphaID) == 41)
        _ = store.beginRemoval(id: alphaID)
        store.completeRemoval(id: alphaID, nativeToken: removalToken ?? 0)
        #expect(store.nativeToken(for: alphaID) == nil)

        let registered = store.registerAddedTorrent(id: alphaID, nativeToken: 43)
        #expect(registered)
        #expect(store.nativeToken(for: alphaID) == 43)
        #expect(store.reconcile([
            TorrentIdentityStore.NativeSnapshot(nativeToken: 43, torrent: alpha),
            TorrentIdentityStore.NativeSnapshot(nativeToken: 42, torrent: beta),
        ]) == .unchanged)
    }

    @Test("Swift identity state rejects native token aliasing and identity replacement")
    func swiftIdentityStateRejectsAliasing() {
        var store = TorrentIdentityStore()
        let generatedID = store.makeCanonicalID()
        #expect(generatedID?.hasPrefix("t:") == true)
        #expect(generatedID?.utf8.count == 34)
        #expect(generatedID.map(TorrentIdentityStore.isCanonicalID) == true)
        #expect(!TorrentIdentityStore.isCanonicalID("t:" + String(repeating: "A", count: 32)))
        #expect(!TorrentIdentityStore.isCanonicalID("v1:" + String(repeating: "1", count: 40)))
        let alphaID = canonicalTorrentID("c")
        let betaID = canonicalTorrentID("d")
        let alpha = makeTorrent(id: alphaID)
        let beta = makeTorrent(id: betaID)
        #expect(store.reconcile([
            TorrentIdentityStore.NativeSnapshot(nativeToken: 1, torrent: alpha),
        ]) == .updated)
        #expect(store.reconcile([
            TorrentIdentityStore.NativeSnapshot(nativeToken: 1, torrent: beta),
        ]) == .rejected)
        #expect(store.reconcile([
            TorrentIdentityStore.NativeSnapshot(nativeToken: 2, torrent: alpha),
        ]) == .rejected)
        #expect(store.nativeToken(for: alphaID) == 1)
        let registeredInvalidID = store.registerAddedTorrent(id: "invalid", nativeToken: 3)
        #expect(!registeredInvalidID)
    }

    @Test("Swift persistence state owns generations coalescing and retry state")
    func swiftPersistenceStateOwnsOrchestration() throws {
        var store = TorrentPersistenceStore()
        let requestedRoutine = store.requestSave(nativeToken: 12, mode: .routine)
        let requestedPolicy = store.requestSave(nativeToken: 12, mode: .policy)
        let requestedFull = store.requestSave(nativeToken: 7, mode: .full)
        #expect(requestedRoutine)
        #expect(requestedPolicy)
        #expect(requestedFull)

        let attempts = store.pendingAttempts()
        #expect(attempts.map(\.nativeToken) == [7, 12])
        #expect(attempts[0].mode == .full)
        #expect(attempts[1].mode == .policy)
        #expect(attempts[0].generation > attempts[1].generation)

        store.complete(attempts[0], succeeded: true)
        store.complete(attempts[1], succeeded: false)
        #expect(store.pendingAttempts().count == 1)
        let retry = try #require(store.pendingAttempts().first)
        #expect(retry.nativeToken == 12)
        #expect(retry.generation == attempts[1].generation)
        #expect(retry.priorFailureCount == 1)

        let requestedNewer = store.requestSave(nativeToken: 12, mode: .routine)
        #expect(requestedNewer)
        #expect(store.pendingAttempts().count == 1)
        let newer = try #require(store.pendingAttempts().first)
        #expect(newer.generation > retry.generation)
        #expect(newer.mode == .policy)
        store.complete(retry, succeeded: true)
        #expect(store.hasPendingWork)

        store.retain(nativeTokens: [])
        #expect(!store.hasPendingWork)

        let tombstone = "removal-0123456789abcdef0123456789abcdef.fastresume.remove"
        let resumeID = "v1:" + String(repeating: "a", count: 40)
        let registeredRemoval = store.registerRemovalTombstone(
            filename: tombstone,
            resumeIDs: [resumeID]
        )
        #expect(registeredRemoval)
        let registeredDuplicate = store.registerRemovalTombstone(
            filename: tombstone,
            resumeIDs: [resumeID]
        )
        #expect(!registeredDuplicate)
        let registeredUppercase = store.registerRemovalTombstone(
            filename: "removal-0123456789ABCDEF0123456789ABCDEF.fastresume.remove",
            resumeIDs: [resumeID]
        )
        #expect(!registeredUppercase)
        let registeredTraversal = store.registerRemovalTombstone(
            filename: "../\(tombstone)",
            resumeIDs: [resumeID]
        )
        #expect(!registeredTraversal)
        var removal = try #require(store.pendingRemovalCleanups.first)
        #expect(!removal.resumeDataWasRemoved)
        store.markResumeDataRemoved(tombstoneFilename: removal.tombstoneFilename)
        removal = try #require(store.pendingRemovalCleanups.first)
        #expect(removal.resumeDataWasRemoved)
        store.completeRemovalCleanup(tombstoneFilename: removal.tombstoneFilename)
        #expect(!store.hasPendingWork)

        store.requestNativeRemovalRecovery()
        #expect(store.shouldRecoverNativeRemovals)
        store.completeNativeRemovalRecovery(succeeded: false)
        #expect(store.shouldRecoverNativeRemovals)
        store.completeNativeRemovalRecovery(succeeded: true)
        #expect(!store.hasPendingWork)
    }

    @Test("Swift source policy owns inheritance and effective decisions")
    func swiftSourcePolicyOwnsEffectiveDecisions() throws {
        var store = TorrentSourcePolicyStore(enablePeerExchangePlugin: true)
        let initial = sourcePolicyState(id: "alpha")
        let initialReconciliation = store.reconcile([initial], torrentIDs: ["alpha"])
        #expect(initialReconciliation == .updated)

        var policy = try #require(store.policy(for: "alpha"))
        #expect(policy.isDHTEnabled)
        #expect(!policy.isPeerExchangeEnabled)
        #expect(!policy.isLocalServiceDiscoveryEnabled)
        #expect(policy.effectiveHTTPSTrackerPolicy == .prefer)
        #expect(policy.effectiveHTTPSWebSeedPolicy == .require)

        var settings = TorrentSettings()
        settings.enableDHTNetwork = false
        settings.enablePeerExchangePlugin = true
        settings.usePeerExchangeByDefault = true
        settings.enableLocalServiceDiscovery = true
        settings.useLocalServiceDiscoveryByDefault = true
        settings.httpsTrackerPolicy = .original
        settings.httpsWebSeedPolicy = .original
        let defaultsChanged = store.updateDefaults(settings)
        #expect(defaultsChanged)

        policy = try #require(store.policy(for: "alpha"))
        #expect(!policy.isDHTEnabled)
        #expect(policy.isPeerExchangeEnabled)
        #expect(policy.isLocalServiceDiscoveryEnabled)
        #expect(policy.effectiveHTTPSTrackerPolicy == .original)
        #expect(policy.effectiveHTTPSWebSeedPolicy == .original)

        let dhtMutation = store.mutate(
            id: "alpha",
            mutation: .boolean(field: .dht, enabled: true)
        )
        #expect(dhtMutation == .updated)
        #expect(store.policy(for: "alpha")?.isDHTEnabled == true)
        #expect(store.applications.first?.dhtOverride == true)
        #expect(store.applications.first?.enableDHT == true)
    }

    @Test("Swift source policy stays fail-closed across metadata transitions")
    func swiftSourcePolicyOwnsMetadataTransitions() throws {
        var store = TorrentSourcePolicyStore(enablePeerExchangePlugin: true)
        let pendingReconciliation = store.reconcile(
            [sourcePolicyState(id: "alpha", metadataPending: true)],
            torrentIDs: ["alpha"]
        )
        #expect(pendingReconciliation == .updated)

        var policy = try #require(store.policy(for: "alpha"))
        #expect(!policy.isDHTEnabled)
        #expect(!policy.isPeerExchangeEnabled)
        #expect(!policy.isLocalServiceDiscoveryEnabled)
        let unavailableDHTMutation = store.mutate(
            id: "alpha",
            mutation: .boolean(field: .dht, enabled: true)
        )
        #expect(unavailableDHTMutation == .unavailable)
        let preMetadataMutation = store.mutate(
            id: "alpha",
            mutation: .boolean(field: .preMetadataDHT, enabled: true)
        )
        #expect(preMetadataMutation == .updated)
        #expect(store.policy(for: "alpha")?.isDHTEnabled == true)

        let lockedReconciliation = store.reconcile(
            [sourcePolicyState(id: "alpha", dhtLocked: true, metadataPending: false)],
            torrentIDs: ["alpha"]
        )
        #expect(lockedReconciliation == .updated)
        policy = try #require(store.policy(for: "alpha"))
        #expect(policy.isDHTLocked)
        #expect(!policy.isDHTEnabled)
        #expect(!policy.allowsPreMetadataDHT)
        #expect(store.applications.first?.dhtOverride == nil)
        let unavailablePreMetadataMutation = store.mutate(
            id: "alpha",
            mutation: .boolean(field: .preMetadataDHT, enabled: false)
        )
        #expect(unavailablePreMetadataMutation == .unavailable)
    }

    @Test("Queue reconciliation retains Swift policy and tracks membership")
    func queueReconciliationRetainsSwiftPolicy() {
        var store = TorrentQueueStore()
        let alpha = makeTorrent(id: "alpha", queuePosition: 0, queuePriority: .normal)
        let beta = makeTorrent(id: "beta", queuePosition: 1, queuePriority: .normal)

        #expect(store.reconcile([alpha, beta]) == .updated)
        let loweredBeta = store.setPriority(.low, for: "beta")
        #expect(loweredBeta)

        let staleNativeBeta = makeTorrent(
            id: "beta",
            queuePosition: 0,
            queuePriority: .high
        )
        let gamma = makeTorrent(id: "gamma", queuePosition: 1, queuePriority: .high)
        #expect(store.reconcile([staleNativeBeta, gamma]) == .updated)
        #expect(store.priority(for: "beta") == .low)
        #expect(store.priority(for: "gamma") == .high)
        #expect(store.priority(for: "alpha") == nil)
        #expect(store.placements.map(\.id) == ["gamma", "beta"])
    }

    @Test("Swift detail state owns semantic revisions")
    func swiftDetailStateOwnsSemanticRevisions() {
        var store = TorrentDetailStore()
        let tracker = TorrentTrackerItem(
            url: "https://tracker.example/announce",
            message: "",
            tier: 0,
            failCount: 0,
            scrapeSeeders: -1,
            scrapeLeechers: -1,
            scrapeDownloaded: -1,
            updating: false,
            verified: true,
            hasError: false,
            enabled: true
        )

        let first = store.trackerBatch(id: "torrent", trackers: [tracker], ifChangedSince: nil)
        #expect(first?.revision == 1)
        #expect(store.trackerBatch(
            id: "torrent",
            trackers: [tracker],
            ifChangedSince: first?.revision
        ) == nil)

        let updated = TorrentTrackerItem(
            url: tracker.url,
            message: "updating",
            tier: tracker.tier,
            failCount: tracker.failCount,
            scrapeSeeders: tracker.scrapeSeeders,
            scrapeLeechers: tracker.scrapeLeechers,
            scrapeDownloaded: tracker.scrapeDownloaded,
            updating: true,
            verified: tracker.verified,
            hasError: tracker.hasError,
            enabled: tracker.enabled
        )
        let second = store.trackerBatch(
            id: "torrent",
            trackers: [updated],
            ifChangedSince: first?.revision
        )
        #expect(second?.revision == 2)
        #expect(second?.trackers == [updated])
    }

    @Test("Swift detail state enforces one deterministic global LRU")
    func swiftDetailStateEnforcesDeterministicGlobalLRU() {
        var store = TorrentDetailStore()
        var initialRevisions = [UInt64]()
        initialRevisions.reserveCapacity(TorrentDetailStore.maximumEntryCount)

        for index in 0..<TorrentDetailStore.maximumEntryCount {
            let batch = store.webSeedBatch(
                id: "torrent-\(index)",
                webSeeds: [TorrentWebSeedItem(url: "https://seed-\(index).example/file")],
                ifChangedSince: nil
            )
            initialRevisions.append(batch?.revision ?? 0)
        }
        #expect(store.entryCount == TorrentDetailStore.maximumEntryCount)
        #expect(store.payloadBytes <= TorrentDetailStore.payloadBudgetBytes)

        let touched = store.webSeedBatch(
            id: "torrent-0",
            webSeeds: [TorrentWebSeedItem(url: "https://seed-0.example/file")],
            ifChangedSince: nil
        )
        #expect(touched?.revision == initialRevisions[0])

        _ = store.peerSources(id: "torrent-new", sources: .empty)
        #expect(store.entryCount == TorrentDetailStore.maximumEntryCount)
        let retained = store.webSeedBatch(
            id: "torrent-0",
            webSeeds: [TorrentWebSeedItem(url: "https://seed-0.example/file")],
            ifChangedSince: nil
        )
        let evicted = store.webSeedBatch(
            id: "torrent-1",
            webSeeds: [TorrentWebSeedItem(url: "https://seed-1.example/file")],
            ifChangedSince: nil
        )
        #expect(retained?.revision == initialRevisions[0])
        #expect(evicted?.revision != initialRevisions[1])
        #expect(store.entryCount == TorrentDetailStore.maximumEntryCount)

        store.retainTorrentIDs(["torrent-0"])
        #expect(store.entryCount == 1)
    }

    @Test("Swift tracker-host state owns semantic ordering and revisions")
    func swiftTrackerHostStateOwnsSemanticOrderingAndRevisions() {
        var store = TorrentTrackerHostStore()
        let alpha = TorrentTrackerHostItem(torrentID: "alpha", host: "tracker-a.example")
        let beta = TorrentTrackerHostItem(torrentID: "beta", host: "tracker-b.example")
        let torrentIDs: Set<TorrentItem.ID> = ["alpha", "beta"]

        #expect(store.reconcile([beta, alpha], torrentIDs: torrentIDs) == .updated)
        #expect(store.revision == 1)
        #expect(store.batch().hosts == [alpha, beta])
        #expect(store.reconcile([alpha, beta], torrentIDs: torrentIDs) == .unchanged)
        #expect(store.revision == 1)

        let orphan = TorrentTrackerHostItem(torrentID: "missing", host: "tracker.example")
        #expect(store.reconcile([orphan], torrentIDs: torrentIDs) == .rejected)
        #expect(store.revision == 1)
        #expect(store.batch().hosts == [alpha, beta])

        #expect(store.reconcile([], torrentIDs: torrentIDs) == .updated)
        #expect(store.revision == 2)
        #expect(store.batch().hosts.isEmpty)
    }

    @Test("Engine creation and restart keep the payload broker boundary")
    func engineCreationAndRestartRequirePayloadBroker() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
            TorrentEngine.clientCreationPreflight.withLock { $0 = nil }
        }
        let creations = Mutex([(URL, Bool)]())
        TorrentEngine.clientCreationPreflight.withLock { preflight in
            preflight = { createdStateDirectory, enablePeerExchangePlugin in
                creations.withLock {
                    $0.append((createdStateDirectory, enablePeerExchangePlugin))
                }
            }
        }

        let broker = TestPayloadBroker()
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            payloadBroker: broker
        )
        try await engine.restart(enablePeerExchangePlugin: false)

        // Other test targets may construct an engine concurrently. The hook
        // is process-wide, so constrain this assertion to the state directory
        // owned by this test instead of treating unrelated creation as ours.
        let snapshots = creations.withLock { creations in
            creations.filter { $0.0 == stateDirectory }
        }
        #expect(snapshots.map(\.0) == [stateDirectory, stateDirectory])
        #expect(snapshots.map(\.1) == [true, false])
    }

    @Test("Startup failure engine reports unavailable and empty read models")
    func startupFailureEngineReportsUnavailableAndEmptyReadModels() async throws {
        let engine = TorrentEngine(startupFailureMessage: "boom")

        #expect(engine.isAvailable == false)
        #expect(try await engine.snapshots().isEmpty)
        #expect(
            try await engine.snapshotsIfChanged(
                since: 1,
                sortedBy: .name,
                direction: .ascending
            )?.torrents.isEmpty == true
        )
        #expect(await engine.trackerBatch(id: "missing", since: nil) == nil)
        #expect(await engine.webSeedBatch(id: "missing", since: nil) == nil)
        #expect(await engine.webSeedActivity(id: "missing") == nil)
        #expect(await engine.peerSources(id: "missing") == nil)
        #expect(await engine.fileBatch(id: "missing", since: nil) == nil)
        #expect(await engine.pieceMapBatch(id: "missing", since: nil) == nil)
        #expect(await engine.networkStatus() == .empty)
        #expect(await engine.takeChanges() == 0)
        #expect(await engine.takeAlertError() == nil)
    }

    @Test("Coalesced polling drains alert errors in bounded batches")
    func coalescedPollingDrainsAlertErrorsInBoundedBatches() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let expectedErrors = (0..<20).map { "alert-error-\($0)" }
        let queuedErrors = Mutex(expectedErrors)
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            payloadBroker: TestPayloadBroker(),
            alertErrorReader: {
                queuedErrors.withLock { errors -> String? in
                    errors.isEmpty ? nil : errors.removeFirst()
                }
            }
        )

        let first = try await engine.poll(
            since: nil,
            sortedBy: .name,
            direction: .ascending,
            includeTrackerHosts: false
        )
        let second = try await engine.poll(
            since: first.snapshotBatch?.revision,
            sortedBy: .name,
            direction: .ascending,
            includeTrackerHosts: false
        )

        #expect(first.alertErrors == Array(expectedErrors.prefix(TorrentEngineLimits.maximumAlertErrorsPerPoll)))
        #expect(second.alertErrors == Array(expectedErrors.dropFirst(TorrentEngineLimits.maximumAlertErrorsPerPoll)))
        #expect(queuedErrors.withLock { $0.isEmpty })
    }

    @Test("Coalesced polling preserves revision and optional tracker host semantics")
    func coalescedPollingPreservesRevisionAndOptionalTrackerHostSemantics() async throws {
        let engine = TorrentEngine(startupFailureMessage: "boom")

        let initial = try await engine.poll(
            since: 1,
            sortedBy: .name,
            direction: .ascending,
            includeTrackerHosts: false
        )
        #expect(initial.bridgeHealth == .unavailable)
        #expect(initial.networkStatus == .empty)
        #expect(initial.dirtyMask == 0)
        #expect(initial.alertErrors.isEmpty)
        #expect(initial.snapshotBatch?.revision == 0)
        #expect(initial.snapshotBatch?.torrents.isEmpty == true)
        #expect(initial.trackerHostBatch == nil)

        let unchanged = try await engine.poll(
            since: 0,
            sortedBy: .name,
            direction: .ascending,
            includeTrackerHosts: true
        )
        #expect(unchanged.snapshotBatch == nil)
        #expect(unchanged.trackerHostBatch?.revision == 0)
        #expect(unchanged.trackerHostBatch?.hosts.isEmpty == true)
    }

    @Test("Missing torrent detail reads are unavailable")
    func missingTorrentDetailReadsAreUnavailable() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            payloadBroker: TestPayloadBroker()
        )

        #expect(await engine.trackerBatch(id: "missing", since: nil) == nil)
        #expect(await engine.webSeedBatch(id: "missing", since: nil) == nil)
        #expect(await engine.fileBatch(id: "missing", since: nil) == nil)
        #expect(await engine.pieceMapBatch(id: "missing", since: nil) == nil)
        #expect(await engine.webSeedActivity(id: "missing") == nil)
        #expect(await engine.peerSources(id: "missing") == nil)
    }

    @Test("Magnet activation is pathless and empty detail batches remain authoritative")
    func magnetActivationIsPathless() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            payloadBroker: TestPayloadBroker()
        )
        let id = try await engine.addMagnet(
            ParsedMagnet.parse(
                "magnet:?xt=urn:btih:\(String(repeating: "6", count: 40))"
            )
        )

        let batch = await engine.webSeedBatch(id: id, since: nil)

        #expect(batch != nil)
        #expect(batch?.webSeeds.isEmpty == true)
    }

    @Test("Local torrent add rejects raw bytes in the isolated Swift parser")
    func localTorrentAddRejectsRawBytesInSwift() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            payloadBroker: TestPayloadBroker()
        )
        let activation = try TorrentStorageActivation(
            claimID: UUID(),
            generation: 1,
            sourceManifestDigest: Data(repeating: 1, count: 32)
        )

        await #expect(throws: TorrentManifestError.malformedBencoding) {
            _ = try await engine.addTorrentFile(
                data: Data([UInt8(ascii: "d")]),
                activation: activation
            )
        }
    }

    @Test("Startup failure engine throws startup error for mutations")
    func startupFailureEngineThrowsStartupErrorForMutations() async throws {
        let engine = TorrentEngine(startupFailureMessage: "boom")
        let magnet = try ParsedMagnet.parse(
            "magnet:?xt=urn:btih:\(String(repeating: "6", count: 40))"
        )

        await expectStartupError {
            _ = try await engine.addMagnet(magnet)
        }
        await expectStartupError {
            try await engine.saveAllChecked()
        }
    }

    @Test("Restart failure reports runtime unavailable and can recover")
    func restartFailureReportsRuntimeUnavailableAndCanRecover() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
            TorrentEngine.clientCreationPreflight.withLock { $0 = nil }
        }
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            payloadBroker: TestPayloadBroker()
        )
        #expect(engine.isAvailable)

        TorrentEngine.clientCreationPreflight.withLock { preflight in
            preflight = { createdStateDirectory, _ in
                guard createdStateDirectory == stateDirectory else { return }
                throw TorrentEngineError.bridgeError("restart boom")
            }
        }

        await #expect(throws: TorrentEngineError.self) {
            try await engine.restart(enablePeerExchangePlugin: false)
        }
        #expect(engine.isAvailable == false)

        TorrentEngine.clientCreationPreflight.withLock { $0 = nil }
        try await engine.restart(enablePeerExchangePlugin: false)
        #expect(engine.isAvailable)
        try await engine.saveAllChecked()
    }

    @Test("Critical native faults are latched and recovered by Swift lifecycle policy")
    func criticalNativeFaultsAreLatchedAndRecoveredBySwiftLifecyclePolicy() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            payloadBroker: TestPayloadBroker()
        )

        await engine.recordCriticalFaults(
            TorrentEngineCriticalFaults.sessionIdentityAuthority.rawValue
        )

        #expect(engine.isAvailable == false)
        #expect(await engine.criticalFaults == [.sessionIdentityAuthority])
        do {
            try await engine.saveAllChecked()
            Issue.record("A latched critical fault must reject engine operations.")
        } catch {
            #expect(
                error.localizedDescription
                    == "The torrent engine contained networking because session identity authority became uncertain. Restart the torrent engine to recover."
            )
        }

        try await engine.restart(enablePeerExchangePlugin: true)
        #expect(engine.isAvailable)
        #expect(await engine.criticalFaults.isEmpty)
        try await engine.saveAllChecked()
    }

    @Test("Engine errors expose safe localized descriptions")
    func engineErrorsExposeSafeLocalizedDescriptions() {
        #expect(TorrentEngineError.failedToCreateClient.localizedDescription == "Could not start the torrent engine.")
        #expect(TorrentEngineError.startupFailed("").localizedDescription == "Could not start the torrent engine.")
        #expect(TorrentEngineError.startupFailed("boom").localizedDescription == "Could not start the torrent engine: boom")
        #expect(TorrentEngineError.bridgeError("").localizedDescription == "The torrent operation failed.")
        #expect(TorrentEngineError.bridgeError("bad magnet").localizedDescription == "bad magnet")
        #expect(TorrentAddError.rejected("").localizedDescription == "The torrent could not be added.")
        #expect(TorrentAddError.commitStatusUnknown("uncertain").localizedDescription == "uncertain")
    }

    @Test("Removing a torrent only untracks it")
    func removingTorrentOnlyUntracksIt() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            payloadBroker: TestPayloadBroker()
        )
        let id = try await engine.addMagnet(
            ParsedMagnet.parse(
                "magnet:?xt=urn:btih:\(String(repeating: "7", count: 40))"
            )
        )

        #expect(try await engine.remove(id: id) == .removed)
        #expect(try await engine.snapshots().contains(where: { $0.id == id }) == false)
    }

    @Test("Safe shutdown is terminal and releases native state")
    func safeShutdownIsTerminalAndReleasesNativeState() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let broker = TestPayloadBroker()
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            payloadBroker: broker
        )
        let wakeEvents = await engine.wakeEvents()

        try await engine.shutdownSafely()

        #expect(engine.isAvailable == false)
        var iterator = wakeEvents.makeAsyncIterator()
        if await iterator.next() != nil {
            #expect(await iterator.next() == nil)
        }
        await #expect(throws: TorrentEngineError.self) {
            try await engine.saveAllChecked()
        }
        await #expect(throws: TorrentEngineError.self) {
            try await engine.restart(enablePeerExchangePlugin: true)
        }

        let reopened = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            payloadBroker: broker
        )
        try await reopened.shutdownSafely()
    }
}

private func canonicalTorrentID(_ digit: Character) -> String {
    "t:" + String(repeating: digit, count: 32)
}

private func sourcePolicyState(
    id: TorrentItem.ID,
    dhtLocked: Bool = false,
    metadataPending: Bool = false
) -> TorrentSourcePolicyStore.NativeState {
    TorrentSourcePolicyStore.NativeState(
        id: id,
        dhtOverride: nil,
        peerExchangeOverride: nil,
        localServiceDiscoveryOverride: nil,
        httpsTrackerPolicy: .inherit,
        httpsWebSeedPolicy: .inherit,
        isDHTLocked: dhtLocked,
        isPeerExchangeLocked: false,
        isLocalServiceDiscoveryLocked: false,
        isMetadataValidationPending: metadataPending,
        allowsPreMetadataDHT: false
    )
}

@Test("Removal warnings share the client UTF-8 resource bound")
func removalWarningsShareClientResourceBound() {
    let warning = TorrentEngine.boundedRemovalWarning(
        String(repeating: "🔒", count: TorrentEngineLimits.maximumRemovalWarningBytes)
    )

    #expect(!warning.isEmpty)
    #expect(warning.utf8.count <= TorrentEngineLimits.maximumRemovalWarningBytes)
    #expect(String(data: Data(warning.utf8), encoding: .utf8) == warning)
}

@safe private final class TestPayloadBroker: TorrentPayloadBrokerAccess, Sendable {
    nonisolated func openPayload(
        claimID: UUID,
        generation: UInt64,
        fileIndex: Int32,
        writable: Bool
    ) throws -> Int32 {
        throw TorrentPayloadBrokerCallError(errorNumber: ENOENT)
    }

    nonisolated func payloadSize(
        claimID: UUID,
        generation: UInt64,
        fileIndex: Int32
    ) throws -> Int64 {
        throw TorrentPayloadBrokerCallError(errorNumber: ENOENT)
    }
}

private func temporaryStateDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "TorrentEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func expectStartupError(_ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("Expected startup failure")
    } catch let error as TorrentEngineError {
        #expect(error.localizedDescription == "Could not start the torrent engine: boom")
    } catch {
        Issue.record("Expected TorrentEngineError, got \(error)")
    }
}
