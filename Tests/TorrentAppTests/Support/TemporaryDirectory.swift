import Foundation

func withTemporaryDirectory<Result>(
    _ body: (URL) throws -> Result
) throws -> Result {
    let url = URL.temporaryDirectory
        .appending(path: "TorrentAppTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: url)
    }
    return try body(url)
}
