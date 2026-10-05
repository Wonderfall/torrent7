package import Foundation
package import TorrentEngineModel
package import TorrentMetainfo
import TorrentStorageAuthority

package extension ParsedTorrentManifest {
    func filePreview(
        torrentData: Data,
        fileSelections: [ParsedMagnet.FileSelection]? = nil
    ) -> TorrentFilePreview {
        let directoryPrefix = manifest.contentKind == .directory
            ? [manifest.name]
            : []
        var selectionIndex = 0
        let files = manifest.files.map { file in
            let priority: TorrentFilePriority
            if let fileSelections {
                while selectionIndex < fileSelections.count,
                      fileSelections[selectionIndex].lastIndex < file.index {
                    selectionIndex += 1
                }
                priority = selectionIndex < fileSelections.count
                    && fileSelections[selectionIndex].firstIndex <= file.index
                    ? .normal : .skip
            } else {
                priority = .normal
            }
            return TorrentFileItem(
                path: (directoryPrefix + file.pathComponents).joined(separator: "/"),
                size: file.expectedSize,
                downloaded: 0,
                progress: file.expectedSize == 0 ? 1 : 0,
                index: file.index,
                priority: priority,
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
