import Foundation
import Synchronization
import Testing
@testable import TorrentApp
import TorrentAppInfrastructure
import TorrentEngineModel

@MainActor
@Suite("Download folder access store")
struct DownloadFolderAccessStoreTests {
    @Test("Access snapshots put the default first and sort and deduplicate additional paths")
    func accessSnapshotsAreDeterministicAndDeduplicated() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            try await withTemporaryDirectory { root in
                let alpha = root.appending(path: "alpha", directoryHint: .isDirectory)
                let beta = root.appending(path: "beta", directoryHint: .isDirectory)
                defaults.set(Data(beta.torrentFilePath.utf8), forKey: SecurityScopedFolder.defaultsKey)
                defaults.set(
                    [
                        "beta": Data(beta.torrentFilePath.utf8),
                        "alpha": Data(alpha.torrentFilePath.utf8)
                    ],
                    forKey: TorrentBookmarkKeys.additionalDownloadFolders
                )
                let store = DownloadFolderAccessStore(
                    domain: .suite(suiteName),
                    accessProvider: FakeDownloadFolderAccessProvider()
                )

                _ = await store.bootstrap()
                let snapshot = await store.makeAccessSnapshot()

                #expect(snapshot.paths == [
                    beta.torrentFilePath,
                    alpha.torrentFilePath
                ])
            }
        }
    }

    @Test("Access snapshots defensively cap paths while retaining the default first")
    func accessSnapshotsDefensivelyCapPaths() {
        let maximumPathCount = DownloadFolderAccessSnapshot.maximumPathCount
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

        let snapshot = DownloadFolderAccessSnapshot(
            defaultAccess: defaultAccess,
            additionalAccesses: additionalAccesses
        )

        #expect(snapshot.paths.count == maximumPathCount)
        #expect(snapshot.paths.first == defaultAccess.url.torrentFilePath)
        #expect(snapshot.paths[1] == "/Downloads/additional-00000")
        #expect(snapshot.paths.last == "/Downloads/additional-\(zeroPaddedIndex(maximumPathCount - 2))")
        #expect(!snapshot.paths.contains(
            "/Downloads/additional-\(zeroPaddedIndex(maximumPathCount - 1))"
        ))
    }

    @Test("Restoration and projected mutations enforce the distinct access path limit")
    func restorationAndProjectedMutationsEnforceAccessLimit() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            try await withTemporaryDirectory { root in
                let maximumPathCount = DownloadFolderAccessSnapshot.maximumPathCount
                let oldDefault = root.appending(path: "default", directoryHint: .isDirectory)
                let additionalURLs = (0..<maximumPathCount).map { index in
                    root.appending(
                        path: "additional-\(zeroPaddedIndex(index))",
                        directoryHint: .isDirectory
                    )
                }
                var bookmarks = [String: Data](minimumCapacity: maximumPathCount)
                for url in additionalURLs {
                    bookmarks[accessKey(url)] = Data(url.torrentFilePath.utf8)
                }
                defaults.set(Data(oldDefault.torrentFilePath.utf8), forKey: SecurityScopedFolder.defaultsKey)
                defaults.set(bookmarks, forKey: TorrentBookmarkKeys.additionalDownloadFolders)

                let store = DownloadFolderAccessStore(
                    domain: .suite(suiteName),
                    accessProvider: FakeDownloadFolderAccessProvider()
                )
                _ = await store.bootstrap()

                let restoredBookmarks = additionalBookmarks(in: defaults)
                #expect(restoredBookmarks.count == maximumPathCount - 1)
                #expect(restoredBookmarks[accessKey(additionalURLs[0])] != nil)
                #expect(restoredBookmarks[accessKey(additionalURLs[maximumPathCount - 1])] == nil)
                let snapshot = await store.makeAccessSnapshot()
                #expect(snapshot.paths.count == maximumPathCount)
                #expect(snapshot.paths.first == oldDefault.torrentFilePath)

                let newAdditional = root.appending(path: "new-additional", directoryHint: .isDirectory)
                do {
                    _ = try await store.prepareForAdd(
                        newAdditional,
                        setsDefault: false,
                        retaining: Set(restoredBookmarks.values.compactMap {
                            String(data: $0, encoding: .utf8)
                        })
                    )
                    Issue.record("Preparing an additional folder beyond the access limit succeeded")
                } catch {
                    #expect(isTooManyAuthorizedDownloadFolders(error))
                }
                #expect(additionalBookmarks(in: defaults) == restoredBookmarks)
                #expect(defaults.data(forKey: SecurityScopedFolder.defaultsKey) == Data(oldDefault.torrentFilePath.utf8))

                let replacement = try await store.prepareForAdd(
                    newAdditional,
                    setsDefault: false,
                    retaining: []
                )
                #expect(replacement.path == newAdditional.torrentFilePath)
                #expect(additionalBookmarks(in: defaults) == restoredBookmarks)

                var retainedPaths = Set(restoredBookmarks.values.compactMap {
                    String(data: $0, encoding: .utf8)
                })
                retainedPaths.insert(oldDefault.torrentFilePath)
                let newDefault = root.appending(path: "new-default", directoryHint: .isDirectory)
                do {
                    _ = try await store.setDefault(
                        newDefault,
                        retaining: retainedPaths
                    )
                    Issue.record("Setting a default folder beyond the access limit succeeded")
                } catch {
                    #expect(isTooManyAuthorizedDownloadFolders(error))
                }

                #expect(
                    await store.currentDefaultURL()?.torrentFilePath
                        == oldDefault.torrentFilePath
                )
                #expect(defaults.data(forKey: SecurityScopedFolder.defaultsKey) == Data(oldDefault.torrentFilePath.utf8))
                #expect(additionalBookmarks(in: defaults) == restoredBookmarks)
            }
        }
    }

    @Test("Removal leases require an exact active download root")
    func removalLeasesRequireExactActiveRoot() async throws {
        try await withIsolatedDefaults { _, suiteName in
            try await withTemporaryDirectory { root in
                let store = DownloadFolderAccessStore(
                    domain: .suite(suiteName),
                    accessProvider: FakeDownloadFolderAccessProvider()
                )
                let downloads = root.appending(path: "downloads", directoryHint: .isDirectory)
                let other = root.appending(path: "other", directoryHint: .isDirectory)
                _ = try await store.setDefault(
                    downloads,
                    retaining: []
                )

                _ = try await store.lease(
                    forSavePath: downloads.torrentFilePath
                )
                await #expect(throws: TorrentStoreError.self) {
                    try await store.lease(
                        forSavePath: downloads
                            .appending(path: "child").torrentFilePath
                    )
                }
                await #expect(throws: TorrentStoreError.self) {
                    try await store.lease(forSavePath: other.torrentFilePath)
                }
                await #expect(throws: TorrentStoreError.self) {
                    try await store.lease(forSavePath: "relative")
                }
            }
        }
    }

    @Test("A prepared add owns live access without persisting it")
    func preparedAddOwnsLiveAccessWithoutPersistingIt() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            try await withTemporaryDirectory { root in
                let tracker = WeakDownloadFolderAccessTracker()
                let store = DownloadFolderAccessStore(
                    domain: .suite(suiteName),
                    accessProvider: TrackingDownloadFolderAccessProvider(tracker: tracker)
                )
                let folder = root.appending(path: "folder", directoryHint: .isDirectory)
                var prepared: PreparedDownloadFolder? = try await store.prepareForAdd(
                    folder,
                    setsDefault: false,
                    retaining: []
                )

                try await prune(store, retaining: [])

                #expect(additionalBookmarks(in: defaults).isEmpty)
                #expect(tracker.access != nil)
                prepared = nil
                #expect(prepared == nil)
                #expect(tracker.access == nil)
            }
        }
    }

    @Test("Durable storage paths retain only their committed folder bookmarks")
    func durablePathsControlCommittedFolderBookmarks() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            try await withTemporaryDirectory { root in
                let store = DownloadFolderAccessStore(
                    domain: .suite(suiteName),
                    accessProvider: FakeDownloadFolderAccessProvider()
                )
                let folder = root.appending(path: "folder", directoryHint: .isDirectory)

                let prepared = try await store.prepareForAdd(
                    folder,
                    setsDefault: false,
                    retaining: []
                )

                #expect(prepared.path == folder.torrentFilePath)
                #expect(prepared.defaultURL == nil)
                #expect(additionalBookmarks(in: defaults).isEmpty)

                await store.commitPreparedForAdd(
                    prepared,
                    retaining: [folder.torrentFilePath]
                )
                #expect(additionalBookmarks(in: defaults)[accessKey(folder)] == Data(folder.torrentFilePath.utf8))

                try await prune(
                    store,
                    retaining: [folder.torrentFilePath]
                )
                #expect(additionalBookmarks(in: defaults)[accessKey(folder)] == Data(folder.torrentFilePath.utf8))

                try await prune(store, retaining: [])
                #expect(additionalBookmarks(in: defaults)[accessKey(folder)] == nil)
            }
        }
    }

    @Test("Preparing a default folder is side-effect free until commit")
    func preparingDefaultFolderIsSideEffectFreeUntilCommit() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            try await withTemporaryDirectory { root in
                let store = DownloadFolderAccessStore(
                    domain: .suite(suiteName),
                    accessProvider: FakeDownloadFolderAccessProvider()
                )
                let folder = root.appending(path: "folder", directoryHint: .isDirectory)

                let prepared = try await store.prepareForAdd(
                    folder,
                    setsDefault: true,
                    retaining: []
                )

                #expect(await store.currentDefaultURL() == nil)
                #expect(defaults.data(forKey: SecurityScopedFolder.defaultsKey) == nil)

                let committedDefault = await store.commitPreparedForAdd(
                    prepared,
                    retaining: []
                )

                #expect(committedDefault?.torrentFilePath == folder.torrentFilePath)
                #expect(
                    await store.currentDefaultURL()?.torrentFilePath
                        == folder.torrentFilePath
                )
                #expect(defaults.data(forKey: SecurityScopedFolder.defaultsKey) == Data(folder.torrentFilePath.utf8))
            }
        }
    }

    @Test("Setting a new default retains the old folder only while storage uses it")
    func settingNewDefaultRetainsOnlyUsedOldAccess() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            try await withTemporaryDirectory { root in
                let store = DownloadFolderAccessStore(
                    domain: .suite(suiteName),
                    accessProvider: FakeDownloadFolderAccessProvider()
                )
                let oldDefault = root.appending(path: "old", directoryHint: .isDirectory)
                let newDefault = root.appending(path: "new", directoryHint: .isDirectory)

                try await store.setDefault(oldDefault, retaining: [])
                try await store.setDefault(
                    newDefault,
                    retaining: [oldDefault.torrentFilePath]
                )

                #expect(
                    await store.currentDefaultURL()?.torrentFilePath
                        == newDefault.torrentFilePath
                )
                #expect(defaults.data(forKey: SecurityScopedFolder.defaultsKey) == Data(newDefault.torrentFilePath.utf8))
                #expect(additionalBookmarks(in: defaults)[accessKey(oldDefault)] == Data(oldDefault.torrentFilePath.utf8))
                #expect(additionalBookmarks(in: defaults)[accessKey(newDefault)] == nil)

                try await prune(store, retaining: [])
                #expect(additionalBookmarks(in: defaults)[accessKey(oldDefault)] == nil)
            }
        }
    }

    @Test("Restores valid additional bookmarks and drops invalid ones")
    func restoresValidAdditionalBookmarksAndDropsInvalidOnes() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            try await withTemporaryDirectory { root in
                let validFolder = root.appending(path: "valid", directoryHint: .isDirectory)
                let invalidData = Data("invalid".utf8)
                defaults.set(
                    [
                        "stale-key": invalidData,
                        accessKey(validFolder): Data(validFolder.torrentFilePath.utf8)
                    ],
                    forKey: TorrentBookmarkKeys.additionalDownloadFolders
                )

                let store = DownloadFolderAccessStore(
                    domain: .suite(suiteName),
                    accessProvider: FakeDownloadFolderAccessProvider(rejectedBookmarkData: [invalidData])
                )
                _ = await store.bootstrap()

                #expect(additionalBookmarks(in: defaults) == [accessKey(validFolder): Data(validFolder.torrentFilePath.utf8)])
            }
        }
    }

    @Test("Clearing default preserves active default as additional access")
    func clearingDefaultPreservesActiveDefaultAsAdditionalAccess() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            try await withTemporaryDirectory { root in
                let store = DownloadFolderAccessStore(
                    domain: .suite(suiteName),
                    accessProvider: FakeDownloadFolderAccessProvider()
                )
                let defaultFolder = root.appending(path: "default", directoryHint: .isDirectory)
                try await store.setDefault(
                    defaultFolder,
                    retaining: []
                )

                await store.clearDefault(
                    retaining: [defaultFolder.torrentFilePath]
                )

                #expect(await store.currentDefaultURL() == nil)
                #expect(defaults.data(forKey: SecurityScopedFolder.defaultsKey) == nil)
                #expect(additionalBookmarks(in: defaults)[accessKey(defaultFolder)] == Data(defaultFolder.torrentFilePath.utf8))
            }
        }
    }
}

