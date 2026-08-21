import Darwin
import Foundation
import Synchronization
import TorrentEngineCore
import TorrentEngineIPC
import XPC

package enum TorrentStorageBrokerClientError: LocalizedError, Sendable {
    case connectionFailed
    case cancelled
    case timedOut
    case invalidReply
    case rejected(TorrentStorageBrokerFailure, String)

    package var errorDescription: String? {
        switch self {
        case .connectionFailed:
            "The isolated engine could not connect to the storage broker."
        case .cancelled:
            "The storage broker connection ended."
        case .timedOut:
            "The storage broker did not respond before its deadline."
        case .invalidReply:
            "The storage broker returned an invalid response."
        case .rejected(_, let message):
            message.isEmpty ? "The storage broker rejected the request." : message
        }
    }
}

@safe private final class TorrentStorageBrokerBlockingResult<Value: Sendable>: Sendable {
    private enum State: Sendable {
        case waiting
        case finished(Result<Value, any Error>)
        case abandoned
    }

    private let state = Mutex<State>(.waiting)
    private let semaphore = DispatchSemaphore(value: 0)

    func finish(_ result: Result<Value, any Error>) -> Bool {
        let accepted = state.withLock { state in
            guard case .waiting = state else {
                return false
            }
            state = .finished(result)
            return true
        }
        if accepted {
            semaphore.signal()
        }
        return accepted
    }

    func wait(timeout: DispatchTime) throws -> Value {
        guard semaphore.wait(timeout: timeout) == .success else {
            state.withLock { state in
                if case .waiting = state {
                    state = .abandoned
                }
            }
            throw TorrentStorageBrokerClientError.timedOut
        }
        let result = state.withLock { state -> Result<Value, any Error>? in
            guard case .finished(let result) = state else {
                return nil
            }
            state = .abandoned
            return result
        }
        guard let result else {
            throw TorrentStorageBrokerClientError.invalidReply
        }
        return try result.get()
    }
}

@safe private final class TorrentStorageBrokerPendingReply: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<TorrentStorageBrokerReply, any Error>?
        var earlyResult: Result<TorrentStorageBrokerReply, any Error>?
    }

    private let state = Mutex(State())

    func wait() async throws -> TorrentStorageBrokerReply {
        try await withCheckedThrowingContinuation { continuation in
            let earlyResult: Result<TorrentStorageBrokerReply, any Error>? =
                state.withLock { state in
                if let result = state.earlyResult {
                    state.earlyResult = nil
                    return result
                }
                state.continuation = continuation
                return nil
            }
            if let earlyResult {
                continuation.resume(with: earlyResult)
            }
        }
    }

    @discardableResult
    func finish(_ result: Result<TorrentStorageBrokerReply, any Error>) -> Bool {
        let completion: (
            continuation: CheckedContinuation<TorrentStorageBrokerReply, any Error>?,
            didStore: Bool
        ) = state.withLock { state in
            if let continuation = state.continuation {
                state.continuation = nil
                return (continuation, false)
            }
            guard state.earlyResult == nil else {
                return (nil, false)
            }
            state.earlyResult = result
            return (nil, true)
        }
        guard let continuation = completion.continuation else {
            return completion.didStore
        }
        continuation.resume(with: result)
        return true
    }
}

@safe private final class TorrentStorageBrokerClientState: Sendable {
    private struct State: Sendable {
        var isCancelled = false
        var pending = [UUID: TorrentStorageBrokerPendingReply]()
    }

    private let state = Mutex(State())

    func register(
        id: UUID,
        pending: TorrentStorageBrokerPendingReply
    ) -> Bool {
        state.withLock { state in
            guard !state.isCancelled,
                  state.pending.count < 64,
                  state.pending.updateValue(pending, forKey: id) == nil else {
                return false
            }
            return true
        }
    }

    func take(id: UUID) -> TorrentStorageBrokerPendingReply? {
        state.withLock { $0.pending.removeValue(forKey: id) }
    }

    func cancelAll() {
        let pending = state.withLock { state in
            guard !state.isCancelled else {
                return [TorrentStorageBrokerPendingReply]()
            }
            state.isCancelled = true
            let pending = Array(state.pending.values)
            state.pending.removeAll(keepingCapacity: false)
            return pending
        }
        for reply in pending {
            reply.finish(.failure(TorrentStorageBrokerClientError.cancelled))
        }
    }

    var isCancelled: Bool {
        state.withLock(\.isCancelled)
    }
}

