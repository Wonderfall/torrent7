import ExtensionFoundation
import TorrentEngineService

@main
struct TorrentEngineDiagnosticsExtension: TorrentEngineAppExtension {
    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        #if TORRENT_THREAD_SANITIZER
        AppExtensionPoint.Identifier(
            host: "app.torrent7.tsan",
            name: "torrent-engine"
        )
        #else
        AppExtensionPoint.Identifier(
            host: "app.torrent7.asan",
            name: "torrent-engine"
        )
        #endif
    }
}
