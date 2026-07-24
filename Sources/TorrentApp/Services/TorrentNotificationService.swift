import Foundation
import UserNotifications

protocol TorrentNotificationServicing: Sendable {
    @MainActor func configure()
    func notifyDownloadFinished(torrentName: String?, playsSound: Bool) async
    func clearBadge() async
}

private final class TorrentNotificationPresentationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil {
            options.insert(.sound)
        }
        return options
    }
}

actor TorrentNotificationService: TorrentNotificationServicing {
    private static let presentationDelegate = TorrentNotificationPresentationDelegate()
    private static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound]

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    @MainActor
    func configure() {
        UNUserNotificationCenter.current().delegate = Self.presentationDelegate
    }

    func notifyDownloadFinished(torrentName: String?, playsSound: Bool) async {
        guard !Task.isCancelled else {
            return
        }
        guard await requestAuthorizationIfNeeded(playsSound: playsSound) else {
            return
        }
        guard !Task.isCancelled else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = torrentName ?? "A download completed."
        if playsSound {
            content.sound = .default
        }
        content.threadIdentifier = "completed-downloads"

        let request = UNNotificationRequest(
            identifier: "download-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        guard !Task.isCancelled else {
            return
        }
        try? await center.add(request)
    }

    func clearBadge() async {
        try? await center.setBadgeCount(0)
    }

    private func requestAuthorizationIfNeeded(playsSound: Bool) async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        let settings = await center.notificationSettings()
        guard !Task.isCancelled else {
            return false
        }
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            if playsSound && settings.soundSetting != .enabled {
                _ = try? await center.requestAuthorization(options: Self.authorizationOptions)
                guard !Task.isCancelled else {
                    return false
                }
            }
            return true
        case .notDetermined:
            let options: UNAuthorizationOptions =
                playsSound ? Self.authorizationOptions : [.alert]
            let isAuthorized =
                (try? await center.requestAuthorization(options: options)) ?? false
            return !Task.isCancelled && isAuthorized
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

}
