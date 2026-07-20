import Foundation
import TorrentEngineModel

struct PreparedDownloadFolder {
    let path: String
    let defaultURL: URL?
    let lease: DownloadFolderAccessLease
    let bookmarkData: Data?

    init(access: DownloadFolderAccessing, defaultURL: URL?, bookmarkData: Data?) {
        path = access.url.torrentFilePath
        self.defaultURL = defaultURL
        lease = DownloadFolderAccessLease(access: access)
        self.bookmarkData = bookmarkData
    }

    func engineAuthorization() throws -> TorrentFolderAuthorization {
        TorrentFolderAuthorization(
            path: path,
            bookmarkData: try lease.access.delegationBookmarkData()
        )
    }
}

final class DownloadFolderAccessLease {
    fileprivate let access: DownloadFolderAccessing

    init(access: DownloadFolderAccessing) {
        self.access = access
    }
}

struct DownloadFolderCapabilitySnapshot {
    static let maximumPathCount = TorrentEngineLimits.maximumAuthorizedSavePathCount

    let revision: UInt64
    let paths: [String]
    // These accesses are lifetime tokens only; the snapshot never invokes them.
    private let accesses: [DownloadFolderAccessing]

    init(
        revision: UInt64 = 0,
        defaultAccess: DownloadFolderAccessing?,
        additionalAccesses: [DownloadFolderAccessing]
    ) {
        var paths = [String]()
        var accesses = [DownloadFolderAccessing]()
        var seenPaths = Set<String>()

        func append(_ access: DownloadFolderAccessing) {
            guard paths.count < Self.maximumPathCount,
                  seenPaths.insert(access.url.torrentFilePath).inserted else {
                return
            }
            paths.append(access.url.torrentFilePath)
            accesses.append(access)
        }

        if let defaultAccess {
            append(defaultAccess)
        }
        for access in additionalAccesses.sorted(by: { $0.url.torrentFilePath < $1.url.torrentFilePath }) {
            append(access)
        }

        self.revision = revision
        self.paths = paths
        self.accesses = accesses
    }

    func engineAuthorizations() throws -> [TorrentFolderAuthorization] {
        try zip(paths, accesses).map { path, access in
            TorrentFolderAuthorization(
                path: path,
                bookmarkData: try access.delegationBookmarkData()
            )
        }
    }
}

protocol DownloadFolderAccessStoring: AnyObject {
    var defaultURL: URL? { get }
    var capabilityRevision: UInt64 { get }
    var capabilitySnapshot: DownloadFolderCapabilitySnapshot { get }
    func restoreDefault() throws -> URL?
    func clearDefaultBookmarkAndAccess()
    func validateSelection(_ url: URL) throws
    func isCurrentDefault(_ url: URL?) -> Bool
    @discardableResult
    func setDefault(_ url: URL, activeTorrents: [TorrentItem]) throws -> URL
    func clearDefault(activeTorrents: [TorrentItem])
    func prepareForAdd(_ url: URL, setsDefault: Bool, activeTorrents: [TorrentItem]) throws -> PreparedDownloadFolder
    @discardableResult
    func commitPreparedForAdd(_ preparedFolder: PreparedDownloadFolder, activeTorrents: [TorrentItem]) -> URL?
    func lease(forSavePath path: String) throws -> DownloadFolderAccessLease
    func prune(activeTorrents: [TorrentItem])
}

final class DownloadFolderAccessStore: DownloadFolderAccessStoring {
    private let defaults: UserDefaults
    private let accessProvider: DownloadFolderAccessProviding
    private var defaultAccess: DownloadFolderAccessing?
    private var additionalAccesses = [String: DownloadFolderAccessing]()
    private(set) var capabilityRevision: UInt64 = 0

    init(
        defaults: UserDefaults = .standard,
        accessProvider: DownloadFolderAccessProviding = SecurityScopedFolderAccessProvider()
    ) {
        self.defaults = defaults
        self.accessProvider = accessProvider
        additionalAccesses = Self.restoreAdditionalDownloadFoldersFromDefaults(defaults: defaults, accessProvider: accessProvider)
    }

    var defaultURL: URL? {
        defaultAccess?.url
    }

    var capabilitySnapshot: DownloadFolderCapabilitySnapshot {
        DownloadFolderCapabilitySnapshot(
            revision: capabilityRevision,
            defaultAccess: defaultAccess,
            additionalAccesses: Array(additionalAccesses.values)
        )
    }

    func restoreDefault() throws -> URL? {
        let previousIdentity = capabilityIdentity
        defer { advanceCapabilityRevision(ifChangedFrom: previousIdentity) }
        defaultAccess = try accessProvider.restoreDefault(defaults: defaults)
        if let defaultAccess {
            removeAdditionalDownloadFolderBookmark(for: defaultAccess.url)
            additionalAccesses.removeValue(forKey: Self.accessKey(defaultAccess.url))
        }
        enforceAdditionalAccessLimit()
        return defaultAccess?.url
    }

