import ExtensionFoundation
import TorrentEngineService

@main
struct TorrentEngineIntegrationExtension: TorrentEngineAppExtension {
    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        #if TORRENT_ADDRESS_SANITIZER
        AppExtensionPoint.Identifier(
            host: "app.torrent7.integration.asan",
            name: "torrent-engine"
        )
        #elseif TORRENT_THREAD_SANITIZER
        AppExtensionPoint.Identifier(
            host: "app.torrent7.integration.tsan",
            name: "torrent-engine"
        )
        #else
        AppExtensionPoint.Identifier(
            host: "app.torrent7.integration",
            name: "torrent-engine"
        )
        #endif
    }
}
