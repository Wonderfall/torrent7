import Foundation
import Testing
import TorrentEngineModel
import XPC
@testable import TorrentEngineIPC

private let testJSONLimits = TorrentEngineIPCLimits.maximumJSONLimits

@Suite("Torrent engine IPC envelopes")
struct TorrentEngineIPCEnvelopeTests {
    @Test("Request and reply envelopes round trip")
    func envelopeRoundTrips() throws {
        let header = makeHeader()
        let request = TorrentEngineIPCRequest(
            header: header,
            payload: Data([0, 1, 2, 255]),
            attachment: Data([9, 8, 7])
        )
        let requestDictionary = try TorrentEngineIPCEnvelopeCodec.encode(
            request,
            maximumPayloadBytes: 64,
            maximumAttachmentBytes: 64
        )
        let decodedRequest = try TorrentEngineIPCEnvelopeCodec.decodeRequest(
            requestDictionary,
            maximumPayloadBytes: 64,
            maximumAttachmentBytes: 64
        )
        #expect(decodedRequest == request)

        let reply = TorrentEngineIPCReply(
            header: header,
            engineEpoch: UUID(),
            status: .failure,
            failureCode: .controllerBusy,
            errorMessage: "The operation failed safely.",
            payload: Data([3, 4, 5])
        )
        let replyDictionary = try TorrentEngineIPCEnvelopeCodec.encode(
            reply,
            maximumPayloadBytes: 64
        )
        let decodedReply = try TorrentEngineIPCEnvelopeCodec.decodeReply(
            replyDictionary,
            maximumPayloadBytes: 64
        )
        #expect(decodedReply == reply)
    }

    @Test("Payload storage is copied")
    func payloadIsCopied() throws {
        var source = Data([1, 2, 3])
        var attachment = Data([4, 5])
        let request = TorrentEngineIPCRequest(
            header: makeHeader(),
            payload: source,
            attachment: attachment
        )
        let dictionary = try TorrentEngineIPCEnvelopeCodec.encode(
            request,
            maximumPayloadBytes: 3,
            maximumAttachmentBytes: 2
        )
        source[0] = 9
        attachment[0] = 9

        let decoded = try TorrentEngineIPCEnvelopeCodec.decodeRequest(
            dictionary,
            maximumPayloadBytes: 3,
            maximumAttachmentBytes: 2
        )
        #expect(decoded.payload == Data([1, 2, 3]))
        #expect(decoded.attachment == Data([4, 5]))
    }

