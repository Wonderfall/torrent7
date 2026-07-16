import Foundation
import TorrentEngineModel
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

enum TorrentSourceSecurityInspector {
    static func summary(magnetURI: String) -> TorrentSourceSecuritySummary {
        MagnetSourceParser.summary(magnetURI: magnetURI) ?? .empty
    }
}

private enum MagnetSourceParser {
    private struct SourceURL {
        let isHTTPS: Bool
    }

    private struct Counts {
        var trackers = 0
        var httpsTrackers = 0
        var webSeeds = 0
        var httpsWebSeeds = 0
    }

    static func summary(magnetURI: String) -> TorrentSourceSecuritySummary? {
        guard magnetURI.utf8.count <= TorrentInputLimits.maxMagnetURIBytes,
              magnetURI.range(of: "magnet:?", options: [.caseInsensitive, .anchored]) != nil,
              !containsControlOrWhitespace(magnetURI) else {
            return nil
        }

        let query = magnetURI.dropFirst("magnet:?".count)
        var hasValidInfoHash = false
        var counts = Counts()

        for rawField in query.split(separator: "&", omittingEmptySubsequences: false) {
            let separator = rawField.firstIndex(of: "=")
            let rawName = separator.map { rawField[..<$0] } ?? rawField[...]
            let rawValue = separator.map { rawField[rawField.index(after: $0)...] } ?? ""[...]

            guard let name = formDecoded(rawName),
                  let value = formDecoded(rawValue),
                  !containsControl(name),
                  !containsControl(value) else {
                return nil
            }

            if name.caseInsensitiveCompare("xt") == .orderedSame {
                guard isValidExactTopic(value) else {
                    return nil
                }
                hasValidInfoHash = true
                continue
            }

            if isTrackerParameter(name) {
                guard !value.isEmpty else {
                    continue
                }
                guard let source = validatedSourceURL(value) else {
                    return nil
                }
                counts.trackers += 1
                counts.httpsTrackers += source.isHTTPS ? 1 : 0
                guard counts.trackers <= TorrentEngineLimits.maximumTrackerCount else {
                    return nil
                }
                continue
            }

            if name.caseInsensitiveCompare("ws") == .orderedSame {
                guard !value.isEmpty else {
                    continue
                }
                guard let source = validatedSourceURL(value) else {
                    return nil
                }
                counts.webSeeds += 1
                counts.httpsWebSeeds += source.isHTTPS ? 1 : 0
                guard counts.webSeeds <= TorrentEngineLimits.maximumWebSeedCount else {
                    return nil
                }
            }
        }

        guard hasValidInfoHash else {
            return nil
        }
        return TorrentSourceSecuritySummary(
            trackerCount: counts.trackers,
            httpsTrackerCount: counts.httpsTrackers,
            webSeedCount: counts.webSeeds,
            httpsWebSeedCount: counts.httpsWebSeeds
        )
    }

    private static func isValidExactTopic(_ value: String) -> Bool {
        let prefix = "urn:btih:"
        guard value.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil else {
            return false
        }

        let hash = value.dropFirst(prefix.count)
        if hash.count == 40 {
            return hash.utf8.allSatisfy(isASCIIHexDigit)
        }
        if hash.count == 32 {
            return hash.utf8.allSatisfy { byte in
                switch byte {
                case Character("A").asciiValue!...Character("Z").asciiValue!,
                     Character("a").asciiValue!...Character("z").asciiValue!,
                     Character("2").asciiValue!...Character("7").asciiValue!:
                    true
                default:
                    false
                }
            }
        }
        return false
    }

    private static func isTrackerParameter(_ name: String) -> Bool {
        let lowered = name.lowercased()
        guard lowered.hasPrefix("tr") else {
            return false
        }
        if lowered == "tr" {
            return true
        }
        guard lowered.hasPrefix("tr.") else {
            return false
        }
        return lowered.dropFirst(3).utf8.allSatisfy(isASCIIDigit)
    }

