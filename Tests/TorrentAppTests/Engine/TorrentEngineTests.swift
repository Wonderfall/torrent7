import Darwin
import Foundation
import Synchronization
import Testing
import TorrentEngineModel
@testable import TorrentEngineCore

@Suite("Torrent engine", .serialized)
struct TorrentEngineTests {
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
    func startupFailureEngineReportsUnavailableAndEmptyReadModels() async {
        let engine = TorrentEngine(startupFailureMessage: "boom")

        #expect(engine.isAvailable == false)
        #expect(await engine.snapshots().isEmpty)
        #expect(await engine.snapshotsIfChanged(since: 1, sortedBy: .name, direction: .ascending)?.torrents.isEmpty == true)
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

        let first = await engine.poll(
            since: nil,
            sortedBy: .name,
            direction: .ascending,
            includeTrackerHosts: false
        )
        let second = await engine.poll(
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
    func coalescedPollingPreservesRevisionAndOptionalTrackerHostSemantics() async {
        let engine = TorrentEngine(startupFailureMessage: "boom")

        let initial = await engine.poll(
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

        let unchanged = await engine.poll(
            since: 0,
            sortedBy: .name,
            direction: .ascending,
            includeTrackerHosts: true
        )
        #expect(unchanged.snapshotBatch == nil)
        #expect(unchanged.trackerHostBatch?.revision == 0)
        #expect(unchanged.trackerHostBatch?.hosts.isEmpty == true)
    }

    @Test("Nonresident torrent details are cache misses")
    func nonresidentTorrentDetailsAreCacheMisses() async throws {
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

    @Test("Magnet activation is pathless and resident detail batches remain authoritative")
    func magnetActivationIsPathless() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            payloadBroker: TestPayloadBroker()
        )
        let id = try await engine.addMagnet(
            "magnet:?xt=urn:btih:\(String(repeating: "6", count: 40))"
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
            _ = try await engine.addMagnet("magnet:?xt=urn:btih:abc")
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
            "magnet:?xt=urn:btih:\(String(repeating: "7", count: 40))"
        )

        #expect(try await engine.remove(id: id) == .removed)
        #expect(await engine.snapshots().contains(where: { $0.id == id }) == false)
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
