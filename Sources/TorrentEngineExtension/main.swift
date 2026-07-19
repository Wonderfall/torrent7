import ExtensionFoundation
import TorrentEngineService

@main
struct TorrentEngineExtension: TorrentEngineAppExtension {
    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(
            host: "app.torrent7",
            name: "torrent-engine"
        )
    }
}
