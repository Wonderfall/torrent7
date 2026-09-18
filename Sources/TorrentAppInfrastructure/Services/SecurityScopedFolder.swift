package import Foundation
import TorrentEngineModel

package protocol DownloadFolderAccessing: AnyObject, Sendable {
    var url: URL { get }
    func bookmarkData() throws -> Data
}

package protocol DownloadFolderAccessProviding: Sendable {
    func createAccess(url: URL, savesBookmark: Bool, defaults: UserDefaults) throws -> any DownloadFolderAccessing
    func restoreDefault(defaults: UserDefaults) throws -> (any DownloadFolderAccessing)?
    func restore(from bookmark: Data) throws -> any DownloadFolderAccessing
    func clearDefaultBookmark(defaults: UserDefaults)
}

package struct SecurityScopedFolderAccessProvider: DownloadFolderAccessProviding {
    package func createAccess(url: URL, savesBookmark: Bool, defaults: UserDefaults) throws -> any DownloadFolderAccessing {
        try SecurityScopedFolder(url: url, savesBookmark: savesBookmark, defaults: defaults)
    }

    package func restoreDefault(defaults: UserDefaults) throws -> (any DownloadFolderAccessing)? {
        try SecurityScopedFolder.restore(defaults: defaults)
    }

    package func restore(from bookmark: Data) throws -> any DownloadFolderAccessing {
        try SecurityScopedFolder.restore(from: bookmark)
    }

    package func clearDefaultBookmark(defaults: UserDefaults) {
        SecurityScopedFolder.clearBookmark(defaults: defaults)
    }
}

package final class SecurityScopedFolder: DownloadFolderAccessing {
    package static let defaultsKey = "DownloadFolderBookmark"

    package let url: URL
    private let isAccessing: Bool

    package init(url: URL, savesBookmark: Bool = true, defaults: UserDefaults = .standard) throws {
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

    package static func clearBookmark(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    package func bookmarkData() throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    package static func restore(defaults: UserDefaults = .standard) throws -> SecurityScopedFolder? {
        guard let bookmark = defaults.data(forKey: defaultsKey) else {
            return nil
        }

        let access = try restore(from: bookmark)
        if let refreshedBookmark = try? access.bookmarkData() {
            defaults.set(refreshedBookmark, forKey: defaultsKey)
        }
        return access
    }

    package static func restore(from bookmark: Data) throws -> SecurityScopedFolder {
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

        let fileManager = FileManager()
        let probeURL = url.appending(
            path: ".torrent-app-access-\(UUID().uuidString)",
            directoryHint: .notDirectory
        )
        guard fileManager.createFile(
            atPath: probeURL.torrentFilePath,
            contents: Data()
        ) else {
            throw TorrentStoreError.downloadFolderNotWritable
        }
        do {
            try fileManager.removeItem(at: probeURL)
        } catch {
            throw TorrentStoreError.downloadFolderNotWritable
        }
    }
}
