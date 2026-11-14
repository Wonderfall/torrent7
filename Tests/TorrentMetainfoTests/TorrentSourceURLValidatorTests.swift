import Testing
@testable import TorrentMetainfo

@Suite("Source URL syntax")
struct TorrentSourceURLValidatorTests {
    @Test("Numeric hosts use canonical dotted-quad spelling", arguments: [
        "010.0.0.1", "0x41.1.1.1", "0X7f.1", "127.1", "1.2.3.004",
    ])
    func noncanonicalNumericHosts(host: String) {
        #expect(!TorrentSourceURLValidator.isValid(
            "http://\(host):80/announce", maximumBytes: 2_048, allowedSchemes: ["http"]
        ))
    }

    @Test("Numeric-looking DNS labels remain valid when the host is not an IP alias")
    func numericLookingDNSLabel() {
        #expect(TorrentSourceURLValidator.isValid(
            "https://0x41.tracker.example/announce",
            maximumBytes: 2_048, allowedSchemes: ["https"]
        ))
    }

    @Test("Source authorities reject userinfo", arguments: ["http", "https", "udp"])
    func rejectsUserinfo(scheme: String) {
        for authority in ["user:pass@tracker.example", "user@tracker.example", "@tracker.example"] {
            #expect(!TorrentSourceURLValidator.isValid(
                "\(scheme)://\(authority)/announce",
                maximumBytes: 2_048, allowedSchemes: [scheme]
            ))
        }
    }

    @Test("Source hostnames reject trailing dots without rejecting dots in paths", arguments: [
        "https", "http", "udp",
    ], ["tracker.example", "192.0.2.1"])
    func trailingDotHostnames(scheme: String, host: String) {
        for suffix in ["/announce.", ":443/announce?key=."] {
            #expect(TorrentSourceURLValidator.isValid(
                "\(scheme)://\(host)\(suffix)",
                maximumBytes: 2_048, allowedSchemes: [scheme]
            ))
            #expect(!TorrentSourceURLValidator.isValid(
                "\(scheme)://\(host).\(suffix)",
                maximumBytes: 2_048, allowedSchemes: [scheme]
            ))
        }
    }

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
