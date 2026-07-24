import AppKit
import Foundation
import TorrentEngineModel

struct TorrentCompletionCandidate: Sendable {
    let id: TorrentItem.ID
    let name: String
}

struct TorrentCompletionProjection: Sendable {
    let completedTorrents: [TorrentCompletionCandidate]
    let completedIDs: Set<TorrentItem.ID>
    let activeIDs: Set<TorrentItem.ID>
}

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
    private static let maximumPendingNotificationCount = 64

    private struct Configuration: Equatable {
        let isEnabled: Bool
        let includesTorrentNames: Bool
        let playsSound: Bool

        init(settings: TorrentSettings) {
            isEnabled = settings.completionNotificationsEnabled
            includesTorrentNames = settings.completionNotificationNamesEnabled
            playsSound = settings.completionNotificationSoundEnabled
        }
    }

    private struct PendingNotification: Sendable {
        let torrent: TorrentCompletionCandidate
        let includesTorrentName: Bool
        let playsSound: Bool
    }

    private let history: TorrentCompletionHistoryStoring
    private let notificationService: any TorrentNotificationServicing
    private let dockTileService: TorrentDockTileServicing
    private let activationProvider: ApplicationActivationProviding
    private var baselineRefreshesRemaining = 2
    private var observationGeneration: UInt64 = 0
    private var configuration = Configuration(settings: TorrentSettings())
    private var badgeCount = 0
    private var pendingNotifications = [TorrentCompletionCandidate]()
    private var nextPendingNotificationIndex = 0
    private var notificationDrainTask: Task<Void, Never>?
    private var notificationDrainID: UUID?
    private var badgeTask: Task<Void, Never>?
    private var badgeTaskID: UUID?

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
        advanceObservationGeneration()
        baselineRefreshesRemaining = 2
        pendingNotifications.removeAll()
        nextPendingNotificationIndex = 0
        notificationDrainTask?.cancel()
    }

    func updateConfiguration(_ settings: TorrentSettings) {
        let updatedConfiguration = Configuration(settings: settings)
        guard updatedConfiguration != configuration else {
            return
        }

        if updatedConfiguration.isEnabled != configuration.isEnabled {
            advanceObservationGeneration()
        }
        configuration = updatedConfiguration
        notificationDrainTask?.cancel()
        if !updatedConfiguration.isEnabled {
            pendingNotifications.removeAll()
            nextPendingNotificationIndex = 0
            clearBadge()
        } else if notificationDrainTask == nil {
            startNotificationDrainIfNeeded()
        }
    }

    func clearBadge() {
        badgeCount = 0
        dockTileService.updateCompletionBadge(count: 0)
        let notificationService = notificationService
        badgeTask?.cancel()
        let taskID = UUID()
        badgeTaskID = taskID
        badgeTask = Task { @MainActor [
            weak self,
            notificationService
        ] in
            defer {
                if let self, self.badgeTaskID == taskID {
                    self.badgeTask = nil
                    self.badgeTaskID = nil
                }
            }
            guard !Task.isCancelled else {
                return
            }
            await notificationService.clearBadge()
        }
    }

    func forget(_ ids: Set<TorrentItem.ID>) async {
        try? await history.forget(ids)
    }

    func observeCompletedDownloads(
        in projection: TorrentCompletionProjection,
        previousTorrentsWereEmpty: Bool,
        isEnabled: Bool
    ) async {
        let generation = observationGeneration
        let observedConfiguration = configuration
        let isBaselining = baselineRefreshesRemaining > 0
        if isBaselining {
            baselineRefreshesRemaining -= 1
            if baselineRefreshesRemaining == 0
                && (!projection.activeIDs.isEmpty || previousTorrentsWereEmpty) {
                try? await history.prune(retaining: projection.activeIDs)
            }
        }

        guard !isBaselining && isEnabled && observedConfiguration.isEnabled else {
            try? await history.remember(projection.completedIDs)
            return
        }

        let claim: TorrentCompletionClaim
        do {
            claim = try await history.claimNewlyCompleted(
                from: projection.completedTorrents
            )
        } catch {
            return
        }

        guard !Task.isCancelled else {
            await history.abandonCompletionClaim(claim.id)
            return
        }
        guard generation == observationGeneration,
              configuration.isEnabled else {
            await history.finalizeCompletionClaim(
                claim.id,
                remembering: projection.completedIDs
            )
            return
        }

        let newlyCompletedTorrents = claim.candidates
        guard !newlyCompletedTorrents.isEmpty else {
            await history.finalizeCompletionClaim(
                claim.id,
                remembering: projection.completedIDs
            )
            return
        }

        let shouldBadgeCompletions = !activationProvider.isApplicationActive
        if !shouldBadgeCompletions {
            clearBadge()
        } else {
            let (updatedBadgeCount, overflow) = badgeCount.addingReportingOverflow(
                newlyCompletedTorrents.count
            )
            badgeCount = overflow ? Int.max : updatedBadgeCount
            dockTileService.updateCompletionBadge(count: badgeCount)
        }

        if nextPendingNotificationIndex > 0 {
            pendingNotifications.removeFirst(nextPendingNotificationIndex)
            nextPendingNotificationIndex = 0
        }
        let availableNotificationCount =
            Self.maximumPendingNotificationCount - pendingNotifications.count
        if availableNotificationCount > 0 {
            pendingNotifications.append(
                contentsOf: newlyCompletedTorrents.prefix(availableNotificationCount)
            )
        }
        startNotificationDrainIfNeeded()
        await history.finalizeCompletionClaim(
            claim.id,
            remembering: projection.completedIDs
        )
    }

    private func startNotificationDrainIfNeeded() {
        guard notificationDrainTask == nil,
              configuration.isEnabled,
              nextPendingNotificationIndex < pendingNotifications.count else {
            return
        }
        let drainID = UUID()
        let notificationService = notificationService
        notificationDrainID = drainID
        notificationDrainTask = Task { @MainActor [weak self, notificationService] in
            defer {
                self?.finishNotificationDrain(drainID: drainID)
            }
            while !Task.isCancelled {
                guard let notification = self?.takePendingNotification(drainID: drainID) else {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                await notificationService.notifyDownloadFinished(
                    torrentName: notification.includesTorrentName
                        ? notification.torrent.name
                        : nil,
                    playsSound: notification.playsSound
                )
            }
        }
    }

    private func takePendingNotification(
        drainID: UUID
    ) -> PendingNotification? {
        guard notificationDrainID == drainID,
              configuration.isEnabled,
              nextPendingNotificationIndex < pendingNotifications.count else {
            return nil
        }
        let torrent = pendingNotifications[nextPendingNotificationIndex]
        nextPendingNotificationIndex += 1
        return PendingNotification(
            torrent: torrent,
            includesTorrentName: configuration.includesTorrentNames,
            playsSound: configuration.playsSound
        )
    }

    private func finishNotificationDrain(drainID: UUID) {
        guard notificationDrainID == drainID else {
            return
        }
        if nextPendingNotificationIndex > 0 {
            pendingNotifications.removeFirst(nextPendingNotificationIndex)
            nextPendingNotificationIndex = 0
        }
        notificationDrainTask = nil
        notificationDrainID = nil
        startNotificationDrainIfNeeded()
    }

    private func advanceObservationGeneration() {
        precondition(
            observationGeneration != UInt64.max,
            "Completion-notification observation generation exhausted"
        )
        observationGeneration += 1
    }
}