@safe package final class TorrentStorageBrokerClient: Sendable {
    private static let requestTimeoutNanoseconds: UInt64 = 5_000_000_000

    private let session: XPCSession
    private let state: TorrentStorageBrokerClientState
    private let engineEpoch: UUID
    private let sessionNonce: UUID

    private init(
        session: XPCSession,
        state: TorrentStorageBrokerClientState,
        engineEpoch: UUID,
        sessionNonce: UUID
    ) {
        self.session = session
        self.state = state
        self.engineEpoch = engineEpoch
        self.sessionNonce = sessionNonce
    }

    package static func connect(
        endpoint: XPCEndpoint,
        sessionNonce: UUID,
        engineEpoch: UUID,
        appIdentifier: String?,
        authentication: TorrentEngineIPCPeerAuthentication
    ) async throws -> TorrentStorageBrokerClient {
        let state = TorrentStorageBrokerClientState()
        let queue = DispatchQueue(
            label: "app.torrent7.engine.storage-broker",
            qos: .userInitiated,
            attributes: .concurrent
        )
        let session: XPCSession
        do {
            session = try XPCSession(
                endpoint: endpoint,
                targetQueue: queue,
                options: .inactive,
                cancellationHandler: { _ in state.cancelAll() }
            )
            if authentication == .sameTeam {
                guard let appIdentifier else {
                    throw TorrentStorageBrokerClientError.connectionFailed
                }
                session.setPeerRequirement(
                    .isFromSameTeam(andMatchesSigningIdentifier: appIdentifier)
                )
            }
            try session.activate()
        } catch let error as TorrentStorageBrokerClientError {
            state.cancelAll()
            throw error
        } catch {
            state.cancelAll()
            throw TorrentStorageBrokerClientError.connectionFailed
        }

        let client = TorrentStorageBrokerClient(
            session: session,
            state: state,
            engineEpoch: engineEpoch,
            sessionNonce: sessionNonce
        )
        do {
            let common = client.common()
            let reply = try await client.send(.handshake(common))
            guard case .success(_, nil, let statistics, nil) = reply,
                  statistics.isEmpty else {
                throw TorrentStorageBrokerClientError.invalidReply
            }
            return client
        } catch {
            client.cancel()
            throw error
        }
    }

    package func openPayload(
        claimID: UUID,
        generation: UInt64,
        fileIndex: Int32,
        access: TorrentStorageBrokerAccess
    ) async throws -> Int32 {
        let request = TorrentStorageBrokerRequest.openPayload(
            common(),
            claimID: claimID,
            generation: generation,
            fileIndex: fileIndex,
            access: access
        )
        let reply = try await send(request)
        guard case .success(_, let metadata?, let statistics, let descriptor?) = reply,
              statistics.isEmpty else {
            throw TorrentStorageBrokerClientError.invalidReply
        }
        do {
            try Self.validate(
                descriptor: descriptor,
                metadata: metadata,
                requestedAccess: access
            )
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    package func statBatch(
        claimID: UUID,
        generation: UInt64,
        fileIndices: [Int32]
    ) async throws -> [TorrentStorageBrokerFileMetadata] {
        let request = TorrentStorageBrokerRequest.statBatch(
            common(),
            claimID: claimID,
            generation: generation,
            fileIndices: fileIndices
        )
        let reply = try await send(request)
        guard case .success(_, nil, let statistics, nil) = reply else {
            throw TorrentStorageBrokerClientError.invalidReply
        }
        return statistics
    }

    package func cancel() {
        state.cancelAll()
        session.cancel(reason: "The engine storage broker client ended")
    }

    deinit {
        cancel()
    }

    private func common() -> TorrentStorageBrokerRequest.Common {
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = now.addingReportingOverflow(
            Self.requestTimeoutNanoseconds
        )
        return TorrentStorageBrokerRequest.Common(
            requestID: UUID(),
            engineEpoch: engineEpoch,
            sessionNonce: sessionNonce,
            deadlineUptimeNanoseconds: deadline.overflow ? UInt64.max : deadline.partialValue
        )
    }

    private func send(
        _ request: TorrentStorageBrokerRequest
    ) async throws -> TorrentStorageBrokerReply {
        guard !state.isCancelled else {
            throw TorrentStorageBrokerClientError.cancelled
        }
        let dictionary = TorrentStorageBrokerIPCCodec.encode(request)
        let requestID = request.common.requestID
        let pending = TorrentStorageBrokerPendingReply()
        guard state.register(id: requestID, pending: pending) else {
            throw TorrentStorageBrokerClientError.connectionFailed
        }

        session.send(message: dictionary) { [state, pending] result in
            let decoded: Result<TorrentStorageBrokerReply, any Error>
            switch result {
            case .success(let dictionary):
                do {
                    decoded = .success(
                        try TorrentStorageBrokerIPCCodec.decodeReply(
                            dictionary,
                            for: request
                        )
                    )
                } catch {
                    decoded = .failure(TorrentStorageBrokerClientError.invalidReply)
                }
            case .failure:
                decoded = .failure(TorrentStorageBrokerClientError.connectionFailed)
            }
            guard state.take(id: requestID) === pending else {
                if case .success(let reply) = decoded {
                    Self.closeDescriptor(in: reply)
                }
                return
            }
            pending.finish(decoded)
        }

        Task.detached { [state, pending] in
            do {
                try await ContinuousClock().sleep(for: .seconds(5))
            } catch {
                return
            }
            guard state.take(id: requestID) === pending else {
                return
            }
            pending.finish(.failure(TorrentStorageBrokerClientError.timedOut))
        }

        let reply = try await withTaskCancellationHandler {
            try await pending.wait()
        } onCancel: { [state, pending] in
            guard state.take(id: requestID) === pending else {
                return
            }
            pending.finish(.failure(CancellationError()))
        }
        if case .failure(_, let code, let message) = reply {
            throw TorrentStorageBrokerClientError.rejected(code, message)
        }
        return reply
    }

    private static func validate(
        descriptor: Int32,
        metadata expected: TorrentStorageBrokerFileMetadata,
        requestedAccess: TorrentStorageBrokerAccess
    ) throws {
        var actual = stat()
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard unsafe Darwin.fstat(descriptor, &actual) == 0,
              flags >= 0,
              (actual.st_mode & S_IFMT) == S_IFREG,
              actual.st_size == expected.size,
              UInt64(truncatingIfNeeded: actual.st_dev) == expected.device,
              UInt64(truncatingIfNeeded: actual.st_ino) == expected.inode,
              UInt64(truncatingIfNeeded: actual.st_nlink) == expected.linkCount,
              UInt32(actual.st_mode) == expected.mode else {
            throw TorrentStorageBrokerClientError.invalidReply
        }
        let mode = flags & O_ACCMODE
        switch requestedAccess {
        case .readOnly:
            guard mode == O_RDONLY else {
                throw TorrentStorageBrokerClientError.invalidReply
            }
        case .readWrite:
            guard mode == O_RDWR else {
                throw TorrentStorageBrokerClientError.invalidReply
            }
        }
    }

    private static func closeDescriptor(in reply: TorrentStorageBrokerReply) {
        guard case .success(_, _, _, let descriptor?) = reply else {
            return
        }
        _ = Darwin.close(descriptor)
    }
}

extension TorrentStorageBrokerClient: TorrentPayloadBrokerAccess {
    package nonisolated func openPayload(
        claimID: UUID,
        generation: UInt64,
        fileIndex: Int32,
        writable: Bool
    ) throws -> Int32 {
        let completion = TorrentStorageBrokerBlockingResult<Int32>()
        Task.detached { [self] in
            let result: Result<Int32, any Error>
            do {
                result = .success(try await openPayload(
                    claimID: claimID,
                    generation: generation,
                    fileIndex: fileIndex,
                    access: writable ? .readWrite : .readOnly
                ))
            } catch {
                result = .failure(error)
            }
            let accepted = completion.finish(result)
            if !accepted, case .success(let descriptor) = result {
                _ = Darwin.close(descriptor)
            }
        }
        do {
            return try completion.wait(timeout: .now() + .seconds(6))
        } catch {
            if error is TorrentStorageBrokerClientError {
                throw Self.bridgeCallError(error)
            }
            throw error
        }
    }

    package nonisolated func payloadSize(
        claimID: UUID,
        generation: UInt64,
        fileIndex: Int32
    ) throws -> Int64 {
        let completion = TorrentStorageBrokerBlockingResult<Int64>()
        Task.detached { [self] in
            let result: Result<Int64, any Error>
            do {
                let metadata = try await statBatch(
                    claimID: claimID,
                    generation: generation,
                    fileIndices: [fileIndex]
                )
                guard metadata.count == 1,
                      metadata[0].fileIndex == fileIndex else {
                    throw TorrentStorageBrokerClientError.invalidReply
                }
                result = .success(metadata[0].size)
            } catch {
                result = .failure(error)
            }
            _ = completion.finish(result)
        }
        do {
            return try completion.wait(timeout: .now() + .seconds(6))
        } catch {
            if error is TorrentStorageBrokerClientError {
                throw Self.bridgeCallError(error)
            }
            throw error
        }
    }

    private nonisolated static func bridgeCallError(
        _ error: any Error
    ) -> TorrentPayloadBrokerCallError {
        let number: Int32
        switch error {
        case TorrentStorageBrokerClientError.rejected(let failure, _):
            number = switch failure {
            case .accessDenied, .sessionRejected:
                EACCES
            case .claimUnavailable, .generationMismatch, .filesystemObjectChanged:
                ESTALE
            case .fileUnavailable:
                ENOENT
            case .deadlineExceeded:
                ETIMEDOUT
            case .malformedRequest:
                EINVAL
            case .internalFailure:
                EIO
            }
        case TorrentStorageBrokerClientError.timedOut:
            number = ETIMEDOUT
        case TorrentStorageBrokerClientError.cancelled:
            number = ECANCELED
        default:
            number = EIO
        }
        return TorrentPayloadBrokerCallError(errorNumber: number)
    }
}
