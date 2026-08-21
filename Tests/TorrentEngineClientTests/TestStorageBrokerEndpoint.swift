import Foundation
import XPC

enum TorrentEngineClientTestStorageBroker {
    static let sessionNonce = UUID()
    static let listener = XPCListener(options: .inactive) { request in
        request.reject(reason: "The unit-test endpoint is transport-only")
    }
    static let endpoint = listener.endpoint
}
