import Darwin
import Foundation
import Synchronization
import Testing
import TorrentBridge
import TorrentEngineModel
@testable import TorrentEngineCore

@Suite("Torrent engine", .serialized)
struct TorrentEngineTests {
    @Test("Authorized save roots duplicate and validate directory authority")
    func authorizedSaveRootsDuplicateAndValidateDirectoryAuthority() throws {
        let stateDirectory = try temporaryStateDirectory()
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        let downloadDirectory = stateDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let descriptor = try openDirectory(downloadDirectory)
        defer {
            Darwin.close(descriptor.value)
        }

        let root = try TorrentAuthorizedSaveRoot(
            canonicalPath: downloadDirectory.torrentFilePath,
            borrowingDirectoryDescriptor: descriptor.value,
            device: descriptor.device,
            inode: descriptor.inode,
            retaining: TestAuthorizedSaveRootLifetimeAnchor()
        )
        #expect(root.canonicalPath == downloadDirectory.torrentFilePath)
        #expect(root.device == descriptor.device)
        #expect(root.inode == descriptor.inode)
        let hasDuplicatedDescriptor = unsafe (
            root.nativeRecord().directory_descriptor != descriptor.value
        )
        #expect(hasDuplicatedDescriptor)
        #expect(throws: TorrentEngineError.self) {
            try TorrentAuthorizedSaveRoot(
                canonicalPath: "relative",
                borrowingDirectoryDescriptor: descriptor.value,
                device: descriptor.device,
                inode: descriptor.inode,
                retaining: TestAuthorizedSaveRootLifetimeAnchor()
            )
        }
        #expect(throws: TorrentEngineError.self) {
            try TorrentAuthorizedSaveRoot(
                canonicalPath: downloadDirectory.torrentFilePath,
                borrowingDirectoryDescriptor: descriptor.value,
                device: descriptor.device,
                inode: descriptor.inode &+ 1,
                retaining: TestAuthorizedSaveRootLifetimeAnchor()
            )
        }
        #expect(throws: TorrentEngineError.self) {
            try TorrentAuthorizedSaveRoot(
                canonicalPath: "/" + String(
                    repeating: "x",
                    count: Int(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BYTES)
                ),
                borrowingDirectoryDescriptor: descriptor.value,
                device: descriptor.device,
                inode: descriptor.inode,
                retaining: TestAuthorizedSaveRootLifetimeAnchor()
            )
        }
    }

    @Test("Authorized save root callbacks retain the security-scope anchor")
    func authorizedSaveRootCallbacksRetainSecurityScopeAnchor() throws {
        let stateDirectory = try temporaryStateDirectory()
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        let lifetimeState = TestAuthorizedSaveRootLifetimeState()
        let retainedLifetime = try TestRetainedAuthorizedSaveRootLifetime(
            at: stateDirectory,
            state: lifetimeState
        )
        #expect(retainedLifetime.hasStableContext)
        #expect(!lifetimeState.isReleased)

        retainedLifetime.release()
        #expect(lifetimeState.isReleased)
    }

    @Test("Engine creation and restart forward authorized save root snapshots")
    func engineCreationAndRestartForwardAuthorizedSaveRootSnapshots() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
            TorrentEngine.clientCreationPreflight.withLock { $0 = nil }
        }
        let initialDirectory = stateDirectory.appending(path: "Initial", directoryHint: .isDirectory)
        let freshDirectory = stateDirectory.appending(path: "Fresh", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: initialDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: freshDirectory, withIntermediateDirectories: true)
        let snapshots = Mutex([[String]]())
        TorrentEngine.clientCreationPreflight.withLock { preflight in
            preflight = { createdStateDirectory, _, authorizedSaveRoots in
                guard createdStateDirectory == stateDirectory else {
                    return
                }
                snapshots.withLock { $0.append(authorizedSaveRoots.map(\.canonicalPath)) }
            }
        }

        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            authorizedSaveRoots: [try authorizedSaveRoot(at: initialDirectory)]
        )
        try await engine.restart(
            enablePeerExchangePlugin: false,
            authorizedSaveRoots: [try authorizedSaveRoot(at: freshDirectory)]
        )

        #expect(snapshots.withLock { $0 } == [[initialDirectory.torrentFilePath], [freshDirectory.torrentFilePath]])
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

    @Test("Coalesced polling drains alert errors in bounded batches")
    func coalescedPollingDrainsAlertErrorsInBoundedBatches() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        let expectedErrors = (0..<20).map { "alert-error-\($0)" }
        let queuedErrors = Mutex(expectedErrors)
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            alertErrorReader: {
                queuedErrors.withLock { errors -> String? in
                    guard !errors.isEmpty else {
                        return nil
                    }
                    return errors.removeFirst()
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
    func coalescedPollingPreservesRevisionAndOptionalTrackerHostSemantics() async throws {
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
            authorizedSaveRoots: [try authorizedSaveRoot(at: downloadDirectory)]
        )
        let id = try await engine.addMagnet(
            "magnet:?xt=urn:btih:\(String(repeating: "6", count: 40))",
            savePath: downloadDirectory.torrentFilePath
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
            try await engine.restart(enablePeerExchangePlugin: false, authorizedSaveRoots: [])
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
        try await engine.restart(enablePeerExchangePlugin: false, authorizedSaveRoots: [])

        #expect(engine.isAvailable == true)
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
            authorizedSaveRoots: [try authorizedSaveRoot(at: downloadDirectory)],
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
            savePath: downloadDirectory.torrentFilePath
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
        let readCountAtCancellation = pollState.withLock { $0.readCount }
        removal.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(completed.withLock { !$0 })
        #expect(
            pollState.withLock { $0.readCount - readCountAtCancellation < 100 },
            "Cancellation must not turn deletion tracking into a hot poll"
        )

        do {
            try await engine.restart(
                enablePeerExchangePlugin: true,
                authorizedSaveRoots: [try authorizedSaveRoot(at: downloadDirectory)]
            )
            Issue.record("Expected restart to remain blocked while deletion is pending")
        } catch {
            #expect(error.localizedDescription.contains("cannot restart while removal is pending"))
        }

        pollState.withLock { $0.returnsPending = false }
        _ = try await removal.value
        #expect(completed.withLock { $0 })
        #expect(engine.isAvailable == true)
    }

    @Test("Forced network containment invalidates a suspended removal before pointer reuse")
    func forcedContainmentInvalidatesSuspendedRemovalPointer() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        let downloadDirectory = stateDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let readCount = Mutex(0)
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            authorizedSaveRoots: [try authorizedSaveRoot(at: downloadDirectory)],
            removalResultReader: {
                readCount.withLock { $0 += 1 }
                return .pending
            }
        )
        let id = try await engine.addMagnet(
            "magnet:?xt=urn:btih:\(String(repeating: "9", count: 40))",
            savePath: downloadDirectory.torrentFilePath
        )
        let removal = Task {
            try await engine.remove(id: id, deleteFiles: true)
        }

        while readCount.withLock({ $0 == 0 }) {
            await Task.yield()
        }
        await engine.forceContainmentAfterNetworkBlockFailure(detail: "test failure")

        let outcome = try await removal.value
        guard case .removedWithWarning(let warning) = outcome else {
            Issue.record("Expected a conservative deletion warning")
            return
        }
        #expect(warning.contains("security containment"))
        #expect(engine.isAvailable == false)
        #expect(readCount.withLock { $0 } == 1)
    }

    @Test("Runtime authorized save path replacement is immediate and fail-closed")
    func runtimeAuthorizedSavePathReplacementIsImmediateAndFailClosed() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        let firstDirectory = stateDirectory.appending(path: "First", directoryHint: .isDirectory)
        let secondDirectory = stateDirectory.appending(path: "Second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            authorizedSaveRoots: [try authorizedSaveRoot(at: firstDirectory)]
        )

        let secondRoot = try authorizedSaveRoot(at: secondDirectory)
        try await engine.replaceAuthorizedSaveRoots([secondRoot])
        await expectUnauthorizedSavePath(engine: engine, path: firstDirectory.torrentFilePath, hashCharacter: "a")
        _ = try await engine.addMagnet(
            "magnet:?xt=urn:btih:\(String(repeating: "b", count: 40))",
            savePath: secondDirectory.torrentFilePath
        )

        do {
            try await engine.replaceAuthorizedSaveRoots([secondRoot, secondRoot])
            Issue.record("Expected a duplicate replacement to fail")
        } catch {
            #expect(error.localizedDescription.contains("authorized download folder path is invalid"))
        }
        _ = try await engine.addMagnet(
            "magnet:?xt=urn:btih:\(String(repeating: "c", count: 40))",
            savePath: secondDirectory.torrentFilePath
        )

        try await engine.replaceAuthorizedSaveRoots([])
        await expectUnauthorizedSavePath(engine: engine, path: secondDirectory.torrentFilePath, hashCharacter: "d")
    }

    @Test("Native add failures distinguish rejection from an unknown commit status")
    func nativeAddFailuresExposeCommitStatus() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        let downloadDirectory = stateDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let engine = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: true,
            authorizedSaveRoots: [try authorizedSaveRoot(at: downloadDirectory)]
        )

        do {
            _ = try await engine.addMagnet(
                "magnet:?xt=urn:btih:\(String(repeating: "e", count: 40))",
                savePath: stateDirectory.torrentFilePath
            )
            Issue.record("Expected the unauthorized add to be rejected")
        } catch let error as TorrentAddError {
            guard case .rejected(let message) = error else {
                Issue.record("Expected a definite add rejection, got \(error)")
                return
            }
            #expect(message.contains("save path is not authorized"))
        }

        let resumeDirectory = stateDirectory.appending(path: "ResumeData", directoryHint: .isDirectory)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: resumeDirectory.torrentFilePath
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: resumeDirectory.torrentFilePath
            )
        }

        do {
            _ = try await engine.addMagnet(
                "magnet:?xt=urn:btih:\(String(repeating: "f", count: 40))",
                savePath: downloadDirectory.torrentFilePath
            )
            Issue.record("Expected the add with unpersistable state to fail")
        } catch let error as TorrentAddError {
            guard case .commitStatusUnknown(let message) = error else {
                Issue.record("Expected an unknown add commit status, got \(error)")
                return
            }
            #expect(message.contains("Torrent was added, but resume data could not be saved"))
        }
    }

    @Test("Safe shutdown blocks, saves, destroys, and permanently marks the engine unavailable")
    func safeShutdownIsTerminalAndReleasesNativeState() async throws {
        let stateDirectory = try temporaryStateDirectory()
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        let engine = try TorrentEngine(stateDirectory: stateDirectory, enablePeerExchangePlugin: true)
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
            try await engine.restart(enablePeerExchangePlugin: true, authorizedSaveRoots: [])
        }
        try assertStateDirectoryCanBeReopened(stateDirectory)
    }
}

