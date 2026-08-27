import Foundation
import TorrentBridge
import TorrentEngineModel
import TorrentMetainfo

/// One self-contained, pointer-free metainfo transfer. All multibyte values
/// use little-endian encoding and all variable data is addressed by UInt32
/// ranges into `bytes`.
struct TorrentMetainfoBridgeCapsule: Sendable {
    let bytes: [UInt8]

    init(_ metainfo: ValidatedMetainfo) throws {
        bytes = try Self.encode(
            source: metainfo.metadata,
            core: metainfo.infoCore,
            envelope: metainfo.envelope,
            inputKind: UInt8(TTORRENT_METAINFO_INPUT_TORRENT_FILE)
        )
    }

    init(_ infoDictionary: ValidatedInfoDictionary) throws {
        bytes = try Self.encode(
            source: infoDictionary.bytes,
            core: infoDictionary.infoCore,
            envelope: nil,
            inputKind: UInt8(TTORRENT_METAINFO_INPUT_INFO_DICTIONARY)
        )
    }

    private enum Layout {
        static let magic = 0
        static let schemaVersion = 4
        static let headerSize = 6
        static let totalSize = 8
        static let inputKind = 12
        static let metainfoKind = 13
        static let contentKind = 14
        static let flags = 15
        static let presentFields = 16
        static let pieceLength = 20
        static let infoRange = 24
        static let nameRange = 32
        static let v1HashRange = 40
        static let v2HashRange = 48
        static let v1PieceHashesRange = 56
        static let fileTable = 64
        static let componentTable = 72
        static let trackerTable = 80
        static let webSeedTable = 88
        static let pieceLayerTable = 96
        static let pieceLayerFileIndexTable = 104
        static let commentRange = 112
        static let createdByRange = 120
        static let creationDate = 128
        static let payloadOffset = 136
        static let fileRecordSize = 144
        static let rangeRecordSize = 146
        static let trackerRecordSize = 148
        static let pieceLayerRecordSize = 150
        static let fileIndexRecordSize = 152
        static let headerSizeValue = Int(TTORRENT_METAINFO_CAPSULE_HEADER_SIZE)
        static let fileRecordSizeValue = Int(TTORRENT_METAINFO_CAPSULE_FILE_RECORD_SIZE)
        static let rangeRecordSizeValue = Int(TTORRENT_METAINFO_CAPSULE_RANGE_RECORD_SIZE)
        static let trackerRecordSizeValue = Int(TTORRENT_METAINFO_CAPSULE_TRACKER_RECORD_SIZE)
        static let pieceLayerRecordSizeValue = Int(
            TTORRENT_METAINFO_CAPSULE_PIECE_LAYER_RECORD_SIZE
        )
        static let fileIndexRecordSizeValue = Int(
            TTORRENT_METAINFO_CAPSULE_FILE_INDEX_RECORD_SIZE
        )
    }

    private struct Tables {
        let files: Int
        let components: Int
        let trackers: Int
        let webSeeds: Int
        let pieceLayers: Int
        let pieceLayerFileIndices: Int
        let payload: Int
    }

    private struct ByteRange {
        let offset: UInt32
        let size: UInt32

        static let empty = ByteRange(offset: 0, size: 0)
    }

