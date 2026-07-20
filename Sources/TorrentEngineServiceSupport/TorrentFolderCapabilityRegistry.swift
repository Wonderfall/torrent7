import Darwin
import CryptoKit
import Foundation
import Synchronization
import System

private final class TorrentEngineServiceScopeValidity: Sendable {
    private let active = Mutex(true)

    init() {}

    var isActive: Bool {
        active.withLock { $0 }
    }

    func invalidate() {
        active.withLock { $0 = false }
    }
}

package struct TorrentEngineServiceScope: Hashable, Sendable {
    package let engineEpoch: UUID
    package let controllerID: UUID
    package let generation: UUID
    private let validity: TorrentEngineServiceScopeValidity

    package init(
        engineEpoch: UUID,
        controllerID: UUID
    ) {
        self.engineEpoch = engineEpoch
        self.controllerID = controllerID
        generation = UUID()
        validity = TorrentEngineServiceScopeValidity()
    }

    package var isActive: Bool {
        validity.isActive
    }

    package func invalidate() {
        validity.invalidate()
    }

    package static func == (
        lhs: TorrentEngineServiceScope,
        rhs: TorrentEngineServiceScope
    ) -> Bool {
        lhs.engineEpoch == rhs.engineEpoch
            && lhs.controllerID == rhs.controllerID
            && lhs.generation == rhs.generation
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(engineEpoch)
        hasher.combine(controllerID)
        hasher.combine(generation)
    }
}

