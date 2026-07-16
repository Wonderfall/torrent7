import Foundation

enum TorrentInputLimits {
    static let maxMagnetURIBytes = 64 * 1024
    static let maxTorrentFileBytes = 64 * 1024 * 1024
}

enum TorrentBookmarkKeys {
    static let additionalDownloadFolders = "AdditionalDownloadFolderBookmarks"
}

enum TorrentCompletionKeys {
    static let completedTorrentIDs = "CompletedTorrentIDs"
}

enum TorrentStoreError: LocalizedError {
    case magnetTooLarge
    case torrentFileTooLarge
    case emptyTorrentFile
    case unreadableTorrentFile
    case engineStarting
    case folderAuthorityChangeInProgress
    case tooManyPendingOperations
    case tooManyAuthorizedDownloadFolders
    case downloadFolderAccessDenied
    case downloadFolderNotWritable

    var errorDescription: String? {
        switch self {
        case .magnetTooLarge:
            return "The magnet link is too large."
        case .torrentFileTooLarge:
            return "The torrent file is larger than \(Self.fileSize(TorrentInputLimits.maxTorrentFileBytes))."
        case .emptyTorrentFile:
            return "The torrent file is empty."
        case .unreadableTorrentFile:
            return "The torrent file could not be read."
        case .engineStarting:
            return "The torrent engine is still starting. Try again shortly."
        case .folderAuthorityChangeInProgress:
            return "Download folder authorization is currently in use. Try again shortly."
        case .tooManyPendingOperations:
            return "Too many torrent operations are waiting. Let the current operations finish, then try again."
        case .tooManyAuthorizedDownloadFolders:
            return "Too many download folders are authorized. Remove an unused torrent, then try again."
        case .downloadFolderAccessDenied:
            return "The selected download folder could not be accessed."
        case .downloadFolderNotWritable:
            return "The selected download folder is not writable."
        }
    }

    private static func fileSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
