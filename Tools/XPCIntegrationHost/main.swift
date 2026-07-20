import AppKit
import Foundation
import TorrentEngineClient
import TorrentEngineModel

private enum IntegrationFailure: LocalizedError {
    case invalidArguments
    case bookmarkScopeUnavailable
    case folderSelectionFailed
    case unexpectedFolderSelection(expected: String, actual: String)
    case unexpectedLibtorrentVersion(String)
    case unavailableClient(String)
    case duplicateTorrentIdentifier
    case networkWasNotBlocked(String)
    case snapshotCount(phase: String, actual: Int, expected: Int)
    case trackerHostCount(phase: String, actual: Int, expected: Int)
    case torrentIdentityMismatch(String)
    case trackerIdentityMismatch(String)
    case torrentWasNotPaused(String)
    case unexpectedEngineAlerts(phase: String, count: Int)
    case applicationRunLoopStopped
    case malformedBookmarkWasAccepted
    case malformedBookmarkUnexpectedError(String)
    case forcedExitCoordinationTimedOut
    case forcedExitWasNotObserved
    case missingNetworkInterfaces(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Usage: TorrentEngineXPCIntegrationHost --automated | --count <1...20000> --download-root <absolute path>"
        case .bookmarkScopeUnavailable:
            "The integration download folder could not acquire a security scope."
        case .folderSelectionFailed:
            "The integration download folder could not be selected through the system open panel."
        case .unexpectedFolderSelection(let expected, let actual):
            "The integration selected \(actual) instead of the required test root \(expected)."
        case .unexpectedLibtorrentVersion(let version):
            "The integration service reported unexpected libtorrent version \(version)."
        case .unavailableClient(let phase):
            "The integration client was unavailable during \(phase)."
        case .duplicateTorrentIdentifier:
            "The integration service returned a duplicate torrent identifier."
        case .networkWasNotBlocked(let phase):
            "The integration service exposed network access during \(phase)."
        case .snapshotCount(let phase, let actual, let expected):
            "The \(phase) poll returned \(actual) torrents instead of \(expected)."
        case .trackerHostCount(let phase, let actual, let expected):
            "The \(phase) poll returned \(actual) tracker hosts instead of \(expected)."
        case .torrentIdentityMismatch(let phase):
            "The \(phase) poll returned a different torrent identity set."
        case .trackerIdentityMismatch(let phase):
            "The \(phase) poll returned a different tracker-host identity set."
        case .torrentWasNotPaused(let phase):
            "The \(phase) poll returned a torrent that was not paused."
        case .unexpectedEngineAlerts(let phase, let count):
            "The \(phase) poll returned \(count) unexpected engine alert errors."
        case .applicationRunLoopStopped:
            "The integration application run loop stopped before the test completed."
        case .malformedBookmarkWasAccepted:
            "The service accepted a malformed nonempty folder bookmark."
        case .malformedBookmarkUnexpectedError(let description):
            "The malformed bookmark failed outside service authorization: \(description)"
        case .forcedExitCoordinationTimedOut:
            "The integration runner did not force the engine helper to exit in time."
        case .forcedExitWasNotObserved:
            "The client did not observe the forced engine-helper exit."
        case .missingNetworkInterfaces(let phase):
            "The \(phase) poll did not return any locally observed network interfaces."
        }
    }
}

private struct IntegrationConfiguration {
    enum Mode {
        case automated
        case dataset(count: Int, downloadRoot: URL)
    }

    let mode: Mode

    init(arguments: [String]) throws {
        if arguments.count == 2, arguments[1] == "--automated" {
            mode = .automated
            return
        }

        guard arguments.count == 5,
              arguments[1] == "--count",
              let count = Int(arguments[2]),
              (1...TorrentEngineLimits.maximumTorrentSnapshotCount).contains(count),
              arguments[3] == "--download-root",
              arguments[4].hasPrefix("/") else {
            throw IntegrationFailure.invalidArguments
        }
        mode = .dataset(
            count: count,
            downloadRoot: URL(
                filePath: arguments[4],
                directoryHint: .isDirectory
            ).standardizedFileURL
        )
    }
}

private struct IntegrationFolder {
    let url: URL
    let scopedURL: URL
    let authorization: TorrentFolderAuthorization

