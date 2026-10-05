package import TorrentEngineModel

/// Keeps refreshes and re-sorts on the newest accepted authoritative snapshot.
package struct TorrentFilePresentationState: Sendable {
    package private(set) var latestBatch: TorrentFileBatch?
    package private(set) var tree = TorrentFileTree.empty

    package init() {}

    @discardableResult
    package mutating func accept(_ batch: TorrentFileBatch) -> Bool {
        guard latestBatch.map({ batch.revision >= $0.revision }) ?? true else { return false }
        latestBatch = batch
        return true
    }

    package mutating func apply(_ presentation: TorrentFileBatchPresentation) -> Bool {
        guard accept(presentation.sourceBatch) else { return false }
        tree = presentation.tree
        return true
    }
}

package struct TorrentFileBatchPresentation: Sendable {
    package let sourceBatch: TorrentFileBatch
    package var revision: UInt64 { sourceBatch.revision }
    package let tree: TorrentFileTree
    package let remainingPendingPriorities: [Int32: TorrentFilePriority]

    @concurrent
    package static func prepare(
        batch: TorrentFileBatch,
        pendingPriorities: [Int32: TorrentFilePriority],
        sortOrder: [TorrentFileTree.Sort] = [TorrentFileTree.Sort(.name)]
    ) async throws -> Self {
        try Task.checkCancellation()
        var files = [TorrentFileItem]()
        files.reserveCapacity(batch.files.count)
        var remaining = pendingPriorities
        for (offset, file) in batch.files.enumerated() {
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
            if pendingPriorities[file.index] == file.priority {
                remaining.removeValue(forKey: file.index)
            }
            files.append(file.withPriority(remaining[file.index] ?? file.priority))
        }
        let tree = try await TorrentFileTree.prepare(files: files, sortOrder: sortOrder)
        return Self(sourceBatch: batch, tree: tree, remainingPendingPriorities: remaining)
    }
}

package struct TorrentAddFileSelectionPresentation: Sendable {
    package let generation: UInt64
    package let filePriorities: [Int32: TorrentFilePriority]?
    package let overrides: [Int32: TorrentFilePriority]
    package let selectedFileCount: Int
    package let selectedFileSize: Int64
    package let tree: TorrentFileTree

    package var hasDownloadableFile: Bool { selectedFileCount > 0 }

    @concurrent
    package static func prepare(
        generation: UInt64,
        files: [TorrentFileItem],
        bulkPriority: TorrentFilePriority?,
        overrides: [Int32: TorrentFilePriority],
        change: TorrentFilePriorityChange? = nil,
        sortOrder: [TorrentFileTree.Sort] = [TorrentFileTree.Sort(.name)]
    ) async throws -> Self {
        try Task.checkCancellation()
        let changedIndices = Set(change?.fileIndices ?? [])
        var overrides = overrides
        var priorities = [Int32: TorrentFilePriority]()
        var presentedFiles = [TorrentFileItem]()
        presentedFiles.reserveCapacity(files.count)
        var selectedFileCount = 0
        var selectedFileSize: Int64 = 0

        for (offset, file) in files.enumerated() {
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
            guard !file.isPadFile else { continue }
            if let change, changedIndices.contains(file.index) {
                if change.priority == (bulkPriority ?? file.priority) {
                    overrides.removeValue(forKey: file.index)
                } else {
                    overrides[file.index] = change.priority
                }
            }
            let priority = overrides[file.index] ?? bulkPriority ?? file.priority
            presentedFiles.append(file.withPriority(priority))
            if priority != .normal { priorities[file.index] = priority }
            guard priority != .skip else { continue }
            selectedFileCount += 1
            let size = max(0, file.size)
            selectedFileSize = selectedFileSize > Int64.max - size ? .max : selectedFileSize + size
        }

        let tree = try await TorrentFileTree.prepare(files: presentedFiles, sortOrder: sortOrder)
        try Task.checkCancellation()
        return Self(
            generation: generation,
            filePriorities: priorities.isEmpty ? nil : priorities,
            overrides: overrides,
            selectedFileCount: selectedFileCount,
            selectedFileSize: selectedFileSize,
            tree: tree
        )
    }
}
