import Testing
@testable import TorrentApp

@Suite("Torrent completion history")
struct TorrentCompletionHistoryStoreTests {
    @Test("Persists remembered completions")
    func persistsRememberedCompletions() async throws {
        try await withIsolatedDefaults { _, suiteName in
            let store = TorrentCompletionHistoryStore(suiteName: suiteName)
            try await store.remember(["alpha", "beta"])

            let reloadedStore = TorrentCompletionHistoryStore(suiteName: suiteName)
            #expect(try await reloadedStore.contains("alpha"))
            #expect(try await reloadedStore.contains("beta"))
            #expect(!(try await reloadedStore.contains("gamma")))
        }
    }

    @Test("Forgets and prunes completions")
    func forgetsAndPrunesCompletions() async throws {
        try await withIsolatedDefaults { _, suiteName in
            let store = TorrentCompletionHistoryStore(suiteName: suiteName)
            try await store.remember(["alpha", "beta", "gamma"])

            try await store.forget(["beta"])
            try await store.prune(retaining: ["alpha", "delta"])

            let reloadedStore = TorrentCompletionHistoryStore(suiteName: suiteName)
            #expect(try await reloadedStore.contains("alpha"))
            #expect(!(try await reloadedStore.contains("beta")))
            #expect(!(try await reloadedStore.contains("gamma")))
        }
    }

    @Test("Removes persisted key when completion history becomes empty")
    func removesPersistedKeyWhenCompletionHistoryBecomesEmpty() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            let store = TorrentCompletionHistoryStore(suiteName: suiteName)
            try await store.remember(["alpha"])
            try await store.forget(["alpha"])

            #expect(defaults.stringArray(forKey: TorrentCompletionKeys.completedTorrentIDs) == nil)
        }
    }

    @Test("Claims deduplicate candidates and reserve in-flight completions")
    func claimsDeduplicateAndReserveCompletions() async throws {
        try await withIsolatedDefaults { _, suiteName in
            let store = TorrentCompletionHistoryStore(
                suiteName: suiteName
            )
            let alpha = TorrentCompletionCandidate(
                id: "alpha",
                name: "Alpha"
            )
            let firstClaim = try await store.claimNewlyCompleted(
                from: [alpha, alpha]
            )
            let overlappingClaim =
                try await store.claimNewlyCompleted(
                    from: [
                        alpha,
                        TorrentCompletionCandidate(
                            id: "beta",
                            name: "Beta"
                        ),
                    ]
                )

            #expect(firstClaim.candidates.map(\.id) == ["alpha"])
            #expect(
                overlappingClaim.candidates.map(\.id) == ["beta"]
            )

            await store.abandonCompletionClaim(firstClaim.id)
            let retriedClaim = try await store.claimNewlyCompleted(
                from: [alpha]
            )
            #expect(retriedClaim.candidates.map(\.id) == ["alpha"])

            await store.finalizeCompletionClaim(
                overlappingClaim.id,
                remembering: ["beta"]
            )
            await store.finalizeCompletionClaim(
                retriedClaim.id,
                remembering: ["alpha"]
            )
            #expect(try await store.contains("alpha"))
            #expect(try await store.contains("beta"))
        }
    }
}
