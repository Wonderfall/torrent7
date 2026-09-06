import Foundation
import Synchronization
import TorrentEngineClient
import XPC

final class TorrentEngineClientTestStorageBroker: TorrentEngineStorageBrokerSession {
    let sessionNonce = UUID()
    private let cancelled = Mutex(false)
    private let listener = XPCListener { request in
        request.reject(reason: "The unit-test endpoint is transport-only")
    }

    var endpoint: XPCEndpoint { listener.endpoint }
    var isCancelled: Bool { cancelled.withLock { $0 } }

    func cancel() {
        cancelled.withLock { $0 = true }
        listener.cancel()
    }
}
