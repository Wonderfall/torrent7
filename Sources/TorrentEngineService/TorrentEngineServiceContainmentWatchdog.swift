import Darwin
import Dispatch
import Foundation

/// A process-external safety boundary for cleanup that cannot rely on Swift
/// actor progress when a synchronous native call is stuck. Missing a deadline
/// terminates only the isolated helper; launchd can start a clean instance.
@safe final class TorrentEngineServiceContainmentWatchdog: @unchecked Sendable {
    private let timeout: DispatchTimeInterval
    private let terminationHandler: @Sendable () -> Void
    private let lock = NSLock()
    private var armedTokens = Set<UUID>()

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
        lock.withLock {
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
        lock.withLock {
            _ = armedTokens.remove(token)
        }
    }

    var armedTokenCount: Int {
        lock.withLock { armedTokens.count }
    }

    private func consume(_ token: UUID) -> Bool {
        lock.withLock {
            armedTokens.remove(token) != nil
        }
    }
}
