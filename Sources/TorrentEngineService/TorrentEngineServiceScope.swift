import Foundation
import Synchronization

private final class TorrentEngineServiceScopeValidity: Sendable {
    private let active = Mutex(true)

    var isActive: Bool {
        active.withLock { $0 }
    }

    func invalidate() {
        active.withLock { $0 = false }
    }
}

/// Identifies one authenticated controller lifetime. Equality deliberately
/// includes a fresh generation so a replacement controller cannot reuse stale
/// work even when its public identifiers happen to match.
package struct TorrentEngineServiceScope: Hashable, Sendable {
    package let engineEpoch: UUID
    package let controllerID: UUID
    package let generation: UUID
    private let validity = TorrentEngineServiceScopeValidity()

    package init(engineEpoch: UUID, controllerID: UUID) {
        self.engineEpoch = engineEpoch
        self.controllerID = controllerID
        generation = UUID()
    }

    package var isActive: Bool {
        validity.isActive
    }

    package func invalidate() {
        validity.invalidate()
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.engineEpoch == rhs.engineEpoch
            && lhs.controllerID == rhs.controllerID
            && lhs.generation == rhs.generation
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(engineEpoch)
        hasher.combine(controllerID)
        hasher.combine(generation)
    }
}
