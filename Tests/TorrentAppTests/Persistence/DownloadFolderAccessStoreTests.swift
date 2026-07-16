import Foundation
import Testing
@testable import TorrentApp

@Suite("Download folder access store")
struct DownloadFolderAccessStoreTests {
    @Test("Capability snapshots put the default first and sort and deduplicate additional paths")
    func capabilitySnapshotsAreDeterministicAndDeduplicated() throws {
        try withIsolatedDefaults { defaults in
            try withTemporaryDirectory { root in
                let alpha = root.appending(path: "alpha", directoryHint: .isDirectory)
                let beta = root.appending(path: "beta", directoryHint: .isDirectory)
                defaults.set(Data(beta.path.utf8), forKey: SecurityScopedFolder.defaultsKey)
                defaults.set(
                    [
                        "beta": Data(beta.path.utf8),
                        "alpha": Data(alpha.path.utf8)
                    ],
                    forKey: TorrentBookmarkKeys.additionalDownloadFolders
                )
                let store = DownloadFolderAccessStore(
                    defaults: defaults,
                    accessProvider: FakeDownloadFolderAccessProvider()
                )

                _ = try store.restoreDefault()

                #expect(store.capabilitySnapshot.paths == [beta.path, alpha.path])
            }
        }
    }

    @Test("Capability snapshots defensively cap paths while retaining the default first")
    func capabilitySnapshotsDefensivelyCapPaths() {
        let maximumPathCount = DownloadFolderCapabilitySnapshot.maximumPathCount
        let defaultAccess = FakeDownloadFolderAccess(
            url: URL(filePath: "/Downloads/default", directoryHint: .isDirectory)
        )
        let additionalAccesses = (0..<maximumPathCount).reversed().map { index in
            FakeDownloadFolderAccess(
                url: URL(
                    filePath: "/Downloads/additional-\(zeroPaddedIndex(index))",
                    directoryHint: .isDirectory
                )
            )
        }

        let snapshot = DownloadFolderCapabilitySnapshot(
            defaultAccess: defaultAccess,
            additionalAccesses: additionalAccesses
        )

        #expect(snapshot.paths.count == maximumPathCount)
        #expect(snapshot.paths.first == defaultAccess.url.path)
        #expect(snapshot.paths[1] == "/Downloads/additional-00000")
        #expect(snapshot.paths.last == "/Downloads/additional-\(zeroPaddedIndex(maximumPathCount - 2))")
        #expect(!snapshot.paths.contains(
            "/Downloads/additional-\(zeroPaddedIndex(maximumPathCount - 1))"
        ))
    }

    @Test("Restoration and projected mutations enforce the distinct capability path limit")
    func restorationAndProjectedMutationsEnforceCapabilityLimit() throws {
        try withIsolatedDefaults { defaults in
            try withTemporaryDirectory { root in
                let maximumPathCount = DownloadFolderCapabilitySnapshot.maximumPathCount
                let oldDefault = root.appending(path: "default", directoryHint: .isDirectory)
                let additionalURLs = (0..<maximumPathCount).map { index in
                    root.appending(
                        path: "additional-\(zeroPaddedIndex(index))",
                        directoryHint: .isDirectory
                    )
                }
                var bookmarks = [String: Data](minimumCapacity: maximumPathCount)
                for url in additionalURLs {
                    bookmarks[accessKey(url)] = Data(url.path.utf8)
                }
                defaults.set(Data(oldDefault.path.utf8), forKey: SecurityScopedFolder.defaultsKey)
                defaults.set(bookmarks, forKey: TorrentBookmarkKeys.additionalDownloadFolders)

                let store = DownloadFolderAccessStore(
                    defaults: defaults,
                    accessProvider: FakeDownloadFolderAccessProvider()
                )
                _ = try store.restoreDefault()

                let restoredBookmarks = additionalBookmarks(in: defaults)
                #expect(restoredBookmarks.count == maximumPathCount - 1)
                #expect(restoredBookmarks[accessKey(additionalURLs[0])] != nil)
                #expect(restoredBookmarks[accessKey(additionalURLs[maximumPathCount - 1])] == nil)
                #expect(store.capabilitySnapshot.paths.count == maximumPathCount)
                #expect(store.capabilitySnapshot.paths.first == oldDefault.path)

                let newAdditional = root.appending(path: "new-additional", directoryHint: .isDirectory)
                do {
                    _ = try store.prepareForAdd(
                        newAdditional,
                        setsDefault: false,
                        activeTorrents: []
                    )
                    Issue.record("Preparing an additional folder beyond the capability limit succeeded")
                } catch {
                    #expect(isTooManyAuthorizedDownloadFolders(error))
                }
                #expect(additionalBookmarks(in: defaults) == restoredBookmarks)
                #expect(defaults.data(forKey: SecurityScopedFolder.defaultsKey) == Data(oldDefault.path.utf8))

                var activeTorrents = restoredBookmarks.values.compactMap { bookmark -> TorrentItem? in
                    guard let path = String(data: bookmark, encoding: .utf8) else {
                        return nil
                    }
                    return makeTorrent(savePath: path)
                }
                activeTorrents.append(makeTorrent(savePath: oldDefault.path))
                let newDefault = root.appending(path: "new-default", directoryHint: .isDirectory)
                do {
                    _ = try store.setDefault(newDefault, activeTorrents: activeTorrents)
                    Issue.record("Setting a default folder beyond the capability limit succeeded")
                } catch {
                    #expect(isTooManyAuthorizedDownloadFolders(error))
                }

                #expect(store.defaultURL?.path == oldDefault.path)
                #expect(defaults.data(forKey: SecurityScopedFolder.defaultsKey) == Data(oldDefault.path.utf8))
                #expect(additionalBookmarks(in: defaults) == restoredBookmarks)
            }
        }
    }

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

private func zeroPaddedIndex(_ index: Int) -> String {
    let digits = String(index)
    return String(repeating: "0", count: max(0, 5 - digits.count)) + digits
}

private func isTooManyAuthorizedDownloadFolders(_ error: Error) -> Bool {
    guard let storeError = error as? TorrentStoreError else {
        return false
    }
    if case .tooManyAuthorizedDownloadFolders = storeError {
        return true
    }
    return false
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
