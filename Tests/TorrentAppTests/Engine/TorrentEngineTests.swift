import Foundation
import Synchronization
import Testing
import TorrentBridge
import TorrentEngineModel
@testable import TorrentApp

@Suite("Torrent engine", .serialized)
struct TorrentEngineTests {
    @Test("Authorized save path encoding is deterministic, bounded, and NUL delimited")
    func authorizedSavePathEncodingIsDeterministicBoundedAndNULDelimited() throws {
        let blob = try TorrentEngine.encodeAuthorizedSavePaths(["/Downloads/B", "/Downloads/A", "/Downloads/B"])
        let records = blob.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }

        #expect(records == ["/Downloads/A", "/Downloads/B"])
        #expect(blob.last == 0)
        #expect(try TorrentEngine.encodeAuthorizedSavePaths([]).isEmpty)
        #expect(throws: TorrentEngineError.self) {
            try TorrentEngine.encodeAuthorizedSavePaths(["relative"])
        }
        #expect(throws: TorrentEngineError.self) {
            try TorrentEngine.encodeAuthorizedSavePaths(["/Downloads/Bad\0Path"])
        }
        #expect(throws: TorrentEngineError.self) {
            try TorrentEngine.encodeAuthorizedSavePaths([
                "/" + String(repeating: "x", count: Int(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BYTES))
            ])
        }
        #expect(throws: TorrentEngineError.self) {
            try TorrentEngine.encodeAuthorizedSavePaths(Array(
                repeating: "/Downloads",
                count: Int(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT) + 1
            ))
        }
    }

    @Test("Engine creation and restart forward authorized save path snapshots")
    func engineCreationAndRestartForwardAuthorizedSavePathSnapshots() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
            TorrentEngine.clientCreationPreflight.withLock { $0 = nil }
        }
        let snapshots = Mutex([[String]]())
        TorrentEngine.clientCreationPreflight.withLock { preflight in
            preflight = { _, _, authorizedSavePaths in
                snapshots.withLock { $0.append(authorizedSavePaths) }
            }
        }

        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            authorizedSavePaths: ["/Downloads/Initial"]
        )
        try await engine.restart(
            enablePeerExchangePlugin: false,
            authorizedSavePaths: ["/Downloads/Fresh"]
        )

        #expect(snapshots.withLock { $0 } == [["/Downloads/Initial"], ["/Downloads/Fresh"]])
    }

    @Test("Startup failure engine reports unavailable and empty read models")
    func startupFailureEngineReportsUnavailableAndEmptyReadModels() async {
        let engine = TorrentEngine(startupFailureMessage: "boom")

        #expect(engine.isAvailable == false)
        #expect(await engine.snapshots().isEmpty)
        #expect(await engine.snapshotsIfChanged(since: 1, sortedBy: .name, direction: .ascending)?.torrents.isEmpty == true)
        #expect(await engine.trackerBatch(id: "missing", since: nil) == nil)
        #expect(await engine.webSeedBatch(id: "missing", since: nil) == nil)
        #expect(await engine.trackerBatch(id: "missing", since: 42) == nil)
        #expect(await engine.webSeedBatch(id: "missing", since: 42) == nil)
        #expect(await engine.webSeedActivity(id: "missing") == nil)
        #expect(await engine.peerSources(id: "missing") == nil)
        #expect(await engine.fileBatch(id: "missing", since: nil) == nil)
        #expect(await engine.pieceMapBatch(id: "missing", since: nil) == nil)
        #expect(await engine.fileBatch(id: "missing", since: 42) == nil)
        #expect(await engine.pieceMapBatch(id: "missing", since: 42) == nil)
        #expect(await engine.networkStatus() == .empty)
        #expect(await engine.takeChanges() == 0)
        #expect(await engine.takeAlertError() == nil)
    }

    @Test("Nonresident torrent details are cache misses rather than authoritative empty batches")
    func nonresidentTorrentDetailsAreCacheMisses() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
        }

        let engine = try TorrentEngine(stateDirectory: stateDirectory, enablePeerExchangePlugin: true)

        let trackerRevision = await engine.trackerBatch(id: "missing", since: nil)?.revision
        let webSeedRevision = await engine.webSeedBatch(id: "missing", since: nil)?.revision
        let fileRevision = await engine.fileBatch(id: "missing", since: nil)?.revision
        let pieceMapRevision = await engine.pieceMapBatch(id: "missing", since: nil)?.revision

        #expect(trackerRevision == nil)
        #expect(webSeedRevision == nil)
        #expect(fileRevision == nil)
        #expect(pieceMapRevision == nil)
        #expect(await engine.webSeedActivity(id: "missing") == nil)
        #expect(await engine.peerSources(id: "missing") == nil)
        #expect(await engine.trackerBatch(id: "missing", since: trackerRevision) == nil)
        #expect(await engine.webSeedBatch(id: "missing", since: webSeedRevision) == nil)
        #expect(await engine.fileBatch(id: "missing", since: fileRevision) == nil)
        #expect(await engine.pieceMapBatch(id: "missing", since: pieceMapRevision) == nil)
    }

    @Test("Resident empty torrent details remain authoritative")
    func residentEmptyTorrentDetailsRemainAuthoritative() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        let downloadDirectory = stateDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            authorizedSavePaths: [downloadDirectory.path]
        )
        let id = try await engine.addMagnet(
            "magnet:?xt=urn:btih:\(String(repeating: "6", count: 40))",
            savePath: downloadDirectory.path
        )

        try await engine.requestSources(id: id)
        let batch = await engine.webSeedBatch(id: id, since: nil)

        #expect(batch != nil)
        #expect(batch?.webSeeds.isEmpty == true)
    }

    @Test("Startup failure engine throws startup error for mutations")
    func startupFailureEngineThrowsStartupErrorForMutations() async {
        let engine = TorrentEngine(startupFailureMessage: "boom")

        await expectStartupError {
            _ = try await engine.addMagnet("magnet:?xt=urn:btih:abc", savePath: "/tmp")
        }
        await expectStartupError {
            try await engine.requestSources(id: "missing")
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

        let engine = try TorrentEngine(stateDirectory: stateDirectory, enablePeerExchangePlugin: true)
        #expect(engine.isAvailable == true)

        TorrentEngine.clientCreationPreflight.withLock { preflight in
            preflight = { _, _, _ in
                throw TorrentEngineError.bridgeError("restart boom")
            }
        }

        do {
            try await engine.restart(enablePeerExchangePlugin: false, authorizedSavePaths: [])
            Issue.record("Expected restart failure")
        } catch let error as TorrentEngineError {
            #expect(error.localizedDescription == "restart boom")
        } catch {
            Issue.record("Expected TorrentEngineError, got \(error)")
        }

        #expect(engine.isAvailable == false)

        do {
            try await engine.saveAllChecked()
            Issue.record("Expected runtime failure")
        } catch let error as TorrentEngineError {
            #expect(error.localizedDescription == "restart boom")
        } catch {
            Issue.record("Expected TorrentEngineError, got \(error)")
        }

        TorrentEngine.clientCreationPreflight.withLock { $0 = nil }
        try await engine.restart(enablePeerExchangePlugin: false, authorizedSavePaths: [])

        #expect(engine.isAvailable == true)
        try await engine.saveAllChecked()
    }

    @Test("Engine errors expose safe localized descriptions")
    func engineErrorsExposeSafeLocalizedDescriptions() {
        #expect(TorrentEngineError.failedToCreateClient.localizedDescription == "Could not start libtorrent.")
        #expect(TorrentEngineError.startupFailed("").localizedDescription == "Could not start libtorrent.")
        #expect(TorrentEngineError.startupFailed("boom").localizedDescription == "Could not start libtorrent: boom")
        #expect(TorrentEngineError.bridgeError("").localizedDescription == "The torrent operation failed.")
        #expect(TorrentEngineError.bridgeError("bad magnet").localizedDescription == "bad magnet")
    }

    @Test("Untrackable deletion states stop the engine before returning and can recover")
    func untrackableDeletionStatesStopEngineBeforeReturningAndCanRecover() async throws {
        for fault in RemovalTrackingFault.allCases {
            try await verifyRemovalTrackingFault(fault)
        }
    }

    @Test("Cancellation cannot bypass terminal deletion tracking")
    func cancellationCannotBypassTerminalDeletionTracking() async throws {
        struct PollState: Sendable {
            var returnsPending = true
            var readCount = 0
        }

        let stateDirectory = try temporaryStateDirectory()
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        let downloadDirectory = stateDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let pollState = Mutex(PollState())
        let completed = Mutex(false)
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            authorizedSavePaths: [downloadDirectory.path],
            removalResultReader: {
                pollState.withLock { state in
                    state.readCount += 1
                    guard state.returnsPending else {
                        return nil
                    }
                    return .pending
                }
            }
        )
        let id = try await engine.addMagnet(
            "magnet:?xt=urn:btih:\(String(repeating: "8", count: 40))",
            savePath: downloadDirectory.path
        )
        let removal = Task {
            defer {
                completed.withLock { $0 = true }
            }
            return try await engine.remove(id: id, deleteFiles: true)
        }

        while pollState.withLock({ $0.readCount == 0 }) {
            await Task.yield()
        }
        removal.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(completed.withLock { !$0 })

        do {
            try await engine.restart(enablePeerExchangePlugin: true, authorizedSavePaths: [downloadDirectory.path])
            Issue.record("Expected restart to remain blocked while deletion is pending")
        } catch {
            #expect(error.localizedDescription.contains("cannot restart while removal is pending"))
        }

        pollState.withLock { $0.returnsPending = false }
        _ = try await removal.value
        #expect(completed.withLock { $0 })
        #expect(engine.isAvailable == true)
    }
}