    private static func formDecoded(_ value: Substring) -> String? {
        let input = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)

        var index = 0
        while index < input.count {
            switch input[index] {
            case Character("+").asciiValue:
                output.append(Character(" ").asciiValue!)
                index += 1
            case Character("%").asciiValue:
                guard index + 2 < input.count,
                      let high = hexValue(input[index + 1]),
                      let low = hexValue(input[index + 2]) else {
                    return nil
                }
                output.append((high << 4) | low)
                index += 3
            default:
                output.append(input[index])
                index += 1
            }
        }

        return String(bytes: output, encoding: .utf8)
    }

    private static func validatedSourceURL(_ value: String) -> SourceURL? {
        guard !value.isEmpty,
              !containsControlOrWhitespace(value),
              hasValidPercentEscapes(value),
              !value.contains("\\") else {
            return nil
        }

        guard let schemeEnd = value.range(of: "://")?.lowerBound else {
            return nil
        }
        let scheme = value[..<schemeEnd]
        guard isValidScheme(scheme) else {
            return nil
        }

        let authorityStart = value.index(schemeEnd, offsetBy: 3)
        let authorityEnd = value[authorityStart...].firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? value.endIndex
        let authority = value[authorityStart..<authorityEnd]
        guard isValidAuthority(authority) else {
            return nil
        }

        return SourceURL(isHTTPS: scheme.caseInsensitiveCompare("https") == .orderedSame)
    }

    private static func isValidScheme(_ scheme: Substring) -> Bool {
        guard let first = scheme.utf8.first, isASCIIAlpha(first) else {
            return false
        }
        return scheme.utf8.dropFirst().allSatisfy { byte in
            isASCIIAlpha(byte) || isASCIIDigit(byte)
                || byte == Character("+").asciiValue
                || byte == Character("-").asciiValue
                || byte == Character(".").asciiValue
        }
    }

    private static func isValidAuthority(_ authority: Substring) -> Bool {
        guard !authority.isEmpty else {
            return false
        }

        let atSigns = authority.indices.filter { authority[$0] == "@" }
        guard atSigns.count <= 1 else {
            return false
        }

        let hostAndPort: Substring
        if let atSign = atSigns.first {
            guard atSign != authority.startIndex else {
                return false
            }
            let userInfo = authority[..<atSign]
            guard !userInfo.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" }) else {
                return false
            }
            hostAndPort = authority[authority.index(after: atSign)...]
        } else {
            hostAndPort = authority
        }
        guard !hostAndPort.isEmpty else {
            return false
        }

        if hostAndPort.first == "[" {
            guard let closingBracket = hostAndPort.firstIndex(of: "]"),
                  closingBracket != hostAndPort.index(after: hostAndPort.startIndex) else {
                return false
            }
            let host = hostAndPort[hostAndPort.index(after: hostAndPort.startIndex)..<closingBracket]
            let suffix = hostAndPort[hostAndPort.index(after: closingBracket)...]
            guard isValidIPv6Host(host) else {
                return false
            }
            return suffix.isEmpty || (suffix.first == ":" && isValidPort(suffix.dropFirst()))
        }

        guard !hostAndPort.contains("["), !hostAndPort.contains("]") else {
            return false
        }
        let colonIndices = hostAndPort.indices.filter { hostAndPort[$0] == ":" }
        guard colonIndices.count <= 1 else {
            return false
        }

        let host: Substring
        if let colon = colonIndices.first {
            host = hostAndPort[..<colon]
            guard isValidPort(hostAndPort[hostAndPort.index(after: colon)...]) else {
                return false
            }
        } else {
            host = hostAndPort
        }
        return isValidDNSOrIPv4Host(host)
    }

    private static func isValidPort(_ port: Substring) -> Bool {
        guard !port.isEmpty, port.utf8.allSatisfy(isASCIIDigit), let value = UInt16(port), value != 0 else {
            return false
        }
        return true
    }

    private static func isValidDNSOrIPv4Host(_ host: Substring) -> Bool {
        guard !host.isEmpty,
              host.utf8.count < TorrentEngineLimits.trackerHostCapacity,
              !host.contains("%"),
              host.utf8.allSatisfy({ isASCIIAlpha($0) || isASCIIDigit($0) || $0 == 45 || $0 == 46 }) else {
            return false
        }

        let withoutTrailingDot = host.last == "." ? host.dropLast() : host
        guard !withoutTrailingDot.isEmpty else {
            return false
        }
        if withoutTrailingDot.utf8.allSatisfy({ isASCIIDigit($0) || $0 == 46 }) {
            return isValidIPv4Address(withoutTrailingDot)
        }
        return withoutTrailingDot.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-" else {
                return false
            }
            return true
        }
    }

    private static func isValidIPv6Host(_ host: Substring) -> Bool {
        let zoneSeparator = host.range(of: "%25")
        let address: Substring
        if let zoneSeparator {
            guard host[zoneSeparator.upperBound...].range(of: "%25") == nil else {
                return false
            }
            address = host[..<zoneSeparator.lowerBound]
            let zone = host[zoneSeparator.upperBound...]
            guard !address.isEmpty, isValidIPv6Zone(zone) else {
                return false
            }
        } else {
            address = host
        }
        guard !address.contains("%") else {
            return false
        }
        return isValidIPv6Address(address)
    }

    private static func isValidIPv6Zone(_ zone: Substring) -> Bool {
        guard !zone.isEmpty else {
            return false
        }
        let bytes = Array(zone.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if isASCIIAlpha(byte) || isASCIIDigit(byte) || [45, 46, 95, 126].contains(byte) {
                index += 1
                continue
            }
            guard byte == Character("%").asciiValue,
                  index + 2 < bytes.count,
                  isASCIIHexDigit(bytes[index + 1]),
                  isASCIIHexDigit(bytes[index + 2]) else {
                return false
            }
            index += 3
        }
        return true
    }

    private static func isValidIPv6Address(_ address: Substring) -> Bool {
        guard !address.isEmpty else {
            return false
        }
        let compression = address.range(of: "::")
        if let compression, address[compression.upperBound...].contains("::") {
            return false
        }

        let left = compression.map { address[..<$0.lowerBound] } ?? address[...]
        let right = compression.map { address[$0.upperBound...] } ?? ""[...]
        guard let leftCount = ipv6GroupCount(left), let rightCount = ipv6GroupCount(right) else {
            return false
        }
        let groupCount = leftCount + rightCount
        return compression == nil ? groupCount == 8 : groupCount < 8
    }

    private static func ipv6GroupCount(_ side: Substring) -> Int? {
        guard !side.isEmpty else {
            return 0
        }
        let groups = side.split(separator: ":", omittingEmptySubsequences: false)
        guard groups.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        var count = 0
        for (index, group) in groups.enumerated() {
            if group.contains(".") {
                guard index == groups.index(before: groups.endIndex), isValidIPv4Address(group) else {
                    return nil
                }
                count += 2
            } else {
                guard group.utf8.count <= 4, group.utf8.allSatisfy(isASCIIHexDigit) else {
                    return nil
                }
                count += 1
            }
        }
        return count
    }

    private static func isValidIPv4Address(_ address: Substring) -> Bool {
        let components = address.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else {
            return false
        }
        return components.allSatisfy { component in
            !component.isEmpty
                && component.utf8.allSatisfy(isASCIIDigit)
                && component.count <= 3
                && UInt8(component) != nil
        }
    }

    private static func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private static func containsControlOrWhitespace(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] != Character("%").asciiValue {
                index += 1
                continue
            }
            guard index + 2 < bytes.count,
                  isASCIIHexDigit(bytes[index + 1]),
                  isASCIIHexDigit(bytes[index + 2]) else {
                return false
            }
            index += 3
        }
        return true
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        isASCIIDigit(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57:
            byte - 48
        case 65...70:
            byte - 55
        case 97...102:
            byte - 87
        default:
            nil
        }
    }
}
