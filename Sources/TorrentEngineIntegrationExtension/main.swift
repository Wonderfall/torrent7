import ExtensionFoundation
import TorrentEngineService

@main
struct TorrentEngineIntegrationExtension: TorrentEngineAppExtension {
    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(
            host: "app.torrent7.integration",
            name: "torrent-engine"
        )
    }
}
