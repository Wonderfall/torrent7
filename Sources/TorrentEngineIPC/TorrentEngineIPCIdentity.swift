package struct TorrentEngineIPCIdentityPair: Equatable, Sendable {
    package let appIdentifier: String
    package let serviceIdentifier: String

    package init(appIdentifier: String, serviceIdentifier: String) {
        self.appIdentifier = appIdentifier
        self.serviceIdentifier = serviceIdentifier
    }
}

package enum TorrentEngineIPCIdentity {
    package static let release = TorrentEngineIPCIdentityPair(
        appIdentifier: "app.torrent7",
        serviceIdentifier: "app.torrent7.engine"
    )
    package static let debug = TorrentEngineIPCIdentityPair(
        appIdentifier: "app.torrent7.debug",
        serviceIdentifier: "app.torrent7.debug.engine"
    )
    // This pair exists only for the separately assembled ad-hoc integration
    // bundle. Production packaging never embeds either integration binary.
    package static let integration = TorrentEngineIPCIdentityPair(
        appIdentifier: "app.torrent7.integration",
        serviceIdentifier: "app.torrent7.integration.engine"
    )
    package static let reducedAssuranceInfoKey = "Torrent7AllowAdHocXPCPeer"

    package static func pair(appIdentifier: String?) -> TorrentEngineIPCIdentityPair? {
        switch appIdentifier {
        case release.appIdentifier:
            release
        case debug.appIdentifier:
            debug
        case integration.appIdentifier:
            integration
        default:
            nil
        }
    }

    package static func pair(serviceIdentifier: String?) -> TorrentEngineIPCIdentityPair? {
        switch serviceIdentifier {
        case release.serviceIdentifier:
            release
        case debug.serviceIdentifier:
            debug
        case integration.serviceIdentifier:
            integration
        default:
            nil
        }
    }

    package static func authentication(
        allowsReducedAssurance: Bool
    ) -> TorrentEngineIPCPeerAuthentication {
        // Local ad-hoc bundles have no Team ID. Packaging requires this flag on
        // both peers only in that mode and forbids it for identified builds.
        return allowsReducedAssurance ? .reducedAssuranceAdHocDevelopment : .sameTeam
    }
}
