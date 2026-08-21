import Dispatch
import Foundation
import Synchronization
import Testing
import TorrentBridge
import TorrentEngineClient
import TorrentEngineModel
@testable import TorrentApp

@MainActor
@Suite("Torrent store integration", .serialized)
struct TorrentStoreIntegrationTests {
    @Test("Application services start explicitly and only once")
    func applicationServicesStartExplicitlyAndOnlyOnce() async throws {
        let suiteName = "app.torrent7.startup.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            TorrentStore.engineStartupFactoryOverride.withLock { $0 = nil }
        }

        let harness = makeStoreHarness(
            defaultsDomain: .suite(suiteName)
        )
        let productionEngine = FakeTorrentEngine()
        let startupCount = Mutex(0)
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { _ in
                startupCount.withLock { $0 += 1 }
                return productionEngine
            }
        }

        #expect(harness.accessStore.bootstrapCount == 0)
        #expect(startupCount.withLock { $0 } == 0)

        harness.store.start()
        harness.store.start()
        await harness.store.saveAll()

        #expect(harness.accessStore.bootstrapCount == 1)
        #expect(startupCount.withLock { $0 } == 1)
        #expect(!harness.engine.isAvailable)
        #expect(harness.store.engineAvailable)
    }

    @Test("Best-effort save suppresses engine failures")
    func bestEffortSaveSuppressesFailure() async {
        let harness = makeStoreHarness()
        await harness.engine.setNextSaveAllError(
            TorrentEngineClientError.serviceRejected("Save failed.")
        )

        await harness.store.saveAll()

        #expect(await harness.engine.saveAllCount == 1)
        #expect(harness.store.lastError == nil)
    }

    @Test("Checked save reports engine failures")
    func checkedSaveReportsFailure() async {
        let harness = makeStoreHarness()
        await harness.engine.setNextSaveAllError(
            TorrentEngineClientError.serviceRejected("Save failed.")
        )

        let didSave = await harness.store.saveAllChecked()

        #expect(!didSave)
        #expect(await harness.engine.saveAllCount == 1)
        #expect(harness.store.lastError == "Save failed.")
    }

    @Test("Checked save cancels a pending production startup for prompt termination")
    func checkedSaveCancelsPendingProductionStartup() async {
        struct StartupState: Sendable {
            var didEnter = false
            var observedCancellation = false
        }

        let harness = makeStoreHarness()
        let state = Mutex(StartupState())
        defer {
            TorrentStore.engineStartupFactoryOverride.withLock { $0 = nil }
        }
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { _ in
                state.withLock { $0.didEnter = true }
                while !Task.isCancelled {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                state.withLock { $0.observedCancellation = true }
                throw CancellationError()
            }
        }

        harness.store.startProductionEngine(enablePeerExchangePlugin: true)
        while !state.withLock({ $0.didEnter }) {
            await Task.yield()
        }

        let didSave = await harness.store.saveAllChecked()

        #expect(didSave)
        #expect(state.withLock { $0.observedCancellation })
    }

    @Test("Concurrent startup installs the engine and applies current settings")
    func concurrentStartupInstallsEngineAndAppliesCurrentSettings() async {
        struct StartupCapture: Sendable {
            var didEnter = false
            var ranOffMainThread = false
            var enablePeerExchangePlugin = false
        }

        let harness = makeStoreHarness()
        let installedEngine = FakeTorrentEngine()
        let capture = Mutex(StartupCapture())
        let releaseStartup = DispatchSemaphore(value: 0)
        defer {
            releaseStartup.signal()
            TorrentStore.engineStartupFactoryOverride.withLock { $0 = nil }
        }
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { enablePeerExchangePlugin in
                capture.withLock { state in
                    state.didEnter = true
                    state.ranOffMainThread = !Thread.isMainThread
                    state.enablePeerExchangePlugin = enablePeerExchangePlugin
                }
                releaseStartup.wait()
                return installedEngine
            }
        }

        harness.store.startProductionEngine(
            enablePeerExchangePlugin: false
        )
        while !capture.withLock({ $0.didEnter }) {
            await Task.yield()
        }

        var currentSettings = harness.store.settings
        currentSettings.enablePeerExchangePlugin = false
        harness.store.updateSettings(currentSettings)
        releaseStartup.signal()

        await harness.store.saveAll()

        #expect(!capture.withLock { $0.enablePeerExchangePlugin })
        #expect(capture.withLock { $0.ranOffMainThread })
        #expect(await harness.engine.shutdownCount == 1)
        #expect(await installedEngine.appliedSettings.last?.settings.enablePeerExchangePlugin == false)
    }

    @Test("A superseded startup shuts down the engine it created")
    func supersededStartupShutsDownCreatedEngine() async {
        struct StartupState: Sendable {
            var callCount = 0
            var firstCallEntered = false
        }

        let harness = makeStoreHarness()
        let abandonedEngine = FakeTorrentEngine()
        let installedEngine = FakeTorrentEngine()
        let state = Mutex(StartupState())
        let releaseFirstStartup = DispatchSemaphore(value: 0)
        defer {
            releaseFirstStartup.signal()
            TorrentStore.engineStartupFactoryOverride.withLock {
                $0 = nil
            }
        }
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { _ in
                let call = state.withLock { state in
                    state.callCount += 1
                    if state.callCount == 1 {
                        state.firstCallEntered = true
                    }
                    return state.callCount
                }
                if call == 1 {
                    releaseFirstStartup.wait()
                    return abandonedEngine
                }
                return installedEngine
            }
        }

        harness.store.startProductionEngine(
            enablePeerExchangePlugin: true
        )
        while !state.withLock({ $0.firstCallEntered }) {
            await Task.yield()
        }

        harness.store.startProductionEngine(
            enablePeerExchangePlugin: true
        )
        releaseFirstStartup.signal()
        await harness.store.saveAll()

        #expect(state.withLock { $0.callCount } == 2)
        #expect(await abandonedEngine.shutdownCount == 1)
        #expect(await installedEngine.appliedSettings.count == 1)
        #expect(harness.store.engineAvailable)
    }

    @Test("Engine startup preserves visible interface choices until the fresh snapshot arrives")
    func engineStartupPreservesVisibleInterfaceChoices() async {
        let interfaces = [
            NetworkInterfaceOption(
                name: "en0",
                displayName: "Wi-Fi",
                fingerprint: "wifi-fingerprint",
                vpnServiceID: nil,
                vpnServiceName: nil,
                isLikelyVPN: false
            ),
            NetworkInterfaceOption(
                name: "utun4",
                displayName: "ProtonVPN",
                fingerprint: "vpn-fingerprint",
                vpnServiceID: "proton-service",
                vpnServiceName: "ProtonVPN",
                isLikelyVPN: true
            ),
        ]
        var settings = TorrentSettings()
        settings.requireNetworkInterface = true
        settings.requiredNetworkInterfaceName = "utun4"
        let harness = makeStoreHarness(settings: settings, networkInterfaces: interfaces)
        let startupEntered = Mutex(false)
        let releaseStartup = DispatchSemaphore(value: 0)
        defer {
            releaseStartup.signal()
            TorrentStore.engineStartupFactoryOverride.withLock { $0 = nil }
        }
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { _ in
                startupEntered.withLock { $0 = true }
                releaseStartup.wait()
                return FakeTorrentEngine()
            }
        }

        harness.store.startProductionEngine(enablePeerExchangePlugin: true)
        while !startupEntered.withLock({ $0 }) {
            await Task.yield()
        }

        #expect(harness.store.networkInterfaces == interfaces)
        #expect(harness.store.selectableNetworkInterfaces == interfaces)
        #expect(!harness.store.requiredNetworkInterfaceAvailable)
        #expect(harness.store.networkProtectionStatusText == "Refreshing interfaces…")

        releaseStartup.signal()
        await harness.store.saveAll()
    }

    @Test("Refresh updates torrents, dependent services, selection, and bookmark pruning")
    func refreshUpdatesTorrentsDependentServicesSelectionAndBookmarkPruning() async {
        let harness = makeStoreHarness()
        let beta = makeTorrent(
            id: "beta",
            name: "Beta",
            downloadPayloadRate: 10,
            uploadPayloadRate: 3
        )
        let alpha = makeTorrent(id: "alpha", name: "Alpha", downloadPayloadRate: 20)
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [beta, alpha]))
        harness.store.selectionState.ids = ["alpha", "missing"]

        await harness.store.refreshNow()

        #expect(harness.store.torrents.map(\.id) == ["alpha", "beta"])
        #expect(harness.store.selectionState.ids == ["alpha"])
        #expect(harness.dock.transferRateUpdates.map(\.downloadRate) == [30])
        #expect(harness.dock.transferRateUpdates.map(\.uploadRate) == [3])
        #expect(harness.sleep.updates.count == 1)
        #expect(harness.sleep.updates.first?.hasActiveTransfers == true)
        #expect(harness.accessStore.pruneCalls.map { $0.map(\.id) } == [["alpha", "beta"]])
        #expect(await harness.engine.snapshotRequests.last?.sortOrder == .name)
    }

    @Test("Changing sort direction publishes the prepared order")
    func changingSortDirectionPublishesPreparedOrder() async {
        let harness = makeStoreHarness()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: [
                makeTorrent(id: "alpha", name: "Alpha"),
                makeTorrent(id: "beta", name: "Beta"),
            ]
        ))
        await harness.store.refreshNow()

        harness.store.setSortDirection(.descending)
        for _ in 0..<20 where harness.store.torrents.map(\.id) != ["beta", "alpha"] {
            await Task.yield()
        }

        #expect(harness.store.torrents.map(\.id) == ["beta", "alpha"])
    }

    @Test("Refresh polls degraded bridge health without making the engine unavailable")
    func refreshPollsDegradedBridgeHealthWithoutMakingEngineUnavailable() async {
        let harness = makeStoreHarness()
        let degradedHealth = TorrentBridgeHealth(
            isAvailable: true,
            totalAlertWorkerFailures: 4,
            consecutiveAlertWorkerFailures: 2,
            isAlertWorkerDegraded: true,
            lastAlertWorkerError: "retrying"
        )
        await harness.engine.setBridgeHealth(degradedHealth)
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: [makeTorrent(id: "alpha", name: "Alpha")]
        ))

        await harness.store.refreshNow()

        #expect(harness.store.bridgeHealth == degradedHealth)
        #expect(harness.store.torrents.map(\.id) == ["alpha"])
        #expect(harness.engine.isAvailable)
    }

    @Test("A changed presentation still publishes completion side effects")
    func changedPresentationPublishesCompletionSideEffects() async {
        let harness = makeStoreHarness()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: []
        ))
        await harness.store.refreshNow()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 2,
            torrents: [makeTorrent(id: "alpha", name: "Alpha")]
        ))
        await harness.store.refreshNow()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 3,
            torrents: [
                makeTorrent(
                    id: "alpha",
                    name: "Alpha",
                    progress: 1,
                    state: .finished,
                    finished: true
                )
            ]
        ))

        await harness.store.refreshNow()
        for _ in 0..<20 {
            if await harness.notifications.notifications.count == 1 {
                break
            }
            await Task.yield()
        }

        #expect(await harness.notifications.notifications.count == 1)
    }

    @Test("Command snapshot ignores live rate-only torrent changes")
    func commandSnapshotIgnoresLiveRateOnlyTorrentChanges() async {
        let harness = makeStoreHarness()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: [
                makeTorrent(id: "alpha", name: "Alpha", downloadRate: 10, state: .downloading),
                makeTorrent(id: "beta", name: "Beta", paused: true, autoManaged: false)
            ]
        ))
        harness.store.selectionState.ids = ["alpha"]
        await harness.store.refreshNow()

        let initialSnapshot = harness.store.commandState.snapshot
        #expect(initialSnapshot.canPauseAnyTorrent == true)
        #expect(initialSnapshot.canResumeAnyTorrent == true)
        #expect(initialSnapshot.canForceRecheckSelectedTorrents == true)

        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 2,
            torrents: [
                makeTorrent(id: "alpha", name: "Alpha", progress: 0.5, downloadRate: 200, state: .downloading),
                makeTorrent(id: "beta", name: "Beta", uploadRate: 50, paused: true, autoManaged: false)
            ]
        ))
        await harness.store.refreshNow()

        #expect(harness.store.commandState.snapshot == initialSnapshot)
    }

    @Test("Finder reveal survives unrelated torrent presentation changes")
    func finderRevealSurvivesUnrelatedPresentationChanges() async throws {
        try await withKnownTorrentHarness { harness, downloadFolder in
            let alpha = makeTorrent(
                id: "alpha",
                name: "sample.bin",
                contentKind: .singleFile,
                hasMetadata: true
            )
            await harness.engine.setNextAddedTorrentFileID(alpha.id)
            await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
                revision: 1,
                torrents: [alpha]
            ))
            #expect(harness.store.addTorrentFile(
                downloadFolder.appending(path: "sample.torrent"),
                torrentData: validSingleFileTorrentData(),
                savePath: downloadFolder.torrentFilePath
            ))
            await harness.store.saveAll()
            #expect(harness.store.downloadLocationPath(for: alpha.id)
                == downloadFolder.appending(path: "sample.bin").torrentFilePath)
            harness.fileLocationService.suspendNextRevealURLs()

            harness.store.revealTorrentInFinder(id: alpha.id)
            await harness.fileLocationService.waitForSuspendedRevealURLs()
            await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
                revision: 2,
                torrents: [alpha, makeTorrent(id: "beta", name: "Beta")]
            ))
            await harness.store.refreshNow()
            harness.fileLocationService.resumeSuspendedRevealURLs()
            for _ in 0..<20 where harness.store.lastError == nil {
                await Task.yield()
            }

            #expect(
                harness.store.lastError
                    == "The download location could not be found."
            )
        }
    }

    @Test("Refresh maintains tracker host index independently of torrent snapshots")
    func refreshMaintainsTrackerHostIndexIndependentlyOfTorrentSnapshots() async {
        let harness = makeStoreHarness()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: [
                makeTorrent(id: "alpha", name: "Alpha"),
                makeTorrent(id: "beta", name: "Beta")
            ]
        ))
        await harness.engine.setTrackerHostBatch(TorrentTrackerHostBatch(
            revision: 1,
            hosts: [
                TorrentTrackerHostItem(torrentID: "alpha", host: "tracker.archlinux.org"),
                TorrentTrackerHostItem(torrentID: "beta", host: "torrent.fedoraproject.org")
            ]
        ))

        await harness.store.refreshNow()

        #expect(harness.store.trackerHosts(for: "alpha") == ["tracker.archlinux.org"])
        #expect(harness.store.trackerHosts(for: "beta") == ["torrent.fedoraproject.org"])

        await harness.engine.setSnapshotBatch(nil)
        await harness.engine.setTrackerHostBatch(TorrentTrackerHostBatch(
            revision: 2,
            hosts: [
                TorrentTrackerHostItem(torrentID: "alpha", host: "mirror.example.org")
            ]
        ))
        await harness.engine.setDirtyMask(UInt32(TTORRENT_DIRTY_TRACKER_HOSTS))

        await harness.store.refreshNow()

        #expect(harness.store.trackerHosts(for: "alpha") == ["mirror.example.org"])
        #expect(harness.store.trackerHosts(for: "beta").isEmpty)
    }

    @Test("Overlapping refresh requests coalesce into one trailing poll")
    func overlappingRefreshRequestsCoalesceIntoTrailingPoll() async {
        let harness = makeStoreHarness()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: [makeTorrent(id: "alpha", name: "Alpha")]
        ))
        await harness.engine.setTrackerHostBatch(TorrentTrackerHostBatch(
            revision: 1,
            hosts: [TorrentTrackerHostItem(torrentID: "alpha", host: "old.example.org")]
        ))
        await harness.store.refreshNow()
        #expect(harness.store.trackerHosts(for: "alpha") == ["old.example.org"])

        await harness.engine.setTrackerHostBatch(TorrentTrackerHostBatch(
            revision: 2,
            hosts: [TorrentTrackerHostItem(torrentID: "alpha", host: "new.example.org")]
        ))
        await harness.engine.setDirtyMask(UInt32(TTORRENT_DIRTY_TRACKER_HOSTS))
        await harness.engine.suspendNextTrackerHostBatchCall()

        let activeRefresh = Task { @MainActor in
            await harness.store.refreshNow()
        }
        await harness.engine.waitForSuspendedTrackerHostBatchCall()

        await harness.engine.setTrackerHostBatch(TorrentTrackerHostBatch(
            revision: 3,
            hosts: [TorrentTrackerHostItem(torrentID: "alpha", host: "latest.example.org")]
        ))
        await harness.engine.setDirtyMask(UInt32(TTORRENT_DIRTY_TRACKER_HOSTS))
        harness.store.refresh()

        await harness.engine.resumeSuspendedTrackerHostBatchCalls()
        await activeRefresh.value

        #expect(harness.store.trackerHosts(for: "alpha") == ["latest.example.org"])
        #expect(await harness.engine.snapshotRequests.count == 3)
    }

    @Test("Add magnet delegates to engine and refreshes afterward")
    func addMagnetDelegatesToEngineAndRefreshesAfterward() async {
        let harness = makeStoreHarness()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [makeTorrent(id: "alpha")]))
        var settings = harness.store.settings
        settings.usePeerExchangeByDefault = false
        harness.store.updateSettings(settings)

        harness.store.addMagnet("magnet:?xt=urn:btih:abc", savePath: "/Downloads", startsPaused: true)
        await harness.store.saveAll()

        #expect(await harness.engine.addedMagnets.map(\.magnet) == ["magnet:?xt=urn:btih:abc"])
        #expect(await harness.engine.addedMagnets.first?.startsPaused == true)
        #expect(await harness.engine.addedMagnets.first?.queuePriority == .normal)
        #expect(await harness.engine.addedMagnets.first?.enablePeerExchange == false)
        #expect(await harness.engine.addedMagnets.first?.httpsTrackerPolicy == .inherit)
        #expect(await harness.engine.addedMagnets.first?.httpsWebSeedPolicy == .inherit)
        #expect(await harness.engine.addedMagnets.first?.allowPreMetadataDHT == false)
        #expect(harness.store.torrents.map(\.id) == ["alpha"])
    }


    @Test("A poll captured before restart cannot mutate the restarted engine state")
    func stalePollCannotCrossEngineRestart() async {
        let current = makeTorrent(id: "current")
        let stale = makeTorrent(id: "stale")
        let harness = makeStoreHarness()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [current]))
        await harness.store.refreshNow()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 2, torrents: [stale]))
        await harness.engine.suspendNextSnapshotBatchCall()

        let staleRefresh = Task { @MainActor in
            await harness.store.refreshNow()
        }
        await harness.engine.waitForSuspendedSnapshotBatchCall()
        await harness.engine.suspendNextRestart()
        var settings = harness.store.settings
        settings.enablePeerExchangePlugin.toggle()
        harness.store.updateSettings(settings)
        await Task.yield()
        #expect(await harness.engine.restartCount == 0)

        await harness.engine.resumeSuspendedSnapshotBatchCalls()
        await staleRefresh.value
        #expect(harness.store.torrents.map(\.id) == [current.id])
        await harness.engine.waitForSuspendedRestart()

        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 3, torrents: [current]))
        await harness.engine.resumeSuspendedRestarts()
        await harness.store.saveAll()
        #expect(harness.store.torrents.map(\.id) == [current.id])
    }


    @Test("Add magnet assigns selected labels to newly registered torrent")
    func addMagnetAssignsSelectedLabelsToNewlyRegisteredTorrent() async throws {
        let suiteName = "app.torrent7.labels.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let harness = makeStoreHarness(defaultsDomain: .suite(suiteName))
        let label = try #require(harness.store.createLabel(named: "Linux"))
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [makeTorrent(id: "alpha")]))

        harness.store.addMagnet(
            "magnet:?xt=urn:btih:abc",
            savePath: "/Downloads",
            labelIDs: [label.id]
        )
        await harness.store.saveAll()

        #expect(harness.store.labelIDs(for: "alpha") == [label.id])
        #expect(harness.store.labels(for: "alpha") == [label])
    }

    @Test("Add magnet assigns labels to returned torrent ID instead of sorted refresh order")
    func addMagnetAssignsLabelsToReturnedTorrentIDInsteadOfSortedRefreshOrder() async throws {
        let suiteName = "app.torrent7.labels.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let harness = makeStoreHarness(defaultsDomain: .suite(suiteName))
        let label = try #require(harness.store.createLabel(named: "Linux"))
        await harness.engine.setNextAddedMagnetID("v1:alpha")
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: [
                makeTorrent(id: "v1:beta", name: "A first in sort order"),
                makeTorrent(id: "v1:alpha", name: "B returned torrent")
            ]
        ))

        harness.store.addMagnet(
            "magnet:?xt=urn:btih:abc",
            savePath: "/Downloads",
            labelIDs: [label.id]
        )
        await harness.store.saveAll()

        #expect(harness.store.labelIDs(for: "v1:alpha") == [label.id])
        #expect(harness.store.labelIDs(for: "v1:beta").isEmpty)
    }

    @Test("Folder-backed magnets promote exact metadata while preserving identity and runtime")
    func folderBackedMagnetPromotionPreservesState() async throws {
        let suiteName = "app.torrent7.magnet-promotion.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try await withKnownTorrentHarness(
            defaultsDomain: .suite(suiteName)
        ) { harness, downloadFolder in
            let fixture = try magnetPromotionFixture()
            let label = try #require(harness.store.createLabel(named: "Linux"))
            let options = TorrentOptions(
                downloadRateLimitKBps: 128,
                uploadRateLimitKBps: 64,
                uploadSlotLimit: 6,
                connectionLimit: 40,
                queuePriority: .high
            )
            let sourcePolicy = TorrentSourcePolicy(
                isDHTEnabled: false,
                isPeerExchangeEnabled: false,
                isLocalServiceDiscoveryEnabled: false,
                httpsTrackerPolicy: .original,
                httpsWebSeedPolicy: .original,
                effectiveHTTPSTrackerPolicy: .original,
                effectiveHTTPSWebSeedPolicy: .original,
                isDHTLocked: false,
                isPeerExchangeLocked: false,
                isLocalServiceDiscoveryLocked: false,
                isMetadataValidationPending: false,
                allowsPreMetadataDHT: true
            )
            await harness.engine.setNextAddedMagnetID(fixture.torrentID)
            await harness.engine.setNextAddedTorrentFileID(fixture.torrentID)
            await harness.engine.setTorrentMetadata(
                fixture.exactInfoDictionary,
                for: fixture.torrentID
            )
            await harness.engine.setTorrentOptions(options)
            await harness.engine.setSourcePolicy(sourcePolicy)
            await harness.engine.setFileBatch(TorrentFileBatch(
                revision: 1,
                files: [TorrentFileItem(
                    path: "sample.bin",
                    size: 4,
                    downloaded: 2,
                    progress: 0.5,
                    index: 0,
                    priority: .high,
                    isPadFile: false
                )]
            ))
            await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
                revision: 1,
                torrents: [makeTorrent(
                    id: fixture.torrentID,
                    name: "sample.bin",
                    queuePosition: 7,
                    queuePriority: .high,
                    paused: true,
                    autoManaged: false,
                    contentKind: .singleFile,
                    hasMetadata: true
                )]
            ))

            #expect(harness.store.addMagnet(
                fixture.magnet,
                downloadFolder: downloadFolder,
                setsDownloadFolderAsDefault: false,
                startsPaused: false,
                queuePriority: .low,
                labelIDs: [label.id]
            ))
            await harness.store.saveAll()

            let promoted = try #require(
                await harness.engine.addedTorrentFiles.first
            )
            let parsed = try TorrentManifestParser().parse(promoted.data)
            #expect(parsed.rawInfoDictionary == fixture.exactInfoDictionary)
            #expect(promoted.activation.preservedTorrentID == fixture.torrentID)
            #expect(promoted.filePriorities == [0: .high])
            #expect(promoted.startsPaused)
            #expect(promoted.queuePriority == .high)
            #expect(!promoted.enablePeerExchange)
            #expect(promoted.httpsTrackerPolicy == .original)
            #expect(promoted.httpsWebSeedPolicy == .original)
            #expect(await harness.engine.removedIDs == [fixture.torrentID])
            #expect(await harness.engine.torrentOptionsUpdates.last?.options == options)
            #expect(await harness.engine.pausedIDs.last == fixture.torrentID)
            #expect(harness.store.labelIDs(for: fixture.torrentID) == [label.id])
            #expect(harness.store.lastError == nil)

            let journal = try #require(harness.storageClaimJournal)
            #expect(await journal.allPromotions().isEmpty)
            let claim = try #require(await journal.allClaims().first)
            #expect(claim.lease.state == .active)
            #expect(claim.torrentID == fixture.torrentID)
        }
    }

    @Test("Magnet promotion rejects metadata before removing the staged torrent")
    func magnetPromotionRejectsMismatchedMetadata() async throws {
        try await withKnownTorrentHarness { harness, downloadFolder in
            let fixture = try magnetPromotionFixture()
            let wrongMagnet = "magnet:?xt=urn:btih:\(String(repeating: "0", count: 40))"
            await harness.engine.setNextAddedMagnetID(fixture.torrentID)
            await harness.engine.setTorrentMetadata(
                fixture.exactInfoDictionary,
                for: fixture.torrentID
            )
            await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
                revision: 1,
                torrents: [makeTorrent(
                    id: fixture.torrentID,
                    hasMetadata: true
                )]
            ))

            #expect(harness.store.addMagnet(
                wrongMagnet,
                downloadFolder: downloadFolder,
                setsDownloadFolderAsDefault: false
            ))
            await harness.store.saveAll()

            #expect(await harness.engine.removedIDs.isEmpty)
            #expect(await harness.engine.addedTorrentFiles.isEmpty)
            #expect(
                harness.store.lastError
                    == TorrentManifestError.advertisedInfoHashMismatch.localizedDescription
            )
            let journal = try #require(harness.storageClaimJournal)
            let pending = try #require(await journal.allPromotions().first)
            #expect(pending.state == .awaitingMetadata)
            #expect(pending.exactInfoDictionary == nil)
        }
    }

    @Test("Ambiguous magnet removal preserves durable promotion evidence")
    func ambiguousMagnetRemovalPreservesPromotion() async throws {
        try await withKnownTorrentHarness { harness, downloadFolder in
            let fixture = try magnetPromotionFixture()
            await harness.engine.setNextAddedMagnetID(fixture.torrentID)
            await harness.engine.setTorrentMetadata(
                fixture.exactInfoDictionary,
                for: fixture.torrentID
            )
            await harness.engine.setFileBatch(TorrentFileBatch(
                revision: 1,
                files: [TorrentFileItem(
                    path: "sample.bin",
                    size: 4,
                    downloaded: 0,
                    progress: 0,
                    index: 0,
                    priority: .normal,
                    isPadFile: false
                )]
            ))
            await harness.engine.setRemoveError(
                TorrentEngineClientError.operationOutcomeUnknown(
                    "Removal outcome unknown."
                )
            )
            await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
                revision: 1,
                torrents: [makeTorrent(
                    id: fixture.torrentID,
                    queuePosition: 2,
                    hasMetadata: true
                )]
            ))

            #expect(harness.store.addMagnet(
                fixture.magnet,
                downloadFolder: downloadFolder,
                setsDownloadFolderAsDefault: false
            ))
            await harness.store.saveAll()

            #expect(await harness.engine.addedTorrentFiles.isEmpty)
            let journal = try #require(harness.storageClaimJournal)
            let pending = try #require(await journal.allPromotions().first)
            #expect(pending.state == .outcomeUnknown)
            #expect(pending.exactInfoDictionary == fixture.exactInfoDictionary)
            #expect(pending.activation?.runtime.queuePosition == 2)
            #expect(pending.activation?.runtime.filePriorities == [0: .normal])
            #expect(harness.store.lastError == "Removal outcome unknown.")
        }
    }

    @Test("Add torrent file assigns selected labels to returned torrent ID")
    func addTorrentFileAssignsSelectedLabelsToReturnedTorrentID() async throws {
        let suiteName = "app.torrent7.labels.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await withKnownTorrentHarness(defaultsDomain: .suite(suiteName)) { harness, downloadFolder in
            let label = try #require(harness.store.createLabel(named: "Linux"))
            await harness.engine.setNextAddedTorrentFileID("file-added")
            await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
                revision: 1,
                torrents: [makeTorrent(id: "file-added", name: "Added torrent")]
            ))

            harness.store.addTorrentFile(
                downloadFolder.appending(path: "sample.torrent"),
                torrentData: validSingleFileTorrentData(),
                savePath: downloadFolder.torrentFilePath,
                labelIDs: [label.id]
            )
            await harness.store.saveAll()

            #expect(harness.store.labelIDs(for: "file-added") == [label.id])
        }
    }

    @Test("Displayed storage path comes from the GUI claim, not the engine part-file path")
    func displayedStoragePathUsesClaimMapping() async throws {
        try await withKnownTorrentHarness { harness, downloadFolder in
            try Data("foreign".utf8).write(
                to: downloadFolder.appending(path: "sample.bin")
            )
            await harness.engine.setNextAddedTorrentFileID("claimed")
            await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
                revision: 1,
                torrents: [makeTorrent(
                    id: "claimed",
                    name: "sample.bin",
                    savePath:
                        "/Users/test/Library/Containers/app.torrent7.engine/Data/Library/Application Support/Torrent7/EngineState/PartFiles/private-claim",
                    contentKind: .singleFile,
                    hasMetadata: true
                )]
            ))

            #expect(harness.store.addTorrentFile(
                downloadFolder.appending(path: "sample.torrent"),
                torrentData: validSingleFileTorrentData(),
                savePath: downloadFolder.torrentFilePath
            ))
            await harness.store.saveAll()

            #expect(harness.store.downloadLocationPath(for: "claimed")
                == downloadFolder.appending(path: "sample 2.bin").torrentFilePath)
        }
    }

    @Test("Imported torrent data is activated in place and never deleted automatically")
    func importedTorrentDataIsPreservedOnRemoval() async throws {
        try await withKnownTorrentHarness { harness, downloadFolder in
            let payload = downloadFolder.appending(path: "sample.bin")
            let original = Data("seed".utf8)
            try original.write(to: payload)
            await harness.engine.setNextAddedTorrentFileID("imported")
            await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
                revision: 1,
                torrents: [makeTorrent(
                    id: "imported",
                    name: "sample.bin",
                    contentKind: .singleFile,
                    hasMetadata: true
                )]
            ))

            #expect(harness.store.addTorrentFile(
                downloadFolder.appending(path: "sample.torrent"),
                torrentData: validSingleFileTorrentData(),
                savePath: downloadFolder.torrentFilePath,
                usesExistingData: true
            ))
            await harness.store.saveAll()

            let journal = try #require(harness.storageClaimJournal)
            let activeClaim = try #require(await journal.allClaims().first)
            let policy = try #require(activeClaim.lease.filePolicies.first)
            #expect(activeClaim.lease.state == .active)
            #expect(policy.provenance == .imported)
            #expect(policy.maximumAccess == .explicitlyImportedWritable)
            #expect(!policy.mayDeleteAutomatically)
            #expect(try Data(contentsOf: payload) == original)

            harness.store.removeTorrent(id: "imported", deleteFiles: true)
            await harness.store.saveAll()

            #expect(await harness.engine.removedIDs == ["imported"])
            #expect(try Data(contentsOf: payload) == original)
            #expect(
                harness.store.lastError
                    == "The torrent was removed, but imported payload data was preserved."
            )
            #expect(await journal.allClaims().first?.lease.state == .deleted)
        }
    }

    @Test("Labels can be toggled, renamed, deleted, and pruned")
    func labelsCanBeToggledRenamedDeletedAndPruned() async throws {
        let suiteName = "app.torrent7.labels.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let harness = makeStoreHarness(defaultsDomain: .suite(suiteName))
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [makeTorrent(id: "alpha")]))
        await harness.store.refreshNow()
        let label = try #require(harness.store.createLabel(named: "Linux"))

        harness.store.toggleLabel(label.id, forTorrentIDs: ["alpha"])
        await harness.store.saveAll()
        #expect(harness.store.labelIDs(for: "alpha") == [label.id])

        harness.store.renameLabel(id: label.id, to: "Distros")
        #expect(harness.store.labels(for: "alpha").map(\.name) == ["Distros"])

        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 2, torrents: []))
        await harness.store.refreshNow()
        #expect(harness.store.labelIDs(for: "alpha").isEmpty)

        harness.store.deleteLabel(id: label.id)
        await harness.store.saveAll()
        #expect(harness.store.labels.isEmpty)
    }

    @Test("Label creation stops at the bounded UI capacity")
    func labelCreationStopsAtCapacity() {
        let labels = (0..<TorrentLabel.maximumCount).map {
            TorrentLabel(id: "label-\($0)", name: "Label \($0)")
        }
        let harness = makeStoreHarness(initialLabels: labels)

        #expect(harness.store.createLabel(named: "Overflow") == nil)
        #expect(
            harness.store.lastError
                == TorrentStoreError.tooManyLabels.localizedDescription
        )
        #expect(harness.store.labels.count == TorrentLabel.maximumCount)
    }

    @Test("Injected defaults domain persists and reloads labels")
    func injectedDefaultsDomainPersistsAndReloadsLabels() async throws {
        let suiteName = "app.torrent7.labels-reload.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let domain = TorrentDefaultsDomain.suite(suiteName)
        let firstHarness = makeStoreHarness(defaultsDomain: domain)
        let label = try #require(firstHarness.store.createLabel(named: "Linux"))

        await firstHarness.store.saveAll()
        let snapshot = try await TorrentLabelPersistenceStore(
            domain: domain
        ).load()
        let reloadedHarness = makeStoreHarness(
            defaultsDomain: domain,
            initialLabels: snapshot.labels,
            initialLabelAssignments: snapshot.assignments
        )

        #expect(reloadedHarness.store.labels == [label])
    }

    @Test("Add magnet can pass explicit per-torrent HTTPS source policies")
    func addMagnetCanPassHTTPSSourcePolicies() async {
        let harness = makeStoreHarness()

        harness.store.addMagnet(
            "magnet:?xt=urn:btih:abc",
            savePath: "/Downloads",
            queuePriority: .high,
            httpsTrackerPolicy: .original,
            httpsWebSeedPolicy: .original,
            allowPreMetadataDHT: true
        )
        await harness.store.saveAll()

        #expect(await harness.engine.addedMagnets.first?.queuePriority == .high)
        #expect(await harness.engine.addedMagnets.first?.httpsTrackerPolicy == .original)
        #expect(await harness.engine.addedMagnets.first?.httpsWebSeedPolicy == .original)
        #expect(await harness.engine.addedMagnets.first?.allowPreMetadataDHT == true)
    }

    @Test("Set queue priority updates torrent options")
    func setQueuePriorityUpdatesTorrentOptions() async {
        let harness = makeStoreHarness()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [makeTorrent(id: "alpha")]))
        await harness.store.refreshNow()

        harness.store.setQueuePriority(for: ["alpha"], priority: .high)
        await harness.store.saveAll()

        #expect(await harness.engine.torrentOptionsUpdates.map(\.id) == ["alpha"])
        #expect(await harness.engine.torrentOptionsUpdates.first?.options.queuePriority == .high)
    }

    @Test("Move queue operations preserve selected visible order")
    func moveQueueOperationsPreserveSelectedVisibleOrder() async {
        let harness = makeStoreHarness()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: [
                makeTorrent(id: "alpha", name: "Alpha"),
                makeTorrent(id: "beta", name: "Beta")
            ]
        ))
        await harness.store.refreshNow()

        harness.store.moveTorrentsInQueue(ids: ["alpha", "beta"], move: .top)
        await harness.store.saveAll()

        #expect(await harness.engine.queueMoves.map(\.id) == ["beta", "alpha"])
        #expect(await harness.engine.queueMoves.map(\.move) == [.top, .top])
    }

    @Test("Add torrent file uses bytes captured during preview")
    func addTorrentFileUsesBytesCapturedDuringPreview() async throws {
        try await withKnownTorrentHarness { harness, downloadFolder in
            let torrentURL = downloadFolder.appending(path: "sample.torrent")
            let previewBytes = validSingleFileTorrentData()
            let replacedBytes = Data("replaced bytes".utf8)
            try previewBytes.write(to: torrentURL)

            let preview = try await harness.store.previewTorrentFile(torrentURL)
            try replacedBytes.write(to: torrentURL)

            harness.store.addTorrentFile(
                torrentURL,
                torrentData: preview.torrentData,
                savePath: downloadFolder.torrentFilePath
            )
            await harness.store.saveAll()

            #expect(await harness.engine.addedTorrentFiles.first?.data == previewBytes)
            #expect(await harness.engine.addedTorrentFiles.first?.activation.sourceManifestDigest.count == 32)
        }
    }

    @Test("Torrent preview rejects symlinked torrent paths before reading")
    func torrentPreviewRejectsSymlinkedTorrentPathsBeforeReading() async throws {
        let harness = makeStoreHarness()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TorrentAppTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let targetURL = directory.appending(path: "target.torrent")
        let symlinkURL = directory.appending(path: "link.torrent")
        try Data("torrent bytes".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        do {
            _ = try await harness.store.previewTorrentFile(symlinkURL)
            Issue.record("Expected symlinked torrent path to be rejected")
        } catch let error as TorrentStoreError {
            #expect(error == .unreadableTorrentFile)
        } catch {
            Issue.record("Expected TorrentStoreError.unreadableTorrentFile, got \(error)")
        }

        #expect(await harness.engine.previewedTorrentFiles.isEmpty)
    }

    @Test("Cancellation rejects a torrent preview result drained from the engine")
    func cancellationRejectsDrainedTorrentPreviewResult() async throws {
        let harness = makeStoreHarness()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TorrentAppTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let torrentURL = directory.appending(path: "sample.torrent")
        try Data("torrent bytes".utf8).write(to: torrentURL)
        await harness.engine.suspendNextTorrentPreview()

        let previewTask = Task { @MainActor in
            try await harness.store.previewTorrentFile(torrentURL)
        }
        await harness.engine.waitForSuspendedTorrentPreview()
        previewTask.cancel()
        await harness.engine.resumeSuspendedTorrentPreviews()

        await #expect(throws: CancellationError.self) {
            try await previewTask.value
        }
        #expect(await harness.engine.previewedTorrentFiles.count == 1)
    }

    @Test("Add torrent file forwards file priorities")
    func addTorrentFileForwardsFilePriorities() async throws {
        try await withKnownTorrentHarness { harness, downloadFolder in
            let torrentURL = downloadFolder.appending(path: "sample.torrent")
            let priorities: [Int32: TorrentFilePriority] = [0: .high]

            harness.store.addTorrentFile(
                torrentURL,
                torrentData: validSingleFileTorrentData(),
                savePath: downloadFolder.torrentFilePath,
                filePriorities: priorities,
                startsPaused: true,
                queuePriority: .high
            )
            await harness.store.saveAll()

            #expect(await harness.engine.addedTorrentFiles.first?.filePriorities == priorities)
            #expect(await harness.engine.addedTorrentFiles.first?.startsPaused == true)
            #expect(await harness.engine.addedTorrentFiles.first?.queuePriority == .high)
        }
    }

    @Test("Set file priority delegates to engine")
    func setFilePriorityDelegatesToEngine() async throws {
        let harness = makeStoreHarness()

        try await harness.store.setFilePriority(for: "alpha", fileIndex: 3, priority: .skip)

        #expect(await harness.engine.filePriorityUpdates.count == 1)
        #expect(await harness.engine.filePriorityUpdates.first?.id == "alpha")
        #expect(await harness.engine.filePriorityUpdates.first?.fileIndex == 3)
        #expect(await harness.engine.filePriorityUpdates.first?.priority == .skip)
    }

    @Test("Unchanged detail batches preserve caller state")
    func unchangedDetailBatchesPreserveCallerState() async {
        let harness = makeStoreHarness()
        await harness.engine.setTrackerBatch(TorrentTrackerBatch(revision: 9, trackers: []))
        await harness.engine.setWebSeedBatch(TorrentWebSeedBatch(revision: 9, webSeeds: []))
        await harness.engine.setFileBatch(TorrentFileBatch(revision: 9, files: []))
        await harness.engine.setPieceMapBatch(TorrentPieceMapBatch(revision: 9, pieceMap: .empty))

        let initialTrackerBatch = await harness.store.trackerBatch(for: "alpha", since: nil)
        let initialWebSeedBatch = await harness.store.webSeedBatch(for: "alpha", since: nil)
        let initialFileBatch = await harness.store.fileBatch(for: "alpha", since: nil)
        let initialPieceMapBatch = await harness.store.pieceMapBatch(for: "alpha", since: nil)
        #expect(initialTrackerBatch?.revision == 9)
        #expect(initialWebSeedBatch?.revision == 9)
        #expect(initialFileBatch?.revision == 9)
        #expect(initialPieceMapBatch?.revision == 9)

        var trackerState = "kept"
        var webSeedState = "kept"
        var fileState = "kept"
        var pieceMapState = "kept"
        if let batch = await harness.store.trackerBatch(for: "alpha", since: 9) {
            trackerState = "replaced by revision \(batch.revision)"
        }
        if let batch = await harness.store.webSeedBatch(for: "alpha", since: 9) {
            webSeedState = "replaced by revision \(batch.revision)"
        }
        if let batch = await harness.store.fileBatch(for: "alpha", since: 9) {
            fileState = "replaced by revision \(batch.revision)"
        }
        if let batch = await harness.store.pieceMapBatch(for: "alpha", since: 9) {
            pieceMapState = "replaced by revision \(batch.revision)"
        }

        #expect(trackerState == "kept")
        #expect(webSeedState == "kept")
        #expect(fileState == "kept")
        #expect(pieceMapState == "kept")
        #expect(await harness.engine.trackerBatchRequests.map(\.revision) == [nil, 9])
        #expect(await harness.engine.webSeedBatchRequests.map(\.revision) == [nil, 9])
        #expect(await harness.engine.fileBatchRequests.map(\.revision) == [nil, 9])
        #expect(await harness.engine.pieceMapBatchRequests.map(\.revision) == [nil, 9])
    }

    @Test("A detail batch from a superseded engine is discarded")
    func staleDetailBatchIsDiscarded() async {
        let harness = makeStoreHarness()
        await harness.engine.setTrackerBatch(
            TorrentTrackerBatch(revision: 9, trackers: [])
        )
        await harness.engine.suspendNextTrackerBatchCall()
        let detailRequest = Task { @MainActor in
            await harness.store.trackerBatch(
                for: "alpha",
                since: nil
            )
        }
        await harness.engine.waitForSuspendedTrackerBatchCall()

        let replacementEngine = FakeTorrentEngine()
        defer {
            TorrentStore.engineStartupFactoryOverride.withLock {
                $0 = nil
            }
        }
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { _ in replacementEngine }
        }

        harness.store.startProductionEngine(
            enablePeerExchangePlugin: true
        )
        await harness.engine.resumeSuspendedTrackerBatchCalls()

        #expect(await detailRequest.value == nil)
        await harness.store.saveAll()
        #expect(harness.store.engineAvailable)
    }

    @Test("Add magnet disables peer exchange when PEX plugin is disabled")
    func addMagnetDisablesPeerExchangeWhenPEXPluginIsDisabled() async {
        var settings = TorrentSettings()
        settings.enablePeerExchangePlugin = false
        settings.usePeerExchangeByDefault = true
        let harness = makeStoreHarness(settings: settings)

        harness.store.addMagnet("magnet:?xt=urn:btih:abc", savePath: "/Downloads")
        await harness.store.saveAll()

        #expect(await harness.engine.addedMagnets.first?.enablePeerExchange == false)
    }

    @Test("Pause and resume commands filter by current torrent state")
    func pauseAndResumeCommandsFilterByCurrentTorrentState() async {
        let harness = makeStoreHarness()
        let active = makeTorrent(id: "active")
        let manuallyPaused = makeTorrent(id: "paused", paused: true, autoManaged: false)
        let queued = makeTorrent(id: "queued", paused: true, autoManaged: true)
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [active, manuallyPaused, queued]))
        await harness.store.refreshNow()

        harness.store.pauseTorrents(ids: ["active", "paused", "queued", "missing"])
        await harness.store.saveAll()
        harness.store.resumeTorrents(ids: ["active", "paused", "queued", "missing"])
        await harness.store.saveAll()

        #expect(await harness.engine.pausedIDs == ["active", "queued"])
        #expect(await harness.engine.resumedIDs == ["paused"])
    }

    @Test("Unresolved storage activation is paused before settings and cannot be resumed")
    func unresolvedStorageActivationRemainsPaused() async throws {
        try await withTemporaryDirectory { root in
            let downloads = root.appending(
                path: "Downloads",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: downloads,
                withIntermediateDirectories: true
            )
            let journal = try TorrentStorageClaimJournal(
                directory: root.appending(
                    path: "Journal",
                    directoryHint: .isDirectory
                )
            )
            let initial = makeStoreHarness(storageClaimJournal: journal)
            await initial.engine.setAddTorrentFileError(
                TorrentEngineClientError.operationOutcomeUnknown(
                    "Activation outcome unknown."
                )
            )
            #expect(initial.store.addTorrentFile(
                downloads.appending(path: "sample.torrent"),
                torrentData: validSingleFileTorrentData(),
                savePath: downloads.torrentFilePath
            ))
            await initial.store.saveAll()

            let claim = try #require(await journal.allClaims().first)
            #expect(claim.lease.state == .activationUnknown)
            #expect(claim.torrentID == nil)
            let digest = try #require(claim.manifest.infoHashes.v1)
            let alphabet = Array("0123456789abcdef".utf8)
            var encodedHash = [UInt8]()
            encodedHash.reserveCapacity(digest.count * 2)
            for byte in digest {
                encodedHash.append(alphabet[Int(byte >> 4)])
                encodedHash.append(alphabet[Int(byte & 0x0f)])
            }
            let infoHash = "v1:" + String(decoding: encodedHash, as: UTF8.self)
            let restoredID = "t:\(String(repeating: "d", count: 32))"
            let restored = makeStoreHarness(
                initialSnapshotBatch: TorrentSnapshotBatch(
                    revision: 1,
                    torrents: [makeTorrent(
                        id: restoredID,
                        infoHash: infoHash,
                        state: .downloading,
                        paused: false,
                        autoManaged: true
                    )]
                ),
                startsTasks: true,
                storageClaimJournal: journal
            )

            await restored.store.saveAll()

            #expect(await restored.engine.pausedIDs == [restoredID])
            #expect(await restored.engine.pauseAppliedDHTValues == [nil])
            #expect(await restored.engine.appliedSettings.count == 1)

            await restored.engine.setSnapshotBatch(TorrentSnapshotBatch(
                revision: 2,
                torrents: [makeTorrent(
                    id: restoredID,
                    infoHash: infoHash,
                    paused: true,
                    autoManaged: false
                )]
            ))
            await restored.store.refreshNow()
            restored.store.resumeTorrent(id: restoredID)
            await restored.store.saveAll()

            #expect(await restored.engine.resumedIDs.isEmpty)

            let failedID = "t:\(String(repeating: "e", count: 32))"
            let failed = makeStoreHarness(
                initialSnapshotBatch: TorrentSnapshotBatch(
                    revision: 1,
                    torrents: [makeTorrent(
                        id: failedID,
                        infoHash: infoHash,
                        state: .downloading,
                        paused: false,
                        autoManaged: true
                    )]
                ),
                initialPauseError: TorrentEngineClientError.serviceRejected(
                    "Pause failed."
                ),
                startsTasks: true,
                storageClaimJournal: journal
            )

            await failed.store.saveAll()

            #expect(await failed.engine.pausedIDs == [failedID])
            #expect(await failed.engine.appliedSettings.isEmpty)
            #expect(await failed.engine.shutdownCount == 1)
            #expect(!failed.store.engineAvailable)
            #expect(
                failed.store.lastError
                    == "A torrent with unresolved storage activation could not be kept paused. The torrent engine was stopped. Pause failed."
            )
        }
    }


    @Test("Updating settings clears disabled completion badge and applies blocked network policy")
    func updatingSettingsClearsDisabledCompletionBadgeAndAppliesBlockedNetworkPolicy() async throws {
        let suiteName = "app.torrent7.store-settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let harness = makeStoreHarness(defaultsDomain: .suite(suiteName))
        var settings = TorrentSettings()
        settings.completionNotificationsEnabled = false
        settings.requireNetworkInterface = true
        settings.requiredNetworkInterfaceName = "utun4"

        harness.store.updateSettings(settings)
        await harness.store.saveAll()

        #expect(harness.dock.completionBadgeUpdates == [0])
        #expect(await harness.engine.blockNetworkCount >= 1)
        #expect(await harness.engine.appliedSettings.last?.networkBlocked == true)
        #expect(TorrentSettings.load(defaults: defaults).libtorrentRequiredNetworkInterfaceName == "utun4")
    }

    @Test("Changing PEX plugin setting restarts engine")
    func changingPEXPluginSettingRestartsEngine() async {
        let harness = makeStoreHarness()
        await harness.engine.suspendNextRestart()
        var settings = harness.store.settings
        settings.enablePeerExchangePlugin = true

        harness.store.updateSettings(settings)
        await harness.engine.waitForSuspendedRestart()

        await harness.engine.resumeSuspendedRestarts()
        await harness.store.saveAll()

        #expect(await harness.engine.blockNetworkCount >= 1)
        #expect(await harness.engine.restartPeerExchangePluginValues == [true])
        #expect(await harness.engine.appliedSettings.last?.settings.enablePeerExchangePlugin == true)
    }


    @Test("Enabling interface binding contains once without restarting the engine")
    func enablingInterfaceBindingContainsOnceWithoutRestart() async throws {
        let vpn = NetworkInterfaceOption(
            name: "utun4",
            displayName: "ProtonVPN",
            fingerprint: "service-fingerprint",
            vpnServiceID: "proton-service",
            vpnServiceName: "ProtonVPN",
            isLikelyVPN: true
        )
        let harness = makeStoreHarness(networkInterfaces: [vpn])
        var settings = harness.store.settings
        settings.requireNetworkInterface = true
        settings.requiredNetworkInterfaceName = vpn.name

        harness.store.updateSettings(settings)
        await harness.store.saveAll()

        #expect(await harness.engine.blockNetworkCount == 1)
        #expect(await harness.engine.restartCount == 0)
        #expect(harness.store.engineAvailable)
        #expect(await harness.engine.appliedSettings.last?.networkBinding == TorrentNetworkBinding(
            interfaceName: vpn.name,
            interfaceFingerprint: vpn.fingerprint,
            vpnServiceID: vpn.vpnServiceID,
            networkBlocked: false
        ))
    }

    @Test("Rapid interface changes share one containment and apply only the latest binding")
    func rapidInterfaceChangesCoalesceContainment() async throws {
        let firstVPN = NetworkInterfaceOption(
            name: "utun1",
            displayName: "First VPN",
            fingerprint: "first-fingerprint",
            vpnServiceID: "first-service",
            vpnServiceName: "First VPN",
            isLikelyVPN: true
        )
        let secondVPN = NetworkInterfaceOption(
            name: "utun2",
            displayName: "Second VPN",
            fingerprint: "second-fingerprint",
            vpnServiceID: "second-service",
            vpnServiceName: "Second VPN",
            isLikelyVPN: true
        )
        let harness = makeStoreHarness(networkInterfaces: [firstVPN, secondVPN])
        await harness.engine.suspendNextNetworkBlock()
        var settings = harness.store.settings
        settings.requireNetworkInterface = true
        settings.requiredNetworkInterfaceName = firstVPN.name

        harness.store.updateSettings(settings)
        await harness.engine.waitForSuspendedNetworkBlock()
        settings.requiredNetworkInterfaceName = secondVPN.name
        harness.store.updateSettings(settings)

        let save = Task { @MainActor in
            await harness.store.saveAll()
        }
        await harness.engine.resumeSuspendedNetworkBlocks()
        await save.value

        #expect(await harness.engine.blockNetworkCount == 1)
        #expect(await harness.engine.restartCount == 0)
        #expect(await harness.engine.appliedSettings.count == 1)
        #expect(await harness.engine.appliedSettings.last?.networkBinding == TorrentNetworkBinding(
            interfaceName: secondVPN.name,
            interfaceFingerprint: secondVPN.fingerprint,
            vpnServiceID: secondVPN.vpnServiceID,
            networkBlocked: false
        ))
    }

    @Test("A stale pre-containment poll cannot revoke a confirmed network block")
    func stalePreContainmentPollCannotRevokeConfirmedBlock() async {
        let harness = makeStoreHarness()
        let replacementCount = Mutex(0)
        defer {
            TorrentStore.engineStartupFactoryOverride.withLock { $0 = nil }
        }
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { _ in
                replacementCount.withLock { $0 += 1 }
                return FakeTorrentEngine()
            }
        }

        await harness.engine.suspendNextSnapshotBatchCall()
        let stalePoll = Task { @MainActor in
            await harness.store.refreshNow()
        }
        await harness.engine.waitForSuspendedSnapshotBatchCall()
        await harness.engine.suspendNextSettingsApplication()

        var restricted = harness.store.settings
        restricted.requireNetworkInterface = true
        restricted.requiredNetworkInterfaceName = "utun-missing"
        harness.store.updateSettings(restricted)
        await harness.engine.waitForSuspendedSettingsApplication()

        await harness.engine.resumeSuspendedSnapshotBatchCalls()
        await stalePoll.value
        await harness.engine.requireControllerReplacementOnNextNetworkBlock()

        var updated = restricted
        updated.downloadRateLimitKBps = 512
        harness.store.updateSettings(updated)
        await harness.engine.resumeSuspendedSettingsApplications()
        await harness.store.saveAll()

        #expect(await harness.engine.blockNetworkCount == 1)
        #expect(replacementCount.withLock { $0 } == 0)
        #expect(harness.store.engineAvailable)
        #expect(await harness.engine.appliedSettings.last?.networkBlocked == true)
    }

    @Test("A failed poll cannot suppress real binding containment")
    func failedPollCannotSuppressContainment() async {
        let vpn = NetworkInterfaceOption(
            name: "utun4",
            displayName: "ProtonVPN",
            fingerprint: "service-fingerprint",
            vpnServiceID: "proton-service",
            vpnServiceName: "ProtonVPN",
            isLikelyVPN: true
        )
        let harness = makeStoreHarness(networkInterfaces: [vpn])
        await harness.engine.setNetworkStatus(.empty)
        await harness.engine.setNextPollError(FakeBookmarkError())

        await harness.store.refreshNow()

        var settings = harness.store.settings
        settings.requireNetworkInterface = true
        settings.requiredNetworkInterfaceName = vpn.name
        harness.store.updateSettings(settings)
        await harness.store.saveAll()

        #expect(await harness.engine.blockNetworkCount == 1)
        #expect(harness.store.engineAvailable)
        #expect(await harness.engine.appliedSettings.last?.networkBlocked == false)
    }

    @Test("Initial synchronization finishes before wake refresh starts")
    func initialSynchronizationPrecedesWakeRefresh() async throws {
        let vpn = NetworkInterfaceOption(
            name: "utun4",
            displayName: "ProtonVPN",
            fingerprint: "service-fingerprint",
            vpnServiceID: "proton-service",
            vpnServiceName: "ProtonVPN",
            isLikelyVPN: true
        )
        var settings = TorrentSettings()
        settings.requireNetworkInterface = true
        settings.requiredNetworkInterfaceName = vpn.name
        let harness = makeStoreHarness(
            settings: settings,
            networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                revision: 1,
                interfaces: [vpn]
            ),
            startsTasks: true,
            keepsWakeStreamOpen: true,
            suspendsInitialSnapshotBatch: true
        )
        await harness.engine.waitForSuspendedSnapshotBatchCall()

        #expect(await harness.engine.wakeStreamRequestCount == 0)
        await harness.engine.resumeSuspendedSnapshotBatchCalls()
        await harness.store.saveAll()
        await harness.engine.waitForWakeStreamRequestCount(1)

        #expect(harness.store.networkInterfaces == [vpn])
        #expect(await harness.engine.appliedSettings.last?.networkBinding.interfaceName == vpn.name)
        await harness.engine.finishWakeStream()
    }

    @Test("Service interface snapshot populates VPN choices before initial binding")
    func serviceInterfaceSnapshotDrivesInitialBinding() async throws {
        let vpn = NetworkInterfaceOption(
            name: "utun4",
            displayName: "ProtonVPN",
            fingerprint: "service-fingerprint",
            vpnServiceID: "proton-service",
            vpnServiceName: "ProtonVPN",
            isLikelyVPN: true
        )
        var settings = TorrentSettings()
        settings.requireNetworkInterface = true
        settings.showOnlyVPNInterfaces = true
        settings.requiredNetworkInterfaceName = vpn.name
        let harness = makeStoreHarness(
            settings: settings,
            networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                revision: 1,
                interfaces: [vpn]
            ),
            startsTasks: true
        )

        await harness.store.saveAll()

        #expect(harness.store.networkInterfaces == [vpn])
        #expect(harness.store.selectableNetworkInterfaces == [vpn])
        let application = try #require(await harness.engine.appliedSettings.last)
        #expect(application.networkBinding == TorrentNetworkBinding(
            interfaceName: vpn.name,
            interfaceFingerprint: vpn.fingerprint,
            vpnServiceID: vpn.vpnServiceID,
            networkBlocked: false
        ))
        #expect(await harness.engine.restartCount == 0)
    }

    @Test("Every new service interface revision reauthorizes exactly once")
    func serviceInterfaceRevisionReauthorizesOnce() async {
        let vpn = NetworkInterfaceOption(
            name: "utun4",
            displayName: "ProtonVPN",
            fingerprint: "service-fingerprint",
            vpnServiceID: "proton-service",
            vpnServiceName: "ProtonVPN",
            isLikelyVPN: true
        )
        var settings = TorrentSettings()
        settings.requireNetworkInterface = true
        settings.showOnlyVPNInterfaces = true
        settings.requiredNetworkInterfaceName = vpn.name
        let harness = makeStoreHarness(
            settings: settings,
            networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                revision: 1,
                interfaces: [vpn]
            ),
            startsTasks: true
        )
        await harness.store.saveAll()
        let initialApplicationCount = await harness.engine.appliedSettings.count

        await harness.engine.setNetworkInterfaceSnapshot(
            TorrentNetworkInterfaceSnapshot(revision: 2, interfaces: [vpn])
        )
        await harness.store.refreshNow(notifiesCompletions: false)
        await harness.store.saveAll()

        #expect(await harness.engine.appliedSettings.count == initialApplicationCount + 1)
        #expect(await harness.engine.appliedSettings.last?.networkBlocked == false)

        await harness.store.refreshNow(notifiesCompletions: false)
        await harness.store.saveAll()
        #expect(await harness.engine.appliedSettings.count == initialApplicationCount + 1)
    }

    @Test("Loss and restoration of service VPN identity blocks then reauthorizes")
    func serviceVPNIdentityChangesFailClosed() async {
        let activeVPN = NetworkInterfaceOption(
            name: "utun4",
            displayName: "ProtonVPN",
            fingerprint: "service-fingerprint",
            vpnServiceID: "proton-service",
            vpnServiceName: "ProtonVPN",
            isLikelyVPN: true
        )
        var settings = TorrentSettings()
        settings.requireNetworkInterface = true
        settings.showOnlyVPNInterfaces = true
        settings.requiredNetworkInterfaceName = activeVPN.name
        let harness = makeStoreHarness(
            settings: settings,
            networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                revision: 1,
                interfaces: [activeVPN]
            ),
            startsTasks: true
        )
        await harness.store.saveAll()

        let inactiveVPN = NetworkInterfaceOption(
            name: activeVPN.name,
            displayName: activeVPN.name,
            fingerprint: activeVPN.fingerprint,
            vpnServiceID: nil,
            vpnServiceName: nil,
            isLikelyVPN: true
        )
        await harness.engine.setNetworkInterfaceSnapshot(
            TorrentNetworkInterfaceSnapshot(revision: 2, interfaces: [inactiveVPN])
        )
        await harness.store.refreshNow(notifiesCompletions: false)
        await harness.store.saveAll()

        #expect(await harness.engine.appliedSettings.last?.networkBlocked == true)
        #expect(harness.store.selectableNetworkInterfaces.isEmpty)

        await harness.engine.setNetworkInterfaceSnapshot(
            TorrentNetworkInterfaceSnapshot(revision: 3, interfaces: [activeVPN])
        )
        await harness.store.refreshNow(notifiesCompletions: false)
        await harness.store.saveAll()

        #expect(await harness.engine.appliedSettings.last?.networkBinding.vpnServiceID == "proton-service")
        #expect(await harness.engine.appliedSettings.last?.networkBlocked == false)
    }

    @Test("Automatic refresh tasks are renewed after an engine restart")
    func refreshTasksAreRenewedAfterRestart() async {
        let harness = makeStoreHarness(startsTasks: true, keepsWakeStreamOpen: true)
        await harness.engine.waitForWakeStreamRequestCount(1)
        await harness.store.saveAll()
        var settings = harness.store.settings
        settings.enablePeerExchangePlugin.toggle()

        harness.store.updateSettings(settings)
        await harness.store.saveAll()
        await harness.engine.waitForWakeStreamRequestCount(2)

        #expect(await harness.engine.wakeStreamRequestCount == 2)
        await harness.engine.finishWakeStream()
    }

    @Test("VPN-only mode remembers disabled network preferences")
    func vpnOnlyModeRemembersDisabledNetworkPreferences() async {
        var settings = TorrentSettings()
        settings.requireNetworkInterface = true
        settings.requiredNetworkInterfaceName = "en0"
        settings.acceptIncomingConnections = true
        settings.usePortForwarding = true
        settings.enableLocalServiceDiscovery = true
        settings.anonymousMode = false
        let interfaces = [
            NetworkInterfaceOption(
                name: "en0",
                displayName: "Ethernet",
                fingerprint: "ethernet",
                vpnServiceID: nil,
                vpnServiceName: nil,
                isLikelyVPN: false
            ),
            NetworkInterfaceOption(
                name: "utun4",
                displayName: "VPN",
                fingerprint: "vpn",
                vpnServiceID: "vpn-service",
                vpnServiceName: "VPN",
                isLikelyVPN: true
            )
        ]
        let harness = makeStoreHarness(settings: settings, networkInterfaces: interfaces)

        harness.store.setShowOnlyVPNInterfaces(true)

        #expect(harness.store.settings.usePortForwarding == true)
        #expect(harness.store.settings.enableLocalServiceDiscovery == true)
        #expect(harness.store.settings.anonymousMode == false)
        #expect(harness.store.settings.effectiveUsePortForwarding == false)
        #expect(harness.store.settings.effectiveEnableLocalServiceDiscovery == false)
        #expect(harness.store.settings.effectiveAnonymousMode == true)

        harness.store.setShowOnlyVPNInterfaces(false)

        #expect(harness.store.settings.usePortForwarding == true)
        #expect(harness.store.settings.enableLocalServiceDiscovery == true)
        #expect(harness.store.settings.anonymousMode == false)
        #expect(harness.store.settings.effectiveUsePortForwarding == true)
        #expect(harness.store.settings.effectiveEnableLocalServiceDiscovery == true)
        #expect(harness.store.settings.effectiveAnonymousMode == false)
    }

    @Test("User operation queue applies bounded backpressure")
    func userOperationQueueAppliesBoundedBackpressure() async {
        let harness = makeStoreHarness()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: [makeTorrent(id: "alpha")]
        ))
        await harness.store.refreshNow()

        for _ in 0..<80 {
            harness.store.pauseTorrent(id: "alpha")
        }

        #expect(harness.store.lastError == TorrentStoreError.tooManyPendingOperations.localizedDescription)
        await harness.store.saveAll()
        #expect(await harness.engine.pausedIDs.count == 64)

        harness.store.pauseTorrent(id: "alpha")
        await harness.store.saveAll()
        #expect(await harness.engine.pausedIDs.count == 65)
        #expect(harness.store.lastError == nil)
    }


    @Test("Torrent Info mutations share FIFO ordering with list commands")
    func torrentInfoMutationsShareFIFOOrdering() async throws {
        let harness = makeStoreHarness()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: [makeTorrent(id: "alpha")]
        ))
        await harness.store.refreshNow()
        await harness.engine.suspendNextRemove()
        harness.store.removeTorrent(id: "alpha", deleteFiles: false)
        await harness.engine.waitForSuspendedRemove()

        let mutation = Task { @MainActor in
            try await harness.store.setFilePriority(for: "alpha", fileIndex: 3, priority: .skip)
        }
        await Task.yield()
        #expect(await harness.engine.filePriorityUpdates.isEmpty)

        await harness.engine.resumeSuspendedRemoves()
        try await mutation.value
        await harness.store.saveAll()
        #expect(await harness.engine.filePriorityUpdates.map(\.fileIndex) == [3])
    }

    @Test("Cancelling a queued Torrent Info mutation removes it from the FIFO")
    func cancellingQueuedTorrentInfoMutationRemovesIt() async {
        let harness = makeStoreHarness()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: [makeTorrent(id: "alpha")]
        ))
        await harness.store.refreshNow()
        await harness.engine.suspendNextRemove()
        harness.store.removeTorrent(id: "alpha", deleteFiles: false)
        await harness.engine.waitForSuspendedRemove()

        let mutation = Task { @MainActor in
            try await harness.store.setFilePriority(
                for: "alpha",
                fileIndex: 3,
                priority: .skip
            )
        }
        await Task.yield()
        mutation.cancel()

        await #expect(throws: CancellationError.self) {
            try await mutation.value
        }
        await harness.engine.resumeSuspendedRemoves()
        await harness.store.saveAll()

        #expect(await harness.engine.filePriorityUpdates.isEmpty)
    }


    @Test("Save drains an urgent network block before a later unblock")
    func saveDrainsNetworkSecurityBarrierBeforeLaterUnblock() async {
        let harness = makeStoreHarness()
        await harness.engine.suspendNextNetworkBlock()
        var restricted = harness.store.settings
        restricted.requireNetworkInterface = true
        restricted.requiredNetworkInterfaceName = "utun-missing"
        harness.store.updateSettings(restricted)
        await harness.engine.waitForSuspendedNetworkBlock()

        var relaxed = restricted
        relaxed.requireNetworkInterface = false
        harness.store.updateSettings(relaxed)
        let save = Task { @MainActor in
            await harness.store.saveAll()
        }
        await Task.yield()

        #expect(await harness.engine.saveAllCount == 0)
        #expect(await harness.engine.appliedSettings.isEmpty)

        await harness.engine.resumeSuspendedNetworkBlocks()
        await save.value

        #expect(await harness.engine.appliedSettings.last?.networkBlocked == false)
        #expect(await harness.engine.saveAllCount == 1)
    }

    @Test("A preempted network block replaces the isolated controller automatically")
    func preemptedNetworkBlockReplacesController() async {
        let interfaces = [
            NetworkInterfaceOption(
                name: "utun1",
                displayName: "First VPN",
                fingerprint: "first-vpn",
                vpnServiceID: "first-service",
                vpnServiceName: "First VPN",
                isLikelyVPN: true
            ),
            NetworkInterfaceOption(
                name: "utun2",
                displayName: "Second VPN",
                fingerprint: "second-vpn",
                vpnServiceID: "second-service",
                vpnServiceName: "Second VPN",
                isLikelyVPN: true
            ),
        ]
        let harness = makeStoreHarness(networkInterfaces: interfaces)
        var initialBinding = harness.store.settings
        initialBinding.requireNetworkInterface = true
        initialBinding.requiredNetworkInterfaceName = "utun1"
        harness.store.updateSettings(initialBinding)
        await harness.store.saveAll()
        await harness.engine.suspendNextSnapshotBatchCall()
        let inFlightRefresh = Task { @MainActor in
            await harness.store.refreshNow()
        }
        await harness.engine.waitForSuspendedSnapshotBatchCall()

        let replacementEngine = FakeTorrentEngine()
        await replacementEngine.setNetworkInterfaceSnapshot(
            TorrentNetworkInterfaceSnapshot(revision: 1, interfaces: interfaces)
        )
        let replacementCount = Mutex(0)
        defer {
            TorrentStore.engineStartupFactoryOverride.withLock { $0 = nil }
        }
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { _ in
                replacementCount.withLock { $0 += 1 }
                return replacementEngine
            }
        }
        await harness.engine.requireControllerReplacementOnNextNetworkBlock()
        let expectedNetworkBlockCount = await harness.engine.blockNetworkCount + 1

        var changedBinding = harness.store.settings
        changedBinding.requiredNetworkInterfaceName = "utun2"
        harness.store.updateSettings(changedBinding)
        await harness.engine.waitForNetworkBlockCount(expectedNetworkBlockCount)

        let replacementSave = Task { @MainActor in
            await harness.store.saveAll()
        }
        let replacementClock = ContinuousClock()
        let replacementDeadline = replacementClock.now.advanced(by: .seconds(1))
        while replacementCount.withLock({ $0 }) == 0,
              replacementClock.now < replacementDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let replacementStartedWithStaleRefresh = replacementCount.withLock { $0 } == 1
        await replacementSave.value

        var pluginChanged = harness.store.settings
        pluginChanged.enablePeerExchangePlugin.toggle()
        harness.store.updateSettings(pluginChanged)
        let restartSave = Task { @MainActor in
            await harness.store.saveAll()
        }
        let restartClock = ContinuousClock()
        let restartDeadline = restartClock.now.advanced(by: .seconds(1))
        while await replacementEngine.restartCount == 0,
              restartClock.now < restartDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let replacementRestartedWithStaleRefresh = await replacementEngine.restartCount == 1

        await harness.engine.resumeSuspendedSnapshotBatchCalls()
        await inFlightRefresh.value
        await restartSave.value

        #expect(replacementStartedWithStaleRefresh)
        #expect(replacementRestartedWithStaleRefresh)
        #expect(replacementCount.withLock { $0 } == 1)
        #expect(!harness.engine.isAvailable)
        #expect(harness.store.engineAvailable)
        #expect(await replacementEngine.appliedSettings.last?.networkBlocked == false)
        #expect(await replacementEngine.appliedSettings.last?.settings.requiredNetworkInterfaceName == "utun2")
        #expect(await replacementEngine.saveAllCount == 2)
        #expect(harness.store.lastError != "The isolated torrent engine connection ended safely.")
    }

    @Test("A magnet queued behind replacement containment runs only after replacement synchronization")
    func queuedMagnetRunsOnlyOnSynchronizedReplacement() async {
        let vpn = NetworkInterfaceOption(
            name: "utun4",
            displayName: "ProtonVPN",
            fingerprint: "vpn-fingerprint",
            vpnServiceID: "proton-service",
            vpnServiceName: "ProtonVPN",
            isLikelyVPN: true
        )
        let harness = makeStoreHarness(networkInterfaces: [vpn])
        let replacementEngine = FakeTorrentEngine(
            networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                revision: 1,
                interfaces: [vpn]
            ),
            suspendsInitialSnapshotBatch: true
        )
        let replacementCount = Mutex(0)
        defer {
            TorrentStore.engineStartupFactoryOverride.withLock { $0 = nil }
        }
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { _ in
                replacementCount.withLock { $0 += 1 }
                return replacementEngine
            }
        }
        await harness.engine.requireControllerReplacementOnNextNetworkBlock()
        await harness.engine.suspendNextNetworkBlock()

        var settings = harness.store.settings
        settings.requireNetworkInterface = true
        settings.requiredNetworkInterfaceName = vpn.name
        harness.store.updateSettings(settings)
        await harness.engine.waitForSuspendedNetworkBlock()

        let accepted = harness.store.addMagnet(
            "magnet:?xt=urn:btih:replacement",
            savePath: "/Downloads"
        )
        #expect(accepted)
        await harness.engine.resumeSuspendedNetworkBlocks()
        await replacementEngine.waitForSuspendedSnapshotBatchCall()

        #expect(await harness.engine.addedMagnets.isEmpty)
        #expect(await replacementEngine.addedMagnets.isEmpty)
        #expect(await replacementEngine.appliedSettings.isEmpty)

        await replacementEngine.resumeSuspendedSnapshotBatchCalls()
        await harness.store.saveAll()

        #expect(replacementCount.withLock { $0 } == 1)
        #expect(await harness.engine.addedMagnets.isEmpty)
        #expect(await replacementEngine.addedMagnets.map(\.magnet) == [
            "magnet:?xt=urn:btih:replacement"
        ])
        #expect(await replacementEngine.operations == [
            .applySettings(dhtEnabled: true, networkBlocked: false),
            .addMagnet(appliedDHTEnabled: true, networkBlocked: false),
        ])
    }

    @Test("Replacement startup failure resolves a queued async operation")
    func replacementStartupFailureResolvesQueuedAsyncOperation() async {
        let harness = makeStoreHarness()
        let replacementCount = Mutex(0)
        let operationStarted = Mutex(false)
        let operationOutcome = Mutex<String?>(nil)
        defer {
            TorrentStore.engineStartupFactoryOverride.withLock { $0 = nil }
        }
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { _ in
                replacementCount.withLock { $0 += 1 }
                throw FakeBookmarkError()
            }
        }
        await harness.engine.requireControllerReplacementOnNextNetworkBlock()
        await harness.engine.suspendNextNetworkBlock()

        var restricted = harness.store.settings
        restricted.requireNetworkInterface = true
        restricted.requiredNetworkInterfaceName = "utun-missing"
        harness.store.updateSettings(restricted)
        await harness.engine.waitForSuspendedNetworkBlock()

        let queuedOperation = Task { @MainActor in
            operationStarted.withLock { $0 = true }
            do {
                try await harness.store.requestSources(for: "alpha")
                operationOutcome.withLock { $0 = "succeeded" }
            } catch {
                operationOutcome.withLock { $0 = error.localizedDescription }
            }
        }
        while !operationStarted.withLock({ $0 }) {
            await Task.yield()
        }
        await Task.yield()
        await harness.engine.resumeSuspendedNetworkBlocks()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while operationOutcome.withLock({ $0 }) == nil,
              clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let resolvedOutcome = operationOutcome.withLock { $0 }
        if resolvedOutcome != nil {
            await queuedOperation.value
        } else {
            queuedOperation.cancel()
        }

        #expect(replacementCount.withLock { $0 } == 1)
        #expect(resolvedOutcome != nil)
        #expect(resolvedOutcome != "succeeded")
        #expect(await harness.engine.requestedSourceIDs.isEmpty)
        #expect(!harness.store.engineAvailable)
    }

    @Test("A recoverable background poll failure replaces the controller")
    func recoverablePollFailureReplacesController() async {
        let harness = makeStoreHarness()
        let replacementEngine = FakeTorrentEngine()
        let replacementCount = Mutex(0)
        defer {
            TorrentStore.engineStartupFactoryOverride.withLock { $0 = nil }
        }
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { _ in
                replacementCount.withLock { $0 += 1 }
                return replacementEngine
            }
        }
        await harness.engine.failNextSnapshotBatchCall(
            recoveryDisposition: .replaceController
        )

        await harness.store.refreshNow(notifiesCompletions: false)
        await harness.store.saveAll()

        #expect(replacementCount.withLock { $0 } == 1)
        #expect(harness.store.engineAvailable)
        #expect(await replacementEngine.appliedSettings.count == 1)
    }

    @Test("A terminal background poll failure is not automatically reconnected")
    func terminalPollFailureDoesNotReconnect() async {
        let harness = makeStoreHarness()
        let replacementCount = Mutex(0)
        defer {
            TorrentStore.engineStartupFactoryOverride.withLock { $0 = nil }
        }
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { _ in
                replacementCount.withLock { $0 += 1 }
                return FakeTorrentEngine()
            }
        }
        await harness.store.refreshNow(notifiesCompletions: false)
        #expect(harness.store.bridgeHealth == .healthy)
        #expect(!harness.store.networkStatus.networkBlocked)
        await harness.engine.failNextSnapshotBatchCall(
            recoveryDisposition: .terminal
        )

        await harness.store.refreshNow(notifiesCompletions: false)

        #expect(replacementCount.withLock { $0 } == 0)
        #expect(!harness.store.engineAvailable)
        #expect(harness.store.bridgeHealth == .unavailable)
        #expect(harness.store.networkStatus == .empty)
    }

    @Test("A terminal containment failure is not automatically reconnected")
    func terminalContainmentFailureDoesNotReconnect() async {
        let vpn = NetworkInterfaceOption(
            name: "utun4",
            displayName: "ProtonVPN",
            fingerprint: "vpn-fingerprint",
            vpnServiceID: "proton-service",
            vpnServiceName: "ProtonVPN",
            isLikelyVPN: true
        )
        let harness = makeStoreHarness(networkInterfaces: [vpn])
        let replacementCount = Mutex(0)
        defer {
            TorrentStore.engineStartupFactoryOverride.withLock { $0 = nil }
        }
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { _ in
                replacementCount.withLock { $0 += 1 }
                return FakeTorrentEngine()
            }
        }
        await harness.engine.requireControllerReplacementOnNextNetworkBlock(
            recoveryDisposition: .terminal
        )
        var settings = harness.store.settings
        settings.requireNetworkInterface = true
        settings.requiredNetworkInterfaceName = vpn.name

        harness.store.updateSettings(settings)
        await harness.store.saveAll()

        #expect(await harness.engine.blockNetworkCount == 1)
        #expect(replacementCount.withLock { $0 } == 0)
        #expect(!harness.store.engineAvailable)
    }

    @Test("A terminal containment error overrides a replaceable published lifecycle")
    func terminalContainmentErrorDominatesPublishedRecovery() async {
        let vpn = NetworkInterfaceOption(
            name: "utun4",
            displayName: "ProtonVPN",
            fingerprint: "vpn-fingerprint",
            vpnServiceID: "proton-service",
            vpnServiceName: "ProtonVPN",
            isLikelyVPN: true
        )
        let harness = makeStoreHarness(networkInterfaces: [vpn])
        let replacementCount = Mutex(0)
        defer {
            TorrentStore.engineStartupFactoryOverride.withLock { $0 = nil }
        }
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { _ in
                replacementCount.withLock { $0 += 1 }
                return FakeTorrentEngine()
            }
        }
        await harness.engine.setRecoveryDisposition(.replaceController)
        await harness.engine.setNextNetworkBlockError(
            TorrentEngineClientError.serviceRejected("Rejected by the service.")
        )

        var settings = harness.store.settings
        settings.requireNetworkInterface = true
        settings.requiredNetworkInterfaceName = vpn.name
        harness.store.updateSettings(settings)
        await harness.store.saveAll()

        #expect(await harness.engine.blockNetworkCount == 1)
        #expect(harness.engine.recoveryDisposition == .terminal)
        #expect(replacementCount.withLock { $0 } == 0)
        #expect(!harness.store.engineAvailable)
        #expect(harness.store.lastError == "Rejected by the service.")
    }

    @Test("Controller replacement does not await a cancellation-insensitive refresh task")
    func controllerReplacementDoesNotAwaitStaleRefreshTask() async {
        let harness = makeStoreHarness(startsTasks: true, keepsWakeStreamOpen: true)
        await harness.store.saveAll()
        await harness.engine.waitForOpenWakeStream()
        await harness.engine.suspendNextSnapshotBatchCall()
        await harness.engine.emitWake()
        await harness.engine.waitForSuspendedSnapshotBatchCall()

        let replacementEngine = FakeTorrentEngine()
        let replacementCount = Mutex(0)
        defer {
            TorrentStore.engineStartupFactoryOverride.withLock { $0 = nil }
        }
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { _ in
                replacementCount.withLock { $0 += 1 }
                return replacementEngine
            }
        }
        await harness.engine.requireControllerReplacementOnNextNetworkBlock()
        let expectedNetworkBlockCount = await harness.engine.blockNetworkCount + 1

        var restricted = harness.store.settings
        restricted.requireNetworkInterface = true
        restricted.requiredNetworkInterfaceName = "utun-missing"
        harness.store.updateSettings(restricted)
        await harness.engine.waitForNetworkBlockCount(expectedNetworkBlockCount)
        let save = Task { @MainActor in
            await harness.store.saveAll()
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while replacementCount.withLock({ $0 }) == 0,
              clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let replacementStartedBeforeRefreshUnwound = replacementCount.withLock { $0 } == 1

        await harness.engine.resumeSuspendedSnapshotBatchCalls()
        await save.value

        #expect(replacementStartedBeforeRefreshUnwound)
        #expect(!harness.engine.isAvailable)
        #expect(harness.store.engineAvailable)
        #expect(await replacementEngine.appliedSettings.last?.networkBlocked == true)
    }

    @Test("An unconfirmed network block terminates and replaces an available engine")
    func failedNetworkBlockTerminatesAvailableEngine() async {
        let harness = makeStoreHarness()
        let replacementEngine = FakeTorrentEngine()
        let replacementCount = Mutex(0)
        defer {
            TorrentStore.engineStartupFactoryOverride.withLock { $0 = nil }
        }
        TorrentStore.engineStartupFactoryOverride.withLock { factory in
            factory = { _ in
                replacementCount.withLock { $0 += 1 }
                return replacementEngine
            }
        }
        await harness.engine.setNextNetworkBlockError(FakeBookmarkError())

        var restricted = harness.store.settings
        restricted.requireNetworkInterface = true
        restricted.requiredNetworkInterfaceName = "utun-missing"
        harness.store.updateSettings(restricted)
        await harness.store.saveAll()

        #expect(replacementCount.withLock { $0 } == 1)
        #expect(!harness.engine.isAvailable)
        #expect(harness.store.engineAvailable)
        #expect(await replacementEngine.appliedSettings.last?.networkBlocked == true)
        #expect(await replacementEngine.appliedSettings.last?.settings.requiredNetworkInterfaceName == "utun-missing")
        #expect(harness.store.lastError == nil)
    }

    @Test("Pending settings applications coalesce to latest values")
    func pendingSettingsApplicationsCoalesceToLatestValues() async throws {
        let suiteName = "app.torrent7.operation-queue.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let harness = makeStoreHarness(defaultsDomain: .suite(suiteName))

        for rateLimit in 1...20 {
            var settings = harness.store.settings
            settings.downloadRateLimitKBps = rateLimit
            harness.store.updateSettings(settings)
        }
        await harness.store.saveAll()

        #expect(await harness.engine.appliedSettings.count == 1)
        #expect(await harness.engine.appliedSettings.first?.settings.downloadRateLimitKBps == 20)
    }

    @Test("Settings retain FIFO order at pending user-operation capacity")
    func settingsRetainFIFOOrderAtPendingUserOperationCapacity() async throws {
        let suiteName = "app.torrent7.operation-queue-order.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let harness = makeStoreHarness(defaultsDomain: .suite(suiteName))
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: [makeTorrent(id: "alpha")]
        ))
        await harness.store.refreshNow()

        await harness.engine.suspendNextRemove()
        harness.store.removeTorrent(id: "alpha", deleteFiles: false)
        await harness.engine.waitForSuspendedRemove()

        var restrictedSettings = harness.store.settings
        restrictedSettings.enableDHTNetwork = false
        harness.store.updateSettings(restrictedSettings)
        harness.store.addMagnet(
            "magnet:?xt=urn:btih:abc",
            savePath: "/Downloads",
            allowPreMetadataDHT: true
        )
        for _ in 0..<63 {
            harness.store.pauseTorrent(id: "alpha")
        }

        var relaxedSettings = harness.store.settings
        relaxedSettings.enableDHTNetwork = true
        relaxedSettings.requireNetworkInterface = true
        relaxedSettings.requiredNetworkInterfaceName = "utun-missing"
        harness.store.updateSettings(relaxedSettings)
        await harness.engine.waitForNetworkBlock()

        await harness.engine.resumeSuspendedRemoves()
        await harness.store.saveAll()

        #expect(await harness.engine.operations == [
            .applySettings(dhtEnabled: false, networkBlocked: true),
            .addMagnet(appliedDHTEnabled: false, networkBlocked: true),
            .applySettings(dhtEnabled: true, networkBlocked: true)
        ])
        #expect(await harness.engine.pauseAppliedDHTValues.count == 63)
        #expect(await harness.engine.pauseAppliedDHTValues.allSatisfy { $0 == false })
        #expect(await harness.engine.pauseNetworkBlockedValues.allSatisfy { $0 })
    }

    @Test("Open wake stream does not retain store")
    func openWakeStreamDoesNotRetainStore() async throws {
        var harness: StoreHarness? = makeStoreHarness(
            startsTasks: true,
            keepsWakeStreamOpen: true
        )
        let engine = try #require(harness?.engine)
        await engine.waitForOpenWakeStream()
        await harness?.store.saveAll()

        weak let weakStore = harness?.store
        harness = nil
        for _ in 0..<20 where weakStore != nil {
            await Task.yield()
        }

        #expect(weakStore == nil)
        await engine.finishWakeStream()
    }
}

