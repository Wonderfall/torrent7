import Foundation

@MainActor
final class TorrentCommandActions {
    var addTorrentFileHandler: () -> Void = {}
    var addMagnetLinkHandler: () -> Void = {}
    var chooseDownloadFolderHandler: () -> Void = {}
    var showSelectedTorrentInfoHandler: () -> Void = {}
    var showSelectedTorrentOptionsHandler: () -> Void = {}
    var revealSelectedTorrentsInFinderHandler: () -> Void = {}
    var pauseSelectedTorrentsHandler: () -> Void = {}
    var resumeSelectedTorrentsHandler: () -> Void = {}
    var requestSelectedTorrentRemovalHandler: () -> Void = {}
    var focusSearchHandler: () -> Void = {}

    func addTorrentFile() {
        addTorrentFileHandler()
    }

    func addMagnetLink() {
        addMagnetLinkHandler()
    }

    func chooseDownloadFolder() {
        chooseDownloadFolderHandler()
    }

    func showSelectedTorrentInfo() {
        showSelectedTorrentInfoHandler()
    }

    func showSelectedTorrentOptions() {
        showSelectedTorrentOptionsHandler()
    }

    func revealSelectedTorrentsInFinder() {
        revealSelectedTorrentsInFinderHandler()
    }

    func pauseSelectedTorrents() {
        pauseSelectedTorrentsHandler()
    }

    func resumeSelectedTorrents() {
        resumeSelectedTorrentsHandler()
    }

    func requestSelectedTorrentRemoval() {
        requestSelectedTorrentRemovalHandler()
    }

    func focusSearch() {
        focusSearchHandler()
    }
}
