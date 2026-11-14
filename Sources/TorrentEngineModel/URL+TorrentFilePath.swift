import Foundation

package extension URL {
    /// Returns a decoded filesystem path without a directory URL's trailing separators.
    ///
    /// `URL.path(percentEncoded:)` preserves trailing separators while the property it
    /// supersedes did not. Paths crossing the engine boundary use the separator-free
    /// form as their stable identity, except that the filesystem root remains `/`.
    var torrentFilePath: String {
        // Standardization preserves encoded path separators and NULs as
        // filename bytes. Decoding the original URL can turn a distinct file
        // URL into a different filesystem path.
        let decodedPath = standardizedFileURL.path(percentEncoded: false)
        guard let lastNonSeparator = decodedPath.lastIndex(where: { $0 != "/" }) else {
            return decodedPath.isEmpty ? "" : "/"
        }
        return String(decodedPath[...lastNonSeparator])
    }
}
