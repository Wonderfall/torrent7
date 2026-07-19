import Darwin
import Foundation
import Synchronization
import Testing
@testable import TorrentEngineServiceSupport

@Suite("Torrent folder descriptor authority lifecycle")
struct TorrentFolderCapabilityAuthorityLifecycleTests {
    @Test("A native lifetime anchor keeps a revoked root alive until native release")
    func nativeAnchorDefersRevokedRootRelease() throws {
        let temporary = try AuthorityLifecycleTemporaryDirectory()
        let bookmark = Data("download-root".utf8)
        let resource = AuthorityLifecycleScopedResource(url: temporary.url)
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            bookmarkResolver: AuthorityLifecycleBookmarkResolver([bookmark: resource])
        )
        let capability = try #require(registry.replaceCommittedGrants(
            bookmarkData: [bookmark],
            scope: scope
        ).first)
        var pin: TorrentFolderCapabilityPin? = try registry.pin(
            capabilityID: capability.id,
            scope: scope
        )
        let descriptor = try #require(pin).directoryFileDescriptor()
        var nativeAnchor: (any AnyObject & Sendable)? = pin?.accessLifetimeAnchor

        #expect(try registry.revoke(capabilityID: capability.id, scope: scope))
        pin = nil

        #expect(resource.snapshot == .init(startCount: 1, stopCount: 0))
        #expect(authorityLifecycleDescriptorIsOpen(descriptor))
        withExtendedLifetime(nativeAnchor) {}

        nativeAnchor = nil

        #expect(resource.snapshot == .init(startCount: 1, stopCount: 1))
        #expect(!authorityLifecycleDescriptorIsOpen(descriptor))
    }

    @Test("Replacement preserves displaced authority until disconnect invalidates every anchor")
    func replacementAndDisconnectInvalidateDisplacedAuthority() throws {
        let temporary = try AuthorityLifecycleTemporaryDirectory()
        let originalBookmark = Data("original".utf8)
        let replacementBookmark = Data("replacement".utf8)
        let originalResource = AuthorityLifecycleScopedResource(
            url: try temporary.makeDirectory("Original")
        )
        let replacementResource = AuthorityLifecycleScopedResource(
            url: try temporary.makeDirectory("Replacement")
        )
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            bookmarkResolver: AuthorityLifecycleBookmarkResolver([
                originalBookmark: originalResource,
                replacementBookmark: replacementResource,
            ])
        )
        let original = try #require(registry.replaceCommittedGrants(
            bookmarkData: [originalBookmark],
            scope: scope
        ).first)
        var originalPin: TorrentFolderCapabilityPin? = try registry.pin(
            capabilityID: original.id,
            scope: scope
        )
        let originalDescriptor = try #require(originalPin).directoryFileDescriptor()
        var originalNativeAnchor: (any AnyObject & Sendable)? = originalPin?.accessLifetimeAnchor
        #expect(originalNativeAnchor != nil)

        var prepared: TorrentFolderCapabilityReplacement? = try registry
            .prepareCommittedGrantReplacement(
                bookmarkData: [replacementBookmark],
                scope: scope
            )
        var replacementPin: TorrentFolderCapabilityPin? = try #require(prepared?.pins.first)
        let replacementDescriptor = try #require(replacementPin).directoryFileDescriptor()
        var replacementNativeAnchor: (any AnyObject & Sendable)? =
            replacementPin?.accessLifetimeAnchor
        #expect(replacementNativeAnchor != nil)
        let preparedValue = try #require(prepared)
        let replacement = try #require(registry.commit(preparedValue).first)
        prepared = nil

        #expect(try registry.capability(capabilityID: original.id, scope: scope) == nil)
        #expect(try registry.capability(capabilityID: replacement.id, scope: scope) == replacement)
        #expect(try registry.pins(scope: scope).map(\.capabilityID) == [replacement.id])
        #expect(originalResource.snapshot == .init(startCount: 1, stopCount: 0))
        #expect(replacementResource.snapshot == .init(startCount: 1, stopCount: 0))
        #expect(authorityLifecycleDescriptorIsOpen(originalDescriptor))
        #expect(authorityLifecycleDescriptorIsOpen(replacementDescriptor))

        // Model the service dropping its temporary pins after the bridge has
        // retained the lifetime anchors. The displaced root is now reachable
        // only through the native-style anchor and the registry's weak index.
        originalPin = nil
        replacementPin = nil
        registry.disconnect(scope: scope)

        #expect(!authorityLifecycleDescriptorIsOpen(originalDescriptor))
        #expect(!authorityLifecycleDescriptorIsOpen(replacementDescriptor))
        #expect(originalResource.snapshot == .init(startCount: 1, stopCount: 1))
        #expect(replacementResource.snapshot == .init(startCount: 1, stopCount: 1))

        originalNativeAnchor = nil
        replacementNativeAnchor = nil
        #expect(originalResource.snapshot.stopCount == 1)
        #expect(replacementResource.snapshot.stopCount == 1)
    }

    @Test("Disconnect start rejects retained authority before final teardown releases it")
    func disconnectStartInvalidatesPreparedAuthorityBeforeCleanup() throws {
        let temporary = try AuthorityLifecycleTemporaryDirectory()
        let bookmark = Data("prepared-root".utf8)
        let resource = AuthorityLifecycleScopedResource(url: temporary.url)
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            bookmarkResolver: AuthorityLifecycleBookmarkResolver([bookmark: resource])
        )
        let prepared = try registry.prepareCommittedGrantReplacement(
            bookmarkData: [bookmark],
            scope: scope
        )
        let pin = try #require(prepared.pins.first)
        let descriptor = try pin.directoryFileDescriptor()
        let nativeAnchor = pin.accessLifetimeAnchor

        #expect(resource.snapshot == .init(startCount: 1, stopCount: 0))
        #expect(pin.isValid)
        #expect(authorityLifecycleDescriptorIsOpen(descriptor))

        // Models TorrentEngineServiceRuntime.beginDisconnect. The shared,
        // one-way token rejects every retained view immediately, but native
        // teardown can still use the already-installed descriptor authority.
        scope.invalidate()

        #expect(!pin.isValid)
        authorityLifecycleExpectError(.capabilityInvalidated) {
            _ = try pin.directoryFileDescriptor()
        }
        authorityLifecycleExpectError(.controllerDisconnected) {
            _ = try registry.commit(prepared)
        }
        #expect(resource.snapshot == .init(startCount: 1, stopCount: 0))
        #expect(authorityLifecycleDescriptorIsOpen(descriptor))

        // Models final teardown after the native engine has stopped. Prepared
        // candidates are not published, so the registry's weak exact-scope
        // index is what makes this retained access discoverable for cleanup.
        registry.disconnect(scope: scope)

        #expect(resource.snapshot == .init(startCount: 1, stopCount: 1))
        #expect(!authorityLifecycleDescriptorIsOpen(descriptor))
        withExtendedLifetime(nativeAnchor) {}
        withExtendedLifetime(prepared) {}
    }

    @Test("A fresh generation may reuse a disconnected controller's wire identifier")
    func freshGenerationMayReuseWireControllerID() throws {
        let temporary = try AuthorityLifecycleTemporaryDirectory()
        let oldBookmark = Data("old-generation".utf8)
        let freshBookmark = Data("fresh-generation".utf8)
        let oldResource = AuthorityLifecycleScopedResource(
            url: try temporary.makeDirectory("OldGeneration")
        )
        let freshResource = AuthorityLifecycleScopedResource(
            url: try temporary.makeDirectory("FreshGeneration")
        )
        let epoch = UUID()
        let controllerID = UUID()
        let oldScope = TorrentEngineServiceScope(
            engineEpoch: epoch,
            controllerID: controllerID
        )
        let freshScope = TorrentEngineServiceScope(
            engineEpoch: epoch,
            controllerID: controllerID
        )
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            bookmarkResolver: AuthorityLifecycleBookmarkResolver([
                oldBookmark: oldResource,
                freshBookmark: freshResource,
            ])
        )
        let oldCapability = try #require(registry.replaceCommittedGrants(
            bookmarkData: [oldBookmark],
            scope: oldScope
        ).first)
        let oldPin = try registry.pin(capabilityID: oldCapability.id, scope: oldScope)
        let oldDescriptor = try oldPin.directoryFileDescriptor()
        let freshCapability = try #require(registry.replaceCommittedGrants(
            bookmarkData: [freshBookmark],
            scope: freshScope
        ).first)
        let freshPin = try registry.pin(
            capabilityID: freshCapability.id,
            scope: freshScope
        )
        let freshDescriptor = try freshPin.directoryFileDescriptor()

        #expect(oldScope.controllerID == freshScope.controllerID)
        #expect(oldScope.generation != freshScope.generation)
        #expect(oldPin.isValid)
        #expect(freshPin.isValid)

        oldScope.invalidate()
        authorityLifecycleExpectError(.controllerDisconnected) {
            _ = try registry.pin(capabilityID: oldCapability.id, scope: oldScope)
        }
        #expect(!oldPin.isValid)
        #expect(freshPin.isValid)
        #expect(authorityLifecycleDescriptorIsOpen(oldDescriptor))
        #expect(authorityLifecycleDescriptorIsOpen(freshDescriptor))

        registry.disconnect(scope: oldScope)

        #expect(!authorityLifecycleDescriptorIsOpen(oldDescriptor))
        #expect(authorityLifecycleDescriptorIsOpen(freshDescriptor))
        #expect(oldResource.snapshot == .init(startCount: 1, stopCount: 1))
        #expect(freshResource.snapshot == .init(startCount: 1, stopCount: 0))
        #expect(freshPin.isValid)
        #expect(freshCapability.scope == freshScope)
        #expect(registry.capabilities(scope: oldScope).isEmpty)
        #expect(registry.capabilities(scope: freshScope) == [freshCapability])

        registry.disconnect(scope: freshScope)
        #expect(!authorityLifecycleDescriptorIsOpen(freshDescriptor))
        #expect(freshResource.snapshot == .init(startCount: 1, stopCount: 1))
    }

    @Test("Successful restart handoff releases only the superseded native root")
    func successfulRestartAuthorityHandoff() throws {
        let temporary = try AuthorityLifecycleTemporaryDirectory()
        let oldBookmark = Data("old-root".utf8)
        let newBookmark = Data("new-root".utf8)
        let oldResource = AuthorityLifecycleScopedResource(
            url: try temporary.makeDirectory("Old")
        )
        let newResource = AuthorityLifecycleScopedResource(
            url: try temporary.makeDirectory("New")
        )
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            bookmarkResolver: AuthorityLifecycleBookmarkResolver([
                oldBookmark: oldResource,
                newBookmark: newResource,
            ])
        )
        let oldCapability = try #require(registry.replaceCommittedGrants(
            bookmarkData: [oldBookmark],
            scope: scope
        ).first)
        var oldPin: TorrentFolderCapabilityPin? = try registry.pin(
            capabilityID: oldCapability.id,
            scope: scope
        )
        let oldDescriptor = try #require(oldPin).directoryFileDescriptor()
        var oldNativeAnchor: (any AnyObject & Sendable)? = oldPin?.accessLifetimeAnchor
        #expect(oldNativeAnchor != nil)
        oldPin = nil

        let newCapability = try registry.grantProvisional(
            bookmarkData: newBookmark,
            scope: scope
        )
        var restartPin: TorrentFolderCapabilityPin? = try registry.pin(
            capabilityID: newCapability.id,
            scope: scope
        )
        let newDescriptor = try #require(restartPin).directoryFileDescriptor()
        var newNativeAnchor: (any AnyObject & Sendable)? = restartPin?.accessLifetimeAnchor
        #expect(newNativeAnchor != nil)
        restartPin = nil

        // This is the registry half of the runtime's successful restart order:
        // install the new native root snapshot, then commit it and revoke roots
        // omitted from that snapshot.
        _ = try registry.commit(capabilityID: newCapability.id, scope: scope)
        #expect(try registry.revoke(capabilityID: oldCapability.id, scope: scope))

        #expect(authorityLifecycleDescriptorIsOpen(oldDescriptor))
        #expect(authorityLifecycleDescriptorIsOpen(newDescriptor))
        #expect(oldResource.snapshot.stopCount == 0)
        #expect(newResource.snapshot.stopCount == 0)

        oldNativeAnchor = nil

        #expect(!authorityLifecycleDescriptorIsOpen(oldDescriptor))
        #expect(oldResource.snapshot.stopCount == 1)
        #expect(authorityLifecycleDescriptorIsOpen(newDescriptor))
        #expect(newResource.snapshot.stopCount == 0)
        #expect(try registry.pins(scope: scope).map(\.capabilityID) == [newCapability.id])

        newNativeAnchor = nil
        #expect(authorityLifecycleDescriptorIsOpen(newDescriptor))
        registry.disconnect(scope: scope)
        #expect(!authorityLifecycleDescriptorIsOpen(newDescriptor))
        #expect(newResource.snapshot.stopCount == 1)
    }

    @Test("Service recovery never carries root authority across process epochs")
    func recoveryStartsWithFreshEpochAuthority() throws {
        let temporary = try AuthorityLifecycleTemporaryDirectory()
        let oldBookmark = Data("old-process".utf8)
        let freshBookmark = Data("fresh-process".utf8)
        let oldResource = AuthorityLifecycleScopedResource(url: temporary.url)
        let oldEpoch = UUID()
        let controllerID = UUID()
        let oldScope = TorrentEngineServiceScope(
            engineEpoch: oldEpoch,
            controllerID: controllerID
        )
        var oldRegistry: TorrentFolderCapabilityRegistry? = TorrentFolderCapabilityRegistry(
            engineEpoch: oldEpoch,
            bookmarkResolver: AuthorityLifecycleBookmarkResolver([oldBookmark: oldResource])
        )
        let oldCapability = try #require(oldRegistry?.replaceCommittedGrants(
            bookmarkData: [oldBookmark],
            scope: oldScope
        ).first)
        var oldPin: TorrentFolderCapabilityPin? = try oldRegistry?.pin(
            capabilityID: oldCapability.id,
            scope: oldScope
        )
        let oldDescriptor = try #require(oldPin).directoryFileDescriptor()
        var oldNativeAnchor: (any AnyObject & Sendable)? = oldPin?.accessLifetimeAnchor
        #expect(oldNativeAnchor != nil)
        oldPin = nil

        oldRegistry = nil

        #expect(!authorityLifecycleDescriptorIsOpen(oldDescriptor))
        #expect(oldResource.snapshot == .init(startCount: 1, stopCount: 1))

        let freshResource = AuthorityLifecycleScopedResource(url: temporary.url)
        let freshEpoch = UUID()
        let freshScope = TorrentEngineServiceScope(
            engineEpoch: freshEpoch,
            controllerID: controllerID
        )
        let freshRegistry = TorrentFolderCapabilityRegistry(
            engineEpoch: freshEpoch,
            bookmarkResolver: AuthorityLifecycleBookmarkResolver([
                freshBookmark: freshResource,
            ])
        )
        authorityLifecycleExpectError(.wrongEngineEpoch) {
            _ = try freshRegistry.replaceCommittedGrants(
                bookmarkData: [freshBookmark],
                scope: oldScope
            )
        }
        let freshCapability = try #require(freshRegistry.replaceCommittedGrants(
            bookmarkData: [freshBookmark],
            scope: freshScope
        ).first)
        let freshPin = try freshRegistry.pin(
            capabilityID: freshCapability.id,
            scope: freshScope
        )
        #expect(freshPin.isValid)
        #expect(authorityLifecycleDescriptorIsOpen(try freshPin.directoryFileDescriptor()))

        oldNativeAnchor = nil
        #expect(oldResource.snapshot.stopCount == 1)
        freshRegistry.disconnect(scope: freshScope)
        #expect(!freshPin.isValid)
        #expect(freshResource.snapshot == .init(startCount: 1, stopCount: 1))
    }
}

