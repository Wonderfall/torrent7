import Foundation
import Testing
import TorrentEngineIPC
import TorrentEngineModel
@testable import TorrentEngineClient

@Suite("Hostile engine response validation")
struct TorrentEngineClientResponseValidatorTests {
    @Test("Removal warnings enforce the shared semantic bound")
    func removalWarningBound() throws {
        try TorrentEngineClientResponseValidator.validate(
            TorrentEngineIPCRemovalResponse(
                outcome: .removedWithWarning(
                    String(repeating: "a", count: TorrentEngineLimits.maximumRemovalWarningBytes)
                )
            )
        )

        #expect(throws: TorrentEngineClientError.self) {
            try TorrentEngineClientResponseValidator.validate(
                TorrentEngineIPCRemovalResponse(
                    outcome: .removedWithWarning(
                        String(repeating: "a", count: TorrentEngineLimits.maximumRemovalWarningBytes + 1)
                    )
                )
            )
        }
    }

    private let maximumPayloadBytes = 16 * 1024 * 1024

    @Test("A tracker tier that would overflow the UI is rejected")
    func rejectsOverflowingTrackerTier() throws {
        let batch = TorrentTrackerBatch(
            revision: 1,
            trackers: [makeTracker(tier: Int32.max)]
        )
        let decoded: TorrentTrackerBatch = try roundTrip(batch)

        #expect(throws: TorrentEngineClientError.self) {
            try TorrentEngineClientResponseValidator.validate(decoded)
        }
    }

    @Test("The largest safe tracker tier remains valid")
    func acceptsLargestSafeTrackerTier() throws {
        let batch = TorrentTrackerBatch(
            revision: 1,
            trackers: [makeTracker(tier: Int32.max - 1)]
        )
        let decoded: TorrentTrackerBatch = try roundTrip(batch)

        try TorrentEngineClientResponseValidator.validate(decoded)
    }

    @Test("An oversized response collection is rejected")
    func rejectsOversizedCollection() throws {
        let batch = TorrentWebSeedBatch(
            revision: 1,
            webSeeds: Array(
                repeating: TorrentWebSeedItem(url: "https://seed.example/file"),
                count: TorrentEngineLimits.maximumWebSeedCount + 1
            )
        )
        let decoded: TorrentWebSeedBatch = try roundTrip(batch)

        #expect(throws: TorrentEngineClientError.self) {
            try TorrentEngineClientResponseValidator.validate(decoded)
        }
    }

    @Test("A valid service interface snapshot crosses the client trust boundary")
    func acceptsValidNetworkInterfaceSnapshot() throws {
        try TorrentEngineClientResponseValidator.validate(
            makePollResponse(snapshot: TorrentNetworkInterfaceSnapshot(
                revision: 1,
                interfaces: [makeNetworkInterface()]
            ))
        )
    }

    @Test("Service interface snapshots require a positive revision and unique names")
    func rejectsInvalidNetworkInterfaceSnapshotIdentity() {
        let interface = makeNetworkInterface()
        for snapshot in [
            TorrentNetworkInterfaceSnapshot(revision: 0, interfaces: [interface]),
            TorrentNetworkInterfaceSnapshot(revision: 1, interfaces: [interface, interface]),
        ] {
            #expect(throws: TorrentEngineClientError.self) {
                try TorrentEngineClientResponseValidator.validate(
                    makePollResponse(snapshot: snapshot)
                )
            }
        }
    }

    @Test("Service interface strings and VPN identity remain bounded and consistent")
    func rejectsMalformedNetworkInterfaceFields() {
        let invalidInterfaces = [
            makeNetworkInterface(name: "bad interface"),
            makeNetworkInterface(displayName: ""),
            makeNetworkInterface(fingerprint: "bad\0fingerprint"),
            makeNetworkInterface(
                vpnServiceID: "vpn-service",
                vpnServiceName: nil,
                isLikelyVPN: true
            ),
            makeNetworkInterface(
                vpnServiceID: "vpn-service",
                vpnServiceName: "VPN",
                isLikelyVPN: false
            ),
            makeNetworkInterface(
                fingerprint: String(
                    repeating: "f",
                    count: TorrentEngineLimits.maximumNetworkInterfaceFingerprintBytes + 1
                )
            ),
        ]

        for interface in invalidInterfaces {
            #expect(throws: TorrentEngineClientError.self) {
                try TorrentEngineClientResponseValidator.validate(
                    makePollResponse(snapshot: TorrentNetworkInterfaceSnapshot(
                        revision: 1,
                        interfaces: [interface]
                    ))
                )
            }
        }
    }

    @Test("Inconsistent piece metadata fails during decoding")
    func rejectsInconsistentPieceMapDuringDecoding() throws {
        let inconsistent = TorrentPieceMap(
            totalPieces: 2,
            completedPieces: 1,
            availablePieces: 2,
            isMapAvailable: true,
            isMapTruncated: false,
            pieces: [1]
        )
        let data = try TorrentEngineIPCPropertyListCodec.encode(
            inconsistent,
            maximumBytes: maximumPayloadBytes
        )

        #expect(throws: TorrentEngineIPCError.self) {
            let _: TorrentPieceMap = try TorrentEngineIPCPropertyListCodec.decode(
                from: data,
                maximumBytes: maximumPayloadBytes
            )
        }
    }

    @Test("An over-bound piece map fails during decoding")
    func rejectsOverBoundPieceMapDuringDecoding() throws {
        let inconsistent = TorrentPieceMap(
            totalPieces: Int(Int32.max) + 1,
            completedPieces: 0,
            availablePieces: 0,
            isMapAvailable: false,
            isMapTruncated: true,
            pieces: []
        )
        let data = try TorrentEngineIPCPropertyListCodec.encode(
            inconsistent,
            maximumBytes: maximumPayloadBytes
        )

        #expect(throws: TorrentEngineIPCError.self) {
            let _: TorrentPieceMap = try TorrentEngineIPCPropertyListCodec.decode(
                from: data,
                maximumBytes: maximumPayloadBytes
            )
        }
    }

    @Test("Invalid piece states fail during decoding")
    func rejectsInvalidPieceStateDuringDecoding() throws {
        let inconsistent = TorrentPieceMap(
            totalPieces: 1,
            completedPieces: 1,
            availablePieces: 1,
            isMapAvailable: true,
            isMapTruncated: false,
            pieces: [2]
        )
        let data = try TorrentEngineIPCPropertyListCodec.encode(
            inconsistent,
            maximumBytes: maximumPayloadBytes
        )

        #expect(throws: TorrentEngineIPCError.self) {
            let _: TorrentPieceMap = try TorrentEngineIPCPropertyListCodec.decode(
                from: data,
                maximumBytes: maximumPayloadBytes
            )
        }
    }

    @Test("Snapshot paths must still be authorized by the client")
    func rejectsUnauthorizedSnapshotPath() {
        let torrent = makeTorrent(savePath: "/tmp/untrusted")

        #expect(throws: TorrentEngineClientError.self) {
            try TorrentEngineClientResponseValidator.validateDataset(
                [torrent],
                kind: .torrentSnapshots,
                authorizedSavePaths: ["/tmp/authorized"]
            )
        }
    }

    @Test("Directory slash normalization preserves exact snapshot authorization")
    func acceptsEquivalentDirectorySlash() throws {
        let torrent = makeTorrent(savePath: "/private/tmp/authorized")

        try TorrentEngineClientResponseValidator.validateDataset(
            [torrent],
            kind: .torrentSnapshots,
            authorizedSavePaths: ["/private/tmp/authorized/"]
        )
    }

    @Test("Torrent display names cannot escape the authorized root")
    func rejectsPathBearingTorrentName() {
        for name in ["../outside", "nested/item", ".", ".."] {
            let torrent = makeTorrent(savePath: "/private/tmp/authorized", name: name)

            #expect(throws: TorrentEngineClientError.self) {
                try TorrentEngineClientResponseValidator.validateDataset(
                    [torrent],
                    kind: .torrentSnapshots,
                    authorizedSavePaths: ["/private/tmp/authorized"]
                )
            }
        }
    }

    private func roundTrip<Value: Codable & Sendable>(_ value: Value) throws -> Value {
        let data = try TorrentEngineIPCPropertyListCodec.encode(
            value,
            maximumBytes: maximumPayloadBytes
        )
        return try TorrentEngineIPCPropertyListCodec.decode(
            from: data,
            maximumBytes: maximumPayloadBytes
        )
    }

    private func makeTracker(tier: Int32) -> TorrentTrackerItem {
        TorrentTrackerItem(
            url: "https://tracker.example/announce",
            message: "",
            tier: tier,
            failCount: 0,
            scrapeSeeders: -1,
            scrapeLeechers: -1,
            scrapeDownloaded: -1,
            updating: false,
            verified: false,
            hasError: false,
            enabled: true
        )
    }

    private func makePollResponse(
        snapshot: TorrentNetworkInterfaceSnapshot
    ) -> TorrentEngineIPCPollResponse {
        TorrentEngineIPCPollResponse(
            dirtyMask: 0,
            alertErrors: [],
            networkStatus: .empty,
            bridgeHealth: .healthy,
            networkInterfaceSnapshot: snapshot,
            snapshotDataset: nil,
            trackerHostDataset: nil
        )
    }

    private func makeNetworkInterface(
        name: String = "utun4",
        displayName: String = "VPN",
        fingerprint: String = "fingerprint",
        vpnServiceID: String? = "vpn-service",
        vpnServiceName: String? = "VPN",
        isLikelyVPN: Bool = true
    ) -> NetworkInterfaceOption {
        NetworkInterfaceOption(
            name: name,
            displayName: displayName,
            fingerprint: fingerprint,
            vpnServiceID: vpnServiceID,
            vpnServiceName: vpnServiceName,
            isLikelyVPN: isLikelyVPN
        )
    }

    private func makeTorrent(savePath: String, name: String = "Torrent") -> TorrentItem {
        TorrentItem(
            id: "t:\(String(repeating: "a", count: 32))",
            infoHash: "v1:\(String(repeating: "b", count: 40))",
            name: name,
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
            hasMetadata: true,
            privateTorrent: false
        )
    }
}
