import Darwin
import Foundation
import Synchronization
import Testing
import XPC
@testable import TorrentEngineIPC
@testable import TorrentEngineService

@Suite("Torrent storage broker client security", .serialized)
struct TorrentStorageBrokerClientSecurityTests {
    @Test("A published blocking result is consumed once even at an expired deadline")
    func blockingCompletionBeforeDeadline() throws {
        let completion = TorrentStorageBrokerBlockingResult<Int>()
        #expect(completion.finish(.success(42)))
        #expect(try completion.wait(timeout: .now()) == 42)
        #expect(!completion.finish(.success(43)))
        #expect(throws: TorrentStorageBrokerClientError.self) {
            try completion.wait(timeout: .now())
        }
    }

    @Test("An abandoned blocking result leaves ownership with its producer")
    func blockingDeadlineBeforeCompletion() {
        let completion = TorrentStorageBrokerBlockingResult<Int>()
        do {
            _ = try completion.wait(timeout: .now())
            Issue.record("An unfinished blocking result unexpectedly succeeded")
        } catch {
            guard case .timedOut = error as? TorrentStorageBrokerClientError else {
                Issue.record("Expected a timeout, received \(error)")
                return
            }
        }
        #expect(!completion.finish(.success(42)))
    }

    // SAFETY: Swift pins the static NUL-terminated path for open. The test owns
    // the source descriptor until defer; each duplicate transfers to exactly
    // one of the producer or waiter, both of which close it before continuing.
    @Test("Blocking completion and timeout transfer each descriptor to exactly one owner")
    func blockingDescriptorOwnershipRace() async throws {
        let original = unsafe "/dev/null".withCString {
            unsafe Darwin.open($0, O_RDONLY | O_CLOEXEC)
        }
        try #require(original >= 0)
        defer { _ = Darwin.close(original) }

        for index in 0..<512 {
            let descriptor = Darwin.dup(original)
            try #require(descriptor >= 0)
            let completion = TorrentStorageBrokerBlockingResult<Int32>()
            let producer = Task.detached {
                let accepted = completion.finish(.success(descriptor))
                if !accepted {
                    _ = Darwin.close(descriptor)
                }
                return accepted
            }
            // Short real deadlines exercise semaphore wakeup/timeout contention
            // directly. Every legal winner is accepted; no timing outcome is required.
            let outcome = Result {
                try completion.wait(timeout: .now() + .nanoseconds((index % 32) * 500))
            }
            let accepted = await producer.value
            switch outcome {
            case .success(let received):
                #expect(accepted)
                #expect(received == descriptor)
                _ = Darwin.close(received)
            case .failure(let error):
                #expect(!accepted)
                #expect(error is TorrentStorageBrokerClientError)
                if accepted {
                    // Keep a failing regression test from leaking its fixture.
                    _ = Darwin.close(descriptor)
                }
            }
        }
    }

    @Test("Every broker reply completion cancels its timeout task")
    func replyCompletionCancelsTimeoutTask() async throws {
        let requestID = UUID()
        let reply = TorrentStorageBrokerReply.success(
            requestID: requestID,
            metadata: nil,
            statistics: [],
            fileDescriptor: nil
        )

        let pending = TorrentStorageBrokerPendingReply()
        let installedTimeout = Task.detached { () -> Void in
            _ = try? await ContinuousClock().sleep(for: .seconds(30))
        }
        defer { installedTimeout.cancel() }
        pending.installTimeoutTask(installedTimeout)

        #expect(pending.finish(.success(reply)))
        #expect(installedTimeout.isCancelled)
        guard case .success(let observedID, nil, let statistics, nil) =
            try await pending.wait() else {
            Issue.record("Expected the completed broker reply")
            return
        }
        #expect(observedID == requestID)
        #expect(statistics.isEmpty)
        #expect(!pending.finish(.success(reply)))

        let earlyPending = TorrentStorageBrokerPendingReply()
        #expect(earlyPending.finish(.success(reply)))
        let lateInstalledTimeout = Task.detached { () -> Void in
            _ = try? await ContinuousClock().sleep(for: .seconds(30))
        }
        defer { lateInstalledTimeout.cancel() }
        earlyPending.installTimeoutTask(lateInstalledTimeout)

        #expect(lateInstalledTimeout.isCancelled)
        await installedTimeout.value
        await lateInstalledTimeout.value
    }

    @Test("Reply, timeout, and cancellation race to complete exactly once")
    func terminalCompletionRaceIsExactlyOnce() async throws {
        for _ in 0..<64 {
            try await exerciseTerminalCompletionRace()
        }
    }

    private func exerciseTerminalCompletionRace() async throws {
        let requestID = UUID()
        let reply = TorrentStorageBrokerReply.success(
            requestID: requestID,
            metadata: nil,
            statistics: [],
            fileDescriptor: nil
        )
        let pending = TorrentStorageBrokerPendingReply()
        let barrier = BrokerPendingReplyRaceBarrier(participantCount: 4)
        let completionCount = Mutex(0)
        let waiting = Task<TorrentStorageBrokerReply, any Error> {
            defer { completionCount.withLock { $0 += 1 } }
            return try await pending.wait()
        }
        let attempts = AsyncStream<BrokerPendingReplyAttempt>.makeStream(
            bufferingPolicy: .bufferingNewest(3)
        )

        let replyContender = Task {
            await barrier.arriveAndWait()
            let accepted = pending.finish(.success(reply))
            attempts.continuation.yield(.init(
                terminal: .reply,
                accepted: accepted
            ))
        }
        let cancellationContender = Task {
            await barrier.arriveAndWait()
            let accepted = pending.finish(.failure(CancellationError()))
            attempts.continuation.yield(.init(
                terminal: .cancellation,
                accepted: accepted
            ))
        }
        let timeoutTask = Task.detached {
            await barrier.arriveAndWait()
            let accepted = pending.finish(.failure(
                TorrentStorageBrokerClientError.timedOut
            ))
            attempts.continuation.yield(.init(
                terminal: .timeout,
                accepted: accepted
            ))
        }
        pending.installTimeoutTask(timeoutTask)

        // The fourth participant releases all contenders only after the timeout
        // task belongs to the pending reply, avoiding timing-based coordination.
        await barrier.arriveAndWait()

        var iterator = attempts.stream.makeAsyncIterator()
        var observedAttempts = [BrokerPendingReplyAttempt]()
        for _ in BrokerPendingReplyTerminal.allCases {
            observedAttempts.append(try #require(await iterator.next()))
        }
        attempts.continuation.finish()
        await replyContender.value
        await cancellationContender.value
        await timeoutTask.value

        let acceptedAttempts = observedAttempts.filter(\.accepted)
        let winner = try #require(acceptedAttempts.first)
        #expect(acceptedAttempts.count == 1)
        #expect(
            Set(observedAttempts.map(\.terminal))
                == Set(BrokerPendingReplyTerminal.allCases)
        )
        #expect(timeoutTask.isCancelled)

        let observedTerminal: BrokerPendingReplyTerminal
        do {
            guard case .success(let observedID, nil, let statistics, nil) =
                try await waiting.value else {
                Issue.record("Expected a valid broker reply")
                return
            }
            #expect(observedID == requestID)
            #expect(statistics.isEmpty)
            observedTerminal = .reply
        } catch is CancellationError {
            observedTerminal = .cancellation
        } catch let error as TorrentStorageBrokerClientError {
            guard case .timedOut = error else {
                Issue.record("Expected timeout, received \(error)")
                return
            }
            observedTerminal = .timeout
        } catch {
            Issue.record("Unexpected terminal error: \(error)")
            return
        }
        #expect(observedTerminal == winner.terminal)
        #expect(completionCount.withLock { $0 } == 1)
    }

    // SAFETY: Ownership/lifetime: the returned descriptor remains open and mutable Data is
    // pinned for the synchronous pread; bounds/alignment: exact Data capacity and offset zero
    // are supplied with byte alignment; synchronization: the test exclusively owns both;
    // safe alternative: reading the broker-returned descriptor without a path requires pread.
    @Test("The client accepts an exact regular payload descriptor")
    func exactRegularDescriptorIsAccepted() async throws {
        let broker = try TestStorageBroker(scenario: .valid)
        let client = try await connect(to: broker)
        defer { client.cancel() }

        let descriptor = try await client.openPayload(
            claimID: UUID(),
            generation: 1,
            fileIndex: 0,
            access: .readOnly
        )
        defer { _ = Darwin.close(descriptor) }

        var contents = Data(count: TestStorageBroker.payload.count)
        let bytesRead = unsafe contents.withUnsafeMutableBytes { bytes in
            unsafe Darwin.pread(
                descriptor,
                bytes.baseAddress,
                bytes.count,
                0
            )
        }
        #expect(bytesRead == contents.count)
        #expect(contents == TestStorageBroker.payload)
    }

    @Test(
        "The client rejects substituted broker descriptors",
        arguments: BrokerDescriptorScenario.invalidCases
    )
    fileprivate func substitutedDescriptorsAreRejected(
        _ scenario: BrokerDescriptorScenario
    ) async throws {
        let broker = try TestStorageBroker(scenario: scenario)
        let client = try await connect(to: broker)
        defer { client.cancel() }

        do {
            let descriptor = try await client.openPayload(
                claimID: UUID(),
                generation: 1,
                fileIndex: 0,
                access: scenario.requestedAccess
            )
            _ = Darwin.close(descriptor)
            Issue.record("The substituted descriptor was accepted")
        } catch let error as TorrentStorageBrokerClientError {
            guard case .invalidReply = error else {
                Issue.record("Expected invalidReply, received \(error)")
                return
            }
        } catch {
            Issue.record("Expected a broker client error, received \(error)")
        }
    }

    private func connect(
        to broker: TestStorageBroker
    ) async throws -> TorrentStorageBrokerClient {
        try await TorrentStorageBrokerClient.connect(
            endpoint: broker.endpoint,
            sessionNonce: broker.sessionNonce,
            engineEpoch: UUID(),
            appIdentifier: nil,
            authentication: .reducedAssuranceAdHocDevelopment
        )
    }
}

