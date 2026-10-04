package import Foundation

package protocol TorrentFileLocationServicing: Sendable {
    func revealURL(
        for location: TorrentStorageLocation,
        fileIndex: Int32?
    ) async throws -> URL?

    func revealURLs(
        for locations: [TorrentStorageLocation]
    ) async throws -> [URL]

    func revealFolderURL(
        for location: TorrentStorageLocation,
        containingFileIndex: Int32,
        depth: Int
    ) async throws -> URL?
}

package struct TorrentFileLocationService: TorrentFileLocationServicing {
    package init() {}

    @concurrent
    package func revealURL(
        for location: TorrentStorageLocation,
        fileIndex: Int32?
    ) async throws -> URL? {
        try Task.checkCancellation()
        let url = try TorrentStorageDestinationPlanner().revealURL(
            for: location,
            fileIndex: fileIndex
        )
        try Task.checkCancellation()
        return url
    }

    @concurrent
    package func revealFolderURL(
        for location: TorrentStorageLocation,
        containingFileIndex: Int32,
        depth: Int
    ) async throws -> URL? {
        try Task.checkCancellation()
        let url = try TorrentStorageDestinationPlanner().revealFolderURL(
            for: location, containingFileIndex: containingFileIndex, depth: depth
        )
        try Task.checkCancellation()
        return url
    }

    @concurrent
    package func revealURLs(
        for locations: [TorrentStorageLocation]
    ) async throws -> [URL] {
        var urls = [URL]()
        var paths = Set<String>()
        urls.reserveCapacity(locations.count)
        for (index, location) in locations.enumerated() {
            if index.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
            guard let url = try? TorrentStorageDestinationPlanner()
                .revealURL(for: location),
                  paths.insert(url.path(percentEncoded: false)).inserted else {
                continue
            }
            urls.append(url)
        }
        try Task.checkCancellation()
        return urls
    }
}
