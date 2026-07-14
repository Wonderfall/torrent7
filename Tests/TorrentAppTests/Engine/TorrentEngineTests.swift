import Foundation
import Synchronization
import Testing
import TorrentBridge
@testable import TorrentApp

@Suite("Torrent engine", .serialized)
struct TorrentEngineTests {
    @Test("Startup failure engine reports unavailable and empty read models")
    func startupFailureEngineReportsUnavailableAndEmptyReadModels() async {
        let engine = TorrentEngine(startupFailureMessage: "boom")

        #expect(engine.isAvailable == false)
        #expect(await engine.snapshots().isEmpty)
        #expect(await engine.snapshotsIfChanged(since: 1, sortedBy: .name, direction: .ascending)?.torrents.isEmpty == true)
        #expect(await engine.trackerBatch(id: "missing").trackers.isEmpty)
        #expect(await engine.webSeedBatch(id: "missing").webSeeds.isEmpty)
        #expect(await engine.webSeedActivity(id: "missing") == .empty)
        #expect(await engine.fileBatch(id: "missing").files.isEmpty)
        #expect(await engine.pieceMapBatch(id: "missing").pieceMap == .empty)
        #expect(await engine.networkStatus() == .empty)
        #expect(await engine.takeChanges() == 0)
        #expect(await engine.takeAlertError() == nil)
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
            preflight = { _, _ in
                throw TorrentEngineError.bridgeError("restart boom")
            }
        }

        do {
            try await engine.restart(enablePeerExchangePlugin: false)
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
        try await engine.restart(enablePeerExchangePlugin: false)

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
            try await engine.restart(enablePeerExchangePlugin: true)
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
    try await engine.restart(enablePeerExchangePlugin: true)
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
