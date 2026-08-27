import Foundation
import Testing
@testable import TorrentMetainfo

@Suite("HTTP tracker response parser")
struct TorrentHTTPTrackerResponseParserTests {
    private let parser = TorrentHTTPTrackerResponseParser()

    @Test("Announce responses produce bounded typed compact peers")
    func parsesCompactAnnounceResponse() throws {
        let ipv4 = Data([203, 0, 113, 8, 0x1a, 0xe1])
        let ipv6 = Data([
            0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 1,
            0x1a, 0xe2,
        ])
        let body = bencodedDictionary([
            ("complete", bencodedInteger(9)),
            ("downloaded", bencodedInteger(17)),
            ("external ip", bencodedString(Data([198, 51, 100, 4]))),
            ("incomplete", bencodedInteger(3)),
            ("interval", bencodedInteger(1_200)),
            ("min interval", bencodedInteger(60)),
            ("peers", bencodedString(ipv4)),
            ("peers6", bencodedString(ipv6)),
            ("tracker id", bencodedString(Data("opaque-token".utf8))),
            ("warning message", bencodedString(Data("maintenance soon".utf8))),
        ])

        let response = try parser.parse(body)

        #expect(response.interval == 1_200)
        #expect(response.minimumInterval == 60)
        #expect(response.complete == 9)
        #expect(response.incomplete == 3)
        #expect(response.downloaded == 17)
        #expect(response.downloaders == -1)
        #expect(response.failureReasonRange == nil)
        #expect(response.trackerIDRange.map { Data(response.body[$0]) }
            == Data("opaque-token".utf8))
        #expect(response.warningMessageRange.map { Data(response.body[$0]) }
            == Data("maintenance soon".utf8))
        #expect(response.externalAddress == TorrentPeerAddress(
            family: .ipv4,
            high: 0,
            low: 0xc633_6404
        ))
        #expect(response.peers.count == 2)
        #expect(response.peers[0] == TorrentTrackerPeer(
            kind: .ipv4,
            address: TorrentPeerAddress(
                family: .ipv4,
                high: 0,
                low: 0xcb00_7108
            ),
            hostnameRange: nil,
            peerIDRange: nil,
            port: 6_881
        ))
        #expect(response.peers[1].kind == .ipv6)
        #expect(response.peers[1].address?.high == 0x2001_0db8_0000_0000)
        #expect(response.peers[1].address?.low == 1)
        #expect(response.peers[1].port == 6_882)
    }

    @Test("Dictionary peer lists retain checked hostname and peer-ID ranges")
    func parsesHostnamePeersAndSkipsInvalidEntries() throws {
        let validPeer = bencodedDictionary([
            ("ip", bencodedString(Data("peer.example".utf8))),
            ("peer id", bencodedString(Data("abcdefghijklmnopqrst".utf8))),
            ("port", bencodedInteger(6_881)),
        ])
        let invalidPeer = bencodedDictionary([
            ("ip", bencodedString(Data("bad/hostname".utf8))),
            ("port", bencodedInteger(6_882)),
        ])
        let body = bencodedDictionary([
            ("peers", bencodedList([invalidPeer, validPeer])),
        ])

        let response = try parser.parse(body)

        #expect(response.peers.count == 1)
        let peer = try #require(response.peers.first)
        #expect(peer.kind == .hostname)
        #expect(peer.hostnameRange.map { Data(response.body[$0]) }
            == Data("peer.example".utf8))
        #expect(peer.peerIDRange.map { Data(response.body[$0]) }
            == Data("abcdefghijklmnopqrst".utf8))
        #expect(peer.port == 6_881)
    }

    @Test("A failure reason is terminal but retains scheduling fields")
    func parsesTrackerFailure() throws {
        let body = bencodedDictionary([
            ("failure reason", bencodedString(Data("temporarily unavailable".utf8))),
            ("interval", bencodedInteger(300)),
            ("tracker id", bencodedString(Data("retry-token".utf8))),
            ("warning message", bencodedString(Data("ignored after failure".utf8))),
        ])

        let response = try parser.parse(body)

        #expect(response.interval == 300)
        #expect(response.failureReasonRange.map { Data(response.body[$0]) }
            == Data("temporarily unavailable".utf8))
        #expect(response.trackerIDRange.map { Data(response.body[$0]) }
            == Data("retry-token".utf8))
        #expect(response.warningMessageRange == nil)
        #expect(response.peers.isEmpty)
    }

    @Test("Scrape responses select only the exact binary info-hash key")
    func parsesScrapeResponse() throws {
        let expectedHash = Data(0..<20)
        let otherHash = Data(repeating: 0xff, count: 20)
        let expectedStatistics = bencodedDictionary([
            ("complete", bencodedInteger(11)),
            ("downloaded", bencodedInteger(23)),
            ("downloaders", bencodedInteger(4)),
            ("incomplete", bencodedInteger(7)),
        ])
        let body = bencodedDictionary([
            ("files", bencodedByteKeyedDictionary([
                (otherHash, bencodedDictionary([])),
                (expectedHash, expectedStatistics),
            ])),
        ])

        let response = try parser.parse(body, scrapeInfoHash: expectedHash)

        #expect(response.complete == 11)
        #expect(response.incomplete == 7)
        #expect(response.downloaded == 23)
        #expect(response.downloaders == 4)
        #expect(response.peers.isEmpty)
    }

    @Test("Scrapes require files and the exact requested hash")
    func rejectsIncompleteScrapeShape() {
        let hash = Data(repeating: 1, count: 20)
        #expect(throws: TorrentHTTPTrackerResponseError.missingScrapeFiles) {
            _ = try parser.parse(bencodedDictionary([]), scrapeInfoHash: hash)
        }
        #expect(throws: TorrentHTTPTrackerResponseError.missingScrapeHash) {
            _ = try parser.parse(
                bencodedDictionary([("files", bencodedDictionary([]))]),
                scrapeInfoHash: hash
            )
        }
        #expect(throws: TorrentHTTPTrackerResponseError.invalidField) {
            _ = try parser.parse(bencodedDictionary([]), scrapeInfoHash: Data([1]))
        }
    }

    @Test("Canonical bencoding and integer bounds fail closed")
    func rejectsMalformedAndAmbiguousResponses() {
        #expect(throws: TorrentHTTPTrackerResponseError.malformedBencoding) {
            _ = try parser.parse(Data("d5:peers0:8:intervali1ee".utf8))
        }
        #expect(throws: TorrentHTTPTrackerResponseError.invalidField) {
            _ = try parser.parse(bencodedDictionary([
                ("interval", bencodedInteger(Int64(Int32.max) + 1)),
            ]))
        }
        #expect(throws: TorrentHTTPTrackerResponseError.invalidField) {
            _ = try parser.parse(bencodedDictionary([
                ("warning message", bencodedString(Data([0]))),
            ]))
        }
    }

    @Test("Compact arrays and peer work are independently bounded")
    func enforcesPeerBounds() {
        #expect(throws: TorrentHTTPTrackerResponseError.invalidField) {
            _ = try parser.parse(bencodedDictionary([
                ("peers", bencodedString(Data([1, 2, 3, 4, 5]))),
            ]))
        }

        var limits = TorrentHTTPTrackerResponseParser.Limits.standard
        limits.maximumPeerCount = 2
        let limited = TorrentHTTPTrackerResponseParser(limits: limits)
        #expect(throws: TorrentHTTPTrackerResponseError.tooManyPeers) {
            _ = try limited.parse(bencodedDictionary([
                ("peers", bencodedString(Data(repeating: 1, count: 18))),
            ]))
        }
    }

    @Test("The decompressed body cap is enforced before scanning")
    func enforcesBodyLimit() {
        var limits = TorrentHTTPTrackerResponseParser.Limits.standard
        limits.maximumResponseBytes = 1
        let limited = TorrentHTTPTrackerResponseParser(limits: limits)

        #expect(throws: TorrentHTTPTrackerResponseError.responseTooLarge) {
            _ = try limited.parse(Data("de".utf8))
        }
    }

    @Test("Invalid or relaxed parser limits fail closed")
    func rejectsInvalidLimits() {
        var negativePeerLimit = TorrentHTTPTrackerResponseParser.Limits.standard
        negativePeerLimit.maximumPeerCount = -1
        #expect(throws: TorrentHTTPTrackerResponseError.workLimitExceeded) {
            _ = try TorrentHTTPTrackerResponseParser(limits: negativePeerLimit)
                .parse(bencodedDictionary([]))
        }

        var relaxedBodyLimit = TorrentHTTPTrackerResponseParser.Limits.standard
        relaxedBodyLimit.maximumResponseBytes += 1
        #expect(throws: TorrentHTTPTrackerResponseError.workLimitExceeded) {
            _ = try TorrentHTTPTrackerResponseParser(limits: relaxedBodyLimit)
                .parse(bencodedDictionary([]))
        }
    }
}

private func bencodedInteger(_ value: Int64) -> Data {
    Data("i\(value)e".utf8)
}

private func bencodedString(_ value: Data) -> Data {
    Data("\(value.count):".utf8) + value
}

private func bencodedList(_ values: [Data]) -> Data {
    values.reduce(into: Data([UInt8(ascii: "l")])) { result, value in
        result.append(value)
    } + Data([UInt8(ascii: "e")])
}

private func bencodedDictionary(_ fields: [(String, Data)]) -> Data {
    bencodedByteKeyedDictionary(fields.map { (Data($0.0.utf8), $0.1) })
}

private func bencodedByteKeyedDictionary(_ fields: [(Data, Data)]) -> Data {
    let sorted = fields.sorted { left, right in
        left.0.lexicographicallyPrecedes(right.0)
    }
    var result = Data([UInt8(ascii: "d")])
    for (key, value) in sorted {
        result.append(bencodedString(key))
        result.append(value)
    }
    result.append(UInt8(ascii: "e"))
    return result
}
