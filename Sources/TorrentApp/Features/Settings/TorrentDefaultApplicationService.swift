import AppKit
import Foundation

struct TorrentDefaultApplicationContext: Sendable {
    let bundleURL: URL
    let bundleIdentifier: String?
    let runningApplicationBundleURL: URL?
}

struct TorrentDefaultApplicationStatus: Equatable, Sendable {
    let applicationURL: URL
    let isDefaultForTorrentFiles: Bool
    let isDefaultForMagnetLinks: Bool
}

enum TorrentDefaultApplicationService {
    @concurrent
    static func status(
        for context: TorrentDefaultApplicationContext
    ) async throws -> TorrentDefaultApplicationStatus {
        try Task.checkCancellation()
        let applicationURL = resolveApplicationURL(context)
        try Task.checkCancellation()

        let torrentApplicationURL =
            NSWorkspace.shared.urlForApplication(toOpen: bittorrentFileType)
        try Task.checkCancellation()
        let magnetApplicationURL = URL(string: "magnet:?").flatMap {
            NSWorkspace.shared.urlForApplication(toOpen: $0)
        }
        try Task.checkCancellation()

        let applicationPath = normalizedAppPath(applicationURL)
        return TorrentDefaultApplicationStatus(
            applicationURL: applicationURL,
            isDefaultForTorrentFiles:
                torrentApplicationURL.map(normalizedAppPath) == applicationPath,
            isDefaultForMagnetLinks:
                magnetApplicationURL.map(normalizedAppPath) == applicationPath
        )
    }

    @concurrent
    static func setAsTorrentFileDefault(
        applicationURL: URL
    ) async throws {
        try Task.checkCancellation()
        try await NSWorkspace.shared.setDefaultApplication(
            at: applicationURL,
            toOpen: bittorrentFileType
        )
        try Task.checkCancellation()
    }

    private static func resolveApplicationURL(
        _ context: TorrentDefaultApplicationContext
    ) -> URL {
        let bundlePath = normalizedAppPath(context.bundleURL)
        let registeredURLs = context.bundleIdentifier.map {
            NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0)
        } ?? []

        for registeredURL in registeredURLs {
            if normalizedAppPath(registeredURL) == bundlePath {
                return registeredURL
            }
        }
        return context.runningApplicationBundleURL ?? context.bundleURL
    }

    private static func normalizedAppPath(_ url: URL) -> String {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .torrentFilePath
    }
}