    private static func encode(
        source: Data,
        core: ValidatedInfoCore,
        envelope: ValidatedTorrentEnvelope?,
        inputKind: UInt8
    ) throws -> [UInt8] {
        let componentCount = try core.files.reduce(into: 0) { count, file in
            count = try checkedAdd(count, file.pathComponents.count)
        }
        let layerFileIndexCount = try (envelope?.pieceLayers ?? []).reduce(into: 0) {
            count,
            layer in
            count = try checkedAdd(count, layer.fileIndices.count)
        }
        let tables = try tableOffsets(
            fileCount: core.files.count,
            componentCount: componentCount,
            trackerCount: envelope?.trackers.count ?? 0,
            webSeedCount: envelope?.webSeeds.count ?? 0,
            pieceLayerCount: envelope?.pieceLayers.count ?? 0,
            pieceLayerFileIndexCount: layerFileIndexCount
        )
        guard tables.payload <= Int(TTORRENT_METAINFO_CAPSULE_MAX_BYTES) else {
            throw capsuleError()
        }

        var output = [UInt8](repeating: 0, count: tables.payload)
        writeHeaderPrefix(
            to: &output,
            tables: tables,
            core: core,
            envelope: envelope,
            inputKind: inputKind,
            componentCount: componentCount,
            layerFileIndexCount: layerFileIndexCount
        )

        let infoBytes = source[core.infoDictionaryRange.range]
        let infoRange = try append(infoBytes, to: &output)
        let nameRange = try append(core.effectiveName.utf8, to: &output)
        let v1HashRange = try append(core.v1InfoHash, to: &output)
        let v2HashRange = try append(core.v2InfoHash, to: &output)
        let v1PieceHashesRange = try translatedInfoRange(
            core.v1PieceHashesRange,
            core: core,
            copiedInfo: infoRange
        )

        var componentIndex = 0
        for (fileIndex, file) in core.files.enumerated() {
            guard file.index == Int32(fileIndex) else {
                throw capsuleError()
            }
            let componentStart = componentIndex
            for component in file.pathComponents {
                let range = try append(component.utf8, to: &output)
                writeRange(
                    range,
                    at: tables.components + componentIndex * Layout.rangeRecordSizeValue,
                    to: &output
                )
                componentIndex = try checkedAdd(componentIndex, 1)
            }

            var flags: UInt32 = 0
            if file.isPadding {
                flags |= UInt32(TTORRENT_METAINFO_FILE_PADDING)
            }
            if file.isExecutable {
                flags |= UInt32(TTORRENT_METAINFO_FILE_EXECUTABLE)
            }
            if file.isHidden {
                flags |= UInt32(TTORRENT_METAINFO_FILE_HIDDEN)
            }
            let root = try translatedInfoRange(
                file.piecesRootRange,
                core: core,
                copiedInfo: infoRange
            )
            let record = tables.files + fileIndex * Layout.fileRecordSizeValue
            write(file.index, at: record, to: &output)
            write(try exactUInt32(componentStart), at: record + 4, to: &output)
            write(try exactUInt32(file.pathComponents.count), at: record + 8, to: &output)
            write(flags, at: record + 12, to: &output)
            write(file.expectedSize, at: record + 16, to: &output)
            writeRange(root, at: record + 24, to: &output)
        }

        if let envelope {
            for (index, tracker) in envelope.trackers.enumerated() {
                let range = try append(tracker.url.utf8, to: &output)
                let record = tables.trackers + index * Layout.trackerRecordSizeValue
                writeRange(range, at: record, to: &output)
                output[record + 8] = tracker.tier
            }
            for (index, webSeed) in envelope.webSeeds.enumerated() {
                let range = try append(webSeed.utf8, to: &output)
                writeRange(
                    range,
                    at: tables.webSeeds + index * Layout.rangeRecordSizeValue,
                    to: &output
                )
            }

            var layerFileIndex = 0
            for (index, layer) in envelope.pieceLayers.enumerated() {
                let root = try append(source[layer.piecesRootRange.range], to: &output)
                let hashes = try append(source[layer.hashesRange.range], to: &output)
                let record = tables.pieceLayers
                    + index * Layout.pieceLayerRecordSizeValue
                writeRange(root, at: record, to: &output)
                writeRange(hashes, at: record + 8, to: &output)
                write(try exactUInt32(layerFileIndex), at: record + 16, to: &output)
                write(try exactUInt32(layer.fileIndices.count), at: record + 20, to: &output)
                for fileIndex in layer.fileIndices {
                    write(
                        fileIndex,
                        at: tables.pieceLayerFileIndices
                            + layerFileIndex * Layout.fileIndexRecordSizeValue,
                        to: &output
                    )
                    layerFileIndex = try checkedAdd(layerFileIndex, 1)
                }
            }

            let commentRange = try append(envelope.comment?.utf8, to: &output)
            let createdByRange = try append(envelope.createdBy?.utf8, to: &output)
            writeRange(commentRange, at: Layout.commentRange, to: &output)
            writeRange(createdByRange, at: Layout.createdByRange, to: &output)
            write(envelope.creationDate ?? -1, at: Layout.creationDate, to: &output)
        }

        writeRange(infoRange, at: Layout.infoRange, to: &output)
        writeRange(nameRange, at: Layout.nameRange, to: &output)
        writeRange(v1HashRange, at: Layout.v1HashRange, to: &output)
        writeRange(v2HashRange, at: Layout.v2HashRange, to: &output)
        writeRange(v1PieceHashesRange, at: Layout.v1PieceHashesRange, to: &output)
        write(try exactUInt32(output.count), at: Layout.totalSize, to: &output)
        guard output.count <= Int(TTORRENT_METAINFO_CAPSULE_MAX_BYTES) else {
            throw capsuleError()
        }
        return output
    }

