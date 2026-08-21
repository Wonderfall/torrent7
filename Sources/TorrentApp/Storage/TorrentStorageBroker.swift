import Darwin
import Foundation
import Synchronization
import TorrentEngineClient
import TorrentEngineIPC
import XPC

enum TorrentStorageBrokerRegistryError: LocalizedError, Equatable, Sendable {
    case invalidClaim
    case claimUnavailable
    case generationMismatch
    case claimInactive
    case fileUnavailable
    case accessDenied
    case filesystemObjectChanged

    var errorDescription: String? {
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
        }
    }
}

@safe final class TorrentStorageBrokerRegistry: Sendable {
    private struct State: Sendable {
        var parentAuthorities = [UUID: TorrentStorageParentAuthority]()
        var claims = [UUID: TorrentStorageClaim]()
    }

    private struct ResolvedFile: Sendable {
        let parent: TorrentStorageParentAuthority
        let mapping: TorrentPhysicalFileMapping
        let logicalFile: TorrentLogicalFile
        let policy: TorrentPayloadFilePolicy
        let ownershipToken: Data
    }

    private let state = Mutex(State())

    func install(parentAuthority: TorrentStorageParentAuthority) throws {
        try parentAuthority.validate()
        state.withLock { state in
            state.parentAuthorities[parentAuthority.id] = parentAuthority
        }
    }

    func install(claim: TorrentStorageClaim) throws {
        try Self.validate(claim)
        let hasParent = state.withLock { state in
            guard state.parentAuthorities[claim.manifest.parentAuthorityID] != nil else {
                return false
            }
            state.claims[claim.manifest.claimID] = claim
            return true
        }
        guard hasParent else {
            throw TorrentStorageBrokerRegistryError.invalidClaim
        }
    }

    func replaceLease(
        claimID: UUID,
        generation: UInt64,
        expectedPolicyRevision: UInt64,
        with lease: TorrentStorageLease
    ) throws {
        try state.withLock { state in
            guard var claim = state.claims[claimID] else {
                throw TorrentStorageBrokerRegistryError.claimUnavailable
            }
            guard claim.manifest.generation == generation else {
                throw TorrentStorageBrokerRegistryError.generationMismatch
            }
            guard claim.lease.policyRevision == expectedPolicyRevision,
                  lease.policyRevision > expectedPolicyRevision,
                  claim.lease.state == .active,
                  lease.state == claim.lease.state,
                  TorrentStoragePolicyValidation.isValid(
                      logicalFiles: claim.manifest.logicalFiles,
                      policies: lease.filePolicies
                  ),
                  TorrentStoragePolicyValidation.preservesAuthorityMetadata(
                      existing: claim.lease.filePolicies,
                      replacement: lease.filePolicies
                  ) else {
                throw TorrentStorageBrokerRegistryError.invalidClaim
            }
            claim.lease = lease
            state.claims[claimID] = claim
        }
    }

    func removeClaim(claimID: UUID, generation: UInt64) throws {
        try state.withLock { state in
            guard let claim = state.claims[claimID] else {
                return
            }
            guard claim.manifest.generation == generation else {
                throw TorrentStorageBrokerRegistryError.generationMismatch
            }
            state.claims.removeValue(forKey: claimID)
        }
    }

