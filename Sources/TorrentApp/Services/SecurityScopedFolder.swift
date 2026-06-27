import Foundation

protocol DownloadFolderAccessing: AnyObject {
    var url: URL { get }
    func bookmarkData() throws -> Data
}

protocol DownloadFolderAccessProviding {
    func createAccess(url: URL, savesBookmark: Bool, defaults: UserDefaults) throws -> DownloadFolderAccessing
    func restoreDefault(defaults: UserDefaults) throws -> DownloadFolderAccessing?
    func restore(from bookmark: Data) throws -> DownloadFolderAccessing
    func clearDefaultBookmark(defaults: UserDefaults)
}

struct SecurityScopedFolderAccessProvider: DownloadFolderAccessProviding {
    func createAccess(url: URL, savesBookmark: Bool, defaults: UserDefaults) throws -> DownloadFolderAccessing {
        try SecurityScopedFolder(url: url, savesBookmark: savesBookmark, defaults: defaults)
    }

    func restoreDefault(defaults: UserDefaults) throws -> DownloadFolderAccessing? {
        try SecurityScopedFolder.restore(defaults: defaults)
    }

    func restore(from bookmark: Data) throws -> DownloadFolderAccessing {
        try SecurityScopedFolder.restore(from: bookmark)
    }

    func clearDefaultBookmark(defaults: UserDefaults) {
        SecurityScopedFolder.clearBookmark(defaults: defaults)
    }
}

final class SecurityScopedFolder: DownloadFolderAccessing {
    static let defaultsKey = "DownloadFolderBookmark"

    let url: URL
    private let isAccessing: Bool

    init(url: URL, savesBookmark: Bool = true, defaults: UserDefaults = .standard) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        guard accessed else {
            throw TorrentStoreError.downloadFolderAccessDenied
        }

        do {
            try Self.validateWritableDirectory(url)
            if savesBookmark {
                let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(bookmark, forKey: Self.defaultsKey)
            }
        } catch {
            url.stopAccessingSecurityScopedResource()
            throw error
        }

        self.url = url
        isAccessing = accessed
    }

    private init(restoredURL: URL, isAccessing: Bool) {
        url = restoredURL
        self.isAccessing = isAccessing
    }

    deinit {
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }

    static func clearBookmark(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    func bookmarkData() throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func restore(defaults: UserDefaults = .standard) throws -> SecurityScopedFolder? {
        guard let bookmark = defaults.data(forKey: defaultsKey) else {
            return nil
        }

        let access = try restore(from: bookmark)
        if let refreshedBookmark = try? access.bookmarkData() {
            defaults.set(refreshedBookmark, forKey: defaultsKey)
        }
        return access
    }

    static func restore(from bookmark: Data) throws -> SecurityScopedFolder {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        let accessed = url.startAccessingSecurityScopedResource()
        guard accessed else {
            throw TorrentStoreError.downloadFolderAccessDenied
        }

        do {
            try validateWritableDirectory(url)
            _ = stale
        } catch {
            url.stopAccessingSecurityScopedResource()
            throw error
        }

        return SecurityScopedFolder(restoredURL: url, isAccessing: accessed)
    }

    private static func validateWritableDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw TorrentStoreError.downloadFolderAccessDenied
        }

        let probeURL = url.appendingPathComponent(".torrent-app-access-\(UUID().uuidString)", isDirectory: false)
        guard FileManager.default.createFile(atPath: probeURL.path, contents: Data()) else {
            throw TorrentStoreError.downloadFolderNotWritable
        }
        do {
            try FileManager.default.removeItem(at: probeURL)
        } catch {
            throw TorrentStoreError.downloadFolderNotWritable
        }
    }
}
