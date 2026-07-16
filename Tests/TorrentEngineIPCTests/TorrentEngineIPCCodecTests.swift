import Foundation
import Testing
import XPC
@testable import TorrentEngineIPC

@Suite("Torrent engine IPC envelopes")
struct TorrentEngineIPCEnvelopeTests {
    @Test("Request and reply envelopes round trip")
    func envelopeRoundTrips() throws {
        let header = makeHeader()
        let request = TorrentEngineIPCRequest(
            header: header,
            payload: Data([0, 1, 2, 255])
        )
        let requestDictionary = try TorrentEngineIPCEnvelopeCodec.encode(
            request,
            maximumPayloadBytes: 64
        )
        let decodedRequest = try TorrentEngineIPCEnvelopeCodec.decodeRequest(
            requestDictionary,
            maximumPayloadBytes: 64
        )
        #expect(decodedRequest == request)

        let reply = TorrentEngineIPCReply(
            header: header,
            engineEpoch: UUID(),
            status: .failure,
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
        let request = TorrentEngineIPCRequest(header: makeHeader(), payload: source)
        let dictionary = try TorrentEngineIPCEnvelopeCodec.encode(
            request,
            maximumPayloadBytes: 3
        )
        source[0] = 9

        let decoded = try TorrentEngineIPCEnvelopeCodec.decodeRequest(
            dictionary,
            maximumPayloadBytes: 3
        )
        #expect(decoded.payload == Data([1, 2, 3]))
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

    @Test("Stable dataset, migration, and hint operation numbers")
    func stableOperationNumbers() {
        #expect(TorrentEngineIPCOperation.openDataset.rawValue == 50)
        #expect(TorrentEngineIPCOperation.readDataset.rawValue == 51)
        #expect(TorrentEngineIPCOperation.closeDataset.rawValue == 52)
        #expect(TorrentEngineIPCOperation.beginStateMigration.rawValue == 60)
        #expect(TorrentEngineIPCOperation.importStateMigrationFile.rawValue == 61)
        #expect(TorrentEngineIPCOperation.commitStateMigration.rawValue == 62)
        #expect(TorrentEngineIPCOperation.abortStateMigration.rawValue == 63)
        #expect(TorrentEngineIPCOperation.changeHint.rawValue == 100)
    }

    private func encodedRequest() throws -> XPCDictionary {
        try TorrentEngineIPCEnvelopeCodec.encode(
            TorrentEngineIPCRequest(header: makeHeader()),
            maximumPayloadBytes: 64
        )
    }
}

@Suite("Torrent engine IPC property-list payloads")
struct TorrentEngineIPCPropertyListTests {
    private struct ExamplePayload: Codable, Equatable, Sendable {
        let name: String
        let values: [Int]
    }

    @Test("Binary property-list payloads round trip")
    func propertyListRoundTrip() throws {
        let value = ExamplePayload(name: "snapshot", values: [1, 2, 3])
        let data = try TorrentEngineIPCPropertyListCodec.encode(
            value,
            maximumBytes: 4_096
        )
        #expect(data.starts(with: Data("bplist00".utf8)))

        let decoded = try TorrentEngineIPCPropertyListCodec.decode(
            ExamplePayload.self,
            from: data,
            maximumBytes: 4_096
        )
        #expect(decoded == value)
    }

    @Test("Property-list calls enforce their own limits")
    func propertyListBounds() throws {
        let value = ExamplePayload(name: "snapshot", values: [1, 2, 3])
        let data = try TorrentEngineIPCPropertyListCodec.encode(
            value,
            maximumBytes: 4_096
        )

        expectIPCError(.payloadTooLarge(actual: data.count, maximum: data.count - 1)) {
            try TorrentEngineIPCPropertyListCodec.encode(
                value,
                maximumBytes: data.count - 1
            )
        }
        expectIPCError(.payloadTooLarge(actual: data.count, maximum: data.count - 1)) {
            try TorrentEngineIPCPropertyListCodec.decode(
                ExamplePayload.self,
                from: data,
                maximumBytes: data.count - 1
            )
        }
        expectIPCError(.propertyListDecodingFailed) {
            try TorrentEngineIPCPropertyListCodec.decode(
                ExamplePayload.self,
                from: Data([0, 1, 2]),
                maximumBytes: 3
            )
        }
    }
}

@Suite("Torrent engine IPC file descriptors")
struct TorrentEngineIPCFileDescriptorTests {
    @Test("Descriptors are boxed and duplicated")
    func fileDescriptorRoundTrip() throws {
        let pipe = Pipe()
        let request = TorrentEngineIPCRequest(
            header: makeHeader(),
            fileDescriptor: pipe.fileHandleForWriting.fileDescriptor
        )
        let dictionary = try TorrentEngineIPCEnvelopeCodec.encode(
            request,
            maximumPayloadBytes: 0
        )
        let decoded = try TorrentEngineIPCEnvelopeCodec.decodeRequest(
            dictionary,
            maximumPayloadBytes: 0
        )

        let duplicated = try #require(decoded.fileDescriptor)
        let duplicatedHandle = FileHandle(
            fileDescriptor: duplicated,
            closeOnDealloc: true
        )
        let sent = Data("bounded descriptor".utf8)
        try duplicatedHandle.write(contentsOf: sent)
        try duplicatedHandle.close()

        let received = try pipe.fileHandleForReading.read(upToCount: sent.count)
        #expect(received == sent)
    }

    @Test("Invalid and wrong-type descriptors are rejected")
    func invalidFileDescriptors() {
        expectIPCError(.invalidFileDescriptor) {
            try TorrentEngineIPCXPCValues.boxedFileDescriptor(-1)
        }

        var dictionary = XPCDictionary()
        dictionary[TorrentEngineIPCField.fileDescriptor] = "not a descriptor"
        expectIPCError(
            .wrongFieldType(
                field: TorrentEngineIPCField.fileDescriptor,
                expected: "file descriptor"
            )
        ) {
            try TorrentEngineIPCXPCValues.duplicateFileDescriptor(from: dictionary)
        }
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