    @MainActor
    static func create(downloadRoot: URL) async throws -> IntegrationFolder {
        let fileManager = FileManager.default
        let expectedSelection = downloadRoot.standardizedFileURL
        let scopedURL = try await selectWithPowerbox(expectedSelection)
        let selectedCanonicalURL = scopedURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard selectedCanonicalURL == expectedSelection else {
            throw IntegrationFailure.unexpectedFolderSelection(
                expected: expectedSelection.path(percentEncoded: false),
                actual: selectedCanonicalURL.path(percentEncoded: false)
            )
        }
        guard scopedURL.startAccessingSecurityScopedResource() else {
            throw IntegrationFailure.bookmarkScopeUnavailable
        }

        let directory = selectedCanonicalURL.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let canonicalURL = directory.standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL

            // Match the production cross-process artifact: delegate only the
            // currently active Powerbox extension to the service. Persistent
            // app-scoped bookmark ownership remains a GUI responsibility.
            let delegationBookmark = try canonicalURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return IntegrationFolder(
                url: canonicalURL,
                scopedURL: scopedURL,
                authorization: TorrentFolderAuthorization(
                    path: canonicalURL.path(percentEncoded: false),
                    bookmarkData: delegationBookmark
                )
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            scopedURL.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    @MainActor
    private static func selectWithPowerbox(_ directory: URL) async throws -> URL {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directory
        panel.prompt = "Authorize Integration Folder"
        panel.message = "Authorizing an isolated folder for the Enhanced Security extension test."

        // Bring the explicitly interactive merge gate to the foreground. The
        // user must still approve the exact folder in the system-owned panel.
        NSApplication.shared.activate()
        return try await withCheckedThrowingContinuation { continuation in
            panel.begin { response in
                guard response == .OK, let selectedURL = panel.urls.first else {
                    continuation.resume(
                        throwing: IntegrationFailure.folderSelectionFailed
                    )
                    return
                }
                continuation.resume(returning: selectedURL)
            }
        }
    }

    func release() {
        try? FileManager.default.removeItem(at: url)
        scopedURL.stopAccessingSecurityScopedResource()
    }
}

@MainActor
private final class IntegrationRunState {
    var result: Result<Void, any Error>?
}

@main
@MainActor
private enum TorrentEngineXPCIntegrationHost {
    private static let trackerHost = "tracker.invalid"
    private static let realisticTorrentCount = 512
    private static let clock = ContinuousClock()
    private static let recoveryMarkerDirectoryName = "Torrent7EnhancedSecurityIntegration"

    static func main() throws {
        let state = IntegrationRunState()
        Task { @MainActor in
            do {
                try await runIntegration()
                state.result = .success(())
            } catch {
                state.result = .failure(error)
            }
            stopApplicationRunLoop()
        }
        NSApplication.shared.run()

        guard let result = state.result else {
            throw IntegrationFailure.applicationRunLoopStopped
        }
        try result.get()
    }

    private static func runIntegration() async throws {
        let configuration = try IntegrationConfiguration(
            arguments: CommandLine.arguments
        )
        print("integration.clock=ContinuousClock")
        print("integration.host_bundle=\(Bundle.main.bundleIdentifier ?? "missing")")

        switch configuration.mode {
        case .automated:
            print("integration.mode=automated")
            print("integration.torrent_count=0")
            try await runAutomatedLifecycle()
        case .dataset(let count, let downloadRoot):
            print("integration.mode=dataset")
            print("integration.torrent_count=\(count)")
            try await runDataset(count: count, downloadRoot: downloadRoot)
        }
        print("integration.result=pass")
    }

    private static func runDataset(count: Int, downloadRoot: URL) async throws {
        let folder = try await IntegrationFolder.create(
            downloadRoot: downloadRoot
        )
        defer {
            folder.release()
        }
        print("integration.download_directory=\(folder.authorization.path)")
        let totalStart = clock.now

        var expectedIDs = Set<String>(minimumCapacity: count)
        let client = try await measure("connect") {
            try await connect([folder.authorization])
        }
        try requireAvailable(client, phase: "initial connection")

        let firstCheckpoint = count == TorrentEngineLimits.maximumTorrentSnapshotCount
            ? realisticTorrentCount
            : count
        let initialAddLabel = count == TorrentEngineLimits.maximumTorrentSnapshotCount
            ? "add_paused_magnets_to_realistic"
            : "add_paused_magnets"
        let initialIDs = try await measure(initialAddLabel) {
            try await addMagnets(
                0..<firstCheckpoint,
                client: client,
                savePath: folder.authorization.path,
                totalCount: count
            )
        }
        guard expectedIDs.isDisjoint(with: initialIDs) else {
            throw IntegrationFailure.duplicateTorrentIdentifier
        }
        expectedIDs.formUnion(initialIDs)

        if count == TorrentEngineLimits.maximumTorrentSnapshotCount {
            try await measure("poll_paged_realistic") {
                try await verifyPoll(
                    client,
                    phase: "realistic paged poll",
                    expectedIDs: expectedIDs,
                    expectedCount: realisticTorrentCount
                )
            }

            let maximumIDs = try await measure("add_paused_magnets_to_maximum") {
                try await addMagnets(
                    realisticTorrentCount..<count,
                    client: client,
                    savePath: folder.authorization.path,
                    totalCount: count
                )
            }
            guard expectedIDs.isDisjoint(with: maximumIDs) else {
                throw IntegrationFailure.duplicateTorrentIdentifier
            }
            expectedIDs.formUnion(maximumIDs)
        }

        let initialPollLabel = count == TorrentEngineLimits.maximumTorrentSnapshotCount
            ? "poll_paged_maximum"
            : "poll_paged_initial"
        try await measure(initialPollLabel) {
            try await verifyPoll(
                client,
                phase: count == TorrentEngineLimits.maximumTorrentSnapshotCount
                    ? "maximum paged poll"
                    : "initial paged poll",
                expectedIDs: expectedIDs,
                expectedCount: count
            )
        }

        try await measure("restart") {
            try await client.restart(
                enablePeerExchangePlugin: false,
                authorizedSavePaths: [folder.authorization.path]
            )
        }
        try requireAvailable(client, phase: "restart")
        try await measure("poll_paged_after_restart") {
            try await verifyPoll(
                client,
                phase: "post-restart paged poll",
                expectedIDs: expectedIDs,
                expectedCount: count
            )
        }

        await measure("shutdown") {
            await client.shutdown()
        }

        let reconnected = try await measure("reconnect") {
            try await connect(
                [folder.authorization],
                retryMode: .replacingTerminatedController
            )
        }
        try requireAvailable(reconnected, phase: "reconnection")
        try await measure("poll_paged_after_reconnect") {
            try await verifyPoll(
                reconnected,
                phase: "post-reconnect paged poll",
                expectedIDs: expectedIDs,
                expectedCount: count
            )
        }
        await measure("final_shutdown") {
            await reconnected.shutdown()
        }

        printTiming("total", duration: totalStart.duration(to: clock.now))
    }

    private static func runAutomatedLifecycle() async throws {
        let totalStart = clock.now
        let expectedIDs = Set<String>()
        let initialClient = try await measure("connect") {
            try await connect([])
        }
        try requireAvailable(initialClient, phase: "automated initial connection")

        try await measure("poll_empty_initial") {
            try await verifyPoll(
                initialClient,
                phase: "automated initial empty poll",
                expectedIDs: expectedIDs,
                expectedCount: 0
            )
        }
        try await measure("force_helper_exit") {
            try await coordinateForcedHelperExit(client: initialClient)
        }
        await initialClient.shutdown()

        let client = try await measure("recover_after_forced_exit") {
            try await connect([], retryMode: .replacingTerminatedController)
        }
        try requireAvailable(client, phase: "automated forced-exit recovery")
        try await measure("poll_empty_after_forced_exit") {
            try await verifyPoll(
                client,
                phase: "automated post-forced-exit empty poll",
                expectedIDs: expectedIDs,
                expectedCount: 0
            )
        }
        try await measure("restart") {
            try await client.restart(
                enablePeerExchangePlugin: false,
                authorizedSavePaths: []
            )
        }
        try requireAvailable(client, phase: "automated restart")
        try await measure("poll_empty_after_restart") {
            try await verifyPoll(
                client,
                phase: "automated post-restart empty poll",
                expectedIDs: expectedIDs,
                expectedCount: 0
            )
        }
        await measure("shutdown") {
            await client.shutdown()
        }

        let reconnected = try await measure("reconnect") {
            try await connect([], retryMode: .replacingTerminatedController)
        }
        try requireAvailable(
            reconnected,
            phase: "automated reconnection"
        )
        try await measure("poll_empty_after_reconnect") {
            try await verifyPoll(
                reconnected,
                phase: "automated post-reconnect empty poll",
                expectedIDs: expectedIDs,
                expectedCount: 0
            )
        }
        await measure("final_shutdown") {
            await reconnected.shutdown()
        }

        try await measure("malformed_bookmark_rejection") {
            try await requireMalformedBookmarkRejection()
        }
        printTiming("total", duration: totalStart.duration(to: clock.now))
    }

    private static func coordinateForcedHelperExit(
        client: TorrentXPCClient
    ) async throws {
        let fileManager = FileManager.default
        let markerDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(
            path: recoveryMarkerDirectoryName,
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: markerDirectory,
            withIntermediateDirectories: true
        )
        let readyMarker = markerDirectory.appending(path: "ready")
        let killedMarker = markerDirectory.appending(path: "killed")
        try? fileManager.removeItem(at: readyMarker)
        try? fileManager.removeItem(at: killedMarker)
        guard fileManager.createFile(
            atPath: readyMarker.path(percentEncoded: false),
            contents: Data()
        ) else {
            throw IntegrationFailure.forcedExitCoordinationTimedOut
        }

        let coordinationDeadline = clock.now.advanced(by: .seconds(20))
        while !fileManager.fileExists(
            atPath: killedMarker.path(percentEncoded: false)
        ) {
            guard clock.now < coordinationDeadline else {
                throw IntegrationFailure.forcedExitCoordinationTimedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try? fileManager.removeItem(at: readyMarker)
        try? fileManager.removeItem(at: killedMarker)

        let interruptionDeadline = clock.now.advanced(by: .seconds(5))
        while client.isAvailable, clock.now < interruptionDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !client.isAvailable else {
            throw IntegrationFailure.forcedExitWasNotObserved
        }
        print("integration.forced_helper_exit=observed")
    }

    private static func requireMalformedBookmarkRejection() async throws {
        let malformedAuthorization = TorrentFolderAuthorization(
            path: "/private/tmp/Torrent7EnhancedSecurityInvalidBookmark",
            bookmarkData: Data("not-a-bookmark".utf8)
        )
        do {
            let unexpectedClient = try await TorrentXPCClient.connect(
                enablePeerExchangePlugin: false,
                folderAuthorizations: [malformedAuthorization],
                retryMode: .replacingTerminatedController
            )
            await unexpectedClient.shutdown()
            throw IntegrationFailure.malformedBookmarkWasAccepted
        } catch let failure as IntegrationFailure {
            throw failure
        } catch let clientError as TorrentEngineClientError {
            guard case .serviceRejected(let message) = clientError,
                  message == "The download folder authorization request is invalid." else {
                throw IntegrationFailure.malformedBookmarkUnexpectedError(
                    clientError.localizedDescription
                )
            }
            print("integration.malformed_bookmark=service_rejected")
        } catch {
            throw IntegrationFailure.malformedBookmarkUnexpectedError(
                error.localizedDescription
            )
        }
    }

    private static func stopApplicationRunLoop() {
        let application = NSApplication.shared
        application.stop(nil)
        guard let wakeEvent = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) else {
            return
        }
        application.postEvent(wakeEvent, atStart: false)
    }

    private static func addMagnets(
        _ indices: Range<Int>,
        client: TorrentXPCClient,
        savePath: String,
        totalCount: Int
    ) async throws -> Set<String> {
        var identifiers = Set<String>(minimumCapacity: indices.count)
        let progressInterval = max(1, totalCount / 10)
        for index in indices {
            let identifier = try await client.addMagnet(
                magnet(index: index),
                savePath: savePath,
                startsPaused: true,
                queuePriority: .normal,
                enablePeerExchange: false,
                allowNonHTTPSTrackers: false,
                allowNonHTTPSWebSeeds: false,
                allowPreMetadataDHT: false
            )
            guard identifiers.insert(identifier).inserted else {
                throw IntegrationFailure.duplicateTorrentIdentifier
            }
            let completed = index + 1
            if completed == indices.upperBound || completed.isMultiple(of: progressInterval) {
                print("integration.added=\(completed)")
            }
        }
        return identifiers
    }

    private static func connect(
        _ authorizations: [TorrentFolderAuthorization],
        retryMode: TorrentEngineConnectionRetryMode = .initial
    ) async throws -> TorrentXPCClient {
        let client = try await TorrentXPCClient.connect(
            enablePeerExchangePlugin: false,
            folderAuthorizations: authorizations,
            retryMode: retryMode
        )
        guard client.libtorrentVersion == "2.1.0.0" else {
            await client.shutdown()
            throw IntegrationFailure.unexpectedLibtorrentVersion(
                client.libtorrentVersion
            )
        }
        return client
    }

    private static func requireAvailable(
        _ client: TorrentXPCClient,
        phase: String
    ) throws {
        guard client.isAvailable else {
            throw IntegrationFailure.unavailableClient(phase)
        }
    }

    private static func verifyPoll(
        _ client: TorrentXPCClient,
        phase: String,
        expectedIDs: Set<String>,
        expectedCount: Int
    ) async throws {
        let result = try await client.poll(
            since: nil,
            sortedBy: .name,
            direction: .ascending,
            includeTrackerHosts: true
        )
        guard result.networkStatus.networkBlocked else {
            throw IntegrationFailure.networkWasNotBlocked(phase)
        }
        guard let networkInterfaces = result.networkInterfaceSnapshot?.interfaces,
              !networkInterfaces.isEmpty else {
            throw IntegrationFailure.missingNetworkInterfaces(phase)
        }
        let vpnInterfaceCount = networkInterfaces.lazy.filter(\.isLikelyVPN).count
        let phaseKey = phase.replacingOccurrences(of: " ", with: "_")
        print("integration.\(phaseKey).interfaces=\(networkInterfaces.count)")
        print("integration.\(phaseKey).vpn_interfaces=\(vpnInterfaceCount)")

        let torrents = result.snapshotBatch?.torrents ?? []
        guard torrents.count == expectedCount else {
            throw IntegrationFailure.snapshotCount(
                phase: phase,
                actual: torrents.count,
                expected: expectedCount
            )
        }
        guard Set(torrents.map(\.id)) == expectedIDs else {
            throw IntegrationFailure.torrentIdentityMismatch(phase)
        }
        guard torrents.allSatisfy(\.paused) else {
            throw IntegrationFailure.torrentWasNotPaused(phase)
        }

        let trackerHosts = result.trackerHostBatch?.hosts ?? []
        guard trackerHosts.count == expectedCount else {
            throw IntegrationFailure.trackerHostCount(
                phase: phase,
                actual: trackerHosts.count,
                expected: expectedCount
            )
        }
        guard Set(trackerHosts.map(\.torrentID)) == expectedIDs,
              trackerHosts.allSatisfy({ $0.host == trackerHost }) else {
            throw IntegrationFailure.trackerIdentityMismatch(phase)
        }
        print("integration.\(phaseKey).alerts=\(result.alertErrors.count)")
        for (index, alert) in result.alertErrors.enumerated() {
            print(
                "integration.\(phaseKey).alert_\(index)_base64="
                + Data(alert.utf8).base64EncodedString()
            )
        }
        guard result.alertErrors.isEmpty else {
            throw IntegrationFailure.unexpectedEngineAlerts(
                phase: phase,
                count: result.alertErrors.count
            )
        }
    }

    private static func magnet(index: Int) -> String {
        let unpaddedHash = String(index + 1, radix: 16, uppercase: false)
        let infoHash = String(
            repeating: "0",
            count: 40 - unpaddedHash.count
        ) + unpaddedHash
        return "magnet:?xt=urn:btih:\(infoHash)&dn=xpc-integration-\(index)&tr=https%3A%2F%2F\(trackerHost)%2Fannounce"
    }

    @discardableResult
    private static func measure<Value>(
        _ label: String,
        operation: () async throws -> Value
    ) async rethrows -> Value {
        let start = clock.now
        let value = try await operation()
        printTiming(label, duration: start.duration(to: clock.now))
        return value
    }

    private static func printTiming(_ label: String, duration: Duration) {
        let components = duration.components
        let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
        let attosecondsPerMicrosecond: Int64 = 1_000_000_000_000
        let wholeMilliseconds = (components.seconds * 1_000)
            + (components.attoseconds / attosecondsPerMillisecond)
        let microseconds = (components.attoseconds % attosecondsPerMillisecond)
            / attosecondsPerMicrosecond
        let unpaddedFraction = String(microseconds)
        let fraction = String(
            repeating: "0",
            count: 3 - unpaddedFraction.count
        ) + unpaddedFraction
        print("timing.\(label).milliseconds=\(wholeMilliseconds).\(fraction)")
    }
}
