import Foundation
import TorrentEngineModel

private struct TorrentLabelStorage: Codable {
    var labels: [TorrentLabel]
    var assignments: [TorrentItem.ID: [TorrentLabel.ID]]
}

struct TorrentLabelSnapshot: Sendable {
    let labels: [TorrentLabel]
    let assignments: [TorrentItem.ID: Set<TorrentLabel.ID>]
}

enum TorrentLabelMutationRequest: Sendable {
    case set(
        labelIDs: Set<TorrentLabel.ID>,
        torrentID: TorrentItem.ID,
        requiresActiveTorrent: Bool
    )
    case toggle(
        labelID: TorrentLabel.ID,
        torrentIDs: Set<TorrentItem.ID>
    )
    case delete(labelID: TorrentLabel.ID)
    case removeAssignments(torrentIDs: Set<TorrentItem.ID>)
}

struct TorrentLabelMutationPlan: Sendable {
    let revision: UInt64
    let snapshot: TorrentLabelSnapshot?

    @concurrent
    static func prepare(
        request: TorrentLabelMutationRequest,
        labels: [TorrentLabel],
        assignments: [TorrentItem.ID: Set<TorrentLabel.ID>],
        activeTorrentIDs: Set<TorrentItem.ID>,
        revision: UInt64
    ) async throws -> Self {
        try Task.checkCancellation()
        let snapshot: TorrentLabelSnapshot? = switch request {
        case .set(
            let requestedLabelIDs,
            let torrentID,
            let requiresActiveTorrent
        ):
            try setLabels(
                requestedLabelIDs,
                for: torrentID,
                requiresActiveTorrent: requiresActiveTorrent,
                labels: labels,
                assignments: assignments,
                activeTorrentIDs: activeTorrentIDs
            )
        case .toggle(let labelID, let torrentIDs):
            try toggleLabel(
                labelID,
                for: torrentIDs,
                labels: labels,
                assignments: assignments,
                activeTorrentIDs: activeTorrentIDs
            )
        case .delete(let labelID):
            try deleteLabel(
                labelID,
                labels: labels,
                assignments: assignments
            )
        case .removeAssignments(let torrentIDs):
            try removeAssignments(
                for: torrentIDs,
                labels: labels,
                assignments: assignments
            )
        }
        try Task.checkCancellation()
        return Self(revision: revision, snapshot: snapshot)
    }

    private static func setLabels(
        _ requestedLabelIDs: Set<TorrentLabel.ID>,
        for torrentID: TorrentItem.ID,
        requiresActiveTorrent: Bool,
        labels: [TorrentLabel],
        assignments: [TorrentItem.ID: Set<TorrentLabel.ID>],
        activeTorrentIDs: Set<TorrentItem.ID>
    ) throws -> TorrentLabelSnapshot? {
        guard !requiresActiveTorrent
                || activeTorrentIDs.contains(torrentID) else {
            return nil
        }

        let validLabelIDs = try labelIDs(in: labels)
        let sanitizedLabelIDs = try intersection(
            requestedLabelIDs,
            validLabelIDs
        )
        guard (assignments[torrentID] ?? []) != sanitizedLabelIDs else {
            return nil
        }

        var updatedAssignments = assignments
        updatedAssignments[torrentID] = sanitizedLabelIDs.isEmpty
            ? nil
            : sanitizedLabelIDs
        return TorrentLabelSnapshot(
            labels: labels,
            assignments: updatedAssignments
        )
    }

    private static func toggleLabel(
        _ labelID: TorrentLabel.ID,
        for torrentIDs: Set<TorrentItem.ID>,
        labels: [TorrentLabel],
        assignments: [TorrentItem.ID: Set<TorrentLabel.ID>],
        activeTorrentIDs: Set<TorrentItem.ID>
    ) throws -> TorrentLabelSnapshot? {
        let validLabelIDs = try labelIDs(in: labels)
        guard validLabelIDs.contains(labelID) else {
            return nil
        }

        let validTorrentIDs = try intersection(
            torrentIDs,
            activeTorrentIDs
        )
        guard !validTorrentIDs.isEmpty else {
            return nil
        }

        var shouldRemove = true
        for (offset, torrentID) in validTorrentIDs.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if assignments[torrentID]?.contains(labelID) != true {
                shouldRemove = false
                break
            }
        }

