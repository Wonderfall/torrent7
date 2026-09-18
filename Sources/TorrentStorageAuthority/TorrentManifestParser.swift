package import Foundation
package import TorrentMetainfo

/// Adapts the shared, authority-free metainfo result into the storage model.
/// All hostile-byte parsing remains in `TorrentMetainfoParser` so the app and
/// engine helper can use one bounded implementation.
package struct TorrentManifestParser: Sendable {
    package typealias Limits = TorrentMetainfoParser.Limits

    private let parser: TorrentMetainfoParser

    package init(limits: Limits = .standard) {
        parser = TorrentMetainfoParser(limits: limits)
    }

    package func parse(
        _ metadata: Data,
        advertisedHashes: TorrentAdvertisedInfoHashes? = nil,
        checkCancellation: @escaping @Sendable () throws -> Void = {}
    ) throws -> ParsedTorrentManifest {
        let parsed = try parser.parse(
            metadata,
            advertisedHashes: advertisedHashes,
            checkCancellation: checkCancellation
        )
        let core = parsed.infoCore
        let contentKind: TorrentStorageContentKind = switch core.contentKind {
        case .singleFile: .singleFile
        case .directory: .directory
        }
        let hashes = try TorrentStorageInfoHashes(
            v1: core.v1InfoHash,
            v2: core.v2InfoHash
        )
        let files = core.files.map { file in
            TorrentLogicalFile(
                index: file.index,
                pathComponents: file.pathComponents,
                expectedSize: file.expectedSize,
                isPadding: file.isPadding
            )
        }
        let digest = TorrentManifestDigest.source(
            name: core.effectiveName,
            contentKind: contentKind,
            infoHashes: hashes,
            pieceLength: core.pieceLength,
            files: files
        )
        return ParsedTorrentManifest(
            manifest: TorrentLogicalManifest(
                name: core.effectiveName,
                contentKind: contentKind,
                infoHashes: hashes,
                pieceLength: core.pieceLength,
                files: files,
                sourceManifestDigest: digest
            ),
            metadata: parsed.metadata,
            infoCore: core,
            envelope: parsed.envelope
        )
    }
}
