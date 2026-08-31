package protocol TorrentNotificationServicing: Actor {
    func configure() async
    func notifyDownloadFinished(torrentName: String?, playsSound: Bool) async
    func clearBadge() async
}
