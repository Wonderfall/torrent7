import Darwin
import Foundation
import System

package struct TorrentEngineServiceScope: Hashable, Sendable {
    package let engineEpoch: UUID
    package let controllerID: UUID

    package init(engineEpoch: UUID, controllerID: UUID) {
        self.engineEpoch = engineEpoch
        self.controllerID = controllerID
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
        maximumCapabilityCount: 20_000,
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
    @unchecked Sendable
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

package final class TorrentFolderCapabilityPin: @unchecked Sendable {
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
        access.isActive
    }

    package func directoryFileDescriptor() throws -> Int32 {
        try access.fileDescriptor()
    }
}

package final class TorrentFolderCapabilityReplacement: @unchecked Sendable {
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

    package var canonicalPaths: [String] {
        entries.map(\.capability.canonicalPath).sorted()
    }
}

package final class TorrentFolderCapabilityRegistry: @unchecked Sendable {
    package let engineEpoch: UUID

    private let limits: TorrentFolderCapabilityLimits
    private let bookmarkResolver: any TorrentFolderBookmarkResolving
    private let lock = NSLock()
    private var entriesByID = [UUID: TorrentFolderCapabilityEntry]()
    private var accessReferencesByController = [UUID: [TorrentWeakFolderCapabilityAccess]]()
    private var knownControllerIDs = Set<UUID>()
    private var disconnectedControllerIDs = Set<UUID>()
    private var registryRevision: UInt64 = 0

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
    /// The returned object retains every candidate scope and descriptor so a
    /// caller can update the native allowlist before atomically committing the
    /// registry snapshot.
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

        return try lock.withLock {
            try requireConnectedController(scope: scope)
            let retainedEntries = entriesByID.values.filter {
                $0.capability.scope.controllerID != scope.controllerID
            }
            try validateProjectedTotals(
                retainedEntries: retainedEntries,
                candidateBookmarkBytes: candidates.map(\.bookmarkByteCount)
            )

            var replacementEntries = [TorrentFolderCapabilityEntry]()
            replacementEntries.reserveCapacity(candidates.count)
            var reservedIDs = Set(entriesByID.keys)
            for candidate in candidates {
                let capability = TorrentFolderCapability(
                    id: makeCapabilityID(reserving: &reservedIDs),
                    scope: scope,
                    canonicalPath: candidate.canonicalPath,
                    identity: candidate.identity,
                    state: .committed
                )
                replacementEntries.append(TorrentFolderCapabilityEntry(
                    capability: capability,
                    bookmarkByteCount: candidate.bookmarkByteCount,
                    access: candidate.access
                ))
            }
            return TorrentFolderCapabilityReplacement(
                scope: scope,
                expectedRegistryRevision: registryRevision,
                entries: replacementEntries
            )
        }
    }

    /// Publishes a prepared replacement only when the registry has not changed
    /// since preparation. Superseded unpinned scopes are released afterwards.
    package func commit(
        _ replacement: TorrentFolderCapabilityReplacement
    ) throws -> [TorrentFolderCapability] {
        try validate(scope: replacement.scope)
        var displacedEntries = [TorrentFolderCapabilityEntry]()
        let capabilities = try lock.withLock {
            try requireConnectedController(scope: replacement.scope)
            guard replacement.expectedRegistryRevision == registryRevision,
                  replacement.entries.allSatisfy({ $0.access.isActive }) else {
                throw TorrentFolderCapabilityError.staleReplacement
            }

            let retainedEntries = entriesByID.values.filter {
                $0.capability.scope.controllerID != replacement.scope.controllerID
            }
            let retainedIDs = Set(retainedEntries.map(\.capability.id))
            let replacementIDs = replacement.entries.map(\.capability.id)
            guard Set(replacementIDs).count == replacementIDs.count,
                  replacementIDs.allSatisfy({ !retainedIDs.contains($0) }) else {
                throw TorrentFolderCapabilityError.staleReplacement
            }
            displacedEntries = entriesByID.values.filter {
                $0.capability.scope.controllerID == replacement.scope.controllerID
            }
            entriesByID = Dictionary(
                uniqueKeysWithValues: retainedEntries.map { ($0.capability.id, $0) }
            )
            for entry in replacement.entries {
                entriesByID[entry.capability.id] = entry
            }
            rememberAccesses(
                replacement.entries.map(\.access),
                controllerID: replacement.scope.controllerID
            )
            incrementRegistryRevision()
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

        return try lock.withLock {
            try requireConnectedController(scope: scope)
            try validateProjectedTotals(
                retainedEntries: Array(entriesByID.values),
                candidateBookmarkBytes: [candidate.bookmarkByteCount]
            )
            guard !entriesByID.values.contains(where: {
                $0.capability.scope.controllerID == scope.controllerID
                    && ($0.capability.canonicalPath == candidate.canonicalPath
                        || $0.capability.identity == candidate.identity)
            }) else {
                throw TorrentFolderCapabilityError.duplicateDirectory
            }

            var reservedIDs = Set(entriesByID.keys)
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
                access: candidate.access
            )
            entriesByID[capability.id] = entry
            rememberAccesses([entry.access], controllerID: scope.controllerID)
            incrementRegistryRevision()
            return capability
        }
    }

    @discardableResult
    package func commit(
        capabilityID: UUID,
        scope: TorrentEngineServiceScope
    ) throws -> TorrentFolderCapability {
        try validate(scope: scope)
        return try lock.withLock {
            try requireConnectedController(scope: scope)
            guard var entry = entry(capabilityID: capabilityID, scope: scope) else {
                throw TorrentFolderCapabilityError.unknownCapability
            }
            guard entry.access.isActive else {
                entriesByID.removeValue(forKey: capabilityID)
                incrementRegistryRevision()
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
                entriesByID[capabilityID] = entry
                incrementRegistryRevision()
            }
            return entry.capability
        }
    }

    package func pin(
        capabilityID: UUID,
        scope: TorrentEngineServiceScope
    ) throws -> TorrentFolderCapabilityPin {
        try validate(scope: scope)
        return try lock.withLock {
            try requireConnectedController(scope: scope)
            guard let entry = entry(capabilityID: capabilityID, scope: scope) else {
                throw TorrentFolderCapabilityError.unknownCapability
            }
            guard entry.access.isActive else {
                entriesByID.removeValue(forKey: capabilityID)
                incrementRegistryRevision()
                throw TorrentFolderCapabilityError.capabilityInvalidated
            }
            return TorrentFolderCapabilityPin(entry: entry)
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
        let removed: TorrentFolderCapabilityEntry? = try lock.withLock {
            try requireConnectedController(scope: scope)
            guard let entry = entry(capabilityID: capabilityID, scope: scope) else {
                return nil
            }
            let removed = entriesByID.removeValue(forKey: entry.capability.id)
            if removed != nil {
                incrementRegistryRevision()
            }
            return removed
        }
        return removed != nil
    }

    /// A disconnect is stronger than ordinary revocation: it invalidates resources
    /// retained by outstanding pins so no descriptor or security scope crosses sessions.
    package func disconnect(controllerID: UUID) {
        let accesses = lock.withLock {
            knownControllerIDs.insert(controllerID)
            disconnectedControllerIDs.insert(controllerID)
            entriesByID = entriesByID.filter {
                $0.value.capability.scope.controllerID != controllerID
            }
            incrementRegistryRevision()
            let references = accessReferencesByController.removeValue(forKey: controllerID) ?? []
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
        return try lock.withLock {
            try requireConnectedController(scope: scope)
            return entry(capabilityID: capabilityID, scope: scope)?.capability
        }
    }

    package func capabilities(controllerID: UUID) -> [TorrentFolderCapability] {
        lock.withLock {
            entriesByID.values
                .map(\.capability)
                .filter { $0.scope.controllerID == controllerID }
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
        try lock.withLock {
            try requireConnectedController(scope: scope)
            knownControllerIDs.insert(scope.controllerID)
        }
    }

    private func incrementRegistryRevision() {
        registryRevision &+= 1
    }

    private func requireConnectedController(scope: TorrentEngineServiceScope) throws {
        guard !disconnectedControllerIDs.contains(scope.controllerID) else {
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

    private func entry(
        capabilityID: UUID,
        scope: TorrentEngineServiceScope
    ) -> TorrentFolderCapabilityEntry? {
        guard let entry = entriesByID[capabilityID], entry.capability.scope == scope else {
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

    private func rememberAccesses(
        _ accesses: [TorrentFolderCapabilityAccess],
        controllerID: UUID
    ) {
        var references = accessReferencesByController[controllerID] ?? []
        let activeEntryCount = entriesByID.values.lazy.filter {
            $0.capability.scope.controllerID == controllerID
        }.count
        // Register a complete replacement in one pass, while amortizing cleanup
        // of stale weak entries from repeated grant/revoke churn.
        if references.count > activeEntryCount,
           references.count - activeEntryCount > 256 {
            references.removeAll { $0.access == nil }
        }
        references.reserveCapacity(references.count + accesses.count)
        references.append(contentsOf: accesses.map(TorrentWeakFolderCapabilityAccess.init))
        accessReferencesByController[controllerID] = references
    }

    private func invalidateEveryAccess() {
        let accesses = lock.withLock {
            disconnectedControllerIDs.formUnion(knownControllerIDs)
            disconnectedControllerIDs.formUnion(accessReferencesByController.keys)
            entriesByID.removeAll()
            incrementRegistryRevision()
            let references = accessReferencesByController.values.joined()
            accessReferencesByController.removeAll()
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

fileprivate struct TorrentFolderCapabilityEntry {
    var capability: TorrentFolderCapability
    let bookmarkByteCount: Int
    let access: TorrentFolderCapabilityAccess
}

private struct TorrentFolderCapabilityCandidate {
    let canonicalPath: String
    let identity: TorrentFolderIdentity
    let bookmarkByteCount: Int
    let access: TorrentFolderCapabilityAccess
}

private final class TorrentWeakFolderCapabilityAccess: @unchecked Sendable {
    weak var access: TorrentFolderCapabilityAccess?

    init(_ access: TorrentFolderCapabilityAccess) {
        self.access = access
    }
}

fileprivate final class TorrentFolderCapabilityAccess: @unchecked Sendable {
    private let lock = NSLock()
    private let scopedResource: any TorrentSecurityScopedResourceAccessing
    private var directoryFileDescriptor: FileDescriptor?
    private var scopeIsActive = true

    init(
        scopedResource: any TorrentSecurityScopedResourceAccessing,
        directoryFileDescriptor: FileDescriptor
    ) {
        self.scopedResource = scopedResource
        self.directoryFileDescriptor = directoryFileDescriptor
    }

    deinit {
        invalidate()
    }

    var isActive: Bool {
        lock.withLock {
            directoryFileDescriptor != nil && scopeIsActive
        }
    }

    func fileDescriptor() throws -> Int32 {
        try lock.withLock {
            guard let directoryFileDescriptor, scopeIsActive else {
                throw TorrentFolderCapabilityError.capabilityInvalidated
            }
            return directoryFileDescriptor.rawValue
        }
    }

    func invalidate() {
        let resources = lock.withLock {
            let descriptor = directoryFileDescriptor
            directoryFileDescriptor = nil
            let stopsScope = scopeIsActive
            scopeIsActive = false
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