    private static func writeHeaderPrefix(
        to output: inout [UInt8],
        tables: Tables,
        core: ValidatedInfoCore,
        envelope: ValidatedTorrentEnvelope?,
        inputKind: UInt8,
        componentCount: Int,
        layerFileIndexCount: Int
    ) {
        write(UInt32(TTORRENT_METAINFO_CAPSULE_MAGIC), at: Layout.magic, to: &output)
        write(
            UInt16(TTORRENT_METAINFO_CAPSULE_SCHEMA_VERSION),
            at: Layout.schemaVersion,
            to: &output
        )
        write(UInt16(Layout.headerSizeValue), at: Layout.headerSize, to: &output)
        output[Layout.inputKind] = inputKind
        output[Layout.metainfoKind] = switch core.kind {
        case .v1: UInt8(TTORRENT_METAINFO_KIND_V1)
        case .v2: UInt8(TTORRENT_METAINFO_KIND_V2)
        case .hybrid: UInt8(TTORRENT_METAINFO_KIND_HYBRID)
        }
        output[Layout.contentKind] = switch core.contentKind {
        case .singleFile: UInt8(TTORRENT_CONTENT_KIND_SINGLE_FILE)
        case .directory: UInt8(TTORRENT_CONTENT_KIND_DIRECTORY)
        }
        output[Layout.flags] = core.isPrivate ? UInt8(TTORRENT_METAINFO_PRIVATE) : 0
        write(envelope?.presentFields.rawValue ?? 0, at: Layout.presentFields, to: &output)
        write(UInt32(core.pieceLength), at: Layout.pieceLength, to: &output)
        write(Int64(-1), at: Layout.creationDate, to: &output)
        writeTable(tables.files, count: core.files.count, at: Layout.fileTable, to: &output)
        writeTable(tables.components, count: componentCount, at: Layout.componentTable, to: &output)
        writeTable(
            tables.trackers,
            count: envelope?.trackers.count ?? 0,
            at: Layout.trackerTable,
            to: &output
        )
        writeTable(
            tables.webSeeds,
            count: envelope?.webSeeds.count ?? 0,
            at: Layout.webSeedTable,
            to: &output
        )
        writeTable(
            tables.pieceLayers,
            count: envelope?.pieceLayers.count ?? 0,
            at: Layout.pieceLayerTable,
            to: &output
        )
        writeTable(
            tables.pieceLayerFileIndices,
            count: layerFileIndexCount,
            at: Layout.pieceLayerFileIndexTable,
            to: &output
        )
        write(UInt32(tables.payload), at: Layout.payloadOffset, to: &output)
        write(UInt16(Layout.fileRecordSizeValue), at: Layout.fileRecordSize, to: &output)
        write(UInt16(Layout.rangeRecordSizeValue), at: Layout.rangeRecordSize, to: &output)
        write(UInt16(Layout.trackerRecordSizeValue), at: Layout.trackerRecordSize, to: &output)
        write(
            UInt16(Layout.pieceLayerRecordSizeValue),
            at: Layout.pieceLayerRecordSize,
            to: &output
        )
        write(
            UInt16(Layout.fileIndexRecordSizeValue),
            at: Layout.fileIndexRecordSize,
            to: &output
        )
    }

    private static func tableOffsets(
        fileCount: Int,
        componentCount: Int,
        trackerCount: Int,
        webSeedCount: Int,
        pieceLayerCount: Int,
        pieceLayerFileIndexCount: Int
    ) throws -> Tables {
        var cursor = Layout.headerSizeValue
        let files = try allocateTable(
            cursor: &cursor,
            count: fileCount,
            recordSize: Layout.fileRecordSizeValue,
            alignment: 8
        )
        let components = try allocateTable(
            cursor: &cursor,
            count: componentCount,
            recordSize: Layout.rangeRecordSizeValue,
            alignment: 4
        )
        let trackers = try allocateTable(
            cursor: &cursor,
            count: trackerCount,
            recordSize: Layout.trackerRecordSizeValue,
            alignment: 4
        )
        let webSeeds = try allocateTable(
            cursor: &cursor,
            count: webSeedCount,
            recordSize: Layout.rangeRecordSizeValue,
            alignment: 4
        )
        let pieceLayers = try allocateTable(
            cursor: &cursor,
            count: pieceLayerCount,
            recordSize: Layout.pieceLayerRecordSizeValue,
            alignment: 4
        )
        let pieceLayerFileIndices = try allocateTable(
            cursor: &cursor,
            count: pieceLayerFileIndexCount,
            recordSize: Layout.fileIndexRecordSizeValue,
            alignment: 4
        )
        cursor = try aligned(cursor, to: 8)
        return Tables(
            files: files,
            components: components,
            trackers: trackers,
            webSeeds: webSeeds,
            pieceLayers: pieceLayers,
            pieceLayerFileIndices: pieceLayerFileIndices,
            payload: cursor
        )
    }

