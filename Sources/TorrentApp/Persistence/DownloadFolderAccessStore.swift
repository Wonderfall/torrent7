import Foundation
import TorrentEngineModel

struct PreparedDownloadFolder: Sendable {
    let path: String
    let defaultURL: URL?
    let lease: DownloadFolderAccessLease
    let bookmarkData: Data?
    private let authorization: Result<TorrentFolderAuthorization, any Error>

    init(access: DownloadFolderAccessing, defaultURL: URL?, bookmarkData: Data?) {
        path = access.url.torrentFilePath
        self.defaultURL = defaultURL
        lease = DownloadFolderAccessLease(access: access)
        self.bookmarkData = bookmarkData
        authorization = Result {
            TorrentFolderAuthorization(
                path: access.url.torrentFilePath,
                bookmarkData: try access.delegationBookmarkData()
            )
        }
    }

    func engineAuthorization() throws -> TorrentFolderAuthorization {
        try authorization.get()
    }
}

final class DownloadFolderAccessLease: Sendable {
    fileprivate let access: DownloadFolderAccessing

    init(access: DownloadFolderAccessing) {
        self.access = access
    }
}

struct DownloadFolderCapabilitySnapshot: Sendable {
    static let maximumPathCount = TorrentEngineLimits.maximumAuthorizedSavePathCount

    let revision: UInt64
    let paths: [String]
    private let authorizations: Result<[TorrentFolderAuthorization], any Error>
    // Security-scoped access remains live for the lifetime of this snapshot.
    private let leases: [DownloadFolderAccessLease]

    init(
        revision: UInt64 = 0,
        defaultAccess: DownloadFolderAccessing?,
        additionalAccesses: [DownloadFolderAccessing]
    ) {
        var paths = [String]()
        var preparedAuthorizations = [TorrentFolderAuthorization]()
        var leases = [DownloadFolderAccessLease]()
        var seenPaths = Set<String>()
        var preparationError: (any Error)?

        func append(_ access: DownloadFolderAccessing) {
            let path = access.url.torrentFilePath
            guard paths.count < Self.maximumPathCount,
                  seenPaths.insert(path).inserted else {
                return
            }
            paths.append(path)
            leases.append(DownloadFolderAccessLease(access: access))
            guard preparationError == nil else {
                return
            }
            do {
                preparedAuthorizations.append(TorrentFolderAuthorization(
                    path: path,
                    bookmarkData: try access.delegationBookmarkData()
                ))
            } catch {
                preparationError = error
            }
        }

        if let defaultAccess {
            append(defaultAccess)
        }
        for access in additionalAccesses.sorted(by: {
            $0.url.torrentFilePath < $1.url.torrentFilePath
        }) {
            append(access)
        }

        self.revision = revision
        self.paths = paths
        authorizations = preparationError.map(Result.failure)
            ?? .success(preparedAuthorizations)
        self.leases = leases
    }

    func engineAuthorizations() throws -> [TorrentFolderAuthorization] {
        try authorizations.get()
    }
}

struct DownloadFolderBootstrapResult: Sendable {
    let defaultURL: URL?
    let discardedInvalidDefault: Bool
}

struct DownloadFolderDefaultUpdate: Sendable {
    let url: URL
    let didChange: Bool
}

struct DownloadFolderPruneSnapshot: Sendable {
    let capabilityRevision: UInt64
    let candidateAccessKeys: Set<String>
}

struct DownloadFolderPrunePlan: Sendable {
    let capabilityRevision: UInt64
    let retainedAccessKeys: Set<String>

    @concurrent
    static func prepare(
        snapshot: DownloadFolderPruneSnapshot,
        activeTorrents: [TorrentItem]
    ) async throws -> DownloadFolderPrunePlan {
        try Task.checkCancellation()
        var unmatchedAccessKeys = snapshot.candidateAccessKeys
        var retainedAccessKeys = Set<String>()
        retainedAccessKeys.reserveCapacity(unmatchedAccessKeys.count)

        for (offset, torrent) in activeTorrents.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            guard !unmatchedAccessKeys.isEmpty else {
                break
            }
            let key = accessKey(
                URL(filePath: torrent.savePath, directoryHint: .isDirectory)
            )
            if unmatchedAccessKeys.remove(key) != nil {
                retainedAccessKeys.insert(key)
            }
        }