    @Test("Request inspection reports resource cost before decoding")
    func requestInspection() throws {
        let request = TorrentEngineIPCRequest(
            header: makeHeader(),
            payload: Data([1, 2, 3, 4]),
            attachment: Data([5, 6])
        )
        let dictionary = try TorrentEngineIPCEnvelopeCodec.encode(
            request,
            maximumPayloadBytes: 4,
            maximumAttachmentBytes: 2
        )

        let metadata = try TorrentEngineIPCEnvelopeCodec.inspectRequest(dictionary)
        #expect(metadata.header == request.header)
        #expect(metadata.hasPayload)
        #expect(metadata.payloadByteCount == 4)
        #expect(metadata.hasAttachment)
        #expect(metadata.attachmentByteCount == 2)
        #expect(metadata.totalByteCount == 6)
        #expect(try TorrentEngineIPCEnvelopeCodec.decodeRequest(
            dictionary,
            metadata: metadata,
            maximumPayloadBytes: 4,
            maximumAttachmentBytes: 2
        ) == request)
    }

    @Test("Inspected metadata must still match at resource acquisition")
    func inspectedMetadataMustMatch() throws {
        let request = TorrentEngineIPCRequest(
            header: makeHeader(),
            payload: Data([1, 2, 3, 4])
        )
        let dictionary = try TorrentEngineIPCEnvelopeCodec.encode(
            request,
            maximumPayloadBytes: 4
        )
        let metadata = TorrentEngineIPCRequestMetadata(
            header: request.header,
            hasPayload: true,
            payloadByteCount: 3,
            hasAttachment: false,
            attachmentByteCount: 0,
            totalByteCount: 3
        )

        expectIPCError(.requestMetadataMismatch) {
            try TorrentEngineIPCEnvelopeCodec.decodeRequest(
                dictionary,
                metadata: metadata,
                maximumPayloadBytes: 4
            )
        }
    }

    @Test("Unknown fields are rejected")
    func unknownFieldIsRejected() throws {
        var dictionary = try encodedRequest()
        dictionary["ambientAuthority"] = true

        expectIPCError(.unexpectedField("ambientAuthority")) {
            try TorrentEngineIPCEnvelopeCodec.decodeRequest(
                dictionary,
                maximumPayloadBytes: 64
            )
        }
    }

    @Test("Missing fields are rejected")
    func missingFieldIsRejected() throws {
        let dictionary = try encodedRequest()
        dictionary.removeValue(forKey: TorrentEngineIPCField.controllerID)

        expectIPCError(.missingField(TorrentEngineIPCField.controllerID)) {
            try TorrentEngineIPCEnvelopeCodec.decodeRequest(
                dictionary,
                maximumPayloadBytes: 64
            )
        }
    }

    @Test("Wrong XPC field types are rejected without integer coercion")
    func wrongFieldTypesAreRejected() throws {
        var stringVersion = try encodedRequest()
        stringVersion[TorrentEngineIPCField.version] = "1"
        expectIPCError(
            .wrongFieldType(field: TorrentEngineIPCField.version, expected: "uint64")
        ) {
            try TorrentEngineIPCEnvelopeCodec.decodeRequest(
                stringVersion,
                maximumPayloadBytes: 64
            )
        }

        var signedVersion = try encodedRequest()
        signedVersion[TorrentEngineIPCField.version] = Int64(1)
        expectIPCError(
            .wrongFieldType(field: TorrentEngineIPCField.version, expected: "uint64")
        ) {
            try TorrentEngineIPCEnvelopeCodec.decodeRequest(
                signedVersion,
                maximumPayloadBytes: 64
            )
        }
    }

    @Test("Protocol version and unknown operation values fail closed")
    func versionAndOperationAreExact() throws {
        var futureVersion = try encodedRequest()
        futureVersion[TorrentEngineIPCField.version] = TorrentEngineIPCProtocol.version + 1
        expectIPCError(.unsupportedProtocolVersion(TorrentEngineIPCProtocol.version + 1)) {
            try TorrentEngineIPCEnvelopeCodec.decodeRequest(
                futureVersion,
                maximumPayloadBytes: 64
            )
        }

        var unknownOperation = try encodedRequest()
        unknownOperation[TorrentEngineIPCField.operation] = UInt64.max
        expectIPCError(.unknownOperation(UInt64.max)) {
            try TorrentEngineIPCEnvelopeCodec.decodeRequest(
                unknownOperation,
                maximumPayloadBytes: 64
            )
        }
    }

    @Test("UUID fields require canonical UUID text")
    func UUIDValidation() throws {
        for invalidValue in [
            "not-a-uuid",
            "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}",
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEZ",
        ] {
            var dictionary = try encodedRequest()
            dictionary[TorrentEngineIPCField.requestID] = invalidValue
            expectIPCError(.invalidUUID(field: TorrentEngineIPCField.requestID)) {
                try TorrentEngineIPCEnvelopeCodec.decodeRequest(
                    dictionary,
                    maximumPayloadBytes: 64
                )
            }
        }
    }

    @Test("Payload bounds are enforced on encode and decode")
    func payloadBounds() throws {
        let request = TorrentEngineIPCRequest(
            header: makeHeader(),
            payload: Data(repeating: 7, count: 5)
        )
        expectIPCError(.payloadTooLarge(actual: 5, maximum: 4)) {
            try TorrentEngineIPCEnvelopeCodec.encode(
                request,
                maximumPayloadBytes: 4
            )
        }

        let dictionary = try TorrentEngineIPCEnvelopeCodec.encode(
            request,
            maximumPayloadBytes: 5
        )
        expectIPCError(.payloadTooLarge(actual: 5, maximum: 4)) {
            try TorrentEngineIPCEnvelopeCodec.decodeRequest(
                dictionary,
                maximumPayloadBytes: 4
            )
        }

        expectIPCError(.invalidMaximumPayloadSize(-1)) {
            try TorrentEngineIPCEnvelopeCodec.decodeRequest(
                dictionary,
                maximumPayloadBytes: -1
            )
        }
    }

    @Test("Raw attachments have independent bounds")
    func attachmentBounds() throws {
        let request = TorrentEngineIPCRequest(
            header: makeHeader(),
            attachment: Data(repeating: 7, count: 5)
        )
        expectIPCError(.payloadTooLarge(actual: 5, maximum: 4)) {
            try TorrentEngineIPCEnvelopeCodec.encode(
                request,
                maximumPayloadBytes: 0,
                maximumAttachmentBytes: 4
            )
        }

        let dictionary = try TorrentEngineIPCEnvelopeCodec.encode(
            request,
            maximumPayloadBytes: 0,
            maximumAttachmentBytes: 5
        )
        expectIPCError(.payloadTooLarge(actual: 5, maximum: 4)) {
            try TorrentEngineIPCEnvelopeCodec.decodeRequest(
                dictionary,
                maximumPayloadBytes: 0,
                maximumAttachmentBytes: 4
            )
        }
        expectIPCError(.unexpectedField(TorrentEngineIPCField.attachment)) {
            try TorrentEngineIPCEnvelopeCodec.encode(
                TorrentEngineIPCRequest(
                    header: makeHeader(),
                    attachment: Data()
                ),
                maximumPayloadBytes: 0
            )
        }
    }

    @Test("Replies cannot carry raw attachments")
    func replyAttachmentsAreRejected() throws {
        let reply = TorrentEngineIPCReply(
            header: makeHeader(),
            engineEpoch: UUID(),
            status: .success
        )
        var dictionary = try TorrentEngineIPCEnvelopeCodec.encode(
            reply,
            maximumPayloadBytes: 0
        )
        try TorrentEngineIPCXPCValues.insertPayload(
            Data([1]),
            into: &dictionary,
            maximumBytes: 1,
            field: TorrentEngineIPCField.attachment
        )

        expectIPCError(.unexpectedField(TorrentEngineIPCField.attachment)) {
            try TorrentEngineIPCEnvelopeCodec.decodeReply(
                dictionary,
                maximumPayloadBytes: 0
            )
        }
    }

    @Test("Failure errors are bounded UTF-8 and status-consistent")
    func errorBoundsAndStatus() throws {
        let oversized = String(
            repeating: "é",
            count: TorrentEngineIPCLimits.maximumErrorBytes / 2 + 1
        )
        let oversizedBytes = oversized.utf8.count
        let oversizedReply = TorrentEngineIPCReply(
            header: makeHeader(),
            engineEpoch: UUID(),
            status: .failure,
            errorMessage: oversized
        )
        expectIPCError(
            .errorMessageTooLarge(
                actual: oversizedBytes,
                maximum: TorrentEngineIPCLimits.maximumErrorBytes
            )
        ) {
            try TorrentEngineIPCEnvelopeCodec.encode(
                oversizedReply,
                maximumPayloadBytes: 64
            )
        }

        let embeddedNull = TorrentEngineIPCReply(
            header: makeHeader(),
            engineEpoch: UUID(),
            status: .failure,
            errorMessage: "prefix\0suffix"
        )
        expectIPCError(.errorMessageContainsNull) {
            try TorrentEngineIPCEnvelopeCodec.encode(
                embeddedNull,
                maximumPayloadBytes: 64
            )
        }

        let successWithError = TorrentEngineIPCReply(
            header: makeHeader(),
            engineEpoch: UUID(),
            status: .success,
            errorMessage: "unexpected"
        )
        expectIPCError(.unexpectedErrorMessage) {
            try TorrentEngineIPCEnvelopeCodec.encode(
                successWithError,
                maximumPayloadBytes: 64
            )
        }

        let failureWithoutError = TorrentEngineIPCReply(
            header: makeHeader(),
            engineEpoch: UUID(),
            status: .failure
        )
        expectIPCError(.missingErrorMessage) {
            try TorrentEngineIPCEnvelopeCodec.encode(
                failureWithoutError,
                maximumPayloadBytes: 64
            )
        }
    }

    @Test("Stable dataset and hint operation numbers")
    func stableOperationNumbers() {
        #expect(TorrentEngineIPCProtocol.version == 9)
        #expect(TorrentEngineIPCOperation.replaceFolderCapabilities.rawValue == 7)
        #expect(TorrentEngineIPCOperation(rawValue: 10) == nil)
        #expect(TorrentEngineIPCOperation(rawValue: 41) == nil)
        #expect(TorrentEngineIPCOperation(rawValue: 50) == nil)
        #expect(TorrentEngineIPCOperation.readDataset.rawValue == 51)
        #expect(TorrentEngineIPCOperation.closeDataset.rawValue == 52)
        #expect(TorrentEngineIPCOperation(rawValue: 60) == nil)
        #expect(TorrentEngineIPCOperation(rawValue: 63) == nil)
        #expect(TorrentEngineIPCOperation.changeHint.rawValue == 100)
        #expect(TorrentEngineIPCFailureCode.operationRejected.rawValue == 1)
        #expect(TorrentEngineIPCFailureCode.controllerBusy.rawValue == 2)
        #expect(TorrentEngineIPCFailureCode.serviceShuttingDown.rawValue == 3)
    }

    @Test("JSON and raw attachment limits remain independently bounded")
    func JSONAndAttachmentLimits() {
        #expect(TorrentEngineIPCOperation.previewTorrentFile.maximumRequestPayloadBytes == 0)
        #expect(
            TorrentEngineIPCOperation.previewTorrentFile.maximumRequestAttachmentBytes
                == TorrentInputLimits.maxTorrentFileBytes
        )
        #expect(
            TorrentEngineIPCOperation.addTorrentFile.maximumRequestPayloadBytes
                + TorrentEngineIPCOperation.addTorrentFile.maximumRequestAttachmentBytes
                <= TorrentEngineIPCLimits.maximumPayloadBytes
        )
        #expect(
            TorrentEngineIPCOperation.handshake.maximumRequestPayloadBytes
                >= ((TorrentEngineIPCLimits.maximumBookmarkAggregateBytes + 2) / 3) * 4
        )
        #expect(
            TorrentEngineIPCOperation.readDataset.maximumReplyPayloadBytes
                >= ((TorrentEngineIPCLimits.maximumDatasetPageBytes + 2) / 3) * 4
        )
    }

    @Test("Maximum file-priority metadata fits its JSON allocation profile")
    func maximumFilePriorityMetadataFits() throws {
        let request = TorrentEngineIPCAddTorrentFileRequest(
            folderCapabilityID: UUID(),
            filePriorities: (0..<TorrentEngineLimits.maximumFileCount).map {
                TorrentEngineIPCFilePriorityEntry(index: Int32($0), priority: .normal)
            },
            startsPaused: false,
            queuePriority: .normal,
            enablePeerExchange: false,
            httpsTrackerPolicy: .inherit,
            httpsWebSeedPolicy: .inherit
        )

        _ = try TorrentEngineIPCJSONCodec.encode(
            request,
            maximumBytes:
                TorrentEngineIPCOperation.addTorrentFile.maximumRequestPayloadBytes,
            limits: TorrentEngineIPCOperation.addTorrentFile.requestJSONLimits
        )
    }

    @Test("Maximum escaped file reply fits its recalibrated JSON limits")
    func maximumFileReplyFits() throws {
        let maximumEscapedPath = String(repeating: "\\\"", count: 511) + "\\"
        let batch = TorrentFileBatch(
            revision: .max,
            files: (0..<TorrentEngineLimits.maximumFileCount).map {
                TorrentFileItem(
                    path: maximumEscapedPath,
                    size: .max,
                    downloaded: .max,
                    progress: 1,
                    index: Int32($0),
                    priority: .high,
                    isPadFile: false
                )
            }
        )

        let encoded = try TorrentEngineIPCJSONCodec.encode(
            batch,
            maximumBytes: TorrentEngineIPCOperation.fileBatch.maximumReplyPayloadBytes,
            limits: TorrentEngineIPCOperation.fileBatch.replyJSONLimits
        )
        #expect(encoded.count > 32 * 1_024 * 1_024)
        #expect(encoded.count <= TorrentEngineIPCLimits.maximumFileMetadataReplyBytes)
    }

    @Test("Maximum aggregate bookmarks fit without slash expansion")
    func maximumAggregateBookmarksFit() throws {
        let bookmarkByteCount =
            TorrentEngineIPCLimits.maximumBookmarkAggregateBytes
                / TorrentEngineLimits.maximumAuthorizedSavePathCount
        let bookmark = Data(repeating: 0xFF, count: bookmarkByteCount)
        let request = TorrentEngineIPCHandshakeRequest(
            enablePeerExchangePlugin: true,
            folders: Array(
                repeating: TorrentEngineIPCFolderGrant(bookmark: bookmark),
                count: TorrentEngineLimits.maximumAuthorizedSavePathCount
            )
        )

        let encoded = try TorrentEngineIPCJSONCodec.encode(
            request,
            maximumBytes: TorrentEngineIPCOperation.handshake.maximumRequestPayloadBytes,
            limits: TorrentEngineIPCOperation.handshake.requestJSONLimits
        )

        #expect(!String(decoding: encoded, as: UTF8.self).contains(#"\/"#))
        #expect(encoded.count <= TorrentEngineIPCOperation.handshake.maximumRequestPayloadBytes)
    }

    @Test("Maximum encoded dataset page fits its outer JSON envelope")
    func maximumDatasetPageEnvelopeFits() throws {
        let page = TorrentEngineIPCDatasetPage(
            id: UUID(),
            kind: .torrentSnapshots,
            page: TorrentEngineIPCLimits.maximumDatasetPageCount - 1,
            encodedItems: Data(
                repeating: 0xFF,
                count: TorrentEngineIPCLimits.maximumDatasetPageBytes
            )
        )

        let encoded = try TorrentEngineIPCJSONCodec.encode(
            page,
            maximumBytes: TorrentEngineIPCOperation.readDataset.maximumReplyPayloadBytes,
            limits: TorrentEngineIPCOperation.readDataset.replyJSONLimits
        )

        #expect(encoded.count <= TorrentEngineIPCOperation.readDataset.maximumReplyPayloadBytes)
    }

    @Test("Maximum tracker and web-seed replies fit their JSON-specific limits")
    func maximumSourceRepliesFit() throws {
        let escapedURL = String(repeating: #"\"#, count: 1_023)
        let escapedMessage = String(repeating: #"\"#, count: 511)

        do {
            let response = TorrentEngineIPCOptionalValue(
                TorrentTrackerBatch(
                    revision: .max,
                    trackers: Array(
                        repeating: TorrentTrackerItem(
                            url: escapedURL,
                            message: escapedMessage,
                            tier: Int32.max - 1,
                            failCount: .max,
                            scrapeSeeders: .max,
                            scrapeLeechers: .max,
                            scrapeDownloaded: .max,
                            updating: true,
                            verified: true,
                            hasError: true,
                            enabled: true
                        ),
                        count: TorrentEngineLimits.maximumTrackerCount
                    )
                )
            )
            _ = try TorrentEngineIPCJSONCodec.encode(
                response,
                maximumBytes:
                    TorrentEngineIPCOperation.trackerBatch.maximumReplyPayloadBytes,
                limits: TorrentEngineIPCOperation.trackerBatch.replyJSONLimits
            )
        }

        do {
            let response = TorrentEngineIPCOptionalValue(
                TorrentWebSeedBatch(
                    revision: .max,
                    webSeeds: Array(
                        repeating: TorrentWebSeedItem(url: escapedURL),
                        count: TorrentEngineLimits.maximumWebSeedCount
                    )
                )
            )
            _ = try TorrentEngineIPCJSONCodec.encode(
                response,
                maximumBytes:
                    TorrentEngineIPCOperation.webSeedBatch.maximumReplyPayloadBytes,
                limits: TorrentEngineIPCOperation.webSeedBatch.replyJSONLimits
            )
        }
    }

    @Test("Maximum piece map uses one bounded bit-packed JSON string")
    func maximumPieceMapIsBitPacked() throws {
        let pieceCount = TorrentEngineLimits.maximumPieceMapCount
        let pieces = (0..<pieceCount).map { UInt8($0 & 1) }
        let response = TorrentEngineIPCOptionalValue(
            TorrentPieceMapBatch(
                revision: .max,
                pieceMap: TorrentPieceMap(
                    totalPieces: pieceCount,
                    completedPieces: pieceCount / 2,
                    availablePieces: pieceCount,
                    isMapAvailable: true,
                    isMapTruncated: false,
                    pieces: pieces
                )
            )
        )

        let encoded = try TorrentEngineIPCJSONCodec.encode(
            response,
            maximumBytes: TorrentEngineIPCOperation.pieceMapBatch.maximumReplyPayloadBytes,
            limits: TorrentEngineIPCOperation.pieceMapBatch.replyJSONLimits
        )
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains(#""pieces":""#))
        #expect(!text.contains(#""pieces":["#))
        #expect(encoded.count < 512 * 1_024)

        let decoded = try TorrentEngineIPCJSONCodec.decode(
            TorrentEngineIPCOptionalValue<TorrentPieceMapBatch>.self,
            from: encoded,
            maximumBytes: TorrentEngineIPCOperation.pieceMapBatch.maximumReplyPayloadBytes,
            limits: TorrentEngineIPCOperation.pieceMapBatch.replyJSONLimits
        )
        #expect(decoded.value?.pieceMap == response.value?.pieceMap)
    }

    @Test("XPC bundle identities require an exact packaged pair")
    func exactBundleIdentities() {
        #expect(
            TorrentEngineIPCIdentity.pair(appIdentifier: "app.torrent7")
                == .init(
                    appIdentifier: "app.torrent7",
                    serviceIdentifier: "app.torrent7.engine"
                )
        )
        #expect(
            TorrentEngineIPCIdentity.pair(serviceIdentifier: "app.torrent7.asan.engine")
                == .init(
                    appIdentifier: "app.torrent7.asan",
                    serviceIdentifier: "app.torrent7.asan.engine"
                )
        )
        #expect(
            TorrentEngineIPCIdentity.pair(appIdentifier: "app.torrent7.tsan")
                == .init(
                    appIdentifier: "app.torrent7.tsan",
                    serviceIdentifier: "app.torrent7.tsan.engine"
                )
        )
        #expect(
            TorrentEngineIPCIdentity.pair(appIdentifier: "app.torrent7.integration")
                == .init(
                    appIdentifier: "app.torrent7.integration",
                    serviceIdentifier: "app.torrent7.integration.engine"
                )
        )
        #expect(
            TorrentEngineIPCIdentity.pair(
                serviceIdentifier: "app.torrent7.integration.asan.engine"
            ) == .init(
                appIdentifier: "app.torrent7.integration.asan",
                serviceIdentifier: "app.torrent7.integration.asan.engine"
            )
        )
        #expect(
            TorrentEngineIPCIdentity.pair(appIdentifier: "app.torrent7.integration.tsan")
                == .init(
                    appIdentifier: "app.torrent7.integration.tsan",
                    serviceIdentifier: "app.torrent7.integration.tsan.engine"
                )
        )
        #expect(TorrentEngineIPCIdentity.pair(appIdentifier: nil) == nil)
        #expect(TorrentEngineIPCIdentity.pair(appIdentifier: "app.torrent7.beta") == nil)
        #expect(TorrentEngineIPCIdentity.pair(serviceIdentifier: nil) == nil)
        #expect(TorrentEngineIPCIdentity.pair(serviceIdentifier: "app.torrent7.helper") == nil)
        #expect(
            TorrentEngineIPCIdentity.authentication(
                allowsReducedAssurance: false
            ) == .sameTeam
        )
        #expect(
            TorrentEngineIPCIdentity.authentication(
                allowsReducedAssurance: true
            ) == .reducedAssuranceAdHocDevelopment
        )
        #expect(
            TorrentEngineIPCIdentity.release.extensionPointIdentifier
                == "app.torrent7.torrent-engine"
        )
        #expect(
            TorrentEngineIPCIdentity.addressDiagnostics.extensionPointIdentifier
                == "app.torrent7.asan.torrent-engine"
        )
        #expect(
            TorrentEngineIPCIdentity.threadDiagnostics.extensionPointIdentifier
                == "app.torrent7.tsan.torrent-engine"
        )
        #expect(
            TorrentEngineIPCIdentity.integration.extensionPointIdentifier
                == "app.torrent7.integration.torrent-engine"
        )
        #expect(
            TorrentEngineIPCIdentity.addressIntegration.extensionPointIdentifier
                == "app.torrent7.integration.asan.torrent-engine"
        )
        #expect(
            TorrentEngineIPCIdentity.threadIntegration.extensionPointIdentifier
                == "app.torrent7.integration.tsan.torrent-engine"
        )
    }

    private func encodedRequest() throws -> XPCDictionary {
        try TorrentEngineIPCEnvelopeCodec.encode(
            TorrentEngineIPCRequest(header: makeHeader()),
            maximumPayloadBytes: 64
        )
    }
}

