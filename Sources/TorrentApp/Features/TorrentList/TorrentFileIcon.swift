import AppKit
import SwiftUI
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
private enum TorrentFileIconProvider {
    private static var cache = [CacheKey: NSImage]()

    static func icon(for row: TorrentRowSnapshot) -> NSImage {
        let key = cacheKey(for: row)
        if let cached = cache[key] {
            return cached
        }

        let icon = makeIcon(for: key)
        cache[key] = icon
        return icon
    }

    private static func makeIcon(for key: CacheKey) -> NSImage {
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

    private static func cacheKey(for row: TorrentRowSnapshot) -> CacheKey {
        let saveURL = URL(fileURLWithPath: row.savePath, isDirectory: true)
            .standardizedFileURL
        let itemURL = saveURL.appendingPathComponent(row.name)
            .standardizedFileURL

        if FileManager.default.fileExists(atPath: itemURL.path) {
            return .existingItem(itemURL.path)
        }

        let pathExtension = itemURL.pathExtension
        guard !pathExtension.isEmpty else {
            return .folder
        }
        return .fileExtension(pathExtension.localizedLowercase)
    }

    private enum CacheKey: Hashable {
        case existingItem(String)
        case fileExtension(String)
        case folder
    }
}

@MainActor
private enum FileItemIconProvider {
    private static var cache = [CacheKey: NSImage]()

    static func icon(for path: String) -> NSImage {
        let key = cacheKey(for: path)
        if let cached = cache[key] {
            return cached
        }

        let icon = makeIcon(for: key)
        cache[key] = icon
        return icon
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
    }
}