@MainActor
private struct StoreHarness {
    let store: TorrentStore
    let engine: FakeTorrentEngine
    let dock: RecordingDockTileService
    let sleep: RecordingSleepPreventionService
    let history: RecordingCompletionHistoryStore
    let notifications: RecordingNotificationService
    let accessStore: RecordingDownloadFolderAccessStore
    let fileLocationService: RecordingTorrentFileLocationService
    let storageClaimJournal: TorrentStorageClaimJournal?
}

@MainActor
private func makeStoreHarness(
    settings: TorrentSettings = TorrentSettings(),
    sortOrder: TorrentSortOrder = .name,
    sortDirection: TorrentSortDirection = .ascending,
    defaultsDomain: TorrentDefaultsDomain = .standard,
    initialLabels: [TorrentLabel] = [],
    initialLabelAssignments: [
        TorrentItem.ID: Set<TorrentLabel.ID>
    ] = [:],
    networkInterfaces: [NetworkInterfaceOption] = [],
    networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot? = nil,
    initialSnapshotBatch: TorrentSnapshotBatch? = nil,
    initialPauseError: Error? = nil,
    startsTasks: Bool = false,
    keepsWakeStreamOpen: Bool = false,
    suspendsInitialSnapshotBatch: Bool = false,
    storageClaimJournal: TorrentStorageClaimJournal? = nil
) -> StoreHarness {
    let engine = FakeTorrentEngine(
        keepsWakeStreamOpen: keepsWakeStreamOpen,
        networkInterfaceSnapshot: networkInterfaceSnapshot,
        suspendsInitialSnapshotBatch: suspendsInitialSnapshotBatch,
        initialSnapshotBatch: initialSnapshotBatch,
        initialPauseError: initialPauseError
    )
    let dock = RecordingDockTileService()
    let notifications = RecordingNotificationService()
    let history = RecordingCompletionHistoryStore()
    let notifier = TorrentCompletionNotifier(
        history: history,
        notificationService: notifications,
        dockTileService: dock,
        activationProvider: FixedApplicationActivationProvider(isApplicationActive: false)
    )
    let sleep = RecordingSleepPreventionService()
    let accessStore = RecordingDownloadFolderAccessStore()
    let fileLocationService = RecordingTorrentFileLocationService()
    let store = TorrentStore(
        settings: settings,
        sortOrder: sortOrder,
        sortDirection: sortDirection,
        engine: engine,
        dockTileService: dock,
        completionNotifier: notifier,
        sleepPreventionService: sleep,
        downloadFolderAccessStore: accessStore,
        fileLocationService: fileLocationService,
        defaultsDomain: defaultsDomain,
        storageClaimJournal: storageClaimJournal,
        initialLabels: initialLabels,
        initialLabelAssignments: initialLabelAssignments,
        networkInterfaces: networkInterfaces,
        startsTasks: startsTasks
    )
    return StoreHarness(
        store: store,
        engine: engine,
        dock: dock,
        sleep: sleep,
        history: history,
        notifications: notifications,
        accessStore: accessStore,
        fileLocationService: fileLocationService,
        storageClaimJournal: storageClaimJournal
    )
}

