package import Foundation

package struct TorrentPeerEndpoint: Codable, Hashable, Sendable {
    package let address: Data
    package let port: UInt16
    package let scopeID: UInt32

    package init(address: Data, port: UInt16, scopeID: UInt32 = 0) {
        self.address = address
        self.port = port
        self.scopeID = scopeID
    }

    package var isValid: Bool {
        (address.count == 4 || address.count == 16)
            && port > 0 && (address.count == 16 || scopeID == 0)
    }
}

package enum TorrentPeerTransport: UInt8, Codable, Sendable {
    case tcp, utp
}

package struct TorrentPeerFlags: OptionSet, Codable, Hashable, Sendable {
    package let rawValue: UInt32
    package init(rawValue: UInt32) { self.rawValue = rawValue }

    package static let seed = Self(rawValue: 1 << 0)
    package static let incoming = Self(rawValue: 1 << 1)
    package static let interested = Self(rawValue: 1 << 2)
    package static let peerInterested = Self(rawValue: 1 << 3)
    package static let choked = Self(rawValue: 1 << 4)
    package static let peerChoked = Self(rawValue: 1 << 5)
    package static let snubbed = Self(rawValue: 1 << 6)
    package static let onParole = Self(rawValue: 1 << 7)
    package static let tls = Self(rawValue: 1 << 8)
    package static let obfuscated = Self(rawValue: 1 << 9)
    package static let allKnown: Self = [
        .seed, .incoming, .interested, .peerInterested, .choked, .peerChoked,
        .snubbed, .onParole, .tls, .obfuscated
    ]
}

package struct TorrentPeerDiscovery: OptionSet, Codable, Hashable, Sendable {
    package let rawValue: UInt32
    package init(rawValue: UInt32) { self.rawValue = rawValue }

    package static let tracker = Self(rawValue: 1 << 0)
    package static let dht = Self(rawValue: 1 << 1)
    package static let peerExchange = Self(rawValue: 1 << 2)
    package static let localNetwork = Self(rawValue: 1 << 3)
    package static let resumeData = Self(rawValue: 1 << 4)
    package static let incoming = Self(rawValue: 1 << 5)
    package static let allKnown: Self = [.tracker, .dht, .peerExchange, .localNetwork, .resumeData, .incoming]
}

package struct TorrentPeer: Codable, Equatable, Identifiable, Sendable {
    package struct ID: Hashable, Sendable {
        package let endpoint: TorrentPeerEndpoint
        package let transport: TorrentPeerTransport
    }

    package let endpoint: TorrentPeerEndpoint
    package let transport: TorrentPeerTransport
    package let client: String
    package let progressPartsPerMillion: Int32
    package let downloadRate: Int32
    package let uploadRate: Int32
    package let downloaded: Int64
    package let uploaded: Int64
    package let flags: TorrentPeerFlags
    package let sources: TorrentPeerDiscovery

    package var id: ID { ID(endpoint: endpoint, transport: transport) }
    package var progress: Double { Double(progressPartsPerMillion) / 1_000_000 }

    package init(
        endpoint: TorrentPeerEndpoint, transport: TorrentPeerTransport,
        client: String, progressPartsPerMillion: Int32,
        downloadRate: Int32, uploadRate: Int32, downloaded: Int64, uploaded: Int64,
        flags: TorrentPeerFlags, sources: TorrentPeerDiscovery
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.client = client
        self.progressPartsPerMillion = progressPartsPerMillion
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.downloaded = downloaded
        self.uploaded = uploaded
        self.flags = flags
        self.sources = sources
    }
}

package struct TorrentPeerSnapshot: Codable, Equatable, Sendable {
    package let peers: [TorrentPeer]
    package let totalCount: Int32

    package init(peers: [TorrentPeer], totalCount: Int32) {
        self.peers = peers
        self.totalCount = totalCount
    }

    package static let empty = Self(peers: [], totalCount: 0)
}
