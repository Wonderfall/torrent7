import Darwin
import Foundation
import Testing
@testable import TorrentEngineClient

@Suite("Legacy state migration client")
struct TorrentLegacyResumeDirectoryTests {
    @Test("Missing and empty legacy state need no migration")
    func missingAndEmptyState() throws {
        let temporary = try ClientMigrationTemporaryDirectory()
        #expect(try TorrentLegacyResumeDirectory.open(stateDirectory: temporary.url) == nil)

        try FileManager.default.createDirectory(
            at: temporary.resumeDataURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let directory = try #require(
            try TorrentLegacyResumeDirectory.open(stateDirectory: temporary.url)
        )
        #expect(directory.filenames.isEmpty)
    }

    @Test("Only exact native state filenames are exposed in deterministic order")
    func exactFilenameAllowlist() throws {
        let temporary = try ClientMigrationTemporaryDirectory(withResumeData: true)
        let v1 = "v1:\(String(repeating: "a", count: 40)).fastresume"
        let v2 = "v2:\(String(repeating: "b", count: 64)).fastresume"
        let token = "t:\(String(repeating: "c", count: 32)).fastresume"
        let tombstone = "removal-\(String(repeating: "d", count: 32)).fastresume.remove"
        for filename in [v2, "arbitrary.fastresume", tombstone, token, v1] {
            try Data("state".utf8).write(
                to: temporary.resumeDataURL.appending(path: filename)
            )
        }

        let directory = try #require(
            try TorrentLegacyResumeDirectory.open(stateDirectory: temporary.url)
        )
        #expect(directory.filenames == [tombstone, token, v1, v2].sorted())
    }

    @Test("Directory and file symlinks fail closed")
    func symlinksFailClosed() throws {
        let temporary = try ClientMigrationTemporaryDirectory()
        let target = temporary.url.appending(path: "Target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: temporary.resumeDataURL,
            withDestinationURL: target
        )
        #expect(throws: TorrentEngineClientError.self) {
            _ = try TorrentLegacyResumeDirectory.open(stateDirectory: temporary.url)
        }

        try FileManager.default.removeItem(at: temporary.resumeDataURL)
        try FileManager.default.createDirectory(
            at: temporary.resumeDataURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let name = "v1:\(String(repeating: "e", count: 40)).fastresume"
        let source = temporary.url.appending(path: "source")
        try Data("state".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(
            at: temporary.resumeDataURL.appending(path: name),
            withDestinationURL: source
        )
        let directory = try #require(
            try TorrentLegacyResumeDirectory.open(stateDirectory: temporary.url)
        )
        #expect(directory.filenames == [name])
        #expect(throws: TorrentEngineClientError.self) {
            _ = try directory.openFile(named: name)
        }
    }

    @Test("Opened migration files are regular owner files")
    func opensRegularFile() throws {
        let temporary = try ClientMigrationTemporaryDirectory(withResumeData: true)
        let name = "t:\(String(repeating: "f", count: 32)).fastresume"
        try Data("resume".utf8).write(
            to: temporary.resumeDataURL.appending(path: name)
        )
        let directory = try #require(
            try TorrentLegacyResumeDirectory.open(stateDirectory: temporary.url)
        )
        let descriptor = try directory.openFile(named: name)
        defer {
            Darwin.close(descriptor)
        }
        var metadata = stat()
        #expect(unsafe Darwin.fstat(descriptor, &metadata) == 0)
        #expect((metadata.st_mode & S_IFMT) == S_IFREG)
        #expect(metadata.st_size == 6)
    }
}

private final class ClientMigrationTemporaryDirectory {
    let url: URL

    var resumeDataURL: URL {
        url.appending(path: "ResumeData", directoryHint: .isDirectory)
    }

    init(withResumeData: Bool = false) throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "TorrentEngineClientTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        if withResumeData {
            try FileManager.default.createDirectory(
                at: resumeDataURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
