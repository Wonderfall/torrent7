import Foundation

enum ByteFormat {
    static func size(_ bytes: Int64) -> String {
        if bytes == 0 {
            return "0 KB"
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Int32) -> String {
        rate(Int64(bytesPerSecond))
    }

    static func rate(_ bytesPerSecond: Int64) -> String {
        "\(size(bytesPerSecond))/s"
    }
}
