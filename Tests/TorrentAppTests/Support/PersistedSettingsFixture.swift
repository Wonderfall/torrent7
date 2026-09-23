import Foundation
import Testing
import TorrentEngineModel

private struct SettingsRecordFixture: Encodable {
    let schemaVersion: UInt32 = 1
    let settings: TorrentSettings
}

// Unlike production saves, fixtures deliberately preserve noncanonical values
// so rejection tests exercise the decoder rather than the save-time clamp.
func versionedSettingsData(_ settings: TorrentSettings) throws -> Data {
    try JSONEncoder().encode(SettingsRecordFixture(settings: settings))
}

func corruptedVPNSettingsData() throws -> Data {
    var settings = TorrentSettings()
    settings.requireNetworkInterface = true
    settings.showOnlyVPNInterfaces = true
    settings.requiredNetworkInterfaceName = "utun4"
    let encoded = String(decoding: try versionedSettingsData(settings), as: UTF8.self)
    let validField = #""dockTransferRatesEnabled":true"#
    try #require(encoded.contains(validField))
    return Data(encoded.replacingOccurrences(
        of: validField,
        with: #""dockTransferRatesEnabled":"invalid""#
    ).utf8)
}
