import Foundation
import Testing
import TorrentEngineIPC
import TorrentEngineModel
@testable import TorrentEngineClient

@Suite("Peer response boundary")
struct TorrentPeerResponseTests {
    private func peer(
        address: Data = Data([8, 8, 8, 8]), port: UInt16 = 6881, scope: UInt32 = 0,
        client: String = "Example", progress: Int32 = 0, download: Int32 = 0, upload: Int32 = 0,
        downloaded: Int64 = 0, uploaded: Int64 = 0, flags: TorrentPeerFlags = [], sources: TorrentPeerDiscovery = []
    ) -> TorrentPeer {
        TorrentPeer(
            endpoint: TorrentPeerEndpoint(address: address, port: port, scopeID: scope), transport: .tcp,
            client: client, progressPartsPerMillion: progress, downloadRate: download, uploadRate: upload,
            downloaded: downloaded, uploaded: uploaded, flags: flags, sources: sources
        )
    }

    @Test("Maximum peer replies fit both the byte and JSON structure budgets")
    func maximumReply() throws {
        let snapshot = TorrentPeerSnapshot(peers: (0..<TorrentEngineLimits.maximumPeerCount).map { index in
            peer(address: Data(repeating: 255, count: 16), port: UInt16(index + 1), scope: .max,
                 client: String(repeating: "\\", count: 255), progress: 1_000_000,
                 download: .max, upload: .max, downloaded: .max, uploaded: .max,
                 flags: .allKnown, sources: .allKnown)
        }, totalCount: .max)
        let operation = TorrentEngineIPCOperation.peers
        let data = try TorrentEngineIPCJSONCodec.encode(
            snapshot, maximumBytes: operation.maximumReplyPayloadBytes, limits: operation.replyJSONLimits
        )
        let decoded = try TorrentEngineIPCJSONCodec.decode(
            TorrentPeerSnapshot.self, from: data,
            maximumBytes: operation.maximumReplyPayloadBytes, limits: operation.replyJSONLimits
        )
        try TorrentEngineClientResponseValidator.validate(decoded)
        #expect(decoded == snapshot)
        try TorrentEngineClientResponseValidator.validate(TorrentPeerSnapshot.empty)
    }

    @Test("Invalid endpoints, counters, flag bits, names and duplicate identities are rejected")
    func malformed() throws {
        let invalid = [
            peer(address: Data()), peer(address: Data(repeating: 0, count: 5)),
            peer(port: 0), peer(scope: 1), peer(client: "bad\0client"), peer(client: String(repeating: "é", count: 128)),
            peer(progress: -1), peer(progress: 1_000_001), peer(download: -1), peer(upload: -1),
            peer(downloaded: -1), peer(uploaded: -1), peer(flags: .init(rawValue: 1 << 31)),
            peer(sources: .init(rawValue: 1 << 31))
        ]
        for value in invalid {
            #expect(throws: TorrentEngineClientError.self) {
                try TorrentEngineClientResponseValidator.validate(TorrentPeerSnapshot(peers: [value], totalCount: 1))
            }
        }
        for snapshot in [
            TorrentPeerSnapshot(peers: [], totalCount: -1), TorrentPeerSnapshot(peers: [], totalCount: 1),
            TorrentPeerSnapshot(peers: [peer(), peer()], totalCount: 2)
        ] {
            #expect(throws: TorrentEngineClientError.self) {
                try TorrentEngineClientResponseValidator.validate(snapshot)
            }
        }
    }
}
