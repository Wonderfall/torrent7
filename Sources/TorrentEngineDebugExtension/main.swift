import ExtensionFoundation
import TorrentEngineService

@main
struct TorrentEngineDebugExtension: TorrentEngineAppExtension {
    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(
            host: "app.torrent7.debug",
            name: "torrent-engine"
        )
    }
}