        try Task.checkCancellation()
        return DownloadFolderPrunePlan(
            capabilityRevision: snapshot.capabilityRevision,
            retainedAccessKeys: retainedAccessKeys
        )
    }

    private static func accessKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().torrentFilePath
    }
}

protocol DownloadFolderAccessStoring: AnyObject, Sendable {
    func bootstrap() async -> DownloadFolderBootstrapResult
    func currentDefaultURL() async -> URL?
    func currentCapabilityRevision() async -> UInt64
    func makeCapabilitySnapshot() async -> DownloadFolderCapabilitySnapshot
    func makePruneSnapshot() async -> DownloadFolderPruneSnapshot
    func clearDefaultBookmarkAndAccess() async
    func validateSelection(_ url: URL) async throws
    @discardableResult
    func setDefault(
        _ url: URL,
        activeTorrents: [TorrentItem]
    ) async throws -> DownloadFolderDefaultUpdate
    func clearDefault(activeTorrents: [TorrentItem]) async
    func prepareForAdd(
        _ url: URL,
        setsDefault: Bool,
        activeTorrents: [TorrentItem]
    ) async throws -> PreparedDownloadFolder
    @discardableResult
    func commitPreparedForAdd(
        _ preparedFolder: PreparedDownloadFolder,
        activeTorrents: [TorrentItem]
    ) async -> URL?
    func lease(forSavePath path: String) async throws -> DownloadFolderAccessLease
    @discardableResult
    func applyPrunePlan(
        _ plan: DownloadFolderPrunePlan,
        activeTorrents: [TorrentItem]
    ) async -> Bool
}