@MainActor
private func withKnownTorrentHarness<Result>(
    defaultsDomain: TorrentDefaultsDomain = .standard,
    _ body: @MainActor (
        _ harness: StoreHarness,
        _ downloadFolder: URL
    ) async throws -> Result
) async throws -> Result {
    try await withTemporaryDirectory { root in
        let downloadFolder = root.appending(
            path: "Downloads",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: downloadFolder,
            withIntermediateDirectories: true
        )
        let journal = try TorrentStorageClaimJournal(
            directory: root.appending(path: "Journal", directoryHint: .isDirectory)
        )
        let harness = makeStoreHarness(
            defaultsDomain: defaultsDomain,
            storageClaimJournal: journal
        )
        return try await body(harness, downloadFolder)
    }
}

private func validSingleFileTorrentData() -> Data {
    var data = Data(
        "d4:infod6:lengthi4e4:name10:sample.bin12:piece lengthi16384e6:pieces20:".utf8
    )
    data.append(Data(repeating: 0, count: 20))
    data.append(contentsOf: Data("ee".utf8))
    return data
}

private struct MagnetPromotionFixture {
    let torrentID: String
    let magnet: String
    let exactInfoDictionary: Data
}

private func magnetPromotionFixture() throws -> MagnetPromotionFixture {
    let parsed = try TorrentManifestParser().parse(validSingleFileTorrentData())
    let v1 = try #require(parsed.manifest.infoHashes.v1)
    let alphabet = Array("0123456789abcdef".utf8)
    var encoded = [UInt8]()
    encoded.reserveCapacity(v1.count * 2)
    for byte in v1 {
        encoded.append(alphabet[Int(byte >> 4)])
        encoded.append(alphabet[Int(byte & 0x0f)])
    }
    let hash = String(decoding: encoded, as: UTF8.self)
    return MagnetPromotionFixture(
        torrentID: "t:\(String(repeating: "c", count: 32))",
        magnet: "magnet:?xt=urn:btih:\(hash)&tr=https%3A%2F%2Ftracker.example%2Fannounce",
        exactInfoDictionary: parsed.rawInfoDictionary
    )
}
