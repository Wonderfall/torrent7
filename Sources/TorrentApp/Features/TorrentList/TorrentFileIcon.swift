import AppKit
import SwiftUI
import TorrentEngineModel
import UniformTypeIdentifiers

@MainActor
struct TorrentFileIcon: View, @MainActor Equatable {
    private static let size: CGFloat = 20

    let row: TorrentRowSnapshot
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: row.contentKind == .directory ? "folder" : "doc")
                    .resizable()
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
        .task(id: row) {
            icon = nil
            guard let loadedIcon = try? await FileIconService.shared.icon(for: row),
                  !Task.isCancelled else {
                return
            }
            icon = loadedIcon
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row
    }
}

@MainActor
struct FileItemIcon: View, @MainActor Equatable {
    private static let size: CGFloat = 18

    let path: String
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: "doc")
                    .resizable()
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
        .task(id: path) {
            icon = nil
            guard let loadedIcon = try? await FileIconService.shared.icon(forFilePath: path),
                  !Task.isCancelled else {
                return
            }
            icon = loadedIcon
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path == rhs.path
    }
}

private actor FileIconService {
    static let shared = FileIconService()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    func icon(for row: TorrentRowSnapshot) throws -> NSImage {
        try Task.checkCancellation()
        let source = TorrentFileIconSource.resolve(for: row)
        try Task.checkCancellation()
        return try icon(for: source)
    }

    func icon(forFilePath path: String) throws -> NSImage {
        try Task.checkCancellation()
        let source = FileItemIconSource.resolve(for: path)
        try Task.checkCancellation()
        return try icon(for: source)
    }

    private func icon(for source: TorrentFileIconSource) throws -> NSImage {
        try cachedIcon(for: source.identifier) {
            switch source {
            case .fileExtension(let pathExtension):
                if let contentType = UTType(filenameExtension: pathExtension) {
                    return NSWorkspace.shared.icon(for: contentType)
                }
                return NSWorkspace.shared.icon(for: .data)
            case .genericFile:
                return NSWorkspace.shared.icon(for: .data)
            case .folder:
                return NSWorkspace.shared.icon(for: .folder)
            }
        }
    }

    private func icon(for source: FileItemIconSource) throws -> NSImage {
        try cachedIcon(for: source.identifier) {
            switch source {
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
    }

    private func cachedIcon(
        for identifier: String,
        makeIcon: () -> NSImage
    ) throws -> NSImage {
        let cacheKey = identifier as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        try Task.checkCancellation()
        let icon = makeIcon()
        try Task.checkCancellation()
        cache.setObject(icon, forKey: cacheKey)
        return icon
    }
}

private enum FileItemIconSource: Hashable {
    case existingItem(String)
    case fileExtension(String)
    case folder

    static func resolve(for path: String) -> Self {
        if (path as NSString).isAbsolutePath
            && FileManager().fileExists(atPath: path) {
            return .existingItem(path)
        }

        let pathExtension = (path as NSString).pathExtension
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

enum TorrentFileIconSource: Hashable {
    case fileExtension(String)
    case genericFile
    case folder

    static func resolve(for row: TorrentRowSnapshot) -> Self {
        guard !row.name.isEmpty,
              row.name != ".",
              row.name != "..",
              !row.name.utf8.contains(0),
              !row.name.contains("/"),
              !row.name.contains("\\") else {
            return .folder
        }

        if row.contentKind == .directory {
            return .folder
        }

        let pathExtension = (row.name as NSString).pathExtension
        if !pathExtension.isEmpty {
            return .fileExtension(pathExtension.localizedLowercase)
        }
        if row.contentKind == .singleFile {
            return .genericFile
        } else {
            return .folder
        }
    }

    var identifier: String {
        switch self {
        case .fileExtension(let pathExtension):
            "extension:\(pathExtension)"
        case .genericFile:
            "file"
        case .folder:
            "folder"
        }
    }
}
