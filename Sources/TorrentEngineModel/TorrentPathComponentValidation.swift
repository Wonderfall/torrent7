/// Shared lexical policy for untrusted metainfo and descriptor-relative storage.
/// Swift strings are valid UTF-8; the remaining exclusions mirror native import.
package enum TorrentPathComponentValidation {
    package static func isSafe(_ component: String) -> Bool {
        isSafe(component, maximumUTF8ByteCount: .max)
    }

    package static func isSafe(
        _ component: String,
        maximumUTF8ByteCount: Int
    ) -> Bool {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              maximumUTF8ByteCount >= 0 else {
            return false
        }

        var byteCount = 0
        for byte in component.utf8 {
            guard byteCount < maximumUTF8ByteCount else {
                return false
            }
            byteCount += 1

            switch byte {
            case 0x00...0x1f,
                 UInt8(ascii: "/"),
                 UInt8(ascii: "\\"),
                 0x7f:
                return false
            default:
                break
            }
        }
        return true
    }
}
