import Foundation

enum AppIdentity {
    static let displayName: String = {
        bundleString(forInfoDictionaryKey: "CFBundleDisplayName")
            ?? bundleString(forInfoDictionaryKey: "CFBundleName")
            ?? "Torrent App"
    }()

    static let marketingVersion = bundleString(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "Unknown"
    static let buildVersion = bundleString(forInfoDictionaryKey: "CFBundleVersion") ?? "Unknown"

    private static func bundleString(forInfoDictionaryKey key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
