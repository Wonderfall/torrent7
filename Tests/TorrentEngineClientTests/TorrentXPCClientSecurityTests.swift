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

    @Test("Change hints are validated without acquiring message resources")
    func changeHintValidationUsesMetadata() throws {
        let controllerID = UUID()
        let header = TorrentEngineIPCHeader(
            requestID: UUID(),
            controllerID: controllerID,
            sequence: 1,
            operation: .changeHint,
            operationID: UUID(),
            expectedEpoch: epoch
        )

        #expect(TorrentEngineXPCTransport.validateHint(
            TorrentEngineIPCRequestMetadata(
                header: header,
                hasPayload: false,
                payloadByteCount: 0,
                hasFileDescriptor: false
            ),
            controllerID: controllerID
        ))
        #expect(!TorrentEngineXPCTransport.validateHint(
            TorrentEngineIPCRequestMetadata(
                header: header,
                hasPayload: true,
                payloadByteCount: 0,
                hasFileDescriptor: false
            ),
            controllerID: controllerID
        ))
        #expect(!TorrentEngineXPCTransport.validateHint(
            TorrentEngineIPCRequestMetadata(
                header: header,
                hasPayload: false,
                payloadByteCount: 0,
                hasFileDescriptor: true
            ),
            controllerID: controllerID
        ))
        #expect(!TorrentEngineXPCTransport.validateHint(
            TorrentEngineIPCRequestMetadata(
                header: header,
                hasPayload: false,
                payloadByteCount: 0,
                hasFileDescriptor: false
            ),
            controllerID: UUID()
        ))

        let encodedEmptyPayload = try TorrentEngineIPCEnvelopeCodec.encode(
            TorrentEngineIPCRequest(header: header, payload: Data()),
            maximumPayloadBytes: 0
        )
        let inspectedEmptyPayload = try TorrentEngineIPCEnvelopeCodec.inspectRequest(
            encodedEmptyPayload
        )
        #expect(inspectedEmptyPayload.hasPayload)
        #expect(inspectedEmptyPayload.payloadByteCount == 0)
        #expect(!TorrentEngineXPCTransport.validateHint(
            inspectedEmptyPayload,
            controllerID: controllerID
        ))
    }

    @Test("XPC reply completion is exactly once across reply and deadline races")
    func xpcReplyCompletionIsExactlyOnce() async throws {
        let header = TorrentEngineIPCHeader(
            requestID: UUID(),
            controllerID: UUID(),
            sequence: 1,
            operation: .poll,
            operationID: UUID(),
            expectedEpoch: epoch
        )
        let reply = TorrentEngineIPCReply(
            header: header,
            engineEpoch: epoch,
            status: .success
        )
        let stream = AsyncStream<TorrentEngineXPCTransport.PendingReply>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let waiting = Task<TorrentEngineIPCReply, any Error> {
            try await withCheckedThrowingContinuation { continuation in
                stream.continuation.yield(
                    TorrentEngineXPCTransport.PendingReply(continuation)
                )
                stream.continuation.finish()
            }
        }
        var iterator = stream.stream.makeAsyncIterator()
        let completion = try #require(await iterator.next())

        #expect(completion.finish(.success(reply)))
        #expect(!completion.finish(.failure(TorrentEngineClientError.invalidReply)))
        #expect(try await waiting.value == reply)

        let timeoutStream = AsyncStream<TorrentEngineXPCTransport.PendingReply>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let timingOut = Task<TorrentEngineIPCReply, any Error> {
            try await withCheckedThrowingContinuation { continuation in
                timeoutStream.continuation.yield(
                    TorrentEngineXPCTransport.PendingReply(continuation)
                )
                timeoutStream.continuation.finish()
            }
        }
        var timeoutIterator = timeoutStream.stream.makeAsyncIterator()
        let timeoutCompletion = try #require(await timeoutIterator.next())
        timeoutCompletion.installTimeoutTask(Task.detached {
            try? await ContinuousClock().sleep(for: .milliseconds(5))
            _ = timeoutCompletion.finish(.failure(
                TorrentEngineClientError.requestTimedOut(outcomeUnknown: false)
            ))
        })

        await #expect(throws: TorrentEngineClientError.self) {
            try await timingOut.value
        }
        #expect(!timeoutCompletion.finish(.success(reply)))
    }

    @Test("Empty preview data is rejected before transport")
    func emptyPreviewIsRejectedLocally() async throws {
        let epoch = epoch
        let transport = ScriptedTorrentEngineTransport { request in
            guard request.header.operation == .handshake else {
                Issue.record("Empty preview data reached the transport")
                throw TorrentEngineClientError.serviceRejected("Unexpected request")
            }
            return try successReply(
                TorrentEngineIPCHandshakeResponse(
                    libtorrentVersion: "2.1.0",
                    folders: []
                ),
                for: request,
                epoch: epoch
            )
        }
        let client = try await makeClient(transport: transport)

        await #expect(throws: TorrentEngineClientError.self) {
            try await client.previewTorrentFile(data: Data())
        }
    }

    @Test("Preview metadata preserves the original client torrent bytes")
    func previewPreservesOriginalTorrentBytes() async throws {
        let epoch = epoch
        let input = Data([0x64, 0x34, 0x3A, 0x69, 0x6E, 0x66, 0x6F])
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
            case .previewTorrentFile:
                #expect(request.payload == input)
                return try successReply(
                    TorrentEngineIPCFilePreviewResponse(TorrentFilePreview(
                        name: "Preview",
                        id: "v1:\(String(repeating: "b", count: 40))",
                        totalSize: 42,
                        sourceSecuritySummary: .empty,
                        files: [],
                        torrentData: Data([0xFF])
                    )),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        let preview = try await client.previewTorrentFile(data: input)

        #expect(preview.name == "Preview")
        #expect(preview.totalSize == 42)
        #expect(preview.torrentData == input)
    }

    @Test("Invalid preview metadata terminates the client")
    func invalidPreviewMetadataIsTerminal() async throws {
        let epoch = epoch
        let input = Data([0x64])
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
            case .previewTorrentFile:
                return try successReply(
                    TorrentEngineIPCFilePreviewResponse(TorrentFilePreview(
                        name: "Preview",
                        id: "v1:\(String(repeating: "b", count: 40))",
                        totalSize: -1,
                        sourceSecuritySummary: .empty,
                        files: [],
                        torrentData: input
                    )),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        await #expect(throws: TorrentEngineClientError.self) {
            try await client.previewTorrentFile(data: input)
        }
        #expect(!client.isAvailable)
        #expect(client.recoveryDisposition == .terminal)
        #expect(transport.isCancelled)
    }

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

    @Test("Cancellation cannot suppress revoke after a drained definite add rejection")
    func cancelledDefiniteAddStillRevokes() async throws {
        let path = testPath("cancelled-definite-add")
        let epoch = epoch
        let capabilityID = UUID()
        let blocker = AsyncRequestBlocker()
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
            case .grantFolderCapability:
                return try successReply(
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
                await blocker.block()
                throw TorrentEngineClientError.serviceRejected(
                    "Rejected before commit"
                )
            case .revokeFolderCapability:
                return try successReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            case .reannounce:
                return try successReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected(
                    "Unexpected operation"
                )
            }
        }
        let client = try await makeClient(transport: transport)
        try await client.delegateFolderAuthorization(
            authorization(path: path, byte: 9)
        )
        let add = Task {
            try await addMagnet(client: client, savePath: path)
        }
        await blocker.waitUntilBlocked()

        add.cancel()
        await blocker.release()
        await #expect(throws: TorrentEngineClientError.self) {
            try await add.value
        }

        #expect(transport.operations == [
            .handshake,
            .grantFolderCapability,
            .addMagnet,
            .revokeFolderCapability,
        ])
        #expect(client.isAvailable)
        #expect(!transport.isCancelled)
        try await client.reannounce(id: torrentID)
        #expect(transport.sequences == [1, 2, 3, 4, 5])
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
        #expect(client.recoveryDisposition == .terminal)
        #expect(transport.isCancelled)
        #expect(transport.operations == [.handshake, .pause])
    }

    @Test("Connection loss requests a fresh controller")
    func connectionLossRequestsControllerReplacement() async throws {
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
                throw TorrentEngineClientError.connectionFailed
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        await #expect(throws: TorrentEngineClientError.self) {
            try await client.pause(id: torrentID)
        }

        #expect(!client.isAvailable)
        #expect(client.recoveryDisposition == .replaceController)
        #expect(transport.isCancelled)
    }

    @Test("An engine epoch change is terminal")
    func engineRestartIsTerminal() async throws {
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
                throw TorrentEngineClientError.engineRestarted
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        await #expect(throws: TorrentEngineClientError.self) {
            try await client.pause(id: torrentID)
        }

        #expect(!client.isAvailable)
        #expect(client.recoveryDisposition == .terminal)
        #expect(transport.isCancelled)
    }

    @Test("A terminal failure dominates transport cancellation ordering")
    func terminalFailureDominatesTransportCancellation() {
        let state = TorrentXPCClientState()

        state.cancel(
            message: TorrentEngineClientError.connectionCancelled.localizedDescription,
            recoveryDisposition: .replaceController
        )
        state.cancel(
            message: TorrentEngineClientError.invalidReply.localizedDescription,
            recoveryDisposition: .terminal
        )
        state.cancel(
            message: TorrentEngineClientError.connectionCancelled.localizedDescription,
            recoveryDisposition: .replaceController
        )

        #expect(!state.isAvailable)
        #expect(state.failure == TorrentEngineClientError.invalidReply.localizedDescription)
        #expect(state.recoveryDisposition == .terminal)
    }

    @Test("Owner termination preserves terminal recovery intent")
    func ownerTerminationPreservesTerminalRecoveryIntent() async throws {
        let epoch = epoch
        let transport = ScriptedTorrentEngineTransport { request in
            guard request.header.operation == .handshake else {
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
            return try successReply(
                TorrentEngineIPCHandshakeResponse(libtorrentVersion: "2.1.0", folders: []),
                for: request,
                epoch: epoch
            )
        }
        let client = try await makeClient(transport: transport)

        await client.terminateConnection(recoveryDisposition: .terminal)
        await client.terminateConnection(recoveryDisposition: .replaceController)

        #expect(!client.isAvailable)
        #expect(client.recoveryDisposition == .terminal)
        #expect(transport.isCancelled)
    }

    @Test("A rejected poll throws and is terminal")
    func rejectedPollThrowsAndIsTerminal() async throws {
        let epoch = epoch
        let rejection = "The poll request violated service policy."
        let transport = ScriptedTorrentEngineTransport { request in
            switch request.header.operation {
            case .handshake:
                try successReply(
                    TorrentEngineIPCHandshakeResponse(libtorrentVersion: "2.1.0", folders: []),
                    for: request,
                    epoch: epoch
                )
            case .poll:
                throw TorrentEngineClientError.serviceRejected(rejection)
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        await #expect(throws: TorrentEngineClientError.self) {
            try await client.poll(
                since: nil,
                sortedBy: .dateAdded,
                direction: .ascending,
                includeTrackerHosts: false
            )
        }

        #expect(!client.isAvailable)
        #expect(client.recoveryDisposition == .terminal)
        #expect(transport.isCancelled)
    }

    @Test("Poll assembles and closes a paged tracker-host dataset")
    func pollLoadsAndClosesTrackerHostDataset() async throws {
        struct DatasetState: Sendable {
            var didRead = false
            var didClose = false
        }

        let epoch = epoch
        let datasetID = UUID()
        let host = TorrentTrackerHostItem(
            torrentID: torrentID,
            host: "tracker.example"
        )
        let state = Mutex(DatasetState())
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
            case .poll:
                let poll: TorrentEngineIPCPollRequest = try decodeRequest(request)
                #expect(poll.snapshotRevision == 7)
                #expect(poll.sortOrder == .name)
                #expect(poll.sortDirection == .descending)
                #expect(poll.includeTrackerHosts)
                return try successReply(
                    TorrentEngineIPCPollResponse(
                        dirtyMask: TorrentEngineDirtySet.trackerHosts.rawValue,
                        alertErrors: [],
                        networkStatus: .empty,
                        bridgeHealth: .healthy,
                        networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                            revision: 1,
                            interfaces: []
                        ),
                        snapshotDataset: nil,
                        trackerHostDataset: TorrentEngineIPCDatasetDescriptor(
                            id: datasetID,
                            kind: .trackerHosts,
                            revision: 9,
                            itemCount: 1,
                            pageCount: 1
                        )
                    ),
                    for: request,
                    epoch: epoch
                )
            case .readDataset:
                let read: TorrentEngineIPCReadDatasetRequest = try decodeRequest(request)
                #expect(read.id == datasetID)
                #expect(read.page == 0)
                state.withLock { $0.didRead = true }
                let encodedHosts = try TorrentEngineIPCPropertyListCodec.encode(
                    [host],
                    maximumBytes: TorrentEngineIPCLimits.maximumDatasetPageBytes
                )
                return try successReply(
                    TorrentEngineIPCDatasetPage(
                        id: datasetID,
                        kind: .trackerHosts,
                        page: 0,
                        encodedItems: encodedHosts
                    ),
                    for: request,
                    epoch: epoch
                )
            case .closeDataset:
                let close: TorrentEngineIPCCloseDatasetRequest = try decodeRequest(request)
                #expect(close.id == datasetID)
                state.withLock { $0.didClose = true }
                return try successReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        let result = try await client.poll(
            since: 7,
            sortedBy: .name,
            direction: .descending,
            includeTrackerHosts: true
        )

        #expect(result.trackerHostBatch?.revision == 9)
        #expect(result.trackerHostBatch?.hosts == [host])
        let finalState = state.withLock { $0 }
        #expect(finalState.didRead)
        #expect(finalState.didClose)
    }

    @Test("Concurrent polls serialize complete dataset pipelines")
    func concurrentPollsSerializeDatasetPipelines() async throws {
        struct DatasetBudgetState: Sendable {
            var pollCount = 0
            var openIDs = Set<UUID>()
            var maximumOpenCount = 0
        }

        let epoch = epoch
        let firstPollBlocker = AsyncRequestBlocker()
        let datasetIDs = (0..<3).map { _ in (UUID(), UUID()) }
        let budget = Mutex(DatasetBudgetState())
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
            case .poll:
                let pollIndex = try budget.withLock { state in
                    guard state.pollCount < datasetIDs.count else {
                        throw TorrentEngineClientError.serviceRejected(
                            "Unexpected extra poll"
                        )
                    }
                    let index = state.pollCount
                    state.pollCount += 1
                    state.openIDs.insert(datasetIDs[index].0)
                    state.openIDs.insert(datasetIDs[index].1)
                    state.maximumOpenCount = max(
                        state.maximumOpenCount,
                        state.openIDs.count
                    )
                    guard state.openIDs.count
                            <= TorrentEngineIPCLimits.maximumOpenDatasets else {
                        throw TorrentEngineClientError.serviceRejected(
                            "Too many torrent engine datasets are open."
                        )
                    }
                    return index
                }
                if pollIndex == 0 {
                    await firstPollBlocker.block()
                }
                return try successReply(
                    TorrentEngineIPCPollResponse(
                        dirtyMask: 0,
                        alertErrors: [],
                        networkStatus: .empty,
                        bridgeHealth: .healthy,
                        networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                            revision: 1,
                            interfaces: []
                        ),
                        snapshotDataset: TorrentEngineIPCDatasetDescriptor(
                            id: datasetIDs[pollIndex].0,
                            kind: .torrentSnapshots,
                            revision: UInt64(pollIndex + 1),
                            itemCount: 0,
                            pageCount: 0
                        ),
                        trackerHostDataset: TorrentEngineIPCDatasetDescriptor(
                            id: datasetIDs[pollIndex].1,
                            kind: .trackerHosts,
                            revision: UInt64(pollIndex + 1),
                            itemCount: 0,
                            pageCount: 0
                        )
                    ),
                    for: request,
                    epoch: epoch
                )
            case .closeDataset:
                let close: TorrentEngineIPCCloseDatasetRequest = try decodeRequest(request)
                let wasOpen = budget.withLock { state in
                    state.openIDs.remove(close.id) != nil
                }
                #expect(wasOpen)
                return try successReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)
        let first = Task {
            try await client.poll(
                since: nil,
                sortedBy: .name,
                direction: .ascending,
                includeTrackerHosts: true
            )
        }
        await firstPollBlocker.waitUntilBlocked()
        let second = Task {
            try await client.poll(
                since: nil,
                sortedBy: .name,
                direction: .ascending,
                includeTrackerHosts: true
            )
        }
        let third = Task {
            try await client.poll(
                since: nil,
                sortedBy: .name,
                direction: .ascending,
                includeTrackerHosts: true
            )
        }

        await waitForPendingPolls(2, client: client)
        #expect(transport.operations == [.handshake, .poll])
        await firstPollBlocker.release()
        _ = try await (first.value, second.value, third.value)

        #expect(client.isAvailable)
        #expect(budget.withLock(\.openIDs).isEmpty)
        #expect(budget.withLock(\.maximumOpenCount) == 2)
        #expect(transport.operations == [
            .handshake,
            .poll, .closeDataset, .closeDataset,
            .poll, .closeDataset, .closeDataset,
            .poll, .closeDataset, .closeDataset,
        ])
    }

    @Test("Cancelling a queued poll releases its pipeline waiter")
    func cancelledQueuedPollReleasesPipelineWaiter() async throws {
        let epoch = epoch
        let firstPollBlocker = AsyncRequestBlocker()
        let pollCount = Mutex(0)
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
            case .poll:
                let index = pollCount.withLock { count in
                    defer { count += 1 }
                    return count
                }
                if index == 0 {
                    await firstPollBlocker.block()
                }
                return try successReply(
                    TorrentEngineIPCPollResponse(
                        dirtyMask: 0,
                        alertErrors: [],
                        networkStatus: .empty,
                        bridgeHealth: .healthy,
                        networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                            revision: UInt64(index + 1),
                            interfaces: []
                        ),
                        snapshotDataset: nil,
                        trackerHostDataset: nil
                    ),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)
        let first = Task {
            try await client.poll(
                since: nil,
                sortedBy: .name,
                direction: .ascending,
                includeTrackerHosts: false
            )
        }
        await firstPollBlocker.waitUntilBlocked()
        let cancelled = Task {
            try await client.poll(
                since: nil,
                sortedBy: .name,
                direction: .ascending,
                includeTrackerHosts: false
            )
        }
        await waitForPendingPolls(1, client: client)

        cancelled.cancel()
        await waitForPendingPolls(0, client: client)
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        await firstPollBlocker.release()
        _ = try await first.value
        _ = try await client.poll(
            since: nil,
            sortedBy: .name,
            direction: .ascending,
            includeTrackerHosts: false
        )

        #expect(client.isAvailable)
        #expect(transport.operations == [.handshake, .poll, .poll])
    }

    @Test("Fatal dataset replies terminate and wake queued polls")
    func fatalDatasetReplyTerminatesAndWakesQueuedPolls() async throws {
        let epoch = epoch
        let datasetID = UUID()
        let pageBlocker = AsyncRequestBlocker()
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
            case .poll:
                return try successReply(
                    TorrentEngineIPCPollResponse(
                        dirtyMask: 0,
                        alertErrors: [],
                        networkStatus: .empty,
                        bridgeHealth: .healthy,
                        networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                            revision: 1,
                            interfaces: []
                        ),
                        snapshotDataset: nil,
                        trackerHostDataset: TorrentEngineIPCDatasetDescriptor(
                            id: datasetID,
                            kind: .trackerHosts,
                            revision: 1,
                            itemCount: 1,
                            pageCount: 1
                        )
                    ),
                    for: request,
                    epoch: epoch
                )
            case .readDataset:
                await pageBlocker.block()
                return try successReply(
                    TorrentEngineIPCDatasetPage(
                        id: UUID(),
                        kind: .trackerHosts,
                        page: 0,
                        encodedItems: Data([0])
                    ),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)
        let active = Task {
            try await client.poll(
                since: nil,
                sortedBy: .name,
                direction: .ascending,
                includeTrackerHosts: true
            )
        }
        await pageBlocker.waitUntilBlocked()
        let queued = Task {
            try await client.poll(
                since: nil,
                sortedBy: .name,
                direction: .ascending,
                includeTrackerHosts: true
            )
        }
        await waitForPendingPolls(1, client: client)

        await pageBlocker.release()
        await #expect(throws: TorrentEngineClientError.self) {
            try await active.value
        }
        await #expect(throws: TorrentEngineClientError.self) {
            try await queued.value
        }

        #expect(!client.isAvailable)
        #expect(client.recoveryDisposition == .terminal)
        #expect(await client.pendingPollPipelineAcquisitionCount == 0)
        #expect(transport.operations == [.handshake, .poll, .readDataset])
    }

    @Test("Failed dataset cleanup replaces the controller")
    func failedDatasetCleanupReplacesController() async throws {
        let epoch = epoch
        let snapshotID = UUID()
        let trackerHostID = UUID()
        let closeAttempts = Mutex([UUID]())
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
            case .poll:
                return try successReply(
                    TorrentEngineIPCPollResponse(
                        dirtyMask: 0,
                        alertErrors: [],
                        networkStatus: .empty,
                        bridgeHealth: .healthy,
                        networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                            revision: 1,
                            interfaces: []
                        ),
                        snapshotDataset: TorrentEngineIPCDatasetDescriptor(
                            id: snapshotID,
                            kind: .torrentSnapshots,
                            revision: 1,
                            itemCount: 0,
                            pageCount: 0
                        ),
                        trackerHostDataset: TorrentEngineIPCDatasetDescriptor(
                            id: trackerHostID,
                            kind: .trackerHosts,
                            revision: 1,
                            itemCount: 0,
                            pageCount: 0
                        )
                    ),
                    for: request,
                    epoch: epoch
                )
            case .closeDataset:
                let close: TorrentEngineIPCCloseDatasetRequest = try decodeRequest(request)
                closeAttempts.withLock { $0.append(close.id) }
                if close.id == snapshotID {
                    throw TorrentEngineClientError.serviceTemporarilyUnavailable(
                        "Dataset cleanup interrupted for testing"
                    )
                }
                return try successReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        await #expect(throws: TorrentEngineClientError.self) {
            try await client.poll(
                since: nil,
                sortedBy: .name,
                direction: .ascending,
                includeTrackerHosts: true
            )
        }

        #expect(closeAttempts.withLock { $0 } == [
            snapshotID,
            snapshotID,
            trackerHostID,
        ])
        #expect(!client.isAvailable)
        #expect(client.recoveryDisposition == .replaceController)
        #expect(transport.isCancelled)
    }

    @Test("Cancellation closes every dataset returned by a poll")
    func cancelledPollClosesEveryOwnedDataset() async throws {
        let epoch = epoch
        let snapshotID = UUID()
        let trackerHostID = UUID()
        let capabilityID = UUID()
        let blocker = AsyncRequestBlocker()
        let closedIDs = Mutex([UUID]())
        let savePath = testPath("cancelled-dataset-poll")
        let torrent = makeDatasetTorrent(savePath: savePath)
        let transport = ScriptedTorrentEngineTransport { request in
            switch request.header.operation {
            case .handshake:
                return try successReply(
                    TorrentEngineIPCHandshakeResponse(
                        libtorrentVersion: "2.1.0",
                        folders: [TorrentEngineIPCGrantedFolder(
                            capabilityID: capabilityID,
                            resolvedPath: savePath
                        )]
                    ),
                    for: request,
                    epoch: epoch
                )
            case .poll:
                return try successReply(
                    TorrentEngineIPCPollResponse(
                        dirtyMask: 0,
                        alertErrors: [],
                        networkStatus: .empty,
                        bridgeHealth: .healthy,
                        networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                            revision: 1,
                            interfaces: []
                        ),
                        snapshotDataset: TorrentEngineIPCDatasetDescriptor(
                            id: snapshotID,
                            kind: .torrentSnapshots,
                            revision: 1,
                            itemCount: 1,
                            pageCount: 1
                        ),
                        trackerHostDataset: TorrentEngineIPCDatasetDescriptor(
                            id: trackerHostID,
                            kind: .trackerHosts,
                            revision: 1,
                            itemCount: 1,
                            pageCount: 1
                        )
                    ),
                    for: request,
                    epoch: epoch
                )
            case .readDataset:
                let read: TorrentEngineIPCReadDatasetRequest = try decodeRequest(request)
                #expect(read.id == snapshotID)
                #expect(read.page == 0)
                await blocker.block()
                return try successReply(
                    TorrentEngineIPCDatasetPage(
                        id: snapshotID,
                        kind: .torrentSnapshots,
                        page: 0,
                        encodedItems: try TorrentEngineIPCPropertyListCodec.encode(
                            [torrent],
                            maximumBytes: TorrentEngineIPCLimits.maximumDatasetPageBytes
                        )
                    ),
                    for: request,
                    epoch: epoch
                )
            case .closeDataset:
                let close: TorrentEngineIPCCloseDatasetRequest = try decodeRequest(request)
                closedIDs.withLock { $0.append(close.id) }
                return try successReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            case .reannounce:
                return try successReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(
            transport: transport,
            authorizations: [authorization(path: savePath, byte: 1)]
        )
        let poll = Task {
            try await client.poll(
                since: nil,
                sortedBy: .name,
                direction: .ascending,
                includeTrackerHosts: true
            )
        }
        await blocker.waitUntilBlocked()

        poll.cancel()
        await blocker.release()
        await #expect(throws: CancellationError.self) {
            try await poll.value
        }

        #expect(closedIDs.withLock { Set($0) } == [snapshotID, trackerHostID])
        #expect(client.isAvailable)
        try await client.reannounce(id: torrentID)
    }

    @Test("Dataset read failure closes every sibling dataset")
    func datasetReadFailureClosesEveryOwnedDataset() async throws {
        let epoch = epoch
        let snapshotID = UUID()
        let trackerHostID = UUID()
        let closedIDs = Mutex([UUID]())
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
            case .poll:
                return try successReply(
                    TorrentEngineIPCPollResponse(
                        dirtyMask: 0,
                        alertErrors: [],
                        networkStatus: .empty,
                        bridgeHealth: .healthy,
                        networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                            revision: 1,
                            interfaces: []
                        ),
                        snapshotDataset: TorrentEngineIPCDatasetDescriptor(
                            id: snapshotID,
                            kind: .torrentSnapshots,
                            revision: 1,
                            itemCount: 1,
                            pageCount: 1
                        ),
                        trackerHostDataset: TorrentEngineIPCDatasetDescriptor(
                            id: trackerHostID,
                            kind: .trackerHosts,
                            revision: 1,
                            itemCount: 1,
                            pageCount: 1
                        )
                    ),
                    for: request,
                    epoch: epoch
                )
            case .readDataset:
                throw TorrentEngineClientError.requestExpiredBeforeSubmission
            case .closeDataset:
                let close: TorrentEngineIPCCloseDatasetRequest = try decodeRequest(request)
                closedIDs.withLock { $0.append(close.id) }
                return try successReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            case .reannounce:
                return try successReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        await #expect(throws: TorrentEngineClientError.self) {
            try await client.poll(
                since: nil,
                sortedBy: .name,
                direction: .ascending,
                includeTrackerHosts: true
            )
        }

        #expect(closedIDs.withLock { Set($0) } == [snapshotID, trackerHostID])
        #expect(client.isAvailable)
        try await client.reannounce(id: torrentID)
    }

    @Test("Cancellation during paging closes the dataset without ending the controller")
    func cancelledPagedPollClosesDataset() async throws {
        let epoch = epoch
        let datasetID = UUID()
        let blocker = AsyncRequestBlocker()
        let host = TorrentTrackerHostItem(
            torrentID: torrentID,
            host: "tracker.example"
        )
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
            case .poll:
                return try successReply(
                    TorrentEngineIPCPollResponse(
                        dirtyMask: TorrentEngineDirtySet.trackerHosts.rawValue,
                        alertErrors: [],
                        networkStatus: .empty,
                        bridgeHealth: .healthy,
                        networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                            revision: 1,
                            interfaces: []
                        ),
                        snapshotDataset: nil,
                        trackerHostDataset: TorrentEngineIPCDatasetDescriptor(
                            id: datasetID,
                            kind: .trackerHosts,
                            revision: 1,
                            itemCount: 2,
                            pageCount: 2
                        )
                    ),
                    for: request,
                    epoch: epoch
                )
            case .readDataset:
                let read: TorrentEngineIPCReadDatasetRequest = try decodeRequest(request)
                #expect(read.page == 0)
                await blocker.block()
                return try successReply(
                    TorrentEngineIPCDatasetPage(
                        id: datasetID,
                        kind: .trackerHosts,
                        page: 0,
                        encodedItems: try TorrentEngineIPCPropertyListCodec.encode(
                            [host],
                            maximumBytes: TorrentEngineIPCLimits.maximumDatasetPageBytes
                        )
                    ),
                    for: request,
                    epoch: epoch
                )
            case .closeDataset, .reannounce:
                return try successReply(
                    TorrentEngineIPCEmpty(),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected(
                    "Unexpected operation"
                )
            }
        }
        let client = try await makeClient(transport: transport)
        let poll = Task {
            try await client.poll(
                since: nil,
                sortedBy: .name,
                direction: .ascending,
                includeTrackerHosts: true
            )
        }
        await blocker.waitUntilBlocked()

        poll.cancel()
        await blocker.release()
        await #expect(throws: CancellationError.self) {
            try await poll.value
        }

        #expect(transport.operations == [
            .handshake,
            .poll,
            .readDataset,
            .closeDataset,
        ])
        #expect(transport.sequences == [1, 2, 3, 4])
        #expect(client.isAvailable)
        #expect(!transport.isCancelled)
        try await client.reannounce(id: torrentID)
        #expect(transport.sequences == [1, 2, 3, 4, 5])
    }

    @Test("Recovery classification distinguishes lifecycle loss from trust failures")
    func recoveryClassification() {
        #expect(
            TorrentEngineClientError.connectionCancelled.recoveryDisposition
                == .replaceController
        )
        #expect(
            TorrentEngineClientError.connectionFailed.recoveryDisposition
                == .replaceController
        )
        #expect(
            TorrentEngineClientError.serviceTemporarilyUnavailable("shutdown")
                .recoveryDisposition == .replaceController
        )
        #expect(TorrentEngineClientError.invalidReply.recoveryDisposition == .terminal)
        #expect(TorrentEngineClientError.engineRestarted.recoveryDisposition == .terminal)
        #expect(
            TorrentEngineClientError.serviceRejected("authentication failed")
                .recoveryDisposition == .terminal
        )
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

    @Test("Typed service cleanup uses capped backoff under an absolute horizon")
    func serviceCleanupRetryBackoff() {
        var policy = TorrentEngineConnectionRetryPolicy()
        let delays = (0 ..< 12).compactMap { _ in
            policy.delay(
                after: .serviceTemporarilyUnavailable(
                    "Previous controller cleanup is still running."
                )
            )
        }

        #expect(TorrentEngineConnectionRetryPolicy.cleanupEpisodeRetryBudget == .seconds(305))
        #expect(delays.prefix(6) == [
            .milliseconds(250),
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(4),
            .seconds(5)
        ])
        #expect(delays.suffix(6).allSatisfy { $0 == .seconds(5) })
        #expect(delays.allSatisfy { $0 > .zero && $0 <= .seconds(5) })
    }

    @Test("Recovery sleeps are clipped to one absolute monotonic deadline")
    func recoverySleepIsClippedToAbsoluteDeadline() {
        let clock = ContinuousClock()
        let now = clock.now
        let deadline = now.advanced(by: .seconds(2))

        #expect(TorrentEngineConnectionRetryPolicy.retryWake(
            now: now,
            deadline: deadline,
            after: .seconds(5)
        ) == deadline)
        #expect(TorrentEngineConnectionRetryPolicy.retryWake(
            now: deadline,
            deadline: deadline,
            after: .milliseconds(1)
        ) == nil)
        #expect(TorrentEngineConnectionRetryPolicy.retryWake(
            now: now,
            deadline: nil,
            after: .milliseconds(50)
        ) == now.advanced(by: .milliseconds(50)))
    }

    @Test("Every IPC operation has a finite deadline and mutations report unknown outcomes")
    func operationDeadlineClassification() {
        for operation in TorrentEngineIPCOperation.allCases {
            #expect(operation.requestTimeout > .zero)
            #expect(operation.requestTimeout <= .seconds(120))
        }
        #expect(!TorrentEngineIPCOperation.poll.timeoutCanLeaveOutcomeUnknown)
        #expect(!TorrentEngineIPCOperation.requestSources.timeoutCanLeaveOutcomeUnknown)
        #expect(TorrentEngineIPCOperation.addMagnet.timeoutCanLeaveOutcomeUnknown)
        #expect(TorrentEngineIPCOperation.applySettings.timeoutCanLeaveOutcomeUnknown)
        #expect(TorrentEngineIPCOperation.remove.timeoutCanLeaveOutcomeUnknown)
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

    @Test("Replacement startup keeps generic failures in capped cleanup backoff")
    func replacementCleanupRetryBackoff() {
        var policy = TorrentEngineConnectionRetryPolicy(
            mode: .replacingTerminatedController
        )
        let delays = (0 ..< 12).compactMap { _ in
            policy.delay(after: .connectionFailed)
        }

        #expect(delays.count == 12)
        #expect(delays.allSatisfy { $0 > .zero && $0 <= .seconds(5) })
        #expect(policy.delay(after: .connectionCancelled) == .seconds(5))

        var rejectionPolicy = TorrentEngineConnectionRetryPolicy(
            mode: .replacingTerminatedController
        )
        #expect(rejectionPolicy.delay(after: .serviceRejected("invalid peer")) == nil)
        #expect(rejectionPolicy.delay(after: .invalidReply) == nil)
    }

    @Test("Interface snapshot revisions cannot move backward within one engine epoch")
    func interfaceSnapshotRevisionIsMonotonic() async throws {
        let epoch = epoch
        let pollCount = Mutex(0)
        let interface = NetworkInterfaceOption(
            name: "utun4",
            displayName: "VPN",
            fingerprint: "fingerprint",
            vpnServiceID: "vpn-service",
            vpnServiceName: "VPN",
            isLikelyVPN: true
        )
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
            case .poll:
                let revision = pollCount.withLock { count in
                    count += 1
                    return count == 1 ? UInt64(2) : UInt64(1)
                }
                return try successReply(
                    TorrentEngineIPCPollResponse(
                        dirtyMask: 0,
                        alertErrors: [],
                        networkStatus: .empty,
                        bridgeHealth: .healthy,
                        networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                            revision: revision,
                            interfaces: [interface]
                        ),
                        snapshotDataset: nil,
                        trackerHostDataset: nil
                    ),
                    for: request,
                    epoch: epoch
                )
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        let accepted = try await client.poll(
            since: nil,
            sortedBy: .name,
            direction: .ascending,
            includeTrackerHosts: false
        )
        #expect(accepted.networkInterfaceSnapshot?.revision == 2)

        await #expect(throws: TorrentEngineClientError.self) {
            try await client.poll(
                since: nil,
                sortedBy: .name,
                direction: .ascending,
                includeTrackerHosts: false
            )
        }
        #expect(!client.isAvailable)
        #expect(client.recoveryDisposition == .terminal)
        #expect(transport.isCancelled)
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

        await #expect(throws: CancellationError.self) {
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

    @Test("An in-flight request delivers its drained result after observer cancellation")
    func inFlightCancellationDeliversDrainedResult() async throws {
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
            case .requestSources:
                await blocker.block()
                return try successReply(TorrentEngineIPCEmpty(), for: request, epoch: epoch)
            case .reannounce:
                return try successReply(TorrentEngineIPCEmpty(), for: request, epoch: epoch)
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)
        let observingTask = Task {
            try await client.requestSources(id: torrentID)
        }
        await blocker.waitUntilBlocked()

        observingTask.cancel()
        try await Task.sleep(for: .milliseconds(25))
        #expect(transport.operations == [.handshake, .requestSources])
        #expect(client.isAvailable)
        #expect(!transport.isCancelled)

        await blocker.release()
        try await observingTask.value
        try await client.reannounce(id: torrentID)

        #expect(client.isAvailable)
        #expect(!transport.isCancelled)
        #expect(transport.operations == [.handshake, .requestSources, .reannounce])
        #expect(transport.sequences == [1, 2, 3])
    }

    @Test("An in-flight request delivers its drained rejection after observer cancellation")
    func inFlightCancellationDeliversDrainedRejection() async throws {
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
            case .requestSources:
                await blocker.block()
                throw TorrentEngineClientError.serviceRejected("Known rejection")
            case .reannounce:
                return try successReply(TorrentEngineIPCEmpty(), for: request, epoch: epoch)
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)
        let observingTask = Task {
            try await client.requestSources(id: torrentID)
        }
        await blocker.waitUntilBlocked()

        observingTask.cancel()
        await blocker.release()
        do {
            try await observingTask.value
            Issue.record("Expected the drained service rejection")
        } catch let error as TorrentEngineClientError {
            guard case .serviceRejected(let message) = error else {
                Issue.record("Expected a known service rejection, got \(error)")
                return
            }
            #expect(message == "Known rejection")
        } catch {
            Issue.record("Expected a known service rejection, got \(error)")
        }

        try await client.reannounce(id: torrentID)
        #expect(client.isAvailable)
        #expect(!transport.isCancelled)
        #expect(transport.operations == [.handshake, .requestSources, .reannounce])
        #expect(transport.sequences == [1, 2, 3])
    }

    @Test("An urgent network block reports that its preempted controller must be replaced")
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

        let disposition = try await client.blockNetworkNow()

        #expect(disposition == .engineReplacementRequired)
        #expect(!client.isAvailable)
        #expect(client.recoveryDisposition == .replaceController)
        #expect(transport.isCancelled)
        #expect(transport.operations == [.handshake, .pause])
        await #expect(throws: TorrentEngineClientError.self) {
            try await client.reannounce(id: "alpha")
        }
        await blocker.release()
        _ = try? await inFlight.value
    }

    @Test("A failed ordered network block closes and replaces the controller")
    func failedNetworkBlockRequiresControllerReplacement() async throws {
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
            case .blockNetwork:
                throw TorrentEngineClientError.serviceRejected("Rejected for testing")
            default:
                throw TorrentEngineClientError.serviceRejected("Unexpected operation")
            }
        }
        let client = try await makeClient(transport: transport)

        let disposition = try await client.blockNetworkNow()

        #expect(disposition == .engineReplacementRequired)
        #expect(!client.isAvailable)
        #expect(client.recoveryDisposition == .terminal)
        #expect(transport.isCancelled)
        #expect(transport.operations == [.handshake, .blockNetwork])
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

    private func waitForPendingPolls(
        _ expectedCount: Int,
        client: TorrentXPCClient
    ) async {
        for _ in 0..<1_000 {
            if await client.pendingPollPipelineAcquisitionCount == expectedCount {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for queued poll-pipeline acquisitions")
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

    private func makeDatasetTorrent(savePath: String) -> TorrentItem {
        TorrentItem(
            id: torrentID,
            infoHash: "v1:\(String(repeating: "b", count: 40))",
            name: "Dataset Torrent",
            savePath: savePath,
            error: "",
            comment: "",
            progress: 0,
            totalDone: 0,
            totalWanted: 100,
            totalSize: 100,
            totalUpload: 0,
            totalDownload: 0,
            totalPayloadUpload: 0,
            totalPayloadDownload: 0,
            allTimeUpload: 0,
            allTimeDownload: 0,
            addedTime: 0,
            createdTime: 0,
            completedTime: 0,
            downloadRate: 0,
            uploadRate: 0,
            downloadPayloadRate: 0,
            uploadPayloadRate: 0,
            peers: 0,
            knownPeers: 0,
            seeds: 0,
            state: .unknown,
            queuePosition: -1,
            queuePriority: .normal,
            paused: false,
            autoManaged: false,
            seeding: false,
            finished: false,
            contentKind: .singleFile,
            hasMetadata: true,
            privateTorrent: false
        )
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

    func send(
        _ request: TorrentEngineIPCRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> TorrentEngineIPCReply {
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
