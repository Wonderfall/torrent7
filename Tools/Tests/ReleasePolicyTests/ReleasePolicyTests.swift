import Foundation
import ReleasePolicy
import Testing

private func plist(_ contents: String) -> Data {
    Data("<?xml version=\"1.0\"?><plist version=\"1.0\">\(contents)</plist>".utf8)
}

@Suite struct ReleasePolicyTests {
    @Test(arguments: ["<integer>1</integer>", "<real>1.0</real>", "<string>true</string>"])
    func booleanDoesNotEqualAnotherValueKind(_ value: String) throws {
        let expected = try PropertyListValue.dictionary(from: plist("<dict><key>a</key><true/></dict>"))
        let actual = try PropertyListValue.dictionary(from: plist("<dict><key>a</key>\(value)</dict>"))
        #expect(!PropertyListValue.dictionary(expected).differences(from: .dictionary(actual)).isEmpty)
    }

    @Test func exactNestedComparisonAndKeyOrder() throws {
        let left = try PropertyListValue.dictionary(from: plist("<dict><key>a</key><array><true/><integer>2</integer></array><key>b</key><data>AQID</data></dict>"))
        let right = try PropertyListValue.dictionary(from: plist("<dict><key>b</key><data>AQID</data><key>a</key><array><true/><integer>2</integer></array></dict>"))
        #expect(PropertyListValue.dictionary(left).differences(from: .dictionary(right)).isEmpty)
        #expect(!PropertyListValue.array([.integer("1"), .integer("2")]).differences(from: .array([.integer("2"), .integer("1")])).isEmpty)
        #expect(!PropertyListValue.dictionary(left).differences(from: .dictionary([:])).isEmpty)
    }

    @Test(arguments: ["", "<not-a-plist>", "<array/>", "<dict><key>a</key><real>nan</real></dict>"])
    func rejectsMalformedOrUnsupportedInput(_ input: String) {
        #expect(throws: (any Error).self) { try PropertyListValue.dictionary(from: plist(input)) }
    }

    @Test func rejectsOversizedAndDeepValues() {
        #expect(throws: PolicyError.excessiveSize) {
            try PropertyListValue.dictionary(from: Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1))
        }
        let nested = String(repeating: "<array>", count: 66) + "<true/>" + String(repeating: "</array>", count: 66)
        #expect(throws: PolicyError.excessiveSize) {
            try PropertyListValue.dictionary(from: plist("<dict><key>a</key>\(nested)</dict>"))
        }
    }

    @Test func fileReadRejectsTheFirstByteBeyondItsLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "policy.plist")
        let exact = Data(repeating: 0, count: PropertyListValue.maximumBytes)
        try exact.write(to: file)
        #expect(try readPropertyList(at: file) == exact)
        try (exact + Data([0])).write(to: file)
        #expect(throws: PolicyError.excessiveSize) { try readPropertyList(at: file) }
    }

    @Test(arguments: ["<true/>", "<integer>1</integer>", "<string>true</string>", "<false/>"])
    func verifiesExactEnhancedSecuritySchema(_ secure: String) throws {
        let point = plist("""
            <dict><key>EXVersion</key><integer>2</integer><key>example.engine</key><dict>
            <key>EXExtensionPointName</key><string>torrent-engine</string>
            <key>EXPresentsUserInterface</key><false/>
            <key>EXRequiresEnhancedSecurity</key>\(secure)
            <key>_EXScopeRestriction</key><string>application</string></dict></dict>
            """)
        let info = plist("<dict><key>EXAppExtensionAttributes</key><dict><key>EXExtensionPointIdentifier</key><string>example.engine</string></dict></dict>")
        if secure == "<true/>" {
            try verifyExtensionMetadata(point: point, info: info, identifier: "example.engine")
            #expect(throws: PolicyError.invalidMetadata) {
                try verifyExtensionMetadata(point: point, info: info, identifier: "wrong.engine")
            }
            let withLegacyService = plist("<dict><key>XPCService</key><dict/><key>EXAppExtensionAttributes</key><dict><key>EXExtensionPointIdentifier</key><string>example.engine</string></dict></dict>")
            #expect(throws: PolicyError.invalidMetadata) {
                try verifyExtensionMetadata(point: point, info: withLegacyService, identifier: "example.engine")
            }
        } else {
            #expect(throws: PolicyError.invalidMetadata) {
                try verifyExtensionMetadata(point: point, info: info, identifier: "example.engine")
            }
        }
    }
}
