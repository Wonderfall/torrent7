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
        actions.showSelectedTorrentOptionsHandler = { invoked.append("options") }
        actions.revealSelectedTorrentsInFinderHandler = { invoked.append("reveal") }
        actions.pauseSelectedTorrentsHandler = { invoked.append("pause") }
        actions.resumeSelectedTorrentsHandler = { invoked.append("resume") }
        actions.requestSelectedTorrentRemovalHandler = { invoked.append("remove") }
        actions.focusSearchHandler = { invoked.append("search") }

        actions.addTorrentFile()
        actions.addMagnetLink()
        actions.chooseDownloadFolder()
        actions.showSelectedTorrentInfo()
        actions.showSelectedTorrentOptions()
        actions.revealSelectedTorrentsInFinder()
        actions.pauseSelectedTorrents()
        actions.resumeSelectedTorrents()
        actions.requestSelectedTorrentRemoval()
        actions.focusSearch()

        #expect(invoked == [
            "file", "magnet", "folder", "info", "options", "reveal",
            "pause", "resume", "remove", "search",
        ])
    }

    @Test("Removed handlers are inert")
    func removedHandlersAreInert() {
        let actions = TorrentCommandActions()
        var invocationCount = 0
        let handler = { invocationCount += 1 }
        actions.addTorrentFileHandler = handler
        actions.addMagnetLinkHandler = handler
        actions.chooseDownloadFolderHandler = handler
        actions.showSelectedTorrentInfoHandler = handler
        actions.showSelectedTorrentOptionsHandler = handler
        actions.revealSelectedTorrentsInFinderHandler = handler
        actions.pauseSelectedTorrentsHandler = handler
        actions.resumeSelectedTorrentsHandler = handler
        actions.requestSelectedTorrentRemovalHandler = handler
        actions.focusSearchHandler = handler

        actions.removeAllHandlers()
        actions.addTorrentFile()
        actions.addMagnetLink()
        actions.chooseDownloadFolder()
        actions.showSelectedTorrentInfo()
        actions.showSelectedTorrentOptions()
        actions.revealSelectedTorrentsInFinder()
        actions.pauseSelectedTorrents()
        actions.resumeSelectedTorrents()
        actions.requestSelectedTorrentRemoval()
        actions.focusSearch()

        #expect(invocationCount == 0)
    }
}
