import Foundation
import TorrentEngineModel

package struct TorrentEngineIPCEmpty: Codable, Equatable, Sendable {
    package init() {}
}

package struct TorrentEngineIPCValue<Value: Codable & Sendable>: Codable, Sendable {
    package let value: Value

    package init(_ value: Value) {
        self.value = value
    }
}

package struct TorrentEngineIPCOptionalValue<Value: Codable & Sendable>: Codable, Sendable {
    package let value: Value?

    package init(_ value: Value?) {
        self.value = value
    }
}

package enum TorrentEngineIPCPeerAuthentication: String, Codable, Sendable {
    case sameTeam
    case reducedAssuranceAdHocDevelopment
}

package struct TorrentEngineIPCFolderGrant: Codable, Equatable, Sendable {
    package let bookmark: Data
    package let provisional: Bool

    package init(bookmark: Data, provisional: Bool) {
        self.bookmark = bookmark
        self.provisional = provisional
    }
}

package struct TorrentEngineIPCGrantedFolder: Codable, Equatable, Sendable {
    package let capabilityID: UUID
    package let resolvedPath: String

    package init(capabilityID: UUID, resolvedPath: String) {
        self.capabilityID = capabilityID
        self.resolvedPath = resolvedPath
    }
}

package struct TorrentEngineIPCHandshakeRequest: Codable, Equatable, Sendable {
    package let enablePeerExchangePlugin: Bool
    package let authentication: TorrentEngineIPCPeerAuthentication
    package let folders: [TorrentEngineIPCFolderGrant]

    package init(
        enablePeerExchangePlugin: Bool,
        authentication: TorrentEngineIPCPeerAuthentication,
        folders: [TorrentEngineIPCFolderGrant]
    ) {
        self.enablePeerExchangePlugin = enablePeerExchangePlugin
        self.authentication = authentication
        self.folders = folders
    }
}

package struct TorrentEngineIPCHandshakeResponse: Codable, Equatable, Sendable {
    package let libtorrentVersion: String
    package let folders: [TorrentEngineIPCGrantedFolder]

    package init(libtorrentVersion: String, folders: [TorrentEngineIPCGrantedFolder]) {
        self.libtorrentVersion = libtorrentVersion
        self.folders = folders
    }
}

package struct TorrentEngineIPCRestartRequest: Codable, Equatable, Sendable {
    package let enablePeerExchangePlugin: Bool
    package let capabilityIDs: [UUID]

    package init(enablePeerExchangePlugin: Bool, capabilityIDs: [UUID]) {
        self.enablePeerExchangePlugin = enablePeerExchangePlugin
        self.capabilityIDs = capabilityIDs
    }
}

package struct TorrentEngineIPCGrantFolderResponse: Codable, Equatable, Sendable {
    package let folder: TorrentEngineIPCGrantedFolder

    package init(folder: TorrentEngineIPCGrantedFolder) {
        self.folder = folder
    }
}

package struct TorrentEngineIPCRevokeFolderRequest: Codable, Equatable, Sendable {
    package let capabilityID: UUID

    package init(capabilityID: UUID) {
        self.capabilityID = capabilityID
    }
}

package struct TorrentEngineIPCReplaceFoldersRequest: Codable, Equatable, Sendable {
    package let folders: [TorrentEngineIPCFolderGrant]

    package init(folders: [TorrentEngineIPCFolderGrant]) {
        self.folders = folders
    }
}

package struct TorrentEngineIPCReplaceFoldersResponse: Codable, Equatable, Sendable {
    package let folders: [TorrentEngineIPCGrantedFolder]

    package init(folders: [TorrentEngineIPCGrantedFolder]) {
        self.folders = folders
    }
}

package struct TorrentEngineIPCAddMagnetRequest: Codable, Equatable, Sendable {
    package let magnet: String
    package let folderCapabilityID: UUID
    package let startsPaused: Bool
    package let queuePriority: TorrentQueuePriority
    package let enablePeerExchange: Bool
    package let allowNonHTTPSTrackers: Bool
    package let allowNonHTTPSWebSeeds: Bool
    package let allowPreMetadataDHT: Bool

    package init(
        magnet: String,
        folderCapabilityID: UUID,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        enablePeerExchange: Bool,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool,
        allowPreMetadataDHT: Bool
    ) {
        self.magnet = magnet
        self.folderCapabilityID = folderCapabilityID
        self.startsPaused = startsPaused
        self.queuePriority = queuePriority
        self.enablePeerExchange = enablePeerExchange
        self.allowNonHTTPSTrackers = allowNonHTTPSTrackers
        self.allowNonHTTPSWebSeeds = allowNonHTTPSWebSeeds
        self.allowPreMetadataDHT = allowPreMetadataDHT
    }
}

