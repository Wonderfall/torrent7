import Foundation

package enum ThirdPartyNotices {
    @concurrent
    package static func loadBundled() async throws -> String {
        try Task.checkCancellation()
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        try Task.checkCancellation()
        return text
    }
}