    func locationsByTorrentID() -> [String: TorrentStorageLocation] {
        state.withLock { state in
            var locations = [String: TorrentStorageLocation]()
            var ambiguousIDs = Set<String>()
            locations.reserveCapacity(state.claims.count)
            for claim in state.claims.values {
                guard claim.lease.state == .activating
                        || claim.lease.state == .active
                        || claim.lease.state == .activationUnknown,
                      let parent = state.parentAuthorities[
                          claim.manifest.parentAuthorityID
                      ],
                      let location = TorrentStorageLocation(
                          claim: claim,
                          parent: parent
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

    func openPayload(
        claimID: UUID,
        generation: UInt64,
        fileIndex: Int32,
        access: TorrentStorageBrokerAccess
    ) throws -> (descriptor: Int32, metadata: TorrentStorageBrokerFileMetadata) {
        let resolved = try resolvedFile(
            claimID: claimID,
            generation: generation,
            fileIndex: fileIndex,
            requiresActiveClaim: true
        )
        guard !resolved.logicalFile.isPadding,
              resolved.mapping.relativePathComponents != nil,
              resolved.mapping.identity != nil else {
            throw TorrentStorageBrokerRegistryError.fileUnavailable
        }
        try Self.validate(access: access, against: resolved.policy)

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

    func statBatch(
        claimID: UUID,
        generation: UInt64,
        fileIndices: [Int32]
    ) throws -> [TorrentStorageBrokerFileMetadata] {
        guard !fileIndices.isEmpty,
              fileIndices.count <= TorrentStorageBrokerProtocol.maximumStatBatchCount else {
            throw TorrentStorageBrokerRegistryError.invalidClaim
        }
        return try fileIndices.map { fileIndex in
            let resolved = try resolvedFile(
                claimID: claimID,
                generation: generation,
                fileIndex: fileIndex,
                requiresActiveClaim: true
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
            return try Self.validatePayloadDescriptor(
                descriptor,
                resolved: resolved,
                access: .readOnly
            )
        }
    }

    private func resolvedFile(
        claimID: UUID,
        generation: UInt64,
        fileIndex: Int32,
        requiresActiveClaim: Bool
    ) throws -> ResolvedFile {
        try state.withLock { state in
            guard let claim = state.claims[claimID],
                  let parent = state.parentAuthorities[claim.manifest.parentAuthorityID] else {
                throw TorrentStorageBrokerRegistryError.claimUnavailable
            }
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
            guard let mapping = claim.manifest.physicalMappings.first(where: {
                $0.fileIndex == fileIndex
            }),
            let logicalFile = claim.manifest.logicalFiles.first(where: {
                $0.index == fileIndex
            }),
            let policy = claim.lease.filePolicies.first(where: {
                $0.fileIndex == fileIndex
            }) else {
                throw TorrentStorageBrokerRegistryError.fileUnavailable
            }
            return ResolvedFile(
                parent: parent,
                mapping: mapping,
                logicalFile: logicalFile,
                policy: policy,
                ownershipToken: claim.manifest.ownershipToken
            )
        }
    }

    private static func validate(_ claim: TorrentStorageClaim) throws {
        let manifest = claim.manifest
        guard manifest.generation > 0,
              manifest.ownershipToken.count == 32,
              manifest.sourceManifestDigest.count == 32,
              manifest.claimMappingDigest.count == 32,
              !manifest.logicalFiles.isEmpty,
              manifest.logicalFiles.map(\.index)
                == Array(0..<Int32(manifest.logicalFiles.count)),
              manifest.physicalMappings.map(\.fileIndex)
                == manifest.logicalFiles.map(\.index),
              claim.lease.policyRevision > 0,
              claim.lease.filePolicies.map(\.fileIndex)
                == manifest.logicalFiles.map(\.index),
              TorrentStoragePolicyValidation.isValid(
                  logicalFiles: manifest.logicalFiles,
                  policies: claim.lease.filePolicies
              ),
              TorrentManifestDigest.mapping(
                claimID: manifest.claimID,
                generation: manifest.generation,
                parentAuthorityID: manifest.parentAuthorityID,
                topLevelName: manifest.collisionSelectedTopLevelName,
                mappings: manifest.physicalMappings
              ) == manifest.claimMappingDigest else {
            throw TorrentStorageBrokerRegistryError.invalidClaim
        }
        for (logicalFile, mapping) in zip(
            manifest.logicalFiles,
            manifest.physicalMappings
        ) {
            guard logicalFile.expectedSize >= 0,
                  logicalFile.isPadding
                    == (mapping.relativePathComponents == nil),
                  (mapping.relativePathComponents == nil)
                    == (mapping.identity == nil) else {
                throw TorrentStorageBrokerRegistryError.invalidClaim
            }
        }
    }

    private static func validate(
        access: TorrentStorageBrokerAccess,
        against policy: TorrentPayloadFilePolicy
    ) throws {
        switch (policy.maximumAccess, access) {
        case (.unavailable, _):
            throw TorrentStorageBrokerRegistryError.accessDenied
        case (.verificationReadOnly, .readWrite):
            throw TorrentStorageBrokerRegistryError.accessDenied
        case (.verificationReadOnly, .readOnly):
            return
        case (.appOwnedWritable, .readOnly),
             (.explicitlyImportedWritable, .readOnly):
            return
        case (.appOwnedWritable, .readWrite),
             (.explicitlyImportedWritable, .readWrite):
            guard policy.mayModify else {
                throw TorrentStorageBrokerRegistryError.accessDenied
            }
        }
    }

    private static func open(
        _ resolved: ResolvedFile,
        access: TorrentStorageBrokerAccess
    ) throws -> Int32 {
        try resolved.parent.validate()
        guard let components = resolved.mapping.relativePathComponents,
              !components.isEmpty,
              components.allSatisfy(isSafeComponent) else {
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
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
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
                | O_CLOEXEC | O_NOFOLLOW
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
        guard let expectedIdentity = resolved.mapping.identity else {
            throw TorrentStorageBrokerRegistryError.fileUnavailable
        }
        var metadata = stat()
        guard unsafe Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= resolved.logicalFile.expectedSize,
              UInt64(truncatingIfNeeded: metadata.st_dev) == expectedIdentity.device,
              UInt64(truncatingIfNeeded: metadata.st_ino) == expectedIdentity.inode,
              UInt64(truncatingIfNeeded: metadata.st_nlink) == expectedIdentity.linkCount else {
            throw TorrentStorageBrokerRegistryError.filesystemObjectChanged
        }

        switch resolved.policy.provenance {
        case .appCreated:
            guard metadata.st_uid == geteuid(), metadata.st_nlink == 1,
                  ownershipMarker(on: descriptor) == resolved.ownershipToken else {
                throw TorrentStorageBrokerRegistryError.filesystemObjectChanged
            }
        case .imported:
            if access == .readWrite {
                guard resolved.policy.mayModify, metadata.st_nlink == 1 else {
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

    private static func ownershipMarker(on descriptor: Int32) -> Data? {
        var marker = [UInt8](repeating: 0, count: 32)
        let count = unsafe marker.withUnsafeMutableBytes { bytes in
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
        guard count == marker.count else {
            return nil
        }
        return Data(marker)
    }

    private static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.utf8.contains(0)
            && !component.contains("/")
            && !component.contains("\\")
    }
}

@safe private final class TorrentStorageBrokerSessionGate: Sendable {
    private struct State: Sendable {
        var acceptedSession: XPCSession?
        var didAcceptSession = false
        var engineEpoch: UUID?
        var isCancelled = false
    }

    private let registry: TorrentStorageBrokerRegistry
    private let sessionNonce: UUID
    private let state = Mutex(State())

    init(registry: TorrentStorageBrokerRegistry, sessionNonce: UUID) {
        self.registry = registry
        self.sessionNonce = sessionNonce
    }

    func reserveSession() -> Bool {
        state.withLock { state in
            guard !state.isCancelled, !state.didAcceptSession else {
                return false
            }
            state.didAcceptSession = true
            return true
        }
    }

    func install(session: XPCSession) {
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

    func handle(_ dictionary: XPCDictionary) -> XPCDictionary? {
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
            return nil
        }
        let common = request.common
        let reply: TorrentStorageBrokerReply
        do {
            guard common.sessionNonce == sessionNonce else {
                throw TorrentStorageBrokerFailure.sessionRejected
            }
            guard DispatchTime.now().uptimeNanoseconds
                    < common.deadlineUptimeNanoseconds else {
                throw TorrentStorageBrokerFailure.deadlineExceeded
            }
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
                        fileIndices: fileIndices
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

    func cancel() {
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
        session?.cancel(reason: "The storage broker session ended")
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

@safe final class TorrentStorageBrokerServer: Sendable {
    let endpoint: XPCEndpoint
    let sessionNonce: UUID

    private let listener: XPCListener
    private let gate: TorrentStorageBrokerSessionGate

    init(
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

    func cancel() {
        gate.cancel()
        listener.cancel()
    }

    deinit {
        cancel()
    }
}
