import Foundation
import TorrentEngineModel

enum TorrentMagnetDescriptorError: LocalizedError, Equatable, Sendable {
    case invalidURI
    case missingInfoHash
    case unsupportedExactTopic
    case conflictingInfoHashes
    case tooManyParameters
    case promotedMetadataTooLarge

    var errorDescription: String? {
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
        case .promotedMetadataTooLarge:
            "The promoted torrent metadata exceeds the safe size limit."
        }
    }
}

/// A bounded, independently parsed description of the security-relevant
/// magnet fields needed to verify and promote received metadata.
struct TorrentMagnetDescriptor: Equatable, Sendable {
    private static let maximumParameterCount =
        TorrentEngineLimits.maximumTrackerCount
        + TorrentEngineLimits.maximumWebSeedCount
        + 256

    let infoHashes: TorrentStorageInfoHashes
    let trackers: [String]
    let webSeeds: [String]

    var advertisedInfoHashes: TorrentAdvertisedInfoHashes {
        get throws {
            try TorrentAdvertisedInfoHashes(
                v1: infoHashes.v1,
                v2: infoHashes.v2
            )
        }
    }

    static func parse(_ magnet: String) throws -> Self {
        guard magnet.utf8.count <= TorrentInputLimits.maxMagnetURIBytes,
              magnet.range(
                of: "magnet:?",
                options: [.caseInsensitive, .anchored]
              ) != nil,
              !magnet.unicodeScalars.contains(where: {
                  $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7f
              }) else {
            throw TorrentMagnetDescriptorError.invalidURI
        }

        let fields = magnet.dropFirst("magnet:?".count)
            .split(separator: "&", omittingEmptySubsequences: false)
        guard fields.count <= maximumParameterCount else {
            throw TorrentMagnetDescriptorError.tooManyParameters
        }

        var v1: Data?
        var v2: Data?
        var trackers = [String]()
        var webSeeds = [String]()
        trackers.reserveCapacity(min(fields.count, 32))
        webSeeds.reserveCapacity(min(fields.count, 8))

        for field in fields {
            let separator = field.firstIndex(of: "=")
            let rawName = separator.map { field[..<$0] } ?? field[...]
            let rawValue = separator.map {
                field[field.index(after: $0)...]
            } ?? ""[...]
            guard let name = formDecoded(rawName),
                  let value = formDecoded(rawValue),
                  !containsControl(name),
                  !containsControl(value) else {
                throw TorrentMagnetDescriptorError.invalidURI
            }

            if name.caseInsensitiveCompare("xt") == .orderedSame {
                let topic = try parseExactTopic(value)
                switch topic {
                case .v1(let hash):
                    if let v1, v1 != hash {
                        throw TorrentMagnetDescriptorError.conflictingInfoHashes
                    }
                    v1 = hash
                case .v2(let hash):
                    if let v2, v2 != hash {
                        throw TorrentMagnetDescriptorError.conflictingInfoHashes
                    }
                    v2 = hash
                }
                continue
            }

            if isTrackerParameter(name), !value.isEmpty {
                guard trackers.count < TorrentEngineLimits.maximumTrackerCount else {
                    throw TorrentMagnetDescriptorError.tooManyParameters
                }
                trackers.append(value)
            } else if name.caseInsensitiveCompare("ws") == .orderedSame,
                      !value.isEmpty {
                guard webSeeds.count < TorrentEngineLimits.maximumWebSeedCount else {
                    throw TorrentMagnetDescriptorError.tooManyParameters
                }
                webSeeds.append(value)
            }
        }

        guard v1 != nil || v2 != nil else {
            throw TorrentMagnetDescriptorError.missingInfoHash
        }
        return try Self(
            infoHashes: TorrentStorageInfoHashes(v1: v1, v2: v2),
            trackers: trackers,
            webSeeds: webSeeds
        )
    }

