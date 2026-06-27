import Testing
@testable import TorrentApp

@Suite("Torrent completion history")
struct TorrentCompletionHistoryStoreTests {
    @Test("Persists remembered completions")
    func persistsRememberedCompletions() throws {
        try withIsolatedDefaults { defaults in
            let store = TorrentCompletionHistoryStore(defaults: defaults)
            store.remember(["alpha", "beta"])

            let reloadedStore = TorrentCompletionHistoryStore(defaults: defaults)
            #expect(reloadedStore.contains("alpha"))
            #expect(reloadedStore.contains("beta"))
            #expect(!reloadedStore.contains("gamma"))
        }
    }

    @Test("Forgets and prunes completions")
    func forgetsAndPrunesCompletions() throws {
        try withIsolatedDefaults { defaults in
            let store = TorrentCompletionHistoryStore(defaults: defaults)
            store.remember(["alpha", "beta", "gamma"])

            store.forget(["beta"])
            store.prune(retaining: ["alpha", "delta"])

            let reloadedStore = TorrentCompletionHistoryStore(defaults: defaults)
            #expect(reloadedStore.contains("alpha"))
            #expect(!reloadedStore.contains("beta"))
            #expect(!reloadedStore.contains("gamma"))
        }
    }

    @Test("Removes persisted key when completion history becomes empty")
    func removesPersistedKeyWhenCompletionHistoryBecomesEmpty() throws {
        try withIsolatedDefaults { defaults in
            let store = TorrentCompletionHistoryStore(defaults: defaults)
            store.remember(["alpha"])
            store.forget(["alpha"])

            #expect(defaults.stringArray(forKey: TorrentCompletionKeys.completedTorrentIDs) == nil)
        }
    }
}
