import Foundation

enum TorrentDefaultsDomain: Sendable {
    case standard
    case suite(String)

    func makeUserDefaults() -> UserDefaults {
        switch self {
        case .standard:
            return .standard
        case .suite(let name):
            guard let defaults = UserDefaults(suiteName: name) else {
                preconditionFailure("Unable to create the requested user defaults suite")
            }
            return defaults
        }
    }
}
