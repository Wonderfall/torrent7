import Foundation
import Testing
@testable import TorrentApp

@Suite("Download folder access store")
struct DownloadFolderAccessStoreTests {
    @Test("Preparing non-default folder saves and prunes additional bookmark")
    func preparingNonDefaultFolderSavesAndPrunesAdditionalBookmark() throws {
        try withIsolatedDefaults { defaults in
            try withTemporaryDirectory { root in
                let store = DownloadFolderAccessStore(defaults: defaults, accessProvider: FakeDownloadFolderAccessProvider())
                let folder = root.appending(path: "folder", directoryHint: .isDirectory)

                let prepared = try store.prepareForAdd(folder, setsDefault: false, activeTorrents: [])

                #expect(prepared.path == folder.path)
                #expect(prepared.defaultURL == nil)
                #expect(additionalBookmarks(in: defaults)[accessKey(folder)] == Data(folder.path.utf8))

                store.prune(activeTorrents: [makeTorrent(savePath: folder.path)])
                #expect(additionalBookmarks(in: defaults)[accessKey(folder)] == Data(folder.path.utf8))

                store.prune(activeTorrents: [])
                #expect(additionalBookmarks(in: defaults).isEmpty)
            }
        }
    }

    @Test("Setting new default preserves old default only while active torrents use it")
    func settingNewDefaultPreservesOldDefaultOnlyWhileActiveTorrentsUseIt() throws {
        try withIsolatedDefaults { defaults in
            try withTemporaryDirectory { root in
                let store = DownloadFolderAccessStore(defaults: defaults, accessProvider: FakeDownloadFolderAccessProvider())
                let oldDefault = root.appending(path: "old", directoryHint: .isDirectory)
                let newDefault = root.appending(path: "new", directoryHint: .isDirectory)

                try store.setDefault(oldDefault, activeTorrents: [])
                try store.setDefault(newDefault, activeTorrents: [makeTorrent(savePath: oldDefault.path)])

                #expect(store.defaultURL?.path == newDefault.path)
                #expect(defaults.data(forKey: SecurityScopedFolder.defaultsKey) == Data(newDefault.path.utf8))
                #expect(additionalBookmarks(in: defaults)[accessKey(oldDefault)] == Data(oldDefault.path.utf8))
                #expect(additionalBookmarks(in: defaults)[accessKey(newDefault)] == nil)

                store.prune(activeTorrents: [])
                #expect(additionalBookmarks(in: defaults).isEmpty)
            }
        }
    }

    @Test("Restores valid additional bookmarks and drops invalid ones")
    func restoresValidAdditionalBookmarksAndDropsInvalidOnes() throws {
        try withIsolatedDefaults { defaults in
            try withTemporaryDirectory { root in
                let validFolder = root.appending(path: "valid", directoryHint: .isDirectory)
                let invalidData = Data("invalid".utf8)
                defaults.set(
                    [
                        "stale-key": invalidData,
                        accessKey(validFolder): Data(validFolder.path.utf8)
                    ],
                    forKey: TorrentBookmarkKeys.additionalDownloadFolders
                )

                _ = DownloadFolderAccessStore(
                    defaults: defaults,
                    accessProvider: FakeDownloadFolderAccessProvider(rejectedBookmarkData: [invalidData])
                )

                #expect(additionalBookmarks(in: defaults) == [accessKey(validFolder): Data(validFolder.path.utf8)])
            }
        }
    }

    @Test("Clearing default preserves active default as additional access")
    func clearingDefaultPreservesActiveDefaultAsAdditionalAccess() throws {
        try withIsolatedDefaults { defaults in
            try withTemporaryDirectory { root in
                let store = DownloadFolderAccessStore(defaults: defaults, accessProvider: FakeDownloadFolderAccessProvider())
                let defaultFolder = root.appending(path: "default", directoryHint: .isDirectory)
                try store.setDefault(defaultFolder, activeTorrents: [])

                store.clearDefault(activeTorrents: [makeTorrent(savePath: defaultFolder.path)])

                #expect(store.defaultURL == nil)
                #expect(defaults.data(forKey: SecurityScopedFolder.defaultsKey) == nil)
                #expect(additionalBookmarks(in: defaults)[accessKey(defaultFolder)] == Data(defaultFolder.path.utf8))
            }
        }
    }
}

private func additionalBookmarks(in defaults: UserDefaults) -> [String: Data] {
    defaults.dictionary(forKey: TorrentBookmarkKeys.additionalDownloadFolders) as? [String: Data] ?? [:]
}

private func accessKey(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
}
