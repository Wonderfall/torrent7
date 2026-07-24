import Foundation
import Testing
import TorrentEngineModel
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

        await notifier.observeCompletedDownloads(
            in: [makeTorrent(id: "complete", finished: true)],
            previousTorrents: [],
            settings: TorrentSettings(),
            isEnabled: true
        )
        await notifier.observeCompletedDownloads(
            in: [makeTorrent(id: "complete", finished: true), makeTorrent(id: "active")],
            previousTorrents: [makeTorrent(id: "complete", finished: true)],
            settings: TorrentSettings(),
            isEnabled: true
        )
        await Task.yield()

        #expect(await history.completedIDs == ["complete"])
        #expect(await history.prunedRetainedIDs == [["complete", "active"]])
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
        await consumeBaseline(for: notifier)

        var settings = TorrentSettings()
        settings.completionNotificationSoundEnabled = false
        await notifier.observeCompletedDownloads(
            in: [
                makeTorrent(id: "alpha", name: "Alpha", finished: true),
                makeTorrent(id: "beta", name: "Beta", seeding: true)
            ],
            previousTorrents: [makeTorrent(id: "alpha")],
            settings: settings,
            isEnabled: true
        )
        await waitForNotifications(notifications, count: 2)

        #expect(await history.completedIDs == ["alpha", "beta"])
        #expect(dock.completionBadgeUpdates == [2])
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
        await consumeBaseline(for: notifier)

        var settings = TorrentSettings()
        settings.completionNotificationNamesEnabled = true

        await notifier.observeCompletedDownloads(
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
        await consumeBaseline(for: notifier)

        await notifier.observeCompletedDownloads(
            in: [makeTorrent(id: "alpha", name: "Alpha", finished: true)],
            previousTorrents: [makeTorrent(id: "alpha")],
            settings: TorrentSettings(),
            isEnabled: true
        )
        await waitForNotifications(notifications, count: 1)
        await waitForBadgeClears(notifications, count: 1)

        #expect(dock.completionBadgeUpdates == [0])
        #expect(await notifications.clearBadgeCount == 1)
        #expect(await notifications.notifications.map(\.torrentName) == [nil])
    }

    @Test("Disabled notification settings remember completions and clear the badge")
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
        await consumeBaseline(for: notifier)
        var settings = TorrentSettings()
        settings.completionNotificationsEnabled = false

        await notifier.observeCompletedDownloads(
            in: [makeTorrent(id: "alpha", finished: true)],
            previousTorrents: [],
            settings: settings,
            isEnabled: true
        )
        await Task.yield()

        #expect(await history.completedIDs == ["alpha"])
        #expect(dock.completionBadgeUpdates == [0])
        #expect(await notifications.notifications.isEmpty)
    }

    @Test("A settings change during history lookup invalidates stale publication")
    func settingsChangeDuringHistoryLookupInvalidatesPublication() async {
        let history = SuspendingCompletionHistoryStore()
        let notifications = RecordingNotificationService()
        let dock = RecordingDockTileService()
        let notifier = TorrentCompletionNotifier(
            history: history,
            notificationService: notifications,
            dockTileService: dock,
            activationProvider: FixedApplicationActivationProvider(isApplicationActive: false)
        )
        await consumeBaseline(for: notifier)

        let observation = Task { @MainActor in
            await notifier.observeCompletedDownloads(
                in: [makeTorrent(id: "alpha", name: "Alpha", finished: true)],
                previousTorrents: [makeTorrent(id: "alpha")],
                settings: TorrentSettings(),
                isEnabled: true
            )
        }
        await waitForHistorySuspension(history)

        var disabledSettings = TorrentSettings()
        disabledSettings.completionNotificationsEnabled = false
        notifier.updateConfiguration(disabledSettings)
        await history.resume()
        await observation.value
        await Task.yield()

        #expect(await history.completedIDs == ["alpha"])
        #expect(await notifications.notifications.isEmpty)
        #expect(dock.completionBadgeUpdates == [0])
    }

    @Test("Cosmetic settings changes during history lookup use current configuration")
    func cosmeticSettingsChangeDuringHistoryLookupUsesCurrentConfiguration() async {
        let history = SuspendingCompletionHistoryStore()
        let notifications = RecordingNotificationService()
        let dock = RecordingDockTileService()
        let notifier = TorrentCompletionNotifier(
            history: history,
            notificationService: notifications,
            dockTileService: dock,
            activationProvider: FixedApplicationActivationProvider(isApplicationActive: false)
        )
        await consumeBaseline(for: notifier)

        var namedSettings = TorrentSettings()
        namedSettings.completionNotificationNamesEnabled = true
        let observation = Task { @MainActor in
            await notifier.observeCompletedDownloads(
                in: [makeTorrent(id: "alpha", name: "Alpha", finished: true)],
                previousTorrents: [makeTorrent(id: "alpha")],
                settings: namedSettings,
                isEnabled: true
            )
        }
        await waitForHistorySuspension(history)

        var privateSettings = TorrentSettings()
        privateSettings.completionNotificationSoundEnabled = false
        notifier.updateConfiguration(privateSettings)
        await history.resume()
        await observation.value
        await waitForNotifications(notifications, count: 1)

        #expect(await history.completedIDs == ["alpha"])
        #expect(await notifications.notifications == [
            RecordingNotificationService.Notification(
                torrentName: nil,
                playsSound: false
            )
        ])
        #expect(dock.completionBadgeUpdates == [1])
    }

    @Test("Disabling and reenabling notifications invalidates an older lookup")
    func notificationEnablementRoundTripInvalidatesOlderLookup() async {
        let history = SuspendingCompletionHistoryStore()
        let notifications = RecordingNotificationService()
        let dock = RecordingDockTileService()
        let notifier = TorrentCompletionNotifier(
            history: history,
            notificationService: notifications,
            dockTileService: dock,
            activationProvider: FixedApplicationActivationProvider(
                isApplicationActive: false
            )
        )
        await consumeBaseline(for: notifier)

        let observation = Task { @MainActor in
            await notifier.observeCompletedDownloads(
                in: [
                    makeTorrent(
                        id: "alpha",
                        name: "Alpha",
                        finished: true
                    )
                ],
                previousTorrents: [makeTorrent(id: "alpha")],
                settings: TorrentSettings(),
                isEnabled: true
            )
        }
        await waitForHistorySuspension(history)

        var disabledSettings = TorrentSettings()
        disabledSettings.completionNotificationsEnabled = false
        notifier.updateConfiguration(disabledSettings)
        notifier.updateConfiguration(TorrentSettings())
        await history.resume()
        await observation.value
        await Task.yield()

        #expect(await history.completedIDs == ["alpha"])
        #expect(await notifications.notifications.isEmpty)
        #expect(dock.completionBadgeUpdates == [0])
    }

    @Test("Cancellation during history lookup does not consume the completion")
    func cancellationDuringHistoryLookupDoesNotConsumeCompletion() async {
        let history = SuspendingCompletionHistoryStore()
        let notifications = RecordingNotificationService()
        let notifier = TorrentCompletionNotifier(
            history: history,
            notificationService: notifications,
            dockTileService: RecordingDockTileService(),
            activationProvider: FixedApplicationActivationProvider(isApplicationActive: false)
        )
        await consumeBaseline(for: notifier)

        let observation = Task { @MainActor in
            await notifier.observeCompletedDownloads(
                in: [makeTorrent(id: "alpha", finished: true)],
                previousTorrents: [makeTorrent(id: "alpha")],
                settings: TorrentSettings(),
                isEnabled: true
            )
        }
        await waitForHistorySuspension(history)

        observation.cancel()
        await history.resume()
        await observation.value

        #expect(await history.completedIDs.isEmpty)
        #expect(await notifications.notifications.isEmpty)
    }

    @Test("Cancellation abandons a claim returned by cancellation-insensitive history")
    func cancellationAbandonsClaimFromCancellationInsensitiveHistory() async {
        let history = SuspendingCompletionHistoryStore(
            observesCancellationAfterSuspension: false
        )
        let notifications = RecordingNotificationService()
        let notifier = TorrentCompletionNotifier(
            history: history,
            notificationService: notifications,
            dockTileService: RecordingDockTileService(),
            activationProvider: FixedApplicationActivationProvider(
                isApplicationActive: false
            )
        )
        await consumeBaseline(for: notifier)

        let observation = Task { @MainActor in
            await notifier.observeCompletedDownloads(
                in: [makeTorrent(id: "alpha", finished: true)],
                previousTorrents: [makeTorrent(id: "alpha")],
                settings: TorrentSettings(),
                isEnabled: true
            )
        }
        await waitForHistorySuspension(history)

        observation.cancel()
        await history.resume()
        await observation.value

        #expect(await history.completedIDs.isEmpty)
        #expect(await notifications.notifications.isEmpty)

        await notifier.observeCompletedDownloads(
            in: [makeTorrent(id: "alpha", finished: true)],
            previousTorrents: [makeTorrent(id: "alpha")],
            settings: TorrentSettings(),
            isEnabled: true
        )
        await waitForNotifications(notifications, count: 1)

        #expect(await history.completedIDs == ["alpha"])
        #expect(await notifications.notifications.count == 1)
    }

    @Test("Disabling notifications cancels and clears queued delivery")
    func disablingNotificationsCancelsQueuedDelivery() async {
        let notifications = SuspendingNotificationService()
        let notifier = TorrentCompletionNotifier(
            history: RecordingCompletionHistoryStore(),
            notificationService: notifications,
            dockTileService: RecordingDockTileService(),
            activationProvider: FixedApplicationActivationProvider(isApplicationActive: false)
        )
        await consumeBaseline(for: notifier)

        await notifier.observeCompletedDownloads(
            in: [
                makeTorrent(id: "alpha", name: "Alpha", finished: true),
                makeTorrent(id: "beta", name: "Beta", finished: true),
            ],
            previousTorrents: [makeTorrent(id: "alpha"), makeTorrent(id: "beta")],
            settings: TorrentSettings(),
            isEnabled: true
        )
        await waitForNotificationSuspension(notifications)

        var disabledSettings = TorrentSettings()
        disabledSettings.completionNotificationsEnabled = false
        notifier.updateConfiguration(disabledSettings)
        await notifications.resume()
        await Task.yield()

        #expect(await notifications.notifications.isEmpty)
    }

    @Test("Queued delivery uses current privacy and sound settings")
    func queuedDeliveryUsesCurrentConfiguration() async {
        let notifications = SuspendingNotificationService()
        let notifier = TorrentCompletionNotifier(
            history: RecordingCompletionHistoryStore(),
            notificationService: notifications,
            dockTileService: RecordingDockTileService(),
            activationProvider: FixedApplicationActivationProvider(isApplicationActive: false)
        )
        await consumeBaseline(for: notifier)

        var namedSettings = TorrentSettings()
        namedSettings.completionNotificationNamesEnabled = true
        await notifier.observeCompletedDownloads(
            in: [
                makeTorrent(id: "alpha", name: "Alpha", finished: true),
                makeTorrent(id: "beta", name: "Beta", finished: true),
            ],
            previousTorrents: [makeTorrent(id: "alpha"), makeTorrent(id: "beta")],
            settings: namedSettings,
            isEnabled: true
        )
        await waitForNotificationSuspension(notifications)

        var privateSettings = TorrentSettings()
        privateSettings.completionNotificationSoundEnabled = false
        notifier.updateConfiguration(privateSettings)
        await notifications.resume()
        await waitForNotifications(notifications, count: 1)

        #expect(await notifications.notifications == [
            SuspendingNotificationService.Notification(
                torrentName: nil,
                playsSound: false
            )
        ])
    }

    private func consumeBaseline(for notifier: TorrentCompletionNotifier) async {
        await notifier.observeCompletedDownloads(in: [], previousTorrents: [], settings: TorrentSettings(), isEnabled: true)
        await notifier.observeCompletedDownloads(in: [], previousTorrents: [], settings: TorrentSettings(), isEnabled: true)
    }

    private func waitForNotifications(_ notifications: RecordingNotificationService, count: Int) async {
        for _ in 0..<20 {
            if await notifications.notifications.count >= count {
                return
            }
            await Task.yield()
        }
    }

    private func waitForBadgeClears(_ notifications: RecordingNotificationService, count: Int) async {
        for _ in 0..<20 {
            if await notifications.clearBadgeCount >= count {
                return
            }
            await Task.yield()
        }
    }

    private func waitForHistorySuspension(
        _ history: SuspendingCompletionHistoryStore
    ) async {
        for _ in 0..<100 {
            if await history.isSuspended {
                return
            }
            await Task.yield()
        }
        Issue.record("History lookup did not suspend")
    }

    private func waitForNotificationSuspension(
        _ notifications: SuspendingNotificationService
    ) async {
        for _ in 0..<100 {
            if await notifications.isSuspended {
                return
            }
            await Task.yield()
        }
        Issue.record("Notification delivery did not suspend")
    }

    private func waitForNotifications(
        _ notifications: SuspendingNotificationService,
        count: Int
    ) async {
        for _ in 0..<100 {
            if await notifications.notifications.count >= count {
                return
            }
            await Task.yield()
        }
    }
}

