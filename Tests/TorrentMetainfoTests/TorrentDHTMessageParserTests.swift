import Foundation
import Testing
@testable import TorrentMetainfo

@Suite("DHT KRPC message parser")
struct TorrentDHTMessageParserTests {
    private let parser = TorrentDHTMessageParser()
    private let nodeID = Data(0..<20)
    private let target = Data(20..<40)

    @Test("Ping queries retain only typed envelope fields")
    func parsesPingQuery() throws {
        let body = query(
            name: "ping",
            arguments: [("id", bencodedString(nodeID))],
            transaction: Data([0x01, 0x02])
        )

        let message = try parser.parse(body, sourceFamily: .ipv4)

        #expect(message.kind == .query)
        #expect(message.queryKind == .ping)
        #expect(message.queryIsValid)
        #expect(message.transactionRange.map { Data(message.body[$0]) } == Data([1, 2]))
        #expect(message.nodeIDRange.map { Data(message.body[$0]) } == nodeID)
        #expect(message.targetRange == nil)
        #expect(message.nodes.isEmpty)
        #expect(message.peers.isEmpty)
    }

    @Test("Get-peers queries decode optional discovery controls")
    func parsesGetPeersQuery() throws {
        let body = query(
            name: "get_peers",
            arguments: [
                ("id", bencodedString(nodeID)),
                ("info_hash", bencodedString(target)),
                ("noseed", bencodedInteger(1)),
                ("scrape", bencodedInteger(0)),
                ("want", bencodedList([
                    bencodedString(Data("n4".utf8)),
                    bencodedString(Data("future".utf8)),
                    bencodedString(Data("n6".utf8)),
                ])),
            ]
        )

        let message = try parser.parse(body, sourceFamily: .ipv6)

        #expect(message.queryKind == .getPeers)
        #expect(message.queryIsValid)
        #expect(message.targetRange.map { Data(message.body[$0]) } == target)
        #expect(message.noseed)
        #expect(!message.scrape)
        #expect(message.wantsSpecified)
        #expect(message.wantsIPv4)
        #expect(message.wantsIPv6)
    }

