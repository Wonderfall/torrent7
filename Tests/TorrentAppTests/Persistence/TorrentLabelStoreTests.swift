import Testing
@testable import TorrentApp

@Suite("Torrent label store")
struct TorrentLabelStoreTests {
    @Test("Normalizes label names to a bounded display length")
    func normalizesLabelNamesToBoundedDisplayLength() {
        let name = String(repeating: "A", count: TorrentLabel.maxNameLength + 20)

        #expect(TorrentLabel.normalizedName("  \(name)  ") == String(repeating: "A", count: TorrentLabel.maxNameLength))
    }

    @Test("Persists labels and valid assignments")
    func persistsLabelsAndValidAssignments() throws {
        try withIsolatedDefaults { defaults in
            let store = TorrentLabelStore(defaults: defaults)
            let linux = TorrentLabel(id: "linux", name: "Linux")
            let iso = TorrentLabel(id: "iso", name: "ISO")

            store.save(labels: [linux, iso], assignments: [
                "alpha": ["linux", "missing"],
                "beta": ["iso"]
            ])

            let loaded = store.load()

            #expect(loaded.labels == [linux, iso])
            #expect(loaded.assignments["alpha"] == ["linux"])
            #expect(loaded.assignments["beta"] == ["iso"])
            #expect(loaded.assignments["missing"] == nil)
        }
    }
}
