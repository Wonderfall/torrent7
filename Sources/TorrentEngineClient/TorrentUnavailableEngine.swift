import Foundation
import TorrentEngineModel

/// A transport-neutral placeholder used while the isolated service is starting
/// or after startup failed. It intentionally has no native-code dependency.
package actor TorrentUnavailableEngine: TorrentEngineServicing {
    package nonisolated let startupFailureMessage: String?
    package nonisolated let libtorrentVersion = "Unknown"
    package nonisolated let isAvailable = false

    package init(message: String) {
        startupFailureMessage = message
    }

    package func shutdown() async {}
    package func terminateConnection(
        recoveryDisposition: TorrentEngineRecoveryDisposition
    ) async {
        _ = recoveryDisposition
    }

    package func restart(
        enablePeerExchangePlugin: Bool,
        authorizedSavePaths: [String]
    ) throws {
        _ = enablePeerExchangePlugin
        _ = authorizedSavePaths
        throw unavailableError
    }

    package func delegateFolderAuthorization(
        _ authorization: TorrentFolderAuthorization
    ) throws {
        _ = authorization
        throw unavailableError
    }

    package func reconcileFolderAuthorizations(
        _ authorizations: [TorrentFolderAuthorization]
    ) throws {
        _ = authorizations
        throw unavailableError
    }

    package func wakeEvents() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }

    package func addMagnet(
        _ magnet: String,
        savePath: String,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        enablePeerExchange: Bool,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool,
        allowPreMetadataDHT: Bool
    ) throws -> String {
        _ = magnet
        _ = savePath
        _ = startsPaused
        _ = queuePriority
        _ = enablePeerExchange
        _ = allowNonHTTPSTrackers
        _ = allowNonHTTPSWebSeeds
        _ = allowPreMetadataDHT
        throw unavailableError
    }

    package func addTorrentFile(
        data: Data,
        savePath: String,
        filePriorities: [Int32: TorrentFilePriority]?,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        enablePeerExchange: Bool,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool
    ) throws -> String {
        _ = data
        _ = savePath
        _ = filePriorities
        _ = startsPaused
        _ = queuePriority
        _ = enablePeerExchange
        _ = allowNonHTTPSTrackers
        _ = allowNonHTTPSWebSeeds
        throw unavailableError
    }

    package func previewTorrentFile(data: Data) throws -> TorrentFilePreview {
        _ = data
        throw unavailableError
    }

    package func pause(id: String) throws { _ = id; throw unavailableError }
    package func resume(id: String) throws { _ = id; throw unavailableError }
    package func reannounce(id: String) throws { _ = id; throw unavailableError }
    package func forceRecheck(id: String) throws { _ = id; throw unavailableError }

    package func remove(id: String, deleteFiles: Bool) throws -> TorrentRemovalOutcome {
        _ = id
        _ = deleteFiles
        throw unavailableError
    }

    package func applySettings(
        _ settings: TorrentSettings,
        networkBinding: TorrentNetworkBinding
    ) throws {
        _ = settings
        _ = networkBinding
        throw unavailableError
    }

    package func blockNetworkNow() throws -> TorrentNetworkBlockDisposition { throw unavailableError }
    package func saveAll() {}
    package func saveAllChecked() throws { throw unavailableError }
    package func takeAlertError() -> String? { nil }
    package func takeChanges() -> UInt32 { 0 }
    package func networkStatus() -> TorrentNetworkStatus { .empty }
    package func bridgeHealth() -> TorrentBridgeHealth { .unavailable }

    package func poll(
        since revision: UInt64?,
        sortedBy sortOrder: TorrentSortOrder,
        direction: TorrentSortDirection,
        includeTrackerHosts: Bool
    ) -> TorrentEnginePollResult {
        _ = revision
        _ = sortOrder
        _ = direction
        _ = includeTrackerHosts
        return TorrentEnginePollResult(
            isAuthoritative: false,
            dirtyMask: 0,
            alertErrors: [],
            networkStatus: .empty,
            bridgeHealth: .unavailable,
            snapshotBatch: nil,
            trackerHostBatch: nil
        )
    }

    package func snapshotsIfChanged(
        since revision: UInt64?,
        sortedBy sortOrder: TorrentSortOrder,
        direction: TorrentSortDirection
    ) -> TorrentSnapshotBatch? {
        _ = revision
        _ = sortOrder
        _ = direction
        return nil
    }

    package func requestSources(id: String) throws { _ = id; throw unavailableError }
    package func sourcePolicy(id: String) throws -> TorrentSourcePolicy { _ = id; throw unavailableError }

    package func setSourcePolicy(
        id: String,
        field: TorrentSourcePolicyField,
        enabled: Bool
    ) throws {
        _ = id
        _ = field
        _ = enabled
        throw unavailableError
    }

    package func torrentOptions(id: String) throws -> TorrentOptions { _ = id; throw unavailableError }

    package func setTorrentOptions(id: String, options: TorrentOptions) throws {
        _ = id
        _ = options
        throw unavailableError
    }

    package func moveTorrentInQueue(id: String, move: TorrentQueueMove) throws {
        _ = id
        _ = move
        throw unavailableError
    }

    package func requestFiles(id: String) throws { _ = id; throw unavailableError }

    package func setFilePriority(
        id: String,
        fileIndex: Int32,
        priority: TorrentFilePriority
    ) throws {
        _ = id
        _ = fileIndex
        _ = priority
        throw unavailableError
    }

    package func requestPieceMap(id: String) throws { _ = id; throw unavailableError }
    package func trackerBatch(id: String, since revision: UInt64?) -> TorrentTrackerBatch? { nil }
    package func trackerHostBatch() -> TorrentTrackerHostBatch { .init(revision: 0, hosts: []) }
    package func webSeedBatch(id: String, since revision: UInt64?) -> TorrentWebSeedBatch? { nil }
    package func webSeedActivity(id: String) -> TorrentWebSeedActivity? { nil }
    package func peerSources(id: String) -> TorrentPeerSources? { nil }
    package func fileBatch(id: String, since revision: UInt64?) -> TorrentFileBatch? { nil }
    package func pieceMapBatch(id: String, since revision: UInt64?) -> TorrentPieceMapBatch? { nil }

    private var unavailableError: TorrentEngineError {
        .startupFailed(startupFailureMessage ?? "")
    }
}
