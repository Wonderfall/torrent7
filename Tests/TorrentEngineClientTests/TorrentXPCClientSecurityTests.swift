import Foundation
import Synchronization
import Testing
import TorrentEngineIPC
import TorrentEngineModel
@testable import TorrentEngineClient

@Suite("Isolated engine client security")
struct TorrentXPCClientSecurityTests {
    private let epoch = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let torrentID = "t:\(String(repeating: "a", count: 32))"

    @Test("Reconciliation replaces the committed capability map atomically")
    func reconciliationReplacesCommittedCapabilities() async throws {
        let oldPath = testPath("old")
        let firstPath = testPath("first")
        let secondPath = testPath("second")
        let oldID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let epoch = epoch
        let transport = ScriptedTorrentEngineTransport { request in
            switch request.header.operation {
            case .handshake:
                try successReply(
                    TorrentEngineIPCHandshakeResponse(
                        libtorrentVersion: "2.1.0",
                        folders: [
                            TorrentEngineIPCGrantedFolder(
                                capabilityID: oldID,
                                resolvedPath: oldPath
                            )
                        ]
                    ),
                    for: request,
                    epoch: epoch
                )
            case .replaceFolderCapabilities:
                try successReply(
                    TorrentEngineIPCReplaceFoldersResponse(
                        folders: [
                            TorrentEngineIPCGrantedFolder(
                                capabilityID: secondID,
                                resolvedPath: secondPath
                            ),
                            TorrentEngineIPCGrantedFolder(
                                capabilityID: firstID,
                                resolvedPath: firstPath
                            )
                        ]
                    ),
                    for: request,
                    epoch: epoch
                )
            case .addMagnet:
                throw TorrentEngineClientError.serviceRejected("Rejected for testing")
            case .restart:
                try successReply(TorrentEngineIPCEmpty(), for: request, epoch: epoch)
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(
            transport: transport,
            authorizations: [authorization(path: oldPath, byte: 1)]
        )

        let unnormalizedFirstPath = URL(filePath: firstPath)
            .deletingLastPathComponent()
            .appending(path: "discarded")
            .appending(path: "..")
            .appending(path: URL(filePath: firstPath).lastPathComponent)
            .path(percentEncoded: false)
        try await client.reconcileFolderAuthorizations([
            authorization(path: unnormalizedFirstPath, byte: 2),
            authorization(path: secondPath, byte: 3)
        ])

        let replaceRequest = try #require(
            transport.requests.first { $0.header.operation == .replaceFolderCapabilities }
        )
        let replacement: TorrentEngineIPCReplaceFoldersRequest = try decodeRequest(replaceRequest)
        #expect(replacement.folders.count == 2)
        #expect(replacement.folders.allSatisfy { !$0.provisional })
        #expect(Set(replacement.folders.map(\.bookmark)) == [Data([2]), Data([3])])

        await #expect(throws: TorrentEngineClientError.self) {
            _ = try await client.addMagnet(
                "magnet:?xt=urn:btih:\(String(repeating: "b", count: 40))",
                savePath: firstPath,
                startsPaused: false,
                queuePriority: .normal,
                enablePeerExchange: false,
                allowNonHTTPSTrackers: false,
                allowNonHTTPSWebSeeds: false,
                allowPreMetadataDHT: false
            )
        }
        #expect(!transport.operations.contains(.revokeFolderCapability))

        try await client.restart(
            enablePeerExchangePlugin: false,
            authorizedSavePaths: [secondPath, firstPath]
        )
        let restartRequest = try #require(
            transport.requests.last { $0.header.operation == .restart }
        )
        let restart: TorrentEngineIPCRestartRequest = try decodeRequest(restartRequest)
        #expect(Set(restart.capabilityIDs) == [firstID, secondID])

