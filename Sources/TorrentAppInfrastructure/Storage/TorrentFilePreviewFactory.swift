package import Foundation
package import TorrentEngineModel
import TorrentMetainfo
import TorrentStorageAuthority

package extension ParsedTorrentManifest {
    func filePreview(torrentData: Data) -> TorrentFilePreview {
        let directoryPrefix = manifest.contentKind == .directory
            ? [manifest.name]
            : []
        let files = manifest.files.map { file in
            TorrentFileItem(
                path: (directoryPrefix + file.pathComponents).joined(separator: "/"),
                size: file.expectedSize,
                downloaded: 0,
                progress: file.expectedSize == 0 ? 1 : 0,
                index: file.index,
                priority: .normal,
                isPadFile: file.isPadding
            )
        }
        return TorrentFilePreview(
            name: manifest.name,
            id: primaryHashKey,
            totalSize: manifest.totalSize,
            sourceSecuritySummary: envelope.sourceSecuritySummary,
            files: files,
            torrentData: torrentData
        )
    }

    private var primaryHashKey: String {
        if let v1 = manifest.infoHashes.v1 {
            return "v1:" + Self.hex(v1)
        }
        if let v2 = manifest.infoHashes.v2 {
            return "v2:" + Self.hex(v2)
        }
        return ""
    }

    private static func hex(_ data: Data) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(data.count * 2)
        for byte in data {
            output.append(alphabet[Int(byte >> 4)])
            output.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
