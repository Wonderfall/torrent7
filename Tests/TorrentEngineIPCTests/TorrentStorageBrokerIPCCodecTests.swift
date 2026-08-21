import Foundation
import Testing
import XPC
@testable import TorrentEngineIPC

@Suite("Torrent storage broker IPC")
struct TorrentStorageBrokerIPCCodecTests {
    @Test("Broker requests and replies round trip")
    func roundTrips() throws {
        let common = makeCommon()
        let request = TorrentStorageBrokerRequest.statBatch(
            common,
            claimID: UUID(),
            generation: 7,
            fileIndices: [0, 4, 9]
        )
        let decoded = try TorrentStorageBrokerIPCCodec.decodeRequest(
            TorrentStorageBrokerIPCCodec.encode(request)
        )
        #expect(decoded == request)

        let reply = TorrentStorageBrokerReply.success(
            requestID: common.requestID,
            metadata: nil,
            statistics: [
                TorrentStorageBrokerFileMetadata(
                    fileIndex: 0,
                    size: 12,
                    device: 3,
                    inode: 4,
                    linkCount: 1,
                    mode: 0o100600
                ),
            ],
            fileDescriptor: nil
        )
        let replyRequest = TorrentStorageBrokerRequest.statBatch(
            common,
            claimID: UUID(),
            generation: 7,
            fileIndices: [0]
        )
        let decodedReply = try TorrentStorageBrokerIPCCodec.decodeReply(
            TorrentStorageBrokerIPCCodec.encode(reply, for: replyRequest),
            for: replyRequest
        )
        guard case .success(let requestID, nil, let statistics, nil) = decodedReply else {
            Issue.record("Expected a successful stat reply")
            return
        }
        #expect(requestID == common.requestID)
        #expect(statistics.count == 1)
        #expect(statistics[0].fileIndex == 0)
    }

    @Test("Oversized stat data is rejected before copying")
    func oversizedStatDataIsRejected() {
        let request = TorrentStorageBrokerRequest.statBatch(
            makeCommon(),
            claimID: UUID(),
            generation: 1,
            fileIndices: [0]
        )
        var dictionary = TorrentStorageBrokerIPCCodec.encode(request)
        let oversized = Data(
            repeating: 0,
            count: TorrentStorageBrokerProtocol.maximumStatBatchBytes + 1
        )
        dictionary["is"] = xpcData(oversized)

        #expect(throws: TorrentStorageBrokerIPCError.malformedMessage) {
            _ = try TorrentStorageBrokerIPCCodec.decodeRequest(dictionary)
        }
    }

    @Test("Oversized UUID strings are rejected before bridging")
    func oversizedUUIDIsRejected() {
        let request = TorrentStorageBrokerRequest.handshake(makeCommon())
        var dictionary = TorrentStorageBrokerIPCCodec.encode(request)
        dictionary["r"] = String(repeating: "A", count: 65_536)

        #expect(throws: TorrentStorageBrokerIPCError.malformedMessage) {
            _ = try TorrentStorageBrokerIPCCodec.decodeRequest(dictionary)
        }
    }

    @Test("Oversized reply messages are rejected before bridging")
    func oversizedReplyMessageIsRejected() throws {
        let request = TorrentStorageBrokerRequest.handshake(makeCommon())
        var dictionary = try TorrentStorageBrokerIPCCodec.encode(
            .failure(
                requestID: request.common.requestID,
                code: .internalFailure,
                message: "failure"
            ),
            for: request
        )
        dictionary["m"] = String(
            repeating: "x",
            count: TorrentStorageBrokerProtocol.maximumErrorBytes + 1
        )

        #expect(throws: TorrentStorageBrokerIPCError.malformedMessage) {
            _ = try TorrentStorageBrokerIPCCodec.decodeReply(dictionary, for: request)
        }
    }

    private func makeCommon() -> TorrentStorageBrokerRequest.Common {
        TorrentStorageBrokerRequest.Common(
            requestID: UUID(),
            engineEpoch: UUID(),
            sessionNonce: UUID(),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                + 5_000_000_000
        )
    }

    private func xpcData(_ data: Data) -> xpc_object_t {
        unsafe data.withUnsafeBytes { bytes in
            unsafe xpc_data_create(bytes.baseAddress, bytes.count)
        }
    }
}
