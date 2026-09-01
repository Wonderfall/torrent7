import Darwin
import Foundation
import Testing
import XPC
@testable import TorrentEngineIPC
@testable import TorrentEngineService

@Suite("Torrent storage broker client security", .serialized)
struct TorrentStorageBrokerClientSecurityTests {
    @Test("Every broker reply completion cancels its timeout task")
    func replyCompletionCancelsTimeoutTask() async throws {
        let requestID = UUID()
        let reply = TorrentStorageBrokerReply.success(
            requestID: requestID,
            metadata: nil,
            statistics: [],
            fileDescriptor: nil
        )

        let pending = TorrentStorageBrokerPendingReply()
        let installedTimeout = Task.detached { () -> Void in
            _ = try? await ContinuousClock().sleep(for: .seconds(30))
        }
        defer { installedTimeout.cancel() }
        pending.installTimeoutTask(installedTimeout)

        #expect(pending.finish(.success(reply)))
        #expect(installedTimeout.isCancelled)
        guard case .success(let observedID, nil, let statistics, nil) =
            try await pending.wait() else {
            Issue.record("Expected the completed broker reply")
            return
        }
        #expect(observedID == requestID)
        #expect(statistics.isEmpty)
        #expect(!pending.finish(.success(reply)))

        let earlyPending = TorrentStorageBrokerPendingReply()
        #expect(earlyPending.finish(.success(reply)))
        let lateInstalledTimeout = Task.detached { () -> Void in
            _ = try? await ContinuousClock().sleep(for: .seconds(30))
        }
        defer { lateInstalledTimeout.cancel() }
        earlyPending.installTimeoutTask(lateInstalledTimeout)

        #expect(lateInstalledTimeout.isCancelled)
        await installedTimeout.value
        await lateInstalledTimeout.value
    }

    @Test("The client accepts an exact regular payload descriptor")
    func exactRegularDescriptorIsAccepted() async throws {
        // SAFETY: Ownership/lifetime: the returned descriptor remains open and mutable Data is
        // pinned for the synchronous pread; bounds/alignment: exact Data capacity and offset zero
        // are supplied with byte alignment; synchronization: the test exclusively owns both;
        // safe alternative: reading the broker-returned descriptor without a path requires pread.
        let broker = try TestStorageBroker(scenario: .valid)
        let client = try await connect(to: broker)
        defer { client.cancel() }

        let descriptor = try await client.openPayload(
            claimID: UUID(),
            generation: 1,
            fileIndex: 0,
            access: .readOnly
        )
        defer { _ = Darwin.close(descriptor) }

        var contents = Data(count: TestStorageBroker.payload.count)
        let bytesRead = unsafe contents.withUnsafeMutableBytes { bytes in
            unsafe Darwin.pread(
                descriptor,
                bytes.baseAddress,
                bytes.count,
                0
            )
        }
        #expect(bytesRead == contents.count)
        #expect(contents == TestStorageBroker.payload)
    }

    @Test(
        "The client rejects substituted broker descriptors",
        arguments: BrokerDescriptorScenario.invalidCases
    )
    fileprivate func substitutedDescriptorsAreRejected(
        _ scenario: BrokerDescriptorScenario
    ) async throws {
        let broker = try TestStorageBroker(scenario: scenario)
        let client = try await connect(to: broker)
        defer { client.cancel() }

        do {
            let descriptor = try await client.openPayload(
                claimID: UUID(),
                generation: 1,
                fileIndex: 0,
                access: scenario.requestedAccess
            )
            _ = Darwin.close(descriptor)
            Issue.record("The substituted descriptor was accepted")
        } catch let error as TorrentStorageBrokerClientError {
            guard case .invalidReply = error else {
                Issue.record("Expected invalidReply, received \(error)")
                return
            }
        } catch {
            Issue.record("Expected a broker client error, received \(error)")
        }
    }

    private func connect(
        to broker: TestStorageBroker
    ) async throws -> TorrentStorageBrokerClient {
        try await TorrentStorageBrokerClient.connect(
            endpoint: broker.endpoint,
            sessionNonce: broker.sessionNonce,
            engineEpoch: UUID(),
            appIdentifier: nil,
            authentication: .reducedAssuranceAdHocDevelopment
        )
    }
}

private enum BrokerDescriptorScenario: Equatable, Sendable {
    case valid
    case directory
    case mismatchedSize
    case mismatchedDevice
    case mismatchedInode
    case mismatchedLinkCount
    case mismatchedMode
    case overprivilegedAccess
    case underprivilegedAccess

    static let invalidCases: [Self] = [
        .directory,
        .mismatchedSize,
        .mismatchedDevice,
        .mismatchedInode,
        .mismatchedLinkCount,
        .mismatchedMode,
        .overprivilegedAccess,
        .underprivilegedAccess,
    ]

