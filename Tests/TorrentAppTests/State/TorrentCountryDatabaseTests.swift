import Foundation
import Network
import Testing
import TorrentAppInfrastructure

@Suite("Offline peer countries")
struct TorrentCountryDatabaseTests {
    private func fixture() -> Data {
        // IPv4: 0...1.0.0.0 US, 1.0.0.1...max JP. IPv6: all FR.
        Data(Array("T7CCDB01".utf8) + [0, 0, 0, 1, 1, 53, 40, 137, 0, 0, 0, 2, 0, 0, 0, 1]
            + [1, 0, 0, 0, 85, 83, 255, 255, 255, 255, 74, 80]
            + Array(repeating: 255, count: 16) + [70, 82])
    }

    @Test("Lookup respects inclusive range boundaries, slices and mapped IPv4")
    func boundaries() throws {
        let prefixed = Data([0, 0, 0]) + fixture()
        let database = try TorrentCountryDatabase(data: prefixed.dropFirst(3))
        #expect(database.countryCode(for: Data([1, 0, 0, 0])) == "US")
        #expect(database.countryCode(for: Data([1, 0, 0, 1])) == "JP")
        #expect(database.countryCode(for: Data([223, 255, 255, 255])) == "JP")
        #expect(database.countryCode(for: try #require(IPv6Address("2001:4860::8888")).rawValue) == "FR")
        #expect(database.countryCode(for: try #require(IPv6Address("::ffff:1.0.0.0")).rawValue) == "US")
        #expect(database.countryCode(for: Data()) == nil)
    }

    @Test("Non-geographic address ranges never acquire a flag", arguments: [
        "0.0.0.0", "10.1.2.3", "127.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.1.1",
        "100.64.0.1", "192.0.2.1", "198.51.100.1", "203.0.113.1", "198.18.0.1", "224.0.0.1",
        "255.255.255.255", "::", "::1", "fc00::1", "fe80::1", "ff02::1", "2001:db8::1",
        "3fff:fff::1", "::ffff:192.168.1.1"
    ])
    func specialAddresses(_ text: String) throws {
        let address = try #require(IPv4Address(text)?.rawValue ?? IPv6Address(text)?.rawValue)
        #expect(try TorrentCountryDatabase(data: fixture()).countryCode(for: address) == nil)
    }

    @Test("Malformed indices and every truncated prefix are rejected")
    func malformed() throws {
        let bytes = fixture()
        for length in 0..<bytes.count {
            #expect(throws: TorrentCountryDatabase.Failure.self) {
                try TorrentCountryDatabase(data: bytes.prefix(length))
            }
        }
        for index in [0, 8, 12, 20, 28, 35, 53] {
            var damaged = bytes
            damaged[index] = 0
            if damaged == bytes { damaged[index] = 255 }
            #expect(throws: TorrentCountryDatabase.Failure.self) {
                try TorrentCountryDatabase(data: damaged)
            }
        }
        var unsorted = bytes
        unsorted.replaceSubrange(30..<34, with: [0, 0, 0, 0])
        #expect(throws: TorrentCountryDatabase.Failure.self) { try TorrentCountryDatabase(data: unsorted) }
        #expect(throws: TorrentCountryDatabase.Failure.self) { try TorrentCountryDatabase(data: bytes + Data([0])) }
    }

    @Test("Compressed indices preserve lookups, including sliced input")
    func compressed() throws {
        let compressed = try (fixture() as NSData).compressed(using: .lzfse) as Data
        let prefixed = Data([0, 0, 0]) + compressed
        let database = try TorrentCountryDatabase(compressedData: prefixed.dropFirst(3))
        #expect(database.date == 20261001)
        #expect(database.countryCode(for: Data([1, 0, 0, 0])) == "US")
        #expect(database.countryCode(for: Data([1, 0, 0, 1])) == "JP")
        #expect(database.countryCode(for: try #require(IPv6Address("2001:4860::8888")).rawValue) == "FR")
    }

    @Test("Compressed input rejects corruption, truncation, trailing bytes and invalid decoded indices")
    func malformedCompressed() throws {
        let compressed = try (fixture() as NSData).compressed(using: .lzfse) as Data
        for length in 0..<compressed.count {
            #expect(throws: TorrentCountryDatabase.Failure.self) {
                try TorrentCountryDatabase(compressedData: compressed.prefix(length))
            }
        }
        for index in [0, compressed.count / 2, compressed.count - 1] {
            var damaged = compressed
            damaged[index] ^= 255
            #expect(throws: TorrentCountryDatabase.Failure.self) {
                try TorrentCountryDatabase(compressedData: damaged)
            }
        }
        for invalid in [
            fixture(), compressed + Data([1]), compressed + compressed,
            compressed + Data(repeating: 0, count: 65_536)
        ] {
            #expect(throws: TorrentCountryDatabase.Failure.self) {
                try TorrentCountryDatabase(compressedData: invalid)
            }
        }
        let invalid = try (Data("not a country index".utf8) as NSData).compressed(using: .lzfse) as Data
        #expect(throws: TorrentCountryDatabase.Failure.self) {
            try TorrentCountryDatabase(compressedData: invalid)
        }
        // Regression for an input that made the system LZMA auto-decoder request
        // a 4 GiB dictionary. Only our bounded-state LZFSE format is accepted.
        let oversizedDictionary = Data([1]) + Data(repeating: 255, count: 38)
            + Data([49, 49, 0, 254, 255, 6, 255, 82])
        #expect(throws: TorrentCountryDatabase.Failure.self) {
            try TorrentCountryDatabase(compressedData: oversizedDictionary)
        }
    }

    @Test("Both stored input and decompressed output have a hard size limit")
    func compressionLimits() throws {
        let oversized = Data(repeating: 0, count: 32 * 1_024 * 1_024 + 1)
        #expect(throws: TorrentCountryDatabase.Failure.self) {
            try TorrentCountryDatabase(compressedData: oversized)
        }
        let compressed = try (oversized as NSData).compressed(using: .lzfse) as Data
        #expect(throws: TorrentCountryDatabase.Failure.self) {
            try TorrentCountryDatabase(compressedData: compressed)
        }
    }

    @Test("Pinned bundled index resolves both IP families without a network request")
    func bundled() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let database = try TorrentCountryDatabase(compressedData: Data(contentsOf: root.appending(path: "Packaging/PeerCountries.bin.lzfse")))
        #expect(database.date == 20261001)
        #expect(database.countryCode(for: Data([8, 8, 8, 8])) == "US")
        // The pinned CSV labels 2001:4860:4802::...2001:4860:6dff:ffff:... as CA.
        #expect(database.countryCode(for: try #require(IPv6Address("2001:4860:4860::8888")).rawValue) == "CA")
    }
}
