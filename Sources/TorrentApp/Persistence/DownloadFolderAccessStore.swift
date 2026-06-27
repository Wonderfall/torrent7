import Foundation

struct PreparedDownloadFolder {
    let path: String
    let defaultURL: URL?
}

protocol DownloadFolderAccessStoring: AnyObject {
    var defaultURL: URL? { get }
    func restoreDefault() throws -> URL?
    func clearDefaultBookmarkAndAccess()
    func validateSelection(_ url: URL) throws
    func isCurrentDefault(_ url: URL?) -> Bool
    @discardableResult
    func setDefault(_ url: URL, activeTorrents: [TorrentItem]) throws -> URL
    func clearDefault(activeTorrents: [TorrentItem])
    func prepareForAdd(_ url: URL, setsDefault: Bool, activeTorrents: [TorrentItem]) throws -> PreparedDownloadFolder
    func prune(activeTorrents: [TorrentItem])
}

final class DownloadFolderAccessStore: DownloadFolderAccessStoring {
    private let defaults: UserDefaults
    private let accessProvider: DownloadFolderAccessProviding
    private var defaultAccess: DownloadFolderAccessing?
    private var additionalAccesses = [String: DownloadFolderAccessing]()

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

    func restoreDefault() throws -> URL? {
        defaultAccess = try accessProvider.restoreDefault(defaults: defaults)
        return defaultAccess?.url
    }

    func clearDefaultBookmarkAndAccess() {
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
        let previousAccess = defaultAccess
        let previousURL = previousAccess?.url
        let newAccess = try accessProvider.createAccess(url: url, savesBookmark: true, defaults: defaults)

        defaultAccess = newAccess
        preserveAdditionalAccessIfNeeded(previousAccess, url: previousURL, activeTorrents: activeTorrents)
        removeAdditionalDownloadFolderBookmark(for: newAccess.url)
        additionalAccesses.removeValue(forKey: Self.accessKey(newAccess.url))
        prune(activeTorrents: activeTorrents)
        return newAccess.url
    }

    func clearDefault(activeTorrents: [TorrentItem]) {
        let previousAccess = defaultAccess
        let previousURL = previousAccess?.url
        accessProvider.clearDefaultBookmark(defaults: defaults)
        defaultAccess = nil

        preserveAdditionalAccessIfNeeded(previousAccess, url: previousURL, activeTorrents: activeTorrents)
        prune(activeTorrents: activeTorrents)
    }

    func prepareForAdd(_ url: URL, setsDefault: Bool, activeTorrents: [TorrentItem]) throws -> PreparedDownloadFolder {
        if isCurrentDefault(url), let defaultURL {
            return PreparedDownloadFolder(path: defaultURL.path, defaultURL: nil)
        }

        if setsDefault {
            let defaultURL = try setDefault(url, activeTorrents: activeTorrents)
            return PreparedDownloadFolder(path: defaultURL.path, defaultURL: defaultURL)
        }

        let access = try accessProvider.createAccess(url: url, savesBookmark: false, defaults: defaults)
        try saveAdditionalDownloadFolderBookmark(for: access)
        additionalAccesses[Self.accessKey(access.url)] = access
        return PreparedDownloadFolder(path: access.url.path, defaultURL: nil)
    }

    func prune(activeTorrents: [TorrentItem]) {
        var activeKeys = Set(activeTorrents.map { torrent in
            Self.accessKey(URL(fileURLWithPath: torrent.savePath, isDirectory: true))
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

    private static func accessKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
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
            Self.accessKey(URL(fileURLWithPath: torrent.savePath, isDirectory: true)) == key
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
        for bookmark in bookmarks.values {
            do {
                let access = try accessProvider.restore(from: bookmark)
                let key = Self.accessKey(access.url)
                accesses[key] = access
                restoredBookmarks[key] = try access.bookmarkData()
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

    private func saveAdditionalDownloadFolderBookmark(for access: DownloadFolderAccessing) throws {
        let key = Self.accessKey(access.url)
        var bookmarks = defaults.dictionary(forKey: TorrentBookmarkKeys.additionalDownloadFolders) as? [String: Data] ?? [:]
        bookmarks[key] = try access.bookmarkData()
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
