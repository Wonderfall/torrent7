import CryptoKit
import Foundation
import TorrentEngineModel

enum TorrentManifestError: LocalizedError, Equatable, Sendable {
    case metadataEmpty
    case metadataTooLarge
    case malformedBencoding
    case nestingLimitExceeded
    case valueLimitExceeded
    case stringLimitExceeded
    case missingInfoDictionary
    case invalidInfoHashes
    case advertisedInfoHashMismatch
    case unsupportedMetadataVersion
    case missingName
    case invalidName
    case invalidPieceLength
    case invalidPieceHashes
    case missingFileTree
    case missingFiles
    case tooManyFiles
    case invalidFileLength
    case invalidFilePath
    case symlinkNotSupported
    case invalidV2PiecesRoot
    case duplicatePath
    case conflictingPath
    case inconsistentHybridLayout
    case emptyPayload

    var errorDescription: String? {
        switch self {
        case .metadataEmpty: "The torrent metadata is empty."
        case .metadataTooLarge: "The torrent metadata exceeds the safe size limit."
        case .malformedBencoding: "The torrent metadata is not canonical bencoding."
        case .nestingLimitExceeded: "The torrent metadata is nested too deeply."
        case .valueLimitExceeded: "The torrent metadata contains too many values."
        case .stringLimitExceeded: "The torrent metadata contains an oversized string."
        case .missingInfoDictionary: "The torrent metadata has no info dictionary."
        case .invalidInfoHashes: "The torrent metadata has no applicable info hash."
        case .advertisedInfoHashMismatch: "The received metadata does not match the advertised info hash."
        case .unsupportedMetadataVersion: "The torrent metadata version is unsupported."
        case .missingName: "The torrent has no usable name."
        case .invalidName: "The torrent name is unsafe."
        case .invalidPieceLength: "The torrent piece length is invalid."
        case .invalidPieceHashes: "The torrent piece hashes do not match its layout."
        case .missingFileTree: "The v2 torrent has no file tree."
        case .missingFiles: "The torrent has no files."
        case .tooManyFiles: "The torrent contains too many files."
        case .invalidFileLength: "A torrent file has an invalid length."
        case .invalidFilePath: "A torrent file has an unsafe path."
        case .symlinkNotSupported: "Torrent symlinks are not supported."
        case .invalidV2PiecesRoot: "A v2 torrent file has an invalid pieces root."
        case .duplicatePath: "The torrent contains duplicate or equivalent file paths."
        case .conflictingPath: "A torrent file path conflicts with another file or directory."
        case .inconsistentHybridLayout: "The v1 and v2 torrent layouts do not match."
        case .emptyPayload: "The torrent payload is empty."
        }
    }
}

struct TorrentAdvertisedInfoHashes: Equatable, Sendable {
    let v1: Data?
    let v2: Data?

    init(v1: Data? = nil, v2: Data? = nil) throws {
        guard v1 == nil || v1?.count == Insecure.SHA1.byteCount,
              v2 == nil || v2?.count == SHA256.byteCount,
              v1 != nil || v2 != nil else {
            throw TorrentManifestError.invalidInfoHashes
        }
        self.v1 = v1
        self.v2 = v2
    }
}

struct TorrentManifestParser: Sendable {
    struct Limits: Equatable, Sendable {
        var maximumMetadataBytes = TorrentInputLimits.maxTorrentFileBytes
        var maximumNestingDepth = 32
        var maximumValueCount = 400_000
        var maximumStringBytes = TorrentInputLimits.maxTorrentFileBytes
        var maximumPathComponentBytes = 255
        var maximumPathDepth = 32
        var maximumFileCount = TorrentEngineLimits.maximumFileCount

        static let standard = Limits()
    }

    private let limits: Limits

    init(limits: Limits = .standard) {
        self.limits = limits
    }

