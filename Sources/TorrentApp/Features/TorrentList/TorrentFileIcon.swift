import AppKit
import SwiftUI
import TorrentEngineModel
import UniformTypeIdentifiers

struct TorrentFileIcon: View, Equatable {
    private static let size: CGFloat = 20

    let row: TorrentRowSnapshot

    var body: some View {
        Image(nsImage: TorrentFileIconProvider.icon(for: row))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: Self.size, height: Self.size)
            .accessibilityHidden(true)
    }
}

struct FileItemIcon: View, Equatable {
    private static let size: CGFloat = 18

    let path: String

    var body: some View {
        Image(nsImage: FileItemIconProvider.icon(for: path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: Self.size, height: Self.size)
            .accessibilityHidden(true)
    }
}

@MainActor
private enum FileIconCache {
    private static let storage: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func icon(for key: String, makeIcon: () -> NSImage) -> NSImage {
        let cacheKey = key as NSString
        if let cached = storage.object(forKey: cacheKey) {
            return cached
        }

        let icon = makeIcon()
        storage.setObject(icon, forKey: cacheKey)
        return icon
    }
}

@MainActor
private enum TorrentFileIconProvider {
    static func icon(for row: TorrentRowSnapshot) -> NSImage {
        let key = TorrentFileIconSource.resolve(for: row)
        return FileIconCache.icon(for: key.identifier) {
            makeIcon(for: key)
        }
    }

    private static func makeIcon(for key: TorrentFileIconSource) -> NSImage {
        if case .existingItem(let path) = key {
            return NSWorkspace.shared.icon(forFile: path)
        }

        if case .fileExtension(let pathExtension) = key {
            if let contentType = UTType(filenameExtension: pathExtension) {
                return NSWorkspace.shared.icon(for: contentType)
            }
            return NSWorkspace.shared.icon(for: .data)
        }

        return NSWorkspace.shared.icon(for: .folder)
    }
}

enum TorrentFileIconSource: Hashable {
    case existingItem(String)
    case fileExtension(String)
    case folder

    static func resolve(for row: TorrentRowSnapshot) -> Self {
        let saveURL = URL(filePath: row.savePath, directoryHint: .isDirectory)
            .standardizedFileURL
        let itemURL = saveURL.appending(path: row.name)
            .standardizedFileURL

        let savePath = saveURL.path(percentEncoded: false)
        let itemPath = itemURL.path(percentEncoded: false)
        let containedPrefix = savePath.hasSuffix("/") ? savePath : "\(savePath)/"
        guard itemPath.hasPrefix(containedPrefix), itemPath != savePath else {
            return .folder
        }

        if FileManager.default.fileExists(atPath: itemPath) {
            return .existingItem(itemPath)
        }

        let pathExtension = itemURL.pathExtension
        guard !pathExtension.isEmpty else {
            return .folder
        }
        return .fileExtension(pathExtension.localizedLowercase)
    }

    var identifier: String {
        switch self {
        case .existingItem(let path):
            "item:\(path)"
        case .fileExtension(let pathExtension):
            "extension:\(pathExtension)"
        case .folder:
            "folder"
        }
    }
}

@MainActor
private enum FileItemIconProvider {
    static func icon(for path: String) -> NSImage {
        let key = cacheKey(for: path)
        return FileIconCache.icon(for: key.identifier) {
            makeIcon(for: key)
        }
    }

    private static func makeIcon(for key: CacheKey) -> NSImage {
        switch key {
        case .existingItem(let path):
            return NSWorkspace.shared.icon(forFile: path)
        case .fileExtension(let pathExtension):
            if let contentType = UTType(filenameExtension: pathExtension) {
                return NSWorkspace.shared.icon(for: contentType)
            }
            return NSWorkspace.shared.icon(for: .data)
        case .folder:
            return NSWorkspace.shared.icon(for: .folder)
        }
    }

    private static func cacheKey(for path: String) -> CacheKey {
        if (path as NSString).isAbsolutePath && FileManager.default.fileExists(atPath: path) {
            return .existingItem(path)
        }

        let pathExtension = (path as NSString).pathExtension
        guard !pathExtension.isEmpty else {
            return .folder
        }
        return .fileExtension(pathExtension.localizedLowercase)
    }

    private enum CacheKey: Hashable {
        case existingItem(String)
        case fileExtension(String)
        case folder

        var identifier: String {
            switch self {
            case .existingItem(let path):
                "item:\(path)"
            case .fileExtension(let pathExtension):
                "extension:\(pathExtension)"
            case .folder:
                "folder"
            }
        }
    }
}
