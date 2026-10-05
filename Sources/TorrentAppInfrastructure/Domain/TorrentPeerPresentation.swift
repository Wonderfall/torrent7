package import Foundation
import Network
package import TorrentEngineModel

package struct TorrentPeerRow: Identifiable, Sendable {
    package let peer: TorrentPeer
    package let address: String
    package let endpoint: String
    package let flag: String
    package let country: String
    package let countryCode: String?
    package let connectionDetails: String
    package var id: TorrentPeer.ID { peer.id }

    package init(peer: TorrentPeer, countries: TorrentCountryDatabase?) {
        self.peer = peer
        let ip = peer.endpoint
        if ip.address.count == 4 {
            address = IPv4Address(ip.address)?.debugDescription ?? "Unknown"
            endpoint = "\(address):\(ip.port)"
        } else {
            let scope = ip.scopeID == 0 ? "" : "%\(ip.scopeID)"
            address = "\(IPv6Address(ip.address)?.debugDescription ?? "Unknown")\(scope)"
            endpoint = "[\(address)]:\(ip.port)"
        }
        countryCode = countries?.countryCode(for: ip.address)
        if let code = countryCode {
            flag = String(String.UnicodeScalarView(code.unicodeScalars.compactMap {
                UnicodeScalar(127_397 + $0.value)
            }))
            country = Locale.current.localizedString(forRegionCode: code) ?? code
        } else {
            flag = ""
            country = TorrentCountryDatabase.isLocal(ip.address) ? "Local network" : "Unknown country"
        }

        var sources = [String]()
        for (source, name): (TorrentPeerDiscovery, String) in [
            (.tracker, "Tracker"), (.dht, "DHT"), (.peerExchange, "Peer exchange"),
            (.localNetwork, "Local discovery"), (.resumeData, "Resume data"), (.incoming, "Incoming")
        ] where peer.sources.contains(source) { sources.append(name) }
        let direction = peer.flags.contains(.incoming) ? "Incoming" : "Outgoing"
        let transport = peer.transport == .tcp ? "TCP" : "µTP"
        var details = ["\(direction) · \(transport)"]
        if peer.flags.contains(.tls) { details.append("TLS encrypted") }
        else if peer.flags.contains(.obfuscated) { details.append("Protocol obfuscation") }
        if !sources.isEmpty { details.append("Discovered via \(sources.joined(separator: ", "))") }
        if peer.flags.contains(.snubbed) { details.append("Peer is not responding to requests") }
        if peer.flags.contains(.onParole) { details.append("Verifying peer after corrupt data") }
        connectionDetails = details.joined(separator: "\n")
    }

    package var downloadState: String {
        if peer.downloadRate > 0 { return "Receiving data from this peer" }
        if !peer.flags.contains(.interested) { return "No pieces needed from this peer" }
        return peer.flags.contains(.peerChoked) ? "Waiting for peer to allow downloads" : "Waiting for data"
    }

    package var uploadState: String {
        if peer.uploadRate > 0 { return "Sending data to this peer" }
        if !peer.flags.contains(.peerInterested) { return "Peer is not requesting pieces" }
        return peer.flags.contains(.choked) ? "Waiting for an upload slot" : "Waiting for requests"
    }

    @concurrent
    package static func prepare(
        snapshot: TorrentPeerSnapshot, countries: TorrentCountryDatabase?, sortOrder: [Sort], query: String = ""
    ) async throws -> [Self] {
        let query = TorrentSearchQuery(query)
        var rows = [Self]()
        rows.reserveCapacity(snapshot.peers.count)
        for peer in snapshot.peers {
            try Task.checkCancellation()
            let row = Self(peer: peer, countries: countries)
            if query.matches(row.endpoint) || query.matches(peer.client)
                || query.matches(row.country) || row.countryCode?.caseInsensitiveCompare(query.text) == .orderedSame {
                rows.append(row)
            }
        }
        // Always break equal column values by endpoint, independent of libtorrent's order.
        rows.sort(using: sortOrder + [Sort(.address)])
        try Task.checkCancellation()
        return rows
    }

    package struct Sort: SortComparator {
        package enum Key: Hashable, Sendable { case address, client, progress, download, upload }
        package let key: Key
        package var order: SortOrder

        package init(_ key: Key, order: SortOrder? = nil) {
            self.key = key
            self.order = order ?? (key == .address || key == .client ? .forward : .reverse)
        }

        package func compare(_ lhs: TorrentPeerRow, _ rhs: TorrentPeerRow) -> ComparisonResult {
            let result: ComparisonResult
            switch key {
            case .address:
                let a = lhs.peer.endpoint
                let b = rhs.peer.endpoint
                if a.address.count != b.address.count { result = compareValues(a.address.count, b.address.count) }
                else if a.address != b.address {
                    result = a.address.lexicographicallyPrecedes(b.address) ? .orderedAscending : .orderedDescending
                } else if a.scopeID != b.scopeID { result = compareValues(a.scopeID, b.scopeID) }
                else if a.port != b.port { result = compareValues(a.port, b.port) }
                else { result = compareValues(lhs.peer.transport.rawValue, rhs.peer.transport.rawValue) }
            case .client: result = lhs.peer.client.localizedStandardCompare(rhs.peer.client)
            case .progress: result = compareValues(lhs.peer.progressPartsPerMillion, rhs.peer.progressPartsPerMillion)
            case .download: result = compareValues(lhs.peer.downloadRate, rhs.peer.downloadRate)
            case .upload: result = compareValues(lhs.peer.uploadRate, rhs.peer.uploadRate)
            }
            guard order == .reverse else { return result }
            switch result {
            case .orderedAscending: return .orderedDescending
            case .orderedDescending: return .orderedAscending
            case .orderedSame: return .orderedSame
            }
        }

        private func compareValues<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
            lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        }
    }
}
