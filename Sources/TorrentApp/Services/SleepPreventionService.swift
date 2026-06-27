import Foundation

protocol SleepPreventionServicing: AnyObject {
    func update(isEnabled: Bool, hasActiveTransfers: Bool)
}

final class SleepPreventionService: SleepPreventionServicing {
    private var activity: (any NSObjectProtocol)?

    deinit {
        endActivity()
    }

    func update(isEnabled: Bool, hasActiveTransfers: Bool) {
        if isEnabled && hasActiveTransfers {
            beginActivity()
        } else {
            endActivity()
        }
    }

    private func beginActivity() {
        guard activity == nil else {
            return
        }

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Active torrent transfers"
        )
    }

    private func endActivity() {
        guard let activity else {
            return
        }

        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}