@Suite("Torrent engine IPC JSON payloads")
struct TorrentEngineIPCJSONTests {
    private struct ExamplePayload: Codable, Equatable, Sendable {
        let name: String
        let values: [Int]
    }

    private struct BinaryPayload: Codable, Equatable, Sendable {
        let bytes: Data
    }

    private struct RevisionPayload: Codable, Equatable, Sendable {
        let revision: UInt64
    }

    private indirect enum RandomJSONValue: Codable, Equatable, Sendable {
        case string(String)
        case integer(Int)
        case boolean(Bool)
        case array([RandomJSONValue])
        case object([String: RandomJSONValue])
    }

    private struct DeterministicGenerator {
        private var state: UInt64 = 0x7A11_C0DE_8259

        mutating func value(depth: Int = 0) -> RandomJSONValue {
            let kind = depth >= 4 ? Int(next() % 3) : Int(next() % 5)
            switch kind {
            case 0:
                return .string(string(maximumFragmentCount: 24))
            case 1:
                return .integer(Int(truncatingIfNeeded: next()))
            case 2:
                return .boolean(next() & 1 == 0)
            case 3:
                var values = [RandomJSONValue]()
                for _ in 0..<Int(next() % 5) {
                    values.append(value(depth: depth + 1))
                }
                return .array(values)
            default:
                var values = [String: RandomJSONValue]()
                for index in 0..<Int(next() % 5) {
                    values["key-\(index)-\(string(maximumFragmentCount: 4))"] =
                        value(depth: depth + 1)
                }
                return .object(values)
            }
        }

