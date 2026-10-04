package import Foundation
package import TorrentEngineModel

/// A presentation of already validated torrent paths. No filesystem access or
/// path normalization is involved; file indices remain the command identities.
package struct TorrentFileTree: Sendable {
    package struct FileCounts: Equatable, Sendable {
        package let finished: Int
        package let downloading: Int
        package let waiting: Int
        package let skipped: Int

        package var total: Int { finished + downloading + waiting + skipped }
    }

    package struct Sort: SortComparator {
        package enum Key: Hashable, Sendable { case name, size, progress, priority }

        package let key: Key
        package var order: SortOrder

        package init(_ key: Key, order: SortOrder? = nil) {
            self.key = key
            self.order = order ?? (key == .name ? .forward : .reverse)
        }

        package func compare(_ lhs: Node, _ rhs: Node) -> ComparisonResult {
            let result: ComparisonResult
            switch key {
            case .name:
                // Keep folders first for name sorting in either direction.
                if (lhs.children != nil) != (rhs.children != nil) {
                    return lhs.children != nil ? .orderedAscending : .orderedDescending
                }
                result = lhs.name.localizedStandardCompare(rhs.name)
            case .size:
                result = compareValues(lhs.size, rhs.size)
            case .progress:
                result = compareValues(lhs.progress, rhs.progress)
            case .priority:
                switch (lhs.priority, rhs.priority) {
                case (.some(let lhs), .some(let rhs)):
                    result = compareValues(lhs.rawValue, rhs.rawValue)
                case (.none, .some): result = .orderedAscending
                case (.some, .none): result = .orderedDescending
                case (.none, .none): result = .orderedSame
                }
            }
            guard order == .reverse else { return result }
            switch result {
            case .orderedAscending: return .orderedDescending
            case .orderedDescending: return .orderedAscending
            case .orderedSame: return .orderedSame
            }
        }

        private func compareValues<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
            lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        }
    }

    package struct Node: Identifiable, Sendable {
        package enum ID: Hashable, Sendable {
            /// A folder is anchored to its lowest descendant file index. Depth
            /// is relative to the torrent root, so no display path grants access.
            case folder(containingFileIndex: Int32, depth: Int)
            case file(Int32)
        }

        package enum Content: Sendable {
            case folder([Node])
            case file(TorrentFileItem)
        }

        package let id: ID
        package let name: String
        package let path: String
        package let filenameExtension: String
        package let content: Content
        package let fileIndices: [Int32]
        package let size: Int64
        package let downloaded: Int64
        package let progress: Double
        /// Nil represents different priorities among descendant files.
        package let priority: TorrentFilePriority?

        package var children: [Node]? {
            if case .folder(let children) = content { children } else { nil }
        }

        package var file: TorrentFileItem? {
            if case .file(let file) = content { file } else { nil }
        }
    }

    package let roots: [Node]
    package let fileCounts: FileCounts
    package var fileCount: Int { fileCounts.total }
    package let filenameExtensions: Set<String>
    package static let empty = Self(
        roots: [], fileCounts: FileCounts(finished: 0, downloading: 0, waiting: 0, skipped: 0),
        filenameExtensions: []
    )

    private struct Entry {
        let file: TorrentFileItem
        let components: [String]
    }

    @concurrent
    package static func prepare(
        files: [TorrentFileItem], sortOrder: [Sort] = [Sort(.name)]
    ) async throws -> Self {
        try Task.checkCancellation()
        var entries = [Entry]()
        var filenameExtensions = Set<String>()
        var finished = 0
        var downloading = 0
        var waiting = 0
        var skipped = 0
        entries.reserveCapacity(files.count)
        for (offset, file) in files.enumerated() {
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
            guard !file.isPadFile else { continue }
            if file.isSkipped {
                skipped += 1
            } else if file.progress >= 1 {
                finished += 1
            } else if file.downloaded > 0 {
                downloading += 1
            } else {
                waiting += 1
            }
            filenameExtensions.insert((file.path as NSString).pathExtension.lowercased())
            entries.append(Entry(
                file: file,
                components: file.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            ))
        }
        let roots = try nodes(entries: entries, depth: 0, parent: "", sortOrder: sortOrder)
        try Task.checkCancellation()
        return Self(
            roots: roots,
            fileCounts: FileCounts(finished: finished, downloading: downloading, waiting: waiting, skipped: skipped),
            filenameExtensions: filenameExtensions
        )
    }

    private static func nodes(
        entries: [Entry], depth: Int, parent: String, sortOrder: [Sort]
    ) throws -> [Node] {
        try Task.checkCancellation()
        var folders = [String: [Entry]]()
        var result = [Node]()
        for (offset, entry) in entries.enumerated() {
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
            let name = entry.components[depth]
            if depth + 1 < entry.components.count {
                folders[name, default: []].append(entry)
            } else {
                let file = entry.file
                result.append(Node(
                    id: .file(file.index), name: name, path: file.path,
                    filenameExtension: (name as NSString).pathExtension.lowercased(),
                    content: .file(file), fileIndices: [file.index],
                    size: max(0, file.size), downloaded: min(max(0, file.downloaded), max(0, file.size)),
                    progress: file.progress, priority: file.priority
                ))
            }
        }
        for (name, entries) in folders {
            let path = parent.isEmpty ? name : "\(parent)/\(name)"
            let children = try nodes(entries: entries, depth: depth + 1, parent: path, sortOrder: sortOrder)
            let fileIndices = children.flatMap(\.fileIndices)
            guard let anchor = fileIndices.min() else { continue }
            let size = children.reduce(Int64(0)) { sum($0, $1.size) }
            let downloaded = children.reduce(Int64(0)) { sum($0, $1.downloaded) }
            let priority = children.first?.priority
            result.append(Node(
                id: .folder(containingFileIndex: anchor, depth: depth), name: name, path: path,
                filenameExtension: "",
                content: .folder(children), fileIndices: fileIndices,
                size: size, downloaded: downloaded,
                progress: size > 0 ? Double(downloaded) / Double(size)
                    : (children.allSatisfy { $0.progress >= 1 } ? 1 : 0),
                priority: children.allSatisfy { $0.priority == priority } ? priority : nil
            ))
        }
        var comparisons = 0
        try result.sort { lhs, rhs in
            if comparisons.isMultiple(of: 128) { try Task.checkCancellation() }
            comparisons += 1
            for comparator in sortOrder {
                let order = comparator.compare(lhs, rhs)
                if order != .orderedSame { return order == .orderedAscending }
            }
            // Equal values fall back to natural names and stable identities.
            let order = Sort(.name).compare(lhs, rhs)
            if order != .orderedSame { return order == .orderedAscending }
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            if case (.file(let lhs), .file(let rhs)) = (lhs.content, rhs.content) {
                return lhs.index < rhs.index
            }
            return false
        }
        return result
    }

    private static func sum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        lhs > Int64.max - rhs ? .max : lhs + rhs
    }
}

package struct TorrentFilePriorityChange: Sendable {
    package let fileIndices: [Int32]
    package let priority: TorrentFilePriority

    package init(fileIndices: [Int32], priority: TorrentFilePriority) {
        self.fileIndices = fileIndices
        self.priority = priority
    }

    @concurrent
    package func pendingPriorities(in files: [TorrentFileItem]) async throws -> [Int32: TorrentFilePriority] {
        try Task.checkCancellation()
        let indices = Set(fileIndices)
        var priorities = [Int32: TorrentFilePriority]()
        for (offset, file) in files.enumerated() {
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
            if !file.isPadFile, indices.contains(file.index), file.priority != priority {
                priorities[file.index] = priority
            }
        }
        try Task.checkCancellation()
        return priorities
    }

}
