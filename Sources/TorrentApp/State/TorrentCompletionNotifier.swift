import AppKit
import Foundation
import TorrentEngineModel

@MainActor
protocol ApplicationActivationProviding {
    var isApplicationActive: Bool { get }
}

@MainActor
struct SharedApplicationActivationProvider: ApplicationActivationProviding {
    var isApplicationActive: Bool {
        NSApplication.shared.isActive
    }
}

@MainActor
final class TorrentCompletionNotifier {
    private struct PendingNotification: Sendable {
        let torrentName: String?
        let playsSound: Bool
    }

    private let history: TorrentCompletionHistoryStoring
    private let notificationService: any TorrentNotificationServicing
    private let dockTileService: TorrentDockTileServicing
    private let activationProvider: ApplicationActivationProviding
    private var baselineRefreshesRemaining = 2
    private var badgeCount = 0
    private var pendingNotifications = [PendingNotification]()
    private var notificationDrainTask: Task<Void, Never>?
    private var notificationDrainID: UUID?
    private var badgeTask: Task<Void, Never>?

    init(
        history: TorrentCompletionHistoryStoring = TorrentCompletionHistoryStore(),
        notificationService: any TorrentNotificationServicing = TorrentNotificationService(),
        dockTileService: TorrentDockTileServicing,
        activationProvider: ApplicationActivationProviding = SharedApplicationActivationProvider()
    ) {
        self.history = history
        self.notificationService = notificationService
        self.dockTileService = dockTileService
        self.activationProvider = activationProvider
    }

    isolated deinit {
        notificationDrainTask?.cancel()
        badgeTask?.cancel()
    }

    func configure() {
        notificationService.configure()
    }

    func beginBaseline() {
        baselineRefreshesRemaining = 2
    }

    func clearBadge() {
        badgeCount = 0
        dockTileService.updateCompletionBadge(count: 0)
        let notificationService = notificationService
        badgeTask?.cancel()
        badgeTask = Task {
            guard !Task.isCancelled else {
                return
            }
            await notificationService.clearBadge()
        }
    }

    func forget(_ ids: Set<TorrentItem.ID>) {
        history.forget(ids)
    }

    func observeCompletedDownloads(
        in snapshots: [TorrentItem],
        previousTorrents: [TorrentItem],
        settings: TorrentSettings,
        isEnabled: Bool
    ) {
        let completedTorrents = snapshots.filter(\.downloadComplete)
        let completedIDs = Set(completedTorrents.map(\.id))

        let isBaselining = baselineRefreshesRemaining > 0
        if isBaselining {
            baselineRefreshesRemaining -= 1
            if baselineRefreshesRemaining == 0 && (!snapshots.isEmpty || previousTorrents.isEmpty) {
                history.prune(retaining: Set(snapshots.map(\.id)))
            }
        }

        guard !isBaselining && isEnabled && settings.completionNotificationsEnabled else {
            history.remember(completedIDs)
            return
        }

        let newlyCompletedTorrents = completedTorrents.filter { !history.contains($0.id) }
        history.remember(completedIDs)
        guard !newlyCompletedTorrents.isEmpty else {
            return
        }

        let shouldBadgeCompletions = !activationProvider.isApplicationActive
        if !shouldBadgeCompletions {
            clearBadge()
        }

        for torrent in newlyCompletedTorrents {
            if shouldBadgeCompletions {
                badgeCount += 1
                dockTileService.updateCompletionBadge(count: badgeCount)
            }
            let torrentName = settings.completionNotificationNamesEnabled ? torrent.name : nil
            let playsSound = settings.completionNotificationSoundEnabled
            pendingNotifications.append(PendingNotification(
                torrentName: torrentName,
                playsSound: playsSound
            ))
        }
        startNotificationDrainIfNeeded()
    }

    private func startNotificationDrainIfNeeded() {
        guard notificationDrainTask == nil else {
            return
        }
        let drainID = UUID()
        let notificationService = notificationService
        notificationDrainID = drainID
        notificationDrainTask = Task { @MainActor [weak self, notificationService] in
            while !Task.isCancelled {
                guard let batch = self?.takePendingNotificationBatch(drainID: drainID) else {
                    return
                }
                for notification in batch {
                    guard !Task.isCancelled else {
                        return
                    }
                    await notificationService.notifyDownloadFinished(
                        torrentName: notification.torrentName,
                        playsSound: notification.playsSound
                    )
                }
            }
        }
    }

    private func takePendingNotificationBatch(
        drainID: UUID
    ) -> [PendingNotification]? {
        guard notificationDrainID == drainID else {
            return nil
        }
        guard !pendingNotifications.isEmpty else {
            notificationDrainTask = nil
            notificationDrainID = nil
            return nil
        }
        let batch = pendingNotifications
        pendingNotifications.removeAll(keepingCapacity: true)
        return batch
    }
}