    var requestedAccess: TorrentStorageBrokerAccess {
        switch self {
        case .valid, .directory, .mismatchedSize, .mismatchedDevice,
             .mismatchedInode, .mismatchedLinkCount, .mismatchedMode,
             .overprivilegedAccess:
            .readOnly
        case .underprivilegedAccess:
            .readWrite
        }
    }
}

@safe private final class TestStorageBroker: Sendable {
    static let payload = Data("brokered payload".utf8)

    let endpoint: XPCEndpoint
    let sessionNonce: UUID

    private let root: URL
    private let listener: XPCListener

    init(scenario: BrokerDescriptorScenario) throws {
        let root = URL.temporaryDirectory.appending(
            path: "TorrentStorageBrokerClientTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let payloadPath = root.appending(path: "payload.bin").path()
        do {
            try Self.payload.write(to: URL(filePath: payloadPath))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }

        let nonce = UUID()
        let listener = XPCListener { request in
            request.accept(
                incomingMessageHandler: { (dictionary: XPCDictionary) in
                    guard let brokerRequest = try? TorrentStorageBrokerIPCCodec
                        .decodeRequest(dictionary),
                          brokerRequest.common.sessionNonce == nonce else {
                        return nil
                    }
                    return Self.response(
                        to: brokerRequest,
                        scenario: scenario,
                        rootPath: root.path(),
                        payloadPath: payloadPath
                    )
                }
            )
        }

        self.root = root
        self.sessionNonce = nonce
        self.listener = listener
        endpoint = listener.endpoint
    }

    deinit {
        listener.cancel()
        try? FileManager.default.removeItem(at: root)
    }

    private static func response(
        to request: TorrentStorageBrokerRequest,
        scenario: BrokerDescriptorScenario,
        rootPath: String,
        payloadPath: String
    ) -> XPCDictionary? {
        // SAFETY: Ownership/lifetime: path C strings and local stat storage live through synchronous
        // calls and each descriptor is deferred-closed after XPC duplicates it; bounds/alignment:
        // withCString NUL-terminates paths and stat storage is exact/aligned; synchronization:
        // each response owns local state; safe alternative: adversarial descriptor construction
        // and authentication require direct Darwin open/fstat calls.
        switch request {
        case .handshake:
            return try? TorrentStorageBrokerIPCCodec.encode(
                .success(
                    requestID: request.common.requestID,
                    metadata: nil,
                    statistics: [],
                    fileDescriptor: nil
                ),
                for: request
            )
        case .openPayload(_, _, _, let fileIndex, _):
            let path = scenario == .directory ? rootPath : payloadPath
            let flags: Int32 = switch scenario {
            case .directory:
                O_RDONLY | O_DIRECTORY | O_CLOEXEC
            case .overprivilegedAccess:
                O_RDWR | O_NOFOLLOW | O_CLOEXEC
            default:
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            }
            let descriptor = unsafe path.withCString { pointer in
                unsafe Darwin.open(pointer, flags)
            }
            guard descriptor >= 0 else {
                return nil
            }
            defer { _ = Darwin.close(descriptor) }

            var status = stat()
            guard unsafe Darwin.fstat(descriptor, &status) == 0 else {
                return nil
            }
            let actualSize = Int64(status.st_size)
            let actualDevice = UInt64(truncatingIfNeeded: status.st_dev)
            let actualInode = UInt64(truncatingIfNeeded: status.st_ino)
            let actualLinkCount = UInt64(truncatingIfNeeded: status.st_nlink)
            let actualMode = UInt32(status.st_mode)
            let metadata = TorrentStorageBrokerFileMetadata(
                fileIndex: fileIndex,
                size: scenario == .mismatchedSize
                    ? actualSize &+ 1
                    : actualSize,
                device: scenario == .mismatchedDevice
                    ? actualDevice &+ 1
                    : actualDevice,
                inode: scenario == .mismatchedInode
                    ? actualInode &+ 1
                    : actualInode,
                linkCount: scenario == .mismatchedLinkCount
                    ? actualLinkCount &+ 1
                    : actualLinkCount,
                mode: scenario == .mismatchedMode
                    ? actualMode ^ UInt32(S_IXUSR)
                    : actualMode
            )
            return try? TorrentStorageBrokerIPCCodec.encode(
                .success(
                    requestID: request.common.requestID,
                    metadata: metadata,
                    statistics: [],
                    fileDescriptor: descriptor
                ),
                for: request
            )
        case .statBatch:
            return try? TorrentStorageBrokerIPCCodec.encode(
                .failure(
                    requestID: request.common.requestID,
                    code: .accessDenied,
                    message: "Unexpected test request."
                ),
                for: request
            )
        }
    }
}
