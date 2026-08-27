import Foundation

package enum TorrentHTTPTrackerResponseError: Error, Equatable, Sendable {
    case emptyResponse
    case responseTooLarge
    case malformedBencoding
    case workLimitExceeded
    case invalidField
    case tooManyPeers
    case invalidPeerEntry
    case missingScrapeFiles
    case missingScrapeHash
}

package enum TorrentTrackerPeerKind: UInt8, Equatable, Sendable {
    case hostname = 1
    case ipv4 = 4
    case ipv6 = 6
}

package struct TorrentTrackerPeer: Equatable, Sendable {
    package let kind: TorrentTrackerPeerKind
    package let address: TorrentPeerAddress?
    package let hostnameRange: Range<Int>?
    package let peerIDRange: Range<Int>?
    package let port: UInt16
}

/// A typed view of one canonical HTTP tracker response. Byte ranges refer to
/// `body`, which owns the exact bytes scanned by the parser. The ranges let a
/// native importer perform checked copying without parsing the bencoding again.
package struct TorrentHTTPTrackerResponse: Equatable, Sendable {
    package let body: Data
    package let interval: Int32
    package let minimumInterval: Int32
    package let complete: Int32
    package let incomplete: Int32
    package let downloaded: Int32
    package let downloaders: Int32
    package let trackerIDRange: Range<Int>?
    package let failureReasonRange: Range<Int>?
    package let warningMessageRange: Range<Int>?
    package let externalAddress: TorrentPeerAddress?
    package let peers: [TorrentTrackerPeer]
}

