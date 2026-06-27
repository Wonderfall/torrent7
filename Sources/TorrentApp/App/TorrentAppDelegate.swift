import AppKit

@MainActor
final class TorrentAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: TorrentStore?
    private var isSavingBeforeTermination = false

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let canPause = store?.torrents.contains { !$0.manuallyPaused } ?? false
        let canResume = store?.torrents.contains(where: \.manuallyPaused) ?? false

        let pauseAllItem = NSMenuItem(
            title: "Pause All",
            action: #selector(pauseAllTorrentsFromDock(_:)),
            keyEquivalent: ""
        )
        pauseAllItem.target = self
        pauseAllItem.isEnabled = canPause
        menu.addItem(pauseAllItem)

        let resumeAllItem = NSMenuItem(
            title: "Resume All",
            action: #selector(resumeAllTorrentsFromDock(_:)),
            keyEquivalent: ""
        )
        resumeAllItem.target = self
        resumeAllItem.isEnabled = canResume
        menu.addItem(resumeAllItem)

        return menu
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else {
            return .terminateNow
        }
        guard !isSavingBeforeTermination else {
            return .terminateLater
        }

        isSavingBeforeTermination = true
        Task { @MainActor [weak self] in
            let didSave = await store.saveAllChecked()
            sender.reply(toApplicationShouldTerminate: didSave)
            self?.isSavingBeforeTermination = false
        }

        return .terminateLater
    }

    @objc private func pauseAllTorrentsFromDock(_ sender: NSMenuItem) {
        store?.pauseAllTorrents()
    }

    @objc private func resumeAllTorrentsFromDock(_ sender: NSMenuItem) {
        store?.resumeAllTorrents()
    }
}
