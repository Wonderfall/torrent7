import Testing
import TorrentEngineModel
@testable import TorrentApp

@Suite("Torrent label store")
struct TorrentLabelStoreTests {
    @Test("Normalizes label names to a bounded display length")
    func normalizesLabelNamesToBoundedDisplayLength() {
        let name = String(repeating: "A", count: TorrentLabel.maxNameLength + 20)

        #expect(TorrentLabel.normalizedName("  \(name)  ") == String(repeating: "A", count: TorrentLabel.maxNameLength))
    }

    @Test("Persists labels and valid assignments")
    func persistsLabelsAndValidAssignments() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            let persistenceStore = TorrentLabelPersistenceStore(domain: .suite(suiteName))
            let linux = TorrentLabel(id: "linux", name: "Linux")
            let iso = TorrentLabel(id: "iso", name: "ISO")

            try await persistenceStore.save(
                labels: [linux, iso],
                assignments: [
                    "alpha": ["linux", "missing"],
                    "beta": ["iso"]
                ],
                revision: 1
            )

            let store = TorrentLabelStore(defaults: defaults)
            let loaded = store.load()

            #expect(loaded.labels == [linux, iso])
            #expect(loaded.assignments["alpha"] == ["linux"])
            #expect(loaded.assignments["beta"] == ["iso"])
            #expect(loaded.assignments["missing"] == nil)
        }
    }

    @Test("Caps labels before publishing persisted data")
    func capsPersistedLabels() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            let labels = (0..<(TorrentLabel.maximumCount + 20)).map {
                TorrentLabel(id: "label-\($0)", name: "Label \($0)")
            }
            let persistenceStore = TorrentLabelPersistenceStore(
                domain: .suite(suiteName)
            )

            try await persistenceStore.save(
                labels: labels,
                assignments: [:],
                revision: 1
            )

            let loaded = TorrentLabelStore(defaults: defaults).load()
            #expect(loaded.labels.count == TorrentLabel.maximumCount)
        }
    }

    @Test("Cancelled preparation does not publish partial label data")
    func cancelledPreparationThrows() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            let assignments = Dictionary(
                uniqueKeysWithValues: (0..<20_000).map { index in
                    ("torrent-\(index)", Set(["linux"]))
                }
            )
            let task = Task {
                try await TorrentLabelPersistenceStore(domain: .suite(suiteName)).save(
                    labels: [TorrentLabel(id: "linux", name: "Linux")],
                    assignments: assignments,
                    revision: 1
                )
            }

            task.cancel()

            await #expect(throws: CancellationError.self) {
                try await task.value
            }
            #expect(defaults.data(forKey: TorrentLabelStore.defaultsKey) == nil)
        }
    }

    @Test("Label pruning prepares a replacement without mutating its snapshot")
    func labelPruningPreparesReplacement() async throws {
        let assignments: [TorrentItem.ID: Set<TorrentLabel.ID>] = [
            "active": ["linux"],
            "stale": ["iso"],
        ]

        let plan = try await TorrentLabelPrunePlan.prepare(
            assignments: assignments,
            activeTorrentIDs: ["active"],
            revision: 7
        )

        #expect(plan.revision == 7)
        #expect(plan.assignments == ["active": ["linux"]])
        #expect(assignments["stale"] == ["iso"])
    }

    @Test("Bulk label toggles prepare one atomic replacement")
    func bulkLabelTogglePreparesAtomicReplacement() async throws {
        let labels = [TorrentLabel(id: "linux", name: "Linux")]
        let assignments: [
            TorrentItem.ID: Set<TorrentLabel.ID>
        ] = [
            "alpha": ["linux"],
        ]

        let plan = try await TorrentLabelMutationPlan.prepare(
            request: .toggle(
                labelID: "linux",
                torrentIDs: ["alpha", "beta", "missing"]
            ),
            labels: labels,
            assignments: assignments,
            activeTorrentIDs: ["alpha", "beta"],
            revision: 8
        )
        let snapshot = try #require(plan.snapshot)

        #expect(plan.revision == 8)
        #expect(snapshot.assignments["alpha"] == ["linux"])
        #expect(snapshot.assignments["beta"] == ["linux"])
        #expect(snapshot.assignments["missing"] == nil)
        #expect(assignments["beta"] == nil)
    }

    @Test("Deleting a label removes every assignment off the UI actor")
    func deletingLabelPreparesAtomicReplacement() async throws {
        let linux = TorrentLabel(id: "linux", name: "Linux")
        let iso = TorrentLabel(id: "iso", name: "ISO")

        let plan = try await TorrentLabelMutationPlan.prepare(
            request: .delete(labelID: linux.id),
            labels: [linux, iso],
            assignments: [
                "alpha": [linux.id, iso.id],
                "beta": [linux.id],
            ],
            activeTorrentIDs: ["alpha", "beta"],
            revision: 3
        )
        let snapshot = try #require(plan.snapshot)

        #expect(snapshot.labels == [iso])
        #expect(snapshot.assignments["alpha"] == [iso.id])
        #expect(snapshot.assignments["beta"] == nil)
    }

    @Test("Cancelled bulk label mutation cannot return a partial snapshot")
    func cancelledBulkLabelMutationThrows() async {
        let assignments = Dictionary(
            uniqueKeysWithValues: (0..<20_000).map { index in
                ("torrent-\(index)", Set(["linux"]))
            }
        )
        let task = Task {
            try await TorrentLabelMutationPlan.prepare(
                request: .delete(labelID: "linux"),
                labels: [TorrentLabel(id: "linux", name: "Linux")],
                assignments: assignments,
                activeTorrentIDs: Set(assignments.keys),
                revision: 1
            )
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
