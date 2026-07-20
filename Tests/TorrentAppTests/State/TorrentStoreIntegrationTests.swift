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
            factory = { _, _ in
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

    @Test("Detached startup installs the engine and applies current settings with fresh capabilities")
    func detachedStartupInstallsEngineAndAppliesCurrentSettingsWithFreshCapabilities() async throws {
        struct StartupCapture: Sendable {
            var didEnter = false
            var ranOffMainThread = false
            var enablePeerExchangePlugin = false
            var authorizedSavePaths = [String]()
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
            factory = { enablePeerExchangePlugin, authorizedSavePaths in
                capture.withLock { state in
                    state.didEnter = true
                    state.ranOffMainThread = !Thread.isMainThread
                    state.enablePeerExchangePlugin = enablePeerExchangePlugin
                    state.authorizedSavePaths = authorizedSavePaths
                }
                releaseStartup.wait()
                return installedEngine
            }
        }

        var startupAccess: FakeDownloadFolderAccess? = FakeDownloadFolderAccess(
            url: URL(filePath: "/Downloads/Initial", directoryHint: .isDirectory)
        )
        weak var weakStartupAccess: FakeDownloadFolderAccess?
        weakStartupAccess = startupAccess
        harness.accessStore.capabilityAdditionalAccesses = [try #require(startupAccess)]
        harness.store.startProductionEngine(
            enablePeerExchangePlugin: true
        )
        while !capture.withLock({ $0.didEnter }) {
            await Task.yield()
        }

        let settingsBeforeBlockedRestore = harness.store.settings
        let folderChange = harness.store.chooseDownloadFolder(
            URL(filePath: "/Downloads/Blocked", directoryHint: .isDirectory)
        )
        harness.store.restoreDefaultSettings()

        #expect(isFolderAuthorityChangeInProgress(folderChange))
        #expect(harness.accessStore.setDefaultCalls.isEmpty)
        #expect(harness.accessStore.clearDefaultCalls.isEmpty)
        #expect(harness.store.settings == settingsBeforeBlockedRestore)

        harness.accessStore.capabilityAdditionalAccesses = []
        startupAccess = nil
        #expect(weakStartupAccess != nil)

        harness.accessStore.setCapabilityPaths(["/Downloads/AddedAfterLaunch"])
        var currentSettings = harness.store.settings
        currentSettings.enablePeerExchangePlugin = false
        harness.store.updateSettings(currentSettings)
        releaseStartup.signal()

        await harness.store.saveAll()

        #expect(capture.withLock { $0.enablePeerExchangePlugin })
        #expect(capture.withLock { $0.ranOffMainThread })
        #expect(capture.withLock { $0.authorizedSavePaths } == ["/Downloads/Initial"])
        #expect(await harness.engine.shutdownCount == 1)
        #expect(harness.store.settings == TorrentSettings())
        #expect(harness.store.downloadFolder == nil)
        #expect(harness.accessStore.clearDefaultCalls.count == 1)
        #expect(await installedEngine.appliedSettings.last?.settings.enablePeerExchangePlugin == true)
        #expect(await installedEngine.restartAuthorizedSavePathSnapshots.isEmpty)
        #expect(weakStartupAccess == nil)
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
            factory = { _, _ in
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

    @Test("Refresh replaces pruned folder authorizations exactly once")
    func refreshReconcilesPrunedFolderAuthorizationsWithoutRedundantReplacement() async {
        let retainedPath = "/Downloads/Retained"
        let prunedPath = "/Downloads/Pruned"
        let harness = makeStoreHarness(
            initialFolderCapabilityPaths: [retainedPath, prunedPath],
            mirrorsFolderCapabilityMutations: true
        )
        let retained = makeTorrent(id: "alpha", savePath: retainedPath)
        let pruned = makeTorrent(id: "beta", savePath: prunedPath)
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: [retained, pruned]
        ))

        await harness.store.refreshNow()

        #expect(await harness.engine.reconciledFolderAuthorizationSnapshots.isEmpty)

        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 2,
            torrents: [retained]
        ))
        await harness.store.refreshNow()
        await harness.store.refreshNow()

        #expect(await harness.engine.reconciledFolderAuthorizationSnapshots == [[
            expectedFolderAuthorization(for: retainedPath),
        ]])
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

    @Test("Stale refresh does not drop tracker host updates")
    func staleRefreshDoesNotDropTrackerHostUpdates() async {
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

        let staleRefresh = Task { @MainActor in
            await harness.store.refreshNow()
        }
        await harness.engine.waitForSuspendedTrackerHostBatchCall()

        await harness.store.refreshNow()
        #expect(harness.store.trackerHosts(for: "alpha") == ["new.example.org"])

        await harness.engine.resumeSuspendedTrackerHostBatchCalls()
        await staleRefresh.value

        #expect(harness.store.trackerHosts(for: "alpha") == ["new.example.org"])
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
        #expect(await harness.engine.addedMagnets.first?.savePath == "/Downloads")
        #expect(await harness.engine.addedMagnets.first?.startsPaused == true)
        #expect(await harness.engine.addedMagnets.first?.queuePriority == .normal)
        #expect(await harness.engine.addedMagnets.first?.enablePeerExchange == false)
        #expect(await harness.engine.addedMagnets.first?.allowNonHTTPSTrackers == false)
        #expect(await harness.engine.addedMagnets.first?.allowNonHTTPSWebSeeds == false)
        #expect(await harness.engine.addedMagnets.first?.allowPreMetadataDHT == false)
        #expect(harness.store.torrents.map(\.id) == ["alpha"])
    }

    @Test("A prepared folder delegates only its transient transfer bookmark")
    func preparedFolderDelegatesTransientBookmark() async {
        let harness = makeStoreHarness()
        let folder = URL(filePath: "/Downloads/Delegated", directoryHint: .isDirectory)

        let accepted = harness.store.addMagnet(
            "magnet:?xt=urn:btih:abc",
            downloadFolder: folder,
            setsDownloadFolderAsDefault: true
        )
        await harness.store.saveAll()

        #expect(accepted)
        let authorization = await harness.engine.delegatedFolderAuthorizations.first
        #expect(authorization?.path == folder.torrentFilePath)
        #expect(authorization?.bookmarkData == Data("delegation:\(folder.torrentFilePath)".utf8))
        #expect(authorization?.bookmarkData != Data(folder.torrentFilePath.utf8))
    }

    @Test("A successful prepared add reconciles authority without waiting for a snapshot")
    func preparedAddImmediatelyReconcilesFolderAuthority() async {
        let oldPath = "/Downloads/Old"
        let folder = URL(filePath: "/Downloads/New", directoryHint: .isDirectory)
        let harness = makeStoreHarness(
            initialFolderCapabilityPaths: [oldPath],
            mirrorsFolderCapabilityMutations: true
        )

        let accepted = harness.store.addMagnet(
            "magnet:?xt=urn:btih:abc",
            downloadFolder: folder,
            setsDownloadFolderAsDefault: true
        )
        await harness.store.saveAll()

        #expect(accepted)
        #expect(await harness.engine.reconciledFolderAuthorizationSnapshots == [[
            expectedFolderAuthorization(for: folder.torrentFilePath),
        ]])
    }

    @Test("Refresh cannot revoke a provisional folder during an add")
    func refreshDoesNotRacePreparedFolderTransaction() async {
        let folder = URL(filePath: "/Downloads/New", directoryHint: .isDirectory)
        let harness = makeStoreHarness(
            initialFolderCapabilityPaths: ["/Downloads/Old"],
            mirrorsFolderCapabilityMutations: true
        )
        await harness.engine.suspendNextAddMagnet()

        let accepted = harness.store.addMagnet(
            "magnet:?xt=urn:btih:abc",
            downloadFolder: folder,
            setsDownloadFolderAsDefault: true
        )
        await harness.engine.waitForSuspendedAddMagnet()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: []
        ))
        await harness.store.refreshNow()

        #expect(await harness.engine.reconciledFolderAuthorizationSnapshots.isEmpty)

        await harness.engine.resumeSuspendedAddMagnets()
        await harness.store.saveAll()

        #expect(accepted)
        #expect(await harness.engine.reconciledFolderAuthorizationSnapshots == [[
            expectedFolderAuthorization(for: folder.torrentFilePath),
        ]])
    }

    @Test("A poll captured before a prepared add cannot prune its committed folder")
    func stalePollCannotPrunePreparedFolderCommit() async {
        let folder = URL(filePath: "/Downloads/New", directoryHint: .isDirectory)
        let harness = makeStoreHarness(mirrorsFolderCapabilityMutations: true)
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: []))
        await harness.engine.suspendNextSnapshotBatchCall()

        let staleRefresh = Task { @MainActor in
            await harness.store.refreshNow()
        }
        await harness.engine.waitForSuspendedSnapshotBatchCall()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 2,
            torrents: [makeTorrent(id: "alpha", savePath: folder.torrentFilePath)]
        ))
        await harness.engine.suspendNextFolderReconciliation()

        let accepted = harness.store.addMagnet(
            "magnet:?xt=urn:btih:abc",
            downloadFolder: folder,
            setsDownloadFolderAsDefault: false
        )
        await harness.engine.waitForSuspendedFolderReconciliation()
        await harness.engine.resumeSuspendedSnapshotBatchCalls()
        await staleRefresh.value

        #expect(accepted)
        #expect(harness.accessStore.capabilitySnapshot.paths == [folder.torrentFilePath])

        await harness.engine.resumeSuspendedFolderReconciliations()
        await harness.store.saveAll()
        #expect(harness.accessStore.capabilitySnapshot.paths == [folder.torrentFilePath])
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

    @Test("Changing the default folder replaces the exact authorization set only when needed")
    func changingDefaultFolderReconcilesExactAuthorizationsWithoutRedundantReplacement() async throws {
        let harness = makeStoreHarness(mirrorsFolderCapabilityMutations: true)
        let firstFolder = URL(filePath: "/Downloads/First", directoryHint: .isDirectory)
        let secondFolder = URL(filePath: "/Downloads/Second", directoryHint: .isDirectory)

        try harness.store.chooseDownloadFolder(firstFolder).get()
        await harness.store.saveAll()
        try harness.store.chooseDownloadFolder(firstFolder).get()
        await harness.store.saveAll()
        try harness.store.chooseDownloadFolder(secondFolder).get()
        await harness.store.saveAll()

        #expect(await harness.engine.reconciledFolderAuthorizationSnapshots == [
            [expectedFolderAuthorization(for: firstFolder.torrentFilePath)],
            [expectedFolderAuthorization(for: secondFolder.torrentFilePath)],
        ])
    }

    @Test("A local bookmark failure closes the engine instead of retaining stale folder authority")
    func localBookmarkFailureContainsStaleFolderAuthority() async throws {
        let harness = makeStoreHarness(mirrorsFolderCapabilityMutations: true)
        harness.accessStore.nextCapabilityDelegationBookmarkError = FakeBookmarkError()

        try harness.store.chooseDownloadFolder(
            URL(filePath: "/Downloads/Unencodable", directoryHint: .isDirectory)
        ).get()
        await harness.store.saveAll()

        #expect(!harness.engine.isAvailable)
        #expect(await harness.engine.shutdownCount == 1)
        #expect(!harness.store.engineAvailable)
        #expect(await harness.engine.reconciledFolderAuthorizationSnapshots.isEmpty)
    }

    @Test("Folder reconciliation converges when authority changes during replacement")
    func folderReconciliationConvergesAcrossSuspension() async throws {
        let firstFolder = URL(filePath: "/Downloads/First", directoryHint: .isDirectory)
        let secondFolder = URL(filePath: "/Downloads/Second", directoryHint: .isDirectory)
        let harness = makeStoreHarness(mirrorsFolderCapabilityMutations: true)

        await harness.engine.suspendNextFolderReconciliation()
        try harness.store.chooseDownloadFolder(firstFolder).get()
        await harness.engine.waitForSuspendedFolderReconciliation()

        try harness.store.chooseDownloadFolder(secondFolder).get()
        await harness.engine.resumeSuspendedFolderReconciliations()
        await harness.store.saveAll()

        #expect(await harness.engine.reconciledFolderAuthorizationSnapshots == [
            [expectedFolderAuthorization(for: firstFolder.torrentFilePath)],
            [expectedFolderAuthorization(for: secondFolder.torrentFilePath)],
        ])
    }

    @Test("Repeated restore requests coalesce and revoke the default folder once")
    func repeatedRestoreRequestsCoalesceAndRevokeDefaultFolderOnce() async throws {
        let harness = makeStoreHarness(mirrorsFolderCapabilityMutations: true)
        let folder = URL(filePath: "/Downloads/Default", directoryHint: .isDirectory)
        try harness.store.chooseDownloadFolder(folder).get()
        await harness.store.saveAll()

        harness.store.restoreDefaultSettings()
        harness.store.restoreDefaultSettings()
        await harness.store.saveAll()

        #expect(harness.accessStore.clearDefaultCalls.count == 1)
        #expect(await harness.engine.reconciledFolderAuthorizationSnapshots == [
            [expectedFolderAuthorization(for: folder.torrentFilePath)],
            [],
        ])
    }

    @Test("Add magnet assigns selected labels to newly registered torrent")
    func addMagnetAssignsSelectedLabelsToNewlyRegisteredTorrent() async throws {
        let suiteName = "app.torrent7.labels.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let harness = makeStoreHarness(defaults: defaults)
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
        let harness = makeStoreHarness(defaults: defaults)
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

    @Test("Add torrent file assigns selected labels to returned torrent ID")
    func addTorrentFileAssignsSelectedLabelsToReturnedTorrentID() async throws {
        let suiteName = "app.torrent7.labels.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let harness = makeStoreHarness(defaults: defaults)
        let label = try #require(harness.store.createLabel(named: "Linux"))
        await harness.engine.setNextAddedTorrentFileID("file-added")
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: [makeTorrent(id: "file-added", name: "Added torrent")]
        ))

        harness.store.addTorrentFile(
            URL(filePath: "/tmp/sample.torrent"),
            torrentData: Data("preview bytes".utf8),
            savePath: "/Downloads",
            labelIDs: [label.id]
        )
        await harness.store.saveAll()

        #expect(harness.store.labelIDs(for: "file-added") == [label.id])
    }

    @Test("Labels can be toggled, renamed, deleted, and pruned")
    func labelsCanBeToggledRenamedDeletedAndPruned() async throws {
        let suiteName = "app.torrent7.labels.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let harness = makeStoreHarness(defaults: defaults)
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [makeTorrent(id: "alpha")]))
        await harness.store.refreshNow()
        let label = try #require(harness.store.createLabel(named: "Linux"))

        harness.store.toggleLabel(label.id, forTorrentIDs: ["alpha"])
        #expect(harness.store.labelIDs(for: "alpha") == [label.id])

        harness.store.renameLabel(id: label.id, to: "Distros")
        #expect(harness.store.labels(for: "alpha").map(\.name) == ["Distros"])

        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 2, torrents: []))
        await harness.store.refreshNow()
        #expect(harness.store.labelIDs(for: "alpha").isEmpty)

        harness.store.deleteLabel(id: label.id)
        #expect(harness.store.labels.isEmpty)
    }

    @Test("Add magnet can pass per-torrent non-HTTPS source exceptions")
    func addMagnetCanPassNonHTTPSSourceExceptions() async {
        let harness = makeStoreHarness()

        harness.store.addMagnet(
            "magnet:?xt=urn:btih:abc",
            savePath: "/Downloads",
            queuePriority: .high,
            allowNonHTTPSTrackers: true,
            allowNonHTTPSWebSeeds: true,
            allowPreMetadataDHT: true
        )
        await harness.store.saveAll()

        #expect(await harness.engine.addedMagnets.first?.queuePriority == .high)
        #expect(await harness.engine.addedMagnets.first?.allowNonHTTPSTrackers == true)
        #expect(await harness.engine.addedMagnets.first?.allowNonHTTPSWebSeeds == true)
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
        let harness = makeStoreHarness()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TorrentAppTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let torrentURL = directory.appending(path: "sample.torrent")
        let previewBytes = Data("preview bytes".utf8)
        let replacedBytes = Data("replaced bytes".utf8)
        try previewBytes.write(to: torrentURL)

        let preview = try await harness.store.previewTorrentFile(torrentURL)
        try replacedBytes.write(to: torrentURL)

        harness.store.addTorrentFile(
            torrentURL,
            torrentData: preview.torrentData,
            savePath: "/Downloads"
        )
        await harness.store.saveAll()

        #expect(await harness.engine.addedTorrentFiles.first?.data == previewBytes)
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

    @Test("Add torrent file forwards file priorities")
    func addTorrentFileForwardsFilePriorities() async {
        let harness = makeStoreHarness()
        let torrentURL = URL(filePath: "/tmp/sample.torrent")
        let priorities: [Int32: TorrentFilePriority] = [
            0: .high,
            1: .skip,
            2: .low
        ]

        harness.store.addTorrentFile(
            torrentURL,
            torrentData: Data("preview bytes".utf8),
            savePath: "/Downloads",
            filePriorities: priorities,
            startsPaused: true,
            queuePriority: .high
        )
        await harness.store.saveAll()

        #expect(await harness.engine.addedTorrentFiles.first?.filePriorities == priorities)
        #expect(await harness.engine.addedTorrentFiles.first?.startsPaused == true)
        #expect(await harness.engine.addedTorrentFiles.first?.queuePriority == .high)
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

    @Test("Removing data delegates deletion to libtorrent under a folder access lease")
    func removingDataDelegatesDeletionToLibtorrentUnderFolderAccessLease() async {
        let harness = makeStoreHarness()
        let torrent = makeTorrent(id: "alpha", name: "Alpha", savePath: "/Downloads", finished: true)
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [torrent]))
        await harness.store.refreshNow()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 2, torrents: []))
        harness.store.selectionState.ids = ["alpha"]

        harness.store.removeTorrents(ids: ["alpha"], deleteFiles: true)
        await harness.store.saveAll()

        #expect(harness.accessStore.leaseCalls == ["/Downloads"])
        #expect(await harness.engine.removed.count == 1)
        #expect(await harness.engine.removed.first?.id == "alpha")
        #expect(await harness.engine.removed.first?.deleteFiles == true)
        #expect(harness.history.forgottenIDs == [["alpha"]])
        #expect(harness.store.selectionState.ids.isEmpty)
    }

    @Test("Removing a torrent without data does not acquire a folder access lease")
    func removingTorrentWithoutDataDoesNotAcquireFolderAccessLease() async {
        let harness = makeStoreHarness()
        let torrent = makeTorrent(id: "alpha", savePath: "/Downloads")
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [torrent]))
        await harness.store.refreshNow()

        harness.store.removeTorrents(ids: ["alpha"], deleteFiles: false)
        await harness.store.saveAll()

        #expect(harness.accessStore.leaseCalls.isEmpty)
        #expect(await harness.engine.removed.count == 1)
        #expect(await harness.engine.removed.first?.deleteFiles == false)
    }

    @Test("Removing a torrent replaces its pruned folder authorization exactly once")
    func removingTorrentReconcilesPrunedFolderAuthorizationWithoutRedundantReplacement() async {
        let retainedPath = "/Downloads/Retained"
        let removedPath = "/Downloads/Removed"
        let harness = makeStoreHarness(
            initialFolderCapabilityPaths: [retainedPath, removedPath],
            mirrorsFolderCapabilityMutations: true
        )
        let retained = makeTorrent(id: "alpha", savePath: retainedPath)
        let removed = makeTorrent(id: "beta", savePath: removedPath)
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: [retained, removed]
        ))
        await harness.store.refreshNow()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 2,
            torrents: [retained]
        ))

        harness.store.removeTorrent(id: removed.id, deleteFiles: false)
        await harness.store.saveAll()
        await harness.store.refreshNow()

        #expect(await harness.engine.removed.map(\.id) == [removed.id])
        #expect(await harness.engine.reconciledFolderAuthorizationSnapshots == [[
            expectedFolderAuthorization(for: retainedPath),
        ]])
    }

    @Test("A missing folder access lease prevents data deletion")
    func missingFolderAccessLeasePreventsDataDeletion() async {
        let harness = makeStoreHarness()
        let torrent = makeTorrent(id: "alpha", savePath: "/Downloads")
        harness.accessStore.leaseResult = .failure(FakeBookmarkError())
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [torrent]))
        await harness.store.refreshNow()

        harness.store.removeTorrents(ids: ["alpha"], deleteFiles: true)
        await harness.store.saveAll()

        #expect(harness.accessStore.leaseCalls == ["/Downloads"])
        #expect(await harness.engine.removed.isEmpty)
        #expect(harness.store.lastError != nil)
    }

    @Test("Folder access lease survives snapshot pruning until terminal deletion")
    func folderAccessLeaseSurvivesSnapshotPruningUntilTerminalDeletion() async throws {
        let harness = makeStoreHarness()
        let torrent = makeTorrent(id: "alpha", savePath: "/Downloads")
        var access: FakeDownloadFolderAccess? = FakeDownloadFolderAccess(
            url: URL(filePath: torrent.savePath, directoryHint: .isDirectory)
        )
        weak let weakAccess = access
        harness.accessStore.leaseResult = .success(DownloadFolderAccessLease(access: try #require(access)))
        access = nil
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [torrent]))
        await harness.store.refreshNow()
        await harness.engine.suspendNextRemove()

        harness.store.removeTorrents(ids: ["alpha"], deleteFiles: true)
        await harness.engine.waitForSuspendedRemove()
        #expect(weakAccess != nil)

        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 2, torrents: []))
        await harness.store.refreshNow()
        #expect(harness.accessStore.pruneCalls.map { $0.map(\.id) } == [["alpha"], []])
        #expect(weakAccess != nil)

        await harness.engine.resumeSuspendedRemoves()
        await harness.store.saveAll()
        #expect(weakAccess == nil)
    }

    @Test("Terminal deletion warning releases access and forgets removed torrent ownership")
    func terminalDeletionWarningReleasesAccessAndForgetsRemovedTorrentOwnership() async throws {
        let harness = makeStoreHarness()
        let torrent = makeTorrent(id: "alpha", savePath: "/Downloads", finished: true)
        var access: FakeDownloadFolderAccess? = FakeDownloadFolderAccess(
            url: URL(filePath: torrent.savePath, directoryHint: .isDirectory)
        )
        weak let weakAccess = access
        harness.accessStore.leaseResult = .success(DownloadFolderAccessLease(access: try #require(access)))
        access = nil
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [torrent]))
        await harness.store.refreshNow()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 2, torrents: []))
        await harness.engine.setRemoveOutcome(.removedWithWarning("Some downloaded files may remain on disk."))
        harness.store.selectionState.ids = ["alpha"]

        harness.store.removeTorrents(ids: ["alpha"], deleteFiles: true)
        await harness.store.saveAll()

        #expect(harness.history.forgottenIDs == [["alpha"]])
        #expect(harness.store.selectionState.ids.isEmpty)
        #expect(harness.store.lastError == "Some downloaded files may remain on disk.")
        #expect(weakAccess == nil)
    }

    @Test("Deletion tracking fault preserves unrelated torrents and folder access")
    func deletionTrackingFaultPreservesUnrelatedTorrentsAndFolderAccess() async throws {
        let harness = makeStoreHarness()
        let removed = makeTorrent(id: "alpha", savePath: "/Downloads/Alpha")
        let retained = makeTorrent(id: "beta", savePath: "/Downloads/Beta")
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [removed, retained]))
        await harness.store.refreshNow()
        await harness.engine.setRemoveOutcome(.removedWithWarning("The torrent engine was stopped safely."))
        await harness.engine.setBecomesUnavailableOnRemove(true)

        harness.store.removeTorrents(ids: [removed.id, retained.id], deleteFiles: true)
        await harness.store.saveAll()
        await harness.store.refreshNow()

        let acceptedID = try #require(await harness.engine.removed.first?.id)
        let retainedID = acceptedID == removed.id ? retained.id : removed.id
        #expect(await harness.engine.removed.count == 1)
        #expect(Set(harness.store.torrents.map(\.id)) == [retainedID])
        #expect(harness.accessStore.pruneCalls.last?.map(\.id) == [retainedID])
        #expect(harness.history.forgottenIDs == [[acceptedID]])
        #expect(harness.store.lastError == "The torrent engine was stopped safely.")
    }

    @Test("Updating settings clears disabled completion badge and applies blocked network policy")
    func updatingSettingsClearsDisabledCompletionBadgeAndAppliesBlockedNetworkPolicy() async throws {
        let suiteName = "app.torrent7.store-settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let harness = makeStoreHarness(defaults: defaults)
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
    func changingPEXPluginSettingRestartsEngine() async throws {
        let harness = makeStoreHarness()
        var restartAccess: FakeDownloadFolderAccess? = FakeDownloadFolderAccess(
            url: URL(filePath: "/Downloads/New", directoryHint: .isDirectory)
        )
        weak var weakRestartAccess: FakeDownloadFolderAccess?
        weakRestartAccess = restartAccess
        harness.accessStore.capabilityAdditionalAccesses = [
            FakeDownloadFolderAccess(url: URL(filePath: "/Downloads/Existing", directoryHint: .isDirectory)),
            try #require(restartAccess)
        ]
        await harness.engine.suspendNextRestart()
        var settings = harness.store.settings
        settings.enablePeerExchangePlugin = false

        harness.store.updateSettings(settings)
        await harness.engine.waitForSuspendedRestart()

        let settingsBeforeBlockedRestore = harness.store.settings
        let folderChange = harness.store.chooseDownloadFolder(
            URL(filePath: "/Downloads/Blocked", directoryHint: .isDirectory)
        )
        harness.store.restoreDefaultSettings()

        #expect(isFolderAuthorityChangeInProgress(folderChange))
        #expect(harness.accessStore.setDefaultCalls.isEmpty)
        #expect(harness.accessStore.clearDefaultCalls.isEmpty)
        #expect(harness.store.settings == settingsBeforeBlockedRestore)

        harness.accessStore.capabilityAdditionalAccesses = []
        restartAccess = nil
        #expect(weakRestartAccess != nil)

        await harness.engine.resumeSuspendedRestarts()
        await harness.store.saveAll()

        #expect(await harness.engine.blockNetworkCount >= 1)
        #expect(await harness.engine.restartPeerExchangePluginValues == [false, true])
        #expect(await harness.engine.restartAuthorizedSavePathSnapshots == [
            ["/Downloads/Existing", "/Downloads/New"],
            [],
        ])
        #expect(harness.store.settings == TorrentSettings())
        #expect(harness.store.downloadFolder == nil)
        #expect(harness.accessStore.clearDefaultCalls.count == 1)
        #expect(await harness.engine.appliedSettings.last?.settings.enablePeerExchangePlugin == true)
        #expect(weakRestartAccess == nil)
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
            factory = { _, _ in
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

    @Test("Rejected add admission does not prepare or commit its folder")
    func rejectedAddAdmissionDoesNotMutateFolderState() async {
        let harness = makeStoreHarness()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(
            revision: 1,
            torrents: [makeTorrent(id: "alpha")]
        ))
        await harness.store.refreshNow()
        await harness.engine.suspendNextRemove()
        harness.store.removeTorrent(id: "alpha", deleteFiles: false)
        await harness.engine.waitForSuspendedRemove()

        for _ in 0..<64 {
            harness.store.pauseTorrent(id: "alpha")
        }
        let folder = URL(filePath: "/Downloads/New", directoryHint: .isDirectory)

        let accepted = harness.store.addMagnet(
            "magnet:?xt=urn:btih:abc",
            downloadFolder: folder,
            setsDownloadFolderAsDefault: true
        )

        #expect(!accepted)
        #expect(harness.accessStore.prepareForAddCalls.isEmpty)
        #expect(harness.accessStore.commitPreparedForAddCalls.isEmpty)
        #expect(harness.accessStore.defaultURL == nil)
        #expect(harness.store.downloadFolder == nil)
        #expect(harness.store.lastError == TorrentStoreError.tooManyPendingOperations.localizedDescription)

        await harness.engine.resumeSuspendedRemoves()
        await harness.store.saveAll()
    }

    @Test("Prepared add retains folder access until the queued engine add completes")
    func preparedAddRetainsFolderAccessThroughQueuedExecution() async throws {
        let harness = makeStoreHarness()
        let folder = URL(filePath: "/Downloads/New", directoryHint: .isDirectory)
        var access: FakeDownloadFolderAccess? = FakeDownloadFolderAccess(url: folder)
        weak let weakAccess = access
        do {
            let retainedAccess = try #require(access)
            harness.accessStore.prepareForAddResult = .success(PreparedDownloadFolder(
                access: retainedAccess,
                defaultURL: folder,
                bookmarkData: try retainedAccess.bookmarkData()
            ))
        }
        access = nil
        await harness.engine.suspendNextAddMagnet()

        let accepted = harness.store.addMagnet(
            "magnet:?xt=urn:btih:abc",
            downloadFolder: folder,
            setsDownloadFolderAsDefault: true
        )
        await harness.engine.waitForSuspendedAddMagnet()

        #expect(accepted)
        #expect(weakAccess != nil)
        #expect(harness.accessStore.commitPreparedForAddCalls.isEmpty)

        let settingsBeforeBlockedRestore = harness.store.settings
        let folderChange = harness.store.chooseDownloadFolder(
            URL(filePath: "/Downloads/Blocked", directoryHint: .isDirectory)
        )
        harness.store.restoreDefaultSettings()

        #expect(isFolderAuthorityChangeInProgress(folderChange))
        #expect(harness.accessStore.setDefaultCalls.isEmpty)
        #expect(harness.accessStore.clearDefaultCalls.isEmpty)
        #expect(harness.store.settings == settingsBeforeBlockedRestore)

        await harness.engine.resumeSuspendedAddMagnets()
        await harness.store.saveAll()
        #expect(harness.accessStore.commitPreparedForAddCalls.count == 1)
        #expect(harness.accessStore.clearDefaultCalls.count == 1)
        #expect(harness.store.downloadFolder == nil)
    }

    @Test("Failed engine add revokes its provisional folder without a local revision change")
    func failedEngineAddDoesNotCommitPreparedFolder() async {
        let harness = makeStoreHarness()
        let folder = URL(filePath: "/Downloads/New", directoryHint: .isDirectory)
        await harness.engine.setAddMagnetError(FakeBookmarkError())

        let accepted = harness.store.addMagnet(
            "magnet:?xt=urn:btih:abc",
            downloadFolder: folder,
            setsDownloadFolderAsDefault: true
        )
        await harness.store.saveAll()

        #expect(accepted)
        #expect(harness.accessStore.prepareForAddCalls.count == 1)
        #expect(harness.accessStore.commitPreparedForAddCalls.isEmpty)
        #expect(harness.accessStore.defaultURL == nil)
        #expect(harness.store.downloadFolder == nil)
        #expect(harness.store.lastError != nil)
        #expect(await harness.engine.reconciledFolderAuthorizationSnapshots == [[]])
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
            factory = { _, _ in
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
            factory = { _, _ in
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
            factory = { _, _ in
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
            factory = { _, _ in
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
            factory = { _, _ in
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
            factory = { _, _ in
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
            factory = { _, _ in
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
            factory = { _, _ in
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
            factory = { _, _ in
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
        let harness = makeStoreHarness(defaults: defaults)

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
        let harness = makeStoreHarness(defaults: defaults)
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
    let accessStore: RecordingDownloadFolderAccessStore
    let fileLocationService: RecordingTorrentFileLocationService
}

@MainActor
private func makeStoreHarness(
    settings: TorrentSettings = TorrentSettings(),
    sortOrder: TorrentSortOrder = .name,
    sortDirection: TorrentSortDirection = .ascending,
    defaults: UserDefaults = .standard,
    networkInterfaces: [NetworkInterfaceOption] = [],
    networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot? = nil,
    startsTasks: Bool = false,
    keepsWakeStreamOpen: Bool = false,
    suspendsInitialSnapshotBatch: Bool = false,
    initialFolderCapabilityPaths: [String] = [],
    mirrorsFolderCapabilityMutations: Bool = false
) -> StoreHarness {
    let engine = FakeTorrentEngine(
        keepsWakeStreamOpen: keepsWakeStreamOpen,
        networkInterfaceSnapshot: networkInterfaceSnapshot,
        suspendsInitialSnapshotBatch: suspendsInitialSnapshotBatch
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
    accessStore.setCapabilityPaths(initialFolderCapabilityPaths)
    accessStore.mirrorsCapabilityMutations = mirrorsFolderCapabilityMutations
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
        defaults: defaults,
        networkInterfaces: networkInterfaces,
        startsTasks: startsTasks
    )
    return StoreHarness(
        store: store,
        engine: engine,
        dock: dock,
        sleep: sleep,
        history: history,
        accessStore: accessStore,
        fileLocationService: fileLocationService
    )
}

private func expectedFolderAuthorization(for path: String) -> TorrentFolderAuthorization {
    TorrentFolderAuthorization(
        path: path,
        bookmarkData: Data("delegation:\(path)".utf8)
    )
}

private func isFolderAuthorityChangeInProgress(_ result: Result<Void, Error>) -> Bool {
    guard case .failure(let error) = result,
          let storeError = error as? TorrentStoreError else {
        return false
    }
    if case .folderAuthorityChangeInProgress = storeError {
        return true
    }
    return false
}
