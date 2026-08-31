import TorrentEngineModel

package struct TorrentCompletionCandidate: Sendable {
    package let id: TorrentItem.ID
    package let name: String

    package init(id: TorrentItem.ID, name: String) {
        self.id = id
        self.name = name
    }
}
