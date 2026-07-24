import Foundation

struct TorrentLabel: Identifiable, Hashable, Codable, Sendable {
    typealias ID = String
    static let maximumCount = 256
    static let maxNameLength = 48
    static let maxNameInputByteCount = 512
    static let maxIDByteCount = 128

    let id: ID
    var name: String

    init(id: ID = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }

    static func normalizedName(_ name: String) -> String {
        let boundedName = String(
            decoding: name.utf8.prefix(maxNameInputByteCount),
            as: UTF8.self
        )
        return String(
            boundedName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maxNameLength)
        )
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
