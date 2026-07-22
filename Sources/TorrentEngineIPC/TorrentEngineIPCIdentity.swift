package struct TorrentEngineIPCIdentityPair: Equatable, Sendable {
    package let appIdentifier: String
    package let serviceIdentifier: String

    package var extensionPointIdentifier: String {
        "\(appIdentifier).\(TorrentEngineIPCIdentity.extensionPointName)"
    }

    package init(appIdentifier: String, serviceIdentifier: String) {
        self.appIdentifier = appIdentifier
        self.serviceIdentifier = serviceIdentifier
    }
}

package enum TorrentEngineIPCIdentity {
    package static let extensionPointName = "torrent-engine"

    package static let release = TorrentEngineIPCIdentityPair(
        appIdentifier: "app.torrent7",
        serviceIdentifier: "app.torrent7.engine"
    )
    package static let addressDiagnostics = TorrentEngineIPCIdentityPair(
        appIdentifier: "app.torrent7.asan",
        serviceIdentifier: "app.torrent7.asan.engine"
    )
    package static let threadDiagnostics = TorrentEngineIPCIdentityPair(
        appIdentifier: "app.torrent7.tsan",
        serviceIdentifier: "app.torrent7.tsan.engine"
    )
    // This pair exists only for the separately assembled ad-hoc integration
    // bundle. Production packaging never embeds either integration binary.
    package static let integration = TorrentEngineIPCIdentityPair(
        appIdentifier: "app.torrent7.integration",
        serviceIdentifier: "app.torrent7.integration.engine"
    )
    package static let addressIntegration = TorrentEngineIPCIdentityPair(
        appIdentifier: "app.torrent7.integration.asan",
        serviceIdentifier: "app.torrent7.integration.asan.engine"
    )
    package static let threadIntegration = TorrentEngineIPCIdentityPair(
        appIdentifier: "app.torrent7.integration.tsan",
        serviceIdentifier: "app.torrent7.integration.tsan.engine"
    )
    package static let reducedAssuranceInfoKey = "Torrent7AllowAdHocXPCPeer"

    package static func pair(appIdentifier: String?) -> TorrentEngineIPCIdentityPair? {
        switch appIdentifier {
        case release.appIdentifier:
            release
        case addressDiagnostics.appIdentifier:
            addressDiagnostics
        case threadDiagnostics.appIdentifier:
            threadDiagnostics
        case integration.appIdentifier:
            integration
        case addressIntegration.appIdentifier:
            addressIntegration
        case threadIntegration.appIdentifier:
            threadIntegration
        default:
            nil
        }
    }

    package static func pair(serviceIdentifier: String?) -> TorrentEngineIPCIdentityPair? {
        switch serviceIdentifier {
        case release.serviceIdentifier:
            release
        case addressDiagnostics.serviceIdentifier:
            addressDiagnostics
        case threadDiagnostics.serviceIdentifier:
            threadDiagnostics
        case integration.serviceIdentifier:
            integration
        case addressIntegration.serviceIdentifier:
            addressIntegration
        case threadIntegration.serviceIdentifier:
            threadIntegration
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
