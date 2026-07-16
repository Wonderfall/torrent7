import Dispatch
import Foundation

do {
    let service = try TorrentEngineServiceBootstrap()
    try service.activate()
    dispatchMain()
} catch {
    fatalError("The isolated torrent engine service could not start: \(error.localizedDescription)")
}
