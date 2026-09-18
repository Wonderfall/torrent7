import Foundation
import ReleasePolicy

do {
    guard CommandLine.arguments.count == 4 else {
        throw PolicyError.usage("usage: verify-enhanced-security-metadata POINT_PLIST INFO_PLIST IDENTIFIER")
    }
    try verifyExtensionMetadata(
        point: readPropertyList(at: URL(filePath: CommandLine.arguments[1])),
        info: readPropertyList(at: URL(filePath: CommandLine.arguments[2])),
        identifier: CommandLine.arguments[3]
    )
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("verify-enhanced-security-metadata: \(error)\n".utf8))
    exit(1)
}