        private mutating func string(maximumFragmentCount: Int) -> String {
            let fragments = [
                "a", "\"", "\\", "/", "[", "]", "{", "}", "\n", "\t",
                "\u{1}", "日本語", "🧲",
            ]
            var result = ""
            for _ in 0..<Int(next() % UInt64(maximumFragmentCount + 1)) {
                result += fragments[Int(next() % UInt64(fragments.count))]
            }
            return result
        }

        private mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return state
        }
    }

    private struct RejectIfDecoded: Decodable, Sendable {
        private struct UnexpectedDecode: Error {}

        init(from decoder: Decoder) throws {
            _ = decoder
            Issue.record("JSONDecoder ran before the preflight rejected the payload")
            throw UnexpectedDecode()
        }
    }

    @Test("JSON payloads round trip")
    func JSONRoundTrip() throws {
        let value = ExamplePayload(name: "snapshot – 日本語 🧲", values: [1, 2, 3])
        let data = try TorrentEngineIPCJSONCodec.encode(
            value,
            maximumBytes: 4_096,
            limits: testJSONLimits
        )
        #expect(data.first == UInt8(ascii: "{"))

        let decoded = try TorrentEngineIPCJSONCodec.decode(
            ExamplePayload.self,
            from: data,
            maximumBytes: 4_096,
            limits: testJSONLimits
        )
        #expect(decoded == value)
    }

    @Test("JSON preserves the full unsigned revision range")
    func UInt64RoundTrip() throws {
        let value = RevisionPayload(revision: .max)
        let data = try TorrentEngineIPCJSONCodec.encode(
            value,
            maximumBytes: 4_096,
            limits: testJSONLimits
        )

        #expect(try TorrentEngineIPCJSONCodec.decode(
            RevisionPayload.self,
            from: data,
            maximumBytes: 4_096,
            limits: testJSONLimits
        ) == value)
    }

    @Test("Add responses use a JSON container instead of a scalar root")
    func addedTorrentResponseRoundTrip() throws {
        let value = TorrentEngineIPCAddedTorrentResponse(
            identifier: "t:\(String(repeating: "a", count: 32))"
        )
        let data = try TorrentEngineIPCJSONCodec.encode(
            value,
            maximumBytes: 4_096,
            limits: testJSONLimits
        )

        let decoded = try TorrentEngineIPCJSONCodec.decode(
            TorrentEngineIPCAddedTorrentResponse.self,
            from: data,
            maximumBytes: 4_096,
            limits: testJSONLimits
        )
        #expect(decoded == value)
    }

    @Test("Removal responses keep both outcomes inside a JSON container")
    func removalResponseRoundTrips() throws {
        for outcome in [
            TorrentRemovalOutcome.removed,
            TorrentRemovalOutcome.removedWithWarning("Files were retained safely."),
        ] {
            let value = TorrentEngineIPCRemovalResponse(outcome: outcome)
            let data = try TorrentEngineIPCJSONCodec.encode(
                value,
                maximumBytes: 4_096,
                limits: testJSONLimits
            )
            let decoded = try TorrentEngineIPCJSONCodec.decode(
                TorrentEngineIPCRemovalResponse.self,
                from: data,
                maximumBytes: 4_096,
                limits: testJSONLimits
            )
            #expect(decoded == value)
        }
    }

    @Test("Poll responses carry the required bounded interface snapshot")
    func pollResponseRoundTrip() throws {
        let response = pollResponse(interfaceCount: 1)
        let data = try TorrentEngineIPCJSONCodec.encode(
            response,
            maximumBytes: TorrentEngineIPCOperation.poll.maximumReplyPayloadBytes,
            limits: TorrentEngineIPCOperation.poll.replyJSONLimits
        )
        let decoded = try TorrentEngineIPCJSONCodec.decode(
            TorrentEngineIPCPollResponse.self,
            from: data,
            maximumBytes: TorrentEngineIPCOperation.poll.maximumReplyPayloadBytes,
            limits: TorrentEngineIPCOperation.poll.replyJSONLimits
        )

        #expect(decoded.networkInterfaceSnapshot == response.networkInterfaceSnapshot)
    }

    @Test("Maximum escaped poll response fits its recalibrated byte profile")
    func maximumPollResponseFits() throws {
        let escapedFingerprint = String(
            repeating: "\"",
            count: TorrentEngineLimits.maximumNetworkInterfaceFingerprintBytes
        )
        let escapedDisplayName = String(
            repeating: "\"",
            count: TorrentEngineLimits.maximumNetworkInterfaceDisplayNameBytes
        )
        let escapedServiceID = String(
            repeating: "\"",
            count: TorrentEngineLimits.maximumVPNServiceIDBytes
        )
        let escapedServiceName = String(
            repeating: "\"",
            count: TorrentEngineLimits.maximumVPNServiceNameBytes
        )
        let response = TorrentEngineIPCPollResponse(
            dirtyMask: .max,
            alertErrors: Array(
                repeating: String(
                    repeating: "\"",
                    count: TorrentEngineIPCLimits.maximumErrorBytes
                ),
                count: TorrentEngineIPCLimits.maximumAlertErrorsPerPoll
            ),
            networkStatus: TorrentNetworkStatus(
                requestedRevision: .max,
                submittedRevision: .max,
                listenPort: 65_535,
                networkBlocked: false,
                hasListener: true,
                endpoint: String(repeating: "\"", count: 255),
                lastError: String(repeating: "\"", count: 511),
                dhtStatus: .running,
                dhtRoutingNodeCount: Int(Int32.max)
            ),
            bridgeHealth: TorrentBridgeHealth(
                isAvailable: true,
                totalAlertWorkerFailures: .max,
                consecutiveAlertWorkerFailures: .max,
                isAlertWorkerDegraded: true,
                lastAlertWorkerError: String(repeating: "\"", count: 511)
            ),
            networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                revision: .max,
                interfaces: (0..<TorrentEngineLimits.maximumNetworkInterfaceCount).map {
                    NetworkInterfaceOption(
                        name: "en\($0)",
                        displayName: escapedDisplayName,
                        fingerprint: escapedFingerprint,
                        vpnServiceID: escapedServiceID,
                        vpnServiceName: escapedServiceName,
                        isLikelyVPN: true
                    )
                }
            ),
            snapshotDataset: TorrentEngineIPCDatasetDescriptor(
                id: UUID(),
                kind: .torrentSnapshots,
                revision: .max,
                itemCount: TorrentEngineLimits.maximumTorrentSnapshotCount,
                pageCount: TorrentEngineIPCLimits.maximumDatasetPageCount
            ),
            trackerHostDataset: TorrentEngineIPCDatasetDescriptor(
                id: UUID(),
                kind: .trackerHosts,
                revision: .max,
                itemCount: TorrentEngineLimits.maximumTrackerHostRowCount,
                pageCount: TorrentEngineIPCLimits.maximumDatasetPageCount
            )
        )

        let encoded = try TorrentEngineIPCJSONCodec.encode(
            response,
            maximumBytes: TorrentEngineIPCOperation.poll.maximumReplyPayloadBytes,
            limits: TorrentEngineIPCOperation.poll.replyJSONLimits
        )

        #expect(encoded.count > 2 * 1_024 * 1_024)
        #expect(encoded.count <= TorrentEngineIPCOperation.poll.maximumReplyPayloadBytes)
    }

    @Test("Container syntax inside strings does not affect depth scanning")
    func containerSyntaxInsideStrings() throws {
        let value = ExamplePayload(
            name: #"literal [{\"nested\":[]}] and \\ escaped text"#,
            values: [1, 2, 3]
        )
        let data = try TorrentEngineIPCJSONCodec.encode(
            value,
            maximumBytes: 4_096,
            limits: testJSONLimits
        )

        #expect(try TorrentEngineIPCJSONCodec.decode(
            ExamplePayload.self,
            from: data,
            maximumBytes: 4_096,
            limits: testJSONLimits
        ) == value)
    }

    @Test("Bare scalar roots are rejected so wire messages must use containers")
    func scalarRootsAreRejected() {
        expectIPCError(.jsonEncodingFailed) {
            try TorrentEngineIPCJSONCodec.encode(
                "not-a-wire-message",
                maximumBytes: 4_096,
                limits: testJSONLimits
            )
        }
    }

    @Test("JSON calls enforce their own limits")
    func JSONBounds() throws {
        let value = ExamplePayload(name: "snapshot", values: [1, 2, 3])
        let data = try TorrentEngineIPCJSONCodec.encode(
            value,
            maximumBytes: 4_096,
            limits: testJSONLimits
        )

        expectIPCError(.payloadTooLarge(actual: data.count, maximum: data.count - 1)) {
            try TorrentEngineIPCJSONCodec.encode(
                value,
                maximumBytes: data.count - 1,
                limits: testJSONLimits
            )
        }
        expectIPCError(.payloadTooLarge(actual: data.count, maximum: data.count - 1)) {
            try TorrentEngineIPCJSONCodec.decode(
                ExamplePayload.self,
                from: data,
                maximumBytes: data.count - 1,
                limits: testJSONLimits
            )
        }
        expectIPCError(.jsonDecodingFailed) {
            try TorrentEngineIPCJSONCodec.decode(
                ExamplePayload.self,
                from: Data([0, 1, 2]),
                maximumBytes: 3,
                limits: testJSONLimits
            )
        }
    }

    @Test("Repeated JSON values consume repeated wire bytes")
    func repeatedValuesConsumeWireBytes() throws {
        let value = String(repeating: "x", count: 200_000)
        let data = try TorrentEngineIPCJSONCodec.encode(
            [value, value],
            maximumBytes: 1 * 1_024 * 1_024,
            limits: testJSONLimits
        )

        #expect(data.count >= value.utf8.count * 2)
        #expect(try TorrentEngineIPCJSONCodec.decode(
            [String].self,
            from: data,
            maximumBytes: 1 * 1_024 * 1_024,
            limits: testJSONLimits
        ) == [value, value])
    }

    @Test("Value-node-dense JSON is rejected before decoding")
    func valueNodeCountIsBounded() throws {
        let limits = TorrentEngineIPCJSONLimits(
            maximumNestingDepth: 8,
            maximumValueNodeCount: 4,
            maximumStringByteCount: 64,
            maximumPrimitiveByteCount: 16
        )
        let accepted = Data("[0,0,0]".utf8)
        #expect(try TorrentEngineIPCJSONCodec.decode(
            [Int].self,
            from: accepted,
            maximumBytes: accepted.count,
            limits: limits
        ) == [0, 0, 0])

        let rejected = Data("[{},{},{},{}]".utf8)
        expectIPCError(.jsonDecodingFailed) {
            try TorrentEngineIPCJSONCodec.decode(
                RejectIfDecoded.self,
                from: rejected,
                maximumBytes: rejected.count,
                limits: limits
            )
        }
    }

    @Test("Individual JSON string and primitive wire lengths are bounded")
    func individualValueLengthsAreBounded() throws {
        let limits = TorrentEngineIPCJSONLimits(
            maximumNestingDepth: 8,
            maximumValueNodeCount: 16,
            maximumStringByteCount: 4,
            maximumPrimitiveByteCount: 4
        )
        let acceptedString = Data(#"["abcd"]"#.utf8)
        #expect(try TorrentEngineIPCJSONCodec.decode(
            [String].self,
            from: acceptedString,
            maximumBytes: acceptedString.count,
            limits: limits
        ) == ["abcd"])

        let rejectedString = Data(#"["abcde"]"#.utf8)
        expectIPCError(.jsonDecodingFailed) {
            try TorrentEngineIPCJSONCodec.decode(
                RejectIfDecoded.self,
                from: rejectedString,
                maximumBytes: rejectedString.count,
                limits: limits
            )
        }

        let acceptedPrimitive = Data("[1234]".utf8)
        #expect(try TorrentEngineIPCJSONCodec.decode(
            [Int].self,
            from: acceptedPrimitive,
            maximumBytes: acceptedPrimitive.count,
            limits: limits
        ) == [1_234])

        let rejectedPrimitive = Data("[12345]".utf8)
        expectIPCError(.jsonDecodingFailed) {
            try TorrentEngineIPCJSONCodec.decode(
                RejectIfDecoded.self,
                from: rejectedPrimitive,
                maximumBytes: rejectedPrimitive.count,
                limits: limits
            )
        }
    }

    @Test("Randomized JSONEncoder containers always pass the preflight")
    func randomizedEncoderOutputPassesPreflight() throws {
        var generator = DeterministicGenerator()
        for _ in 0..<1_024 {
            let value = generator.value()
            let data = try TorrentEngineIPCJSONCodec.encode(
                value,
                maximumBytes: 64 * 1_024,
                limits: testJSONLimits
            )
            #expect(try TorrentEngineIPCJSONCodec.decode(
                RandomJSONValue.self,
                from: data,
                maximumBytes: 64 * 1_024,
                limits: testJSONLimits
            ) == value)
        }
    }

    @Test("Base64 data does not receive optional slash escaping")
    func base64SlashesAreNotEscaped() throws {
        let value = BinaryPayload(bytes: Data(repeating: 0xFF, count: 3))
        let data = try TorrentEngineIPCJSONCodec.encode(
            value,
            maximumBytes: 4_096,
            limits: testJSONLimits
        )
        let text = String(decoding: data, as: UTF8.self)

        #expect(text.contains(#""bytes":"////""#))
        #expect(!text.contains(#"\/"#))
        #expect(try TorrentEngineIPCJSONCodec.decode(
            BinaryPayload.self,
            from: data,
            maximumBytes: 4_096,
            limits: testJSONLimits
        ) == value)
    }

    @Test("Mismatched JSON containers are rejected before decoding")
    func mismatchedContainers() {
        let data = Data(#"{"values":[1,2}}"#.utf8)

        expectIPCError(.jsonDecodingFailed) {
            try TorrentEngineIPCJSONCodec.decode(
                RejectIfDecoded.self,
                from: data,
                maximumBytes: data.count,
                limits: testJSONLimits
            )
        }
    }

    @Test("Trailing JSON values are rejected before decoding")
    func trailingValue() {
        let data = Data(#"{} []"#.utf8)

        expectIPCError(.jsonDecodingFailed) {
            try TorrentEngineIPCJSONCodec.decode(
                RejectIfDecoded.self,
                from: data,
                maximumBytes: data.count,
                limits: testJSONLimits
            )
        }
    }

    @Test("JSON depth accepts the exact boundary and rejects the next container")
    func JSONDepth() throws {
        let acceptedText = String(repeating: "[", count: 32)
            + "0"
            + String(repeating: "]", count: 32)
        try TorrentEngineIPCJSONCodec.preflightForFuzzing(
            Data(acceptedText.utf8),
            limits: testJSONLimits
        )

        let rejectedText = String(repeating: "[", count: 33)
            + "0"
            + String(repeating: "]", count: 33)
        let rejected = Data(rejectedText.utf8)

        expectIPCError(.jsonDecodingFailed) {
            try TorrentEngineIPCJSONCodec.decode(
                RejectIfDecoded.self,
                from: rejected,
                maximumBytes: rejected.count,
                limits: testJSONLimits
            )
        }
    }

    private func pollResponse(interfaceCount: Int) -> TorrentEngineIPCPollResponse {
        TorrentEngineIPCPollResponse(
            dirtyMask: 0,
            alertErrors: [],
            networkStatus: .empty,
            bridgeHealth: .healthy,
            networkInterfaceSnapshot: TorrentNetworkInterfaceSnapshot(
                revision: 1,
                interfaces: (0..<interfaceCount).map { index in
                    NetworkInterfaceOption(
                        name: "en\(index)",
                        displayName: "Interface \(index)",
                        fingerprint: "fingerprint-\(index)",
                        vpnServiceID: nil,
                        vpnServiceName: nil,
                        isLikelyVPN: false
                    )
                }
            ),
            snapshotDataset: nil,
            trackerHostDataset: nil
        )
    }
}

private func makeHeader() -> TorrentEngineIPCHeader {
    TorrentEngineIPCHeader(
        requestID: UUID(),
        controllerID: UUID(),
        sequence: 1,
        operation: .handshake,
        operationID: UUID(),
        expectedEpoch: UUID()
    )
}

private func expectIPCError<Result>(
    _ expected: TorrentEngineIPCError,
    performing operation: () throws -> Result
) {
    do {
        _ = try operation()
        Issue.record("Expected \(expected), but the operation succeeded")
    } catch let error as TorrentEngineIPCError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected \(expected), but received \(error)")
    }
}
