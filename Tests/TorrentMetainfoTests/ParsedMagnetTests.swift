import Foundation
import Testing
import TorrentEngineModel
import TorrentMetainfo

@Suite("Parsed magnet")
struct ParsedMagnetTests {
    @Test("Parses a bounded hybrid magnet into canonical typed fields")
    func parsesHybridMagnet() throws {
        let parsed = try ParsedMagnet.parse([
            "MAGNET:?xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567",
            "xt=urn:btmh:1220\(String(repeating: "ab", count: 32))",
            "dn=Hello+world",
            "tr=https%3A%2F%2Ftracker.example%2Fannounce",
            "tr.7=udp%3A%2F%2Ftracker.example%3A80%2Fannounce",
            "ws.4=https%3A%2F%2Fseed.example%2Fcontent",
            "so=1-3%2C7",
            "x.pe=192.0.2.1%3A6881",
            "dht=ignored.example%3A6881",
        ].joined(separator: "&"))

        #expect(parsed.v1InfoHash == Data([
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23,
            0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67,
        ]))
        #expect(parsed.v2InfoHash == Data(repeating: 0xab, count: 32))
        #expect(parsed.displayName == "Hello world")
        #expect(parsed.trackers == [
            ParsedMagnet.Tracker(
                url: "https://tracker.example/announce",
                tier: 0
            ),
            ParsedMagnet.Tracker(
                url: "udp://tracker.example:80/announce",
                tier: 1
            ),
        ])
        #expect(parsed.webSeeds == ["https://seed.example/content"])
        #expect(parsed.fileSelections == [
            ParsedMagnet.FileSelection(firstIndex: 1, lastIndex: 3),
            ParsedMagnet.FileSelection(firstIndex: 7, lastIndex: 7),
        ])
        #expect(parsed.sourceSecuritySummary == TorrentSourceSecuritySummary(
            trackerCount: 2,
            httpsTrackerCount: 1,
            webSeedCount: 1,
            httpsWebSeedCount: 1
        ))
    }

    @Test("Accepts equal topics and rejects conflicting or unsupported topics")
    func exactTopicRules() throws {
        let hash = String(repeating: "1", count: 40)
        let equal = try ParsedMagnet.parse(
            "magnet:?xt=urn:btih:\(hash)&xt=URN:BTIH:\(hash.uppercased())"
        )
        #expect(equal.v1InfoHash == Data(repeating: 0x11, count: 20))

        #expect(throws: ParsedMagnetError.conflictingInfoHashes) {
            _ = try ParsedMagnet.parse(
                "magnet:?xt=urn:btih:\(hash)&xt=urn:btih:\(String(repeating: "2", count: 40))"
            )
        }
        #expect(throws: ParsedMagnetError.unsupportedExactTopic) {
            _ = try ParsedMagnet.parse(
                "magnet:?xt=urn:sha1:\(hash)"
            )
        }
    }

    @Test("Freezes plus decoding and numbered tracker behavior")
    func dialectDetails() throws {
        let parsed = try ParsedMagnet.parse(
            "magnet:?xt=urn:btih:ABCDEFGHIJKLMNOPQRSTUVWXYZ234567&dn=a+b&tr.=https%3A%2F%2Fone.example%2Fa&TR.12=https%3A%2F%2Ftwo.example%2Fb&tr.label=https%3A%2F%2Fignored.example%2Fc"
        )

        #expect(parsed.displayName == "a b")
        #expect(parsed.trackers.map(\.url) == [
            "https://one.example/a",
            "https://two.example/b",
        ])
    }

    @Test("Rejects invalid sources and over-complex select-only work")
    func resourceAndSourceRules() {
        let hash = String(repeating: "3", count: 40)
        #expect(throws: ParsedMagnetError.invalidSourceURL) {
            _ = try ParsedMagnet.parse(
                "magnet:?xt=urn:btih:\(hash)&tr=https%3A%2F%2Funder_score.example%2Fa"
            )
        }
        #expect(throws: ParsedMagnetError.invalidSourceURL) {
            _ = try ParsedMagnet.parse(
                "magnet:?xt=urn:btih:\(hash)&ws=udp%3A%2F%2Fseed.example%3A80"
            )
        }

        let repeatedWideRange = Array(
            repeating: "so=0-19999",
            count: 5
        ).joined(separator: "&")
        #expect(throws: ParsedMagnetError.fileSelectionTooComplex) {
            _ = try ParsedMagnet.parse(
                "magnet:?xt=urn:btih:\(hash)&\(repeatedWideRange)"
            )
        }
    }

    @Test("Typed decoding revalidates hashes, sources, tiers, and selections")
    func decodingRevalidatesModel() throws {
        let valid = try ParsedMagnet.parse(
            "magnet:?xt=urn:btih:\(String(repeating: "4", count: 40))&tr=https%3A%2F%2Ftracker.example%2Fa&so=1-2"
        )
        let encoded = try JSONEncoder().encode(valid)
        #expect(try JSONDecoder().decode(ParsedMagnet.self, from: encoded) == valid)

        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["v1InfoHash"] = Data(repeating: 0, count: 19).base64EncodedString()
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ParsedMagnet.self, from: malformed)
        }
    }

    @Test("Cancellation is checked during long field decoding")
    func cancellationCheck() {
        struct Cancelled: Error {}
        var checks = 0
        #expect(throws: Cancelled.self) {
            _ = try ParsedMagnet.parse(
                "magnet:?dn=\(String(repeating: "a", count: 1_024))&xt=urn:btih:\(String(repeating: "5", count: 40))",
                checkCancellation: {
                    checks += 1
                    if checks == 3 {
                        throw Cancelled()
                    }
                }
            )
        }
    }
}
