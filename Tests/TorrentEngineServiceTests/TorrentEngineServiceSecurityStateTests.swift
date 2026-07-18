import Foundation
import Synchronization
import Testing
import XPC
@testable import TorrentEngineIPC
@testable import TorrentEngineService

@Suite("Torrent engine XPC service security state")
struct TorrentEngineServiceSecurityStateTests {
    @Test("Overlapping peers receive retryable busy and shutdown classifications")
    func overlappingPeerFailureCodes() {
        let activePeer = UUID()

        #expect(TorrentEngineServiceRuntime.inFlightFailureCode(
            activePeerToken: activePeer,
            incomingPeerToken: UUID(),
            isShuttingDown: false
        ) == .controllerBusy)
        #expect(TorrentEngineServiceRuntime.inFlightFailureCode(
            activePeerToken: activePeer,
            incomingPeerToken: activePeer,
            isShuttingDown: false
        ) == .operationRejected)
        #expect(TorrentEngineServiceRuntime.inFlightFailureCode(
            activePeerToken: activePeer,
            incomingPeerToken: UUID(),
            isShuttingDown: true
        ) == .serviceShuttingDown)
        #expect(TorrentEngineServiceRuntime.isTransientAdmissionFailure(.controllerBusy))
        #expect(TorrentEngineServiceRuntime.isTransientAdmissionFailure(.serviceShuttingDown))
        #expect(!TorrentEngineServiceRuntime.isTransientAdmissionFailure(.operationRejected))
    }

    @Test("A busy contender receives its typed reply before bounded retirement")
    func busyContenderReceivesReply() async throws {
        let temporary = try ServiceTemporaryDirectory()
        let runtime = try TorrentEngineServiceRuntime(
            stateDirectory: temporary.url,
            authentication: .sameTeam,
            transactionBegin: {},
            transactionEnd: {}
        )
        let activePeer = UUID()
        _ = await runtime.handle(
            try beginMigrationRequest(),
            from: activePeer,
            session: TorrentEngineServiceSessionHandle(),
            peerIsCancelled: { false },
            pendingReply: TorrentEnginePendingReply { _ in }
        )
        let contenderCancellations = Mutex(0)
        let contenderRequest = try beginMigrationRequest()
        let replies = Mutex([TorrentEngineIPCReply]())

        let disposition = await runtime.handle(
            contenderRequest,
            from: UUID(),
            session: TorrentEngineServiceSessionHandle(
                cancelObserver: { _ in contenderCancellations.withLock { $0 += 1 } }
            ),
            peerIsCancelled: { false },
            pendingReply: TorrentEnginePendingReply { dictionary, _ in
                if let reply = try? TorrentEngineIPCEnvelopeCodec.decodeReply(
                    dictionary,
                    maximumPayloadBytes: contenderRequest.header.operation.maximumReplyPayloadBytes
                ) {
                    replies.withLock { $0.append(reply) }
                }
            }
        )

        #expect(disposition == .retirePeerAfterReply)
        #expect(replies.withLock { $0.map(\.header) } == [contenderRequest.header])
        #expect(replies.withLock { $0.map(\.status) } == [.failure])
        #expect(replies.withLock { $0.map(\.failureCode) } == [.controllerBusy])
        #expect(contenderCancellations.withLock { $0 } == 0)
        #expect(await runtime.diagnostics() == .activeMigration)

        await runtime.beginDisconnect(peerToken: activePeer)
        await runtime.finishDisconnect(peerToken: activePeer)
    }

    @Test("A shutting-down contender receives its typed reply before bounded retirement")
    func shuttingDownContenderReceivesReply() async throws {
        let temporary = try ServiceTemporaryDirectory()
        let runtime = try TorrentEngineServiceRuntime(
            stateDirectory: temporary.url,
            authentication: .sameTeam,
            transactionBegin: {},
            transactionEnd: {}
        )
        let activePeer = UUID()
        _ = await runtime.handle(
            try beginMigrationRequest(),
            from: activePeer,
            session: TorrentEngineServiceSessionHandle(),
            peerIsCancelled: { false },
            pendingReply: TorrentEnginePendingReply { _ in }
        )
        await runtime.beginDisconnect(peerToken: activePeer)
        let contenderCancellations = Mutex(0)
        let contenderRequest = try beginMigrationRequest()
        let replies = Mutex([TorrentEngineIPCReply]())

        let disposition = await runtime.handle(
            contenderRequest,
            from: UUID(),
            session: TorrentEngineServiceSessionHandle(
                cancelObserver: { _ in contenderCancellations.withLock { $0 += 1 } }
            ),
            peerIsCancelled: { false },
            pendingReply: TorrentEnginePendingReply { dictionary, _ in
                if let reply = try? TorrentEngineIPCEnvelopeCodec.decodeReply(
                    dictionary,
                    maximumPayloadBytes: contenderRequest.header.operation.maximumReplyPayloadBytes
                ) {
                    replies.withLock { $0.append(reply) }
                }
            }
        )

        #expect(disposition == .retirePeerAfterReply)
        #expect(replies.withLock { $0.map(\.header) } == [contenderRequest.header])
        #expect(replies.withLock { $0.map(\.status) } == [.failure])
        #expect(replies.withLock { $0.map(\.failureCode) } == [.serviceShuttingDown])
        #expect(contenderCancellations.withLock { $0 } == 0)
        #expect(await runtime.diagnostics() == .disconnectingMigration)

        await runtime.finishDisconnect(peerToken: activePeer)
    }

    @Test("Admission limits are atomic and failed reservations do not consume budget")
    func admissionAccounting() throws {
        let budget = TorrentEngineServiceAdmissionBudget(limits: .init(
            maximumPeerCount: 2,
            maximumRequestCount: 2,
            maximumPayloadByteCount: 10,
            maximumFileDescriptorCount: 1
        ))

        let firstPeer = try #require(budget.acquirePeer())
        let secondPeer = try #require(budget.acquirePeer())
        #expect(budget.acquirePeer() == nil)

        let firstRequest = try #require(budget.acquireRequest(
            payloadByteCount: 6,
            hasFileDescriptor: false
        ))
        #expect(budget.acquireRequest(payloadByteCount: 5, hasFileDescriptor: false) == nil)
        #expect(budget.acquireRequest(payloadByteCount: -1, hasFileDescriptor: false) == nil)
        #expect(budget.snapshot() == TorrentEngineServiceAdmissionSnapshot(
            peerCount: 2,
            requestCount: 1,
            payloadByteCount: 6,
            fileDescriptorCount: 0
        ))

        let secondRequest = try #require(budget.acquireRequest(
            payloadByteCount: 4,
            hasFileDescriptor: true
        ))
        #expect(budget.acquireRequest(payloadByteCount: 0, hasFileDescriptor: false) == nil)
        #expect(budget.snapshot() == TorrentEngineServiceAdmissionSnapshot(
            peerCount: 2,
            requestCount: 2,
            payloadByteCount: 10,
            fileDescriptorCount: 1
        ))

        firstPeer.release()
        firstPeer.release()
        firstRequest.release()
        firstRequest.release()
        #expect(budget.snapshot() == TorrentEngineServiceAdmissionSnapshot(
            peerCount: 1,
            requestCount: 1,
            payloadByteCount: 4,
            fileDescriptorCount: 1
        ))

        secondRequest.release()
        secondPeer.release()
        #expect(budget.snapshot() == .zero)
    }

    @Test("Concurrent cancellation releases each admission exactly once")
    func concurrentAdmissionCancellation() async throws {
        let maximumRequestCount = 16
        let budget = TorrentEngineServiceAdmissionBudget(limits: .init(
            maximumPeerCount: 1,
            maximumRequestCount: maximumRequestCount,
            maximumPayloadByteCount: maximumRequestCount * 3,
            maximumFileDescriptorCount: maximumRequestCount
        ))
        let peer = try #require(budget.acquirePeer())

        let admissions = await withTaskGroup(
            of: TorrentEngineServiceRequestAdmission?.self,
            returning: [TorrentEngineServiceRequestAdmission].self
        ) { group in
            for _ in 0..<64 {
                group.addTask {
                    budget.acquireRequest(payloadByteCount: 3, hasFileDescriptor: true)
                }
            }
            var acquired = [TorrentEngineServiceRequestAdmission]()
            for await admission in group {
                if let admission {
                    acquired.append(admission)
                }
            }
            return acquired
        }

        #expect(admissions.count == maximumRequestCount)
        #expect(budget.snapshot() == TorrentEngineServiceAdmissionSnapshot(
            peerCount: 1,
            requestCount: maximumRequestCount,
            payloadByteCount: maximumRequestCount * 3,
            fileDescriptorCount: maximumRequestCount
        ))

        await withTaskGroup(of: Void.self) { group in
            for admission in admissions {
                for _ in 0..<4 {
                    group.addTask {
                        admission.release()
                    }
                }
            }
            for _ in 0..<16 {
                group.addTask {
                    peer.release()
                }
            }
        }

        #expect(budget.snapshot() == .zero)
    }

    @Test("Disconnect invalidates generation before terminal cleanup releases the transaction")
    func disconnectCleanupOrdering() async throws {
        let temporary = try ServiceTemporaryDirectory()
        let lifecycle = LifecycleRecorder()
        let runtime = try TorrentEngineServiceRuntime(
            stateDirectory: temporary.url,
            authentication: .sameTeam,
            transactionBegin: { lifecycle.begin() },
            transactionEnd: { lifecycle.end() }
        )
        let peerToken = UUID()

        let disposition = await runtime.handle(
            try beginMigrationRequest(),
            from: peerToken,
            session: TorrentEngineServiceSessionHandle(),
            peerIsCancelled: { false },
            pendingReply: TorrentEnginePendingReply { lifecycle.reply(status: $0) }
        )

        #expect(disposition == .continuePeer)
        #expect(lifecycle.events == [.begin, .reply(.success)])
        #expect(lifecycle.snapshot == .init(beginCount: 1, endCount: 0))
        #expect(await runtime.diagnostics() == .activeMigration)

        await runtime.beginDisconnect(peerToken: peerToken)

        #expect(await runtime.diagnostics() == .disconnectingMigration)
        #expect(lifecycle.events == [.begin, .reply(.success)])
        #expect(lifecycle.snapshot == .init(beginCount: 1, endCount: 0))

        await runtime.finishDisconnect(peerToken: peerToken)

        #expect(await runtime.diagnostics() == .inactive)
        #expect(lifecycle.events == [.begin, .reply(.success), .end])
        #expect(lifecycle.snapshot == .init(beginCount: 1, endCount: 1))
    }

    @Test("Failed initial request replies before transaction release and clears controller state")
    func failedInitialRequestCleanupOrdering() async throws {
        let temporary = try ServiceTemporaryDirectory()
        let lifecycle = LifecycleRecorder()
        let runtime = try TorrentEngineServiceRuntime(
            stateDirectory: temporary.url,
            authentication: .sameTeam,
            transactionBegin: { lifecycle.begin() },
            transactionEnd: { lifecycle.end() }
        )

        let disposition = await runtime.handle(
            invalidHandshakeRequest(),
            from: UUID(),
            session: TorrentEngineServiceSessionHandle(
                cancelObserver: { _ in lifecycle.cancel() }
            ),
            peerIsCancelled: { false },
            pendingReply: TorrentEnginePendingReply { lifecycle.reply(status: $0) }
        )

        #expect(disposition == .terminatePeer)
        #expect(lifecycle.events == [.begin, .reply(.failure), .cancel, .end])
        #expect(lifecycle.snapshot == .init(beginCount: 1, endCount: 1))
        #expect(await runtime.diagnostics() == .inactive)
    }

    @Test("A pre-record sequence rejection terminalizes the peer")
    func invalidSequenceTerminalizesPeer() async throws {
        let temporary = try ServiceTemporaryDirectory()
        let lifecycle = LifecycleRecorder()
        let runtime = try TorrentEngineServiceRuntime(
            stateDirectory: temporary.url,
            authentication: .sameTeam,
            transactionBegin: { lifecycle.begin() },
            transactionEnd: { lifecycle.end() }
        )
        let peerToken = UUID()
        let controllerID = UUID()
        let session = TorrentEngineServiceSessionHandle(
            cancelObserver: { _ in lifecycle.cancel() }
        )

        let initialDisposition = await runtime.handle(
            try beginMigrationRequest(controllerID: controllerID),
            from: peerToken,
            session: session,
            peerIsCancelled: { false },
            pendingReply: TorrentEnginePendingReply { lifecycle.reply(status: $0) }
        )
        let rejectedDisposition = await runtime.handle(
            try beginMigrationRequest(controllerID: controllerID, sequence: 3),
            from: peerToken,
            session: session,
            peerIsCancelled: { false },
            pendingReply: TorrentEnginePendingReply { lifecycle.reply(status: $0) }
        )

        #expect(initialDisposition == .continuePeer)
        #expect(rejectedDisposition == .terminatePeer)
        #expect(lifecycle.events == [
            .begin,
            .reply(.success),
            .reply(.failure),
            .cancel,
        ])

        await runtime.beginDisconnect(peerToken: peerToken)
        await runtime.finishDisconnect(peerToken: peerToken)
        #expect(await runtime.diagnostics() == .inactive)
        #expect(lifecycle.events.last == .end)
    }

    @Test("Pending replies are single-use under concurrent send attempts")
    func pendingReplyIsSingleUse() async {
        let sendCount = Mutex(0)
        let pendingReply = TorrentEnginePendingReply { _ in
            sendCount.withLock { $0 += 1 }
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    pendingReply.send(XPCDictionary(), status: .success)
                }
            }
        }

        #expect(sendCount.withLock { $0 } == 1)
    }
}