private enum RemovalTrackingFault: Int, CaseIterable, Sendable {
    case readError
    case unknownState

    var detail: String {
        switch self {
        case .readError:
            "poll boom"
        case .unknownState:
            "unknown deletion state"
        }
    }

    func result() throws -> TorrentRemovalResultReadOverride? {
        switch self {
        case .readError:
            throw TorrentEngineError.bridgeError(detail)
        case .unknownState:
            return .unknownState
        }
    }
}

private func verifyRemovalTrackingFault(_ fault: RemovalTrackingFault) async throws {
    let stateDirectory = try temporaryStateDirectory()
    defer {
        try? FileManager.default.removeItem(at: stateDirectory)
    }
    let downloadDirectory = stateDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
    let engine = try TorrentEngine(
        stateDirectory: stateDirectory,
        enablePeerExchangePlugin: true,
        authorizedSavePaths: [downloadDirectory.path],
        removalResultReader: {
            try fault.result()
        }
    )
    let hashCharacter = String(fault.rawValue + 7)
    let id = try await engine.addMagnet(
        "magnet:?xt=urn:btih:\(String(repeating: hashCharacter, count: 40))",
        savePath: downloadDirectory.path
    )

    let outcome = try await engine.remove(id: id, deleteFiles: true)
    guard case .removedWithWarning(let warning) = outcome else {
        Issue.record("Expected a conservative deletion warning")
        return
    }
    #expect(warning.contains("stopped safely before folder access was released"))
    #expect(warning.contains(fault.detail))
    #expect(engine.isAvailable == false)
    #expect(await engine.snapshotsIfChanged(since: 1, sortedBy: .name, direction: .ascending) == nil)

    do {
        try await engine.saveAllChecked()
        Issue.record("Expected the stopped engine to report its runtime failure")
    } catch {
        #expect(error.localizedDescription.contains(fault.detail))
    }

    try assertStateDirectoryCanBeReopened(stateDirectory)
    try await engine.restart(enablePeerExchangePlugin: true, authorizedSavePaths: [downloadDirectory.path])
    #expect(engine.isAvailable == true)
    try await engine.saveAllChecked()
}

private func assertStateDirectoryCanBeReopened(_ stateDirectory: URL) throws {
    var errorBuffer = Array<CChar>(repeating: 0, count: 1_024)
    let created = unsafe errorBuffer.withUnsafeMutableBufferPointer { error in
        unsafe stateDirectory.path.withCString { path in
            unsafe TorrentClientCreateWithError(
                path,
                1,
                nil,
                0,
                error.baseAddress,
                Int32(error.count)
            )
        }
    }
    guard let client = unsafe created else {
        throw TorrentEngineError.failedToCreateClient
    }
    unsafe TorrentClientDestroyBlocking(client)
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
        #expect(error.localizedDescription == "Could not start libtorrent: boom")
    } catch {
        Issue.record("Expected TorrentEngineError, got \(error)")
    }
}
