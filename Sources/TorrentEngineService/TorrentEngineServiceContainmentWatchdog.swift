import Darwin
import Dispatch
import Foundation
import Synchronization

/// A process-external safety boundary for cleanup that cannot rely on Swift
/// actor progress when a synchronous native call is stuck. Missing a deadline
/// terminates only the isolated helper; ExtensionFoundation can start a clean
/// instance for the next connection attempt.
@safe final class TorrentEngineServiceContainmentWatchdog: Sendable {
    private let timeout: DispatchTimeInterval
    private let terminationHandler: @Sendable () -> Void
    private let armedTokens = Mutex(Set<UUID>())

    init(
        timeout: DispatchTimeInterval = .seconds(30),
        terminationHandler: @escaping @Sendable () -> Void = {
            Darwin._exit(70)
        }
    ) {
        self.timeout = timeout
        self.terminationHandler = terminationHandler
    }

    func arm() -> UUID {
        let token = UUID()
        armedTokens.withLock { armedTokens in
            _ = armedTokens.insert(token)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + timeout
        ) { [weak self] in
            guard let self, consume(token) else {
                return
            }
            terminationHandler()
        }
        return token
    }

    func disarm(_ token: UUID) {
        armedTokens.withLock { armedTokens in
            _ = armedTokens.remove(token)
        }
    }

    var armedTokenCount: Int {
        armedTokens.withLock { $0.count }
    }

    private func consume(_ token: UUID) -> Bool {
        armedTokens.withLock { armedTokens in
            armedTokens.remove(token) != nil
        }
    }
}