    func parse(
        _ metadata: Data,
        advertisedHashes: TorrentAdvertisedInfoHashes? = nil
    ) throws -> ParsedTorrentManifest {
        guard !metadata.isEmpty else {
            throw TorrentManifestError.metadataEmpty
        }
        guard metadata.count <= limits.maximumMetadataBytes else {
            throw TorrentManifestError.metadataTooLarge
        }

        var decoder = BencodeDecoder(data: metadata, limits: limits)
        let root = try decoder.decode()
        guard case .dictionary(let topLevel, _) = root else {
            throw TorrentManifestError.malformedBencoding
        }
        guard let info = value(named: "info", in: topLevel),
              case .dictionary(let infoValues, let infoRange) = info else {
            throw TorrentManifestError.missingInfoDictionary
        }

        let rawInfo = metadata.subdata(in: infoRange)
        let version = try optionalInteger(named: "meta version", in: infoValues)
        guard version == nil || version == 2 else {
            throw TorrentManifestError.unsupportedMetadataVersion
        }
        let hasV2 = version == 2
        let hasV1Layout = value(named: "files", in: infoValues) != nil
            || value(named: "length", in: infoValues) != nil
        guard hasV1Layout || hasV2 else {
            throw TorrentManifestError.missingFiles
        }

        let v1Hash = hasV1Layout ? Data(Insecure.SHA1.hash(data: rawInfo)) : nil
        let v2Hash = hasV2 ? Data(SHA256.hash(data: rawInfo)) : nil
        let hashes = try TorrentStorageInfoHashes(v1: v1Hash, v2: v2Hash)
        try verify(advertisedHashes, against: hashes)

        let pieceLength = try requiredInteger(named: "piece length", in: infoValues)
        guard pieceLength > 0, pieceLength <= 128 * 1_024 * 1_024 else {
            throw TorrentManifestError.invalidPieceLength
        }
        if hasV2 {
            guard pieceLength >= 16 * 1_024,
                  pieceLength.nonzeroBitCount == 1 else {
                throw TorrentManifestError.invalidPieceLength
            }
        }

        let parsedName = try parseOptionalName(infoValues)
        let v1Layout = hasV1Layout
            ? try parseV1Layout(infoValues, name: parsedName)
            : nil
        let v2Layout = hasV2
            ? try parseV2Layout(infoValues, name: parsedName, pieceLength: pieceLength)
            : nil

        let selected: ParsedLayout
        if let v1Layout, let v2Layout {
            selected = try validateHybrid(v1: v1Layout, v2: v2Layout)
        } else if let v1Layout {
            selected = v1Layout
        } else if let v2Layout {
            selected = v2Layout
        } else {
            throw TorrentManifestError.missingFiles
        }

        guard selected.files.count <= limits.maximumFileCount else {
            throw TorrentManifestError.tooManyFiles
        }
        guard selected.files.contains(where: { $0.expectedSize > 0 && !$0.isPadding }) else {
            throw TorrentManifestError.emptyPayload
        }
        try validatePathSet(selected.files)
        if hasV1Layout {
            try validateV1PieceHashes(
                infoValues,
                totalSize: selected.files.reduce(into: Int64(0)) {
                    $0 = tryAdding($0, $1.expectedSize)
                },
                pieceLength: pieceLength
            )
        }

        let name: String
        if let parsedName {
            name = parsedName
        } else if hasV2, let v2Hash {
            name = "Torrent-" + Self.hex(v2Hash.prefix(6))
        } else {
            throw TorrentManifestError.missingName
        }
        try validateComponent(name, isTopLevel: true)

        let indexed = selected.files.enumerated().map { offset, file in
            TorrentLogicalFile(
                index: Int32(offset),
                pathComponents: file.pathComponents,
                expectedSize: file.expectedSize,
                isPadding: file.isPadding
            )
        }
        let digest = TorrentManifestDigest.source(
            name: name,
            contentKind: selected.contentKind,
            infoHashes: hashes,
            pieceLength: pieceLength,
            files: indexed
        )
        return ParsedTorrentManifest(
            manifest: TorrentLogicalManifest(
                name: name,
                contentKind: selected.contentKind,
                infoHashes: hashes,
                pieceLength: pieceLength,
                files: indexed,
                sourceManifestDigest: digest
            ),
            rawInfoDictionary: rawInfo
        )
    }

    private struct UnindexedFile: Equatable {
        var pathComponents: [String]
        let expectedSize: Int64
        let isPadding: Bool
    }

    private struct ParsedLayout {
        let contentKind: TorrentStorageContentKind
        let files: [UnindexedFile]
    }

