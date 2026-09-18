import Foundation
import ReleasePolicy
import Testing

@Suite("Native release inventory")
struct NativeDependencyInventoryTests {
    @Test("Malformed and oversized build stamps fail closed", arguments: [
        Data(), Data("no-separator".utf8), Data("=value".utf8),
        Data("key=one\nkey=two\n".utf8), Data("key=value\0".utf8),
        Data([0xff]), Data(repeating: 65, count: 131_073)
    ])
    func rejectsInvalidStamps(_ data: Data) {
        #expect(throws: InventoryError.invalidStamp) { try NativeBuildStamp(data) }
    }

    @Test("Build values retain embedded equals signs")
    func preservesValues() throws {
        let stamp = try NativeBuildStamp(Data("flags=-DVALUE=1\n".utf8))
        #expect(try stamp.value("flags") == "-DVALUE=1")
        #expect(throws: InventoryError.invalidField("missing")) { try stamp.value("missing") }
    }

    @Test("Every declared patch requires a name and digest")
    func requiresCompletePatchSeries() throws {
        let digest = String(repeating: "a", count: 64)
        let text = "boost-patch-count=1\nboost-patch-1=fix.patch\nboost-patch-1-sha256=\(digest)\n"
        let stamp = try NativeBuildStamp(Data(text.utf8))
        let expected: [InventoryProperty] = [
            .init(name: "torrent7:boost-patch-1", value: "fix.patch"),
            .init(name: "torrent7:boost-patch-1-sha256", value: digest)
        ]
        #expect(try stamp.patches("boost") == expected)
        let incomplete = try NativeBuildStamp(Data("boost-patch-count=2\n".utf8))
        #expect(throws: InventoryError.invalidField("boost-patch-count")) { try incomplete.patches("boost") }
    }

    @Test("Patch counts, names and hashes are bounded", arguments: [
        "boost-patch-count=-1\n", "boost-patch-count=129\n", "boost-patch-count=huge\n",
        "boost-patch-count=1\nboost-patch-1=../escape.patch\n",
        "boost-patch-count=0\nboost-patch-1=undeclared.patch\n",
        "boost-patch-count=1\nboost-patch-1=fix.patch\nboost-patch-1-sha256=bad\n"
    ])
    func rejectsInvalidPatchSeries(_ text: String) throws {
        let stamp = try NativeBuildStamp(Data(text.utf8))
        #expect(throws: (any Error).self) { try stamp.patches("boost") }
    }
}
