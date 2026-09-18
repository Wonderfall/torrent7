package import Foundation
import TorrentEngineModel

package struct PreparedDownloadFolder: Sendable {
    package let path: String
    package let defaultURL: URL?
    package let lease: DownloadFolderAccessLease
    package let bookmarkData: Data?

    package init(access: any DownloadFolderAccessing, defaultURL: URL?, bookmarkData: Data?) {
        path = access.url.torrentFilePath
        self.defaultURL = defaultURL
        lease = DownloadFolderAccessLease(access: access)
        self.bookmarkData = bookmarkData
    }
}

package final class DownloadFolderAccessLease: Sendable {
    fileprivate let access: any DownloadFolderAccessing

    package var url: URL {
        access.url
    }

    package init(access: any DownloadFolderAccessing) {
        self.access = access
    }
}

package struct DownloadFolderAccessSnapshot: Sendable {
    package static let maximumPathCount = 32

    package let revision: UInt64
    package let paths: [String]
    // Security-scoped access remains live for the lifetime of this snapshot.
    package let leases: [DownloadFolderAccessLease]

    package init(
        revision: UInt64 = 0,
        defaultAccess: (any DownloadFolderAccessing)?,
        additionalAccesses: [any DownloadFolderAccessing]
    ) {
        var paths = [String]()
        var leases = [DownloadFolderAccessLease]()
        var seenPaths = Set<String>()

        func append(_ access: any DownloadFolderAccessing) {
            let path = access.url.torrentFilePath
            guard paths.count < Self.maximumPathCount,
                  seenPaths.insert(path).inserted else {
                return
            }
            paths.append(path)
            leases.append(DownloadFolderAccessLease(access: access))
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
        self.leases = leases
    }
}

package struct DownloadFolderBootstrapResult: Sendable {
    package let defaultURL: URL?
    package let discardedInvalidDefault: Bool

    package init(defaultURL: URL?, discardedInvalidDefault: Bool) {
        self.defaultURL = defaultURL
        self.discardedInvalidDefault = discardedInvalidDefault
    }
}

package struct DownloadFolderDefaultUpdate: Sendable {
    package let url: URL
    package let didChange: Bool

    package init(url: URL, didChange: Bool) {
        self.url = url
        self.didChange = didChange
    }
}

package protocol DownloadFolderAccessStoring: Actor {
    func bootstrap() async -> DownloadFolderBootstrapResult
    func currentDefaultURL() async -> URL?
    func makeAccessSnapshot() async -> DownloadFolderAccessSnapshot
    func clearDefaultBookmarkAndAccess() async
    func validateSelection(_ url: URL) async throws
    @discardableResult
    func setDefault(
        _ url: URL,
        retaining paths: Set<String>
    ) async throws -> DownloadFolderDefaultUpdate
    func clearDefault(retaining paths: Set<String>) async
    func prepareForAdd(
        _ url: URL,
        setsDefault: Bool,
        retaining paths: Set<String>
    ) async throws -> PreparedDownloadFolder
    @discardableResult
    func commitPreparedForAdd(
        _ preparedFolder: PreparedDownloadFolder,
        retaining paths: Set<String>
    ) async -> URL?
    func lease(forSavePath path: String) async throws -> DownloadFolderAccessLease
    @discardableResult
    func prune(
        retaining paths: Set<String>,
        ifRevisionMatches revision: UInt64
    ) async -> Bool
}

package actor DownloadFolderAccessStore: DownloadFolderAccessStoring {
    private let defaultsDomain: TorrentDefaultsDomain
    private var cachedDefaults: UserDefaults?
    private let accessProvider: any DownloadFolderAccessProviding
    private var defaultAccess: (any DownloadFolderAccessing)?
    private var additionalAccesses = [String: any DownloadFolderAccessing]()
    private var didRestoreAdditionalAccesses = false
    private var didRestoreDefaultAccess = false
    private var discardedInvalidDefault = false
    private var accessRevision: UInt64 = 0

    package init(
        domain: TorrentDefaultsDomain = .standard,
        accessProvider: any DownloadFolderAccessProviding = SecurityScopedFolderAccessProvider()
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

    package func bootstrap() async -> DownloadFolderBootstrapResult {
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

    package func currentDefaultURL() async -> URL? {
        defaultAccess?.url
    }

    package func makeAccessSnapshot() async -> DownloadFolderAccessSnapshot {
        restoreAdditionalAccessesIfNeeded()
        return DownloadFolderAccessSnapshot(
            revision: accessRevision,
            defaultAccess: defaultAccess,
            additionalAccesses: Array(additionalAccesses.values)
        )
    }

    package func clearDefaultBookmarkAndAccess() async {
        let previousIdentity = accessIdentity
        defer { advanceAccessRevision(ifChangedFrom: previousIdentity) }
        didRestoreDefaultAccess = true
        accessProvider.clearDefaultBookmark(defaults: defaults)
        defaultAccess = nil
    }

    package func validateSelection(_ url: URL) async throws {
        _ = try accessProvider.createAccess(
            url: url,
            savesBookmark: false,
            defaults: defaults
        )
    }

    @discardableResult
    package func setDefault(
        _ url: URL,
        retaining paths: Set<String>
    ) async throws -> DownloadFolderDefaultUpdate {
        restoreAdditionalAccessesIfNeeded()
        let previousIdentity = accessIdentity
        defer { advanceAccessRevision(ifChangedFrom: previousIdentity) }
        pruneAdditionalAccesses(retaining: paths)
        if let defaultAccess,
           Self.accessKey(url) == Self.accessKey(defaultAccess.url) {
            return DownloadFolderDefaultUpdate(
                url: defaultAccess.url,
                didChange: false
            )
        }

        let previousAccess = defaultAccess
        let previousURL = previousAccess?.url
        let newAccess = try accessProvider.createAccess(
            url: url,
            savesBookmark: false,
            defaults: defaults
        )
        try validateProjectedDefault(newAccess, retaining: paths)
        let bookmarkData = try newAccess.bookmarkData()

        defaults.set(bookmarkData, forKey: SecurityScopedFolder.defaultsKey)
        didRestoreDefaultAccess = true
        defaultAccess = newAccess
        preserveAdditionalAccessIfNeeded(
            previousAccess,
            url: previousURL,
            retaining: paths
        )
        removeAdditionalDownloadFolderBookmark(for: newAccess.url)
        additionalAccesses.removeValue(forKey: Self.accessKey(newAccess.url))
        pruneAdditionalAccesses(retaining: paths)
        return DownloadFolderDefaultUpdate(
            url: newAccess.url,
            didChange: true
        )
    }

    package func clearDefault(retaining paths: Set<String>) async {
        restoreAdditionalAccessesIfNeeded()
        let previousIdentity = accessIdentity
        defer { advanceAccessRevision(ifChangedFrom: previousIdentity) }
        let previousAccess = defaultAccess
        let previousURL = previousAccess?.url
        accessProvider.clearDefaultBookmark(defaults: defaults)
        didRestoreDefaultAccess = true
        defaultAccess = nil

        preserveAdditionalAccessIfNeeded(
            previousAccess,
            url: previousURL,
            retaining: paths
        )
        pruneAdditionalAccesses(retaining: paths)
        enforceAdditionalAccessLimit()
    }

    package func prepareForAdd(
        _ url: URL,
        setsDefault: Bool,
        retaining paths: Set<String>
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
            try validateProjectedDefault(access, retaining: paths)
        } else {
            let retainedKeys = Self.accessKeys(for: paths)
            var projectedAdditionalAccesses = additionalAccesses.filter {
                retainedKeys.contains($0.key)
            }
            projectedAdditionalAccesses[Self.accessKey(access.url)] = access
            try validateAccessCount(
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
    package func commitPreparedForAdd(
        _ preparedFolder: PreparedDownloadFolder,
        retaining paths: Set<String>
    ) async -> URL? {
        restoreAdditionalAccessesIfNeeded()
        let previousIdentity = accessIdentity
        defer { advanceAccessRevision(ifChangedFrom: previousIdentity) }
        pruneAdditionalAccesses(retaining: paths)
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
                retaining: paths
            )
            removeAdditionalDownloadFolderBookmark(
                for: preparedFolder.lease.access.url
            )
            additionalAccesses.removeValue(
                forKey: Self.accessKey(preparedFolder.lease.access.url)
            )
            pruneAdditionalAccesses(retaining: paths)
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

    package func lease(forSavePath path: String) async throws -> DownloadFolderAccessLease {
        restoreAdditionalAccessesIfNeeded()
        guard !path.isEmpty, (path as NSString).isAbsolutePath else {
            throw TorrentStoreError.downloadFolderAccessDenied
        }

        let key = Self.accessKey(
            URL(filePath: path, directoryHint: .isDirectory)
        )
        let access: (any DownloadFolderAccessing)?
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

    package func prune(
        retaining paths: Set<String>,
        ifRevisionMatches revision: UInt64
    ) async -> Bool {
        restoreAdditionalAccessesIfNeeded()
        guard revision == accessRevision else {
            return false
        }
        let previousIdentity = accessIdentity
        defer { advanceAccessRevision(ifChangedFrom: previousIdentity) }
        pruneAdditionalAccesses(retaining: paths)
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

    private func pruneAdditionalAccesses(retaining paths: Set<String>) {
        let activeKeys = Self.accessKeys(for: paths)
        let staleKeys = Set(additionalAccesses.keys).subtracting(activeKeys)
        guard !staleKeys.isEmpty else {
            return
        }
        for key in staleKeys {
            additionalAccesses.removeValue(forKey: key)
        }
        removeAdditionalDownloadFolderBookmarks(for: staleKeys)
    }

    private struct AccessIdentity: Equatable {
        let defaultAccess: ObjectIdentifier?
        let additionalAccesses: [String: ObjectIdentifier]
    }

    private var accessIdentity: AccessIdentity {
        AccessIdentity(
            defaultAccess: defaultAccess.map(ObjectIdentifier.init),
            additionalAccesses: additionalAccesses.mapValues(
                ObjectIdentifier.init
            )
        )
    }

    private func advanceAccessRevision(
        ifChangedFrom previousIdentity: AccessIdentity
    ) {
        guard accessIdentity != previousIdentity else {
            return
        }
        precondition(accessRevision != UInt64.max)
        accessRevision += 1
    }

    private static func accessKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().torrentFilePath
    }

    private func validateProjectedDefault(
        _ projectedDefaultAccess: any DownloadFolderAccessing,
        retaining paths: Set<String>
    ) throws {
        let projectedDefaultKey = Self.accessKey(projectedDefaultAccess.url)
        let retainedKeys = Self.accessKeys(for: paths)
        var projectedAdditionalAccesses = additionalAccesses.filter {
            retainedKeys.contains($0.key)
        }

        if let defaultAccess {
            let previousDefaultKey = Self.accessKey(defaultAccess.url)
            if previousDefaultKey != projectedDefaultKey,
               retainedKeys.contains(previousDefaultKey) {
                projectedAdditionalAccesses[previousDefaultKey] = defaultAccess
            }
        }

        projectedAdditionalAccesses.removeValue(forKey: projectedDefaultKey)
        try validateAccessCount(
            defaultAccess: projectedDefaultAccess,
            additionalAccesses: projectedAdditionalAccesses
        )
    }

    private func validateAccessCount(
        defaultAccess: (any DownloadFolderAccessing)?,
        additionalAccesses: [String: any DownloadFolderAccessing]
    ) throws {
        var paths = Set(additionalAccesses.values.map(\.url.torrentFilePath))
        if let defaultAccess {
            paths.insert(defaultAccess.url.torrentFilePath)
        }
        guard paths.count <= DownloadFolderAccessSnapshot.maximumPathCount else {
            throw TorrentStoreError.tooManyDownloadFolders
        }
    }

    private func preserveAdditionalAccessIfNeeded(
        _ access: (any DownloadFolderAccessing)?,
        url: URL?,
        retaining paths: Set<String>
    ) {
        guard let access, let url else {
            return
        }

        let key = Self.accessKey(url)
        guard Self.accessKeys(for: paths).contains(key) else {
            return
        }

        additionalAccesses[key] = access
        try? saveAdditionalDownloadFolderBookmark(for: access)
    }

    private static func accessKeys(for paths: Set<String>) -> Set<String> {
        Set(paths.map {
            accessKey(URL(filePath: $0, directoryHint: .isDirectory))
        })
    }

    private static func restoreAdditionalDownloadFoldersFromDefaults(
        defaults: UserDefaults,
        accessProvider: any DownloadFolderAccessProviding
    ) -> [String: any DownloadFolderAccessing] {
        guard let bookmarks = defaults.dictionary(
            forKey: TorrentBookmarkKeys.additionalDownloadFolders
        ) as? [String: Data] else {
            return [:]
        }

        var accesses = [String: any DownloadFolderAccessing]()
        var restoredBookmarks = [String: Data]()
        for key in bookmarks.keys.sorted() {
            guard accesses.count
                    < DownloadFolderAccessSnapshot.maximumPathCount else {
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
            DownloadFolderAccessSnapshot.maximumPathCount
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
        for access: any DownloadFolderAccessing
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