    private func parseV1Layout(
        _ info: [BencodeEntry],
        name: String?
    ) throws -> ParsedLayout {
        if let filesNode = value(named: "files", in: info) {
            guard let name else {
                throw TorrentManifestError.missingName
            }
            try validateComponent(name, isTopLevel: true)
            guard case .list(let entries, _) = filesNode, !entries.isEmpty else {
                throw TorrentManifestError.missingFiles
            }
            guard entries.count <= limits.maximumFileCount else {
                throw TorrentManifestError.tooManyFiles
            }
            var files = [UnindexedFile]()
            files.reserveCapacity(entries.count)
            for entry in entries {
                guard case .dictionary(let dictionary, _) = entry else {
                    throw TorrentManifestError.malformedBencoding
                }
                let size = try requiredInteger(named: "length", in: dictionary)
                guard size >= 0 else {
                    throw TorrentManifestError.invalidFileLength
                }
                let attributes = try optionalStringData(named: "attr", in: dictionary)
                if attributes?.contains(UInt8(ascii: "l")) == true
                    || value(named: "symlink path", in: dictionary) != nil {
                    throw TorrentManifestError.symlinkNotSupported
                }
                let isPadding = attributes?.contains(UInt8(ascii: "p")) == true
                let components: [String]
                if isPadding {
                    // Libtorrent canonicalizes padding entries to this
                    // synthetic logical path regardless of the source path.
                    components = [".pad", "\(size)-\(files.count)"]
                } else {
                    let pathNode = value(named: "path.utf-8", in: dictionary)
                        ?? value(named: "path", in: dictionary)
                    guard let pathNode else {
                        throw TorrentManifestError.invalidFilePath
                    }
                    components = try parsePathList(pathNode)
                }
                files.append(UnindexedFile(
                    pathComponents: components,
                    expectedSize: size,
                    isPadding: isPadding
                ))
            }
            return ParsedLayout(contentKind: .directory, files: files)
        }

        guard let name else {
            throw TorrentManifestError.missingName
        }
        try validateComponent(name, isTopLevel: true)
        let size = try requiredInteger(named: "length", in: info)
        guard size >= 0 else {
            throw TorrentManifestError.invalidFileLength
        }
        let attributes = try optionalStringData(named: "attr", in: info)
        if attributes?.contains(UInt8(ascii: "l")) == true
            || value(named: "symlink path", in: info) != nil {
            throw TorrentManifestError.symlinkNotSupported
        }
        guard attributes?.contains(UInt8(ascii: "p")) != true else {
            throw TorrentManifestError.invalidFilePath
        }
        return ParsedLayout(
            contentKind: .singleFile,
            files: [UnindexedFile(
                pathComponents: [name],
                expectedSize: size,
                isPadding: false
            )]
        )
    }

    private func parseV2Layout(
        _ info: [BencodeEntry],
        name: String?,
        pieceLength: Int64
    ) throws -> ParsedLayout {
        guard let treeNode = value(named: "file tree", in: info),
              case .dictionary(let tree, _) = treeNode else {
            throw TorrentManifestError.missingFileTree
        }

        var rawFiles = [UnindexedFile]()
        try walkV2Tree(tree, path: [], files: &rawFiles)
        guard !rawFiles.isEmpty else {
            throw TorrentManifestError.missingFiles
        }

        let realFileCount = rawFiles.count
        // Rootless v2 metadata has no libtorrent top-level name. Even a
        // one-leaf tree is therefore a directory layout with a synthetic,
        // digest-derived destination name.
        let isSingleFile = name != nil
            && realFileCount == 1
            && rawFiles[0].pathComponents.count == 1
        if isSingleFile, let name,
           normalizedComponent(name) != normalizedComponent(rawFiles[0].pathComponents[0]) {
            throw TorrentManifestError.inconsistentHybridLayout
        }

        var files = [UnindexedFile]()
        files.reserveCapacity(min(limits.maximumFileCount, rawFiles.count * 2))
        for file in rawFiles {
            guard files.count < limits.maximumFileCount else {
                throw TorrentManifestError.tooManyFiles
            }
            files.append(file)
            let remainder = file.expectedSize % pieceLength
            if remainder != 0 {
                guard files.count < limits.maximumFileCount else {
                    throw TorrentManifestError.tooManyFiles
                }
                let padSize = pieceLength - remainder
                files.append(UnindexedFile(
                    pathComponents: [".pad", "\(padSize)-\(files.count)"],
                    expectedSize: padSize,
                    isPadding: true
                ))
            }
        }

        return ParsedLayout(
            contentKind: isSingleFile ? .singleFile : .directory,
            files: files
        )
    }

