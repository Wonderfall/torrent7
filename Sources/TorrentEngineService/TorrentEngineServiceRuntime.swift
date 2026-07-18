import Darwin
import Foundation
import TorrentEngineCore
import TorrentEngineIPC
import TorrentEngineModel
import TorrentEngineServiceSupport
import TorrentNetworkSecurity
import XPC

private enum TorrentEngineServiceRuntimeError: LocalizedError {
    case controllerBusy
    case handshakeRequired
    case handshakeAlreadyCompleted
    case invalidController
    case invalidEpoch
    case invalidSequence
    case replayedOperation
    case replayedRequest
    case concurrentRequest
    case serviceShuttingDown
    case invalidPayload
    case payloadTooLarge
    case unexpectedFileDescriptor
    case missingFileDescriptor
    case invalidFolderGrant
    case invalidFolderCapability
    case folderAuthorizationInUse
    case invalidTorrentIdentifier
    case invalidMagnet
    case invalidTorrentFile
    case invalidFilePriorities
    case unsupportedOperation
    case tooManyOpenDatasets
    case datasetStorageLimitExceeded
    case unknownDataset
    case invalidDatasetPage
    case stateMigrationUnavailable
    case stateMigrationAlreadyActive
    case networkBindingRejected(TorrentNetworkBindingBlockReason)

    var errorDescription: String? {
        switch self {
        case .controllerBusy:
            "The isolated torrent engine already has a controller."
        case .handshakeRequired:
            "A torrent engine handshake is required first."
        case .handshakeAlreadyCompleted:
            "The torrent engine handshake was already completed."
        case .invalidController:
            "The torrent engine controller identity is invalid."
        case .invalidEpoch:
            "The torrent engine process epoch changed."
        case .invalidSequence:
            "The torrent engine request sequence is invalid."
        case .replayedOperation:
            "A replayed torrent engine operation was rejected."
        case .replayedRequest:
            "A replayed torrent engine request was rejected."
        case .concurrentRequest:
            "Concurrent torrent engine requests are not permitted."
        case .serviceShuttingDown:
            "The isolated torrent engine is shutting down safely."
        case .invalidPayload:
            "The torrent engine request payload is invalid."
        case .payloadTooLarge:
            "The torrent engine request payload exceeds its operation limit."
        case .unexpectedFileDescriptor:
            "This torrent engine operation does not accept a file descriptor."
        case .missingFileDescriptor:
            "The state migration file descriptor is missing."
        case .invalidFolderGrant:
            "The download folder authorization request is invalid."
        case .invalidFolderCapability:
            "The download folder authorization is unavailable or changed."
        case .folderAuthorizationInUse:
            "Too many download folders are still in use by active torrents. Remove affected torrents before replacing these folders."
        case .invalidTorrentIdentifier:
            "The torrent identifier is invalid."
        case .invalidMagnet:
            "The magnet URI is invalid or too large."
        case .invalidTorrentFile:
            "The torrent file is empty or too large."
        case .invalidFilePriorities:
            "The torrent file priorities are invalid."
        case .unsupportedOperation:
            "The requested torrent engine operation is not supported."
        case .tooManyOpenDatasets:
            "Too many torrent engine datasets are open."
        case .datasetStorageLimitExceeded:
            "The torrent engine dataset storage limit was exceeded."
        case .unknownDataset:
            "The torrent engine dataset is unavailable or expired."
        case .invalidDatasetPage:
            "The requested torrent engine dataset page is invalid."
        case .stateMigrationUnavailable:
            "The legacy torrent state migration is unavailable."
        case .stateMigrationAlreadyActive:
            "A legacy torrent state migration is already active."
        case .networkBindingRejected(let reason):
            reason.userMessage
        }
    }
}

private struct TorrentEngineServiceDataset: Sendable {
    let descriptor: TorrentEngineIPCDatasetDescriptor
    let ownerControllerID: UUID
    let pages: [Data]
    let byteCount: Int
    let expiresAt: ContinuousClock.Instant
}

private struct TorrentEngineControllerLease: Equatable, Sendable {
    let peerToken: UUID
    let controllerID: UUID
    let generation: UUID
}

struct TorrentEngineServiceRuntimeDiagnostics: Equatable, Sendable {
    let hasActivePeer: Bool
    let hasActiveController: Bool
    let hasActiveControllerGeneration: Bool
    let hasActiveSession: Bool
    let hasEngine: Bool
    let hasActiveMigration: Bool
    let transactionIsActive: Bool
    let isShuttingDown: Bool
}

enum TorrentEngineServiceRequestDisposition: Equatable, Sendable {
    case continuePeer
    case retirePeerAfterReply
    case terminatePeer
}

enum TorrentEngineServiceNetworkContainmentResult: Equatable, Sendable {
    case blocked
    case engineUnavailable
}