package struct TorrentEngineIPCFilePriorityEntry: Codable, Equatable, Sendable {
    package let index: Int32
    package let priority: TorrentFilePriority

    package init(index: Int32, priority: TorrentFilePriority) {
        self.index = index
        self.priority = priority
    }
}

package struct TorrentEngineIPCAddTorrentFileRequest: Codable, Equatable, Sendable {
    package let torrentData: Data
    package let folderCapabilityID: UUID
    package let filePriorities: [TorrentEngineIPCFilePriorityEntry]?
    package let startsPaused: Bool
    package let queuePriority: TorrentQueuePriority
    package let enablePeerExchange: Bool
    package let allowNonHTTPSTrackers: Bool
    package let allowNonHTTPSWebSeeds: Bool

    package init(
        torrentData: Data,
        folderCapabilityID: UUID,
        filePriorities: [TorrentEngineIPCFilePriorityEntry]?,
        startsPaused: Bool,
        queuePriority: TorrentQueuePriority,
        enablePeerExchange: Bool,
        allowNonHTTPSTrackers: Bool,
        allowNonHTTPSWebSeeds: Bool
    ) {
        self.torrentData = torrentData
        self.folderCapabilityID = folderCapabilityID
        self.filePriorities = filePriorities
        self.startsPaused = startsPaused
        self.queuePriority = queuePriority
        self.enablePeerExchange = enablePeerExchange
        self.allowNonHTTPSTrackers = allowNonHTTPSTrackers
        self.allowNonHTTPSWebSeeds = allowNonHTTPSWebSeeds
    }
}

/// A dictionary-rooted add response suitable for binary property-list encoding.
///
/// `PropertyListEncoder` rejects scalar top-level values, so torrent identifiers
/// must never be encoded as a bare `String` on the XPC wire.
package struct TorrentEngineIPCAddedTorrentResponse: Codable, Equatable, Sendable {
    package let identifier: String

    package init(identifier: String) {
        self.identifier = identifier
    }
}

package struct TorrentEngineIPCTorrentIDRequest: Codable, Equatable, Sendable {
    package let id: String

    package init(id: String) {
        self.id = id
    }
}

package struct TorrentEngineIPCTorrentRevisionRequest: Codable, Equatable, Sendable {
    package let id: String
    package let revision: UInt64?

    package init(id: String, revision: UInt64?) {
        self.id = id
        self.revision = revision
    }
}

package struct TorrentEngineIPCRemoveRequest: Codable, Equatable, Sendable {
    package let id: String
    package let deleteFiles: Bool

    package init(id: String, deleteFiles: Bool) {
        self.id = id
        self.deleteFiles = deleteFiles
    }
}

package struct TorrentEngineIPCRemovalResponse: Codable, Equatable, Sendable {
    package let outcome: TorrentRemovalOutcome

    package init(outcome: TorrentRemovalOutcome) {
        self.outcome = outcome
    }
}

package struct TorrentEngineIPCApplySettingsRequest: Codable, Equatable, Sendable {
    package let settings: TorrentSettings
    package let networkBinding: TorrentNetworkBinding

    package init(settings: TorrentSettings, networkBinding: TorrentNetworkBinding) {
        self.settings = settings
        self.networkBinding = networkBinding
    }
}

package struct TorrentEngineIPCPollRequest: Codable, Equatable, Sendable {
    package let snapshotRevision: UInt64?
    package let sortOrder: TorrentSortOrder
    package let sortDirection: TorrentSortDirection
    package let includeSnapshot: Bool
    package let includeTrackerHosts: Bool

    package init(
        snapshotRevision: UInt64?,
        sortOrder: TorrentSortOrder,
        sortDirection: TorrentSortDirection,
        includeSnapshot: Bool = true,
        includeTrackerHosts: Bool
    ) {
        self.snapshotRevision = snapshotRevision
        self.sortOrder = sortOrder
        self.sortDirection = sortDirection
        self.includeSnapshot = includeSnapshot
        self.includeTrackerHosts = includeTrackerHosts
    }
}

