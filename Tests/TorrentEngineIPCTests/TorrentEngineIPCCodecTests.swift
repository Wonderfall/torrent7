import Foundation
import Testing
import TorrentEngineModel
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

    @Test("Request inspection reports resource cost before decoding")
    func requestInspection() throws {
        let request = TorrentEngineIPCRequest(
            header: makeHeader(),
            payload: Data([1, 2, 3, 4])
        )
        let dictionary = try TorrentEngineIPCEnvelopeCodec.encode(
            request,
            maximumPayloadBytes: 4
        )

        let metadata = try TorrentEngineIPCEnvelopeCodec.inspectRequest(dictionary)
        #expect(metadata.header == request.header)
        #expect(metadata.hasPayload)
        #expect(metadata.payloadByteCount == 4)
        #expect(try TorrentEngineIPCEnvelopeCodec.decodeRequest(
            dictionary,
            metadata: metadata,
            maximumPayloadBytes: 4
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
            payloadByteCount: 3
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
        #expect(TorrentEngineIPCProtocol.version == 7)
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

    @Test("Add responses use a property-list container instead of a scalar root")
    func addedTorrentResponseRoundTrip() throws {
        let value = TorrentEngineIPCAddedTorrentResponse(
            identifier: "t:\(String(repeating: "a", count: 32))"
        )
        let data = try TorrentEngineIPCPropertyListCodec.encode(
            value,
            maximumBytes: 4_096
        )

        let decoded = try TorrentEngineIPCPropertyListCodec.decode(
            TorrentEngineIPCAddedTorrentResponse.self,
            from: data,
            maximumBytes: 4_096
        )
        #expect(decoded == value)
    }

    @Test("Removal responses keep both outcomes inside a property-list container")
    func removalResponseRoundTrips() throws {
        for outcome in [
            TorrentRemovalOutcome.removed,
            TorrentRemovalOutcome.removedWithWarning("Files were retained safely."),
        ] {
            let value = TorrentEngineIPCRemovalResponse(outcome: outcome)
            let data = try TorrentEngineIPCPropertyListCodec.encode(
                value,
                maximumBytes: 4_096
            )
            let decoded = try TorrentEngineIPCPropertyListCodec.decode(
                TorrentEngineIPCRemovalResponse.self,
                from: data,
                maximumBytes: 4_096
            )
            #expect(decoded == value)
        }
    }

    @Test("Poll responses carry the required bounded interface snapshot")
    func pollResponseRoundTrip() throws {
        let response = pollResponse(interfaceCount: 1)
        let data = try TorrentEngineIPCPropertyListCodec.encode(
            response,
            maximumBytes: TorrentEngineIPCOperation.poll.maximumReplyPayloadBytes
        )
        let decoded = try TorrentEngineIPCPropertyListCodec.decode(
            TorrentEngineIPCPollResponse.self,
            from: data,
            maximumBytes: TorrentEngineIPCOperation.poll.maximumReplyPayloadBytes,
            decodingLimits: TorrentEngineIPCOperation.poll.propertyListDecodingLimits
        )

        #expect(decoded.networkInterfaceSnapshot == response.networkInterfaceSnapshot)
    }

    @Test("Poll decoding rejects interface collection amplification")
    func pollInterfaceCollectionAmplification() throws {
        let maximum = TorrentEngineLimits.maximumNetworkInterfaceCount
        let accepted = pollResponse(interfaceCount: maximum)
        let acceptedData = try TorrentEngineIPCPropertyListCodec.encode(
            accepted,
            maximumBytes: TorrentEngineIPCOperation.poll.maximumReplyPayloadBytes
        )
        _ = try TorrentEngineIPCPropertyListCodec.decode(
            TorrentEngineIPCPollResponse.self,
            from: acceptedData,
            maximumBytes: TorrentEngineIPCOperation.poll.maximumReplyPayloadBytes,
            decodingLimits: TorrentEngineIPCOperation.poll.propertyListDecodingLimits
        )

        let oversized = pollResponse(interfaceCount: maximum + 1)
        let oversizedData = try TorrentEngineIPCPropertyListCodec.encode(
            oversized,
            maximumBytes: TorrentEngineIPCOperation.poll.maximumReplyPayloadBytes
        )
        expectIPCError(.propertyListDecodingFailed) {
            try TorrentEngineIPCPropertyListCodec.decode(
                TorrentEngineIPCPollResponse.self,
                from: oversizedData,
                maximumBytes: TorrentEngineIPCOperation.poll.maximumReplyPayloadBytes,
                decodingLimits: TorrentEngineIPCOperation.poll.propertyListDecodingLimits
            )
        }
        expectIPCError(.propertyListDecodingFailed) {
            try TorrentEngineIPCPropertyListCodec.decode(
                TorrentNetworkInterfaceSnapshot.self,
                from: try TorrentEngineIPCPropertyListCodec.encode(
                    oversized.networkInterfaceSnapshot,
                    maximumBytes: TorrentEngineIPCOperation.poll.maximumReplyPayloadBytes
                ),
                maximumBytes: TorrentEngineIPCOperation.poll.maximumReplyPayloadBytes
            )
        }
    }

    @Test("Bare scalar roots are rejected so wire messages must use containers")
    func scalarRootsAreRejected() {
        expectIPCError(.propertyListEncodingFailed) {
            try TorrentEngineIPCPropertyListCodec.encode(
                "not-a-wire-message",
                maximumBytes: 4_096
            )
        }
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

    @Test("Binary property-list collection amplification is rejected before decoding")
    func propertyListCollectionAmplification() throws {
        let amplified = Array(repeating: 0, count: 500_000)
        let data = try TorrentEngineIPCPropertyListCodec.encode(
            amplified,
            maximumBytes: 1 * 1_024 * 1_024
        )

        expectIPCError(.propertyListDecodingFailed) {
            try TorrentEngineIPCPropertyListCodec.decode(
                [Int].self,
                from: data,
                maximumBytes: 1 * 1_024 * 1_024,
                decodingLimits: .init(
                    maximumContainerElementCount: 256,
                    maximumCollectionReferenceCount: 128 * 1_024
                )
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