    private func walkV2Tree(
        _ entries: [BencodeEntry],
        path: [String],
        files: inout [UnindexedFile]
    ) throws {
        guard path.count < limits.maximumPathDepth else {
            throw TorrentManifestError.invalidFilePath
        }
        for entry in entries {
            let component = try string(entry.key)
            guard !component.isEmpty else {
                throw TorrentManifestError.malformedBencoding
            }
            try validateComponent(component)
            guard case .dictionary(let child, _) = entry.value else {
                throw TorrentManifestError.malformedBencoding
            }
            let nextPath = path + [component]
            if child.count == 1, child[0].keyData.isEmpty {
                guard case .dictionary(let properties, _) = child[0].value else {
                    throw TorrentManifestError.malformedBencoding
                }
                let attributes = try optionalStringData(named: "attr", in: properties)
                if attributes?.contains(UInt8(ascii: "l")) == true
                    || value(named: "symlink path", in: properties) != nil {
                    throw TorrentManifestError.symlinkNotSupported
                }
                guard attributes?.contains(UInt8(ascii: "p")) != true else {
                    throw TorrentManifestError.invalidFilePath
                }
                let size = try requiredInteger(named: "length", in: properties)
                guard size >= 0 else {
                    throw TorrentManifestError.invalidFileLength
                }
                if size > 0 {
                    guard let root = try optionalStringData(named: "pieces root", in: properties),
                          root.count == SHA256.byteCount,
                          root.contains(where: { $0 != 0 }) else {
                        throw TorrentManifestError.invalidV2PiecesRoot
                    }
                } else if let root = try optionalStringData(named: "pieces root", in: properties),
                          root.count != SHA256.byteCount {
                    throw TorrentManifestError.invalidV2PiecesRoot
                }
                files.append(UnindexedFile(
                    pathComponents: nextPath,
                    expectedSize: size,
                    isPadding: false
                ))
                guard files.count <= limits.maximumFileCount else {
                    throw TorrentManifestError.tooManyFiles
                }
            } else {
                guard !child.isEmpty,
                      !child.contains(where: { $0.keyData.isEmpty }) else {
                    throw TorrentManifestError.malformedBencoding
                }
                try walkV2Tree(child, path: nextPath, files: &files)
            }
        }
    }

    private func validateHybrid(
        v1: ParsedLayout,
        v2: ParsedLayout
    ) throws -> ParsedLayout {
        var v2Files = v2.files
        if v2Files.count == v1.files.count + 1,
           v2Files.last?.isPadding == true {
            v2Files.removeLast()
        }
        guard v1.contentKind == v2.contentKind,
              v1.files.count == v2Files.count else {
            throw TorrentManifestError.inconsistentHybridLayout
        }
        for (left, right) in zip(v1.files, v2Files) {
            guard left.expectedSize == right.expectedSize,
                  left.isPadding == right.isPadding else {
                throw TorrentManifestError.inconsistentHybridLayout
            }
            if !left.isPadding {
                guard normalizedPath(left.pathComponents)
                        == normalizedPath(right.pathComponents) else {
                    throw TorrentManifestError.inconsistentHybridLayout
                }
            }
        }
        return ParsedLayout(contentKind: v2.contentKind, files: v2Files)
    }

    private func validateV1PieceHashes(
        _ info: [BencodeEntry],
        totalSize: Int64,
        pieceLength: Int64
    ) throws {
        guard let pieces = try optionalStringData(named: "pieces", in: info) else {
            throw TorrentManifestError.invalidPieceHashes
        }
        let pieceCount = totalSize == 0 ? 0 : (totalSize - 1) / pieceLength + 1
        guard pieceCount <= Int64(Int.max / Insecure.SHA1.byteCount),
              pieces.count == Int(pieceCount) * Insecure.SHA1.byteCount else {
            throw TorrentManifestError.invalidPieceHashes
        }
    }

    private func validatePathSet(_ files: [UnindexedFile]) throws {
        var exact = Set<String>()
        var normalized = Set<String>()
        var exactPrefixes = Set<String>()
        var normalizedPrefixes = Set<String>()

        for file in files where !file.isPadding {
            guard !file.pathComponents.isEmpty,
                  file.pathComponents.count <= limits.maximumPathDepth else {
                throw TorrentManifestError.invalidFilePath
            }
            for component in file.pathComponents {
                try validateComponent(component)
            }
            let exactPath = file.pathComponents.joined(separator: "\0")
            let normalizedFilePath = normalizedPath(file.pathComponents).joined(separator: "\0")
            guard exact.insert(exactPath).inserted,
                  normalized.insert(normalizedFilePath).inserted else {
                throw TorrentManifestError.duplicatePath
            }
            guard !exactPrefixes.contains(exactPath),
                  !normalizedPrefixes.contains(normalizedFilePath) else {
                throw TorrentManifestError.conflictingPath
            }
            for end in 1..<file.pathComponents.count {
                let exactPrefix = file.pathComponents[..<end].joined(separator: "\0")
                let normalizedPrefix = normalizedPath(file.pathComponents[..<end])
                    .joined(separator: "\0")
                guard !exact.contains(exactPrefix),
                      !normalized.contains(normalizedPrefix) else {
                    throw TorrentManifestError.conflictingPath
                }
                exactPrefixes.insert(exactPrefix)
                normalizedPrefixes.insert(normalizedPrefix)
            }
        }
    }

