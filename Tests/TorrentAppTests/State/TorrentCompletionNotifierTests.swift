import Testing
@testable import TorrentApp

@MainActor
@Suite("Torrent completion notifier")
struct TorrentCompletionNotifierTests {
    @Test("Baselining remembers completed torrents without notifying")
    func baseliningRemembersCompletedTorrentsWithoutNotifying() async {
        let history = RecordingCompletionHistoryStore(completedIDs: ["stale"])
        let notifications = RecordingNotificationService()
        let dock = RecordingDockTileService()
        let notifier = TorrentCompletionNotifier(
            history: history,
            notificationService: notifications,
            dockTileService: dock,
            activationProvider: FixedApplicationActivationProvider(isApplicationActive: false)
        )

        notifier.observeCompletedDownloads(
            in: [makeTorrent(id: "complete", finished: true)],
            previousTorrents: [],
            settings: TorrentSettings(),
            isEnabled: true
        )
        notifier.observeCompletedDownloads(
            in: [makeTorrent(id: "complete", finished: true), makeTorrent(id: "active")],
            previousTorrents: [makeTorrent(id: "complete", finished: true)],
            settings: TorrentSettings(),
            isEnabled: true
        )
        await Task.yield()

        #expect(history.completedIDs == ["complete"])
        #expect(history.prunedRetainedIDs == [["complete", "active"]])
        #expect(dock.completionBadgeUpdates.isEmpty)
        #expect(await notifications.notifications.isEmpty)
    }

    @Test("Inactive app badges and notifies newly completed torrents without names by default")
    func inactiveAppBadgesAndNotifiesNewlyCompletedTorrentsWithoutNamesByDefault() async {
        let history = RecordingCompletionHistoryStore()
        let notifications = RecordingNotificationService()
        let dock = RecordingDockTileService()
        let notifier = TorrentCompletionNotifier(
            history: history,
            notificationService: notifications,
            dockTileService: dock,
            activationProvider: FixedApplicationActivationProvider(isApplicationActive: false)
        )
        consumeBaseline(for: notifier)

        var settings = TorrentSettings()
        settings.completionNotificationSoundEnabled = false
        notifier.observeCompletedDownloads(
            in: [
                makeTorrent(id: "alpha", name: "Alpha", finished: true),
                makeTorrent(id: "beta", name: "Beta", seeding: true)
            ],
            previousTorrents: [makeTorrent(id: "alpha")],
            settings: settings,
            isEnabled: true
        )
        await Task.yield()

        #expect(history.completedIDs == ["alpha", "beta"])
        #expect(dock.completionBadgeUpdates == [1, 2])
        #expect(await notifications.notifications == [
            RecordingNotificationService.Notification(torrentName: nil, playsSound: false),
            RecordingNotificationService.Notification(torrentName: nil, playsSound: false)
        ])
    }

    @Test("Opt-in notification setting includes torrent names")
    func optInNotificationSettingIncludesTorrentNames() async {
        let notifications = RecordingNotificationService()
        let notifier = TorrentCompletionNotifier(
            history: RecordingCompletionHistoryStore(),
            notificationService: notifications,
            dockTileService: RecordingDockTileService(),
            activationProvider: FixedApplicationActivationProvider(isApplicationActive: false)
        )
        consumeBaseline(for: notifier)

        var settings = TorrentSettings()
        settings.completionNotificationNamesEnabled = true

        notifier.observeCompletedDownloads(
            in: [makeTorrent(id: "alpha", name: "Alpha", finished: true)],
            previousTorrents: [makeTorrent(id: "alpha")],
            settings: settings,
            isEnabled: true
        )
        await waitForNotifications(notifications, count: 1)

        #expect(await notifications.notifications == [
            RecordingNotificationService.Notification(torrentName: "Alpha", playsSound: true)
        ])
    }

    @Test("Active app clears badge instead of incrementing completion badge")
    func activeAppClearsBadgeInsteadOfIncrementingCompletionBadge() async {
        let notifications = RecordingNotificationService()
        let dock = RecordingDockTileService()
        let notifier = TorrentCompletionNotifier(
            history: RecordingCompletionHistoryStore(),
            notificationService: notifications,
            dockTileService: dock,
            activationProvider: FixedApplicationActivationProvider(isApplicationActive: true)
        )
        consumeBaseline(for: notifier)

        notifier.observeCompletedDownloads(
            in: [makeTorrent(id: "alpha", name: "Alpha", finished: true)],
            previousTorrents: [makeTorrent(id: "alpha")],
            settings: TorrentSettings(),
            isEnabled: true
        )
        await Task.yield()

        #expect(dock.completionBadgeUpdates == [0])
        #expect(await notifications.clearBadgeCount == 1)
        #expect(await notifications.notifications.map(\.torrentName) == [nil])
    }

    @Test("Disabled notification settings remember completions without side effects")
    func disabledNotificationSettingsRememberCompletionsWithoutSideEffects() async {
        let history = RecordingCompletionHistoryStore()
        let notifications = RecordingNotificationService()
        let dock = RecordingDockTileService()
        let notifier = TorrentCompletionNotifier(
            history: history,
            notificationService: notifications,
            dockTileService: dock,
            activationProvider: FixedApplicationActivationProvider(isApplicationActive: false)
        )
        consumeBaseline(for: notifier)
        var settings = TorrentSettings()
        settings.completionNotificationsEnabled = false

        notifier.observeCompletedDownloads(
            in: [makeTorrent(id: "alpha", finished: true)],
            previousTorrents: [],
            settings: settings,
            isEnabled: true
        )
        await Task.yield()

        #expect(history.completedIDs == ["alpha"])
        #expect(dock.completionBadgeUpdates.isEmpty)
        #expect(await notifications.notifications.isEmpty)
    }

    private func consumeBaseline(for notifier: TorrentCompletionNotifier) {
        notifier.observeCompletedDownloads(in: [], previousTorrents: [], settings: TorrentSettings(), isEnabled: true)
        notifier.observeCompletedDownloads(in: [], previousTorrents: [], settings: TorrentSettings(), isEnabled: true)
    }

    private func waitForNotifications(_ notifications: RecordingNotificationService, count: Int) async {
        for _ in 0..<20 {
            if await notifications.notifications.count >= count {
                return
            }
            await Task.yield()
        }
    }
}