private actor SuspendingCompletionHistoryStore: TorrentCompletionHistoryStoring {
    private(set) var completedIDs = Set<TorrentItem.ID>()
    private(set) var isSuspended = false
    private let observesCancellationAfterSuspension: Bool
    private var shouldSuspendNextClaim = true
    private var continuation: CheckedContinuation<Void, Never>?
    private var reservedIDs = Set<TorrentItem.ID>()
    private var reservedIDsByClaim = [UUID: Set<TorrentItem.ID>]()

    init(observesCancellationAfterSuspension: Bool = true) {
        self.observesCancellationAfterSuspension =
            observesCancellationAfterSuspension
    }

    func contains(_ id: TorrentItem.ID) async throws -> Bool {
        completedIDs.contains(id)
    }

    func claimNewlyCompleted(
        from candidates: [TorrentCompletionCandidate]
    ) async throws -> TorrentCompletionClaim {
        if shouldSuspendNextClaim {
            shouldSuspendNextClaim = false
            precondition(continuation == nil)
            isSuspended = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
            isSuspended = false
        }
        if observesCancellationAfterSuspension {
            try Task.checkCancellation()
        }
        let newlyCompleted = candidates.filter {
            !completedIDs.contains($0.id) && !reservedIDs.contains($0.id)
        }
        if observesCancellationAfterSuspension {
            try Task.checkCancellation()
        }
        let claimID = UUID()
        let claimedIDs = Set(newlyCompleted.map(\.id))
        reservedIDs.formUnion(claimedIDs)
        reservedIDsByClaim[claimID] = claimedIDs
        return TorrentCompletionClaim(
            id: claimID,
            candidates: newlyCompleted
        )
    }

    func finalizeCompletionClaim(
        _ id: UUID,
        remembering completedIDs: Set<TorrentItem.ID>
    ) {
        releaseCompletionClaim(id)
        self.completedIDs.formUnion(completedIDs)
    }

    func abandonCompletionClaim(_ id: UUID) {
        releaseCompletionClaim(id)
    }

    func remember(_ ids: Set<TorrentItem.ID>) async throws {
        try Task.checkCancellation()
        completedIDs.formUnion(ids)
    }

    func forget(_ ids: Set<TorrentItem.ID>) async throws {
        try Task.checkCancellation()
        completedIDs.subtract(ids)
    }

    func prune(retaining activeIDs: Set<TorrentItem.ID>) async throws {
        try Task.checkCancellation()
        completedIDs.formIntersection(activeIDs)
    }

    func resume() {
        guard let continuation else {
            return
        }
        self.continuation = nil
        continuation.resume()
    }

    private func releaseCompletionClaim(_ id: UUID) {
        guard let claimedIDs = reservedIDsByClaim.removeValue(forKey: id) else {
            return
        }
        reservedIDs.subtract(claimedIDs)
    }
}