private final class AuthorityLifecycleScopedResource:
    TorrentSecurityScopedResourceAccessing,
    @unchecked Sendable
{
    struct Snapshot: Equatable, Sendable {
        var startCount = 0
        var stopCount = 0
    }

    let url: URL
    let bookmarkDataIsStale = false
    private let state = Mutex(Snapshot())

    init(url: URL) {
        self.url = url
    }

    func startAccessingSecurityScopedResource() -> Bool {
        state.withLock { $0.startCount += 1 }
        return true
    }

    func stopAccessingSecurityScopedResource() {
        state.withLock { $0.stopCount += 1 }
    }

    var snapshot: Snapshot {
        state.withLock { $0 }
    }
}

private final class AuthorityLifecycleBookmarkResolver:
    TorrentFolderBookmarkResolving,
    @unchecked Sendable
{
    private let resourcesByBookmark: [Data: AuthorityLifecycleScopedResource]

    init(_ resourcesByBookmark: [Data: AuthorityLifecycleScopedResource]) {
        self.resourcesByBookmark = resourcesByBookmark
    }

    func resolve(
        bookmarkData: Data
    ) throws -> any TorrentSecurityScopedResourceAccessing {
        guard let resource = resourcesByBookmark[bookmarkData] else {
            throw AuthorityLifecycleTestError.missingBookmark
        }
        return resource
    }
}

private enum AuthorityLifecycleTestError: Error {
    case missingBookmark
}

private final class AuthorityLifecycleTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "TorrentAuthorityLifecycleTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func makeDirectory(_ name: String) throws -> URL {
        let child = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return child
    }
}

private func authorityLifecycleExpectError(
    _ expected: TorrentFolderCapabilityError,
    performing operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected capability error: \(expected)")
    } catch let error as TorrentFolderCapabilityError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func authorityLifecycleDescriptorIsOpen(_ descriptor: Int32) -> Bool {
    Darwin.fcntl(descriptor, F_GETFD) != -1
}