private enum BrokerPendingReplyTerminal: CaseIterable, Hashable, Sendable {
    case reply
    case timeout
    case cancellation
}

private struct BrokerPendingReplyAttempt: Sendable {
    let terminal: BrokerPendingReplyTerminal
    let accepted: Bool
}

@safe private final class BrokerPendingReplyRaceBarrier: Sendable {
    private struct State: Sendable {
        let participantCount: Int
        var arrivals = 0
        var isOpen = false
        var waiters = [CheckedContinuation<Void, Never>]()
    }

    private let state: Mutex<State>

    init(participantCount: Int) {
        precondition(participantCount > 0)
        state = Mutex(State(participantCount: participantCount))
    }

    func arriveAndWait() async {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            let waiters = state.withLock { state in
                if state.isOpen {
                    return [continuation]
                }
                state.arrivals += 1
                state.waiters.append(continuation)
                guard state.arrivals == state.participantCount else {
                    return [CheckedContinuation<Void, Never>]()
                }
                state.isOpen = true
                let waiters = state.waiters
                state.waiters.removeAll(keepingCapacity: false)
                return waiters
            }
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}

private enum BrokerDescriptorScenario: Equatable, Sendable {
    case valid
    case directory
    case mismatchedSize
    case mismatchedDevice
    case mismatchedInode
    case mismatchedLinkCount
    case mismatchedMode
    case overprivilegedAccess
    case underprivilegedAccess

