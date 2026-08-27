import Foundation
import TorrentEngineModel

package enum ParsedMagnetError: LocalizedError, Equatable, Sendable {
    case invalidURI
    case missingInfoHash
    case unsupportedExactTopic
    case conflictingInfoHashes
    case tooManyParameters
    case tooManyTrackers
    case tooManyWebSeeds
    case displayNameTooLong
    case invalidSourceURL
    case invalidFileSelection
    case fileSelectionTooComplex

    package var errorDescription: String? {
        switch self {
        case .invalidURI:
            "The magnet link is malformed."
        case .missingInfoHash:
            "The magnet link has no supported BitTorrent info hash."
        case .unsupportedExactTopic:
            "The magnet link contains an unsupported exact topic."
        case .conflictingInfoHashes:
            "The magnet link advertises conflicting info hashes."
        case .tooManyParameters:
            "The magnet link contains too many parameters."
        case .tooManyTrackers:
            "The magnet link contains too many trackers."
        case .tooManyWebSeeds:
            "The magnet link contains too many web seeds."
        case .displayNameTooLong:
            "The magnet display name is too long."
        case .invalidSourceURL:
            "The magnet link contains an invalid tracker or web seed URL."
        case .invalidFileSelection:
            "The magnet link contains an invalid file selection."
        case .fileSelectionTooComplex:
            "The magnet file selection exceeds the safe work limit."
        }
    }
}