private extension TorrentEngineServiceAdmissionSnapshot {
    static let zero = TorrentEngineServiceAdmissionSnapshot(
        peerCount: 0,
        requestCount: 0,
        payloadByteCount: 0,
        fileDescriptorCount: 0
    )
}

private extension TorrentEngineServiceRuntimeDiagnostics {
    static let activeMigration = TorrentEngineServiceRuntimeDiagnostics(
        hasActivePeer: true,
        hasActiveController: true,
        hasActiveControllerGeneration: true,
        hasActiveSession: true,
        hasEngine: false,
        hasActiveMigration: true,
        transactionIsActive: true,
        isShuttingDown: false
    )

    static let disconnectingMigration = TorrentEngineServiceRuntimeDiagnostics(
        hasActivePeer: true,
        hasActiveController: true,
        hasActiveControllerGeneration: false,
        hasActiveSession: true,
        hasEngine: false,
        hasActiveMigration: true,
        transactionIsActive: true,
        isShuttingDown: true
    )

    static let inactive = TorrentEngineServiceRuntimeDiagnostics(
        hasActivePeer: false,
        hasActiveController: false,
        hasActiveControllerGeneration: false,
        hasActiveSession: false,
        hasEngine: false,
        hasActiveMigration: false,
        transactionIsActive: false,
        isShuttingDown: false
    )
}

