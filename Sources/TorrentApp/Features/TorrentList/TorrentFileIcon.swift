import AppKit
import Observation
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

struct FileItemIcon: View {
    private static let size: CGFloat = 18

    let source: TorrentFileIconSource
    let images: TorrentFileIconImages

    var body: some View {
        Group {
            if let icon = images.icons[source] {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: source == .folder ? "folder" : "doc")
                    .resizable()
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }
}

@Observable
final class TorrentFileIconImages {
    // Each cell reads this property in its own body. Passing a dictionary value
    // through TableColumn's cached content closure can leave cells with the
    // initial placeholder until an unrelated selection change redraws them.
    var icons = [TorrentFileIconSource: NSImage]()
}

actor FileIconService {
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

    /// Loaded by the outline, so disappearing table cells cannot cancel or
    /// discard their icons. Only filename types are consulted, never disk paths.
    func icons(for filenameExtensions: Set<String>) throws -> [TorrentFileIconSource: NSImage] {
        var icons = [TorrentFileIconSource: NSImage]()
        icons[.folder] = try icon(for: .folder)
        for filenameExtension in filenameExtensions {
            try Task.checkCancellation()
            let source: TorrentFileIconSource = filenameExtension.isEmpty
                ? .genericFile : .fileExtension(filenameExtension)
            icons[source] = try icon(for: source)
        }
        try Task.checkCancellation()
        return icons
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

nonisolated enum TorrentFileIconSource: Hashable {
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
