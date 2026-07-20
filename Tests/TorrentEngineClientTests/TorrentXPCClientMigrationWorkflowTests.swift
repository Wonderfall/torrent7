import Foundation
import Synchronization
import Testing
import TorrentEngineIPC
@testable import TorrentEngineClient

@Suite("Legacy state migration workflow")
struct TorrentXPCClientMigrationWorkflowTests {
    private let epoch = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test("A completed service migration never touches the legacy source")
    func completedMigrationSkipsInvalidSource() async throws {
        let temporary = try MigrationWorkflowTemporaryDirectory()
        let invalidSource = try temporary.makeSymlinkedStateDirectory(named: "Completed")
        let epoch = epoch
        let transport = MigrationWorkflowTransport { request in
            switch request.header.operation {
            case .beginStateMigration:
                return try migrationSuccessReply(
                    TorrentEngineIPCStateMigrationBeginResponse(alreadyComplete: true),
                    for: request,
                    epoch: epoch
                )
            case .handshake:
                return try migrationSuccessReply(
                    TorrentEngineIPCHandshakeResponse(
                        libtorrentVersion: "2.1.0",
                        folders: []
                    ),
                    for: request,
                    epoch: epoch
                )
            default:
                throw MigrationWorkflowTestError.unexpectedOperation(
                    request.header.operation
                )
            }
        }

        let client = try await makeMigrationClient(
            source: invalidSource,
            transport: transport
        )

        #expect(client.isAvailable)
        #expect(transport.operations == [.beginStateMigration, .handshake])
        #expect(transport.sequences == [1, 2])
    }

    @Test("Transient migration admission remains retryable by connection recovery")
    func transientBeginFailureIsPreserved() async throws {
        let temporary = try MigrationWorkflowTemporaryDirectory()
        let source = try temporary.makeStateDirectory(
            named: "TransientAdmission",
            withResumeData: true
        )
        let transport = MigrationWorkflowTransport { request in
            guard request.header.operation == .beginStateMigration else {
                throw MigrationWorkflowTestError.unexpectedOperation(
                    request.header.operation
                )
            }
            throw TorrentEngineClientError.serviceTemporarilyUnavailable(
                "Previous controller cleanup is still running."
            )
        }

        do {
            _ = try await makeMigrationClient(source: source, transport: transport)
            Issue.record("Expected transient migration admission to fail")
        } catch let error as TorrentEngineClientError {
            guard case .serviceTemporarilyUnavailable(let message) = error else {
                Issue.record("Expected retryable admission, got \(error)")
                return
            }
            #expect(message.contains("cleanup"))
        }

        #expect(transport.operations == [.beginStateMigration])
        #expect(transport.isCancelled)
    }

