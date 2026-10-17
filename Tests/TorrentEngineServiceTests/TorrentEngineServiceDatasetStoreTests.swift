import Foundation
import Testing
import TorrentEngineIPC
@testable import TorrentEngineService

@Suite("Controller-owned poll datasets")
struct TorrentEngineServiceDatasetStoreTests {
    @Test("An expired dataset reports expiry only to its owner and remains closable")
    func expirationPreservesOwnership() throws {
        let now = ContinuousClock().now
        let owner = UUID()
        let dataset = makeDataset(owner: owner, now: now)
        var store = TorrentEngineServiceDatasetStore()
        try store.register([dataset])
        let read = TorrentEngineIPCReadDatasetRequest(id: dataset.descriptor.id, page: 0)
        #expect(try store.read(read, controllerID: owner, now: now).encodedItems == Data([1]))
        let expired = now.advanced(by: .seconds(30))
        #expect(throws: TorrentEngineServiceDatasetError.expired) {
            try store.read(read, controllerID: owner, now: expired)
        }
        #expect(throws: TorrentEngineServiceDatasetError.unknownDataset) {
            try store.read(read, controllerID: UUID(), now: expired)
        }
        #expect(throws: TorrentEngineServiceDatasetError.unknownDataset) {
            try store.close(dataset.descriptor.id, controllerID: UUID(), now: expired)
        }
        for page in [-1, 1, Int.max] {
            #expect(throws: TorrentEngineServiceDatasetError.invalidPage) {
                try store.read(
                    TorrentEngineIPCReadDatasetRequest(id: dataset.descriptor.id, page: page),
                    controllerID: owner, now: expired
                )
            }
        }
        try store.close(dataset.descriptor.id, controllerID: owner, now: expired)
        #expect(throws: TorrentEngineServiceDatasetError.unknownDataset) {
            try store.read(read, controllerID: owner, now: expired)
        }
        #expect(throws: TorrentEngineServiceDatasetError.unknownDataset) {
            try store.close(dataset.descriptor.id, controllerID: owner, now: expired)
        }
    }

    @Test("Close can be the first operation after expiration")
    func closeAfterExpiration() throws {
        let now = ContinuousClock().now
        let owner = UUID()
        let dataset = makeDataset(owner: owner, now: now)
        var store = TorrentEngineServiceDatasetStore()
        try store.register([dataset])
        try store.close(dataset.descriptor.id, controllerID: owner, now: now.advanced(by: .seconds(31)))
        try store.register([dataset])
        store.removeAll()
        #expect(throws: TorrentEngineServiceDatasetError.unknownDataset) {
            try store.close(dataset.descriptor.id, controllerID: owner, now: now)
        }
    }

    @Test("Expired ownership records stay bounded until close or disconnect")
    func expiredRecordsRespectQuota() throws {
        let now = ContinuousClock().now
        let owner = UUID()
        let datasets = (0..<TorrentEngineIPCLimits.maximumOpenDatasets).map { _ in
            makeDataset(owner: owner, now: now)
        }
        var store = TorrentEngineServiceDatasetStore()
        try store.register(datasets)
        let expired = now.advanced(by: .seconds(30))
        store.expire(at: expired)
        #expect(throws: TorrentEngineServiceDatasetError.tooManyOpenDatasets) {
            try store.register([makeDataset(owner: owner, now: expired)])
        }
        let first = try #require(datasets.first)
        try store.close(first.descriptor.id, controllerID: owner, now: expired)
        try store.register([makeDataset(owner: owner, now: expired)])
        store.removeAll()
        try store.register(datasets)
    }

    @Test("Expiry releases the encoded-byte quota without dropping ownership")
    func expiredPagesReleaseByteBudget() throws {
        let now = ContinuousClock().now
        let owner = UUID()
        let page = Data(repeating: 0, count: TorrentEngineIPCLimits.maximumDatasetPageBytes)
        let pages = Array(repeating: page, count: 64)
        let first = makeDataset(owner: owner, now: now, pages: pages)
        let second = makeDataset(owner: owner, now: now, pages: pages)
        var store = TorrentEngineServiceDatasetStore()
        try store.register([first, second])
        #expect(throws: TorrentEngineServiceDatasetError.storageLimitExceeded) {
            try store.register([makeDataset(owner: owner, now: now)])
        }
        let expired = now.advanced(by: .seconds(30))
        store.expire(at: expired)
        try store.register([makeDataset(owner: owner, now: expired, pages: pages)])
        #expect(throws: TorrentEngineServiceDatasetError.expired) {
            try store.read(
                TorrentEngineIPCReadDatasetRequest(id: first.descriptor.id, page: 0),
                controllerID: owner, now: expired
            )
        }
    }

    @Test("Only expiry receives the recoverable wire classification")
    func failureClassification() {
        #expect(TorrentEngineServiceRuntime.failureCode(for: TorrentEngineServiceDatasetError.expired) == .datasetExpired)
        for error in [TorrentEngineServiceDatasetError.unknownDataset, .invalidPage, .tooManyOpenDatasets, .storageLimitExceeded] {
            #expect(TorrentEngineServiceRuntime.failureCode(for: error) == .operationRejected)
        }
    }

    private func makeDataset(
        owner: UUID,
        now: ContinuousClock.Instant,
        pages: [Data] = [Data([1])]
    ) -> TorrentEngineServiceDataset {
        TorrentEngineServiceDataset(
            descriptor: TorrentEngineIPCDatasetDescriptor(
                id: UUID(), kind: .torrentSnapshots, revision: 1,
                itemCount: pages.count, pageCount: pages.count
            ),
            ownerControllerID: owner,
            contents: .available(
                pages: pages,
                byteCount: pages.reduce(0) { $0 + $1.count },
                expiresAt: now.advanced(by: .seconds(30))
            )
        )
    }
}
