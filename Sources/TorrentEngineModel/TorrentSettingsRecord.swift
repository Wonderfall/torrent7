/// The on-disk format is versioned independently of settings sent over IPC.
/// Add a specific migration only when a future schema change requires one.
package struct TorrentSettingsRecord: Codable, Sendable {
    package static let maximumEncodedBytes = 16 * 1_024
    private static let currentSchemaVersion: UInt32 = 1

    private let schemaVersion: UInt32
    package let settings: TorrentSettings

    package init(settings: TorrentSettings) {
        schemaVersion = Self.currentSchemaVersion
        self.settings = settings.clamped()
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported settings schema version."
            )
        }

        let settings = try container.decode(TorrentSettings.self, forKey: .settings)
        guard settings == settings.clamped() else {
            throw DecodingError.dataCorruptedError(
                forKey: .settings,
                in: container,
                debugDescription: "Stored settings are not canonical."
            )
        }
        self.settings = settings
    }
}