@safe actor TorrentEngineServiceRuntime {
    private static let datasetLifetime: Duration = .seconds(30)
    private static let changeHintMinimumInterval: Duration = .milliseconds(100)
    private static let maximumRememberedIdentifiers = 4_096

    private let engineEpoch = UUID()
    private let stateDirectory: URL
    private let capabilityRegistry: TorrentFolderCapabilityRegistry
    private let migrationCoordinator: TorrentLegacyStateMigrationCoordinator
    private let transactionBegin: @Sendable () -> Void
    private let transactionEnd: @Sendable () -> Void
    private let containmentWatchdog: TorrentEngineServiceContainmentWatchdog
    private let cleanupWatchdog: TorrentEngineServiceContainmentWatchdog
    private let clock = ContinuousClock()

    private var activePeerToken: UUID?
    private var activeControllerID: UUID?
    private var activeControllerGeneration: UUID?
    private var activeSession: TorrentEngineServiceSessionHandle?
    private var lastSequence: UInt64 = 0
    private var recentOperationIDs = [UUID]()
    private var recentOperationIDSet = Set<UUID>()
    private var recentRequestIDs = [UUID]()
    private var recentRequestIDSet = Set<UUID>()
    private var hintSequence: UInt64 = 1
    private var hintTask: Task<Void, Never>?
    private var engine: TorrentEngine?
    private var networkAuthority: TorrentNetworkBindingAuthority?
    private var networkAuthorityID: UUID?
    private var networkAuthorityStartIsPending = false
    private var activeMigrationID: UUID?
    private var datasetsByID = [UUID: TorrentEngineServiceDataset]()
    private var transactionIsActive = false
    private var isShuttingDown = false
    private var isHandlingRequest = false

    init(
        stateDirectory: URL,
        containmentWatchdog: TorrentEngineServiceContainmentWatchdog = .init(),
        cleanupWatchdog: TorrentEngineServiceContainmentWatchdog = .init(
            timeout: .seconds(300)
        ),
        transactionBegin: @escaping @Sendable () -> Void = { xpc_transaction_begin() },
        transactionEnd: @escaping @Sendable () -> Void = { xpc_transaction_end() }
    ) throws {
        self.stateDirectory = stateDirectory
        self.containmentWatchdog = containmentWatchdog
        self.cleanupWatchdog = cleanupWatchdog
        self.transactionBegin = transactionBegin
        self.transactionEnd = transactionEnd
        capabilityRegistry = TorrentFolderCapabilityRegistry(engineEpoch: engineEpoch)
        migrationCoordinator = try TorrentLegacyStateMigrationCoordinator(
            engineEpoch: engineEpoch,
            stateDirectoryURL: stateDirectory
        )
    }

    func diagnostics() -> TorrentEngineServiceRuntimeDiagnostics {
        TorrentEngineServiceRuntimeDiagnostics(
            hasActivePeer: activePeerToken != nil,
            hasActiveController: activeControllerID != nil,
            hasActiveControllerGeneration: activeControllerGeneration != nil,
            hasActiveSession: activeSession != nil,
            hasEngine: engine != nil,
            hasActiveMigration: activeMigrationID != nil,
            transactionIsActive: transactionIsActive,
            isShuttingDown: isShuttingDown
        )
    }

    func handle(
        _ request: TorrentEngineIPCRequest,
        from peerToken: UUID,
        session: TorrentEngineServiceSessionHandle,
        peerIsCancelled: @Sendable () -> Bool,
        pendingReply: TorrentEnginePendingReply
    ) async -> TorrentEngineServiceRequestDisposition {
        var shouldEndTransactionAfterReply = false
        var didRecordRequest = false
        var ownedFileDescriptor = request.fileDescriptor
        defer {
            if let ownedFileDescriptor {
                Darwin.close(ownedFileDescriptor)
            }
        }

        guard !peerIsCancelled() else {
            return .terminatePeer
        }

        guard !isHandlingRequest else {
            let inFlightError: TorrentEngineServiceRuntimeError
            let failureCode = Self.inFlightFailureCode(
                activePeerToken: activePeerToken,
                incomingPeerToken: peerToken,
                isShuttingDown: isShuttingDown
            )
            switch failureCode {
            case .controllerBusy:
                inFlightError = .controllerBusy
            case .serviceShuttingDown:
                inFlightError = .serviceShuttingDown
            case .operationRejected:
                inFlightError = .concurrentRequest
            }
            do {
                try sendReply(
                    for: request.header,
                    status: .failure,
                    payload: nil,
                    failureCode: failureCode,
                    errorMessage: Self.failureMessage(for: inFlightError),
                    pendingReply: pendingReply
                )
            } catch {
                session.cancel(reason: "Torrent engine transient rejection serialization failed")
                return .terminatePeer
            }
            if Self.isTransientAdmissionFailure(failureCode) {
                // The establishing client closes its contender after decoding
                // this typed reply. Cancelling here can let XPC invalidation
                // overtake the reply and erase the retry classification.
                return .retirePeerAfterReply
            }
            session.cancel(reason: "Overlapping torrent engine request rejected")
            return .terminatePeer
        }
        isHandlingRequest = true
        defer {
            isHandlingRequest = false
        }

        do {
            if let payload = request.payload,
               payload.count > request.header.operation.maximumRequestPayloadBytes {
                throw TorrentEngineServiceRuntimeError.payloadTooLarge
            }

            let controllerLease = try validateAndRecord(
                header: request.header,
                peerToken: peerToken,
                session: session
            )
            didRecordRequest = true

            let transferredFileDescriptor: Int32?
            if request.header.operation == .importStateMigrationFile {
                guard let descriptor = ownedFileDescriptor else {
                    throw TorrentEngineServiceRuntimeError.missingFileDescriptor
                }
                transferredFileDescriptor = descriptor
                ownedFileDescriptor = nil
            } else {
                guard ownedFileDescriptor == nil else {
                    throw TorrentEngineServiceRuntimeError.unexpectedFileDescriptor
                }
                transferredFileDescriptor = nil
            }

            let payload = try await dispatch(
                request,
                fileDescriptor: transferredFileDescriptor,
                controllerLease: controllerLease
            )
            if request.header.operation == .shutdown {
                shouldEndTransactionAfterReply = true
            }
            if request.header.operation != .shutdown {
                try requireActiveController(controllerLease)
            }
            guard !peerIsCancelled() else {
                await beginDisconnect(peerToken: peerToken)
                if shouldEndTransactionAfterReply {
                    endTransactionIfNeeded()
                }
                return .terminatePeer
            }
            try sendReply(
                for: request.header,
                status: .success,
                payload: payload,
                errorMessage: nil,
                pendingReply: pendingReply
            )
            if shouldEndTransactionAfterReply {
                session.cancel(reason: "Torrent engine shutdown completed")
                endTransactionIfNeeded()
                return .terminatePeer
            }
            return .continuePeer
        } catch {
            if error is TorrentEngineIPCError {
                // Response serialization is commit-ambiguous: a native
                // mutation may already have succeeded. Never report this as a
                // normal rejection or keep accepting guessed successor state.
                await terminateActiveControllerAfterSecurityBoundaryFailure(
                    reason: "Torrent engine response serialization failed"
                )
                session.cancel(reason: "Torrent engine response serialization failed")
                if request.header.operation == .shutdown {
                    endTransactionIfNeeded()
                }
                return .terminatePeer
            }
            var shouldTerminatePeerAfterReply = !didRecordRequest
            if (request.header.operation == .handshake
                    || request.header.operation == .beginStateMigration),
               engine == nil,
               activeMigrationID == nil {
                shouldEndTransactionAfterReply = await releaseFailedInitialController(
                    peerToken: peerToken,
                    endsTransaction: false
                ) || shouldEndTransactionAfterReply
                shouldTerminatePeerAfterReply = shouldEndTransactionAfterReply
                    || shouldTerminatePeerAfterReply
            }
            let failureCode = Self.failureCode(for: error)
            let isTransientAdmissionFailure = Self.isTransientAdmissionFailure(failureCode)
            guard !peerIsCancelled(), !isShuttingDown || isTransientAdmissionFailure else {
                if shouldEndTransactionAfterReply {
                    endTransactionIfNeeded()
                }
                return .terminatePeer
            }
            do {
                try sendReply(
                    for: request.header,
                    status: .failure,
                    payload: nil,
                    failureCode: failureCode,
                    errorMessage: Self.failureMessage(for: error),
                    pendingReply: pendingReply
                )
            } catch {
                session.cancel(reason: "Torrent engine rejection serialization failed")
                if shouldEndTransactionAfterReply {
                    endTransactionIfNeeded()
                }
                return .terminatePeer
            }
            if shouldEndTransactionAfterReply {
                session.cancel(reason: "Torrent engine initialization failed")
                endTransactionIfNeeded()
                return .terminatePeer
            }
            if shouldTerminatePeerAfterReply {
                if isTransientAdmissionFailure {
                    return .retirePeerAfterReply
                }
                // A protocol-state rejection before sequence recording leaves
                // the peer unable to resynchronize safely. Close it after the
                // correlated failure reply instead of keeping a zombie
                // controller or accepting a guessed successor sequence.
                session.cancel(reason: "Torrent engine protocol state rejected")
                return .terminatePeer
            }
            return .continuePeer
        }
    }

    func beginDisconnect(peerToken: UUID) async {
        guard activePeerToken == peerToken else {
            return
        }
        guard !isShuttingDown else {
            return
        }
        isShuttingDown = true
        activeControllerGeneration = nil
        hintTask?.cancel()
        hintTask = nil
        if let networkAuthority {
            await networkAuthority.forceBlock(reason: .controllerDisconnected)
        }
        if let engine {
            do {
                _ = try await engine.blockNetworkNow()
            } catch {
                await engine.forceContainmentAfterNetworkBlockFailure(
                    detail: error.localizedDescription
                )
            }
        }
    }

    func finishDisconnect(
        peerToken: UUID,
        endsTransaction: Bool = true
    ) async {
        guard activePeerToken == peerToken,
              let controllerID = activeControllerID else {
            return
        }
        if !isShuttingDown {
            await beginDisconnect(peerToken: peerToken)
        }
        let cleanupToken = cleanupWatchdog.arm()
        defer {
            cleanupWatchdog.disarm(cleanupToken)
        }
        await finishShutDownActiveController(
            controllerID: controllerID,
            endsTransaction: endsTransaction
        )
    }

    private func validateAndRecord(
        header: TorrentEngineIPCHeader,
        peerToken: UUID,
        session: TorrentEngineServiceSessionHandle
    ) throws -> TorrentEngineControllerLease {
        guard !isShuttingDown else {
            throw TorrentEngineServiceRuntimeError.serviceShuttingDown
        }

        if let activePeerToken {
            guard activePeerToken == peerToken else {
                throw TorrentEngineServiceRuntimeError.controllerBusy
            }
            guard activeControllerID == header.controllerID else {
                throw TorrentEngineServiceRuntimeError.invalidController
            }
            guard activeControllerGeneration != nil else {
                throw TorrentEngineServiceRuntimeError.invalidController
            }
            guard lastSequence != UInt64.max,
                  header.sequence == lastSequence + 1 else {
                throw TorrentEngineServiceRuntimeError.invalidSequence
            }
        } else {
            guard header.operation == .handshake
                    || header.operation == .beginStateMigration else {
                throw TorrentEngineServiceRuntimeError.handshakeRequired
            }
            guard header.sequence == 1,
                  header.expectedEpoch == nil else {
                throw TorrentEngineServiceRuntimeError.invalidSequence
            }
            activePeerToken = peerToken
            activeControllerID = header.controllerID
            activeControllerGeneration = UUID()
            activeSession = session
            beginTransactionIfNeeded()
        }

        switch header.operation {
        case .handshake, .beginStateMigration, .importStateMigrationFile,
             .commitStateMigration, .abortStateMigration:
            guard engine == nil else {
                throw TorrentEngineServiceRuntimeError.handshakeAlreadyCompleted
            }
            guard header.expectedEpoch == nil else {
                throw TorrentEngineServiceRuntimeError.invalidEpoch
            }
        default:
            guard engine != nil else {
                throw TorrentEngineServiceRuntimeError.handshakeRequired
            }
            guard header.expectedEpoch == engineEpoch else {
                throw TorrentEngineServiceRuntimeError.invalidEpoch
            }
        }

        guard !recentOperationIDSet.contains(header.operationID) else {
            throw TorrentEngineServiceRuntimeError.replayedOperation
        }
        guard !recentRequestIDSet.contains(header.requestID) else {
            throw TorrentEngineServiceRuntimeError.replayedRequest
        }

        lastSequence = header.sequence
        remember(
            header.operationID,
            order: &recentOperationIDs,
            membership: &recentOperationIDSet
        )
        remember(
            header.requestID,
            order: &recentRequestIDs,
            membership: &recentRequestIDSet
        )

        guard let generation = activeControllerGeneration else {
            throw TorrentEngineServiceRuntimeError.invalidController
        }
        return TorrentEngineControllerLease(
            peerToken: peerToken,
            controllerID: header.controllerID,
            generation: generation
        )
    }

    private func remember(
        _ identifier: UUID,
        order: inout [UUID],
        membership: inout Set<UUID>
    ) {
        order.append(identifier)
        membership.insert(identifier)
        if order.count > Self.maximumRememberedIdentifiers {
            let discarded = order.removeFirst()
            membership.remove(discarded)
        }
    }

    private func dispatch(
        _ request: TorrentEngineIPCRequest,
        fileDescriptor: Int32?,
        controllerLease: TorrentEngineControllerLease
    ) async throws -> Data {
        let operation = request.header.operation
        let scope = TorrentEngineServiceScope(
            engineEpoch: engineEpoch,
            controllerID: request.header.controllerID
        )

        switch operation {
        case .handshake:
            let value = try decode(TorrentEngineIPCHandshakeRequest.self, from: request)
            return try await handleHandshake(
                value,
                scope: scope,
                operation: operation,
                controllerLease: controllerLease
            )
        case .restart:
            let value = try decode(TorrentEngineIPCRestartRequest.self, from: request)
            try await handleRestart(value, scope: scope, controllerLease: controllerLease)
            return try encode(TorrentEngineIPCEmpty(), for: operation)
        case .shutdown:
            _ = try decode(TorrentEngineIPCEmpty.self, from: request)
            await shutDownActiveController(endsTransaction: false)
            return try encode(TorrentEngineIPCEmpty(), for: operation)
        case .poll:
            let value = try decode(TorrentEngineIPCPollRequest.self, from: request)
            return try await handlePoll(
                value,
                scope: scope,
                operation: operation,
                controllerLease: controllerLease
            )
        case .grantFolderCapability:
            let value = try decode(TorrentEngineIPCFolderGrant.self, from: request)
            return try await handleGrantFolder(
                value,
                scope: scope,
                operation: operation,
                controllerLease: controllerLease
            )
        case .revokeFolderCapability:
            let value = try decode(TorrentEngineIPCRevokeFolderRequest.self, from: request)
            try await handleRevokeFolder(
                value,
                scope: scope,
                controllerLease: controllerLease
            )
            return try encode(TorrentEngineIPCEmpty(), for: operation)
        case .replaceFolderCapabilities:
            let value = try decode(TorrentEngineIPCReplaceFoldersRequest.self, from: request)
            return try await handleReplaceFolders(
                value,
                scope: scope,
                operation: operation,
                controllerLease: controllerLease
            )

        case .previewTorrentFile:
            guard let value = request.payload else {
                throw TorrentEngineServiceRuntimeError.invalidPayload
            }
            try Self.validateTorrentData(value)
            let preview = try await requireEngine().previewTorrentFile(data: value)
            return try encode(TorrentEngineIPCFilePreviewResponse(preview), for: operation)
        case .addMagnet:
            let value = try decode(TorrentEngineIPCAddMagnetRequest.self, from: request)
            let identifier = try await handleAddMagnet(
                value,
                scope: scope,
                controllerLease: controllerLease
            )
            return try encode(
                TorrentEngineIPCAddedTorrentResponse(identifier: identifier),
                for: operation
            )
        case .addTorrentFile:
            let value = try decode(TorrentEngineIPCAddTorrentFileRequest.self, from: request)
            let identifier = try await handleAddTorrentFile(
                value,
                scope: scope,
                controllerLease: controllerLease
            )
            return try encode(
                TorrentEngineIPCAddedTorrentResponse(identifier: identifier),
                for: operation
            )
        case .pause:
            let value = try decodeTorrentIDRequest(request)
            try await requireEngine().pause(id: value.id)
            return try encode(TorrentEngineIPCEmpty(), for: operation)
        case .resume:
            let value = try decodeTorrentIDRequest(request)
            try await requireEngine().resume(id: value.id)
            return try encode(TorrentEngineIPCEmpty(), for: operation)
        case .reannounce:
            let value = try decodeTorrentIDRequest(request)
            try await requireEngine().reannounce(id: value.id)
            return try encode(TorrentEngineIPCEmpty(), for: operation)
        case .forceRecheck:
            let value = try decodeTorrentIDRequest(request)
            try await requireEngine().forceRecheck(id: value.id)
            return try encode(TorrentEngineIPCEmpty(), for: operation)
        case .remove:
            let value = try decode(TorrentEngineIPCRemoveRequest.self, from: request)
            try Self.validateTorrentID(value.id)
            let outcome = try await requireEngine().remove(
                id: value.id,
                deleteFiles: value.deleteFiles
            )
            return try encode(
                TorrentEngineIPCRemovalResponse(outcome: outcome),
                for: operation
            )

        case .applySettings:
            let value = try decode(TorrentEngineIPCApplySettingsRequest.self, from: request)
            try await applySettings(value, controllerLease: controllerLease)
            return try encode(TorrentEngineIPCEmpty(), for: operation)
        case .blockNetwork:
            _ = try decode(TorrentEngineIPCEmpty.self, from: request)
            do {
                if let networkAuthority {
                    await networkAuthority.forceBlock(reason: .controllerRequested)
                } else {
                    try await blockNetworkWithinContainmentDeadline(requireEngine())
                }
                try requireActiveController(controllerLease)
            } catch {
                await terminateActiveControllerAfterSecurityBoundaryFailure(
                    reason: "Torrent engine network block failed"
                )
                throw error
            }
            return try encode(TorrentEngineIPCEmpty(), for: operation)
        case .saveAll:
            _ = try decode(TorrentEngineIPCEmpty.self, from: request)
            try await requireEngine().saveAllChecked()
            return try encode(TorrentEngineIPCEmpty(), for: operation)

        case .requestSources:
            let value = try decodeTorrentIDRequest(request)
            try await requireEngine().requestSources(id: value.id)
            return try encode(TorrentEngineIPCEmpty(), for: operation)
        case .sourcePolicy:
            let value = try decodeTorrentIDRequest(request)
            return try await encode(requireEngine().sourcePolicy(id: value.id), for: operation)
        case .setSourcePolicy:
            let value = try decode(TorrentEngineIPCSetSourcePolicyRequest.self, from: request)
            try Self.validateTorrentID(value.id)
            try await requireEngine().setSourcePolicy(
                id: value.id,
                field: value.field,
                enabled: value.enabled
            )
            return try encode(TorrentEngineIPCEmpty(), for: operation)
        case .torrentOptions:
            let value = try decodeTorrentIDRequest(request)
            return try await encode(requireEngine().torrentOptions(id: value.id), for: operation)
        case .setTorrentOptions:
            let value = try decode(TorrentEngineIPCSetTorrentOptionsRequest.self, from: request)
            try Self.validateTorrentID(value.id)
            try await requireEngine().setTorrentOptions(id: value.id, options: value.options)
            return try encode(TorrentEngineIPCEmpty(), for: operation)
        case .moveTorrentInQueue:
            let value = try decode(TorrentEngineIPCMoveQueueRequest.self, from: request)
            try Self.validateTorrentID(value.id)
            try await requireEngine().moveTorrentInQueue(id: value.id, move: value.move)
            return try encode(TorrentEngineIPCEmpty(), for: operation)
        case .requestFiles:
            let value = try decodeTorrentIDRequest(request)
            try await requireEngine().requestFiles(id: value.id)
            return try encode(TorrentEngineIPCEmpty(), for: operation)
        case .setFilePriority:
            let value = try decode(TorrentEngineIPCSetFilePriorityRequest.self, from: request)
            try Self.validateTorrentID(value.id)
            guard (0..<TorrentEngineLimits.maximumFileCount).contains(Int(value.fileIndex)) else {
                throw TorrentEngineServiceRuntimeError.invalidFilePriorities
            }
            try await requireEngine().setFilePriority(
                id: value.id,
                fileIndex: value.fileIndex,
                priority: value.priority
            )
            return try encode(TorrentEngineIPCEmpty(), for: operation)
        case .requestPieceMap:
            let value = try decodeTorrentIDRequest(request)
            try await requireEngine().requestPieceMap(id: value.id)
            return try encode(TorrentEngineIPCEmpty(), for: operation)

        case .trackerBatch:
            let value = try decodeTorrentRevisionRequest(request)
            let batch = try await requireEngine().trackerBatch(id: value.id, since: value.revision)
            return try encodeOptional(batch, for: operation)
        case .webSeedBatch:
            let value = try decodeTorrentRevisionRequest(request)
            let batch = try await requireEngine().webSeedBatch(id: value.id, since: value.revision)
            return try encodeOptional(batch, for: operation)
        case .webSeedActivity:
            let value = try decodeTorrentIDRequest(request)
            return try await encodeOptional(
                requireEngine().webSeedActivity(id: value.id),
                for: operation
            )
        case .peerSources:
            let value = try decodeTorrentIDRequest(request)
            return try await encodeOptional(
                requireEngine().peerSources(id: value.id),
                for: operation
            )
        case .fileBatch:
            let value = try decodeTorrentRevisionRequest(request)
            let batch = try await requireEngine().fileBatch(id: value.id, since: value.revision)
            return try encodeOptional(batch, for: operation)
        case .pieceMapBatch:
            let value = try decodeTorrentRevisionRequest(request)
            let batch = try await requireEngine().pieceMapBatch(id: value.id, since: value.revision)
            return try encodeOptional(batch, for: operation)

        case .readDataset:
            let value = try decode(TorrentEngineIPCReadDatasetRequest.self, from: request)
            let page = try readDataset(value, controllerID: scope.controllerID)
            return try encode(page, for: operation)
        case .closeDataset:
            let value = try decode(TorrentEngineIPCCloseDatasetRequest.self, from: request)
            try closeDataset(value.id, controllerID: scope.controllerID)
            return try encode(TorrentEngineIPCEmpty(), for: operation)

        case .beginStateMigration:
            _ = try decode(TorrentEngineIPCEmpty.self, from: request)
            return try beginMigration(scope: scope, operation: operation)
        case .importStateMigrationFile:
            guard let fileDescriptor else {
                throw TorrentEngineServiceRuntimeError.missingFileDescriptor
            }
            return try importMigrationFile(
                request,
                fileDescriptor: fileDescriptor,
                scope: scope,
                operation: operation
            )
        case .commitStateMigration:
            _ = try decode(TorrentEngineIPCEmpty.self, from: request)
            return try commitMigration(scope: scope, operation: operation)
        case .abortStateMigration:
            _ = try decode(TorrentEngineIPCEmpty.self, from: request)
            return try abortMigration(scope: scope, operation: operation)

        case .changeHint:
            throw TorrentEngineServiceRuntimeError.unsupportedOperation
        }
    }

    private func handleHandshake(
        _ request: TorrentEngineIPCHandshakeRequest,
        scope: TorrentEngineServiceScope,
        operation: TorrentEngineIPCOperation,
        controllerLease: TorrentEngineControllerLease
    ) async throws -> Data {
        guard engine == nil else {
            throw TorrentEngineServiceRuntimeError.handshakeAlreadyCompleted
        }
        guard activeMigrationID == nil else {
            throw TorrentEngineServiceRuntimeError.stateMigrationAlreadyActive
        }
        let replacement: TorrentFolderCapabilityReplacement
        do {
            replacement = try capabilityRegistry.prepareCommittedGrantReplacement(
                bookmarkData: request.folders.map(\.bookmark),
                scope: scope
            )
        } catch {
            throw TorrentEngineServiceRuntimeError.invalidFolderGrant
        }
        let authorizedRoots: [TorrentAuthorizedSaveRoot]
        do {
            authorizedRoots = try Self.authorizedRoots(for: replacement.pins)
        } catch {
            throw TorrentEngineServiceRuntimeError.invalidFolderGrant
        }
        // Native construction restores service-owned state and starts the
        // alert worker synchronously. Cover that work, and any cleanup after
        // partial startup, before entering the bridge.
        let startupToken = cleanupWatchdog.arm()
        defer {
            cleanupWatchdog.disarm(startupToken)
        }
        let created = try TorrentEngine(
            stateDirectory: stateDirectory,
            enablePeerExchangePlugin: request.enablePeerExchangePlugin,
            authorizedSaveRoots: authorizedRoots
        )
        engine = created
        do {
            // The bridge starts paused and blocked. Repeat the block explicitly
            // at the trust boundary before exposing a successful handshake.
            try await blockNetworkWithinContainmentDeadline(created)
            try requireActiveController(controllerLease)
            let capabilities = try capabilityRegistry.commit(replacement)
            let response = TorrentEngineIPCHandshakeResponse(
                libtorrentVersion: created.libtorrentVersion,
                folders: capabilities.map {
                    TorrentEngineIPCGrantedFolder(
                        capabilityID: $0.id,
                        resolvedPath: $0.canonicalPath
                    )
                }
            )
            let responsePayload = try encode(response, for: operation)
            startChangeHints(for: created, controllerID: scope.controllerID)
            let authority = networkBindingAuthority()
            networkAuthorityStartIsPending = true
            let networkAuthorityStarted = await authority.start()
            networkAuthorityStartIsPending = false
            guard networkAuthorityStarted else {
                throw TorrentEngineServiceRuntimeError.networkBindingRejected(.monitorNotReady)
            }
            try requireActiveController(controllerLease)
            return responsePayload
        } catch {
            hintTask?.cancel()
            hintTask = nil
            if engine === created {
                engine = nil
            }
            try? await created.shutdownSafely()
            throw error
        }
    }

    private func handleRestart(
        _ request: TorrentEngineIPCRestartRequest,
        scope: TorrentEngineServiceScope,
        controllerLease: TorrentEngineControllerLease
    ) async throws {
        guard request.capabilityIDs.count <= TorrentEngineLimits.maximumAuthorizedSavePathCount,
              Set(request.capabilityIDs).count == request.capabilityIDs.count else {
            throw TorrentEngineServiceRuntimeError.invalidFolderCapability
        }

        var pins = [TorrentFolderCapabilityPin]()
        let authorizedRoots: [TorrentAuthorizedSaveRoot]
        pins.reserveCapacity(request.capabilityIDs.count)
        do {
            for capabilityID in request.capabilityIDs {
                let pin = try capabilityRegistry.pin(capabilityID: capabilityID, scope: scope)
                pins.append(pin)
            }
            authorizedRoots = try Self.authorizedRoots(for: pins)
        } catch {
            throw TorrentEngineServiceRuntimeError.invalidFolderCapability
        }

        datasetsByID.removeAll()
        do {
            if let networkAuthority {
                await networkAuthority.forceBlock(reason: .authorizationReplaced)
            } else {
                try await blockNetworkWithinContainmentDeadline(requireEngine())
            }
            try requireActiveController(controllerLease)
            let restartedEngine = try requireEngine()
            let cleanupToken = cleanupWatchdog.arm()
            do {
                try await restartedEngine.restart(
                    enablePeerExchangePlugin: request.enablePeerExchangePlugin,
                    authorizedSaveRoots: authorizedRoots
                )
                cleanupWatchdog.disarm(cleanupToken)
            } catch {
                cleanupWatchdog.disarm(cleanupToken)
                throw error
            }
            try requireActiveController(controllerLease)

            let retainedIDs = Set(request.capabilityIDs)
            for capabilityID in request.capabilityIDs {
                _ = try capabilityRegistry.commit(capabilityID: capabilityID, scope: scope)
            }
            for capability in capabilityRegistry.capabilities(controllerID: scope.controllerID)
            where !retainedIDs.contains(capability.id) {
                _ = try capabilityRegistry.revoke(capabilityID: capability.id, scope: scope)
            }
        } catch {
            await terminateActiveControllerAfterSecurityBoundaryFailure(
                reason: "Torrent engine restart failed"
            )
            throw error
        }
    }

    private func handleGrantFolder(
        _ request: TorrentEngineIPCFolderGrant,
        scope: TorrentEngineServiceScope,
        operation: TorrentEngineIPCOperation,
        controllerLease: TorrentEngineControllerLease
    ) async throws -> Data {
        let capability: TorrentFolderCapability
        do {
            capability = try capabilityRegistry.grantProvisional(
                bookmarkData: request.bookmark,
                scope: scope
            )
        } catch {
            throw TorrentEngineServiceRuntimeError.invalidFolderGrant
        }

        do {
            let roots = try authorizedRoots(scope: scope)
            try await requireEngine().replaceAuthorizedSaveRoots(roots)
            try requireActiveController(controllerLease)
        } catch {
            _ = try? capabilityRegistry.revoke(capabilityID: capability.id, scope: scope)
            await restoreAuthorizedRootsOrTerminate(
                scope: scope,
                reason: "Torrent engine folder grant rollback failed"
            )
            throw error
        }

        return try encode(
            TorrentEngineIPCGrantFolderResponse(
                folder: TorrentEngineIPCGrantedFolder(
                    capabilityID: capability.id,
                    resolvedPath: capability.canonicalPath
                )
            ),
            for: operation
        )
    }

    private func handleRevokeFolder(
        _ request: TorrentEngineIPCRevokeFolderRequest,
        scope: TorrentEngineServiceScope,
        controllerLease: TorrentEngineControllerLease
    ) async throws {
        guard try capabilityRegistry.capability(
            capabilityID: request.capabilityID,
            scope: scope
        ) != nil else {
            return
        }
        do {
            let desiredPins = try capabilityRegistry.pins(scope: scope).filter {
                $0.capabilityID != request.capabilityID
            }
            let desiredRoots = try Self.authorizedRoots(for: desiredPins)
            try await requireEngine().replaceAuthorizedSaveRoots(desiredRoots)
            try requireActiveController(controllerLease)
            _ = try capabilityRegistry.revoke(
                capabilityID: request.capabilityID,
                scope: scope
            )
        } catch {
            await restoreAuthorizedRootsOrTerminate(
                scope: scope,
                reason: "Torrent engine folder revocation rollback failed"
            )
            throw error
        }
    }

    private func handleReplaceFolders(
        _ request: TorrentEngineIPCReplaceFoldersRequest,
        scope: TorrentEngineServiceScope,
        operation: TorrentEngineIPCOperation,
        controllerLease: TorrentEngineControllerLease
    ) async throws -> Data {
        let replacement: TorrentFolderCapabilityReplacement
        do {
            replacement = try capabilityRegistry.prepareCommittedGrantReplacement(
                bookmarkData: request.folders.map(\.bookmark),
                scope: scope
            )
        } catch {
            throw TorrentEngineServiceRuntimeError.invalidFolderGrant
        }
        try requireActiveController(controllerLease)

        do {
            let roots = try Self.authorizedRoots(for: replacement.pins)
            try await requireEngine().replaceAuthorizedSaveRoots(roots)
            try requireActiveController(controllerLease)
        } catch let engineError as TorrentEngineError {
            if case .authorizedRootCapacityReached = engineError {
                throw TorrentEngineServiceRuntimeError.folderAuthorizationInUse
            }
            await terminateActiveControllerAfterSecurityBoundaryFailure(
                reason: "Torrent engine folder authorization replacement failed"
            )
            throw engineError
        } catch {
            await terminateActiveControllerAfterSecurityBoundaryFailure(
                reason: "Torrent engine folder authorization replacement failed"
            )
            throw error
        }

        let capabilities: [TorrentFolderCapability]
        do {
            capabilities = try capabilityRegistry.commit(replacement)
        } catch {
            await terminateActiveControllerAfterSecurityBoundaryFailure(
                reason: "Torrent engine folder authorization commit failed"
            )
            throw TorrentEngineServiceRuntimeError.invalidFolderGrant
        }

        return try encode(
            TorrentEngineIPCReplaceFoldersResponse(
                folders: capabilities.map {
                    TorrentEngineIPCGrantedFolder(
                        capabilityID: $0.id,
                        resolvedPath: $0.canonicalPath
                    )
                }
            ),
            for: operation
        )
    }

    private func handleAddMagnet(
        _ request: TorrentEngineIPCAddMagnetRequest,
        scope: TorrentEngineServiceScope,
        controllerLease: TorrentEngineControllerLease
    ) async throws -> String {
        guard !request.magnet.isEmpty,
              request.magnet.hasPrefix("magnet:?"),
              request.magnet.utf8.count <= TorrentInputLimits.maxMagnetURIBytes,
              !request.magnet.utf8.contains(0) else {
            throw TorrentEngineServiceRuntimeError.invalidMagnet
        }
        let pin = try authorizedPin(request.folderCapabilityID, scope: scope)
        let wasProvisional = try capabilityRegistry.capability(
            capabilityID: request.folderCapabilityID,
            scope: scope
        )?.state == .provisional
        var didInvokeNativeAdd = false
        do {
            let addingEngine = try requireEngine()
            didInvokeNativeAdd = true
            let identifier = try await addingEngine.addMagnet(
                request.magnet,
                savePath: pin.canonicalPath,
                startsPaused: request.startsPaused,
                queuePriority: request.queuePriority,
                enablePeerExchange: request.enablePeerExchange,
                allowNonHTTPSTrackers: request.allowNonHTTPSTrackers,
                allowNonHTTPSWebSeeds: request.allowNonHTTPSWebSeeds,
                allowPreMetadataDHT: request.allowPreMetadataDHT
            )
            try await validateAddedTorrentID(identifier)
            try requireActiveController(controllerLease)
            _ = try capabilityRegistry.commit(
                capabilityID: request.folderCapabilityID,
                scope: scope
            )
            return identifier
        } catch {
            if didInvokeNativeAdd {
                // The bridge can fail after libtorrent accepted the torrent
                // (for example, if a later policy rollback fails). Without a
                // typed rollback proof this outcome is commit-ambiguous: close
                // the controller and let disconnect cleanup revoke authority.
                await terminateActiveControllerAfterSecurityBoundaryFailure(
                    reason: "Torrent engine magnet add outcome is unknown"
                )
                throw error
            }
            if wasProvisional, !isShuttingDown {
                _ = try? capabilityRegistry.revoke(
                    capabilityID: request.folderCapabilityID,
                    scope: scope
                )
                await restoreAuthorizedRootsOrTerminate(
                    scope: scope,
                    reason: "Torrent engine magnet authorization rollback failed"
                )
            }
            throw error
        }
    }

    private func handleAddTorrentFile(
        _ request: TorrentEngineIPCAddTorrentFileRequest,
        scope: TorrentEngineServiceScope,
        controllerLease: TorrentEngineControllerLease
    ) async throws -> String {
        try Self.validateTorrentData(request.torrentData)
        let priorities = try Self.validatedFilePriorities(request.filePriorities)
        let pin = try authorizedPin(request.folderCapabilityID, scope: scope)
        let wasProvisional = try capabilityRegistry.capability(
            capabilityID: request.folderCapabilityID,
            scope: scope
        )?.state == .provisional
        var didInvokeNativeAdd = false
        do {
            let addingEngine = try requireEngine()
            didInvokeNativeAdd = true
            let identifier = try await addingEngine.addTorrentFile(
                data: request.torrentData,
                savePath: pin.canonicalPath,
                filePriorities: priorities,
                startsPaused: request.startsPaused,
                queuePriority: request.queuePriority,
                enablePeerExchange: request.enablePeerExchange,
                allowNonHTTPSTrackers: request.allowNonHTTPSTrackers,
                allowNonHTTPSWebSeeds: request.allowNonHTTPSWebSeeds
            )
            try await validateAddedTorrentID(identifier)
            try requireActiveController(controllerLease)
            _ = try capabilityRegistry.commit(
                capabilityID: request.folderCapabilityID,
                scope: scope
            )
            return identifier
        } catch {
            if didInvokeNativeAdd {
                // A thrown bridge error does not prove libtorrent rolled the
                // add back. Contain the potentially committed torrent instead
                // of returning a definite rejection or revoking its folder.
                await terminateActiveControllerAfterSecurityBoundaryFailure(
                    reason: "Torrent engine torrent-file add outcome is unknown"
                )
                throw error
            }
            if wasProvisional, !isShuttingDown {
                _ = try? capabilityRegistry.revoke(
                    capabilityID: request.folderCapabilityID,
                    scope: scope
                )
                await restoreAuthorizedRootsOrTerminate(
                    scope: scope,
                    reason: "Torrent engine torrent-file authorization rollback failed"
                )
            }
            throw error
        }
    }

    private func handlePoll(
        _ request: TorrentEngineIPCPollRequest,
        scope: TorrentEngineServiceScope,
        operation: TorrentEngineIPCOperation,
        controllerLease: TorrentEngineControllerLease
    ) async throws -> Data {
        let result = try await requireEngine().poll(
            since: request.snapshotRevision,
            sortedBy: request.sortOrder,
            direction: request.sortDirection,
            includeTrackerHosts: request.includeTrackerHosts
        )
        guard let networkInterfaceSnapshot = await networkAuthority?.interfaceSnapshot() else {
            throw TorrentEngineServiceRuntimeError.networkBindingRejected(.monitorNotReady)
        }
        try requireActiveController(controllerLease)

        cleanupExpiredDatasets()
        var candidates = [TorrentEngineServiceDataset]()
        if let batch = result.snapshotBatch {
            guard batch.torrents.count <= TorrentEngineLimits.maximumTorrentSnapshotCount else {
                throw TorrentEngineServiceRuntimeError.datasetStorageLimitExceeded
            }
            candidates.append(try makeDataset(
                kind: .torrentSnapshots,
                revision: batch.revision,
                items: batch.torrents,
                ownerControllerID: scope.controllerID
            ))
        }
        if let batch = result.trackerHostBatch {
            guard batch.hosts.count <= TorrentEngineLimits.maximumTrackerHostRowCount else {
                throw TorrentEngineServiceRuntimeError.datasetStorageLimitExceeded
            }
            candidates.append(try makeDataset(
                kind: .trackerHosts,
                revision: batch.revision,
                items: batch.hosts,
                ownerControllerID: scope.controllerID
            ))
        }
        let snapshot = candidates.first { $0.descriptor.kind == .torrentSnapshots }
        let trackerHosts = candidates.first { $0.descriptor.kind == .trackerHosts }
        let response = TorrentEngineIPCPollResponse(
            dirtyMask: result.dirtyMask,
            alertErrors: Array(result.alertErrors.prefix(TorrentEngineIPCLimits.maximumAlertErrorsPerPoll)),
            networkStatus: result.networkStatus,
            bridgeHealth: result.bridgeHealth,
            networkInterfaceSnapshot: networkInterfaceSnapshot,
            snapshotDataset: snapshot?.descriptor,
            trackerHostDataset: trackerHosts?.descriptor
        )
        let payload = try encode(response, for: operation)
        try registerDatasets(candidates)
        return payload
    }

    private func applySettings(
        _ request: TorrentEngineIPCApplySettingsRequest,
        controllerLease: TorrentEngineControllerLease
    ) async throws {
        let engine = try requireEngine()
        let authority = networkBindingAuthority()
        guard await authority.start() else {
            throw TorrentEngineServiceRuntimeError.networkBindingRejected(.monitorNotReady)
        }
        try requireActiveController(controllerLease)
        let decision = await authority.prepare(
            settings: request.settings,
            binding: request.networkBinding
        )
        try requireActiveController(controllerLease)

        do {
            switch decision {
            case .blocked(let reason):
                try await engine.applySettings(
                    request.settings,
                    networkBinding: .unbound(networkBlocked: true)
                )
                try requireActiveController(controllerLease)
                guard reason == .controllerRequested else {
                    throw TorrentEngineServiceRuntimeError.networkBindingRejected(reason)
                }
            case .unrestricted:
                try await engine.applySettings(
                    request.settings,
                    networkBinding: request.networkBinding
                )
                try requireActiveController(controllerLease)
            case .constrained(let lease):
                guard await authority.activate(lease) else {
                    throw TorrentEngineServiceRuntimeError.networkBindingRejected(.monitorChanged)
                }
                try requireActiveController(controllerLease)
                try await engine.applySettings(
                    request.settings,
                    networkBinding: request.networkBinding
                )
                try requireActiveController(controllerLease)
                guard await authority.confirm(lease) else {
                    throw TorrentEngineServiceRuntimeError.networkBindingRejected(.monitorChanged)
                }
                try requireActiveController(controllerLease)
            }
        } catch {
            await authority.forceBlock(reason: .authorizationReplaced)
            throw error
        }
    }

    private func networkBindingAuthority() -> TorrentNetworkBindingAuthority {
        if let networkAuthority {
            return networkAuthority
        }
        let authorityID = UUID()
        let containmentWatchdog = containmentWatchdog
        let authority = TorrentNetworkBindingAuthority(
            invalidationHandler: { [weak self] reason in
                let watchdogToken = containmentWatchdog.arm()
                defer {
                    containmentWatchdog.disarm(watchdogToken)
                }
                await self?.networkBindingWasInvalidated(
                    reason: reason,
                    authorityID: authorityID
                )
            },
            observationHandler: { [weak self] in
                await self?.networkInterfaceSnapshotDidChange(authorityID: authorityID)
            }
        )
        networkAuthority = authority
        networkAuthorityID = authorityID
        return authority
    }

    private func networkBindingWasInvalidated(
        reason: TorrentNetworkBindingBlockReason,
        authorityID: UUID
    ) async {
        guard networkAuthorityID == authorityID,
              let controllerGeneration = activeControllerGeneration,
              let engine else {
            return
        }
        let result = await processNetworkBindingInvalidation(
            reason: reason,
            controllerReplacementIsAllowed: !networkAuthorityStartIsPending,
            expectedControllerGeneration: controllerGeneration,
            expectedAuthorityID: authorityID
        ) {
            do {
                _ = try await engine.blockNetworkNow()
                return .blocked
            } catch {
                // A failed fail-closed operation makes the native engine unusable;
                // blocking destroy is the final containment boundary.
                await engine.forceContainmentAfterNetworkBlockFailure(
                    detail: error.localizedDescription
                )
                return .engineUnavailable
            }
        }
        if result == .engineUnavailable,
           self.engine === engine {
            self.engine = nil
        }
    }

    @discardableResult
    func processNetworkBindingInvalidation(
        reason: TorrentNetworkBindingBlockReason,
        controllerReplacementIsAllowed: Bool = true,
        expectedControllerGeneration: UUID? = nil,
        expectedAuthorityID: UUID? = nil,
        containment: @Sendable () async -> TorrentEngineServiceNetworkContainmentResult
    ) async -> TorrentEngineServiceNetworkContainmentResult {
        let result = await containment()
        if let expectedControllerGeneration,
           activeControllerGeneration != expectedControllerGeneration {
            return result
        }
        if let expectedAuthorityID,
           networkAuthorityID != expectedAuthorityID {
            return result
        }
        let monitorCannotRecover = switch reason {
        case .monitorNotReady, .monitorStopped:
            true
        default:
            false
        }
        guard result == .engineUnavailable
                || (monitorCannotRecover && controllerReplacementIsAllowed) else {
            return result
        }
        guard !isShuttingDown else {
            return result
        }

        // This callback is invoked by the authority actor. Calling
        // beginDisconnect here would await that same authority and deadlock.
        // Native containment has already completed, so invalidate the lease
        // and cancel the session directly; listener cleanup finishes teardown.
        isShuttingDown = true
        activeControllerGeneration = nil
        hintTask?.cancel()
        hintTask = nil
        activeSession?.cancel(
            reason: result == .engineUnavailable
                ? "Torrent engine network containment failed"
                : "Torrent engine network interface monitor became unavailable"
        )
        return result
    }

    private func networkInterfaceSnapshotDidChange(authorityID: UUID) {
        guard networkAuthorityID == authorityID,
              let activeControllerID else {
            return
        }
        sendChangeHint(controllerID: activeControllerID)
    }

    private func terminateActiveControllerAfterSecurityBoundaryFailure(
        reason: String
    ) async {
        guard let peerToken = activePeerToken else {
            return
        }
        let session = activeSession
        let containmentToken = containmentWatchdog.arm()
        await beginDisconnect(peerToken: peerToken)
        containmentWatchdog.disarm(containmentToken)
        session?.cancel(reason: reason)
    }

    private func makeDataset<Value: Encodable & Sendable>(
        kind: TorrentEngineIPCDatasetKind,
        revision: UInt64,
        items: [Value],
        ownerControllerID: UUID
    ) throws -> TorrentEngineServiceDataset {
        var pages = [Data]()
        pages.reserveCapacity(
            max(
                1,
                items.count / TorrentEngineIPCLimits.maximumDatasetPageItemCount
            )
        )
        var byteCount = 0
        var index = 0
        while index < items.count {
            var pageEnd = min(
                index + TorrentEngineIPCLimits.maximumDatasetPageItemCount,
                items.count
            )
            var encodedPage: Data?
            while pageEnd > index {
                do {
                    encodedPage = try TorrentEngineIPCPropertyListCodec.encode(
                        Array(items[index..<pageEnd]),
                        maximumBytes: TorrentEngineIPCLimits.maximumDatasetPageBytes
                    )
                    break
                } catch TorrentEngineIPCError.payloadTooLarge {
                    let count = pageEnd - index
                    guard count > 1 else {
                        throw TorrentEngineServiceRuntimeError.datasetStorageLimitExceeded
                    }
                    pageEnd = index + max(1, count / 2)
                }
            }
            guard let encodedPage,
                  encodedPage.count <= TorrentEngineIPCLimits.maximumDatasetAggregateBytes - byteCount else {
                throw TorrentEngineServiceRuntimeError.datasetStorageLimitExceeded
            }
            pages.append(encodedPage)
            byteCount += encodedPage.count
            index = pageEnd
        }

        let descriptor = TorrentEngineIPCDatasetDescriptor(
            id: UUID(),
            kind: kind,
            revision: revision,
            itemCount: items.count,
            pageCount: pages.count
        )
        return TorrentEngineServiceDataset(
            descriptor: descriptor,
            ownerControllerID: ownerControllerID,
            pages: pages,
            byteCount: byteCount,
            expiresAt: clock.now.advanced(by: Self.datasetLifetime)
        )
    }

    private func registerDatasets(_ datasets: [TorrentEngineServiceDataset]) throws {
        guard datasetsByID.count <= TorrentEngineIPCLimits.maximumOpenDatasets - datasets.count else {
            throw TorrentEngineServiceRuntimeError.tooManyOpenDatasets
        }
        let currentBytes = datasetsByID.values.reduce(into: 0) { $0 += $1.byteCount }
        guard Set(datasets.map(\.descriptor.id)).count == datasets.count else {
            throw TorrentEngineServiceRuntimeError.datasetStorageLimitExceeded
        }
        var projectedBytes = currentBytes
        for dataset in datasets {
            guard dataset.byteCount <= TorrentEngineIPCLimits.maximumDatasetAggregateBytes - projectedBytes else {
                throw TorrentEngineServiceRuntimeError.datasetStorageLimitExceeded
            }
            guard datasetsByID[dataset.descriptor.id] == nil else {
                throw TorrentEngineServiceRuntimeError.datasetStorageLimitExceeded
            }
            projectedBytes += dataset.byteCount
        }
        for dataset in datasets {
            datasetsByID[dataset.descriptor.id] = dataset
        }
    }

    private func readDataset(
        _ request: TorrentEngineIPCReadDatasetRequest,
        controllerID: UUID
    ) throws -> TorrentEngineIPCDatasetPage {
        cleanupExpiredDatasets()
        guard let dataset = datasetsByID[request.id],
              dataset.ownerControllerID == controllerID else {
            throw TorrentEngineServiceRuntimeError.unknownDataset
        }
        guard dataset.pages.indices.contains(request.page) else {
            throw TorrentEngineServiceRuntimeError.invalidDatasetPage
        }
        return TorrentEngineIPCDatasetPage(
            id: dataset.descriptor.id,
            kind: dataset.descriptor.kind,
            page: request.page,
            encodedItems: dataset.pages[request.page]
        )
    }

    private func closeDataset(_ id: UUID, controllerID: UUID) throws {
        cleanupExpiredDatasets()
        guard let dataset = datasetsByID[id],
              dataset.ownerControllerID == controllerID else {
            throw TorrentEngineServiceRuntimeError.unknownDataset
        }
        datasetsByID.removeValue(forKey: id)
    }

    private func cleanupExpiredDatasets() {
        let now = clock.now
        datasetsByID = datasetsByID.filter { now < $0.value.expiresAt }
    }

    private func beginMigration(
        scope: TorrentEngineServiceScope,
        operation: TorrentEngineIPCOperation
    ) throws -> Data {
        guard activeMigrationID == nil else {
            throw TorrentEngineServiceRuntimeError.stateMigrationAlreadyActive
        }
        if try migrationCoordinator.hasCompletedMigration() {
            return try encode(
                TorrentEngineIPCStateMigrationBeginResponse(alreadyComplete: true),
                for: operation
            )
        }
        let migration = try migrationCoordinator.begin(scope: scope)
        activeMigrationID = migration.id
        return try encode(
            TorrentEngineIPCStateMigrationBeginResponse(alreadyComplete: false),
            for: operation
        )
    }

    private func importMigrationFile(
        _ request: TorrentEngineIPCRequest,
        fileDescriptor: Int32,
        scope: TorrentEngineServiceScope,
        operation: TorrentEngineIPCOperation
    ) throws -> Data {
        var descriptorIsOwned = true
        defer {
            if descriptorIsOwned {
                Darwin.close(fileDescriptor)
            }
        }
        guard let activeMigrationID else {
            throw TorrentEngineServiceRuntimeError.stateMigrationUnavailable
        }
        let value = try decode(TorrentEngineIPCStateMigrationFileRequest.self, from: request)
        descriptorIsOwned = false
        try migrationCoordinator.importFile(
            migrationID: activeMigrationID,
            scope: scope,
            filename: value.name,
            fileDescriptor: fileDescriptor
        )
        return try encode(TorrentEngineIPCEmpty(), for: operation)
    }

    private func commitMigration(
        scope: TorrentEngineServiceScope,
        operation: TorrentEngineIPCOperation
    ) throws -> Data {
        guard let activeMigrationID else {
            throw TorrentEngineServiceRuntimeError.stateMigrationUnavailable
        }
        _ = try migrationCoordinator.commit(
            migrationID: activeMigrationID,
            scope: scope
        )
        self.activeMigrationID = nil
        return try encode(TorrentEngineIPCEmpty(), for: operation)
    }

    private func abortMigration(
        scope: TorrentEngineServiceScope,
        operation: TorrentEngineIPCOperation
    ) throws -> Data {
        guard let activeMigrationID else {
            throw TorrentEngineServiceRuntimeError.stateMigrationUnavailable
        }
        try migrationCoordinator.abort(migrationID: activeMigrationID, scope: scope)
        self.activeMigrationID = nil
        return try encode(TorrentEngineIPCEmpty(), for: operation)
    }

    private func authorizedPin(
        _ capabilityID: UUID,
        scope: TorrentEngineServiceScope
    ) throws -> TorrentFolderCapabilityPin {
        do {
            let pin = try capabilityRegistry.pin(capabilityID: capabilityID, scope: scope)
            try Self.validate(pin: pin)
            return pin
        } catch {
            throw TorrentEngineServiceRuntimeError.invalidFolderCapability
        }
    }

    private func authorizedRoots(
        scope: TorrentEngineServiceScope
    ) throws -> [TorrentAuthorizedSaveRoot] {
        do {
            return try Self.authorizedRoots(for: capabilityRegistry.pins(scope: scope))
        } catch {
            throw TorrentEngineServiceRuntimeError.invalidFolderCapability
        }
    }

    private static func authorizedRoots(
        for pins: [TorrentFolderCapabilityPin]
    ) throws -> [TorrentAuthorizedSaveRoot] {
        // This synchronous conversion duplicates every borrowed registry
        // descriptor before the resulting values cross into the engine actor.
        try pins.map { pin in
            try validate(pin: pin)
            return try TorrentAuthorizedSaveRoot(
                canonicalPath: pin.canonicalPath,
                borrowingDirectoryDescriptor: pin.directoryFileDescriptor(),
                device: pin.identity.device,
                inode: pin.identity.inode,
                retaining: pin.accessLifetimeAnchor
            )
        }
    }

    private func restoreAuthorizedRootsOrTerminate(
        scope: TorrentEngineServiceScope,
        reason: String
    ) async {
        guard let engine else {
            await terminateActiveControllerAfterSecurityBoundaryFailure(reason: reason)
            return
        }
        do {
            let roots = try authorizedRoots(scope: scope)
            try await engine.replaceAuthorizedSaveRoots(roots)
        } catch {
            await terminateActiveControllerAfterSecurityBoundaryFailure(reason: reason)
        }
    }

    private static func validate(pin: TorrentFolderCapabilityPin) throws {
        guard pin.isValid else {
            throw TorrentEngineServiceRuntimeError.invalidFolderCapability
        }
        let descriptor = try pin.directoryFileDescriptor()
        var descriptorMetadata = stat()
        var pathMetadata = stat()
        let descriptorStatus = unsafe Darwin.fstat(descriptor, &descriptorMetadata)
        let pathStatus = unsafe pin.canonicalPath.withCString {
            unsafe Darwin.lstat($0, &pathMetadata)
        }
        guard descriptorStatus == 0,
              pathStatus == 0,
              (descriptorMetadata.st_mode & S_IFMT) == S_IFDIR,
              (pathMetadata.st_mode & S_IFMT) == S_IFDIR,
              descriptorMetadata.st_dev == pathMetadata.st_dev,
              descriptorMetadata.st_ino == pathMetadata.st_ino,
              pin.identity.device == UInt64(truncatingIfNeeded: descriptorMetadata.st_dev),
              pin.identity.inode == UInt64(truncatingIfNeeded: descriptorMetadata.st_ino) else {
            throw TorrentEngineServiceRuntimeError.invalidFolderCapability
        }
    }

    private func requireEngine() throws -> TorrentEngine {
        guard let engine else {
            throw TorrentEngineServiceRuntimeError.handshakeRequired
        }
        return engine
    }

    private func blockNetworkWithinContainmentDeadline(
        _ engine: TorrentEngine
    ) async throws {
        let containmentToken = containmentWatchdog.arm()
        defer {
            containmentWatchdog.disarm(containmentToken)
        }
        _ = try await engine.blockNetworkNow()
    }

    private func requireActiveController(
        _ lease: TorrentEngineControllerLease
    ) throws {
        guard !isShuttingDown,
              activePeerToken == lease.peerToken,
              activeControllerID == lease.controllerID,
              activeControllerGeneration == lease.generation else {
            throw TorrentEngineServiceRuntimeError.serviceShuttingDown
        }
    }

    private func decode<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from request: TorrentEngineIPCRequest
    ) throws -> Value {
        guard let payload = request.payload else {
            throw TorrentEngineServiceRuntimeError.invalidPayload
        }
        do {
            return try TorrentEngineIPCPropertyListCodec.decode(
                type,
                from: payload,
                maximumBytes: request.header.operation.maximumRequestPayloadBytes,
                decodingLimits: request.header.operation.propertyListDecodingLimits
            )
        } catch {
            throw TorrentEngineServiceRuntimeError.invalidPayload
        }
    }

    private func encode<Value: Encodable & Sendable>(
        _ value: Value,
        for operation: TorrentEngineIPCOperation
    ) throws -> Data {
        try TorrentEngineIPCPropertyListCodec.encode(
            value,
            maximumBytes: operation.maximumReplyPayloadBytes
        )
    }

    private func encodeOptional<Value: Codable & Sendable>(
        _ value: Value?,
        for operation: TorrentEngineIPCOperation
    ) throws -> Data {
        try encode(TorrentEngineIPCOptionalValue(value), for: operation)
    }

    private func decodeTorrentIDRequest(
        _ request: TorrentEngineIPCRequest
    ) throws -> TorrentEngineIPCTorrentIDRequest {
        let value = try decode(TorrentEngineIPCTorrentIDRequest.self, from: request)
        try Self.validateTorrentID(value.id)
        return value
    }

    private func decodeTorrentRevisionRequest(
        _ request: TorrentEngineIPCRequest
    ) throws -> TorrentEngineIPCTorrentRevisionRequest {
        let value = try decode(TorrentEngineIPCTorrentRevisionRequest.self, from: request)
        try Self.validateTorrentID(value.id)
        return value
    }

    private static func validateTorrentID(_ id: String) throws {
        let bytes = Array(id.utf8)
        guard bytes.count == 34,
              bytes[0] == 0x74,
              bytes[1] == 0x3A,
              bytes.dropFirst(2).allSatisfy({
                  ($0 >= 0x30 && $0 <= 0x39)
                      || ($0 >= 0x61 && $0 <= 0x66)
              }) else {
            throw TorrentEngineServiceRuntimeError.invalidTorrentIdentifier
        }
    }

    private func validateAddedTorrentID(_ id: String) async throws {
        do {
            try Self.validateTorrentID(id)
        } catch {
            await terminateActiveControllerAfterSecurityBoundaryFailure(
                reason: "Torrent engine returned an invalid torrent identifier"
            )
            throw TorrentEngineServiceRuntimeError.invalidTorrentIdentifier
        }
    }

    private static func validateTorrentData(_ data: Data) throws {
        guard !data.isEmpty,
              data.count <= TorrentInputLimits.maxTorrentFileBytes else {
            throw TorrentEngineServiceRuntimeError.invalidTorrentFile
        }
    }

    private static func validatedFilePriorities(
        _ entries: [TorrentEngineIPCFilePriorityEntry]?
    ) throws -> [Int32: TorrentFilePriority]? {
        guard let entries else {
            return nil
        }
        guard entries.count <= TorrentEngineLimits.maximumFileCount else {
            throw TorrentEngineServiceRuntimeError.invalidFilePriorities
        }
        var priorities = [Int32: TorrentFilePriority](minimumCapacity: entries.count)
        for entry in entries {
            guard (0..<TorrentEngineLimits.maximumFileCount).contains(Int(entry.index)),
                  priorities.updateValue(entry.priority, forKey: entry.index) == nil else {
                throw TorrentEngineServiceRuntimeError.invalidFilePriorities
            }
        }
        return priorities
    }

    private func sendReply(
        for header: TorrentEngineIPCHeader,
        status: TorrentEngineIPCReplyStatus,
        payload: Data?,
        failureCode: TorrentEngineIPCFailureCode? = nil,
        errorMessage: String?,
        pendingReply: TorrentEnginePendingReply
    ) throws {
        let reply = TorrentEngineIPCReply(
            header: header,
            engineEpoch: engineEpoch,
            status: status,
            failureCode: failureCode,
            errorMessage: errorMessage,
            payload: payload
        )
        let dictionary = try TorrentEngineIPCEnvelopeCodec.encode(
            reply,
            maximumPayloadBytes: header.operation.maximumReplyPayloadBytes
        )
        pendingReply.send(dictionary, status: status)
    }

    private static func failureMessage(for error: any Error) -> String {
        let source: String
        if let localizedError = error as? any LocalizedError,
           let description = localizedError.errorDescription {
            source = description
        } else {
            source = error.localizedDescription
        }
        var message = source.replacingOccurrences(of: "\0", with: "")
        if message.isEmpty {
            message = "The isolated torrent engine rejected the operation."
        }
        if message.count > TorrentEngineIPCLimits.maximumErrorBytes {
            message = String(message.prefix(TorrentEngineIPCLimits.maximumErrorBytes))
        }
        while message.utf8.count > TorrentEngineIPCLimits.maximumErrorBytes {
            message.removeLast()
        }
        return message
    }

    static func inFlightFailureCode(
        activePeerToken: UUID?,
        incomingPeerToken: UUID,
        isShuttingDown: Bool
    ) -> TorrentEngineIPCFailureCode {
        if isShuttingDown {
            return .serviceShuttingDown
        }
        if let activePeerToken, activePeerToken != incomingPeerToken {
            return .controllerBusy
        }
        return .operationRejected
    }

    static func isTransientAdmissionFailure(
        _ failureCode: TorrentEngineIPCFailureCode
    ) -> Bool {
        switch failureCode {
        case .controllerBusy, .serviceShuttingDown:
            true
        case .operationRejected:
            false
        }
    }

    private static func failureCode(
        for error: any Error
    ) -> TorrentEngineIPCFailureCode {
        guard let runtimeError = error as? TorrentEngineServiceRuntimeError else {
            return .operationRejected
        }
        switch runtimeError {
        case .controllerBusy:
            return .controllerBusy
        case .serviceShuttingDown:
            return .serviceShuttingDown
        default:
            return .operationRejected
        }
    }

    private func startChangeHints(
        for engine: TorrentEngine,
        controllerID: UUID
    ) {
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            let events = await engine.wakeEvents()
            for await _ in events {
                guard !Task.isCancelled else {
                    return
                }
                await self?.sendChangeHint(controllerID: controllerID)
                do {
                    try await Task.sleep(for: Self.changeHintMinimumInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func sendChangeHint(controllerID: UUID) {
        guard !isShuttingDown,
              activeControllerID == controllerID,
              let session = activeSession,
              hintSequence != UInt64.max else {
            return
        }
        let header = TorrentEngineIPCHeader(
            requestID: UUID(),
            controllerID: controllerID,
            sequence: hintSequence,
            operation: .changeHint,
            operationID: UUID(),
            expectedEpoch: engineEpoch
        )
        hintSequence += 1
        guard let message = try? TorrentEngineIPCEnvelopeCodec.encode(
            TorrentEngineIPCRequest(header: header),
            maximumPayloadBytes: TorrentEngineIPCOperation.changeHint.maximumRequestPayloadBytes
        ) else {
            return
        }
        try? session.send(message: message)
    }

    private func releaseFailedInitialController(
        peerToken: UUID,
        endsTransaction: Bool
    ) async -> Bool {
        guard activePeerToken == peerToken,
              engine == nil else {
            return false
        }
        await shutDownActiveController(endsTransaction: endsTransaction)
        return true
    }

    private func shutDownActiveController(endsTransaction: Bool = true) async {
        guard let peerToken = activePeerToken else {
            return
        }
        let containmentToken = containmentWatchdog.arm()
        await beginDisconnect(peerToken: peerToken)
        containmentWatchdog.disarm(containmentToken)
        await finishDisconnect(
            peerToken: peerToken,
            endsTransaction: endsTransaction
        )
    }

    private func finishShutDownActiveController(
        controllerID: UUID,
        endsTransaction: Bool
    ) async {
        if let networkAuthority {
            await networkAuthority.stop()
        }
        networkAuthority = nil
        networkAuthorityID = nil
        networkAuthorityStartIsPending = false
        if let engine {
            _ = try? await engine.blockNetworkNow()
            try? await engine.shutdownSafely()
        }
        self.engine = nil
        datasetsByID.removeAll()
        activeMigrationID = nil
        migrationCoordinator.disconnect(controllerID: controllerID)
        capabilityRegistry.disconnect(controllerID: controllerID)

        activePeerToken = nil
        activeControllerID = nil
        activeControllerGeneration = nil
        activeSession = nil
        lastSequence = 0
        recentOperationIDs.removeAll(keepingCapacity: true)
        recentOperationIDSet.removeAll(keepingCapacity: true)
        recentRequestIDs.removeAll(keepingCapacity: true)
        recentRequestIDSet.removeAll(keepingCapacity: true)
        hintSequence = 1
        isShuttingDown = false
        if endsTransaction {
            endTransactionIfNeeded()
        }
    }

    private func beginTransactionIfNeeded() {
        guard !transactionIsActive else {
            return
        }
        transactionBegin()
        transactionIsActive = true
    }

    private func endTransactionIfNeeded() {
        guard transactionIsActive else {
            return
        }
        transactionIsActive = false
        transactionEnd()
    }
}
