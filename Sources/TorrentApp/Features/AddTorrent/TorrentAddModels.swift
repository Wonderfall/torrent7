import Foundation
import UniformTypeIdentifiers

let bittorrentFileType = UTType(importedAs: "org.bittorrent.torrent", conformingTo: .data)

enum FileImportMode {
    case torrentFiles
    case downloadFolder

    var allowedContentTypes: [UTType] {
        switch self {
        case .torrentFiles:
            return [bittorrentFileType]
        case .downloadFolder:
            return [.folder]
        }
    }

    var allowsMultipleSelection: Bool {
        self == .torrentFiles
    }
}

struct TorrentAddDraft: Identifiable, Equatable {
    enum Source: Equatable {
        case torrentFile(URL)
        case magnet(String)
    }

    let id = UUID()
    let source: Source

    var fileURL: URL? {
        guard case .torrentFile(let url) = source else {
            return nil
        }
        return url
    }

    var magnetURI: String? {
        guard case .magnet(let uri) = source else {
            return nil
        }
        return uri
    }

    var title: String {
        switch source {
        case .torrentFile(let url):
            return url.deletingPathExtension().lastPathComponent
        case .magnet:
            return "Magnet Link"
        }
    }
}

enum TorrentAddSourceParser {
    static func magnetDraft(from value: String) -> TorrentAddDraft? {
        let magnet = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard magnet.utf8.count <= TorrentInputLimits.maxMagnetURIBytes else {
            return nil
        }
        guard magnet.range(of: "magnet:?", options: [.caseInsensitive, .anchored]) != nil else {
            return nil
        }

        let canonicalMagnet = "magnet:" + String(magnet.dropFirst("magnet:".count))
        return TorrentAddDraft(source: .magnet(canonicalMagnet))
    }

    static func torrentFileDrafts(from urls: [URL]) -> [TorrentAddDraft] {
        urls
            .filter { $0.pathExtension.caseInsensitiveCompare("torrent") == .orderedSame }
            .map { TorrentAddDraft(source: .torrentFile($0)) }
    }
}

struct TorrentAddOptions {
    let downloadFolder: URL
    let torrentData: Data?
    let filePriorities: [Int32: TorrentFilePriority]?
    let movesTorrentFileToTrash: Bool
    let setsDownloadFolderAsDefault: Bool
    let startsPaused: Bool
    let queuePriority: TorrentQueuePriority
    let labelIDs: Set<TorrentLabel.ID>
    let allowsPreMetadataDHT: Bool
}

struct TorrentSourceSecuritySummary: Equatable, Sendable {
    let trackerCount: Int
    let httpsTrackerCount: Int
    let webSeedCount: Int
    let httpsWebSeedCount: Int

    var sourceCount: Int {
        trackerCount + webSeedCount
    }

    var httpsSourceCount: Int {
        httpsTrackerCount + httpsWebSeedCount
    }

    var nonHTTPSSourceCount: Int {
        max(0, sourceCount - httpsSourceCount)
    }

    var nonHTTPSTrackerCount: Int {
        max(0, trackerCount - httpsTrackerCount)
    }

    var nonHTTPSWebSeedCount: Int {
        max(0, webSeedCount - httpsWebSeedCount)
    }

    var hasHTTPSSources: Bool {
        httpsSourceCount > 0
    }

    var hasNonHTTPSSources: Bool {
        nonHTTPSSourceCount > 0
    }

    var hasNonHTTPSTrackers: Bool {
        nonHTTPSTrackerCount > 0
    }

    var hasNonHTTPSWebSeeds: Bool {
        nonHTTPSWebSeedCount > 0
    }

    var needsTrackerExceptionPrompt: Bool {
        trackerCount > 0 && httpsTrackerCount == 0
    }

    var needsWebSeedExceptionPrompt: Bool {
        webSeedCount > 0 && httpsWebSeedCount == 0
    }

    static let empty = TorrentSourceSecuritySummary(
        trackerCount: 0,
        httpsTrackerCount: 0,
        webSeedCount: 0,
        httpsWebSeedCount: 0
    )
}

enum TorrentSourceSecurityParser {
    // Mirror libtorrent's byte-level magnet and tracker parsing so consent
    // decisions cannot diverge through URL normalization.
    private static let magnetPrefix = Array("magnet:?".utf8)
    private static let trackerName = Array("tr".utf8)
    private static let webSeedName = Array("ws".utf8)
    private static let httpScheme = Array("http".utf8)
    private static let httpsScheme = Array("https".utf8)
    private static let udpScheme = Array("udp".utf8)

    static func summary(magnetURI: String) -> TorrentSourceSecuritySummary {
        let bytes = Array(magnetURI.utf8)
        guard bytes.starts(with: magnetPrefix) else {
            return .empty
        }

        var trackerCount = 0
        var httpsTrackerCount = 0
        var webSeedCount = 0
        var httpsWebSeedCount = 0
        var remainder = bytes.dropFirst(magnetPrefix.count)
        while !remainder.isEmpty {
            let name = removePrefix(from: &remainder, through: 0x3d)
            let value = removePrefix(from: &remainder, through: 0x26)
            guard let decodedValue = percentDecode(value) else {
                continue
            }
            if matchesParameter(name, trackerName), let scheme = usableTrackerScheme(decodedValue) {
                trackerCount += 1
                httpsTrackerCount += scheme == "https" ? 1 : 0
            } else if matchesParameter(name, webSeedName) {
                webSeedCount += 1
                httpsWebSeedCount += isHTTPSURL(decodedValue) ? 1 : 0
            }
        }

        return TorrentSourceSecuritySummary(
            trackerCount: trackerCount,
            httpsTrackerCount: httpsTrackerCount,
            webSeedCount: webSeedCount,
            httpsWebSeedCount: httpsWebSeedCount
        )
    }