    private static func allocateTable(
        cursor: inout Int,
        count: Int,
        recordSize: Int,
        alignment: Int
    ) throws -> Int {
        cursor = try aligned(cursor, to: alignment)
        let result = cursor
        cursor = try checkedAdd(cursor, try checkedMultiply(count, recordSize))
        return result
    }

    private static func aligned(_ value: Int, to alignment: Int) throws -> Int {
        let remainder = value % alignment
        return remainder == 0 ? value : try checkedAdd(value, alignment - remainder)
    }

    private static func checkedAdd(_ left: Int, _ right: Int) throws -> Int {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow, result.partialValue >= 0 else {
            throw capsuleError()
        }
        return result.partialValue
    }

    private static func checkedMultiply(_ left: Int, _ right: Int) throws -> Int {
        let result = left.multipliedReportingOverflow(by: right)
        guard !result.overflow, result.partialValue >= 0 else {
            throw capsuleError()
        }
        return result.partialValue
    }

    private static func translatedInfoRange(
        _ sourceRange: ValidatedMetainfoRange?,
        core: ValidatedInfoCore,
        copiedInfo: ByteRange
    ) throws -> ByteRange {
        guard let sourceRange else {
            return .empty
        }
        let info = core.infoDictionaryRange.range
        let source = sourceRange.range
        guard source.lowerBound >= info.lowerBound,
              source.upperBound <= info.upperBound else {
            throw capsuleError()
        }
        let relative = source.lowerBound - info.lowerBound
        guard let offset = UInt32(exactly: relative),
              offset <= UInt32.max - copiedInfo.offset else {
            throw capsuleError()
        }
        return ByteRange(offset: copiedInfo.offset + offset, size: sourceRange.size)
    }

    private static func append<C: Collection>(
        _ source: C?,
        to output: inout [UInt8]
    ) throws -> ByteRange where C.Element == UInt8 {
        guard let source else {
            return .empty
        }
        guard !source.isEmpty else {
            return .empty
        }
        let offset = try exactUInt32(output.count)
        let size = try exactUInt32(source.count)
        output.append(contentsOf: source)
        guard output.count <= Int(TTORRENT_METAINFO_CAPSULE_MAX_BYTES) else {
            throw capsuleError()
        }
        return ByteRange(offset: offset, size: size)
    }

    private static func exactUInt32(_ value: Int) throws -> UInt32 {
        guard let result = UInt32(exactly: value) else {
            throw capsuleError()
        }
        return result
    }

    private static func writeTable(
        _ offset: Int,
        count: Int,
        at destination: Int,
        to output: inout [UInt8]
    ) {
        write(UInt32(offset), at: destination, to: &output)
        write(UInt32(count), at: destination + 4, to: &output)
    }

    private static func writeRange(
        _ range: ByteRange,
        at destination: Int,
        to output: inout [UInt8]
    ) {
        write(range.offset, at: destination, to: &output)
        write(range.size, at: destination + 4, to: &output)
    }

    private static func write(_ value: UInt16, at offset: Int, to output: inout [UInt8]) {
        output[offset] = UInt8(truncatingIfNeeded: value)
        output[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func write(_ value: UInt32, at offset: Int, to output: inout [UInt8]) {
        for byte in 0..<4 {
            output[offset + byte] = UInt8(truncatingIfNeeded: value >> UInt32(byte * 8))
        }
    }

    private static func write(_ value: Int32, at offset: Int, to output: inout [UInt8]) {
        write(UInt32(bitPattern: value), at: offset, to: &output)
    }

    private static func write(_ value: Int64, at offset: Int, to output: inout [UInt8]) {
        let bits = UInt64(bitPattern: value)
        for byte in 0..<8 {
            output[offset + byte] = UInt8(truncatingIfNeeded: bits >> UInt64(byte * 8))
        }
    }

    private static func capsuleError() -> TorrentEngineError {
        .bridgeError("The validated metainfo exceeds the native capsule format.")
    }
}