package struct TorrentFolderIdentity: Equatable, Hashable, Sendable {
    package let device: UInt64
    package let inode: UInt64

    package init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

package enum TorrentFolderCapabilityState: Equatable, Sendable {
    case provisional
    case committed
}

package struct TorrentFolderCapability: Equatable, Sendable {
    package let id: UUID
    package let scope: TorrentEngineServiceScope
    package let canonicalPath: String
    package let identity: TorrentFolderIdentity
    package let state: TorrentFolderCapabilityState
}

package struct TorrentFolderCapabilityLimits: Equatable, Sendable {
    package static let `default` = Self(
        maximumCapabilityCount: 32,
        maximumBookmarkBytes: 1_048_576,
        maximumAggregateBookmarkBytes: 20_480_000,
        maximumCanonicalPathBytes: 1_023
    )

    package let maximumCapabilityCount: Int
    package let maximumBookmarkBytes: Int
    package let maximumAggregateBookmarkBytes: Int
    package let maximumCanonicalPathBytes: Int

    package init(
        maximumCapabilityCount: Int,
        maximumBookmarkBytes: Int,
        maximumAggregateBookmarkBytes: Int,
        maximumCanonicalPathBytes: Int = 1_023
    ) {
        precondition(maximumCapabilityCount > 0)
        precondition(maximumBookmarkBytes > 0)
        precondition(maximumAggregateBookmarkBytes > 0)
        precondition(maximumCanonicalPathBytes > 0)
        self.maximumCapabilityCount = maximumCapabilityCount
        self.maximumBookmarkBytes = maximumBookmarkBytes
        self.maximumAggregateBookmarkBytes = maximumAggregateBookmarkBytes
        self.maximumCanonicalPathBytes = maximumCanonicalPathBytes
    }
}

package enum TorrentFolderCapabilityError: Error, Equatable, Sendable {
    case wrongEngineEpoch
    case controllerDisconnected
    case emptyBookmark
    case bookmarkTooLarge(actual: Int, maximum: Int)
    case tooManyCapabilities(maximum: Int)
    case aggregateBookmarksTooLarge(maximum: Int)
    case bookmarkResolutionFailed
    case staleBookmark
    case securityScopeDenied
    case nonFileURL
    case nonCanonicalDirectory
    case canonicalPathTooLarge(maximum: Int)
    case directoryOpenFailed
    case duplicateDirectory
    case unknownCapability
    case capabilityInvalidated
    case staleReplacement
}

package protocol TorrentSecurityScopedResourceAccessing: AnyObject, Sendable {
    var url: URL { get }
    var bookmarkDataIsStale: Bool { get }
    func startAccessingSecurityScopedResource() -> Bool
    func stopAccessingSecurityScopedResource()
}

package protocol TorrentFolderBookmarkResolving: Sendable {
    func resolve(bookmarkData: Data) throws -> any TorrentSecurityScopedResourceAccessing
}

package struct TorrentFoundationFolderBookmarkResolver: TorrentFolderBookmarkResolving {
    // Cross-process delegation bookmarks carry an implicit sandbox extension.
    // Resolution must not activate it as a side effect: the registry starts and
    // balances the scope explicitly after every payload bound has passed.
    package static let resolutionOptions: URL.BookmarkResolutionOptions = [
        .withoutUI,
        .withoutMounting,
        .withoutImplicitStartAccessing,
    ]

    package init() {}

    package func resolve(
        bookmarkData: Data
    ) throws -> any TorrentSecurityScopedResourceAccessing {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: Self.resolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return TorrentFoundationSecurityScopedResource(url: url, isStale: isStale)
    }
}

private final class TorrentFoundationSecurityScopedResource:
    TorrentSecurityScopedResourceAccessing,
    Sendable
{
    let url: URL
    let bookmarkDataIsStale: Bool

    init(url: URL, isStale: Bool) {
        self.url = url
        bookmarkDataIsStale = isStale
    }

    func startAccessingSecurityScopedResource() -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessingSecurityScopedResource() {
        url.stopAccessingSecurityScopedResource()
    }
}

package final class TorrentFolderCapabilityPin: Sendable {
    package let capabilityID: UUID
    package let scope: TorrentEngineServiceScope
    package let canonicalPath: String
    package let identity: TorrentFolderIdentity

    private let access: TorrentFolderCapabilityAccess

    fileprivate init(entry: TorrentFolderCapabilityEntry) {
        capabilityID = entry.capability.id
        scope = entry.capability.scope
        canonicalPath = entry.capability.canonicalPath
        identity = entry.capability.identity
        access = entry.access
    }

    package var isValid: Bool {
        scope.isActive && access.isActive
    }

    /// Keeps the security scope and registry-owned descriptor alive while a
    /// native storage root derived from this pin can still be used.
    package var accessLifetimeAnchor: any AnyObject & Sendable {
        access
    }

    package func directoryFileDescriptor() throws -> Int32 {
        guard scope.isActive else {
            throw TorrentFolderCapabilityError.capabilityInvalidated
        }
        return try access.fileDescriptor()
    }
}

package final class TorrentFolderCapabilityReplacement: Sendable {
    fileprivate let scope: TorrentEngineServiceScope
    fileprivate let expectedRegistryRevision: UInt64
    fileprivate let entries: [TorrentFolderCapabilityEntry]

    fileprivate init(
        scope: TorrentEngineServiceScope,
        expectedRegistryRevision: UInt64,
        entries: [TorrentFolderCapabilityEntry]
    ) {
        self.scope = scope
        self.expectedRegistryRevision = expectedRegistryRevision
        self.entries = entries
    }

    package var capabilities: [TorrentFolderCapability] {
        entries.map(\.capability)
    }

    package var pins: [TorrentFolderCapabilityPin] {
        entries.map(TorrentFolderCapabilityPin.init(entry:))
    }
}

package final class TorrentFolderCapabilityRegistry: Sendable {
    private struct State {
        var entriesByID = [UUID: TorrentFolderCapabilityEntry]()
        var accessReferencesByScope = [
            TorrentEngineServiceScope: [TorrentWeakFolderCapabilityAccess]
        ]()
        var registryRevision: UInt64 = 0
    }

    package let engineEpoch: UUID

    private let limits: TorrentFolderCapabilityLimits
    private let bookmarkResolver: any TorrentFolderBookmarkResolving
    private let state = Mutex(State())

    package init(
        engineEpoch: UUID,
        limits: TorrentFolderCapabilityLimits = .default,
        bookmarkResolver: any TorrentFolderBookmarkResolving = TorrentFoundationFolderBookmarkResolver()
    ) {
        self.engineEpoch = engineEpoch
        self.limits = limits
        self.bookmarkResolver = bookmarkResolver
    }

    deinit {
        invalidateEveryAccess()
    }

    /// Resolves a complete controller snapshot before publishing any part of it.
    /// Every resulting grant is committed; previous grants become unpinnable atomically.
    package func replaceCommittedGrants(
        bookmarkData: [Data],
        scope: TorrentEngineServiceScope
    ) throws -> [TorrentFolderCapability] {
        let replacement = try prepareCommittedGrantReplacement(
            bookmarkData: bookmarkData,
            scope: scope
        )
        return try commit(replacement)
    }

    /// Resolves and validates a complete replacement without publishing it.
    /// The returned object retains one freshly validated or exactly reused
    /// scope and descriptor per entry so a caller can update the native
    /// allowlist before atomically committing the registry snapshot.
    package func prepareCommittedGrantReplacement(
        bookmarkData: [Data],
        scope: TorrentEngineServiceScope
    ) throws -> TorrentFolderCapabilityReplacement {
        try beginControllerOperation(scope: scope)
        try validateBookmarkCollection(bookmarkData)

        var candidates = [TorrentFolderCapabilityCandidate]()
        candidates.reserveCapacity(bookmarkData.count)
        var candidatePaths = Set<String>()
        var candidateIdentities = Set<TorrentFolderIdentity>()
        for bookmark in bookmarkData {
            let candidate = try makeCandidate(bookmarkData: bookmark)
            guard candidatePaths.insert(candidate.canonicalPath).inserted,
                  candidateIdentities.insert(candidate.identity).inserted else {
                throw TorrentFolderCapabilityError.duplicateDirectory
            }
            candidates.append(candidate)
        }

        let replacement = try state.withLock { state in
            try requireConnectedController(scope: scope)
            let retainedEntries = state.entriesByID.values.filter {
                $0.capability.scope != scope
            }
            let displacedEntries = state.entriesByID.values.filter {
                $0.capability.scope == scope
            }
            try validateProjectedTotals(
                retainedEntries: retainedEntries,
                candidateBookmarkBytes: candidates.map(\.bookmarkByteCount)
            )

            var replacementEntries = [TorrentFolderCapabilityEntry]()
            replacementEntries.reserveCapacity(candidates.count)
            var reservedIDs = Set(state.entriesByID.keys)
            for candidate in candidates {
                let reusableEntry = displacedEntries.first {
                    $0.bookmarkFingerprint == candidate.bookmarkFingerprint
                        && $0.capability.canonicalPath == candidate.canonicalPath
                        && $0.capability.identity == candidate.identity
                        && $0.access.isActive
                }
                let capability = TorrentFolderCapability(
                    id: reusableEntry?.capability.id
                        ?? makeCapabilityID(reserving: &reservedIDs),
                    scope: scope,
                    canonicalPath: candidate.canonicalPath,
                    identity: candidate.identity,
                    state: .committed
                )
                replacementEntries.append(TorrentFolderCapabilityEntry(
                    capability: capability,
                    bookmarkByteCount: candidate.bookmarkByteCount,
                    bookmarkFingerprint: candidate.bookmarkFingerprint,
                    access: reusableEntry?.access ?? candidate.access
                ))
            }
            let replacement = TorrentFolderCapabilityReplacement(
                scope: scope,
                expectedRegistryRevision: state.registryRevision,
                entries: replacementEntries
            )
            Self.rememberAccesses(
                replacementEntries.map(\.access),
                scope: scope,
                in: &state
            )
            return replacement
        }
        // Candidate accesses superseded by an identical active entry release
        // here, outside the registry lock. Unchanged snapshots therefore keep
        // one stable native lifetime context without skipping fresh bookmark,
        // path, or descriptor validation.
        candidates.removeAll()
        return replacement
    }

    /// Publishes a prepared replacement only when the registry has not changed
    /// since preparation. Superseded unpinned scopes are released afterwards.
    package func commit(
        _ replacement: TorrentFolderCapabilityReplacement
    ) throws -> [TorrentFolderCapability] {
        try validate(scope: replacement.scope)
        var displacedEntries = [TorrentFolderCapabilityEntry]()
        let capabilities = try state.withLock { state in
            try requireConnectedController(scope: replacement.scope)
            guard replacement.expectedRegistryRevision == state.registryRevision,
                  replacement.entries.allSatisfy({ $0.access.isActive }) else {
                throw TorrentFolderCapabilityError.staleReplacement
            }

            let retainedEntries = state.entriesByID.values.filter {
                $0.capability.scope != replacement.scope
            }
            let retainedIDs = Set(retainedEntries.map(\.capability.id))
            let replacementIDs = replacement.entries.map(\.capability.id)
            guard Set(replacementIDs).count == replacementIDs.count,
                  replacementIDs.allSatisfy({ !retainedIDs.contains($0) }) else {
                throw TorrentFolderCapabilityError.staleReplacement
            }
            displacedEntries = state.entriesByID.values.filter {
                $0.capability.scope == replacement.scope
            }
            state.entriesByID = Dictionary(
                uniqueKeysWithValues: retainedEntries.map { ($0.capability.id, $0) }
            )
            for entry in replacement.entries {
                state.entriesByID[entry.capability.id] = entry
            }
            Self.incrementRegistryRevision(&state)
            return replacement.capabilities
        }

        // Release superseded unpinned scopes and descriptors outside the registry lock.
        displacedEntries.removeAll()
        return capabilities
    }

    package func grantProvisional(
        bookmarkData: Data,
        scope: TorrentEngineServiceScope
    ) throws -> TorrentFolderCapability {
        try beginControllerOperation(scope: scope)
        try validateBookmark(bookmarkData)
        let candidate = try makeCandidate(bookmarkData: bookmarkData)

        return try state.withLock { state in
            try requireConnectedController(scope: scope)
            try validateProjectedTotals(
                retainedEntries: Array(state.entriesByID.values),
                candidateBookmarkBytes: [candidate.bookmarkByteCount]
            )
            guard !state.entriesByID.values.contains(where: {
                $0.capability.scope == scope
                    && ($0.capability.canonicalPath == candidate.canonicalPath
                        || $0.capability.identity == candidate.identity)
            }) else {
                throw TorrentFolderCapabilityError.duplicateDirectory
            }

            var reservedIDs = Set(state.entriesByID.keys)
            let capability = TorrentFolderCapability(
                id: makeCapabilityID(reserving: &reservedIDs),
                scope: scope,
                canonicalPath: candidate.canonicalPath,
                identity: candidate.identity,
                state: .provisional
            )
            let entry = TorrentFolderCapabilityEntry(
                capability: capability,
                bookmarkByteCount: candidate.bookmarkByteCount,
                bookmarkFingerprint: candidate.bookmarkFingerprint,
                access: candidate.access
            )
            state.entriesByID[capability.id] = entry
            Self.rememberAccesses([entry.access], scope: scope, in: &state)
            Self.incrementRegistryRevision(&state)
            return capability
        }
    }

    @discardableResult
    package func commit(
        capabilityID: UUID,
        scope: TorrentEngineServiceScope
    ) throws -> TorrentFolderCapability {
        try validate(scope: scope)
        return try state.withLock { state in
            try requireConnectedController(scope: scope)
            guard var entry = Self.entry(
                capabilityID: capabilityID,
                scope: scope,
                in: state
            ) else {
                throw TorrentFolderCapabilityError.unknownCapability
            }
            guard entry.access.isActive else {
                state.entriesByID.removeValue(forKey: capabilityID)
                Self.incrementRegistryRevision(&state)
                throw TorrentFolderCapabilityError.capabilityInvalidated
            }
            if entry.capability.state == .provisional {
                entry.capability = TorrentFolderCapability(
                    id: entry.capability.id,
                    scope: entry.capability.scope,
                    canonicalPath: entry.capability.canonicalPath,
                    identity: entry.capability.identity,
                    state: .committed
                )
                state.entriesByID[capabilityID] = entry
                Self.incrementRegistryRevision(&state)
            }
            return entry.capability
        }
    }

    package func pin(
        capabilityID: UUID,
        scope: TorrentEngineServiceScope
    ) throws -> TorrentFolderCapabilityPin {
        try validate(scope: scope)
        return try state.withLock { state in
            try requireConnectedController(scope: scope)
            guard let entry = Self.entry(
                capabilityID: capabilityID,
                scope: scope,
                in: state
            ) else {
                throw TorrentFolderCapabilityError.unknownCapability
            }
            guard entry.access.isActive else {
                state.entriesByID.removeValue(forKey: capabilityID)
                Self.incrementRegistryRevision(&state)
                throw TorrentFolderCapabilityError.capabilityInvalidated
            }
            return TorrentFolderCapabilityPin(entry: entry)
        }
    }

    /// Captures one coherent descriptor-backed authorization snapshot. Each
    /// pin retains its security scope even if the registry is changed after
    /// this method returns.
    package func pins(
        scope: TorrentEngineServiceScope
    ) throws -> [TorrentFolderCapabilityPin] {
        try validate(scope: scope)
        return try state.withLock { state in
            try requireConnectedController(scope: scope)
            let entries = state.entriesByID.values
                .filter { $0.capability.scope == scope }
                .sorted { $0.capability.canonicalPath < $1.capability.canonicalPath }
            guard entries.allSatisfy({ $0.access.isActive }) else {
                let invalidIDs = entries.lazy
                    .filter { !$0.access.isActive }
                    .map(\.capability.id)
                for capabilityID in invalidIDs {
                    state.entriesByID.removeValue(forKey: capabilityID)
                }
                Self.incrementRegistryRevision(&state)
                throw TorrentFolderCapabilityError.capabilityInvalidated
            }
            return entries.map(TorrentFolderCapabilityPin.init(entry:))
        }
    }

    /// Revocation prevents all new pins immediately. Existing pins retain access until
    /// they are released, unless the owning controller disconnects first.
    @discardableResult
    package func revoke(
        capabilityID: UUID,
        scope: TorrentEngineServiceScope
    ) throws -> Bool {
        try validate(scope: scope)
        let removed: TorrentFolderCapabilityEntry? = try state.withLock { state in
            try requireConnectedController(scope: scope)
            guard let entry = Self.entry(
                capabilityID: capabilityID,
                scope: scope,
                in: state
            ) else {
                return nil
            }
            let removed = state.entriesByID.removeValue(forKey: entry.capability.id)
            if removed != nil {
                Self.incrementRegistryRevision(&state)
            }
            return removed
        }
        return removed != nil
    }

    /// A disconnect is stronger than ordinary revocation: it invalidates resources
    /// retained by outstanding pins so no descriptor or security scope crosses sessions.
    package func disconnect(scope: TorrentEngineServiceScope) {
        scope.invalidate()
        let accesses = state.withLock { state in
            state.entriesByID = state.entriesByID.filter {
                $0.value.capability.scope != scope
            }
            Self.incrementRegistryRevision(&state)
            let references = state.accessReferencesByScope.removeValue(forKey: scope) ?? []
            return references.compactMap(\.access)
        }
        for access in uniqueAccesses(accesses) {
            access.invalidate()
        }
    }

    package func disconnectAll() {
        invalidateEveryAccess()
    }

    package func capability(
        capabilityID: UUID,
        scope: TorrentEngineServiceScope
    ) throws -> TorrentFolderCapability? {
        try validate(scope: scope)
        return try state.withLock { state in
            try requireConnectedController(scope: scope)
            return Self.entry(
                capabilityID: capabilityID,
                scope: scope,
                in: state
            )?.capability
        }
    }

    package func capabilities(scope: TorrentEngineServiceScope) -> [TorrentFolderCapability] {
        state.withLock { state in
            state.entriesByID.values
                .map(\.capability)
                .filter { $0.scope == scope }
                .sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    private func validate(scope: TorrentEngineServiceScope) throws {
        guard scope.engineEpoch == engineEpoch else {
            throw TorrentFolderCapabilityError.wrongEngineEpoch
        }
    }

    private func beginControllerOperation(scope: TorrentEngineServiceScope) throws {
        try validate(scope: scope)
        try state.withLock { _ in
            try requireConnectedController(scope: scope)
        }
    }

    private func requireConnectedController(scope: TorrentEngineServiceScope) throws {
        guard scope.isActive else {
            throw TorrentFolderCapabilityError.controllerDisconnected
        }
    }

    private func validateBookmarkCollection(_ bookmarks: [Data]) throws {
        guard bookmarks.count <= limits.maximumCapabilityCount else {
            throw TorrentFolderCapabilityError.tooManyCapabilities(
                maximum: limits.maximumCapabilityCount
            )
        }
        var aggregate = 0
        for bookmark in bookmarks {
            try validateBookmark(bookmark)
            guard bookmark.count <= limits.maximumAggregateBookmarkBytes - aggregate else {
                throw TorrentFolderCapabilityError.aggregateBookmarksTooLarge(
                    maximum: limits.maximumAggregateBookmarkBytes
                )
            }
            aggregate += bookmark.count
        }
    }

    private func validateBookmark(_ bookmark: Data) throws {
        guard !bookmark.isEmpty else {
            throw TorrentFolderCapabilityError.emptyBookmark
        }
        guard bookmark.count <= limits.maximumBookmarkBytes else {
            throw TorrentFolderCapabilityError.bookmarkTooLarge(
                actual: bookmark.count,
                maximum: limits.maximumBookmarkBytes
            )
        }
    }

    private func validateProjectedTotals(
        retainedEntries: [TorrentFolderCapabilityEntry],
        candidateBookmarkBytes: [Int]
    ) throws {
        guard retainedEntries.count <= limits.maximumCapabilityCount - candidateBookmarkBytes.count else {
            throw TorrentFolderCapabilityError.tooManyCapabilities(
                maximum: limits.maximumCapabilityCount
            )
        }

        var aggregate = retainedEntries.reduce(into: 0) { total, entry in
            total += entry.bookmarkByteCount
        }
        for byteCount in candidateBookmarkBytes {
            guard byteCount <= limits.maximumAggregateBookmarkBytes - aggregate else {
                throw TorrentFolderCapabilityError.aggregateBookmarksTooLarge(
                    maximum: limits.maximumAggregateBookmarkBytes
                )
            }
            aggregate += byteCount
        }
    }

    private func makeCandidate(bookmarkData: Data) throws -> TorrentFolderCapabilityCandidate {
        let scopedResource: any TorrentSecurityScopedResourceAccessing
        do {
            scopedResource = try bookmarkResolver.resolve(bookmarkData: bookmarkData)
        } catch {
            throw TorrentFolderCapabilityError.bookmarkResolutionFailed
        }
        guard !scopedResource.bookmarkDataIsStale else {
            throw TorrentFolderCapabilityError.staleBookmark
        }
        guard scopedResource.startAccessingSecurityScopedResource() else {
            throw TorrentFolderCapabilityError.securityScopeDenied
        }

        do {
            let directory = try TorrentCanonicalDirectory.open(
                url: scopedResource.url,
                maximumPathBytes: limits.maximumCanonicalPathBytes
            )
            let access = TorrentFolderCapabilityAccess(
                scopedResource: scopedResource,
                directoryFileDescriptor: directory.fileDescriptor
            )
            return TorrentFolderCapabilityCandidate(
                canonicalPath: directory.path,
                identity: directory.identity,
                bookmarkByteCount: bookmarkData.count,
                bookmarkFingerprint: TorrentFolderBookmarkFingerprint(bookmarkData),
                access: access
            )
        } catch let error as TorrentFolderCapabilityError {
            scopedResource.stopAccessingSecurityScopedResource()
            throw error
        } catch {
            scopedResource.stopAccessingSecurityScopedResource()
            throw TorrentFolderCapabilityError.directoryOpenFailed
        }
    }

    private static func entry(
        capabilityID: UUID,
        scope: TorrentEngineServiceScope,
        in state: State
    ) -> TorrentFolderCapabilityEntry? {
        guard let entry = state.entriesByID[capabilityID],
              entry.capability.scope == scope else {
            return nil
        }
        return entry
    }

    private func makeCapabilityID(reserving reservedIDs: inout Set<UUID>) -> UUID {
        while true {
            let candidate = UUID()
            if reservedIDs.insert(candidate).inserted {
                return candidate
            }
        }
    }

    private static func rememberAccesses(
        _ accesses: [TorrentFolderCapabilityAccess],
        scope: TorrentEngineServiceScope,
        in state: inout State
    ) {
        var references = state.accessReferencesByScope[scope] ?? []
        var knownAccesses = Set<ObjectIdentifier>()
        references.removeAll { reference in
            guard let access = reference.access else {
                return true
            }
            return !knownAccesses.insert(ObjectIdentifier(access)).inserted
        }
        for access in accesses
        where knownAccesses.insert(ObjectIdentifier(access)).inserted {
            references.append(TorrentWeakFolderCapabilityAccess(access))
        }
        state.accessReferencesByScope[scope] = references
    }

    private static func incrementRegistryRevision(_ state: inout State) {
        state.registryRevision &+= 1
    }

    private func invalidateEveryAccess() {
        let accesses = state.withLock { state in
            let scopes = Set(state.entriesByID.values.map(\.capability.scope))
                .union(state.accessReferencesByScope.keys)
            for scope in scopes {
                scope.invalidate()
            }
            state.entriesByID.removeAll()
            Self.incrementRegistryRevision(&state)
            let references = state.accessReferencesByScope.values.joined()
            state.accessReferencesByScope.removeAll()
            return references.compactMap(\.access)
        }
        for access in uniqueAccesses(accesses) {
            access.invalidate()
        }
    }

    private func uniqueAccesses(
        _ accesses: [TorrentFolderCapabilityAccess]
    ) -> [TorrentFolderCapabilityAccess] {
        var seen = Set<ObjectIdentifier>()
        return accesses.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}

fileprivate struct TorrentFolderCapabilityEntry: Sendable {
    var capability: TorrentFolderCapability
    let bookmarkByteCount: Int
    let bookmarkFingerprint: TorrentFolderBookmarkFingerprint
    let access: TorrentFolderCapabilityAccess
}

private struct TorrentFolderCapabilityCandidate: Sendable {
    let canonicalPath: String
    let identity: TorrentFolderIdentity
    let bookmarkByteCount: Int
    let bookmarkFingerprint: TorrentFolderBookmarkFingerprint
    let access: TorrentFolderCapabilityAccess
}

fileprivate struct TorrentFolderBookmarkFingerprint: Equatable, Sendable {
    private let bytes: [UInt8]

    init(_ bookmarkData: Data) {
        bytes = Array(SHA256.hash(data: bookmarkData))
    }
}

private final class TorrentWeakFolderCapabilityAccess {
    weak var access: TorrentFolderCapabilityAccess?

    init(_ access: TorrentFolderCapabilityAccess) {
        self.access = access
    }
}

fileprivate final class TorrentFolderCapabilityAccess: Sendable {
    private struct State: Sendable {
        var directoryFileDescriptor: FileDescriptor?
        var scopeIsActive = true
    }

    private let scopedResource: any TorrentSecurityScopedResourceAccessing
    private let state: Mutex<State>

    init(
        scopedResource: any TorrentSecurityScopedResourceAccessing,
        directoryFileDescriptor: FileDescriptor
    ) {
        self.scopedResource = scopedResource
        state = Mutex(State(directoryFileDescriptor: directoryFileDescriptor))
    }

    deinit {
        invalidate()
    }

    var isActive: Bool {
        state.withLock { state in
            state.directoryFileDescriptor != nil && state.scopeIsActive
        }
    }

    func fileDescriptor() throws -> Int32 {
        try state.withLock { state in
            guard let directoryFileDescriptor = state.directoryFileDescriptor,
                  state.scopeIsActive else {
                throw TorrentFolderCapabilityError.capabilityInvalidated
            }
            return directoryFileDescriptor.rawValue
        }
    }

    func invalidate() {
        let resources = state.withLock { state in
            let descriptor = state.directoryFileDescriptor
            state.directoryFileDescriptor = nil
            let stopsScope = state.scopeIsActive
            state.scopeIsActive = false
            return (descriptor, stopsScope)
        }
        if let descriptor = resources.0 {
            try? descriptor.close()
        }
        if resources.1 {
            scopedResource.stopAccessingSecurityScopedResource()
        }
    }
}

private struct TorrentCanonicalDirectory {
    let path: String
    let identity: TorrentFolderIdentity
    let fileDescriptor: FileDescriptor

    static func open(
        url: URL,
        maximumPathBytes: Int
    ) throws -> TorrentCanonicalDirectory {
        guard url.isFileURL else {
            throw TorrentFolderCapabilityError.nonFileURL
        }

        let standardizedURL = url.standardizedFileURL
        let canonicalURL = standardizedURL.resolvingSymlinksInPath().standardizedFileURL
        let standardizedPath = standardizedURL.path(percentEncoded: false)
        let canonicalPath = canonicalURL.path(percentEncoded: false)
        guard !canonicalPath.isEmpty,
              (canonicalPath as NSString).isAbsolutePath,
              standardizedPath == canonicalPath else {
            throw TorrentFolderCapabilityError.nonCanonicalDirectory
        }
        guard canonicalPath.utf8.count <= maximumPathBytes else {
            throw TorrentFolderCapabilityError.canonicalPathTooLarge(maximum: maximumPathBytes)
        }

        let descriptor: FileDescriptor
        do {
            descriptor = try FileDescriptor.open(
                FilePath(canonicalPath),
                .readOnly,
                options: [.closeOnExec, .directory, .noFollow]
            )
        } catch {
            throw TorrentFolderCapabilityError.directoryOpenFailed
        }

        do {
            var descriptorMetadata = stat()
            guard unsafe Darwin.fstat(descriptor.rawValue, &descriptorMetadata) == 0,
                  (descriptorMetadata.st_mode & S_IFMT) == S_IFDIR else {
                throw TorrentFolderCapabilityError.directoryOpenFailed
            }

            var pathMetadata = stat()
            let pathStatus = unsafe canonicalPath.withCString { pathPointer in
                unsafe Darwin.lstat(pathPointer, &pathMetadata)
            }
            guard pathStatus == 0,
                  (pathMetadata.st_mode & S_IFMT) == S_IFDIR,
                  pathMetadata.st_dev == descriptorMetadata.st_dev,
                  pathMetadata.st_ino == descriptorMetadata.st_ino else {
                throw TorrentFolderCapabilityError.nonCanonicalDirectory
            }

            return TorrentCanonicalDirectory(
                path: canonicalPath,
                identity: TorrentFolderIdentity(
                    device: UInt64(truncatingIfNeeded: descriptorMetadata.st_dev),
                    inode: UInt64(truncatingIfNeeded: descriptorMetadata.st_ino)
                ),
                fileDescriptor: descriptor
            )
        } catch {
            try? descriptor.close()
            throw error
        }
    }
}
