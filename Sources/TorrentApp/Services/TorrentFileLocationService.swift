import Foundation
import TorrentEngineModel

protocol TorrentFileLocationServicing: AnyObject {
    func revealURL(for torrent: TorrentItem) -> URL?
    func revealURL(for torrent: TorrentItem, filePath: String) -> URL?
}

final class TorrentFileLocationService: TorrentFileLocationServicing {
    func revealURL(for torrent: TorrentItem) -> URL? {
        let saveURL = URL(filePath: torrent.savePath, directoryHint: .isDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let itemURL = saveURL
            .appending(path: torrent.name)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory = ObjCBool(false)

        if isURLStrictlyContained(itemURL, in: saveURL),
           unsafe FileManager.default.fileExists(atPath: itemURL.torrentFilePath, isDirectory: &isDirectory) {
            return itemURL
        }

        guard unsafe FileManager.default.fileExists(atPath: saveURL.torrentFilePath, isDirectory: &isDirectory) else {
            return nil
        }

        return saveURL
    }

    func revealURL(for torrent: TorrentItem, filePath: String) -> URL? {
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

        var isDirectory = ObjCBool(false)
        if unsafe FileManager.default.fileExists(atPath: itemURL.torrentFilePath, isDirectory: &isDirectory) {
            return itemURL
        }

        var parentURL = itemURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard parentURL.torrentFilePath == saveURL.torrentFilePath || isURLStrictlyContained(parentURL, in: saveURL) else {
            return nil
        }

        while isURLStrictlyContained(parentURL, in: saveURL) {
            if unsafe FileManager.default.fileExists(atPath: parentURL.torrentFilePath, isDirectory: &isDirectory),
               isDirectory.boolValue {
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

        guard unsafe FileManager.default.fileExists(atPath: saveURL.torrentFilePath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
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
}
