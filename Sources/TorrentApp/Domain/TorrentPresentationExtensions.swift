import TorrentEngineModel

extension TorrentWebSeedActivity {
    var summaryText: String? {
        guard activeCount > 0 else {
            return nil
        }

        let connectionText = "\(activeCount) active"
        guard downloadRate > 0 else {
            return connectionText
        }
        return "\(connectionText) · \(ByteFormat.rate(downloadRate))"
    }
}

extension TorrentFileItem {
    var detailText: String {
        "\(ByteFormat.size(downloaded)) of \(ByteFormat.size(size))"
    }
}