/// A bounded, protocol-specific magnet representation. Raw magnet text is not
/// retained, so downstream code cannot defer or repeat URI parsing.
package struct ParsedMagnet: Codable, Equatable, Sendable {
    package struct Tracker: Codable, Equatable, Sendable {
        package let url: String
        package let tier: UInt8

        package init(url: String, tier: UInt8) {
            self.url = url
            self.tier = tier
        }
    }

    package struct FileSelection: Codable, Equatable, Sendable {
        package let firstIndex: Int32
        package let lastIndex: Int32

        package init(firstIndex: Int32, lastIndex: Int32) {
            self.firstIndex = firstIndex
            self.lastIndex = lastIndex
        }
    }

    private enum CodingKeys: String, CodingKey {
        case v1InfoHash
        case v2InfoHash
        case displayName
        case trackers
        case webSeeds
        case fileSelections
    }

    private static let maximumParameterCount =
        TorrentEngineLimits.maximumTrackerCount
        + TorrentEngineLimits.maximumWebSeedCount
        + 256
    private static let maximumDisplayNameBytes = 511
    private static let maximumSourceURLBytes = 16 * 1_024
    private static let maximumRetainedFieldBytes = TorrentInputLimits.maxMagnetURIBytes
    private static let maximumFileSelectionWork = TorrentEngineLimits.maximumFileCount * 4

    package let v1InfoHash: Data?
    package let v2InfoHash: Data?
    package let displayName: String?
    package let trackers: [Tracker]
    package let webSeeds: [String]
    /// `nil` means no `so` parameter. An empty array means an explicit
    /// select-only request that selected no files.
    package let fileSelections: [FileSelection]?

    package init(
        v1InfoHash: Data?,
        v2InfoHash: Data?,
        displayName: String?,
        trackers: [Tracker],
        webSeeds: [String],
        fileSelections: [FileSelection]?
    ) throws {
        try Self.validate(
            v1InfoHash: v1InfoHash,
            v2InfoHash: v2InfoHash,
            displayName: displayName,
            trackers: trackers,
            webSeeds: webSeeds,
            fileSelections: fileSelections
        )
        self.v1InfoHash = v1InfoHash
        self.v2InfoHash = v2InfoHash
        self.displayName = displayName
        self.trackers = trackers
        self.webSeeds = webSeeds
        self.fileSelections = fileSelections
    }

    package init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                v1InfoHash: values.decodeIfPresent(Data.self, forKey: .v1InfoHash),
                v2InfoHash: values.decodeIfPresent(Data.self, forKey: .v2InfoHash),
                displayName: values.decodeIfPresent(String.self, forKey: .displayName),
                trackers: values.decode([Tracker].self, forKey: .trackers),
                webSeeds: values.decode([String].self, forKey: .webSeeds),
                fileSelections: values.decodeIfPresent(
                    [FileSelection].self,
                    forKey: .fileSelections
                )
            )
        } catch let error as ParsedMagnetError {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: error.localizedDescription,
                underlyingError: error
            ))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(v1InfoHash, forKey: .v1InfoHash)
        try values.encodeIfPresent(v2InfoHash, forKey: .v2InfoHash)
        try values.encodeIfPresent(displayName, forKey: .displayName)
        try values.encode(trackers, forKey: .trackers)
        try values.encode(webSeeds, forKey: .webSeeds)
        try values.encodeIfPresent(fileSelections, forKey: .fileSelections)
    }

    package static func parse(
        _ uri: String,
        checkCancellation: () throws -> Void = {}
    ) throws -> Self {
        try checkCancellation()
        guard uri.utf8.count <= TorrentInputLimits.maxMagnetURIBytes,
              uri.range(
                of: "magnet:?",
                options: [.caseInsensitive, .anchored]
              ) != nil,
              !containsControlOrWhitespace(uri) else {
            throw ParsedMagnetError.invalidURI
        }

        let query = uri.dropFirst("magnet:?".count)
        var cursor = query.startIndex
        var parameterCount = 0
        var v1InfoHash: Data?
        var v2InfoHash: Data?
        var displayName: String?
        var trackers = [Tracker]()
        var webSeeds = [String]()
        var selectedFiles: [Bool]?
        var selectionWork = 0
        trackers.reserveCapacity(32)
        webSeeds.reserveCapacity(8)

        while true {
            parameterCount += 1
            guard parameterCount <= maximumParameterCount else {
                throw ParsedMagnetError.tooManyParameters
            }
            if parameterCount.isMultiple(of: 16) {
                try checkCancellation()
            }

            let fieldEnd = query[cursor...].firstIndex(of: "&") ?? query.endIndex
            let field = query[cursor..<fieldEnd]
            let separator = field.firstIndex(of: "=")
            let rawName = separator.map { field[..<$0] } ?? field[...]
            let rawValue = separator.map {
                field[field.index(after: $0)...]
            } ?? ""[...]
            guard let name = try formDecoded(
                      rawName,
                      checkCancellation: checkCancellation
                  ),
                  let value = try formDecoded(
                      rawValue,
                      checkCancellation: checkCancellation
                  ),
                  !containsControl(name),
                  !containsControl(value) else {
                throw ParsedMagnetError.invalidURI
            }
            let parameterName = baseParameterName(name)

            if parameterName.caseInsensitiveCompare("xt") == .orderedSame {
                switch try parseExactTopic(value) {
                case .v1(let hash):
                    if let v1InfoHash, v1InfoHash != hash {
                        throw ParsedMagnetError.conflictingInfoHashes
                    }
                    v1InfoHash = hash
                case .v2(let hash):
                    if let v2InfoHash, v2InfoHash != hash {
                        throw ParsedMagnetError.conflictingInfoHashes
                    }
                    v2InfoHash = hash
                }
            } else if parameterName.caseInsensitiveCompare("dn") == .orderedSame {
                guard value.utf8.count <= maximumDisplayNameBytes else {
                    throw ParsedMagnetError.displayNameTooLong
                }
                displayName = value.isEmpty ? nil : value
            } else if parameterName.caseInsensitiveCompare("tr") == .orderedSame,
                      !value.isEmpty {
                guard trackers.count < TorrentEngineLimits.maximumTrackerCount else {
                    throw ParsedMagnetError.tooManyTrackers
                }
                guard validatedSourceURL(
                    value,
                    allowedSchemes: ["http", "https", "udp"]
                ) else {
                    throw ParsedMagnetError.invalidSourceURL
                }
                trackers.append(Tracker(
                    url: value,
                    tier: UInt8(min(trackers.count, Int(UInt8.max)))
                ))
            } else if parameterName.caseInsensitiveCompare("ws") == .orderedSame,
                      !value.isEmpty {
                guard webSeeds.count < TorrentEngineLimits.maximumWebSeedCount else {
                    throw ParsedMagnetError.tooManyWebSeeds
                }
                guard validatedSourceURL(
                    value,
                    allowedSchemes: ["http", "https"]
                ) else {
                    throw ParsedMagnetError.invalidSourceURL
                }
                webSeeds.append(value)
            } else if parameterName.caseInsensitiveCompare("so") == .orderedSame {
                try parseFileSelection(
                    value,
                    selectedFiles: &selectedFiles,
                    work: &selectionWork
                )
            }

            guard fieldEnd != query.endIndex else {
                break
            }
            cursor = query.index(after: fieldEnd)
        }

        try checkCancellation()
        guard v1InfoHash != nil || v2InfoHash != nil else {
            throw ParsedMagnetError.missingInfoHash
        }
        return try Self(
            v1InfoHash: v1InfoHash,
            v2InfoHash: v2InfoHash,
            displayName: displayName,
            trackers: trackers,
            webSeeds: webSeeds,
            fileSelections: selectedFiles.map(canonicalSelections)
        )
    }

    package var sourceSecuritySummary: TorrentSourceSecuritySummary {
        TorrentSourceSecuritySummary(
            trackerCount: trackers.count,
            httpsTrackerCount: trackers.count(where: { Self.isHTTPS($0.url) }),
            webSeedCount: webSeeds.count,
            httpsWebSeedCount: webSeeds.count(where: Self.isHTTPS)
        )
    }

    private enum ExactTopic {
        case v1(Data)
        case v2(Data)
    }

    private static func validate(
        v1InfoHash: Data?,
        v2InfoHash: Data?,
        displayName: String?,
        trackers: [Tracker],
        webSeeds: [String],
        fileSelections: [FileSelection]?
    ) throws {
        guard v1InfoHash == nil || v1InfoHash?.count == 20,
              v2InfoHash == nil || v2InfoHash?.count == 32 else {
            throw ParsedMagnetError.unsupportedExactTopic
        }
        guard v1InfoHash != nil || v2InfoHash != nil else {
            throw ParsedMagnetError.missingInfoHash
        }
        guard displayName?.utf8.count ?? 0 <= maximumDisplayNameBytes else {
            throw ParsedMagnetError.displayNameTooLong
        }
        if let displayName, displayName.isEmpty || containsControl(displayName) {
            throw ParsedMagnetError.invalidURI
        }
        guard trackers.count <= TorrentEngineLimits.maximumTrackerCount else {
            throw ParsedMagnetError.tooManyTrackers
        }
        guard webSeeds.count <= TorrentEngineLimits.maximumWebSeedCount else {
            throw ParsedMagnetError.tooManyWebSeeds
        }

        var retainedBytes = displayName?.utf8.count ?? 0
        for (index, tracker) in trackers.enumerated() {
            let expectedTier = UInt8(min(index, Int(UInt8.max)))
            guard tracker.tier == expectedTier,
                  validatedSourceURL(
                    tracker.url,
                    allowedSchemes: ["http", "https", "udp"]
                  ) else {
                throw ParsedMagnetError.invalidSourceURL
            }
            retainedBytes = try addingRetainedBytes(retainedBytes, tracker.url.utf8.count)
        }
        for webSeed in webSeeds {
            guard validatedSourceURL(
                webSeed,
                allowedSchemes: ["http", "https"]
            ) else {
                throw ParsedMagnetError.invalidSourceURL
            }
            retainedBytes = try addingRetainedBytes(retainedBytes, webSeed.utf8.count)
        }

        guard let fileSelections else {
            return
        }
        guard fileSelections.count <= TorrentEngineLimits.maximumFileCount else {
            throw ParsedMagnetError.invalidFileSelection
        }
        var previousLast: Int32?
        for selection in fileSelections {
            guard selection.firstIndex >= 0,
                  selection.firstIndex <= selection.lastIndex,
                  selection.lastIndex < Int32(TorrentEngineLimits.maximumFileCount),
                  previousLast.map({ selection.firstIndex > $0 + 1 }) ?? true else {
                throw ParsedMagnetError.invalidFileSelection
            }
            previousLast = selection.lastIndex
        }
    }

    private static func addingRetainedBytes(_ total: Int, _ count: Int) throws -> Int {
        let result = total.addingReportingOverflow(count)
        guard !result.overflow, result.partialValue <= maximumRetainedFieldBytes else {
            throw ParsedMagnetError.tooManyParameters
        }
        return result.partialValue
    }

    private static func parseExactTopic(_ value: String) throws -> ExactTopic {
        let lowercase = value.lowercased()
        let v1Prefix = "urn:btih:"
        if lowercase.hasPrefix(v1Prefix) {
            let encoded = value.dropFirst(v1Prefix.count)
            if encoded.utf8.count == 40, let hash = decodeHex(encoded) {
                return .v1(hash)
            }
            if encoded.utf8.count == 32, let hash = decodeBase32(encoded) {
                return .v1(hash)
            }
            throw ParsedMagnetError.unsupportedExactTopic
        }

        let v2Prefix = "urn:btmh:"
        if lowercase.hasPrefix(v2Prefix) {
            let multihash = value.dropFirst(v2Prefix.count)
            guard multihash.utf8.count == 68,
                  multihash.prefix(4).lowercased() == "1220",
                  let hash = decodeHex(multihash.dropFirst(4)),
                  hash.count == 32 else {
                throw ParsedMagnetError.unsupportedExactTopic
            }
            return .v2(hash)
        }
        throw ParsedMagnetError.unsupportedExactTopic
    }

    private static func parseFileSelection(
        _ value: String,
        selectedFiles: inout [Bool]?,
        work: inout Int
    ) throws {
        guard value.utf8.allSatisfy({ isASCIIDigit($0) || $0 == 45 || $0 == 44 }) else {
            throw ParsedMagnetError.invalidFileSelection
        }
        if selectedFiles == nil {
            selectedFiles = Array(
                repeating: false,
                count: TorrentEngineLimits.maximumFileCount
            )
        }

        var cursor = value.startIndex
        while true {
            let tokenEnd = value[cursor...].firstIndex(of: ",") ?? value.endIndex
            let token = value[cursor..<tokenEnd]
            if !token.isEmpty {
                let divider = token.firstIndex(of: "-")
                let first: Int
                let last: Int
                if let divider {
                    guard token[token.index(after: divider)...].firstIndex(of: "-") == nil,
                          divider != token.startIndex,
                          divider != token.index(before: token.endIndex),
                          let parsedFirst = Int(token[..<divider]),
                          let parsedLast = Int(token[token.index(after: divider)...]) else {
                        throw ParsedMagnetError.invalidFileSelection
                    }
                    first = parsedFirst
                    last = parsedLast
                } else {
                    guard let index = Int(token) else {
                        throw ParsedMagnetError.invalidFileSelection
                    }
                    first = index
                    last = index
                }
                guard first <= last,
                      first >= 0,
                      last < TorrentEngineLimits.maximumFileCount else {
                    throw ParsedMagnetError.invalidFileSelection
                }
                let addedWork = last - first + 1
                let workResult = work.addingReportingOverflow(addedWork)
                guard !workResult.overflow,
                      workResult.partialValue <= maximumFileSelectionWork else {
                    throw ParsedMagnetError.fileSelectionTooComplex
                }
                work = workResult.partialValue
                for index in first...last {
                    selectedFiles?[index] = true
                }
            }

            guard tokenEnd != value.endIndex else {
                return
            }
            cursor = value.index(after: tokenEnd)
        }
    }

    private static func canonicalSelections(_ selected: [Bool]) -> [FileSelection] {
        var result = [FileSelection]()
        var index = selected.startIndex
        while index < selected.endIndex {
            guard selected[index] else {
                index += 1
                continue
            }
            let first = index
            repeat {
                index += 1
            } while index < selected.endIndex && selected[index]
            result.append(FileSelection(
                firstIndex: Int32(first),
                lastIndex: Int32(index - 1)
            ))
        }
        return result
    }

    private static func formDecoded(
        _ value: Substring,
        checkCancellation: () throws -> Void
    ) throws -> String? {
        let input = Array(value.utf8)
        var output = [UInt8]()
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            if index.isMultiple(of: 256) {
                try checkCancellation()
            }
            switch input[index] {
            case UInt8(ascii: "+"):
                output.append(UInt8(ascii: " "))
                index += 1
            case UInt8(ascii: "%"):
                guard index + 2 < input.count,
                      let high = hexNibble(input[index + 1]),
                      let low = hexNibble(input[index + 2]) else {
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

    private static func decodeHex<S: StringProtocol>(_ value: S) -> Data? {
        let bytes = Array(value.utf8)
        guard bytes.count.isMultiple(of: 2) else {
            return nil
        }
        var result = Data(capacity: bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = hexNibble(bytes[index]),
                  let low = hexNibble(bytes[index + 1]) else {
                return nil
            }
            result.append((high << 4) | low)
        }
        return result
    }

    private static func decodeBase32<S: StringProtocol>(_ value: S) -> Data? {
        var result = Data(capacity: 20)
        var accumulator: UInt32 = 0
        var bitCount = 0
        for byte in value.utf8 {
            let uppercase = byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")
                ? byte - 32
                : byte
            let decoded: UInt8
            switch uppercase {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                decoded = uppercase - UInt8(ascii: "A")
            case UInt8(ascii: "2")...UInt8(ascii: "7"):
                decoded = uppercase - UInt8(ascii: "2") + 26
            default:
                return nil
            }
            accumulator = (accumulator << 5) | UInt32(decoded)
            bitCount += 5
            while bitCount >= 8 {
                bitCount -= 8
                result.append(UInt8(truncatingIfNeeded: accumulator >> bitCount))
                accumulator &= bitCount == 0 ? 0 : (1 << bitCount) - 1
            }
        }
        guard result.count == 20, bitCount == 0, accumulator == 0 else {
            return nil
        }
        return result
    }

    private static func validatedSourceURL(
        _ value: String,
        allowedSchemes: Set<String>
    ) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumSourceURLBytes,
              !containsControlOrWhitespace(value),
              hasValidPercentEscapes(value),
              !value.contains("\\") else {
            return false
        }
        guard let schemeEnd = value.range(of: "://")?.lowerBound else {
            return false
        }
        let scheme = value[..<schemeEnd]
        guard allowedSchemes.contains(scheme.lowercased()) else {
            return false
        }

        let authorityStart = value.index(schemeEnd, offsetBy: 3)
        let authorityEnd = value[authorityStart...].firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? value.endIndex
        return isValidAuthority(value[authorityStart..<authorityEnd])
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
            return suffix.isEmpty
                || (suffix.first == ":" && isValidPort(suffix.dropFirst()))
        }

        guard !hostAndPort.contains("["), !hostAndPort.contains("]") else {
            return false
        }
        let colons = hostAndPort.indices.filter { hostAndPort[$0] == ":" }
        guard colons.count <= 1 else {
            return false
        }
        if let colon = colons.first {
            return isValidDNSOrIPv4Host(hostAndPort[..<colon])
                && isValidPort(hostAndPort[hostAndPort.index(after: colon)...])
        }
        return isValidDNSOrIPv4Host(hostAndPort)
    }

    private static func isValidPort(_ port: Substring) -> Bool {
        !port.isEmpty
            && port.utf8.allSatisfy(isASCIIDigit)
            && UInt16(port).map { $0 != 0 } == true
    }

    private static func isValidDNSOrIPv4Host(_ host: Substring) -> Bool {
        guard !host.isEmpty,
              host.utf8.count < TorrentEngineLimits.trackerHostCapacity,
              !host.contains("%"),
              host.utf8.allSatisfy({
                  isASCIIAlpha($0) || isASCIIDigit($0) || $0 == 45 || $0 == 46
              }) else {
            return false
        }
        let withoutTrailingDot = host.last == "." ? host.dropLast() : host
        guard !withoutTrailingDot.isEmpty else {
            return false
        }
        if withoutTrailingDot.utf8.allSatisfy({ isASCIIDigit($0) || $0 == 46 }) {
            return isValidIPv4Address(withoutTrailingDot)
        }
        return withoutTrailingDot
            .split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { label in
                !label.isEmpty
                    && label.utf8.count <= 63
                    && label.first != "-"
                    && label.last != "-"
            }
    }

    private static func isValidIPv6Host(_ host: Substring) -> Bool {
        let zoneSeparator = host.range(of: "%25")
        let address: Substring
        if let zoneSeparator {
            guard host[zoneSeparator.upperBound...].range(of: "%25") == nil,
                  isValidIPv6Zone(host[zoneSeparator.upperBound...]) else {
                return false
            }
            address = host[..<zoneSeparator.lowerBound]
        } else {
            address = host
        }
        return !address.contains("%") && isValidIPv6Address(address)
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
            guard byte == UInt8(ascii: "%"),
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
        guard let leftCount = ipv6GroupCount(left),
              let rightCount = ipv6GroupCount(right) else {
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
                guard index == groups.index(before: groups.endIndex),
                      isValidIPv4Address(group) else {
                    return nil
                }
                count += 2
            } else {
                guard group.utf8.count <= 4,
                      group.utf8.allSatisfy(isASCIIHexDigit) else {
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

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] != UInt8(ascii: "%") {
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

    private static func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func containsControlOrWhitespace(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
                || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func baseParameterName(_ name: String) -> Substring {
        guard let separator = name.firstIndex(of: ".") else {
            return name[...]
        }
        let suffix = name[name.index(after: separator)...]
        guard suffix.utf8.allSatisfy(isASCIIDigit) else {
            return name[...]
        }
        return name[..<separator]
    }

    private static func isHTTPS(_ value: String) -> Bool {
        guard let separator = value.firstIndex(of: ":") else {
            return false
        }
        return value[..<separator].caseInsensitiveCompare("https") == .orderedSame
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

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
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
