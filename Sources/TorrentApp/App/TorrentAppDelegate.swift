import AppKit

@MainActor
final class TorrentAppDelegate: NSObject, NSApplicationDelegate {
    let store = TorrentStore()
    private var isSavingBeforeTermination = false
    private var terminationTask: Task<Void, Never>?

    isolated deinit {
        terminationTask?.cancel()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let canPause =
            store.commandState.snapshot.canPauseAnyTorrent
        let canResume =
            store.commandState.snapshot.canResumeAnyTorrent

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
        guard !isSavingBeforeTermination else {
            return .terminateLater
        }

        isSavingBeforeTermination = true
        let store = store
        terminationTask = Task { @MainActor [weak self, store] in
            let didSave = await store.saveAllChecked()
            sender.reply(toApplicationShouldTerminate: didSave)
            self?.isSavingBeforeTermination = false
            self?.terminationTask = nil
        }

        return .terminateLater
    }

    @objc private func pauseAllTorrentsFromDock(_ sender: NSMenuItem) {
        store.pauseAllTorrents()
    }

    @objc private func resumeAllTorrentsFromDock(_ sender: NSMenuItem) {
        store.resumeAllTorrents()
    }
}