    @Test("Missing and empty legacy sources abort an incomplete migration before handshake")
    func missingAndEmptySourcesAbortBeforeHandshake() async throws {
        let temporary = try MigrationWorkflowTemporaryDirectory()
        let missingSource = temporary.url.appending(
            path: "Missing",
            directoryHint: .isDirectory
        )
        let emptySource = try temporary.makeStateDirectory(
            named: "Empty",
            withResumeData: true
        )

        for source in [missingSource, emptySource] {
            let transport = incompleteMigrationTransport()

            let client = try await makeMigrationClient(
                source: source,
                transport: transport
            )

            #expect(client.isAvailable)
            #expect(transport.operations == [
                .beginStateMigration,
                .abortStateMigration,
                .handshake
            ])
            #expect(transport.sequences == [1, 2, 3])
        }
    }

    @Test("An invalid legacy source is aborted and fails closed")
    func invalidSourceAbortsAndFails() async throws {
        let temporary = try MigrationWorkflowTemporaryDirectory()
        let invalidSource = try temporary.makeSymlinkedStateDirectory(named: "Invalid")
        let epoch = epoch
        let transport = MigrationWorkflowTransport { request in
            switch request.header.operation {
            case .beginStateMigration:
                return try migrationSuccessReply(
                    TorrentEngineIPCStateMigrationBeginResponse(alreadyComplete: false),
                    for: request,
                    epoch: epoch
                )
            case .abortStateMigration:
                return try migrationSuccessReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            default:
                throw MigrationWorkflowTestError.unexpectedOperation(
                    request.header.operation
                )
            }
        }

        await expectMigrationFailure {
            _ = try await makeMigrationClient(
                source: invalidSource,
                transport: transport
            )
        }

        #expect(transport.operations == [
            .beginStateMigration,
            .abortStateMigration
        ])
        #expect(transport.isCancelled)
    }

    @Test(
        "Import and commit failures abort the active migration",
        arguments: MigrationRemoteFailure.allCases
    )
    func remoteFailureAborts(_ failure: MigrationRemoteFailure) async throws {
        let temporary = try MigrationWorkflowTemporaryDirectory()
        let source = try temporary.makeStateDirectory(
            named: failure.rawValue,
            withResumeData: true
        )
        try temporary.writeResumeFile(
            named: "t:\(String(repeating: "a", count: 32)).fastresume",
            in: source,
            contents: "resume"
        )
        let epoch = epoch
        let transport = MigrationWorkflowTransport { request in
            switch request.header.operation {
            case .beginStateMigration:
                return try migrationSuccessReply(
                    TorrentEngineIPCStateMigrationBeginResponse(alreadyComplete: false),
                    for: request,
                    epoch: epoch
                )
            case .importStateMigrationFile:
                guard failure != .importFile else {
                    throw TorrentEngineClientError.serviceRejected(
                        "Import rejected for testing"
                    )
                }
                return try migrationSuccessReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            case .commitStateMigration:
                guard failure != .commit else {
                    throw TorrentEngineClientError.serviceRejected(
                        "Commit rejected for testing"
                    )
                }
                return try migrationSuccessReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            case .abortStateMigration:
                return try migrationSuccessReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            default:
                throw MigrationWorkflowTestError.unexpectedOperation(
                    request.header.operation
                )
            }
        }

        await expectMigrationFailure {
            _ = try await makeMigrationClient(source: source, transport: transport)
        }

        let expectedOperations: [TorrentEngineIPCOperation] = switch failure {
        case .importFile:
            [.beginStateMigration, .importStateMigrationFile, .abortStateMigration]
        case .commit:
            [
                .beginStateMigration,
                .importStateMigrationFile,
                .commitStateMigration,
                .abortStateMigration
            ]
        }
        #expect(transport.operations == expectedOperations)
        #expect(transport.isCancelled)
    }

    @Test("Valid legacy files are imported deterministically before commit and handshake")
    func successfulMigrationOrdering() async throws {
        let temporary = try MigrationWorkflowTemporaryDirectory()
        let source = try temporary.makeStateDirectory(
            named: "Successful",
            withResumeData: true
        )
        let first = "t:\(String(repeating: "b", count: 32)).fastresume"
        let second = "v1:\(String(repeating: "c", count: 40)).fastresume"
        try temporary.writeResumeFile(named: second, in: source, contents: "second")
        try temporary.writeResumeFile(named: first, in: source, contents: "first")
        let transport = incompleteMigrationTransport()

        let client = try await makeMigrationClient(source: source, transport: transport)

        #expect(client.isAvailable)
        #expect(transport.operations == [
            .beginStateMigration,
            .importStateMigrationFile,
            .importStateMigrationFile,
            .commitStateMigration,
            .handshake
        ])
        #expect(transport.sequences == [1, 2, 3, 4, 5])
        let importedNames: [String] = try transport.requests.compactMap { request in
            guard request.header.operation == .importStateMigrationFile else {
                return nil
            }
            #expect(request.fileDescriptor != nil)
            return try decodeMigrationFilename(request)
        }
        #expect(importedNames == [first, second])
    }

    private func incompleteMigrationTransport() -> MigrationWorkflowTransport {
        let epoch = epoch
        return MigrationWorkflowTransport { request in
            switch request.header.operation {
            case .beginStateMigration:
                try migrationSuccessReply(
                    TorrentEngineIPCStateMigrationBeginResponse(alreadyComplete: false),
                    for: request,
                    epoch: epoch
                )
            case .importStateMigrationFile, .commitStateMigration,
                 .abortStateMigration:
                try migrationSuccessReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            case .handshake:
                try migrationSuccessReply(
                    TorrentEngineIPCHandshakeResponse(
                        libtorrentVersion: "2.1.0",
                        folders: []
                    ),
                    for: request,
                    epoch: epoch
                )
            default:
                throw MigrationWorkflowTestError.unexpectedOperation(
                    request.header.operation
                )
            }
        }
    }

    private func makeMigrationClient(
        source: URL,
        transport: MigrationWorkflowTransport
    ) async throws -> TorrentXPCClient {
        try await TorrentXPCClient.connect(
            enablePeerExchangePlugin: false,
            folderAuthorizations: [],
            legacyStateDirectory: source,
            transport: transport,
            controllerID: UUID()
        )
    }
}

