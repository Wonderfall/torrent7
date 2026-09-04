import Foundation
import Testing
import TorrentEngineModel

func corruptedVPNSettingsData() throws -> Data {
    var settings = TorrentSettings()
    settings.requireNetworkInterface = true
    settings.showOnlyVPNInterfaces = true
    settings.requiredNetworkInterfaceName = "utun4"
    let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
    let validField = #""dockTransferRatesEnabled":true"#
    try #require(encoded.contains(validField))
    return Data(encoded.replacingOccurrences(
        of: validField,
        with: #""dockTransferRatesEnabled":"invalid""#
    ).utf8)
}
