import Foundation

package struct TorrentLabel: Identifiable, Hashable, Codable, Sendable {
    package typealias ID = String
    package static let maximumCount = 256
    package static let maxNameLength = 48
    package static let maxNameInputByteCount = 512
    package static let maxIDByteCount = 128

    package let id: ID
    package var name: String

    package init(id: ID = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }

    package static func normalizedName(_ name: String) -> String {
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

    package func matches(name otherName: String) -> Bool {
        name.compare(
            Self.normalizedName(otherName),
            options: [.caseInsensitive, .diacriticInsensitive],
            range: nil,
            locale: .current
        ) == .orderedSame
    }
}