    static let invalidCases: [Self] = [
        .directory,
        .mismatchedSize,
        .mismatchedDevice,
        .mismatchedInode,
        .mismatchedLinkCount,
        .mismatchedMode,
        .overprivilegedAccess,
        .underprivilegedAccess,
    ]

    var requestedAccess: TorrentStorageBrokerAccess {
        switch self {
        case .valid, .directory, .mismatchedSize, .mismatchedDevice,
             .mismatchedInode, .mismatchedLinkCount, .mismatchedMode,
             .overprivilegedAccess:
            .readOnly
        case .underprivilegedAccess:
            .readWrite
        }
    }
}

@safe private final class TestStorageBroker: Sendable {
    static let payload = Data("brokered payload".utf8)

    let endpoint: XPCEndpoint
    let sessionNonce: UUID

    private let root: URL
    private let listener: XPCListener

    init(scenario: BrokerDescriptorScenario) throws {
        let root = URL.temporaryDirectory.appending(
            path: "TorrentStorageBrokerClientTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let payloadPath = root.appending(path: "payload.bin").path()
        do {
            try Self.payload.write(to: URL(filePath: payloadPath))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }

        let nonce = UUID()
        let listener = XPCListener { request in
            request.accept(
                incomingMessageHandler: { (dictionary: XPCDictionary) in
                    guard let brokerRequest = try? TorrentStorageBrokerIPCCodec
                        .decodeRequest(dictionary),
                          brokerRequest.common.sessionNonce == nonce else {
                        return nil
                    }
                    return Self.response(
                        to: brokerRequest,
                        scenario: scenario,
                        rootPath: root.path(),
                        payloadPath: payloadPath
                    )
                }
            )
        }

        self.root = root
        self.sessionNonce = nonce
        self.listener = listener
        endpoint = listener.endpoint
    }

    deinit {
        listener.cancel()
        try? FileManager.default.removeItem(at: root)
    }

    // SAFETY: Ownership/lifetime: path C strings and local stat storage live through synchronous
    // calls and each descriptor is deferred-closed after XPC duplicates it; bounds/alignment:
    // withCString NUL-terminates paths and stat storage is exact/aligned; synchronization:
    // each response owns local state; safe alternative: adversarial descriptor construction
    // and authentication require direct Darwin open/fstat calls.
    private static func response(
        to request: TorrentStorageBrokerRequest,
        scenario: BrokerDescriptorScenario,
        rootPath: String,
        payloadPath: String
    ) -> XPCDictionary? {
        switch request {
        case .handshake:
            return try? TorrentStorageBrokerIPCCodec.encode(
                .success(
                    requestID: request.common.requestID,
                    metadata: nil,
                    statistics: [],
                    fileDescriptor: nil
                ),
                for: request
            )
        case .openPayload(_, _, _, let fileIndex, _):
            let path = scenario == .directory ? rootPath : payloadPath
            let flags: Int32 = switch scenario {
            case .directory:
                O_RDONLY | O_DIRECTORY | O_CLOEXEC
            case .overprivilegedAccess:
                O_RDWR | O_NOFOLLOW | O_CLOEXEC
            default:
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            }
            let descriptor = unsafe path.withCString { pointer in
                unsafe Darwin.open(pointer, flags)
            }
            guard descriptor >= 0 else {
                return nil
            }
            defer { _ = Darwin.close(descriptor) }

            var status = stat()
            guard unsafe Darwin.fstat(descriptor, &status) == 0 else {
                return nil
            }
            let actualSize = Int64(status.st_size)
            let actualDevice = UInt64(truncatingIfNeeded: status.st_dev)
            let actualInode = UInt64(truncatingIfNeeded: status.st_ino)
            let actualLinkCount = UInt64(truncatingIfNeeded: status.st_nlink)
            let actualMode = UInt32(status.st_mode)
            let metadata = TorrentStorageBrokerFileMetadata(
                fileIndex: fileIndex,
                size: scenario == .mismatchedSize
                    ? actualSize &+ 1
                    : actualSize,
                device: scenario == .mismatchedDevice
                    ? actualDevice &+ 1
                    : actualDevice,
                inode: scenario == .mismatchedInode
                    ? actualInode &+ 1
                    : actualInode,
                linkCount: scenario == .mismatchedLinkCount
                    ? actualLinkCount &+ 1
                    : actualLinkCount,
                mode: scenario == .mismatchedMode
                    ? actualMode ^ UInt32(S_IXUSR)
                    : actualMode
            )
            return try? TorrentStorageBrokerIPCCodec.encode(
                .success(
                    requestID: request.common.requestID,
                    metadata: metadata,
                    statistics: [],
                    fileDescriptor: descriptor
                ),
                for: request
            )
        case .statBatch:
            return try? TorrentStorageBrokerIPCCodec.encode(
                .failure(
                    requestID: request.common.requestID,
                    code: .accessDenied,
                    message: "Unexpected test request."
                ),
                for: request
            )
        }
    }
}