    /// Builds a canonical top-level torrent dictionary while inserting the
    /// exact received info bytes verbatim. Only magnet-origin sources are
    /// synthesized; the hash-defining dictionary is never decoded/re-encoded.
    func torrentFile(exactInfoDictionary info: Data) throws -> Data {
        guard !info.isEmpty else {
            throw TorrentManifestError.metadataEmpty
        }
        var output = Data()
        output.reserveCapacity(min(
            TorrentInputLimits.maxTorrentFileBytes,
            info.count + trackers.reduce(0) { $0 + $1.utf8.count + 32 }
                + webSeeds.reduce(0) { $0 + $1.utf8.count + 16 }
                + 128
        ))
        output.append(UInt8(ascii: "d"))
        if let firstTracker = trackers.first {
            Self.appendBencoded("announce", to: &output)
            Self.appendBencoded(firstTracker, to: &output)
            Self.appendBencoded("announce-list", to: &output)
            output.append(UInt8(ascii: "l"))
            for tracker in trackers {
                output.append(UInt8(ascii: "l"))
                Self.appendBencoded(tracker, to: &output)
                output.append(UInt8(ascii: "e"))
            }
            output.append(UInt8(ascii: "e"))
        }
        Self.appendBencoded("info", to: &output)
        output.append(info)
        if !webSeeds.isEmpty {
            Self.appendBencoded("url-list", to: &output)
            output.append(UInt8(ascii: "l"))
            for webSeed in webSeeds {
                Self.appendBencoded(webSeed, to: &output)
            }
            output.append(UInt8(ascii: "e"))
        }
        output.append(UInt8(ascii: "e"))
        guard output.count <= TorrentInputLimits.maxTorrentFileBytes else {
            throw TorrentMagnetDescriptorError.promotedMetadataTooLarge
        }
        return output
    }

    private enum ExactTopic {
        case v1(Data)
        case v2(Data)
    }

    private static func parseExactTopic(_ value: String) throws -> ExactTopic {
        let lowercased = value.lowercased()
        let v1Prefix = "urn:btih:"
        if lowercased.hasPrefix(v1Prefix) {
            let encoded = value.dropFirst(v1Prefix.count)
            if encoded.utf8.count == 40,
               let bytes = decodeHex(encoded) {
                return .v1(bytes)
            }
            if encoded.utf8.count == 32,
               let bytes = decodeBase32(encoded) {
                return .v1(bytes)
            }
            throw TorrentMagnetDescriptorError.unsupportedExactTopic
        }

        let v2Prefix = "urn:btmh:"
        if lowercased.hasPrefix(v2Prefix) {
            let multihash = value.dropFirst(v2Prefix.count)
            guard multihash.utf8.count == 68,
                  multihash.prefix(4).lowercased() == "1220",
                  let bytes = decodeHex(multihash.dropFirst(4)),
                  bytes.count == 32 else {
                throw TorrentMagnetDescriptorError.unsupportedExactTopic
            }
            return .v2(bytes)
        }
        throw TorrentMagnetDescriptorError.unsupportedExactTopic
    }

    private static func formDecoded(_ value: Substring) -> String? {
        let input = Array(value.utf8)
        var output = [UInt8]()
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
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
            let upper = byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")
                ? byte - 32
                : byte
            let decoded: UInt8
            switch upper {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                decoded = upper - UInt8(ascii: "A")
            case UInt8(ascii: "2")...UInt8(ascii: "7"):
                decoded = upper - UInt8(ascii: "2") + 26
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
        guard result.count == 20,
              bitCount == 0,
              accumulator == 0 else {
            return nil
        }
        return result
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            byte - UInt8(ascii: "a") + 10
        default:
            nil
        }
    }

    private static func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7f
        }
    }

    private static func isTrackerParameter(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered == "tr" {
            return true
        }
        guard lowered.hasPrefix("tr."), lowered.count > 3 else {
            return false
        }
        return lowered.dropFirst(3).utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
        }
    }

    private static func appendBencoded(_ value: String, to output: inout Data) {
        let bytes = Data(value.utf8)
        output.append(Data("\(bytes.count):".utf8))
        output.append(bytes)
    }
}