        var updatedAssignments = assignments
        for (offset, torrentID) in validTorrentIDs.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            var assignedLabelIDs = updatedAssignments[torrentID] ?? []
            if shouldRemove {
                assignedLabelIDs.remove(labelID)
            } else {
                assignedLabelIDs.insert(labelID)
            }
            updatedAssignments[torrentID] = assignedLabelIDs.isEmpty
                ? nil
                : assignedLabelIDs
        }
        return TorrentLabelSnapshot(
            labels: labels,
            assignments: updatedAssignments
        )
    }

    private static func deleteLabel(
        _ labelID: TorrentLabel.ID,
        labels: [TorrentLabel],
        assignments: [TorrentItem.ID: Set<TorrentLabel.ID>]
    ) throws -> TorrentLabelSnapshot? {
        var updatedLabels = [TorrentLabel]()
        updatedLabels.reserveCapacity(labels.count)
        var foundLabel = false
        for (offset, label) in labels.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if label.id == labelID {
                foundLabel = true
            } else {
                updatedLabels.append(label)
            }
        }
        guard foundLabel else {
            return nil
        }

        var updatedAssignments = assignments
        for (offset, assignment) in assignments.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            guard assignment.value.contains(labelID) else {
                continue
            }
            var assignedLabelIDs = assignment.value
            assignedLabelIDs.remove(labelID)
            updatedAssignments[assignment.key] = assignedLabelIDs.isEmpty
                ? nil
                : assignedLabelIDs
        }
        return TorrentLabelSnapshot(
            labels: updatedLabels,
            assignments: updatedAssignments
        )
    }

    private static func removeAssignments(
        for torrentIDs: Set<TorrentItem.ID>,
        labels: [TorrentLabel],
        assignments: [TorrentItem.ID: Set<TorrentLabel.ID>]
    ) throws -> TorrentLabelSnapshot? {
        var updatedAssignments = assignments
        var changed = false
        for (offset, torrentID) in torrentIDs.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if updatedAssignments.removeValue(forKey: torrentID) != nil {
                changed = true
            }
        }
        guard changed else {
            return nil
        }
        return TorrentLabelSnapshot(
            labels: labels,
            assignments: updatedAssignments
        )
    }

    private static func labelIDs(
        in labels: [TorrentLabel]
    ) throws -> Set<TorrentLabel.ID> {
        var ids = Set<TorrentLabel.ID>()
        ids.reserveCapacity(labels.count)
        for (offset, label) in labels.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            ids.insert(label.id)
        }
        return ids
    }

    private static func intersection<Element: Hashable & Sendable>(
        _ lhs: Set<Element>,
        _ rhs: Set<Element>
    ) throws -> Set<Element> {
        let candidates = lhs.count <= rhs.count ? lhs : rhs
        let membership = lhs.count <= rhs.count ? rhs : lhs
        var result = Set<Element>()
        result.reserveCapacity(candidates.count)
        for (offset, element) in candidates.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if membership.contains(element) {
                result.insert(element)
            }
        }
        return result
    }
}

struct TorrentLabelPrunePlan: Sendable {
    let revision: UInt64
    let assignments: [TorrentItem.ID: Set<TorrentLabel.ID>]?

    @concurrent
    static func prepare(
        assignments: [TorrentItem.ID: Set<TorrentLabel.ID>],
        activeTorrentIDs: Set<TorrentItem.ID>,
        revision: UInt64
    ) async throws -> Self {
        try Task.checkCancellation()
        var retainedAssignments = [TorrentItem.ID: Set<TorrentLabel.ID>]()
        retainedAssignments.reserveCapacity(min(assignments.count, activeTorrentIDs.count))
        for (offset, assignment) in assignments.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if activeTorrentIDs.contains(assignment.key) {
                retainedAssignments[assignment.key] = assignment.value
            }
        }
        try Task.checkCancellation()
        return Self(
            revision: revision,
            assignments: retainedAssignments.count == assignments.count
                ? nil
                : retainedAssignments
        )
    }
}

