import Foundation
import TorrentEngineModel

protocol TorrentFileLocationServicing: Sendable {
    func revealURL(for torrent: TorrentItem) async throws -> URL?
    func revealURL(for torrent: TorrentItem, filePath: String) async throws -> URL?
    func revealURLs(for torrents: [TorrentItem]) async throws -> [URL]
}

struct TorrentFileLocationService: TorrentFileLocationServicing {
    @concurrent
    func revealURL(for torrent: TorrentItem) async throws -> URL? {
        try Task.checkCancellation()
        let url = resolveURL(for: torrent)
        try Task.checkCancellation()
        return url
    }

    @concurrent
    func revealURL(for torrent: TorrentItem, filePath: String) async throws -> URL? {
        try Task.checkCancellation()
        let url = resolveURL(for: torrent, filePath: filePath)
        try Task.checkCancellation()
        return url
    }

    @concurrent
    func revealURLs(for torrents: [TorrentItem]) async throws -> [URL] {
        var urls = [URL]()
        var paths = Set<String>()
        urls.reserveCapacity(torrents.count)
        for (index, torrent) in torrents.enumerated() {
            if index.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
            guard let url = resolveURL(for: torrent),
                  paths.insert(url.torrentFilePath).inserted else {
                continue
            }
            urls.append(url)
        }
        try Task.checkCancellation()
        return urls
    }

    private func resolveURL(for torrent: TorrentItem) -> URL? {
        let saveURL = URL(filePath: torrent.savePath, directoryHint: .isDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let itemURL = saveURL
            .appending(path: torrent.name)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let fileManager = FileManager()

        if isURLStrictlyContained(itemURL, in: saveURL),
           fileManager.fileExists(atPath: itemURL.torrentFilePath) {
            return itemURL
        }

        guard fileManager.fileExists(
            atPath: saveURL.torrentFilePath
        ) else {
            return nil
        }

        return saveURL
    }

    private func resolveURL(for torrent: TorrentItem, filePath: String) -> URL? {
        let saveURL = URL(filePath: torrent.savePath, directoryHint: .isDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let itemURL = saveURL
            .appending(path: filePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard isURLStrictlyContained(itemURL, in: saveURL) else {
            return nil
        }

        let fileManager = FileManager()
        if fileManager.fileExists(atPath: itemURL.torrentFilePath) {
            return itemURL
        }

        var parentURL = itemURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard parentURL.torrentFilePath == saveURL.torrentFilePath || isURLStrictlyContained(parentURL, in: saveURL) else {
            return nil
        }

        while isURLStrictlyContained(parentURL, in: saveURL) {
            if directoryExists(at: parentURL) {
                return parentURL
            }

            let nextParentURL = parentURL.deletingLastPathComponent()
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard nextParentURL.torrentFilePath != parentURL.torrentFilePath else {
                break
            }
            parentURL = nextParentURL
        }

        guard directoryExists(at: saveURL) else {
            return nil
        }

        return saveURL
    }

    private func isURLStrictlyContained(_ url: URL, in directory: URL) -> Bool {
        let path = url.torrentFilePath
        let directoryPath = directory.torrentFilePath
        let directoryPrefix = directoryPath.hasSuffix("/") ? directoryPath : "\(directoryPath)/"
        return path != directoryPath && path.hasPrefix(directoryPrefix)
    }

    private func directoryExists(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey]
        ) else {
            return false
        }
        return values.isDirectory == true
    }
}