    private func parsePathList(_ node: BencodeNode) throws -> [String] {
        guard case .list(let nodes, _) = node,
              !nodes.isEmpty,
              nodes.count <= limits.maximumPathDepth else {
            throw TorrentManifestError.invalidFilePath
        }
        return try nodes.map { node in
            guard case .string(let data, _) = node else {
                throw TorrentManifestError.invalidFilePath
            }
            let component = try string(data)
            try validateComponent(component)
            return component
        }
    }

    private func parseOptionalName(_ info: [BencodeEntry]) throws -> String? {
        guard let node = value(named: "name.utf-8", in: info)
            ?? value(named: "name", in: info) else {
            return nil
        }
        guard case .string(let data, _) = node else {
            throw TorrentManifestError.invalidName
        }
        let name = try string(data)
        try validateComponent(name, isTopLevel: true)
        return name
    }

    private func validateComponent(
        _ component: String,
        isTopLevel: Bool = false
    ) throws {
        let byteCount = component.utf8.count
        guard !component.isEmpty,
              byteCount <= limits.maximumPathComponentBytes,
              component != ".",
              component != "..",
              !component.utf8.contains(0),
              !component.contains("/"),
              !component.contains("\\") else {
            throw isTopLevel
                ? TorrentManifestError.invalidName
                : TorrentManifestError.invalidFilePath
        }
    }

    private func verify(
        _ advertised: TorrentAdvertisedInfoHashes?,
        against actual: TorrentStorageInfoHashes
    ) throws {
        guard let advertised else {
            return
        }
        if let expected = advertised.v1, actual.v1 != expected {
            throw TorrentManifestError.advertisedInfoHashMismatch
        }
        if let expected = advertised.v2, actual.v2 != expected {
            throw TorrentManifestError.advertisedInfoHashMismatch
        }
    }

    private func normalizedPath<S: Collection>(_ components: S) -> [String]
    where S.Element == String {
        components.map(normalizedComponent)
    }

    private func normalizedComponent(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let alphabet = Array("0123456789abcdef".utf8)
        var result = [UInt8]()
        for byte in bytes {
            result.append(alphabet[Int(byte >> 4)])
            result.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: result, as: UTF8.self)
    }

    private func tryAdding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }

    private func value(named name: String, in entries: [BencodeEntry]) -> BencodeNode? {
        let key = Data(name.utf8)
        return entries.first(where: { $0.keyData == key })?.value
    }

    private func requiredInteger(
        named name: String,
        in entries: [BencodeEntry]
    ) throws -> Int64 {
        guard let value = value(named: name, in: entries),
              case .integer(let integer, _) = value else {
            throw TorrentManifestError.malformedBencoding
        }
        return integer
    }

    private func optionalInteger(
        named name: String,
        in entries: [BencodeEntry]
    ) throws -> Int64? {
        guard let value = value(named: name, in: entries) else {
            return nil
        }
        guard case .integer(let integer, _) = value else {
            throw TorrentManifestError.malformedBencoding
        }
        return integer
    }

    private func optionalStringData(
        named name: String,
        in entries: [BencodeEntry]
    ) throws -> Data? {
        guard let value = value(named: name, in: entries) else {
            return nil
        }
        guard case .string(let data, _) = value else {
            throw TorrentManifestError.malformedBencoding
        }
        return data
    }

    private func string(_ data: Data) throws -> String {
        guard let string = String(data: data, encoding: .utf8) else {
            throw TorrentManifestError.invalidFilePath
        }
        return string
    }
}

private struct BencodeEntry {
    let keyData: Data
    let key: Data
    let value: BencodeNode
}

private indirect enum BencodeNode {
    case string(Data, Range<Int>)
    case integer(Int64, Range<Int>)
    case list([BencodeNode], Range<Int>)
    case dictionary([BencodeEntry], Range<Int>)
}

private struct BencodeDecoder {
    private let data: Data
    private let limits: TorrentManifestParser.Limits
    private var offset = 0
    private var valueCount = 0

