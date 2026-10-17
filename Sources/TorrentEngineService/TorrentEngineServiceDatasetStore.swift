import Foundation
import TorrentEngineIPC

enum TorrentEngineServiceDatasetError: LocalizedError, Equatable {
    case tooManyOpenDatasets
    case storageLimitExceeded
    case unknownDataset
    case invalidPage
    case expired

    var errorDescription: String? {
        switch self {
        case .tooManyOpenDatasets:
            "Too many torrent engine datasets are open."
        case .storageLimitExceeded:
            "The torrent engine dataset storage limit was exceeded."
        case .unknownDataset:
            "The torrent engine dataset is unavailable."
        case .invalidPage:
            "The requested torrent engine dataset page is invalid."
        case .expired:
            "The torrent engine dataset expired. Request a fresh snapshot."
        }
    }
}

struct TorrentEngineServiceDataset: Sendable {
    enum Contents: Sendable {
        case available(pages: [Data], byteCount: Int, expiresAt: ContinuousClock.Instant)
        case expired
    }

    let descriptor: TorrentEngineIPCDatasetDescriptor
    let ownerControllerID: UUID
    var contents: Contents

    var byteCount: Int {
        switch contents {
        case .available(_, let byteCount, _): byteCount
        case .expired: 0
        }
    }
}

// Owned by the runtime actor. Expiration releases page storage but retains a
// small ownership record until close/disconnect, within the same dataset quota.
// This distinguishes a valid expired handle from an unknown or foreign one.
struct TorrentEngineServiceDatasetStore: Sendable {
    private var datasetsByID = [UUID: TorrentEngineServiceDataset]()

    mutating func expire(at now: ContinuousClock.Instant) {
        for (id, dataset) in datasetsByID {
            if case .available(_, _, let expiresAt) = dataset.contents, now >= expiresAt {
                datasetsByID[id]?.contents = .expired
            }
        }
    }

    mutating func register(_ datasets: [TorrentEngineServiceDataset]) throws {
        guard datasets.count <= TorrentEngineIPCLimits.maximumOpenDatasets,
              datasetsByID.count <= TorrentEngineIPCLimits.maximumOpenDatasets - datasets.count else {
            throw TorrentEngineServiceDatasetError.tooManyOpenDatasets
        }
        let currentBytes = datasetsByID.values.reduce(into: 0) { $0 += $1.byteCount }
        guard Set(datasets.map(\.descriptor.id)).count == datasets.count else {
            throw TorrentEngineServiceDatasetError.storageLimitExceeded
        }
        var projectedBytes = currentBytes
        for dataset in datasets {
            guard dataset.byteCount >= 0,
                  dataset.byteCount <= TorrentEngineIPCLimits.maximumDatasetAggregateBytes - projectedBytes,
                  datasetsByID[dataset.descriptor.id] == nil else {
                throw TorrentEngineServiceDatasetError.storageLimitExceeded
            }
            projectedBytes += dataset.byteCount
        }
        for dataset in datasets {
            datasetsByID[dataset.descriptor.id] = dataset
        }
    }

    mutating func read(
        _ request: TorrentEngineIPCReadDatasetRequest,
        controllerID: UUID,
        now: ContinuousClock.Instant
    ) throws -> TorrentEngineIPCDatasetPage {
        expire(at: now)
        guard let dataset = datasetsByID[request.id], dataset.ownerControllerID == controllerID else {
            throw TorrentEngineServiceDatasetError.unknownDataset
        }
        guard (0..<dataset.descriptor.pageCount).contains(request.page) else {
            throw TorrentEngineServiceDatasetError.invalidPage
        }
        guard case .available(let pages, _, _) = dataset.contents else {
            throw TorrentEngineServiceDatasetError.expired
        }
        return TorrentEngineIPCDatasetPage(
            id: dataset.descriptor.id,
            kind: dataset.descriptor.kind,
            page: request.page,
            encodedItems: pages[request.page]
        )
    }

    mutating func close(_ id: UUID, controllerID: UUID, now: ContinuousClock.Instant) throws {
        expire(at: now)
        guard let dataset = datasetsByID[id], dataset.ownerControllerID == controllerID else {
            throw TorrentEngineServiceDatasetError.unknownDataset
        }
        datasetsByID.removeValue(forKey: id)
    }

    mutating func removeAll() {
        datasetsByID.removeAll()
    }
}
