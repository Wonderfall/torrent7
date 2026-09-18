import Foundation
import ReleasePolicy

do {
    guard CommandLine.arguments.count == 3 else {
        throw PolicyError.usage("usage: compare-entitlements EXPECTED_PLIST ACTUAL_PLIST")
    }
    let expected = try PropertyListValue.dictionary(from: readPropertyList(at: URL(filePath: CommandLine.arguments[1])))
    let actual = try PropertyListValue.dictionary(from: readPropertyList(at: URL(filePath: CommandLine.arguments[2])))
    let differences = PropertyListValue.dictionary(expected).differences(from: .dictionary(actual))
    guard differences.isEmpty else {
        try FileHandle.standardError.write(contentsOf: Data((differences.joined(separator: "\n") + "\n").utf8))
        exit(1)
    }
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("compare-entitlements: \(error)\n".utf8))
    exit(1)
}
