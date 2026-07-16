import Foundation
import Testing
@testable import TorrentApp

@Suite("Download folder access store")
struct DownloadFolderAccessStoreTests {
    @Test("Removal leases require an exact active download root")
    func removalLeasesRequireExactActiveRoot() throws {
        try withIsolatedDefaults { defaults in
            try withTemporaryDirectory { root in
                let store = DownloadFolderAccessStore(
                    defaults: defaults,
                    accessProvider: FakeDownloadFolderAccessProvider()
                )
                let downloads = root.appending(path: "downloads", directoryHint: .isDirectory)
                let other = root.appending(path: "other", directoryHint: .isDirectory)
                _ = try store.setDefault(downloads, activeTorrents: [])

                _ = try store.lease(forSavePath: downloads.path)
                #expect(throws: TorrentStoreError.self) {
                    try store.lease(forSavePath: downloads.appending(path: "child").path)
                }
                #expect(throws: TorrentStoreError.self) {
                    try store.lease(forSavePath: other.path)
                }
                #expect(throws: TorrentStoreError.self) {
                    try store.lease(forSavePath: "relative")
                }
            }
        }
    }

    @Test("A prepared add owns live access without persisting it")
    func preparedAddOwnsLiveAccessWithoutPersistingIt() throws {
        try withIsolatedDefaults { defaults in
            try withTemporaryDirectory { root in
                let tracker = WeakDownloadFolderAccessTracker()
                let store = DownloadFolderAccessStore(
                    defaults: defaults,
                    accessProvider: TrackingDownloadFolderAccessProvider(tracker: tracker)
                )
                let folder = root.appending(path: "folder", directoryHint: .isDirectory)
                var prepared: PreparedDownloadFolder? = try store.prepareForAdd(
                    folder,
                    setsDefault: false,
                    activeTorrents: []
                )

                store.prune(activeTorrents: [])

                #expect(additionalBookmarks(in: defaults).isEmpty)
                #expect(tracker.access != nil)
                prepared = nil
                #expect(prepared == nil)
                #expect(tracker.access == nil)
            }
        }
    }

    @Test("Committing a non-default folder saves and prunes its bookmark")
    func committingNonDefaultFolderSavesAndPrunesAdditionalBookmark() throws {
        try withIsolatedDefaults { defaults in
            try withTemporaryDirectory { root in
                let store = DownloadFolderAccessStore(defaults: defaults, accessProvider: FakeDownloadFolderAccessProvider())
                let folder = root.appending(path: "folder", directoryHint: .isDirectory)

                let prepared = try store.prepareForAdd(folder, setsDefault: false, activeTorrents: [])

                #expect(prepared.path == folder.path)
                #expect(prepared.defaultURL == nil)
                #expect(additionalBookmarks(in: defaults).isEmpty)

                store.commitPreparedForAdd(prepared, activeTorrents: [])
                #expect(additionalBookmarks(in: defaults)[accessKey(folder)] == Data(folder.path.utf8))

                store.prune(activeTorrents: [makeTorrent(savePath: folder.path)])
                #expect(additionalBookmarks(in: defaults)[accessKey(folder)] == Data(folder.path.utf8))

                store.prune(activeTorrents: [])
                #expect(additionalBookmarks(in: defaults).isEmpty)
            }
        }
    }

    @Test("Preparing a default folder is side-effect free until commit")
    func preparingDefaultFolderIsSideEffectFreeUntilCommit() throws {
        try withIsolatedDefaults { defaults in
            try withTemporaryDirectory { root in
                let store = DownloadFolderAccessStore(
                    defaults: defaults,
                    accessProvider: FakeDownloadFolderAccessProvider()
                )
                let folder = root.appending(path: "folder", directoryHint: .isDirectory)

                let prepared = try store.prepareForAdd(folder, setsDefault: true, activeTorrents: [])

                #expect(store.defaultURL == nil)
                #expect(defaults.data(forKey: SecurityScopedFolder.defaultsKey) == nil)

                let committedDefault = store.commitPreparedForAdd(prepared, activeTorrents: [])

                #expect(committedDefault?.path == folder.path)
                #expect(store.defaultURL?.path == folder.path)
                #expect(defaults.data(forKey: SecurityScopedFolder.defaultsKey) == Data(folder.path.utf8))
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

private final class WeakDownloadFolderAccessTracker {
    weak var access: FakeDownloadFolderAccess?
}

private struct TrackingDownloadFolderAccessProvider: DownloadFolderAccessProviding {
    let tracker: WeakDownloadFolderAccessTracker

    func createAccess(url: URL, savesBookmark: Bool, defaults: UserDefaults) throws -> DownloadFolderAccessing {
        let access = FakeDownloadFolderAccess(url: url)
        tracker.access = access
        if savesBookmark {
            defaults.set(try access.bookmarkData(), forKey: SecurityScopedFolder.defaultsKey)
        }
        return access
    }

    func restoreDefault(defaults: UserDefaults) throws -> DownloadFolderAccessing? {
        guard let bookmark = defaults.data(forKey: SecurityScopedFolder.defaultsKey) else {
            return nil
        }
        return try restore(from: bookmark)
    }

    func restore(from bookmark: Data) throws -> DownloadFolderAccessing {
        guard let path = String(data: bookmark, encoding: .utf8), !path.isEmpty else {
            throw FakeBookmarkError()
        }
        let access = FakeDownloadFolderAccess(url: URL(fileURLWithPath: path, isDirectory: true))
        tracker.access = access
        return access
    }

    func clearDefaultBookmark(defaults: UserDefaults) {
        defaults.removeObject(forKey: SecurityScopedFolder.defaultsKey)
    }
}