        let operationCount = transport.operations.count
        await #expect(throws: TorrentEngineClientError.self) {
            try await client.restart(
                enablePeerExchangePlugin: false,
                authorizedSavePaths: [oldPath]
            )
        }
        #expect(transport.operations.count == operationCount)
    }

    @Test("Local exact-replacement validation failure terminalizes before the wire")
    func localReconciliationValidationFailureTerminalizes() async throws {
        let epoch = epoch
        let transport = ScriptedTorrentEngineTransport { request in
            switch request.header.operation {
            case .handshake:
                try successReply(
                    TorrentEngineIPCHandshakeResponse(
                        libtorrentVersion: "2.1.0",
                        folders: []
                    ),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        await #expect(throws: TorrentEngineClientError.self) {
            try await client.reconcileFolderAuthorizations([
                TorrentFolderAuthorization(
                    path: testPath("invalid-empty-bookmark"),
                    bookmarkData: Data()
                ),
            ])
        }

        #expect(transport.operations == [.handshake])
        #expect(transport.isCancelled)
        #expect(!client.isAvailable)
    }

    @Test("A rejected reconciliation terminates instead of retaining revoked authority")
    func rejectedReconciliationTerminates() async throws {
        let oldPath = testPath("old-rejected")
        let newPath = testPath("new-rejected")
        let oldID = UUID()
        let epoch = epoch
        let transport = ScriptedTorrentEngineTransport { request in
            switch request.header.operation {
            case .handshake:
                try successReply(
                    TorrentEngineIPCHandshakeResponse(
                        libtorrentVersion: "2.1.0",
                        folders: [
                            TorrentEngineIPCGrantedFolder(
                                capabilityID: oldID,
                                resolvedPath: oldPath
                            )
                        ]
                    ),
                    for: request,
                    epoch: epoch
                )
            case .replaceFolderCapabilities:
                throw TorrentEngineClientError.serviceRejected("Rejected for testing")
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(
            transport: transport,
            authorizations: [authorization(path: oldPath, byte: 1)]
        )

        await #expect(throws: TorrentEngineClientError.self) {
            try await client.reconcileFolderAuthorizations([
                authorization(path: newPath, byte: 2)
            ])
        }
        #expect(!client.isAvailable)
        #expect(transport.isCancelled)
        #expect(transport.operations == [.handshake, .replaceFolderCapabilities])
    }

    @Test("Mismatched replacement paths terminate the client")
    func mismatchedReconciliationTerminates() async throws {
        let oldPath = testPath("old-mismatch")
        let requestedPath = testPath("requested")
        let wrongPath = testPath("wrong")
        let epoch = epoch
        let transport = ScriptedTorrentEngineTransport { request in
            switch request.header.operation {
            case .handshake:
                try successReply(
                    TorrentEngineIPCHandshakeResponse(
                        libtorrentVersion: "2.1.0",
                        folders: [
                            TorrentEngineIPCGrantedFolder(
                                capabilityID: UUID(),
                                resolvedPath: oldPath
                            )
                        ]
                    ),
                    for: request,
                    epoch: epoch
                )
            case .replaceFolderCapabilities:
                try successReply(
                    TorrentEngineIPCReplaceFoldersResponse(
                        folders: [
                            TorrentEngineIPCGrantedFolder(
                                capabilityID: UUID(),
                                resolvedPath: wrongPath
                            )
                        ]
                    ),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(
            transport: transport,
            authorizations: [authorization(path: oldPath, byte: 1)]
        )

        await #expect(throws: TorrentEngineClientError.self) {
            try await client.reconcileFolderAuthorizations([
                authorization(path: requestedPath, byte: 2)
            ])
        }

        #expect(!client.isAvailable)
        #expect(transport.isCancelled)
    }

    @Test("A definite add rejection revokes its provisional capability")
    func rejectedAddRevokesProvisionalCapability() async throws {
        let path = testPath("rejected-add")
        let capabilityID = UUID()
        let epoch = epoch
        let transport = ScriptedTorrentEngineTransport { request in
            switch request.header.operation {
            case .handshake:
                try successReply(
                    TorrentEngineIPCHandshakeResponse(libtorrentVersion: "2.1.0", folders: []),
                    for: request,
                    epoch: epoch
                )
            case .grantFolderCapability:
                try successReply(
                    TorrentEngineIPCGrantFolderResponse(
                        folder: TorrentEngineIPCGrantedFolder(
                            capabilityID: capabilityID,
                            resolvedPath: path
                        )
                    ),
                    for: request,
                    epoch: epoch
                )
            case .addMagnet:
                throw TorrentEngineClientError.serviceRejected("Rejected for testing")
            case .revokeFolderCapability:
                try successReply(TorrentEngineIPCEmpty(), for: request, epoch: epoch)
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)
        try await client.delegateFolderAuthorization(authorization(path: path, byte: 1))

        await #expect(throws: TorrentEngineClientError.self) {
            _ = try await addMagnet(client: client, savePath: path)
        }

        #expect(transport.operations == [
            .handshake,
            .grantFolderCapability,
            .addMagnet,
            .revokeFolderCapability
        ])
        #expect(client.isAvailable)
        let operationCount = transport.operations.count
        await #expect(throws: TorrentEngineClientError.self) {
            _ = try await addMagnet(client: client, savePath: path)
        }
        #expect(transport.operations.count == operationCount)
    }

    @Test("An ambiguous add failure does not revoke a possibly committed capability")
    func ambiguousAddDoesNotRevoke() async throws {
        let path = testPath("ambiguous-add")
        let epoch = epoch
        let transport = provisionalAddTransport(path: path, epoch: epoch) { _ in
            throw TorrentEngineClientError.connectionFailed
        }
        let client = try await makeClient(transport: transport)
        try await client.delegateFolderAuthorization(authorization(path: path, byte: 1))

        await #expect(throws: TorrentEngineClientError.self) {
            _ = try await addMagnet(client: client, savePath: path)
        }

        #expect(transport.operations == [.handshake, .grantFolderCapability, .addMagnet])
        #expect(transport.isCancelled)
        #expect(!client.isAvailable)
    }

    @Test("A successful add response round trips its canonical identifier")
    func successfulAddResponseRoundTripsIdentifier() async throws {
        let path = testPath("successful-add")
        let epoch = epoch
        let torrentID = torrentID
        let transport = provisionalAddTransport(path: path, epoch: epoch) { request in
            try successReply(
                TorrentEngineIPCAddedTorrentResponse(identifier: torrentID),
                for: request,
                epoch: epoch
            )
        }
        let client = try await makeClient(transport: transport)
        try await client.delegateFolderAuthorization(authorization(path: path, byte: 1))

        let identifier = try await addMagnet(client: client, savePath: path)

        #expect(identifier == torrentID)
        #expect(transport.operations == [.handshake, .grantFolderCapability, .addMagnet])
        #expect(!transport.isCancelled)
        #expect(client.isAvailable)
    }

    @Test("A successful torrent-file add round trips its canonical identifier")
    func successfulTorrentFileAddResponseRoundTripsIdentifier() async throws {
        let path = testPath("successful-file-add")
        let epoch = epoch
        let torrentID = torrentID
        let transport = provisionalAddTransport(path: path, epoch: epoch) { request in
            try successReply(
                TorrentEngineIPCAddedTorrentResponse(identifier: torrentID),
                for: request,
                epoch: epoch
            )
        }
        let client = try await makeClient(transport: transport)
        try await client.delegateFolderAuthorization(authorization(path: path, byte: 1))

        let identifier = try await client.addTorrentFile(
            data: Data("d4:infod4:name4:testee".utf8),
            savePath: path,
            filePriorities: [0: .normal],
            startsPaused: false,
            queuePriority: .normal,
            enablePeerExchange: false,
            allowNonHTTPSTrackers: false,
            allowNonHTTPSWebSeeds: false
        )

        #expect(identifier == torrentID)
        #expect(transport.operations == [.handshake, .grantFolderCapability, .addTorrentFile])
        #expect(!transport.isCancelled)
        #expect(client.isAvailable)
    }

    @Test("A semantically invalid add reply is terminal and never revokes")
    func invalidAddReplyIsTerminal() async throws {
        let path = testPath("invalid-add")
        let epoch = epoch
        let transport = provisionalAddTransport(path: path, epoch: epoch) { request in
            try successReply(
                TorrentEngineIPCAddedTorrentResponse(
                    identifier: "not-a-canonical-torrent-id"
                ),
                for: request,
                epoch: epoch
            )
        }
        let client = try await makeClient(transport: transport)
        try await client.delegateFolderAuthorization(authorization(path: path, byte: 1))

        await #expect(throws: TorrentEngineClientError.self) {
            _ = try await addMagnet(client: client, savePath: path)
        }

        #expect(transport.operations == [.handshake, .grantFolderCapability, .addMagnet])
        #expect(transport.isCancelled)
        #expect(!client.isAvailable)
        let operationCount = transport.operations.count
        await #expect(throws: TorrentEngineClientError.self) {
            try await client.pause(id: torrentID)
        }
        #expect(transport.operations.count == operationCount)
    }

    @Test(arguments: InvalidReplyKind.allCases)
    func malformedUnitReplyTerminates(kind: InvalidReplyKind) async throws {
        let epoch = epoch
        let transport = ScriptedTorrentEngineTransport { request in
            switch request.header.operation {
            case .handshake:
                try successReply(
                    TorrentEngineIPCHandshakeResponse(libtorrentVersion: "2.1.0", folders: []),
                    for: request,
                    epoch: epoch
                )
            case .pause:
                TorrentEngineIPCReply(
                    header: request.header,
                    engineEpoch: epoch,
                    status: .success,
                    payload: kind == .missingPayload ? nil : Data([0xff])
                )
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        await #expect(throws: TorrentEngineClientError.self) {
            try await client.pause(id: torrentID)
        }

        #expect(!client.isAvailable)
        #expect(transport.isCancelled)
        #expect(transport.operations == [.handshake, .pause])
    }

    @Test("Typed busy failures are retryable without weakening other rejections")
    func typedBusyFailureIsTransient() throws {
        let header = TorrentEngineIPCHeader(
            requestID: UUID(),
            controllerID: UUID(),
            sequence: 1,
            operation: .handshake,
            operationID: UUID(),
            expectedEpoch: nil
        )
        let request = TorrentEngineIPCRequest(header: header)
        let reply = TorrentEngineIPCReply(
            header: header,
            engineEpoch: epoch,
            status: .failure,
            failureCode: .controllerBusy,
            errorMessage: "Previous controller cleanup is still running."
        )

        do {
            _ = try TorrentEngineXPCTransport.validateDecodedReply(reply, for: request)
            Issue.record("Expected a transient service rejection")
        } catch let error as TorrentEngineClientError {
            guard case .serviceTemporarilyUnavailable(let message) = error else {
                Issue.record("Expected a typed transient failure")
                return
            }
            #expect(message.contains("cleanup"))
        }
    }

    @Test("Typed service cleanup retries remain bounded to the cleanup horizon")
    func serviceCleanupRetryHorizon() {
        var policy = TorrentEngineConnectionRetryPolicy()
        var delays = [Duration]()

        while let delay = policy.delay(
            after: .serviceTemporarilyUnavailable("Previous controller cleanup is still running.")
        ) {
            delays.append(delay)
        }

        #expect(delays.count > 4)
        #expect(delays.reduce(.zero, +) == .seconds(305))
        #expect(delays.allSatisfy { $0 > .zero && $0 <= .seconds(5) })
        #expect(policy.delay(after: .serviceTemporarilyUnavailable("busy")) == nil)
    }

    @Test("Connection invalidation remains transient after typed cleanup begins")
    func cleanupRetrySurvivesConnectionRelaunch() {
        var policy = TorrentEngineConnectionRetryPolicy()

        #expect(
            policy.delay(after: .serviceTemporarilyUnavailable("shutting down"))
                == .milliseconds(250)
        )
        #expect(policy.delay(after: .connectionCancelled) == .milliseconds(500))
        #expect(policy.delay(after: .connectionFailed) == .seconds(1))
        #expect(policy.delay(after: .serviceRejected("invalid peer")) == nil)
    }

    @Test("Only transient connection failures use short retries")
    func connectionRetryClassification() {
        var connectionPolicy = TorrentEngineConnectionRetryPolicy()
        #expect(connectionPolicy.delay(after: .connectionFailed) == .milliseconds(50))
        #expect(connectionPolicy.delay(after: .connectionCancelled) == .milliseconds(100))
        #expect(connectionPolicy.delay(after: .connectionFailed) == .milliseconds(200))
        #expect(connectionPolicy.delay(after: .connectionFailed) == nil)

        var rejectionPolicy = TorrentEngineConnectionRetryPolicy()
        #expect(rejectionPolicy.delay(after: .serviceRejected("invalid peer")) == nil)
        #expect(rejectionPolicy.delay(after: .invalidReply) == nil)
        #expect(rejectionPolicy.delay(after: .invalidBookmark) == nil)
    }

    @Test("An absent optional detail is valid and keeps the connection alive")
    func absentOptionalDetailIsValid() async throws {
        let epoch = epoch
        let transport = ScriptedTorrentEngineTransport { request in
            switch request.header.operation {
            case .handshake:
                try successReply(
                    TorrentEngineIPCHandshakeResponse(
                        libtorrentVersion: "2.1.0",
                        folders: []
                    ),
                    for: request,
                    epoch: epoch
                )
            case .webSeedActivity:
                try successReply(
                    TorrentEngineIPCOptionalValue<TorrentWebSeedActivity>(nil),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        #expect(await client.webSeedActivity(id: torrentID) == nil)
        #expect(client.isAvailable)
        #expect(!transport.isCancelled)
    }

    @Test("An invalid present optional detail terminates the connection")
    func invalidOptionalDetailIsTerminal() async throws {
        let epoch = epoch
        let transport = ScriptedTorrentEngineTransport { request in
            switch request.header.operation {
            case .handshake:
                try successReply(
                    TorrentEngineIPCHandshakeResponse(
                        libtorrentVersion: "2.1.0",
                        folders: []
                    ),
                    for: request,
                    epoch: epoch
                )
            case .webSeedActivity:
                try successReply(
                    TorrentEngineIPCOptionalValue(
                        TorrentWebSeedActivity(
                            activeCount: -1,
                            downloadRate: 0,
                            totalDownload: 0
                        )
                    ),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        #expect(await client.webSeedActivity(id: torrentID) == nil)
        #expect(!client.isAvailable)
        #expect(transport.isCancelled)
    }

    @Test("Concurrent calls use one strictly increasing request sequence")
    func concurrentCallsAreSerialized() async throws {
        let blocker = AsyncRequestBlocker()
        let epoch = epoch
        let transport = ScriptedTorrentEngineTransport { request in
            switch request.header.operation {
            case .handshake:
                return try successReply(
                    TorrentEngineIPCHandshakeResponse(libtorrentVersion: "2.1.0", folders: []),
                    for: request,
                    epoch: epoch
                )
            case .pause:
                await blocker.block()
                return try successReply(TorrentEngineIPCEmpty(), for: request, epoch: epoch)
            case .resume:
                return try successReply(TorrentEngineIPCEmpty(), for: request, epoch: epoch)
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        let first = Task {
            try await client.pause(id: torrentID)
        }
        await blocker.waitUntilBlocked()
        let second = Task {
            try await client.resume(id: torrentID)
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(transport.operations == [.handshake, .pause])
        await blocker.release()
        try await first.value
        try await second.value

        #expect(transport.operations == [.handshake, .pause, .resume])
        #expect(transport.sequences == [1, 2, 3])
        #expect(transport.maximumConcurrentSends == 1)
    }

    @Test("Cancelling a queued call does not terminate the controller")
    func queuedCancellationIsLocal() async throws {
        let blocker = AsyncRequestBlocker()
        let epoch = epoch
        let transport = ScriptedTorrentEngineTransport { request in
            switch request.header.operation {
            case .handshake:
                return try successReply(
                    TorrentEngineIPCHandshakeResponse(
                        libtorrentVersion: "2.1.0",
                        folders: []
                    ),
                    for: request,
                    epoch: epoch
                )
            case .pause:
                await blocker.block()
                return try successReply(TorrentEngineIPCEmpty(), for: request, epoch: epoch)
            case .resume, .reannounce:
                return try successReply(TorrentEngineIPCEmpty(), for: request, epoch: epoch)
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        let inFlight = Task {
            try await client.pause(id: torrentID)
        }
        await blocker.waitUntilBlocked()
        let queued = Task {
            try await client.resume(id: torrentID)
        }
        try await Task.sleep(for: .milliseconds(50))
        queued.cancel()

        await #expect(throws: TorrentEngineClientError.self) {
            try await queued.value
        }
        #expect(transport.operations == [.handshake, .pause])

        await blocker.release()
        try await inFlight.value
        try await client.reannounce(id: torrentID)

        #expect(client.isAvailable)
        #expect(!transport.isCancelled)
        #expect(transport.operations == [.handshake, .pause, .reannounce])
        #expect(transport.sequences == [1, 2, 3])
    }

    @Test("An urgent network block preempts an ordered request by closing the controller")
    func urgentNetworkBlockPreemptsInFlightRequest() async throws {
        let blocker = AsyncRequestBlocker()
        let epoch = epoch
        let transport = ScriptedTorrentEngineTransport { request in
            switch request.header.operation {
            case .handshake:
                return try successReply(
                    TorrentEngineIPCHandshakeResponse(
                        libtorrentVersion: "2.1.0",
                        folders: []
                    ),
                    for: request,
                    epoch: epoch
                )
            case .pause:
                await blocker.block()
                return try successReply(TorrentEngineIPCEmpty(), for: request, epoch: epoch)
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)
        let inFlight = Task {
            try await client.pause(id: torrentID)
        }
        await blocker.waitUntilBlocked()

        await #expect(throws: TorrentEngineClientError.self) {
            try await client.blockNetworkNow()
        }

        #expect(!client.isAvailable)
        #expect(transport.isCancelled)
        #expect(transport.operations == [.handshake, .pause])
        await blocker.release()
        _ = try? await inFlight.value
    }

    private func makeClient(
        transport: ScriptedTorrentEngineTransport,
        authorizations: [TorrentFolderAuthorization] = []
    ) async throws -> TorrentXPCClient {
        try await TorrentXPCClient.connect(
            enablePeerExchangePlugin: false,
            folderAuthorizations: authorizations,
            transport: transport,
            controllerID: UUID()
        )
    }

    private func authorization(path: String, byte: UInt8) -> TorrentFolderAuthorization {
        TorrentFolderAuthorization(path: path, bookmarkData: Data([byte]))
    }

    private func testPath(_ component: String) -> String {
        FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appending(path: "TorrentXPCClientSecurityTests-\(component)", directoryHint: .isDirectory)
            .standardizedFileURL
            .path(percentEncoded: false)
    }

    private func addMagnet(
        client: TorrentXPCClient,
        savePath: String
    ) async throws -> String {
        try await client.addMagnet(
            "magnet:?xt=urn:btih:\(String(repeating: "c", count: 40))",
            savePath: savePath,
            startsPaused: false,
            queuePriority: .normal,
            enablePeerExchange: false,
            allowNonHTTPSTrackers: false,
            allowNonHTTPSWebSeeds: false,
            allowPreMetadataDHT: false
        )
    }

    private func provisionalAddTransport(
        path: String,
        epoch: UUID,
        addHandler: @escaping @Sendable (TorrentEngineIPCRequest) async throws
            -> TorrentEngineIPCReply
    ) -> ScriptedTorrentEngineTransport {
        let capabilityID = UUID()
        return ScriptedTorrentEngineTransport { request in
            switch request.header.operation {
            case .handshake:
                try successReply(
                    TorrentEngineIPCHandshakeResponse(libtorrentVersion: "2.1.0", folders: []),
                    for: request,
                    epoch: epoch
                )
            case .grantFolderCapability:
                try successReply(
                    TorrentEngineIPCGrantFolderResponse(
                        folder: TorrentEngineIPCGrantedFolder(
                            capabilityID: capabilityID,
                            resolvedPath: path
                        )
                    ),
                    for: request,
                    epoch: epoch
                )
            case .addMagnet, .addTorrentFile:
                try await addHandler(request)
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
    }
}

enum InvalidReplyKind: CaseIterable, Sendable {
    case missingPayload
    case malformedPayload
}

@safe private final class ScriptedTorrentEngineTransport: TorrentEngineIPCTransport, Sendable {
    typealias Handler = @Sendable (TorrentEngineIPCRequest) async throws
        -> TorrentEngineIPCReply

    private struct State: Sendable {
        var requests = [TorrentEngineIPCRequest]()
        var activeSends = 0
        var maximumConcurrentSends = 0
        var isCancelled = false
    }

    private let handler: Handler
    private let state = Mutex(State())

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: TorrentEngineIPCRequest) async throws -> TorrentEngineIPCReply {
        try state.withLock { state in
            guard !state.isCancelled else {
                throw TorrentEngineClientError.connectionCancelled
            }
            state.requests.append(request)
            state.activeSends += 1
            state.maximumConcurrentSends = max(
                state.maximumConcurrentSends,
                state.activeSends
            )
        }
        defer {
            state.withLock { $0.activeSends -= 1 }
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

    var maximumConcurrentSends: Int {
        state.withLock(\.maximumConcurrentSends)
    }

    var isCancelled: Bool {
        state.withLock(\.isCancelled)
    }
}

private actor AsyncRequestBlocker {
    private var blocked = false
    private var released = false
    private var blockedWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()

    func block() async {
        blocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else {
            return
        }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !blocked else {
            return
        }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private func successReply<Value: Encodable & Sendable>(
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

private func decodeRequest<Value: Decodable & Sendable>(
    _ request: TorrentEngineIPCRequest
) throws -> Value {
    guard let payload = request.payload else {
        throw TorrentXPCClientTestError.missingPayload
    }
    return try TorrentEngineIPCPropertyListCodec.decode(
        from: payload,
        maximumBytes: request.header.operation.maximumRequestPayloadBytes
    )
}

private enum TorrentXPCClientTestError: Error {
    case missingPayload
}
