import Foundation

package struct TorrentSearchQuery: Equatable, Sendable {
    package let text: String
    package var isEmpty: Bool { text.isEmpty }

    package init(_ input: String) {
        text = Self.boundedInput(input).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package static func boundedInput(_ input: String) -> String {
        String(decoding: input.utf8.prefix(1_024), as: UTF8.self)
    }

    package func matches(_ value: String) -> Bool {
        isEmpty || value.localizedStandardContains(text)
    }
}
