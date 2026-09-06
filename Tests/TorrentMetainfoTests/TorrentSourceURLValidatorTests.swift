import Testing
@testable import TorrentMetainfo

@Suite("Source URL syntax")
struct TorrentSourceURLValidatorTests {
    @Test("IPv6 accepts ordinary literals and a final dotted IPv4 tail", arguments: [
        "::", "::1", "2001:db8::1", "2001:db8:1:2:3:4:5:6",
        "::192.0.2.1", "::ffff:192.0.2.1", "2001:db8::192.0.2.1",
        "2001:db8:1:2:3::192.0.2.1", "2001:db8:1:2:3:4:192.0.2.1",
        "fe80::1%25en0", "::ffff:192.0.2.1%25en0",
    ])
    func validIPv6(host: String) {
        #expect(TorrentSourceURLValidator.isValid(
            "https://[\(host)]:443/announce", maximumBytes: 2_048, allowedSchemes: ["https"]
        ))
    }

    @Test("IPv6 rejects misplaced dotted tails and invalid group counts", arguments: [
        "192.0.2.1::", "192.0.2.1::1", "2001:db8:192.0.2.1::",
        "192.0.2.1::198.51.100.1", "192.0.2.1::%25en0",
        "2001:db8::192.0.2.1:1", "2001:db8:1:2:3:192.0.2.1",
        "2001:db8:1:2:3:4::192.0.2.1", "::ffff:192.0.2.256",
        "2001::db8::1", ":::1",
    ])
    func invalidIPv6(host: String) {
        #expect(!TorrentSourceURLValidator.isValid(
            "https://[\(host)]:443/announce", maximumBytes: 2_048, allowedSchemes: ["https"]
        ))
    }
}