    @Test("Announce-peer queries retain bounded token, name, and port")
    func parsesAnnouncePeerQuery() throws {
        let body = query(
            name: "announce_peer",
            arguments: [
                ("id", bencodedString(nodeID)),
                ("implied_port", bencodedInteger(1)),
                ("info_hash", bencodedString(target)),
                ("n", bencodedString(Data("Example torrent".utf8))),
                ("port", bencodedInteger(6_881)),
                ("seed", bencodedInteger(1)),
                ("token", bencodedString(Data([0xde, 0xad, 0xbe, 0xef]))),
            ]
        )

        let message = try parser.parse(body, sourceFamily: .ipv4)

        #expect(message.queryKind == .announcePeer)
        #expect(message.queryIsValid)
        #expect(message.port == 6_881)
        #expect(message.impliedPort)
        #expect(message.seed)
        #expect(message.tokenRange.map { Data(message.body[$0]) }
            == Data([0xde, 0xad, 0xbe, 0xef]))
        #expect(message.nameRange.map { Data(message.body[$0]) }
            == Data("Example torrent".utf8))
    }

    @Test("Responses produce typed nodes, peers, tokens, and address hints")
    func parsesDiscoveryResponse() throws {
        let node4 = nodeID + Data([203, 0, 113, 7, 0x1a, 0xe1])
        let node6 = target + Data([
            0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 1,
            0x1a, 0xe2,
        ])
        let peer4 = Data([198, 51, 100, 9, 0x13, 0x88])
        let peer6 = Data([
            0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 2,
            0x13, 0x89,
        ])
        let response = bencodedDictionary([
            ("id", bencodedString(nodeID)),
            ("nodes", bencodedString(node4)),
            ("nodes6", bencodedString(node6)),
            ("token", bencodedString(Data("write-token".utf8))),
            ("values", bencodedList([
                bencodedString(peer4),
                bencodedString(peer6),
            ])),
        ])
        let body = bencodedDictionary([
            ("ip", bencodedString(Data([192, 0, 2, 4, 0x1a, 0xe1]))),
            ("r", response),
            ("t", bencodedString(Data([1, 2]))),
            ("y", bencodedString(Data("r".utf8))),
        ])

        let message = try parser.parse(body, sourceFamily: .ipv6)

        #expect(message.kind == .response)
        #expect(message.nodeIDRange.map { Data(message.body[$0]) } == nodeID)
        #expect(message.tokenRange.map { Data(message.body[$0]) }
            == Data("write-token".utf8))
        #expect(message.externalAddress == TorrentPeerAddress(
            family: .ipv4,
            high: 0,
            low: 0xc000_0204
        ))
        #expect(message.nodes.count == 2)
        #expect(Data(message.body[message.nodes[0].idRange]) == nodeID)
        #expect(message.nodes[0].address.low == 0xcb00_7107)
        #expect(message.nodes[0].port == 6_881)
        #expect(message.nodes[1].address.family == .ipv6)
        #expect(message.nodes[1].address.low == 1)
        #expect(message.peers == [
            TorrentDHTEndpoint(
                address: TorrentPeerAddress(family: .ipv4, high: 0, low: 0xc633_6409),
                port: 5_000
            ),
            TorrentDHTEndpoint(
                address: TorrentPeerAddress(
                    family: .ipv6,
                    high: 0x2001_0db8_0000_0000,
                    low: 2
                ),
                port: 5_001
            ),
        ])
    }

    @Test("Mainline aggregate peer strings are source-family dependent")
    func parsesMainlineAggregatePeers() throws {
        let aggregate = Data([
            192, 0, 2, 1, 0x00, 0x50,
            192, 0, 2, 2, 0x01, 0xbb,
        ])
        let body = response([
            ("id", bencodedString(nodeID)),
            ("values", bencodedList([bencodedString(aggregate)])),
        ])

        let fromIPv4 = try parser.parse(body, sourceFamily: .ipv4)
        let fromIPv6 = try parser.parse(body, sourceFamily: .ipv6)

        #expect(fromIPv4.peers.count == 2)
        #expect(fromIPv4.peers.map(\.port) == [80, 443])
        #expect(fromIPv6.peers.isEmpty)
    }

    @Test("Sample-infohash responses retain one bounded contiguous hash range")
    func parsesSampleResponse() throws {
        let samples = Data(0..<40)
        let body = response([
            ("id", bencodedString(nodeID)),
            ("interval", bencodedInteger(3_600)),
            ("num", bencodedInteger(12_345)),
            ("samples", bencodedString(samples)),
        ])

        let message = try parser.parse(body, sourceFamily: .ipv4)

        #expect(message.interval == 3_600)
        #expect(message.totalInfoHashCount == 12_345)
        #expect(message.sampleCount == 2)
        #expect(message.sampleHashesRange.map { Data(message.body[$0]) } == samples)
    }

    @Test("Errors retain bounded typed details without interpreting binary IDs")
    func parsesErrorResponse() throws {
        let body = bencodedDictionary([
            ("e", bencodedList([
                bencodedInteger(203),
                bencodedString(Data("protocol error".utf8)),
            ])),
            ("t", bencodedString(Data([0, 0xff]))),
            ("y", bencodedString(Data("e".utf8))),
        ])

        let message = try parser.parse(body, sourceFamily: .ipv4)

        #expect(message.kind == .error)
        #expect(message.errorCode == 203)
        #expect(message.errorMessageRange.map { Data(message.body[$0]) }
            == Data("protocol error".utf8))
        #expect(message.transactionRange.map { Data(message.body[$0]) }
            == Data([0, 0xff]))
    }

    @Test("BEP 44 and unknown queries remain explicit product-policy cases")
    func classifiesUnsupportedAndUnknownQueries() throws {
        let itemGet = query(
            name: "get",
            arguments: [
                ("id", bencodedString(nodeID)),
                ("target", bencodedString(target)),
            ]
        )
        let future = query(
            name: "future_lookup",
            arguments: [
                ("id", bencodedString(nodeID)),
                ("target", bencodedString(target)),
            ]
        )

        let getMessage = try parser.parse(itemGet, sourceFamily: .ipv4)
        let futureMessage = try parser.parse(future, sourceFamily: .ipv4)

        #expect(getMessage.queryKind == .getItem)
        #expect(getMessage.queryIsValid)
        #expect(futureMessage.queryKind == .unknown)
        #expect(futureMessage.queryIsValid)
        #expect(futureMessage.targetRange.map { Data(futureMessage.body[$0]) } == target)
    }

    @Test("Invalid recognized arguments stay typed for a native error reply")
    func retainsInvalidQueryEnvelope() throws {
        let body = query(
            name: "announce_peer",
            arguments: [
                ("id", bencodedString(nodeID)),
                ("info_hash", bencodedString(target)),
                ("port", bencodedInteger(70_000)),
                ("token", bencodedString(Data([1]))),
            ]
        )

        let message = try parser.parse(body, sourceFamily: .ipv4)

        #expect(message.queryKind == .announcePeer)
        #expect(!message.queryIsValid)
        #expect(message.port == nil)
        #expect(message.transactionRange != nil)
    }

    @Test("Canonical syntax and fixed work ceilings fail closed")
    func rejectsMalformedAndRelaxedLimits() {
        #expect(throws: TorrentDHTMessageError.malformedBencoding) {
            _ = try parser.parse(
                Data("d1:y1:q1:t2:aa1:q4:pinge".utf8),
                sourceFamily: .ipv4
            )
        }

        var relaxed = TorrentDHTMessageParser.Limits.standard
        relaxed.maximumMessageBytes += 1
        #expect(throws: TorrentDHTMessageError.workLimitExceeded) {
            _ = try TorrentDHTMessageParser(limits: relaxed).parse(
                query(name: "ping", arguments: [("id", bencodedString(nodeID))]),
                sourceFamily: .ipv4
            )
        }
    }
}

private func query(
    name: String,
    arguments: [(String, Data)],
    transaction: Data = Data([0, 1])
) -> Data {
    bencodedDictionary([
        ("a", bencodedDictionary(arguments)),
        ("q", bencodedString(Data(name.utf8))),
        ("t", bencodedString(transaction)),
        ("y", bencodedString(Data("q".utf8))),
    ])
}

private func response(_ fields: [(String, Data)]) -> Data {
    bencodedDictionary([
        ("r", bencodedDictionary(fields)),
        ("t", bencodedString(Data([0, 1]))),
        ("y", bencodedString(Data("r".utf8))),
    ])
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
    let sorted = fields.sorted {
        $0.0.utf8.lexicographicallyPrecedes($1.0.utf8)
    }
    var result = Data([UInt8(ascii: "d")])
    for (key, value) in sorted {
        result.append(bencodedString(Data(key.utf8)))
        result.append(value)
    }
    result.append(UInt8(ascii: "e"))
    return result
}