private func expectUnauthorizedSavePath(
    engine: TorrentEngine,
    path: String,
    hashCharacter: Character
) async {
    do {
        _ = try await engine.addMagnet(
            "magnet:?xt=urn:btih:\(String(repeating: hashCharacter, count: 40))",
            savePath: path
        )
        Issue.record("Expected the save path to be rejected")
    } catch {
        #expect(error.localizedDescription.contains("save path is not authorized"))
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

@Test("Removal warnings share the client UTF-8 resource bound")
func removalWarningsShareClientResourceBound() {
    let warning = TorrentEngine.boundedRemovalWarning(
        String(repeating: "🔒", count: TorrentEngineLimits.maximumRemovalWarningBytes)
    )

    #expect(!warning.isEmpty)
    #expect(warning.utf8.count <= TorrentEngineLimits.maximumRemovalWarningBytes)
    #expect(String(data: Data(warning.utf8), encoding: .utf8) == warning)
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
        authorizedSaveRoots: [try authorizedSaveRoot(at: downloadDirectory)],
        removalResultReader: {
            try fault.result()
        }
    )
    let hashCharacter = String(fault.rawValue + 7)
    let id = try await engine.addMagnet(
        "magnet:?xt=urn:btih:\(String(repeating: hashCharacter, count: 40))",
        savePath: downloadDirectory.torrentFilePath
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
    try await engine.restart(
        enablePeerExchangePlugin: true,
        authorizedSaveRoots: [try authorizedSaveRoot(at: downloadDirectory)]
    )
    #expect(engine.isAvailable == true)
    try await engine.saveAllChecked()
}

private func assertStateDirectoryCanBeReopened(_ stateDirectory: URL) throws {
    var errorBuffer = Array<CChar>(repeating: 0, count: 1_024)
    let created = unsafe errorBuffer.withUnsafeMutableBufferPointer { error in
        unsafe stateDirectory.torrentFilePath.withCString { path in
            unsafe TorrentClientCreateWithError(
                path,
                1,
                nil,
                0,
                nil,
                0,
                nil,
                nil,
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

private final class TestAuthorizedSaveRootLifetimeAnchor: @unchecked Sendable {}

private final class TestAuthorizedSaveRootLifetimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false

    var isReleased: Bool {
        lock.withLock { released }
    }

    func markReleased() {
        lock.withLock { released = true }
    }
}

private final class TestAuthorizedSaveRootLifetimeProbe: @unchecked Sendable {
    private let state: TestAuthorizedSaveRootLifetimeState

    init(state: TestAuthorizedSaveRootLifetimeState) {
        self.state = state
    }

    deinit {
        state.markReleased()
    }
}

private struct TestDirectoryDescriptor {
    let value: Int32
    let device: UInt64
    let inode: UInt64
}

private func openDirectory(_ directory: URL) throws -> TestDirectoryDescriptor {
    let descriptor = unsafe directory.torrentFilePath.withCString {
        unsafe Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
        throw TorrentEngineError.bridgeError("Could not open the test download directory.")
    }
    var metadata = stat()
    guard unsafe Darwin.fstat(descriptor, &metadata) == 0 else {
        Darwin.close(descriptor)
        throw TorrentEngineError.bridgeError("Could not inspect the test download directory.")
    }
    return TestDirectoryDescriptor(
        value: descriptor,
        device: UInt64(truncatingIfNeeded: metadata.st_dev),
        inode: UInt64(truncatingIfNeeded: metadata.st_ino)
    )
}

private func authorizedSaveRoot(
    at directory: URL,
    retaining lifetimeAnchor: any AnyObject & Sendable = TestAuthorizedSaveRootLifetimeAnchor()
) throws -> TorrentAuthorizedSaveRoot {
    let descriptor = try openDirectory(directory)
    defer {
        Darwin.close(descriptor.value)
    }
    return try TorrentAuthorizedSaveRoot(
        canonicalPath: directory.torrentFilePath,
        borrowingDirectoryDescriptor: descriptor.value,
        device: descriptor.device,
        inode: descriptor.inode,
        retaining: lifetimeAnchor
    )
}

@safe private final class TestRetainedAuthorizedSaveRootLifetime: @unchecked Sendable {
    let hasStableContext: Bool
    private var context: UnsafeMutableRawPointer?

    init(
        at directory: URL,
        state: TestAuthorizedSaveRootLifetimeState
    ) throws {
        let lifetimeAnchor = TestAuthorizedSaveRootLifetimeProbe(state: state)
        let firstRoot = try authorizedSaveRoot(at: directory, retaining: lifetimeAnchor)
        let secondRoot = try authorizedSaveRoot(at: directory, retaining: lifetimeAnchor)
        let firstRecord = unsafe firstRoot.nativeRecord()
        let secondRecord = unsafe secondRoot.nativeRecord()
        guard let firstContext = unsafe firstRecord.lifetime_context,
              let secondContext = unsafe secondRecord.lifetime_context else {
            throw TorrentEngineError.bridgeError("An authorized root lifetime context is missing.")
        }
        hasStableContext = unsafe firstContext == secondContext
        unsafe torrentAuthorizedSaveRootRetainCallback(firstContext)
        unsafe context = firstContext
    }

    func release() {
        guard let context = unsafe context else {
            return
        }
        unsafe self.context = nil
        unsafe torrentAuthorizedSaveRootReleaseCallback(context)
    }

    deinit {
        release()
    }
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
