import Foundation
import Network
import Testing
import TorrentAppInfrastructure
import TorrentEngineModel

@Suite("Peer presentation")
struct TorrentPeerPresentationTests {
    private func peer(_ address: Data, rate: Int32 = 0, flags: TorrentPeerFlags = []) -> TorrentPeer {
        TorrentPeer(
            endpoint: TorrentPeerEndpoint(address: address, port: 6881), transport: .tcp,
            client: "Example 1.0", progressPartsPerMillion: 500_000, downloadRate: rate,
            uploadRate: 0, downloaded: 100, uploaded: 200, flags: flags, sources: [.tracker, .dht]
        )
    }

    @Test("IP ordering is numeric and rate ties have stable endpoint order")
    func sorting() async throws {
        let peers = [peer(Data([1, 0, 0, 10])), peer(Data([1, 0, 0, 2])), peer(Data([2, 0, 0, 1]), rate: 100)]
        let snapshot = TorrentPeerSnapshot(peers: peers, totalCount: 3)
        let addresses = try await TorrentPeerRow.prepare(snapshot: snapshot, countries: nil, sortOrder: [.init(.address)])
        #expect(addresses.map(\.address) == ["1.0.0.2", "1.0.0.10", "2.0.0.1"])
        let rates = try await TorrentPeerRow.prepare(snapshot: snapshot, countries: nil, sortOrder: [.init(.download)])
        #expect(rates.map(\.address) == ["2.0.0.1", "1.0.0.2", "1.0.0.10"])
        #expect(rates[0].downloadState == "Receiving data from this peer")
    }

    @Test("IPv6 endpoints, local addresses and transfer states are unambiguous")
    func details() throws {
        let ipv6 = try #require(IPv6Address("fe80::1"))
        let value = peer(ipv6.rawValue, flags: [.incoming, .interested, .peerChoked, .peerInterested, .choked])
        let row = TorrentPeerRow(peer: value, countries: nil)
        #expect(row.endpoint == "[fe80::1]:6881")
        #expect(row.flag.isEmpty)
        #expect(row.country == "Local network")
        #expect(row.connectionDetails.contains("Incoming · TCP"))
        #expect(row.connectionDetails.contains("Tracker, DHT"))
        #expect(row.downloadState == "Waiting for peer to allow downloads")
        #expect(row.uploadState == "Waiting for an upload slot")
    }

    @Test("Cancelled preparation does not publish rows")
    func cancellation() async {
        let task = Task {
            // SAFETY: The current-task handle is used only in its synchronous
            // callback to cancel this test task and never escapes the callback.
            unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
            return try await TorrentPeerRow.prepare(snapshot: .empty, countries: nil, sortOrder: [])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