private func beginMigrationRequest(
    controllerID: UUID = UUID(),
    sequence: UInt64 = 1
) throws -> TorrentEngineIPCRequest {
    let operation = TorrentEngineIPCOperation.beginStateMigration
    return TorrentEngineIPCRequest(
        header: TorrentEngineIPCHeader(
            requestID: UUID(),
            controllerID: controllerID,
            sequence: sequence,
            operation: operation,
            operationID: UUID(),
            expectedEpoch: nil
        ),
        payload: try TorrentEngineIPCPropertyListCodec.encode(
            TorrentEngineIPCEmpty(),
            maximumBytes: operation.maximumRequestPayloadBytes
        )
    )
}

private func invalidHandshakeRequest() -> TorrentEngineIPCRequest {
    TorrentEngineIPCRequest(
        header: TorrentEngineIPCHeader(
            requestID: UUID(),
            controllerID: UUID(),
            sequence: 1,
            operation: .handshake,
            operationID: UUID(),
            expectedEpoch: nil
        ),
        payload: Data([0])
    )
}

@safe private final class LifecycleRecorder: Sendable {
    enum Event: Equatable, Sendable {
        case begin
        case reply(TorrentEngineIPCReplyStatus)
        case cancel
        case end
    }

    struct Snapshot: Equatable, Sendable {
        var beginCount = 0
        var endCount = 0
    }

    private struct State: Sendable {
        var snapshot = Snapshot()
        var events = [Event]()
    }

    private let state = Mutex(State())

    func begin() {
        state.withLock { state in
            state.snapshot.beginCount += 1
            state.events.append(.begin)
        }
    }

    func end() {
        state.withLock { state in
            state.snapshot.endCount += 1
            state.events.append(.end)
        }
    }

    func reply(status: TorrentEngineIPCReplyStatus) {
        state.withLock { $0.events.append(.reply(status)) }
    }

    func cancel() {
        state.withLock { $0.events.append(.cancel) }
    }

    var snapshot: Snapshot {
        state.withLock(\.snapshot)
    }

    var events: [Event] {
        state.withLock(\.events)
    }
}

private final class ServiceTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TorrentEngineServiceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
