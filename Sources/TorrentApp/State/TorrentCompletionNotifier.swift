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
    private let history: TorrentCompletionHistoryStoring
    private let notificationService: any TorrentNotificationServicing
    private let dockTileService: TorrentDockTileServicing
    private let activationProvider: ApplicationActivationProviding
    private var baselineRefreshesRemaining = 2
    private var badgeCount = 0

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
        Task {
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
            let notificationService = notificationService
            let torrentName = settings.completionNotificationNamesEnabled ? torrent.name : nil
            let playsSound = settings.completionNotificationSoundEnabled
            Task {
                await notificationService.notifyDownloadFinished(torrentName: torrentName, playsSound: playsSound)
            }
        }
    }
}