    func clearDefaultBookmarkAndAccess() {
        let previousIdentity = capabilityIdentity
        defer { advanceCapabilityRevision(ifChangedFrom: previousIdentity) }
        accessProvider.clearDefaultBookmark(defaults: defaults)
        defaultAccess = nil
    }

    func validateSelection(_ url: URL) throws {
        _ = try accessProvider.createAccess(url: url, savesBookmark: false, defaults: defaults)
    }

    func isCurrentDefault(_ url: URL?) -> Bool {
        guard let url, let defaultURL else {
            return false
        }

        return Self.accessKey(url) == Self.accessKey(defaultURL)
    }

    @discardableResult
    func setDefault(_ url: URL, activeTorrents: [TorrentItem]) throws -> URL {
        let previousIdentity = capabilityIdentity
        defer { advanceCapabilityRevision(ifChangedFrom: previousIdentity) }
        let previousAccess = defaultAccess
        let previousURL = previousAccess?.url
        let newAccess = try accessProvider.createAccess(url: url, savesBookmark: false, defaults: defaults)
        try validateProjectedDefault(newAccess, activeTorrents: activeTorrents)
        let bookmarkData = try newAccess.bookmarkData()

        defaults.set(bookmarkData, forKey: SecurityScopedFolder.defaultsKey)
        defaultAccess = newAccess
        preserveAdditionalAccessIfNeeded(previousAccess, url: previousURL, activeTorrents: activeTorrents)
        removeAdditionalDownloadFolderBookmark(for: newAccess.url)
        additionalAccesses.removeValue(forKey: Self.accessKey(newAccess.url))
        prune(activeTorrents: activeTorrents)
        return newAccess.url
    }

    func clearDefault(activeTorrents: [TorrentItem]) {
        let previousIdentity = capabilityIdentity
        defer { advanceCapabilityRevision(ifChangedFrom: previousIdentity) }
        let previousAccess = defaultAccess
        let previousURL = previousAccess?.url
        accessProvider.clearDefaultBookmark(defaults: defaults)
        defaultAccess = nil

        preserveAdditionalAccessIfNeeded(previousAccess, url: previousURL, activeTorrents: activeTorrents)
        prune(activeTorrents: activeTorrents)
        enforceAdditionalAccessLimit()
    }

    func prepareForAdd(_ url: URL, setsDefault: Bool, activeTorrents: [TorrentItem]) throws -> PreparedDownloadFolder {
        if isCurrentDefault(url), let defaultAccess {
            return PreparedDownloadFolder(access: defaultAccess, defaultURL: nil, bookmarkData: nil)
        }

        let access = try accessProvider.createAccess(url: url, savesBookmark: false, defaults: defaults)
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
    ) -> URL? {
        let previousIdentity = capabilityIdentity
        defer { advanceCapabilityRevision(ifChangedFrom: previousIdentity) }
        guard let bookmarkData = preparedFolder.bookmarkData else {
            return nil
        }

        if preparedFolder.defaultURL != nil {
            let previousAccess = defaultAccess
            let previousURL = previousAccess?.url
            defaults.set(bookmarkData, forKey: SecurityScopedFolder.defaultsKey)
            defaultAccess = preparedFolder.lease.access

            preserveAdditionalAccessIfNeeded(previousAccess, url: previousURL, activeTorrents: activeTorrents)
            removeAdditionalDownloadFolderBookmark(for: preparedFolder.lease.access.url)
            additionalAccesses.removeValue(forKey: Self.accessKey(preparedFolder.lease.access.url))
            prune(activeTorrents: activeTorrents)
            return preparedFolder.lease.access.url
        }

        saveAdditionalDownloadFolderBookmark(bookmarkData, for: preparedFolder.lease.access.url)
        additionalAccesses[Self.accessKey(preparedFolder.lease.access.url)] = preparedFolder.lease.access
        return nil
    }

