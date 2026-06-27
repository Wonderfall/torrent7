import Foundation

enum TorrentInfoTab: Hashable {
    case general
    case sources
    case files
    case pieces
    case options
}

struct TorrentInfoTabRequest: Equatable {
    let tab: TorrentInfoTab
    let token: Int
}