package enum TorrentEngineIPCDatasetKind: String, Codable, Sendable {
    case torrentSnapshots
    case trackerHosts
}

package struct TorrentEngineIPCDatasetDescriptor: Codable, Equatable, Sendable {
    package let id: UUID
    package let kind: TorrentEngineIPCDatasetKind
    package let revision: UInt64
    package let itemCount: Int
    package let pageCount: Int

    package init(
        id: UUID,
        kind: TorrentEngineIPCDatasetKind,
        revision: UInt64,
        itemCount: Int,
        pageCount: Int
    ) {
        self.id = id
        self.kind = kind
        self.revision = revision
        self.itemCount = itemCount
        self.pageCount = pageCount
    }
}

package struct TorrentEngineIPCPollResponse: Codable, Sendable {
    package let dirtyMask: UInt32
    package let alertErrors: [String]
    package let networkStatus: TorrentNetworkStatus
    package let bridgeHealth: TorrentBridgeHealth
    package let networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot
    package let snapshotDataset: TorrentEngineIPCDatasetDescriptor?
    package let trackerHostDataset: TorrentEngineIPCDatasetDescriptor?

    package init(
        dirtyMask: UInt32,
        alertErrors: [String],
        networkStatus: TorrentNetworkStatus,
        bridgeHealth: TorrentBridgeHealth,
        networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot,
        snapshotDataset: TorrentEngineIPCDatasetDescriptor?,
        trackerHostDataset: TorrentEngineIPCDatasetDescriptor?
    ) {
        self.dirtyMask = dirtyMask
        self.alertErrors = alertErrors
        self.networkStatus = networkStatus
        self.bridgeHealth = bridgeHealth
        self.networkInterfaceSnapshot = networkInterfaceSnapshot
        self.snapshotDataset = snapshotDataset
        self.trackerHostDataset = trackerHostDataset
    }
}

package struct TorrentEngineIPCReadDatasetRequest: Codable, Equatable, Sendable {
    package let id: UUID
    package let page: Int

    package init(id: UUID, page: Int) {
        self.id = id
        self.page = page
    }
}

package struct TorrentEngineIPCDatasetPage: Codable, Equatable, Sendable {
    package let id: UUID
    package let kind: TorrentEngineIPCDatasetKind
    package let page: Int
    package let encodedItems: Data

    package init(id: UUID, kind: TorrentEngineIPCDatasetKind, page: Int, encodedItems: Data) {
        self.id = id
        self.kind = kind
        self.page = page
        self.encodedItems = encodedItems
    }
}

package struct TorrentEngineIPCCloseDatasetRequest: Codable, Equatable, Sendable {
    package let id: UUID

    package init(id: UUID) {
        self.id = id
    }
}

package struct TorrentEngineIPCSetSourcePolicyRequest: Codable, Equatable, Sendable {
    package let id: String
    package let field: TorrentSourcePolicyField
    package let enabled: Bool

    package init(id: String, field: TorrentSourcePolicyField, enabled: Bool) {
        self.id = id
        self.field = field
        self.enabled = enabled
    }
}

package struct TorrentEngineIPCSetTorrentOptionsRequest: Codable, Equatable, Sendable {
    package let id: String
    package let options: TorrentOptions

    package init(id: String, options: TorrentOptions) {
        self.id = id
        self.options = options
    }
}

package struct TorrentEngineIPCMoveQueueRequest: Codable, Equatable, Sendable {
    package let id: String
    package let move: TorrentQueueMove

    package init(id: String, move: TorrentQueueMove) {
        self.id = id
        self.move = move
    }
}

package struct TorrentEngineIPCSetFilePriorityRequest: Codable, Equatable, Sendable {
    package let id: String
    package let fileIndex: Int32
    package let priority: TorrentFilePriority

    package init(id: String, fileIndex: Int32, priority: TorrentFilePriority) {
        self.id = id
        self.fileIndex = fileIndex
        self.priority = priority
    }
}

package struct TorrentEngineIPCStateMigrationBeginResponse: Codable, Equatable, Sendable {
    package let alreadyComplete: Bool

    package init(alreadyComplete: Bool) {
        self.alreadyComplete = alreadyComplete
    }
}

package struct TorrentEngineIPCStateMigrationFileRequest: Codable, Equatable, Sendable {
    package let name: String

    package init(name: String) {
        self.name = name
    }
}