    func lease(forSavePath path: String) throws -> DownloadFolderAccessLease {
        guard !path.isEmpty, (path as NSString).isAbsolutePath else {
            throw TorrentStoreError.downloadFolderAccessDenied
        }

        let key = Self.accessKey(URL(filePath: path, directoryHint: .isDirectory))
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

    func prune(activeTorrents: [TorrentItem]) {
        let previousIdentity = capabilityIdentity
        defer { advanceCapabilityRevision(ifChangedFrom: previousIdentity) }
        var activeKeys = Set(activeTorrents.map { torrent in
            Self.accessKey(URL(filePath: torrent.savePath, directoryHint: .isDirectory))
        })
        if let defaultURL {
            activeKeys.remove(Self.accessKey(defaultURL))
        }

        let staleKeys = Set(additionalAccesses.keys).subtracting(activeKeys)
        for key in staleKeys {
            additionalAccesses.removeValue(forKey: key)
        }
        pruneAdditionalDownloadFolderBookmarks(retaining: activeKeys)
    }

    private struct CapabilityIdentity: Equatable {
        let defaultAccess: ObjectIdentifier?
        let additionalAccesses: [String: ObjectIdentifier]
    }

    private var capabilityIdentity: CapabilityIdentity {
        CapabilityIdentity(
            defaultAccess: defaultAccess.map(ObjectIdentifier.init),
            additionalAccesses: additionalAccesses.mapValues(ObjectIdentifier.init)
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
            Self.accessKey(URL(filePath: torrent.savePath, directoryHint: .isDirectory))
        })

        if let defaultAccess {
            let previousDefaultKey = Self.accessKey(defaultAccess.url)
            if previousDefaultKey != projectedDefaultKey, activeKeys.contains(previousDefaultKey) {
                projectedAdditionalAccesses[previousDefaultKey] = defaultAccess
            }
        }

        projectedAdditionalAccesses.removeValue(forKey: projectedDefaultKey)
        projectedAdditionalAccesses = projectedAdditionalAccesses.filter { key, _ in
            activeKeys.contains(key)
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
        var paths = Set(additionalAccesses.values.map { $0.url.torrentFilePath })
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
            Self.accessKey(URL(filePath: torrent.savePath, directoryHint: .isDirectory)) == key
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
        guard let bookmarks = defaults.dictionary(forKey: TorrentBookmarkKeys.additionalDownloadFolders) as? [String: Data] else {
            return [:]
        }

        var accesses = [String: DownloadFolderAccessing]()
        var restoredBookmarks = [String: Data]()
        for key in bookmarks.keys.sorted() {
            guard accesses.count < DownloadFolderCapabilitySnapshot.maximumPathCount else {
                break
            }
            guard let bookmark = bookmarks[key] else {
                continue
            }
            do {
                let access = try accessProvider.restore(from: bookmark)
                let key = Self.accessKey(access.url)
                let refreshedBookmark = try access.bookmarkData()
                guard accesses[key] == nil else {
                    continue
                }
                accesses[key] = access
                restoredBookmarks[key] = refreshedBookmark
            } catch {
                continue
            }
        }

        if restoredBookmarks.isEmpty {
            defaults.removeObject(forKey: TorrentBookmarkKeys.additionalDownloadFolders)
        } else {
            defaults.set(restoredBookmarks, forKey: TorrentBookmarkKeys.additionalDownloadFolders)
        }
        return accesses
    }

    private func enforceAdditionalAccessLimit() {
        let maximumAdditionalAccessCount = DownloadFolderCapabilitySnapshot.maximumPathCount - (defaultAccess == nil ? 0 : 1)
        let retainedKeys = Set(additionalAccesses
            .sorted { lhs, rhs in
                let lhsPath = lhs.value.url.torrentFilePath
                let rhsPath = rhs.value.url.torrentFilePath
                return lhsPath == rhsPath ? lhs.key < rhs.key : lhsPath < rhsPath
            }
            .prefix(maximumAdditionalAccessCount)
            .map(\.key))
        additionalAccesses = additionalAccesses.filter { key, _ in
            retainedKeys.contains(key)
        }
        pruneAdditionalDownloadFolderBookmarks(retaining: retainedKeys)
    }

    private func saveAdditionalDownloadFolderBookmark(for access: DownloadFolderAccessing) throws {
        try saveAdditionalDownloadFolderBookmark(access.bookmarkData(), for: access.url)
    }

    private func saveAdditionalDownloadFolderBookmark(_ bookmarkData: Data, for url: URL) {
        let key = Self.accessKey(url)
        var bookmarks = defaults.dictionary(forKey: TorrentBookmarkKeys.additionalDownloadFolders) as? [String: Data] ?? [:]
        bookmarks[key] = bookmarkData
        defaults.set(bookmarks, forKey: TorrentBookmarkKeys.additionalDownloadFolders)
    }

    private func removeAdditionalDownloadFolderBookmark(for url: URL) {
        let key = Self.accessKey(url)
        var bookmarks = defaults.dictionary(forKey: TorrentBookmarkKeys.additionalDownloadFolders) as? [String: Data] ?? [:]
        bookmarks.removeValue(forKey: key)
        if bookmarks.isEmpty {
            defaults.removeObject(forKey: TorrentBookmarkKeys.additionalDownloadFolders)
        } else {
            defaults.set(bookmarks, forKey: TorrentBookmarkKeys.additionalDownloadFolders)
        }
    }

    private func pruneAdditionalDownloadFolderBookmarks(retaining activeKeys: Set<String>) {
        var bookmarks = defaults.dictionary(forKey: TorrentBookmarkKeys.additionalDownloadFolders) as? [String: Data] ?? [:]
        bookmarks = bookmarks.filter { key, _ in
            activeKeys.contains(key)
        }

        if bookmarks.isEmpty {
            defaults.removeObject(forKey: TorrentBookmarkKeys.additionalDownloadFolders)
        } else {
            defaults.set(bookmarks, forKey: TorrentBookmarkKeys.additionalDownloadFolders)
        }
    }
}
