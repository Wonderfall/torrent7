import Foundation
import Testing

func withIsolatedDefaults<Result>(
    _ body: (UserDefaults) throws -> Result
) throws -> Result {
    let suiteName = "app.torrent7.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    return try body(defaults)
}
