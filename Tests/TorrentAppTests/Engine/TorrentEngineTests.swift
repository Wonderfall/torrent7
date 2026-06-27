import Foundation
import Testing
@testable import TorrentApp

@Suite("Torrent engine")
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