/// Bounded schema-directed parsing for the final, decompressed bencoded body
/// of an HTTP tracker announce or scrape response. HTTP framing, redirects,
/// decompression, TLS, and endpoint policy intentionally remain native.
package struct TorrentHTTPTrackerResponseParser: Sendable {
    package struct Limits: Equatable, Sendable {
        package var maximumResponseBytes = 512 * 1_024
        package var maximumPeerCount = 3_000
        package var maximumTrackerIDBytes = 1_024
        package var maximumHumanMessageBytes = 1_024
        package var maximumHostnameBytes = 255
        package var maximumNestingDepth = 8
        package var maximumValueCount = 32_768
        package var maximumContainerCount = 4_096
        package var maximumDictionaryKeyBytes = 512 * 1_024
        package var maximumIntegerDigits = 19
        package var maximumStringLengthDigits = 19

        package static let standard = Limits()
    }

    private let limits: Limits

    package init(limits: Limits = .standard) {
        self.limits = limits
    }

    /// `scrapeInfoHash` is nil for announce responses and must contain exactly
    /// the 20-byte v1-compatible tracker key for scrape responses.
    package func parse(
        _ bytes: Data,
        scrapeInfoHash: Data? = nil
    ) throws -> TorrentHTTPTrackerResponse {
        guard limitsAreValid else {
            throw TorrentHTTPTrackerResponseError.workLimitExceeded
        }
        guard !bytes.isEmpty else {
            throw TorrentHTTPTrackerResponseError.emptyResponse
        }
        guard bytes.count <= limits.maximumResponseBytes else {
            throw TorrentHTTPTrackerResponseError.responseTooLarge
        }
        if let scrapeInfoHash, scrapeInfoHash.count != 20 {
            throw TorrentHTTPTrackerResponseError.invalidField
        }

        let document: BencodeRangeDocument
        do {
            document = try BencodeRangeDocument.scan(
                bytes,
                limits: scannerLimits
            )
        } catch {
            throw scanError(error)
        }
        let root = document.rootIndex
        guard document.kind(at: root) == .dictionary else {
            throw TorrentHTTPTrackerResponseError.invalidField
        }

        let interval = try boundedInteger(
            named: "interval",
            in: root,
            document: document,
            defaultValue: 1_800,
            range: 0...Int64(Int32.max)
        )
        let minimumInterval = try boundedInteger(
            named: "min interval",
            in: root,
            document: document,
            defaultValue: 30,
            range: 0...Int64(Int32.max)
        )
        let trackerIDRange = try optionalStringRange(
            named: "tracker id",
            in: root,
            document: document,
            maximumBytes: limits.maximumTrackerIDBytes,
            humanReadable: false
        )
        let failureReasonRange = try optionalStringRange(
            named: "failure reason",
            in: root,
            document: document,
            maximumBytes: limits.maximumHumanMessageBytes,
            humanReadable: true
        )

        if failureReasonRange != nil {
            return TorrentHTTPTrackerResponse(
                body: document.data,
                interval: interval,
                minimumInterval: minimumInterval,
                complete: -1,
                incomplete: -1,
                downloaded: -1,
                downloaders: -1,
                trackerIDRange: trackerIDRange,
                failureReasonRange: failureReasonRange,
                warningMessageRange: nil,
                externalAddress: nil,
                peers: []
            )
        }

        let warningMessageRange = try optionalStringRange(
            named: "warning message",
            in: root,
            document: document,
            maximumBytes: limits.maximumHumanMessageBytes,
            humanReadable: true
        )

        if let scrapeInfoHash {
            let statistics = try parseScrapeStatistics(
                root: root,
                expectedInfoHash: scrapeInfoHash,
                document: document
            )
            return TorrentHTTPTrackerResponse(
                body: document.data,
                interval: interval,
                minimumInterval: minimumInterval,
                complete: statistics.complete,
                incomplete: statistics.incomplete,
                downloaded: statistics.downloaded,
                downloaders: statistics.downloaders,
                trackerIDRange: trackerIDRange,
                failureReasonRange: nil,
                warningMessageRange: warningMessageRange,
                externalAddress: nil,
                peers: []
            )
        }

        let complete = try swarmStatistic(
            named: "complete",
            in: root,
            document: document
        )
        let incomplete = try swarmStatistic(
            named: "incomplete",
            in: root,
            document: document
        )
        let downloaded = try swarmStatistic(
            named: "downloaded",
            in: root,
            document: document
        )
        var peers = [TorrentTrackerPeer]()
        peers.reserveCapacity(min(limits.maximumPeerCount, 256))
        try parseIPv4OrHostnamePeers(
            in: root,
            document: document,
            peers: &peers
        )
        try parseCompactPeers(
            named: "peers6",
            family: .ipv6,
            stride: 18,
            in: root,
            document: document,
            peers: &peers
        )

        return TorrentHTTPTrackerResponse(
            body: document.data,
            interval: interval,
            minimumInterval: minimumInterval,
            complete: complete,
            incomplete: incomplete,
            downloaded: downloaded,
            downloaders: -1,
            trackerIDRange: trackerIDRange,
            failureReasonRange: nil,
            warningMessageRange: warningMessageRange,
            externalAddress: try externalAddress(in: root, document: document),
            peers: peers
        )
    }

    private var scannerLimits: BencodeScanLimits {
        BencodeScanLimits(
            maximumNestingDepth: limits.maximumNestingDepth,
            maximumValueCount: limits.maximumValueCount,
            maximumStringBytes: limits.maximumResponseBytes,
            maximumContainerCount: limits.maximumContainerCount,
            maximumDictionaryKeyBytes: limits.maximumDictionaryKeyBytes,
            maximumIntegerDigits: limits.maximumIntegerDigits,
            maximumStringLengthDigits: limits.maximumStringLengthDigits
        )
    }

    private var limitsAreValid: Bool {
        let maximum = Limits.standard
        return limits.maximumResponseBytes > 0
            && limits.maximumResponseBytes <= maximum.maximumResponseBytes
            && limits.maximumPeerCount >= 0
            && limits.maximumPeerCount <= maximum.maximumPeerCount
            && limits.maximumTrackerIDBytes >= 0
            && limits.maximumTrackerIDBytes <= maximum.maximumTrackerIDBytes
            && limits.maximumHumanMessageBytes >= 0
            && limits.maximumHumanMessageBytes <= maximum.maximumHumanMessageBytes
            && limits.maximumHostnameBytes >= 0
            && limits.maximumHostnameBytes <= maximum.maximumHostnameBytes
            && limits.maximumNestingDepth >= 0
            && limits.maximumNestingDepth <= maximum.maximumNestingDepth
            && limits.maximumValueCount > 0
            && limits.maximumValueCount <= maximum.maximumValueCount
            && limits.maximumContainerCount >= 0
            && limits.maximumContainerCount <= maximum.maximumContainerCount
            && limits.maximumDictionaryKeyBytes >= 0
            && limits.maximumDictionaryKeyBytes <= maximum.maximumDictionaryKeyBytes
            && limits.maximumIntegerDigits > 0
            && limits.maximumIntegerDigits <= maximum.maximumIntegerDigits
            && limits.maximumStringLengthDigits > 0
            && limits.maximumStringLengthDigits <= maximum.maximumStringLengthDigits
    }

    private func boundedInteger(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument,
        defaultValue: Int32,
        range: ClosedRange<Int64>
    ) throws -> Int32 {
        guard let value = document.value(named: name, inDictionaryAt: dictionary),
              let integer = document.integer(at: value) else {
            return defaultValue
        }
        guard range.contains(integer),
              let compact = Int32(exactly: integer) else {
            throw TorrentHTTPTrackerResponseError.invalidField
        }
        return compact
    }

    private func swarmStatistic(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument
    ) throws -> Int32 {
        try boundedInteger(
            named: name,
            in: dictionary,
            document: document,
            defaultValue: -1,
            range: -1...Int64(Int32.max)
        )
    }

    private func optionalStringRange(
        named name: String,
        in dictionary: Int,
        document: BencodeRangeDocument,
        maximumBytes: Int,
        humanReadable: Bool
    ) throws -> Range<Int>? {
        guard let value = document.value(named: name, inDictionaryAt: dictionary),
              let range = document.stringRange(at: value) else {
            return nil
        }
        guard range.count <= maximumBytes else {
            throw TorrentHTTPTrackerResponseError.invalidField
        }
        if humanReadable {
            let value = document.data[range]
            guard !value.contains(0),
                  String(data: value, encoding: .utf8) != nil else {
                throw TorrentHTTPTrackerResponseError.invalidField
            }
        }
        return range
    }

    private struct ScrapeStatistics {
        let complete: Int32
        let incomplete: Int32
        let downloaded: Int32
        let downloaders: Int32
    }

    private func parseScrapeStatistics(
        root: Int,
        expectedInfoHash: Data,
        document: BencodeRangeDocument
    ) throws -> ScrapeStatistics {
        guard let files = document.value(named: "files", inDictionaryAt: root),
              document.kind(at: files) == .dictionary else {
            throw TorrentHTTPTrackerResponseError.missingScrapeFiles
        }
        var matchingEntry: Int?
        var child = document.firstChild(of: files)
        while let index = child {
            if let key = document.dictionaryKeyRange(forChild: index),
               document.bytes(in: key, equalTo: expectedInfoHash) {
                matchingEntry = index
                break
            }
            child = document.nextSibling(of: index)
        }
        guard let matchingEntry,
              document.kind(at: matchingEntry) == .dictionary else {
            throw TorrentHTTPTrackerResponseError.missingScrapeHash
        }
        return try ScrapeStatistics(
            complete: swarmStatistic(
                named: "complete",
                in: matchingEntry,
                document: document
            ),
            incomplete: swarmStatistic(
                named: "incomplete",
                in: matchingEntry,
                document: document
            ),
            downloaded: swarmStatistic(
                named: "downloaded",
                in: matchingEntry,
                document: document
            ),
            downloaders: swarmStatistic(
                named: "downloaders",
                in: matchingEntry,
                document: document
            )
        )
    }

    private func parseIPv4OrHostnamePeers(
        in root: Int,
        document: BencodeRangeDocument,
        peers: inout [TorrentTrackerPeer]
    ) throws {
        guard let value = document.value(named: "peers", inDictionaryAt: root) else {
            return
        }
        switch document.kind(at: value) {
        case .string:
            try appendCompactPeers(
                value: value,
                family: .ipv4,
                stride: 6,
                document: document,
                peers: &peers
            )
        case .list:
            guard document.childCount(of: value) <= limits.maximumPeerCount else {
                throw TorrentHTTPTrackerResponseError.tooManyPeers
            }
            var foundInvalidEntry = false
            var child = document.firstChild(of: value)
            while let index = child {
                if let peer = parseHostnamePeer(index, document: document) {
                    try append(peer, to: &peers)
                } else {
                    foundInvalidEntry = true
                }
                child = document.nextSibling(of: index)
            }
            if peers.isEmpty,
               foundInvalidEntry {
                throw TorrentHTTPTrackerResponseError.invalidPeerEntry
            }
        case .integer, .dictionary:
            // Match libtorrent's compatibility behavior for a recognized key
            // with an unsupported representation: treat it as no peer list.
            return
        }
    }

    private func parseCompactPeers(
        named name: String,
        family: TorrentPeerAddressFamily,
        stride: Int,
        in root: Int,
        document: BencodeRangeDocument,
        peers: inout [TorrentTrackerPeer]
    ) throws {
        guard let value = document.value(named: name, inDictionaryAt: root),
              document.kind(at: value) == .string else {
            return
        }
        try appendCompactPeers(
            value: value,
            family: family,
            stride: stride,
            document: document,
            peers: &peers
        )
    }

    private func appendCompactPeers(
        value: Int,
        family: TorrentPeerAddressFamily,
        stride: Int,
        document: BencodeRangeDocument,
        peers: inout [TorrentTrackerPeer]
    ) throws {
        guard let range = document.stringRange(at: value),
              range.count.isMultiple(of: stride) else {
            throw TorrentHTTPTrackerResponseError.invalidField
        }
        let count = range.count / stride
        guard count <= limits.maximumPeerCount - peers.count else {
            throw TorrentHTTPTrackerResponseError.tooManyPeers
        }
        let addressSize = stride - 2
        var offset = range.lowerBound
        while offset < range.upperBound {
            let address = decodeAddress(
                document.data[offset..<(offset + addressSize)],
                family: family
            )
            let port = UInt16(document.data[offset + addressSize]) << 8
                | UInt16(document.data[offset + addressSize + 1])
            peers.append(TorrentTrackerPeer(
                kind: family == .ipv4 ? .ipv4 : .ipv6,
                address: address,
                hostnameRange: nil,
                peerIDRange: nil,
                port: port
            ))
            offset += stride
        }
    }

    private func parseHostnamePeer(
        _ index: Int,
        document: BencodeRangeDocument
    ) -> TorrentTrackerPeer? {
        guard document.kind(at: index) == .dictionary,
              let hostValue = document.value(named: "ip", inDictionaryAt: index),
              let hostnameRange = document.stringRange(at: hostValue),
              !hostnameRange.isEmpty,
              hostnameRange.count <= limits.maximumHostnameBytes,
              isSafeHostname(document.data[hostnameRange]),
              let portValue = document.value(named: "port", inDictionaryAt: index),
              let portInteger = document.integer(at: portValue),
              let port = UInt16(exactly: portInteger) else {
            return nil
        }
        var peerIDRange: Range<Int>?
        if let peerIDValue = document.value(named: "peer id", inDictionaryAt: index),
           let candidate = document.stringRange(at: peerIDValue),
           candidate.count == 20 {
            peerIDRange = candidate
        }
        return TorrentTrackerPeer(
            kind: .hostname,
            address: nil,
            hostnameRange: hostnameRange,
            peerIDRange: peerIDRange,
            port: port
        )
    }

    private func append(
        _ peer: TorrentTrackerPeer,
        to peers: inout [TorrentTrackerPeer]
    ) throws {
        guard peers.count < limits.maximumPeerCount else {
            throw TorrentHTTPTrackerResponseError.tooManyPeers
        }
        peers.append(peer)
    }

    private func isSafeHostname(_ bytes: Data.SubSequence) -> Bool {
        bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "."),
                 UInt8(ascii: "-"),
                 UInt8(ascii: "_"),
                 UInt8(ascii: ":"):
                true
            default:
                false
            }
        }
    }

    private func externalAddress(
        in root: Int,
        document: BencodeRangeDocument
    ) throws -> TorrentPeerAddress? {
        guard let value = document.value(named: "external ip", inDictionaryAt: root),
              let range = document.stringRange(at: value) else {
            return nil
        }
        switch range.count {
        case 4:
            return decodeAddress(document.data[range], family: .ipv4)
        case 16:
            return decodeAddress(document.data[range], family: .ipv6)
        default:
            return nil
        }
    }

    private func decodeAddress(
        _ bytes: Data.SubSequence,
        family: TorrentPeerAddressFamily
    ) -> TorrentPeerAddress {
        if family == .ipv4 {
            let low = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            return TorrentPeerAddress(family: .ipv4, high: 0, low: low)
        }
        var high: UInt64 = 0
        var low: UInt64 = 0
        for byte in bytes.prefix(8) {
            high = (high << 8) | UInt64(byte)
        }
        for byte in bytes.suffix(8) {
            low = (low << 8) | UInt64(byte)
        }
        return TorrentPeerAddress(family: .ipv6, high: high, low: low)
    }

    private func scanError(_ error: Error) -> TorrentHTTPTrackerResponseError {
        guard let error = error as? BencodeScanError else {
            return .malformedBencoding
        }
        switch error {
        case .malformed:
            return .malformedBencoding
        case .nestingLimitExceeded,
             .valueLimitExceeded,
             .stringLimitExceeded,
             .containerLimitExceeded,
             .dictionaryKeyByteLimitExceeded,
             .integerDigitLimitExceeded,
             .stringLengthDigitLimitExceeded:
            return .workLimitExceeded
        }
    }
}
