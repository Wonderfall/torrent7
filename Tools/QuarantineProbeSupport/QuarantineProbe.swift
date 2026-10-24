import Darwin
package import Foundation
import System
package import XPC

/// Shared only by the packaged integration host and its probe extension.
package struct QuarantineProbeRequest: Codable, Sendable {
    package let endpoint: XPCEndpoint
    package let nonce: UUID
    package let claims: [UUID]

    package init(endpoint: XPCEndpoint, nonce: UUID, claims: [UUID]) {
        self.endpoint = endpoint
        self.nonce = nonce
        self.claims = claims
    }
}

package enum QuarantineProbeReply: Codable, Sendable {
    case success([QuarantineObservation])
    case failure(String)
}

package struct QuarantineObservation: Codable, Sendable {
    package let readError: Int32
    package let removalError: Int32
    package let overwriteError: Int32

    package init(readError: Int32, removalError: Int32, overwriteError: Int32) {
        self.readError = readError
        self.removalError = removalError
        self.overwriteError = overwriteError
    }
}

package enum QuarantineProbeFailure: LocalizedError {
    case failed(String)

    package var errorDescription: String? {
        switch self { case .failed(let message): message }
    }
}

package enum QuarantineProbe {
    package static let payload = Data("torrent7 quarantine payload probe".utf8)
    package static let attribute = "com.apple.quarantine"

    // SAFETY: The descriptor is borrowed from the caller. The attribute name and
    // fixed-size byte array stay pinned during fgetxattr; its returned count is
    // checked before copying. No raw memory or descriptor escapes this function.
    package static func read(_ descriptor: Int32) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 1_024)
        let count = attribute.withCString { name in
            bytes.withUnsafeMutableBytes { buffer in
                unsafe fgetxattr(descriptor, name, buffer.baseAddress, buffer.count, 0, 0)
            }
        }
        if count < 0 {
            guard errno == ENOATTR else {
                throw QuarantineProbeFailure.failed("Reading quarantine failed: \(Errno(rawValue: errno))")
            }
            return nil
        }
        guard count <= bytes.count else {
            throw QuarantineProbeFailure.failed("Oversized quarantine attribute")
        }
        return Data(bytes.prefix(count))
    }
}
