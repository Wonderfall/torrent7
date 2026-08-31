import Darwin
import Foundation
import Synchronization
import TorrentEngineClient
import TorrentEngineIPC
import TorrentEngineModel
import TorrentStorageAuthority
import XPC

package enum TorrentStorageBrokerRegistryError: LocalizedError, Equatable, Sendable {
    case invalidClaim
    case claimUnavailable
    case generationMismatch
    case claimInactive
    case fileUnavailable
    case accessDenied
    case filesystemObjectChanged
    case deadlineExceeded

    package var errorDescription: String? {
        switch self {
        case .invalidClaim:
            "The storage claim is invalid."
        case .claimUnavailable:
            "The storage claim is unavailable."
        case .generationMismatch:
            "The storage claim generation changed."
        case .claimInactive:
            "The storage claim is not active."
        case .fileUnavailable:
            "The requested payload file is unavailable."
        case .accessDenied:
            "The requested payload access is not permitted."
        case .filesystemObjectChanged:
            "The payload filesystem object changed."
        case .deadlineExceeded:
            "The storage broker request deadline expired."
        }
    }
}

@safe package final class TorrentStorageBrokerRegistry: Sendable {
    private struct State: Sendable {
        var registrations = [UUID: Registration]()
    }

    private struct Registration: Sendable {
        var claim: TorrentStorageClaim
        let parent: TorrentStorageParentAuthority
    }

    private struct ResolvedFile: Sendable {
        let claimID: UUID
        let claimGeneration: UInt64
        let parent: TorrentStorageParentAuthority
        let logicalFile: TorrentLogicalFile
        let relativePathComponents: [String]?
        let expectedIdentity: TorrentFilesystemIdentity?
        let ownership: TorrentStorageOwnership
    }

    private let state = Mutex(State())

    package init() {}

    package func install(
        claim: TorrentStorageClaim,
        parent: TorrentStorageParentAuthority
    ) throws {
        try Self.validate(claim)
        try parent.validate()
        guard claim.manifest.parentID == parent.id else {
            throw TorrentStorageBrokerRegistryError.invalidClaim
        }
        try state.withLock { state in
            if let existing = state.registrations[claim.manifest.claimID] {
                guard existing.claim == claim else {
                    throw TorrentStorageBrokerRegistryError.invalidClaim
                }
                return
            }
            state.registrations[claim.manifest.claimID] = Registration(
                claim: claim,
                parent: parent
            )
        }
    }

    package func replace(claim: TorrentStorageClaim) throws {
        try Self.validate(claim)
        try state.withLock { state in
            guard var registration = state.registrations[
                claim.manifest.claimID
            ], registration.claim.manifest == claim.manifest else {
                throw TorrentStorageBrokerRegistryError.claimUnavailable
            }
            registration.claim = claim
            state.registrations[claim.manifest.claimID] = registration
        }
    }

    package func removeClaim(claimID: UUID, generation: UInt64) throws {
        try state.withLock { state in
            guard let registration = state.registrations[claimID] else {
                return
            }
            let claim = registration.claim
            guard claim.manifest.generation == generation else {
                throw TorrentStorageBrokerRegistryError.generationMismatch
            }
            state.registrations.removeValue(forKey: claimID)
        }
    }

    package func installedClaimIDs() -> Set<UUID> {
        state.withLock { Set($0.registrations.keys) }
    }

    package func locationsByTorrentID() -> [String: TorrentStorageLocation] {
        state.withLock { state in
            var locations = [String: TorrentStorageLocation]()
            var ambiguousIDs = Set<String>()
            locations.reserveCapacity(state.registrations.count)
            for registration in state.registrations.values {
                let claim = registration.claim
                guard claim.lease.state == .activating
                        || claim.lease.state == .active
                        || claim.lease.state == .activationUnknown,
                      let location = TorrentStorageLocation(
                          claim: claim,
                          parent: registration.parent
                      ),
                      !ambiguousIDs.contains(location.torrentID) else {
                    continue
                }
                if locations.updateValue(
                    location,
                    forKey: location.torrentID
                ) != nil {
                    locations.removeValue(forKey: location.torrentID)
                    ambiguousIDs.insert(location.torrentID)
                }
            }
            return locations
        }
    }

    package func openPayload(
        claimID: UUID,
        generation: UInt64,
        fileIndex: Int32,
        access: TorrentStorageBrokerAccess
    ) throws -> (descriptor: Int32, metadata: TorrentStorageBrokerFileMetadata) {
        let resolved = try resolvedFile(
            claimID: claimID,
            generation: generation,
            fileIndex: fileIndex,
            requiresActiveClaim: true,
            requiresAvailableFile: true
        )
        guard !resolved.logicalFile.isPadding,
              resolved.relativePathComponents != nil,
              resolved.expectedIdentity != nil else {
            throw TorrentStorageBrokerRegistryError.fileUnavailable
        }

        let descriptor = try Self.open(
            resolved,
            access: access
        )
        do {
            let metadata = try Self.validatePayloadDescriptor(
                descriptor,
                resolved: resolved,
                access: access
            )
            return (descriptor, metadata)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    package func statBatch(
        claimID: UUID,
        generation: UInt64,
        fileIndices: [Int32],
        deadlineUptimeNanoseconds: UInt64? = nil
    ) throws -> [TorrentStorageBrokerFileMetadata] {
        guard !fileIndices.isEmpty,
              fileIndices.count <= TorrentStorageBrokerProtocol.maximumStatBatchCount else {
            throw TorrentStorageBrokerRegistryError.invalidClaim
        }
        return try fileIndices.map { fileIndex in
            try Self.checkDeadline(deadlineUptimeNanoseconds)
            let resolved = try resolvedFile(
                claimID: claimID,
                generation: generation,
                fileIndex: fileIndex,
                requiresActiveClaim: true,
                requiresAvailableFile: false
            )
            if resolved.logicalFile.isPadding {
                return TorrentStorageBrokerFileMetadata(
                    fileIndex: fileIndex,
                    size: resolved.logicalFile.expectedSize,
                    device: 0,
                    inode: 0,
                    linkCount: 0,
                    mode: UInt32(S_IFREG | 0o400)
                )
            }
            let descriptor = try Self.open(resolved, access: .readOnly)
            defer { _ = Darwin.close(descriptor) }
            let metadata = try Self.validatePayloadDescriptor(
                descriptor,
                resolved: resolved,
                access: .readOnly
            )
            try Self.checkDeadline(deadlineUptimeNanoseconds)
            return metadata
        }
    }

    private func resolvedFile(
        claimID: UUID,
        generation: UInt64,
        fileIndex: Int32,
        requiresActiveClaim: Bool,
        requiresAvailableFile: Bool
    ) throws -> ResolvedFile {
        try state.withLock { state in
            guard let registration = state.registrations[claimID] else {
                throw TorrentStorageBrokerRegistryError.claimUnavailable
            }
            let claim = registration.claim
            guard claim.manifest.generation == generation else {
                throw TorrentStorageBrokerRegistryError.generationMismatch
            }
            if requiresActiveClaim {
                guard claim.lease.state == .activating
                        || claim.lease.state == .active
                        || claim.lease.state == .activationUnknown else {
                    throw TorrentStorageBrokerRegistryError.claimInactive
                }
            }
            guard fileIndex >= 0 else {
                throw TorrentStorageBrokerRegistryError.fileUnavailable
            }
            let index = Int(fileIndex)
            guard index < claim.manifest.physicalFileIdentities.count,
                  index < claim.manifest.logicalFiles.count,
                  index < claim.lease.fileAvailability.count else {
                throw TorrentStorageBrokerRegistryError.fileUnavailable
            }
            let logicalFile = claim.manifest.logicalFiles[index]
            guard logicalFile.index == fileIndex else {
                throw TorrentStorageBrokerRegistryError.invalidClaim
            }
            guard !requiresAvailableFile
                    || logicalFile.isPadding
                    || claim.lease.fileAvailability[index] else {
                throw TorrentStorageBrokerRegistryError.accessDenied
            }
            return ResolvedFile(
                claimID: claim.manifest.claimID,
                claimGeneration: claim.manifest.generation,
                parent: registration.parent,
                logicalFile: logicalFile,
                relativePathComponents: claim.manifest
                    .relativePathComponents(forFileAt: index),
                expectedIdentity: claim.manifest.physicalFileIdentities[index],
                ownership: claim.manifest.ownership
            )
        }
    }

    private static func validate(_ claim: TorrentStorageClaim) throws {
        guard TorrentStorageClaimValidation.isValid(claim) else {
            throw TorrentStorageBrokerRegistryError.invalidClaim
        }
    }

    private static func open(
        _ resolved: ResolvedFile,
        access: TorrentStorageBrokerAccess
    ) throws -> Int32 {
        try resolved.parent.validate()
        guard let components = resolved.relativePathComponents,
              !components.isEmpty,
              components.allSatisfy(TorrentPathComponentValidation.isSafe) else {
            throw TorrentStorageBrokerRegistryError.fileUnavailable
        }

        var current = Darwin.dup(resolved.parent.descriptor)
        guard current >= 0 else {
            throw TorrentStorageBrokerRegistryError.filesystemObjectChanged
        }
        do {
            for component in components.dropLast() {
                let next = unsafe component.withCString { pointer in
                    unsafe Darwin.openat(
                        current,
                        pointer,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                    )
                }
                guard next >= 0 else {
                    throw TorrentStorageBrokerRegistryError.filesystemObjectChanged
                }
                _ = Darwin.close(current)
                current = next
            }
            guard let leaf = components.last else {
                throw TorrentStorageBrokerRegistryError.fileUnavailable
            }
            let flags = (access == .readWrite ? O_RDWR : O_RDONLY)
                | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            let result = unsafe leaf.withCString { pointer in
                unsafe Darwin.openat(current, pointer, flags)
            }
            guard result >= 0 else {
                throw TorrentStorageBrokerRegistryError.filesystemObjectChanged
            }
            _ = Darwin.close(current)
            return result
        } catch {
            _ = Darwin.close(current)
            throw error
        }
    }

    private static func validatePayloadDescriptor(
        _ descriptor: Int32,
        resolved: ResolvedFile,
        access: TorrentStorageBrokerAccess
    ) throws -> TorrentStorageBrokerFileMetadata {
        guard let expectedIdentity = resolved.expectedIdentity else {
            throw TorrentStorageBrokerRegistryError.fileUnavailable
        }
        var metadata = stat()
        guard unsafe Darwin.fstat(descriptor, &metadata) == 0 else {
            throw TorrentStorageBrokerRegistryError.filesystemObjectChanged
        }
        let actualIdentity = TorrentFilesystemIdentity(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino),
            linkCount: UInt64(truncatingIfNeeded: metadata.st_nlink),
            ownerUserID: metadata.st_uid,
            fileGeneration: metadata.st_gen
        )
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= resolved.logicalFile.expectedSize,
              actualIdentity == expectedIdentity else {
            throw TorrentStorageBrokerRegistryError.filesystemObjectChanged
        }

        switch resolved.ownership {
        case .appCreated(let key):
            guard metadata.st_uid == geteuid(), metadata.st_nlink == 1,
                  let components = resolved.relativePathComponents,
                  let tag = ownershipTag(on: descriptor),
                  TorrentStorageOwnershipTag.isValid(
                      tag,
                      key: key,
                      claimID: resolved.claimID,
                      claimGeneration: resolved.claimGeneration,
                      relativePathComponents: components,
                      identity: actualIdentity,
                      isDirectory: false
                  ) else {
                throw TorrentStorageBrokerRegistryError.filesystemObjectChanged
            }
        case .imported:
            if access == .readWrite {
                guard metadata.st_uid == geteuid(),
                      metadata.st_nlink == 1 else {
                    throw TorrentStorageBrokerRegistryError.accessDenied
                }
            }
        }

        return TorrentStorageBrokerFileMetadata(
            fileIndex: resolved.logicalFile.index,
            size: metadata.st_size,
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino),
            linkCount: UInt64(truncatingIfNeeded: metadata.st_nlink),
            mode: UInt32(metadata.st_mode)
        )
    }

    private static func ownershipTag(on descriptor: Int32) -> Data? {
        var tag = [UInt8](
            repeating: 0,
            count: TorrentStorageOwnershipTag.tagByteCount
        )
        let count = unsafe tag.withUnsafeMutableBytes { bytes in
            unsafe TorrentStorageDestinationPlanner.ownershipAttribute.withCString { name in
                unsafe Darwin.fgetxattr(
                    descriptor,
                    name,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
        }
        guard count == tag.count else {
            return nil
        }
        return Data(tag)
    }

    private static func checkDeadline(_ deadline: UInt64?) throws {
        guard let deadline else {
            return
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw TorrentStorageBrokerRegistryError.deadlineExceeded
        }
    }

}

@safe package final class TorrentStorageBrokerSessionGate: Sendable {
    package struct Limits: Sendable {
        package static let production = Limits(
            maximumInFlightRequests: 64,
            maximumRequestsPerInterval: 2_048,
            rateIntervalNanoseconds: 1_000_000_000,
            maximumFutureDeadlineNanoseconds: 6_000_000_000
        )

        package let maximumInFlightRequests: Int
        package let maximumRequestsPerInterval: Int
        package let rateIntervalNanoseconds: UInt64
        package let maximumFutureDeadlineNanoseconds: UInt64

        package init(
            maximumInFlightRequests: Int,
            maximumRequestsPerInterval: Int,
            rateIntervalNanoseconds: UInt64,
            maximumFutureDeadlineNanoseconds: UInt64
        ) {
            precondition(maximumInFlightRequests > 0)
            precondition(maximumRequestsPerInterval >= maximumInFlightRequests)
            precondition(rateIntervalNanoseconds > 0)
            precondition(maximumFutureDeadlineNanoseconds > 0)
            self.maximumInFlightRequests = maximumInFlightRequests
            self.maximumRequestsPerInterval = maximumRequestsPerInterval
            self.rateIntervalNanoseconds = rateIntervalNanoseconds
            self.maximumFutureDeadlineNanoseconds = maximumFutureDeadlineNanoseconds
        }
    }

    private struct State: Sendable {
        var acceptedSession: XPCSession?
        var didAcceptSession = false
        var engineEpoch: UUID?
        var isCancelled = false
        var inFlightRequestCount = 0
        var rateIntervalStart: UInt64?
        var requestsInRateInterval = 0
    }

    private let registry: TorrentStorageBrokerRegistry
    private let sessionNonce: UUID
    private let limits: Limits
    private let state = Mutex(State())

    package init(
        registry: TorrentStorageBrokerRegistry,
        sessionNonce: UUID,
        limits: Limits = .production
    ) {
        self.registry = registry
        self.sessionNonce = sessionNonce
        self.limits = limits
    }

    package func reserveSession() -> Bool {
        state.withLock { state in
            guard !state.isCancelled, !state.didAcceptSession else {
                return false
            }
            state.didAcceptSession = true
            return true
        }
    }

    package func install(session: XPCSession) {
        let shouldCancel = state.withLock { state in
            guard !state.isCancelled else {
                return true
            }
            state.acceptedSession = session
            return false
        }
        if shouldCancel {
            session.cancel(reason: "The storage broker is no longer available")
        }
    }

    package func handle(_ dictionary: XPCDictionary) -> XPCDictionary? {
        let requestStart = DispatchTime.now().uptimeNanoseconds
        guard beginRequest(at: requestStart) else {
            return nil
        }
        defer { finishRequest() }

        var descriptorToClose: Int32?
        defer {
            if let descriptorToClose {
                _ = Darwin.close(descriptorToClose)
            }
        }
        let request: TorrentStorageBrokerRequest
        do {
            request = try TorrentStorageBrokerIPCCodec.decodeRequest(dictionary)
        } catch {
            cancel(reason: "The storage broker received a malformed request")
            return nil
        }
        let common = request.common
        let reply: TorrentStorageBrokerReply
        do {
            guard common.sessionNonce == sessionNonce else {
                throw TorrentStorageBrokerFailure.sessionRejected
            }
            try validateDeadline(common.deadlineUptimeNanoseconds, now: requestStart)
            try authenticate(request)
            switch request {
            case .handshake:
                reply = .success(
                    requestID: common.requestID,
                    metadata: nil,
                    statistics: [],
                    fileDescriptor: nil
                )
            case .openPayload(_, let claimID, let generation, let fileIndex, let access):
                let opened = try registry.openPayload(
                    claimID: claimID,
                    generation: generation,
                    fileIndex: fileIndex,
                    access: access
                )
                descriptorToClose = opened.descriptor
                try checkDeadline(common.deadlineUptimeNanoseconds)
                reply = .success(
                    requestID: common.requestID,
                    metadata: opened.metadata,
                    statistics: [],
                    fileDescriptor: opened.descriptor
                )
            case .statBatch(_, let claimID, let generation, let fileIndices):
                reply = .success(
                    requestID: common.requestID,
                    metadata: nil,
                    statistics: try registry.statBatch(
                        claimID: claimID,
                        generation: generation,
                        fileIndices: fileIndices,
                        deadlineUptimeNanoseconds: common.deadlineUptimeNanoseconds
                    ),
                    fileDescriptor: nil
                )
            }
        } catch let failure as TorrentStorageBrokerFailure {
            reply = .failure(
                requestID: common.requestID,
                code: failure,
                message: Self.message(for: failure)
            )
        } catch let failure as TorrentStorageBrokerRegistryError {
            let code = Self.failureCode(for: failure)
            reply = .failure(
                requestID: common.requestID,
                code: code,
                message: Self.message(for: code)
            )
        } catch {
            reply = .failure(
                requestID: common.requestID,
                code: .internalFailure,
                message: Self.message(for: .internalFailure)
            )
        }
        return try? TorrentStorageBrokerIPCCodec.encode(reply, for: request)
    }

    package func cancel() {
        cancel(reason: "The storage broker session ended")
    }

    private func cancel(reason: String) {
        let session = state.withLock { state in
            guard !state.isCancelled else {
                return nil as XPCSession?
            }
            state.isCancelled = true
            let session = state.acceptedSession
            state.acceptedSession = nil
            state.engineEpoch = nil
            return session
        }
        session?.cancel(reason: reason)
    }

    private func beginRequest(at now: UInt64) -> Bool {
        let result: (accepted: Bool, session: XPCSession?) = state.withLock { state in
            guard !state.isCancelled else {
                return (false, nil)
            }
            let rateIntervalExpired: Bool
            if let start = state.rateIntervalStart {
                rateIntervalExpired = now < start
                    || now - start >= limits.rateIntervalNanoseconds
            } else {
                rateIntervalExpired = true
            }
            if rateIntervalExpired {
                state.rateIntervalStart = now
                state.requestsInRateInterval = 0
            }
            guard state.requestsInRateInterval
                    < limits.maximumRequestsPerInterval,
                  state.inFlightRequestCount
                    < limits.maximumInFlightRequests else {
                return (false, Self.cancelledSession(from: &state))
            }
            state.requestsInRateInterval += 1
            state.inFlightRequestCount += 1
            return (true, nil)
        }
        result.session?.cancel(reason: "The storage broker request limit was exceeded")
        return result.accepted
    }

    private func finishRequest() {
        state.withLock { state in
            precondition(state.inFlightRequestCount > 0)
            state.inFlightRequestCount -= 1
        }
    }

    private func validateDeadline(_ deadline: UInt64, now: UInt64) throws {
        try checkDeadline(deadline)
        let upperBound = now.addingReportingOverflow(
            limits.maximumFutureDeadlineNanoseconds
        )
        guard !upperBound.overflow,
              deadline <= upperBound.partialValue else {
            throw TorrentStorageBrokerFailure.deadlineExceeded
        }
    }

    private func checkDeadline(_ deadline: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw TorrentStorageBrokerFailure.deadlineExceeded
        }
    }

    private static func cancelledSession(from state: inout State) -> XPCSession? {
        state.isCancelled = true
        let session = state.acceptedSession
        state.acceptedSession = nil
        state.engineEpoch = nil
        return session
    }

    private func authenticate(_ request: TorrentStorageBrokerRequest) throws {
        try state.withLock { state in
            guard !state.isCancelled else {
                throw TorrentStorageBrokerFailure.sessionRejected
            }
            switch request {
            case .handshake(let common):
                if let engineEpoch = state.engineEpoch {
                    guard engineEpoch == common.engineEpoch else {
                        throw TorrentStorageBrokerFailure.sessionRejected
                    }
                } else {
                    state.engineEpoch = common.engineEpoch
                }
            default:
                guard state.engineEpoch == request.common.engineEpoch else {
                    throw TorrentStorageBrokerFailure.sessionRejected
                }
            }
        }
    }

    private static func failureCode(
        for error: TorrentStorageBrokerRegistryError
    ) -> TorrentStorageBrokerFailure {
        switch error {
        case .invalidClaim, .claimUnavailable, .claimInactive:
            .claimUnavailable
        case .generationMismatch:
            .generationMismatch
        case .fileUnavailable:
            .fileUnavailable
        case .accessDenied:
            .accessDenied
        case .filesystemObjectChanged:
            .filesystemObjectChanged
        case .deadlineExceeded:
            .deadlineExceeded
        }
    }

    private static func message(for failure: TorrentStorageBrokerFailure) -> String {
        switch failure {
        case .malformedRequest:
            "The storage broker request was malformed."
        case .sessionRejected:
            "The storage broker session was rejected."
        case .claimUnavailable:
            "The storage claim is unavailable."
        case .generationMismatch:
            "The storage claim generation changed."
        case .fileUnavailable:
            "The payload file is unavailable."
        case .accessDenied:
            "Payload access is not permitted."
        case .filesystemObjectChanged:
            "The payload filesystem object changed."
        case .deadlineExceeded:
            "The storage broker request deadline expired."
        case .internalFailure:
            "The storage broker could not complete the request."
        }
    }
}

@safe package final class TorrentStorageBrokerServer: Sendable {
    package let endpoint: XPCEndpoint
    package let sessionNonce: UUID

    private let listener: XPCListener
    private let gate: TorrentStorageBrokerSessionGate

    package init(
        registry: TorrentStorageBrokerRegistry,
        engineConfiguration: TorrentEngineXPCConfiguration
    ) throws {
        let nonce = UUID()
        let gate = TorrentStorageBrokerSessionGate(
            registry: registry,
            sessionNonce: nonce
        )
        let queue = DispatchQueue(
            label: "app.torrent7.storage-broker",
            qos: .userInitiated,
            attributes: .concurrent
        )
        let listener = XPCListener(
            targetQueue: queue,
            options: .inactive
        ) { request in
            guard gate.reserveSession() else {
                return request.reject(reason: "A storage broker session already exists")
            }
            let accepted: (
                XPCListener.IncomingSessionRequest.Decision,
                XPCSession
            ) = request.accept(
                incomingMessageHandler: { (message: XPCDictionary) in
                    gate.handle(message)
                },
                cancellationHandler: { _ in
                    gate.cancel()
                }
            )
            if engineConfiguration.authentication == .sameTeam {
                accepted.1.setPeerRequirement(
                    .isFromSameTeam(
                        andMatchesSigningIdentifier: engineConfiguration.serviceIdentifier
                    )
                )
            }
            gate.install(session: accepted.1)
            return accepted.0
        }
        self.sessionNonce = nonce
        self.gate = gate
        self.listener = listener
        endpoint = listener.endpoint
        try listener.activate()
    }

    package func cancel() {
        gate.cancel()
        listener.cancel()
    }

    deinit {
        cancel()
    }
}