enum MigrationRemoteFailure: String, CaseIterable, Sendable {
    case importFile
    case commit
}

@safe private final class MigrationWorkflowTransport: TorrentEngineIPCTransport, Sendable {
    typealias Handler = @Sendable (TorrentEngineIPCRequest) async throws
        -> TorrentEngineIPCReply

    private struct State: Sendable {
        var requests = [TorrentEngineIPCRequest]()
        var isCancelled = false
    }

    private let handler: Handler
    private let state = Mutex(State())

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(
        _ request: TorrentEngineIPCRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> TorrentEngineIPCReply {
        try state.withLock { state in
            guard !state.isCancelled else {
                throw TorrentEngineClientError.connectionCancelled
            }
            state.requests.append(request)
        }
        guard ContinuousClock().now < deadline else {
            throw TorrentEngineClientError.requestTimedOut(
                outcomeUnknown: request.header.operation.timeoutCanLeaveOutcomeUnknown
            )
        }
        return try await handler(request)
    }

    func cancel() {
        state.withLock { $0.isCancelled = true }
    }

    var requests: [TorrentEngineIPCRequest] {
        state.withLock(\.requests)
    }

    var operations: [TorrentEngineIPCOperation] {
        state.withLock { $0.requests.map(\.header.operation) }
    }

    var sequences: [UInt64] {
        state.withLock { $0.requests.map(\.header.sequence) }
    }

    var isCancelled: Bool {
        state.withLock(\.isCancelled)
    }
}

private final class MigrationWorkflowTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "TorrentEngineMigrationWorkflowTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func makeStateDirectory(
        named name: String,
        withResumeData: Bool
    ) throws -> URL {
        let state = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: state,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        if withResumeData {
            try FileManager.default.createDirectory(
                at: state.appending(path: "ResumeData", directoryHint: .isDirectory),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return state
    }

    func makeSymlinkedStateDirectory(named name: String) throws -> URL {
        let target = try makeStateDirectory(
            named: "\(name)-Target",
            withResumeData: false
        )
        let link = url.appending(path: "\(name)-Link", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )
        return link
    }

    func writeResumeFile(
        named filename: String,
        in stateDirectory: URL,
        contents: String
    ) throws {
        try Data(contents.utf8).write(
            to: stateDirectory
                .appending(path: "ResumeData", directoryHint: .isDirectory)
                .appending(path: filename, directoryHint: .notDirectory)
        )
    }
}

private func migrationSuccessReply<Value: Encodable & Sendable>(
    _ value: Value,
    for request: TorrentEngineIPCRequest,
    epoch: UUID
) throws -> TorrentEngineIPCReply {
    TorrentEngineIPCReply(
        header: request.header,
        engineEpoch: epoch,
        status: .success,
        payload: try TorrentEngineIPCPropertyListCodec.encode(
            value,
            maximumBytes: request.header.operation.maximumReplyPayloadBytes
        )
    )
}

private func decodeMigrationFilename(
    _ request: TorrentEngineIPCRequest
) throws -> String {
    guard let payload = request.payload else {
        throw MigrationWorkflowTestError.missingPayload
    }
    let value = try TorrentEngineIPCPropertyListCodec.decode(
        TorrentEngineIPCStateMigrationFileRequest.self,
        from: payload,
        maximumBytes: request.header.operation.maximumRequestPayloadBytes
    )
    return value.name
}

private func expectMigrationFailure(
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("Expected legacy state migration to fail")
    } catch let error as TorrentEngineClientError {
        guard case .migrationFailed = error else {
            Issue.record("Unexpected client error: \(error)")
            return
        }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private enum MigrationWorkflowTestError: Error {
    case missingPayload
    case unexpectedOperation(TorrentEngineIPCOperation)
}
