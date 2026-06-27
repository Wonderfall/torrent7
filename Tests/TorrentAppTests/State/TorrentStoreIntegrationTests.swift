import Foundation
import Testing
import TorrentBridge
@testable import TorrentApp

@MainActor
@Suite("Torrent store integration")
struct TorrentStoreIntegrationTests {
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
        #expect(harness.store.torrents.map(\.id) == ["alpha"])
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
            allowNonHTTPSWebSeeds: true
        )
        await harness.store.saveAll()

        #expect(await harness.engine.addedMagnets.first?.queuePriority == .high)
        #expect(await harness.engine.addedMagnets.first?.allowNonHTTPSTrackers == true)
        #expect(await harness.engine.addedMagnets.first?.allowNonHTTPSWebSeeds == true)
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

    @Test("Removing with trash moves downloaded data and forgets completion ownership")
    func removingWithTrashMovesDownloadedDataAndForgetsCompletionOwnership() async {
        var settings = TorrentSettings()
        settings.moveRemovedDataToTrash = true
        let harness = makeStoreHarness(settings: settings)
        let torrent = makeTorrent(id: "alpha", name: "Alpha", savePath: "/Downloads", finished: true)
        let downloadedURL = URL(filePath: "/Downloads/Alpha")
        harness.fileLocationService.downloadedDataURLs["alpha"] = downloadedURL
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [torrent]))
        await harness.store.refreshNow()
        harness.store.selectionState.ids = ["alpha"]

        harness.store.removeTorrents(ids: ["alpha"], deleteFiles: true)
        await harness.store.saveAll()

        #expect(harness.fileLocationService.trashedURLs == [downloadedURL])
        #expect(await harness.engine.removed.count == 1)
        #expect(await harness.engine.removed.first?.id == "alpha")
        #expect(await harness.engine.removed.first?.deleteFiles == false)
        #expect(await harness.engine.removed.first?.deletePartfile == false)
        #expect(harness.history.forgottenIDs == [["alpha"]])
        #expect(harness.store.selectionState.ids.isEmpty)
    }

    @Test("Removing with delete deletes downloaded data from the app side")
    func removingWithDeleteDeletesDownloadedDataFromTheAppSide() async {
        let harness = makeStoreHarness()
        let torrent = makeTorrent(id: "alpha", name: "Alpha", savePath: "/Downloads", finished: false)
        let downloadedURL = URL(filePath: "/Downloads/Alpha")
        harness.fileLocationService.downloadedDataURLs["alpha"] = downloadedURL
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [torrent]))
        await harness.store.refreshNow()
        harness.store.selectionState.ids = ["alpha"]

        harness.store.removeTorrents(ids: ["alpha"], deleteFiles: true)
        await harness.store.saveAll()

        #expect(harness.fileLocationService.deletedURLs == [downloadedURL])
        #expect(harness.fileLocationService.trashedURLs.isEmpty)
        #expect(await harness.engine.removed.count == 1)
        #expect(await harness.engine.removed.first?.id == "alpha")
        #expect(await harness.engine.removed.first?.deleteFiles == false)
        #expect(await harness.engine.removed.first?.deletePartfile == false)
        #expect(harness.history.forgottenIDs == [["alpha"]])
        #expect(harness.store.selectionState.ids.isEmpty)
    }

    @Test("Removing with delete prunes folder access only after deleting data")
    func removingWithDeletePrunesFolderAccessOnlyAfterDeletingData() async {
        let harness = makeStoreHarness()
        let torrent = makeTorrent(id: "alpha", name: "Alpha", savePath: "/Downloads", finished: false)
        let downloadedURL = URL(filePath: "/Downloads/Alpha")
        harness.fileLocationService.downloadedDataURLs["alpha"] = downloadedURL
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [torrent]))
        await harness.store.refreshNow()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 2, torrents: []))

        var pruneCallsDuringDelete = [[TorrentItem]]()
        harness.fileLocationService.onDeleteDownloadedData = { _ in
            pruneCallsDuringDelete = harness.accessStore.pruneCalls
        }

        harness.store.removeTorrents(ids: ["alpha"], deleteFiles: true)
        await harness.store.saveAll()

        #expect(pruneCallsDuringDelete.map { $0.map(\.id) } == [["alpha"]])
        #expect(harness.accessStore.pruneCalls.map { $0.map(\.id) } == [["alpha"], []])
    }

    @Test("Removing with trash prunes folder access only after moving data")
    func removingWithTrashPrunesFolderAccessOnlyAfterMovingData() async {
        var settings = TorrentSettings()
        settings.moveRemovedDataToTrash = true
        let harness = makeStoreHarness(settings: settings)
        let torrent = makeTorrent(id: "alpha", name: "Alpha", savePath: "/Downloads", finished: false)
        let downloadedURL = URL(filePath: "/Downloads/Alpha")
        harness.fileLocationService.downloadedDataURLs["alpha"] = downloadedURL
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [torrent]))
        await harness.store.refreshNow()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 2, torrents: []))

        var pruneCallsDuringTrash = [[TorrentItem]]()
        harness.fileLocationService.onMoveDownloadedDataToTrash = { _ in
            pruneCallsDuringTrash = harness.accessStore.pruneCalls
        }

        harness.store.removeTorrents(ids: ["alpha"], deleteFiles: true)
        await harness.store.saveAll()

        #expect(pruneCallsDuringTrash.map { $0.map(\.id) } == [["alpha"]])
        #expect(harness.accessStore.pruneCalls.map { $0.map(\.id) } == [["alpha"], []])
    }

    @Test("Removing with trash does not move data before engine removal succeeds")
    func removingWithTrashDoesNotMoveDataBeforeEngineRemovalSucceeds() async {
        var settings = TorrentSettings()
        settings.moveRemovedDataToTrash = true
        let harness = makeStoreHarness(settings: settings)
        let torrent = makeTorrent(id: "alpha", name: "Alpha", savePath: "/Downloads", finished: true)
        let downloadedURL = URL(filePath: "/Downloads/Alpha")
        harness.fileLocationService.downloadedDataURLs["alpha"] = downloadedURL
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [torrent]))
        await harness.engine.setRemoveError(FakeBookmarkError())
        await harness.store.refreshNow()

        harness.store.removeTorrents(ids: ["alpha"], deleteFiles: true)
        await harness.store.saveAll()

        #expect(harness.fileLocationService.trashedURLs.isEmpty)
        #expect(await harness.engine.removed.isEmpty)
    }

    @Test("Removing with trash keeps engine removal when trash fails")
    func removingWithTrashKeepsEngineRemovalWhenTrashFails() async {
        var settings = TorrentSettings()
        settings.moveRemovedDataToTrash = true
        let harness = makeStoreHarness(settings: settings)
        let torrent = makeTorrent(id: "alpha", name: "Alpha", savePath: "/Downloads", finished: true)
        let downloadedURL = URL(filePath: "/Downloads/Alpha")
        harness.fileLocationService.downloadedDataURLs["alpha"] = downloadedURL
        harness.fileLocationService.trashError = FakeBookmarkError()
        await harness.engine.setSnapshotBatch(TorrentSnapshotBatch(revision: 1, torrents: [torrent]))
        await harness.store.refreshNow()
        harness.store.selectionState.ids = ["alpha"]

        harness.store.removeTorrents(ids: ["alpha"], deleteFiles: true)
        await harness.store.saveAll()

        #expect(await harness.engine.removed.count == 1)
        #expect(await harness.engine.removed.first?.id == "alpha")
        #expect(await harness.engine.removed.first?.deleteFiles == false)
        #expect(await harness.engine.removed.first?.deletePartfile == false)
        #expect(harness.fileLocationService.trashedURLs.isEmpty)
        #expect(harness.history.forgottenIDs == [["alpha"]])
        #expect(harness.store.selectionState.ids.isEmpty)
        #expect(harness.store.lastError != nil)
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
    func changingPEXPluginSettingRestartsEngine() async {
        let harness = makeStoreHarness()
        var settings = harness.store.settings
        settings.enablePeerExchangePlugin = false

        harness.store.updateSettings(settings)
        await harness.store.saveAll()

        #expect(await harness.engine.blockNetworkCount >= 1)
        #expect(await harness.engine.restartPeerExchangePluginValues == [false])
        #expect(await harness.engine.appliedSettings.last?.settings.enablePeerExchangePlugin == false)
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
    networkInterfaces: [NetworkInterfaceOption] = []
) -> StoreHarness {
    let engine = FakeTorrentEngine()
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
        networkInterfaceMonitor: FakeNetworkInterfaceMonitor(),
        downloadFolderAccessStore: accessStore,
        fileLocationService: fileLocationService,
        defaults: defaults,
        networkInterfaces: networkInterfaces
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
