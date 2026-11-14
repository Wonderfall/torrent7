import Darwin
import ExtensionFoundation
import Foundation
import Synchronization
import System
import TorrentEngineIPC
import TorrentEngineService
import TorrentQuarantineProbeSupport
import XPC

/// Test-only entry point. Production extensions never link this target.
enum QuarantineProbeConfiguration {
    @MainActor
    static func make() -> ConnectionHandler {
        ConnectionHandler(onSessionRequest: { request in
            request.accept { _ in QuarantineProbePeer() }
        })
    }
}

private final class QuarantineProbePeer: XPCPeerHandler {
    private struct State {
        var started = false
        var task: Task<Void, Never>?
    }
    private let state = Mutex(State())

    func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
        let request: QuarantineProbeRequest
        do {
            request = try message.decode(as: QuarantineProbeRequest.self)
            guard request.claims.count == 2, request.paths.count == 2 else {
                return QuarantineProbeReply.failure("Expected two fixture claims")
            }
        } catch {
            return QuarantineProbeReply.failure(error.localizedDescription)
        }
        let reply = QuarantineProbePendingReply(message: message)
        let accepted = state.withLock { state in
            guard !state.started else { return false }
            state.started = true
            state.task = Task {
                do {
                    let observations = try await Self.run(request)
                    reply.send(.success(observations))
                } catch {
                    reply.send(.failure(error.localizedDescription))
                }
            }
            return true
        }
        return accepted ? nil : QuarantineProbeReply.failure("Probe already started")
    }

    func handleCancellation(error: XPCRichError) {
        state.withLock { state in
            state.started = true
            state.task?.cancel()
        }
    }

    deinit { state.withLock { $0.task?.cancel() } }

    private static func run(_ request: QuarantineProbeRequest) async throws -> [QuarantineObservation] {
        let broker = try await TorrentStorageBrokerClient.connect(
            endpoint: request.endpoint, sessionNonce: request.nonce,
            engineEpoch: UUID(), appIdentifier: nil,
            authentication: .reducedAssuranceAdHocDevelopment
        )
        defer { broker.cancel() }
        var observations = [QuarantineObservation]()
        for (index, claim) in request.claims.enumerated() {
            try Task.checkCancellation()
            let descriptor = try await broker.openPayload(
                claimID: claim, generation: 1, fileIndex: 0, access: .readWrite
            )
            defer { _ = close(descriptor) }
            observations.append(try probe(descriptor, path: request.paths[index]))
        }
        return observations
    }

    // SAFETY: This function borrows one validated writable fixture descriptor.
    // Data and attribute-name storage stay pinned for synchronous positioned I/O
    // and xattr calls. The write fits the fixture's 64-byte bound. Each syscall's
    // result/errno is captured immediately; no pointer or borrowed buffer escapes.
    private static func probe(_ descriptor: Int32, path: String) throws -> QuarantineObservation {
        let read = QuarantineProbe.attribute.withCString { name in
            unsafe fgetxattr(descriptor, name, nil, 0, 0, 0)
        }
        let readError = read < 0 ? errno : 0
        let written = unsafe QuarantineProbe.payload.withUnsafeBytes { bytes in
            unsafe pwrite(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        guard written == QuarantineProbe.payload.count else {
            throw QuarantineProbeFailure.failed("Writing payload failed: \(Errno(rawValue: errno))")
        }
        let removed = QuarantineProbe.attribute.withCString { name in
            unsafe fremovexattr(descriptor, name, 0)
        }
        let removalError = removed == 0 ? 0 : errno

        // The sandbox may deny reading the attribute too. Use a syntactically
        // valid replacement with all flags cleared, without needing its contents.
        let weakened = Data("0000;00000001;fixture;".utf8)
        let overwritten = QuarantineProbe.attribute.withCString { name in
            unsafe weakened.withUnsafeBytes { bytes in
                unsafe fsetxattr(descriptor, name, bytes.baseAddress, bytes.count, 0, 0)
            }
        }
        let overwriteError = overwritten == 0 ? 0 : errno
        let path = probePath(descriptor, path: path)
        let metadata = probeMetadata(descriptor)
        return QuarantineObservation(
            readError: readError, removalError: removalError, overwriteError: overwriteError,
            pathOpenError: path.openError,
            descriptorTraversalError: path.traversalError, linkError: path.linkError,
            symlinkError: path.symlinkError, renameError: path.renameError,
            unlinkError: path.unlinkError, otherAttributeError: metadata.attributeError,
            flagsError: metadata.flagsError
        )
    }

    private struct PathObservation {
        let openError: Int32
        let traversalError: Int32
        let linkError: Int32
        let symlinkError: Int32
        let renameError: Int32
        let unlinkError: Int32
    }

    // SAFETY: Each pathname String pins its C bytes for one synchronous
    // syscall; returned descriptors are closed immediately. No pointer escapes.
    private static func probePath(_ descriptor: Int32, path: String) -> PathObservation {
        let opened = path.withCString { pointer in
            unsafe open(pointer, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        let openError = opened < 0 ? errno : 0
        if opened >= 0 { _ = close(opened) }

        let traversed = "..".withCString { pointer in
            unsafe openat(descriptor, pointer, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        }
        let traversalError = traversed < 0 ? errno : 0
        if traversed >= 0 { _ = close(traversed) }

        let linked = path.withCString { source in
            (path + ".probe-linked").withCString { destination in
                unsafe link(source, destination)
            }
        }
        let linkError = linked == 0 ? 0 : errno
        let symlinked = path.withCString { source in
            (path + ".probe-symlink").withCString { destination in
                unsafe symlink(source, destination)
            }
        }
        let symlinkError = symlinked == 0 ? 0 : errno
        let renamed = path.withCString { source in
            (path + ".probe-renamed").withCString { destination in
                unsafe rename(source, destination)
            }
        }
        let renameError = renamed == 0 ? 0 : errno
        let unlinked = path.withCString { pointer in unsafe unlink(pointer) }
        let unlinkError = unlinked == 0 ? 0 : errno
        return PathObservation(
            openError: openError,
            traversalError: traversalError, linkError: linkError,
            symlinkError: symlinkError, renameError: renameError, unlinkError: unlinkError
        )
    }

    private struct MetadataObservation {
        let attributeError: Int32
        let flagsError: Int32
    }

    // SAFETY: The attribute bytes and name are pinned for one synchronous
    // fsetxattr. fchflags borrows only the already owned descriptor.
    private static func probeMetadata(_ descriptor: Int32) -> MetadataObservation {
        let attribute = Data("fixture".utf8)
        let result = "app.torrent7.integration.probe".withCString { name in
            unsafe attribute.withUnsafeBytes { bytes in
                unsafe fsetxattr(descriptor, name, bytes.baseAddress, bytes.count, 0, 0)
            }
        }
        let attributeError = result == 0 ? 0 : errno
        let flagsResult = fchflags(descriptor, UInt32(UF_NODUMP))
        let flagsError = flagsResult == 0 ? 0 : errno
        return MetadataObservation(attributeError: attributeError, flagsError: flagsError)
    }
}

// SAFETY: XPCReceivedMessage has no Sendable conformance. This immutable wrapper
// retains it for the single owned probe task; only that task sends its one reply,
// and the incoming handler never uses the message after creating the wrapper.
private final class QuarantineProbePendingReply: @unchecked Sendable {
    private let message: XPCReceivedMessage
    init(message: XPCReceivedMessage) { self.message = message }
    func send(_ reply: QuarantineProbeReply) { message.reply(reply) }
}
