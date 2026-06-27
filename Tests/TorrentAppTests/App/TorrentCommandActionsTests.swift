import Testing
@testable import TorrentApp

@MainActor
@Suite("Torrent command actions")
struct TorrentCommandActionsTests {
    @Test("Invokes configured handlers")
    func invokesConfiguredHandlers() {
        let actions = TorrentCommandActions()
        var invoked = [String]()
        actions.addTorrentFileHandler = { invoked.append("file") }
        actions.addMagnetLinkHandler = { invoked.append("magnet") }
        actions.chooseDownloadFolderHandler = { invoked.append("folder") }
        actions.showSelectedTorrentInfoHandler = { invoked.append("info") }
        actions.revealSelectedTorrentsInFinderHandler = { invoked.append("reveal") }
        actions.pauseSelectedTorrentsHandler = { invoked.append("pause") }
        actions.resumeSelectedTorrentsHandler = { invoked.append("resume") }
        actions.requestSelectedTorrentRemovalHandler = { invoked.append("remove") }
        actions.focusSearchHandler = { invoked.append("search") }

        actions.addTorrentFile()
        actions.addMagnetLink()
        actions.chooseDownloadFolder()
        actions.showSelectedTorrentInfo()
        actions.revealSelectedTorrentsInFinder()
        actions.pauseSelectedTorrents()
        actions.resumeSelectedTorrents()
        actions.requestSelectedTorrentRemoval()
        actions.focusSearch()

        #expect(invoked == ["file", "magnet", "folder", "info", "reveal", "pause", "resume", "remove", "search"])
    }
}