    private static func removePrefix(
        from remainder: inout ArraySlice<UInt8>,
        through separator: UInt8
    ) -> ArraySlice<UInt8> {
        guard let separatorIndex = remainder.firstIndex(of: separator) else {
            let prefix = remainder
            remainder = remainder[remainder.endIndex...]
            return prefix
        }
        let prefix = remainder[..<separatorIndex]
        remainder = remainder[remainder.index(after: separatorIndex)...]
        return prefix
    }

    private static func matchesParameter(_ rawName: ArraySlice<UInt8>, _ expected: [UInt8]) -> Bool {
        var name = rawName
        if let period = name.firstIndex(of: 0x2e) {
            let suffix = name[name.index(after: period)...]
            if suffix.allSatisfy({ isDigit($0) }) {
                name = name[..<period]
            }
        }
        return asciiEqual(name, expected)
    }

    private static func percentDecode(_ encoded: ArraySlice<UInt8>) -> [UInt8]? {
        let input = Array(encoded)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            switch input[index] {
            case 0x2b:
                decoded.append(0x20)
                index += 1
            case 0x25:
                guard index + 2 < input.count,
                      let high = hexValue(input[index + 1]),
                      let low = hexValue(input[index + 2])
                else {
                    return nil
                }
                decoded.append(high * 16 + low)
                index += 3
            default:
                decoded.append(input[index])
                index += 1
            }
        }
        return decoded
    }

    private static func usableTrackerScheme(_ url: [UInt8]) -> String? {
        guard !url.isEmpty,
              url.allSatisfy({ $0 > 0x20 && $0 != 0x7f }),
              let schemeEnd = url.firstIndex(of: 0x3a),
              schemeEnd + 2 < url.count,
              url[schemeEnd + 1] == 0x2f,
              url[schemeEnd + 2] == 0x2f,
              hasValidAuthority(url, startingAt: schemeEnd + 3)
        else {
            return nil
        }

        let scheme = url[..<schemeEnd]
        if asciiEqual(scheme, httpScheme) {
            return "http"
        }
        if asciiEqual(scheme, httpsScheme) {
            return "https"
        }
        if asciiEqual(scheme, udpScheme) {
            return "udp"
        }
        return nil
    }

    private static func hasValidAuthority(_ url: [UInt8], startingAt authorityStart: Int) -> Bool {
        let authorityEnd = url[authorityStart...].firstIndex(where: {
            $0 == 0x2f || $0 == 0x3f || $0 == 0x23
        }) ?? url.endIndex
        let firstAt = url[authorityStart...].firstIndex(of: 0x40)
        let firstColon = url[authorityStart...].firstIndex(of: 0x3a)
        let hostnameStart: Int
        if let firstAt, let firstColon, firstColon < firstAt, firstAt < authorityEnd {
            hostnameStart = firstAt + 1
        } else {
            hostnameStart = authorityStart
        }

        let hostname: ArraySlice<UInt8>
        let portStart: Int?
        let isBracketed: Bool
        if hostnameStart < url.endIndex, url[hostnameStart] == 0x5b {
            guard let closingBracket = url[hostnameStart...].firstIndex(of: 0x5d) else {
                return false
            }
            hostname = url[(hostnameStart + 1)..<closingBracket]
            let portColon = url[closingBracket...].firstIndex(of: 0x3a)
            portStart = portColon.flatMap { $0 < authorityEnd ? $0 + 1 : nil }
            isBracketed = true
        } else {
            let portColon = url[hostnameStart...].firstIndex(of: 0x3a)
            let hostnameEnd = portColon.flatMap { $0 < authorityEnd ? $0 : nil } ?? authorityEnd
            hostname = url[hostnameStart..<hostnameEnd]
            portStart = portColon.flatMap { $0 < authorityEnd ? $0 + 1 : nil }
            isBracketed = false
        }

        guard !hostname.isEmpty,
              hostname.allSatisfy({ isValidHostnameByte($0, isBracketed: isBracketed) })
        else {
            return false
        }
        return portStart.map { url[$0..<authorityEnd].allSatisfy(isDigit) } ?? true
    }

    private static func isHTTPSURL(_ url: [UInt8]) -> Bool {
        guard let schemeEnd = url.firstIndex(of: 0x3a) else {
            return false
        }
        return asciiEqual(url[..<schemeEnd], httpsScheme)
    }

    private static func isValidHostnameByte(_ byte: UInt8, isBracketed: Bool) -> Bool {
        isDigit(byte)
            || (0x41 ... 0x5a).contains(byte)
            || (0x61 ... 0x7a).contains(byte)
            || byte == 0x2d
            || byte == 0x2e
            || (isBracketed && (byte == 0x25 || byte == 0x3a || byte == 0x5f || byte == 0x7e))
    }

    private static func asciiEqual(_ lhs: ArraySlice<UInt8>, _ rhs: [UInt8]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            asciiLowercase($0.0) == asciiLowercase($0.1)
        }
    }

    private static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        (0x41 ... 0x5a).contains(byte) ? byte + 0x20 : byte
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30 ... 0x39: byte - 0x30
        case 0x41 ... 0x46: byte - 0x41 + 10
        case 0x61 ... 0x66: byte - 0x61 + 10
        default: nil
        }
    }
}