private actor SuspendingNotificationService: TorrentNotificationServicing {
    struct Notification: Equatable, Sendable {
        let torrentName: String?
        let playsSound: Bool
    }

    private(set) var notifications = [Notification]()
    private(set) var isSuspended = false
    private var shouldSuspendNextNotification = true
    private var continuation: CheckedContinuation<Void, Never>?

    @MainActor
    func configure() {}

    func notifyDownloadFinished(torrentName: String?, playsSound: Bool) async {
        if shouldSuspendNextNotification {
            shouldSuspendNextNotification = false
            precondition(continuation == nil)
            isSuspended = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
            isSuspended = false
        }
        guard !Task.isCancelled else {
            return
        }
        notifications.append(Notification(
            torrentName: torrentName,
            playsSound: playsSound
        ))
    }

    func clearBadge() async {}

    func resume() {
        guard let continuation else {
            return
        }
        self.continuation = nil
        continuation.resume()
    }
}

private extension TorrentCompletionNotifier {
    func observeCompletedDownloads(
        in snapshots: [TorrentItem],
        previousTorrents: [TorrentItem],
        settings: TorrentSettings,
        isEnabled: Bool
    ) async {
        updateConfiguration(settings)
        let completedTorrents = snapshots.compactMap { torrent in
            torrent.downloadComplete
                ? TorrentCompletionCandidate(id: torrent.id, name: torrent.name)
                : nil
        }
        await observeCompletedDownloads(
            in: TorrentCompletionProjection(
                completedTorrents: completedTorrents,
                completedIDs: Set(completedTorrents.map(\.id)),
                activeIDs: Set(snapshots.map(\.id))
            ),
            previousTorrentsWereEmpty: previousTorrents.isEmpty,
            isEnabled: isEnabled
        )
    }
}
