import Foundation

protocol TorrentFileLocationServicing: AnyObject {
    func revealURL(for torrent: TorrentItem) -> URL?
    func revealURL(for torrent: TorrentItem, filePath: String) -> URL?
}

final class TorrentFileLocationService: TorrentFileLocationServicing {
    func revealURL(for torrent: TorrentItem) -> URL? {
        let saveURL = URL(fileURLWithPath: torrent.savePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let itemURL = saveURL
            .appendingPathComponent(torrent.name)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory = ObjCBool(false)

        if isURLStrictlyContained(itemURL, in: saveURL),
           unsafe FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDirectory) {
            return itemURL
        }

        guard unsafe FileManager.default.fileExists(atPath: saveURL.path, isDirectory: &isDirectory) else {
            return nil
        }

        return saveURL
    }

    func revealURL(for torrent: TorrentItem, filePath: String) -> URL? {
        let saveURL = URL(fileURLWithPath: torrent.savePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let itemURL = saveURL
            .appendingPathComponent(filePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard isURLStrictlyContained(itemURL, in: saveURL) else {
            return nil
        }

        var isDirectory = ObjCBool(false)
        if unsafe FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDirectory) {
            return itemURL
        }

        var parentURL = itemURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard parentURL.path == saveURL.path || isURLStrictlyContained(parentURL, in: saveURL) else {
            return nil
        }

        while isURLStrictlyContained(parentURL, in: saveURL) {
            if unsafe FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return parentURL
            }

            let nextParentURL = parentURL.deletingLastPathComponent()
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard nextParentURL.path != parentURL.path else {
                break
            }
            parentURL = nextParentURL
        }

        guard unsafe FileManager.default.fileExists(atPath: saveURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        return saveURL
    }

    private func isURLStrictlyContained(_ url: URL, in directory: URL) -> Bool {
        let path = url.path
        let directoryPath = directory.path
        let directoryPrefix = directoryPath.hasSuffix("/") ? directoryPath : "\(directoryPath)/"
        return path != directoryPath && path.hasPrefix(directoryPrefix)
    }
}
