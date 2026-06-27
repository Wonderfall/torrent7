import Foundation

struct TorrentLabel: Identifiable, Hashable, Codable, Sendable {
    typealias ID = String
    static let maxNameLength = 48

    let id: ID
    var name: String

    init(id: ID = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }

    static func normalizedName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
    }

    func matches(name otherName: String) -> Bool {
        name.compare(
            Self.normalizedName(otherName),
            options: [.caseInsensitive, .diacriticInsensitive],
            range: nil,
            locale: .current
        ) == .orderedSame
    }
}