struct TorrentLabelStore {
    static let defaultsKey = "TorrentLabels.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> TorrentLabelSnapshot {
        Self.decode(defaults.data(forKey: Self.defaultsKey))
    }

    fileprivate static func decode(_ data: Data?) -> TorrentLabelSnapshot {
        decode(data, checkCancellation: {})
    }

    fileprivate static func decode(
        _ data: Data?,
        checkCancellation: () throws -> Void
    ) rethrows -> TorrentLabelSnapshot {
        guard let data,
              let storage = try? JSONDecoder().decode(
                  TorrentLabelStorage.self,
                  from: data
              ) else {
            return TorrentLabelSnapshot(labels: [], assignments: [:])
        }
        try checkCancellation()
        let labels = try sanitizedLabels(
            storage.labels,
            checkCancellation: checkCancellation
        )
        var labelIDs = Set<TorrentLabel.ID>()
        labelIDs.reserveCapacity(labels.count)
        for label in labels {
            labelIDs.insert(label.id)
        }
        var assignments = [TorrentItem.ID: Set<TorrentLabel.ID>]()
        assignments.reserveCapacity(storage.assignments.count)
        for (assignmentOffset, item) in storage.assignments.enumerated() {
            if assignmentOffset.isMultiple(of: 128) {
                try checkCancellation()
            }
            var validIDs = Set<TorrentLabel.ID>()
            validIDs.reserveCapacity(min(item.value.count, labelIDs.count))
            for (labelOffset, labelID) in item.value.enumerated() {
                if labelOffset.isMultiple(of: 128) {
                    try checkCancellation()
                }
                if labelIDs.contains(labelID) {
                    validIDs.insert(labelID)
                }
            }
            if !validIDs.isEmpty {
                assignments[item.key] = validIDs
            }
        }
        try checkCancellation()

        return TorrentLabelSnapshot(
            labels: labels,
            assignments: assignments
        )
    }

    fileprivate static func sanitizedLabels(
        _ labels: [TorrentLabel],
        checkCancellation: () throws -> Void
    ) rethrows -> [TorrentLabel] {
        var sanitized = [TorrentLabel]()
        sanitized.reserveCapacity(
            min(labels.count, TorrentLabel.maximumCount)
        )
        var seenIDs = Set<TorrentLabel.ID>()
        seenIDs.reserveCapacity(
            min(labels.count, TorrentLabel.maximumCount)
        )
        for (offset, label) in labels.enumerated() {
            if offset.isMultiple(of: 128) {
                try checkCancellation()
            }
            guard sanitized.count < TorrentLabel.maximumCount else {
                break
            }
            guard !label.id.isEmpty,
                  label.id.utf8.count <= TorrentLabel.maxIDByteCount else {
                continue
            }
            let name = TorrentLabel.normalizedName(label.name)
            guard !name.isEmpty,
                  seenIDs.insert(label.id).inserted else {
                continue
            }
            sanitized.append(TorrentLabel(id: label.id, name: name))
        }
        try checkCancellation()
        return sanitized
    }
}

protocol TorrentLabelPersisting: Actor {
    func load() async throws -> TorrentLabelSnapshot
    func save(
        labels: [TorrentLabel],
        assignments: [TorrentItem.ID: Set<TorrentLabel.ID>],
        revision: UInt64
    ) async throws
}

actor TorrentLabelPersistenceStore: TorrentLabelPersisting {
    private let domain: TorrentDefaultsDomain
    private var defaults: UserDefaults?
    private var newestRevision: UInt64 = 0

    init(domain: TorrentDefaultsDomain = .standard) {
        self.domain = domain
    }

    func load() async throws -> TorrentLabelSnapshot {
        try Task.checkCancellation()
        let data = userDefaults.data(forKey: TorrentLabelStore.defaultsKey)
        let snapshot = try TorrentLabelStore.decode(
            data,
            checkCancellation: {
                try Task.checkCancellation()
            }
        )
        try Task.checkCancellation()
        return snapshot
    }

    func save(
        labels: [TorrentLabel],
        assignments: [TorrentItem.ID: Set<TorrentLabel.ID>],
        revision: UInt64
    ) async throws {
        try Task.checkCancellation()
        guard revision >= newestRevision else {
            return
        }
        newestRevision = revision
        let labels = try TorrentLabelStore.sanitizedLabels(
            labels,
            checkCancellation: {
                try Task.checkCancellation()
            }
        )
        let labelIDs = Set(labels.map(\.id))
        var sanitizedAssignments = [TorrentItem.ID: [TorrentLabel.ID]]()
        sanitizedAssignments.reserveCapacity(assignments.count)
        for (offset, item) in assignments.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            var validIDs = [TorrentLabel.ID]()
            validIDs.reserveCapacity(min(item.value.count, labelIDs.count))
            for (labelOffset, labelID) in item.value.enumerated() {
                if labelOffset.isMultiple(of: 128) {
                    try Task.checkCancellation()
                }
                if labelIDs.contains(labelID) {
                    validIDs.append(labelID)
                }
            }
            if !validIDs.isEmpty {
                sanitizedAssignments[item.key] = validIDs.sorted()
            }
        }

        let storage = TorrentLabelStorage(
            labels: labels,
            assignments: sanitizedAssignments
        )
        let data = try JSONEncoder().encode(storage)
        try Task.checkCancellation()
        userDefaults.set(data, forKey: TorrentLabelStore.defaultsKey)
    }

    private var userDefaults: UserDefaults {
        if let defaults {
            return defaults
        }
        let createdDefaults = domain.makeUserDefaults()
        defaults = createdDefaults
        return createdDefaults
    }
}