private func prune(
    _ store: DownloadFolderAccessStore,
    retaining paths: Set<String>
) async throws {
    while true {
        let snapshot = await store.makeAccessSnapshot()
        if await store.prune(
            retaining: paths,
            ifRevisionMatches: snapshot.revision
        ) {
            return
        }
    }
}

private func additionalBookmarks(in defaults: UserDefaults) -> [String: Data] {
    defaults.dictionary(forKey: TorrentBookmarkKeys.additionalDownloadFolders) as? [String: Data] ?? [:]
}

private func accessKey(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().torrentFilePath
}

private func zeroPaddedIndex(_ index: Int) -> String {
    let digits = String(index)
    return String(repeating: "0", count: max(0, 5 - digits.count)) + digits
}

private func isTooManyAuthorizedDownloadFolders(_ error: any Error) -> Bool {
    guard let storeError = error as? TorrentStoreError else {
        return false
    }
    if case .tooManyDownloadFolders = storeError {
        return true
    }
    return false
}

private final class WeakDownloadFolderAccessTracker: Sendable {
    private struct State: ~Copyable {
        weak var access: FakeDownloadFolderAccess?
    }

    private let state = Mutex(State())

    var access: FakeDownloadFolderAccess? {
        get {
            state.withLock { $0.access }
        }
        set {
            state.withLock { $0.access = newValue }
        }
    }
}