    init(data: Data, limits: TorrentManifestParser.Limits) {
        self.data = data
        self.limits = limits
    }

    mutating func decode() throws -> BencodeNode {
        let node = try decodeValue(depth: 0)
        guard offset == data.count else {
            throw TorrentManifestError.malformedBencoding
        }
        return node
    }

    private mutating func decodeValue(depth: Int) throws -> BencodeNode {
        guard depth <= limits.maximumNestingDepth else {
            throw TorrentManifestError.nestingLimitExceeded
        }
        valueCount += 1
        guard valueCount <= limits.maximumValueCount,
              offset < data.count else {
            throw valueCount > limits.maximumValueCount
                ? TorrentManifestError.valueLimitExceeded
                : TorrentManifestError.malformedBencoding
        }

        switch data[offset] {
        case UInt8(ascii: "i"):
            return try decodeInteger()
        case UInt8(ascii: "l"):
            return try decodeList(depth: depth)
        case UInt8(ascii: "d"):
            return try decodeDictionary(depth: depth)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try decodeString()
        default:
            throw TorrentManifestError.malformedBencoding
        }
    }

    private mutating func decodeInteger() throws -> BencodeNode {
        let start = offset
        offset += 1
        let numberStart = offset
        while offset < data.count, data[offset] != UInt8(ascii: "e") {
            offset += 1
        }
        guard offset < data.count, offset > numberStart else {
            throw TorrentManifestError.malformedBencoding
        }
        let bytes = data.subdata(in: numberStart..<offset)
        guard let text = String(data: bytes, encoding: .ascii),
              text != "-0",
              !(text.hasPrefix("0") && text.count > 1),
              !(text.hasPrefix("-0")),
              text.allSatisfy({ $0 == "-" || $0.isNumber }),
              text.filter({ $0 == "-" }).count <= 1,
              !text.dropFirst().contains("-"),
              let value = Int64(text) else {
            throw TorrentManifestError.malformedBencoding
        }
        offset += 1
        return .integer(value, start..<offset)
    }

    private mutating func decodeString() throws -> BencodeNode {
        let start = offset
        let lengthStart = offset
        while offset < data.count, data[offset] != UInt8(ascii: ":") {
            guard data[offset] >= UInt8(ascii: "0"),
                  data[offset] <= UInt8(ascii: "9") else {
                throw TorrentManifestError.malformedBencoding
            }
            offset += 1
        }
        guard offset < data.count, offset > lengthStart else {
            throw TorrentManifestError.malformedBencoding
        }
        let lengthBytes = data.subdata(in: lengthStart..<offset)
        guard let lengthText = String(data: lengthBytes, encoding: .ascii),
              !(lengthText.hasPrefix("0") && lengthText.count > 1),
              let length = Int(lengthText),
              length <= limits.maximumStringBytes else {
            if Int(String(data: lengthBytes, encoding: .ascii) ?? "")
                .map({ $0 > limits.maximumStringBytes }) == true {
                throw TorrentManifestError.stringLimitExceeded
            }
            throw TorrentManifestError.malformedBencoding
        }
        offset += 1
        guard length <= data.count - offset else {
            throw TorrentManifestError.malformedBencoding
        }
        let bytes = data.subdata(in: offset..<(offset + length))
        offset += length
        return .string(bytes, start..<offset)
    }

    private mutating func decodeList(depth: Int) throws -> BencodeNode {
        let start = offset
        offset += 1
        var values = [BencodeNode]()
        while offset < data.count, data[offset] != UInt8(ascii: "e") {
            values.append(try decodeValue(depth: depth + 1))
        }
        guard offset < data.count else {
            throw TorrentManifestError.malformedBencoding
        }
        offset += 1
        return .list(values, start..<offset)
    }

    private mutating func decodeDictionary(depth: Int) throws -> BencodeNode {
        let start = offset
        offset += 1
        var entries = [BencodeEntry]()
        var previousKey: Data?
        while offset < data.count, data[offset] != UInt8(ascii: "e") {
            let keyNode = try decodeString()
            guard case .string(let key, _) = keyNode,
                  previousKey.map({ $0.lexicographicallyPrecedes(key) }) ?? true else {
                throw TorrentManifestError.malformedBencoding
            }
            previousKey = key
            let value = try decodeValue(depth: depth + 1)
            entries.append(BencodeEntry(keyData: key, key: key, value: value))
        }
        guard offset < data.count else {
            throw TorrentManifestError.malformedBencoding
        }
        offset += 1
        return .dictionary(entries, start..<offset)
    }
}
