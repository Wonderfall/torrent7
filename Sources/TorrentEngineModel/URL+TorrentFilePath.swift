import Foundation

package extension URL {
    /// Returns a decoded filesystem path without a directory URL's trailing separators.
    ///
    /// `URL.path(percentEncoded:)` preserves trailing separators while the property it
    /// supersedes did not. Paths crossing the engine boundary use the separator-free
    /// form as their stable identity, except that the filesystem root remains `/`.
    var torrentFilePath: String {
        let decodedPath = path(percentEncoded: false)
        guard let lastNonSeparator = decodedPath.lastIndex(where: { $0 != "/" }) else {
            return decodedPath.isEmpty ? "" : "/"
        }
        return String(decodedPath[...lastNonSeparator])
    }
}