actor DownloadFolderAccessStore: DownloadFolderAccessStoring {
    private let defaultsDomain: TorrentDefaultsDomain
    private var cachedDefaults: UserDefaults?
    private let accessProvider: DownloadFolderAccessProviding
    private var defaultAccess: DownloadFolderAccessing?
    private var additionalAccesses = [String: DownloadFolderAccessing]()
    private var didRestoreAdditionalAccesses = false
    private var didRestoreDefaultAccess = false
    private var discardedInvalidDefault = false
    private var capabilityRevision: UInt64 = 0

    init(
        domain: TorrentDefaultsDomain = .standard,
        accessProvider: DownloadFolderAccessProviding = SecurityScopedFolderAccessProvider()
    ) {
        defaultsDomain = domain
        self.accessProvider = accessProvider
    }

    private var defaults: UserDefaults {
        if let cachedDefaults {
            return cachedDefaults
        }
        let defaults = defaultsDomain.makeUserDefaults()
        cachedDefaults = defaults
        return defaults
    }

    func bootstrap() async -> DownloadFolderBootstrapResult {
        restoreAdditionalAccessesIfNeeded()
        guard !didRestoreDefaultAccess else {
            return DownloadFolderBootstrapResult(
                defaultURL: defaultAccess?.url,
                discardedInvalidDefault: discardedInvalidDefault
            )
        }

        didRestoreDefaultAccess = true
        do {
            defaultAccess = try accessProvider.restoreDefault(defaults: defaults)
            if let defaultAccess {
                removeAdditionalDownloadFolderBookmark(for: defaultAccess.url)
                additionalAccesses.removeValue(forKey: Self.accessKey(defaultAccess.url))
            }
            enforceAdditionalAccessLimit()
        } catch {
            accessProvider.clearDefaultBookmark(defaults: defaults)
            defaultAccess = nil
            discardedInvalidDefault = true
        }

        return DownloadFolderBootstrapResult(
            defaultURL: defaultAccess?.url,
            discardedInvalidDefault: discardedInvalidDefault
        )
    }

    func currentDefaultURL() async -> URL? {
        defaultAccess?.url
    }

    func currentCapabilityRevision() async -> UInt64 {
        restoreAdditionalAccessesIfNeeded()
        return capabilityRevision
    }

    func makeCapabilitySnapshot() async -> DownloadFolderCapabilitySnapshot {
        restoreAdditionalAccessesIfNeeded()
        return DownloadFolderCapabilitySnapshot(
            revision: capabilityRevision,
            defaultAccess: defaultAccess,
            additionalAccesses: Array(additionalAccesses.values)
        )
    }

    func makePruneSnapshot() async -> DownloadFolderPruneSnapshot {
        restoreAdditionalAccessesIfNeeded()
        return DownloadFolderPruneSnapshot(
            capabilityRevision: capabilityRevision,
            candidateAccessKeys: Set(additionalAccesses.keys)
        )
    }

    func clearDefaultBookmarkAndAccess() async {
        let previousIdentity = capabilityIdentity
        defer { advanceCapabilityRevision(ifChangedFrom: previousIdentity) }
        didRestoreDefaultAccess = true
        accessProvider.clearDefaultBookmark(defaults: defaults)
        defaultAccess = nil
    }

    func validateSelection(_ url: URL) async throws {
        _ = try accessProvider.createAccess(
            url: url,
            savesBookmark: false,
            defaults: defaults
        )
    }

    @discardableResult
    func setDefault(
        _ url: URL,
        activeTorrents: [TorrentItem]
    ) async throws -> DownloadFolderDefaultUpdate {
        restoreAdditionalAccessesIfNeeded()
        if let defaultAccess,
           Self.accessKey(url) == Self.accessKey(defaultAccess.url) {
            return DownloadFolderDefaultUpdate(
                url: defaultAccess.url,
                didChange: false
            )
        }

        let previousIdentity = capabilityIdentity
        defer { advanceCapabilityRevision(ifChangedFrom: previousIdentity) }
        let previousAccess = defaultAccess
        let previousURL = previousAccess?.url
        let newAccess = try accessProvider.createAccess(
            url: url,
            savesBookmark: false,
            defaults: defaults
        )
        try validateProjectedDefault(newAccess, activeTorrents: activeTorrents)
        let bookmarkData = try newAccess.bookmarkData()

        defaults.set(bookmarkData, forKey: SecurityScopedFolder.defaultsKey)
        didRestoreDefaultAccess = true
        defaultAccess = newAccess
        preserveAdditionalAccessIfNeeded(
            previousAccess,
            url: previousURL,
            activeTorrents: activeTorrents
        )
        removeAdditionalDownloadFolderBookmark(for: newAccess.url)
        additionalAccesses.removeValue(forKey: Self.accessKey(newAccess.url))
        pruneSynchronously(activeTorrents: activeTorrents)
        return DownloadFolderDefaultUpdate(
            url: newAccess.url,
            didChange: true
        )
    }

    func clearDefault(activeTorrents: [TorrentItem]) async {
        restoreAdditionalAccessesIfNeeded()
        let previousIdentity = capabilityIdentity
        defer { advanceCapabilityRevision(ifChangedFrom: previousIdentity) }
        let previousAccess = defaultAccess
        let previousURL = previousAccess?.url
        accessProvider.clearDefaultBookmark(defaults: defaults)
        didRestoreDefaultAccess = true
        defaultAccess = nil

        preserveAdditionalAccessIfNeeded(
            previousAccess,
            url: previousURL,
            activeTorrents: activeTorrents
        )
        pruneSynchronously(activeTorrents: activeTorrents)
        enforceAdditionalAccessLimit()
    }

    func prepareForAdd(
        _ url: URL,
        setsDefault: Bool,
        activeTorrents: [TorrentItem]
    ) async throws -> PreparedDownloadFolder {
        restoreAdditionalAccessesIfNeeded()
        if let defaultAccess,
           Self.accessKey(url) == Self.accessKey(defaultAccess.url) {
            return PreparedDownloadFolder(
                access: defaultAccess,
                defaultURL: nil,
                bookmarkData: nil
            )
        }

        let access = try accessProvider.createAccess(
            url: url,
            savesBookmark: false,
            defaults: defaults
        )
        if setsDefault {
            try validateProjectedDefault(access, activeTorrents: activeTorrents)
        } else {
            var projectedAdditionalAccesses = additionalAccesses
            projectedAdditionalAccesses[Self.accessKey(access.url)] = access
            try validateCapabilityCount(
                defaultAccess: defaultAccess,
                additionalAccesses: projectedAdditionalAccesses
            )
        }
        let bookmarkData = try access.bookmarkData()
        return PreparedDownloadFolder(
            access: access,
            defaultURL: setsDefault ? access.url : nil,
            bookmarkData: bookmarkData
        )
    }

    @discardableResult
    func commitPreparedForAdd(
        _ preparedFolder: PreparedDownloadFolder,
        activeTorrents: [TorrentItem]
    ) async -> URL? {
        restoreAdditionalAccessesIfNeeded()
        let previousIdentity = capabilityIdentity
        defer { advanceCapabilityRevision(ifChangedFrom: previousIdentity) }
        guard let bookmarkData = preparedFolder.bookmarkData else {
            return nil
        }

        if preparedFolder.defaultURL != nil {
            let previousAccess = defaultAccess
            let previousURL = previousAccess?.url
            defaults.set(bookmarkData, forKey: SecurityScopedFolder.defaultsKey)
            didRestoreDefaultAccess = true
            defaultAccess = preparedFolder.lease.access

            preserveAdditionalAccessIfNeeded(
                previousAccess,
                url: previousURL,
                activeTorrents: activeTorrents
            )
            removeAdditionalDownloadFolderBookmark(
                for: preparedFolder.lease.access.url
            )
            additionalAccesses.removeValue(
                forKey: Self.accessKey(preparedFolder.lease.access.url)
            )
            pruneSynchronously(activeTorrents: activeTorrents)
            return preparedFolder.lease.access.url
        }

        saveAdditionalDownloadFolderBookmark(
            bookmarkData,
            for: preparedFolder.lease.access.url
        )
        additionalAccesses[Self.accessKey(preparedFolder.lease.access.url)] =
            preparedFolder.lease.access
        return nil
    }

    func lease(forSavePath path: String) async throws -> DownloadFolderAccessLease {
        restoreAdditionalAccessesIfNeeded()
        guard !path.isEmpty, (path as NSString).isAbsolutePath else {
            throw TorrentStoreError.downloadFolderAccessDenied
        }

        let key = Self.accessKey(
            URL(filePath: path, directoryHint: .isDirectory)
        )
        let access: DownloadFolderAccessing?
        if let defaultAccess, Self.accessKey(defaultAccess.url) == key {
            access = defaultAccess
        } else {
            access = additionalAccesses[key]
        }

        guard let access else {
            throw TorrentStoreError.downloadFolderAccessDenied
        }
        return DownloadFolderAccessLease(access: access)
    }

    @discardableResult
    func applyPrunePlan(
        _ plan: DownloadFolderPrunePlan,
        activeTorrents _: [TorrentItem]
    ) async -> Bool {
        restoreAdditionalAccessesIfNeeded()
        guard plan.capabilityRevision == capabilityRevision else {
            return false
        }
        prune(retainingActiveKeys: plan.retainedAccessKeys)
        return true
    }

    private func restoreAdditionalAccessesIfNeeded() {
        guard !didRestoreAdditionalAccesses else {
            return
        }
        didRestoreAdditionalAccesses = true
        additionalAccesses = Self.restoreAdditionalDownloadFoldersFromDefaults(
            defaults: defaults,
            accessProvider: accessProvider
        )
    }

    private func pruneSynchronously(activeTorrents: [TorrentItem]) {
        var activeKeys = Set(activeTorrents.map { torrent in
            Self.accessKey(
                URL(filePath: torrent.savePath, directoryHint: .isDirectory)
            )
        })
        if let defaultAccess {
            activeKeys.remove(Self.accessKey(defaultAccess.url))
        }
        prune(retainingActiveKeys: activeKeys)
    }

    private func prune(retainingActiveKeys activeKeys: Set<String>) {
        let previousIdentity = capabilityIdentity
        defer { advanceCapabilityRevision(ifChangedFrom: previousIdentity) }
        let staleKeys = Set(additionalAccesses.keys).subtracting(activeKeys)
        guard !staleKeys.isEmpty else {
            return
        }
        for key in staleKeys {
            additionalAccesses.removeValue(forKey: key)
        }
        removeAdditionalDownloadFolderBookmarks(for: staleKeys)
    }

    private struct CapabilityIdentity: Equatable {
        let defaultAccess: ObjectIdentifier?
        let additionalAccesses: [String: ObjectIdentifier]
    }

    private var capabilityIdentity: CapabilityIdentity {
        CapabilityIdentity(
            defaultAccess: defaultAccess.map(ObjectIdentifier.init),
            additionalAccesses: additionalAccesses.mapValues(
                ObjectIdentifier.init
            )
        )
    }

    private func advanceCapabilityRevision(
        ifChangedFrom previousIdentity: CapabilityIdentity
    ) {
        guard capabilityIdentity != previousIdentity else {
            return
        }
        precondition(
            capabilityRevision != UInt64.max,
            "Download-folder capability revision exhausted"
        )
        capabilityRevision += 1
    }

    private static func accessKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().torrentFilePath
    }

    private func validateProjectedDefault(
        _ projectedDefaultAccess: DownloadFolderAccessing,
        activeTorrents: [TorrentItem]
    ) throws {
        var projectedAdditionalAccesses = additionalAccesses
        let projectedDefaultKey = Self.accessKey(projectedDefaultAccess.url)
        let activeKeys = Set(activeTorrents.map { torrent in
            Self.accessKey(
                URL(filePath: torrent.savePath, directoryHint: .isDirectory)
            )
        })

        if let defaultAccess {
            let previousDefaultKey = Self.accessKey(defaultAccess.url)
            if previousDefaultKey != projectedDefaultKey,
               activeKeys.contains(previousDefaultKey) {
                projectedAdditionalAccesses[previousDefaultKey] = defaultAccess
            }
        }

        projectedAdditionalAccesses.removeValue(forKey: projectedDefaultKey)
        projectedAdditionalAccesses = projectedAdditionalAccesses.filter {
            key, _ in activeKeys.contains(key)
        }
        try validateCapabilityCount(
            defaultAccess: projectedDefaultAccess,
            additionalAccesses: projectedAdditionalAccesses
        )
    }

    private func validateCapabilityCount(
        defaultAccess: DownloadFolderAccessing?,
        additionalAccesses: [String: DownloadFolderAccessing]
    ) throws {
        var paths = Set(additionalAccesses.values.map(\.url.torrentFilePath))
        if let defaultAccess {
            paths.insert(defaultAccess.url.torrentFilePath)
        }
        guard paths.count <= DownloadFolderCapabilitySnapshot.maximumPathCount else {
            throw TorrentStoreError.tooManyAuthorizedDownloadFolders
        }
    }

    private func preserveAdditionalAccessIfNeeded(
        _ access: DownloadFolderAccessing?,
        url: URL?,
        activeTorrents: [TorrentItem]
    ) {
        guard let access, let url else {
            return
        }

        let key = Self.accessKey(url)
        let isUsedByActiveTorrent = activeTorrents.contains { torrent in
            Self.accessKey(
                URL(filePath: torrent.savePath, directoryHint: .isDirectory)
            ) == key
        }
        guard isUsedByActiveTorrent else {
            return
        }

        additionalAccesses[key] = access
        try? saveAdditionalDownloadFolderBookmark(for: access)
    }

    private static func restoreAdditionalDownloadFoldersFromDefaults(
        defaults: UserDefaults,
        accessProvider: DownloadFolderAccessProviding
    ) -> [String: DownloadFolderAccessing] {
        guard let bookmarks = defaults.dictionary(
            forKey: TorrentBookmarkKeys.additionalDownloadFolders
        ) as? [String: Data] else {
            return [:]
        }

        var accesses = [String: DownloadFolderAccessing]()
        var restoredBookmarks = [String: Data]()
        for key in bookmarks.keys.sorted() {
            guard accesses.count
                    < DownloadFolderCapabilitySnapshot.maximumPathCount else {
                break
            }
            guard let bookmark = bookmarks[key] else {
                continue
            }
            do {
                let access = try accessProvider.restore(from: bookmark)
                let accessKey = Self.accessKey(access.url)
                let refreshedBookmark = try access.bookmarkData()
                guard accesses[accessKey] == nil else {
                    continue
                }
                accesses[accessKey] = access
                restoredBookmarks[accessKey] = refreshedBookmark
            } catch {
                continue
            }
        }

        if restoredBookmarks.isEmpty {
            defaults.removeObject(
                forKey: TorrentBookmarkKeys.additionalDownloadFolders
            )
        } else {
            defaults.set(
                restoredBookmarks,
                forKey: TorrentBookmarkKeys.additionalDownloadFolders
            )
        }
        return accesses
    }

    private func enforceAdditionalAccessLimit() {
        let maximumAdditionalAccessCount =
            DownloadFolderCapabilitySnapshot.maximumPathCount
            - (defaultAccess == nil ? 0 : 1)
        let retainedKeys = Set(additionalAccesses
            .sorted { lhs, rhs in
                let lhsPath = lhs.value.url.torrentFilePath
                let rhsPath = rhs.value.url.torrentFilePath
                return lhsPath == rhsPath
                    ? lhs.key < rhs.key
                    : lhsPath < rhsPath
            }
            .prefix(maximumAdditionalAccessCount)
            .map(\.key))
        additionalAccesses = additionalAccesses.filter {
            key, _ in retainedKeys.contains(key)
        }
        pruneAdditionalDownloadFolderBookmarks(retaining: retainedKeys)
    }

    private func saveAdditionalDownloadFolderBookmark(
        for access: DownloadFolderAccessing
    ) throws {
        try saveAdditionalDownloadFolderBookmark(
            access.bookmarkData(),
            for: access.url
        )
    }

    private func saveAdditionalDownloadFolderBookmark(
        _ bookmarkData: Data,
        for url: URL
    ) {
        let key = Self.accessKey(url)
        var bookmarks = defaults.dictionary(
            forKey: TorrentBookmarkKeys.additionalDownloadFolders
        ) as? [String: Data] ?? [:]
        bookmarks[key] = bookmarkData
        defaults.set(
            bookmarks,
            forKey: TorrentBookmarkKeys.additionalDownloadFolders
        )
    }

    private func removeAdditionalDownloadFolderBookmark(for url: URL) {
        let key = Self.accessKey(url)
        var bookmarks = defaults.dictionary(
            forKey: TorrentBookmarkKeys.additionalDownloadFolders
        ) as? [String: Data] ?? [:]
        bookmarks.removeValue(forKey: key)
        saveAdditionalDownloadFolderBookmarks(bookmarks)
    }

    private func pruneAdditionalDownloadFolderBookmarks(
        retaining activeKeys: Set<String>
    ) {
        var bookmarks = defaults.dictionary(
            forKey: TorrentBookmarkKeys.additionalDownloadFolders
        ) as? [String: Data] ?? [:]
        bookmarks = bookmarks.filter { key, _ in activeKeys.contains(key) }
        saveAdditionalDownloadFolderBookmarks(bookmarks)
    }

    private func removeAdditionalDownloadFolderBookmarks(
        for staleKeys: Set<String>
    ) {
        var bookmarks = defaults.dictionary(
            forKey: TorrentBookmarkKeys.additionalDownloadFolders
        ) as? [String: Data] ?? [:]
        for key in staleKeys {
            bookmarks.removeValue(forKey: key)
        }
        saveAdditionalDownloadFolderBookmarks(bookmarks)
    }

    private func saveAdditionalDownloadFolderBookmarks(
        _ bookmarks: [String: Data]
    ) {
        if bookmarks.isEmpty {
            defaults.removeObject(
                forKey: TorrentBookmarkKeys.additionalDownloadFolders
            )
        } else {
            defaults.set(
                bookmarks,
                forKey: TorrentBookmarkKeys.additionalDownloadFolders
            )
        }
    }
}