private struct TrackingDownloadFolderAccessProvider: DownloadFolderAccessProviding {
    let tracker: WeakDownloadFolderAccessTracker

    func createAccess(url: URL, savesBookmark: Bool, defaults: UserDefaults) throws -> any DownloadFolderAccessing {
        let access = FakeDownloadFolderAccess(url: url)
        tracker.access = access
        if savesBookmark {
            defaults.set(try access.bookmarkData(), forKey: SecurityScopedFolder.defaultsKey)
        }
        return access
    }

    func restoreDefault(defaults: UserDefaults) throws -> (any DownloadFolderAccessing)? {
        guard let bookmark = defaults.data(forKey: SecurityScopedFolder.defaultsKey) else {
            return nil
        }
        return try restore(from: bookmark)
    }

    func restore(from bookmark: Data) throws -> any DownloadFolderAccessing {
        guard let path = String(data: bookmark, encoding: .utf8), !path.isEmpty else {
            throw FakeBookmarkError()
        }
        let access = FakeDownloadFolderAccess(url: URL(filePath: path, directoryHint: .isDirectory))
        tracker.access = access
        return access
    }

    func clearDefaultBookmark(defaults: UserDefaults) {
        defaults.removeObject(forKey: SecurityScopedFolder.defaultsKey)
    }
}
