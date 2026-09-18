import Foundation
import ReleasePolicy

do {
    guard CommandLine.arguments.count == 4 else {
        throw PolicyError.usage("usage: write-native-sbom DEPS_PREFIX OUTPUT_JSON NATIVE_BUILD_ID")
    }
    let data = try NativeDependencyInventory.encode(
        prefix: URL(filePath: CommandLine.arguments[1]), expectedBuildID: CommandLine.arguments[3]
    )
    try data.write(to: URL(filePath: CommandLine.arguments[2]), options: .withoutOverwriting)
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("write-native-sbom: \(error)\n".utf8))
    exit(1)
}
