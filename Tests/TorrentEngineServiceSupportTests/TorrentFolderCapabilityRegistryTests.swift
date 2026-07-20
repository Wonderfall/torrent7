import Darwin
import Foundation
import Testing
@testable import TorrentEngineServiceSupport

@Suite("Torrent folder capability registry")
struct TorrentFolderCapabilityRegistryTests {
    @Test("Delegation bookmark resolution is non-interactive, non-starting, and explicit")
    func implicitBookmarkResolutionContract() throws {
        #expect(TorrentFoundationFolderBookmarkResolver.resolutionOptions.contains(
            .withoutImplicitStartAccessing
        ))
        #expect(TorrentFoundationFolderBookmarkResolver.resolutionOptions.contains(.withoutUI))
        #expect(TorrentFoundationFolderBookmarkResolver.resolutionOptions.contains(.withoutMounting))
        #expect(!TorrentFoundationFolderBookmarkResolver.resolutionOptions.contains(
            .withSecurityScope
        ))

        let temporary = try TemporaryDirectory()
        let bookmark = Data("implicit-bookmark".utf8)
        let resource = TestScopedResource(url: temporary.url)
        let resolver = TestBookmarkResolver([bookmark: resource])
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            bookmarkResolver: resolver
        )

        let capability = try registry.grantProvisional(
            bookmarkData: bookmark,
            scope: scope
        )

        #expect(capability.state == .provisional)
        #expect(resource.startCount == 1)
        #expect(resource.stopCount == 0)
        registry.disconnect(scope: scope)
        #expect(resource.stopCount == 1)
    }

    @Test("Bookmark count, per-payload, and aggregate bounds run before resolution")
    func bookmarkBounds() throws {
        let temporary = try TemporaryDirectory()
        let oldBookmark = Data([1])
        let oldResource = TestScopedResource(url: temporary.url)
        let resolver = TestBookmarkResolver([oldBookmark: oldResource])
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            limits: TorrentFolderCapabilityLimits(
                maximumCapabilityCount: 2,
                maximumBookmarkBytes: 4,
                maximumAggregateBookmarkBytes: 6
            ),
            bookmarkResolver: resolver
        )
        let original = try registry.replaceCommittedGrants(
            bookmarkData: [oldBookmark],
            scope: scope
        )

        expectCapabilityError(.emptyBookmark) {
            _ = try registry.grantProvisional(bookmarkData: Data(), scope: scope)
        }
        expectCapabilityError(.bookmarkTooLarge(actual: 5, maximum: 4)) {
            _ = try registry.grantProvisional(bookmarkData: Data(repeating: 2, count: 5), scope: scope)
        }
        expectCapabilityError(.tooManyCapabilities(maximum: 2)) {
            _ = try registry.replaceCommittedGrants(
                bookmarkData: [Data([2]), Data([3]), Data([4])],
                scope: scope
            )
        }
        expectCapabilityError(.aggregateBookmarksTooLarge(maximum: 6)) {
            _ = try registry.replaceCommittedGrants(
                bookmarkData: [Data(repeating: 2, count: 4), Data(repeating: 3, count: 4)],
                scope: scope
            )
        }

        #expect(resolver.resolveCount == 1)
        #expect(try registry.capability(capabilityID: original[0].id, scope: scope) == original[0])
        #expect(oldResource.stopCount == 0)
    }

    @Test("Replacement resolves completely before atomically displacing old grants")
    func replacementIsAtomic() throws {
        let temporary = try TemporaryDirectory()
        let firstURL = try temporary.makeDirectory("First")
        let secondURL = try temporary.makeDirectory("Second")
        let regularFileURL = temporary.url.appending(path: "not-a-directory")
        try Data("file".utf8).write(to: regularFileURL)

        let firstBookmark = Data("first".utf8)
        let secondBookmark = Data("second".utf8)
        let invalidBookmark = Data("invalid".utf8)
        let firstResource = TestScopedResource(url: firstURL)
        let secondResource = TestScopedResource(url: secondURL)
        let invalidResource = TestScopedResource(url: regularFileURL)
        let resolver = TestBookmarkResolver([
            firstBookmark: firstResource,
            secondBookmark: secondResource,
            invalidBookmark: invalidResource,
        ])
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            bookmarkResolver: resolver
        )
        let original = try #require(registry.replaceCommittedGrants(
            bookmarkData: [firstBookmark],
            scope: scope
        ).first)

        expectCapabilityError(.directoryOpenFailed) {
            _ = try registry.replaceCommittedGrants(
                bookmarkData: [secondBookmark, invalidBookmark],
                scope: scope
            )
        }
        #expect(try registry.capability(capabilityID: original.id, scope: scope) == original)
        #expect(firstResource.stopCount == 0)
        #expect(secondResource.stopCount == 1)
        #expect(invalidResource.stopCount == 1)

        let replacement = try #require(registry.replaceCommittedGrants(
            bookmarkData: [secondBookmark],
            scope: scope
        ).first)
        #expect(replacement.state == .committed)
        #expect(replacement.canonicalPath == secondURL.path(percentEncoded: false))
        #expect(try registry.capability(capabilityID: original.id, scope: scope) == nil)
        #expect(firstResource.stopCount == 1)
        #expect(secondResource.startCount == 2)
        #expect(secondResource.stopCount == 1)
    }

    @Test("Prepared replacements retain candidates without publishing them")
    func preparedReplacementIsNotPublished() throws {
        let temporary = try TemporaryDirectory()
        let firstURL = try temporary.makeDirectory("First")
        let secondURL = try temporary.makeDirectory("Second")
        let firstBookmark = Data("first".utf8)
        let secondBookmark = Data("second".utf8)
        let firstResource = TestScopedResource(url: firstURL)
        let secondResource = TestScopedResource(url: secondURL)
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            bookmarkResolver: TestBookmarkResolver([
                firstBookmark: firstResource,
                secondBookmark: secondResource,
            ])
        )
        let original = try #require(registry.replaceCommittedGrants(
            bookmarkData: [firstBookmark],
            scope: scope
        ).first)

        var prepared: TorrentFolderCapabilityReplacement? =
            try registry.prepareCommittedGrantReplacement(
                bookmarkData: [secondBookmark],
                scope: scope
            )
        #expect(prepared?.pins.map(\.canonicalPath) == [secondURL.path(percentEncoded: false)])
        #expect(try registry.capability(capabilityID: original.id, scope: scope) == original)
        #expect(firstResource.stopCount == 0)
        #expect(secondResource.startCount == 1)
        #expect(secondResource.stopCount == 0)

        prepared = nil
        #expect(try registry.capability(capabilityID: original.id, scope: scope) == original)
        #expect(firstResource.stopCount == 0)
        #expect(secondResource.stopCount == 1)

        let replacement = try registry.prepareCommittedGrantReplacement(
            bookmarkData: [secondBookmark],
            scope: scope
        )
        let committed = try #require(registry.commit(replacement).first)
        #expect(committed.canonicalPath == secondURL.path(percentEncoded: false))
        #expect(try registry.capability(capabilityID: original.id, scope: scope) == nil)
        #expect(firstResource.stopCount == 1)
    }

    @Test("Identical committed replacements reuse the validated access context")
    func identicalReplacementReusesAccessContext() throws {
        let temporary = try TemporaryDirectory()
        let bookmark = Data("stable-bookmark".utf8)
        let resource = TestScopedResource(url: temporary.url)
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            bookmarkResolver: TestBookmarkResolver([bookmark: resource])
        )
        let original = try #require(registry.replaceCommittedGrants(
            bookmarkData: [bookmark],
            scope: scope
        ).first)
        let originalPin = try registry.pin(capabilityID: original.id, scope: scope)
        let originalAnchor = ObjectIdentifier(originalPin.accessLifetimeAnchor)

        let prepared = try registry.prepareCommittedGrantReplacement(
            bookmarkData: [bookmark],
            scope: scope
        )
        let replacementPin = try #require(prepared.pins.first)

        #expect(prepared.capabilities.first?.id == original.id)
        #expect(ObjectIdentifier(replacementPin.accessLifetimeAnchor) == originalAnchor)
        #expect(resource.startCount == 2)
        #expect(resource.stopCount == 1)

        let committed = try #require(registry.commit(prepared).first)
        #expect(committed.id == original.id)
        #expect(try registry.pins(scope: scope).first?.capabilityID == original.id)

        registry.disconnect(scope: scope)
        #expect(resource.stopCount == 2)
        #expect(!originalPin.isValid)
        #expect(!replacementPin.isValid)
    }

    @Test("Different bookmark bytes never reuse an existing access context")
    func distinctBookmarkDoesNotReuseAccessContext() throws {
        let temporary = try TemporaryDirectory()
        let originalBookmark = Data("original-bookmark".utf8)
        let replacementBookmark = Data("replacement-bookmark".utf8)
        let resource = TestScopedResource(url: temporary.url)
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            bookmarkResolver: TestBookmarkResolver([
                originalBookmark: resource,
                replacementBookmark: resource,
            ])
        )
        let original = try #require(registry.replaceCommittedGrants(
            bookmarkData: [originalBookmark],
            scope: scope
        ).first)
        let originalPin = try registry.pin(capabilityID: original.id, scope: scope)
        let originalAnchor = ObjectIdentifier(originalPin.accessLifetimeAnchor)

        let prepared = try registry.prepareCommittedGrantReplacement(
            bookmarkData: [replacementBookmark],
            scope: scope
        )
        let replacementPin = try #require(prepared.pins.first)

        #expect(prepared.capabilities.first?.id != original.id)
        #expect(ObjectIdentifier(replacementPin.accessLifetimeAnchor) != originalAnchor)
        #expect(resource.startCount == 2)
        #expect(resource.stopCount == 0)

        _ = try registry.commit(prepared)
        registry.disconnect(scope: scope)
        #expect(resource.stopCount == 2)
        #expect(!originalPin.isValid)
        #expect(!replacementPin.isValid)
    }

    @Test("A prepared replacement cannot overwrite an intervening registry change")
    func preparedReplacementDetectsInterveningChange() throws {
        let temporary = try TemporaryDirectory()
        let firstBookmark = Data("first".utf8)
        let secondBookmark = Data("second".utf8)
        let thirdBookmark = Data("third".utf8)
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            bookmarkResolver: TestBookmarkResolver([
                firstBookmark: TestScopedResource(url: try temporary.makeDirectory("First")),
                secondBookmark: TestScopedResource(url: try temporary.makeDirectory("Second")),
                thirdBookmark: TestScopedResource(url: try temporary.makeDirectory("Third")),
            ])
        )
        let original = try #require(registry.replaceCommittedGrants(
            bookmarkData: [firstBookmark],
            scope: scope
        ).first)
        let prepared = try registry.prepareCommittedGrantReplacement(
            bookmarkData: [secondBookmark],
            scope: scope
        )
        let intervening = try registry.grantProvisional(
            bookmarkData: thirdBookmark,
            scope: scope
        )

        expectCapabilityError(.staleReplacement) {
            _ = try registry.commit(prepared)
        }
        #expect(try registry.capability(capabilityID: original.id, scope: scope) == original)
        #expect(try registry.capability(capabilityID: intervening.id, scope: scope) == intervening)
    }

    @Test("Only exact canonical directories become capabilities")
    func exactCanonicalDirectoryValidation() throws {
        let temporary = try TemporaryDirectory()
        let directoryURL = try temporary.makeDirectory("Directory")
        let symlinkURL = temporary.url.appending(path: "Alias", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: directoryURL)
        let fileURL = temporary.url.appending(path: "File")
        try Data("file".utf8).write(to: fileURL)

        let directoryBookmark = Data("directory".utf8)
        let symlinkBookmark = Data("symlink".utf8)
        let fileBookmark = Data("file".utf8)
        let directoryResource = TestScopedResource(url: directoryURL)
        let symlinkResource = TestScopedResource(url: symlinkURL)
        let fileResource = TestScopedResource(url: fileURL)
        let resolver = TestBookmarkResolver([
            directoryBookmark: directoryResource,
            symlinkBookmark: symlinkResource,
            fileBookmark: fileResource,
        ])
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            bookmarkResolver: resolver
        )

        expectCapabilityError(.nonCanonicalDirectory) {
            _ = try registry.grantProvisional(bookmarkData: symlinkBookmark, scope: scope)
        }
        expectCapabilityError(.directoryOpenFailed) {
            _ = try registry.grantProvisional(bookmarkData: fileBookmark, scope: scope)
        }
        #expect(symlinkResource.stopCount == 1)
        #expect(fileResource.stopCount == 1)

        let capability = try registry.grantProvisional(
            bookmarkData: directoryBookmark,
            scope: scope
        )
        let pin = try registry.pin(capabilityID: capability.id, scope: scope)
        let snapshotPins = try registry.pins(scope: scope)
        var metadata = stat()
        #expect(unsafe Darwin.fstat(try pin.directoryFileDescriptor(), &metadata) == 0)
        #expect(snapshotPins.map(\.capabilityID) == [capability.id])
        #expect(snapshotPins.first?.isValid == true)
        #expect(capability.identity == TorrentFolderIdentity(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(truncatingIfNeeded: metadata.st_ino)
        ))
        #expect(capability.canonicalPath == directoryURL.path(percentEncoded: false))
    }

    @Test("Provisional grants commit idempotently and remain controller scoped")
    func commitAndScope() throws {
        let temporary = try TemporaryDirectory()
        let bookmark = Data("folder".utf8)
        let resolver = TestBookmarkResolver([
            bookmark: TestScopedResource(url: temporary.url),
        ])
        let epoch = UUID()
        let controllerID = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: controllerID)
        let wrongController = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let wrongEpoch = TorrentEngineServiceScope(engineEpoch: UUID(), controllerID: controllerID)
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            bookmarkResolver: resolver
        )
        let provisional = try registry.grantProvisional(bookmarkData: bookmark, scope: scope)

        expectCapabilityError(.unknownCapability) {
            _ = try registry.pin(capabilityID: provisional.id, scope: wrongController)
        }
        expectCapabilityError(.wrongEngineEpoch) {
            _ = try registry.commit(capabilityID: provisional.id, scope: wrongEpoch)
        }
        let committed = try registry.commit(capabilityID: provisional.id, scope: scope)
        #expect(committed.state == .committed)
        #expect(try registry.commit(capabilityID: provisional.id, scope: scope) == committed)
    }

    @Test("Revoke defers release through a pin, while disconnect force-invalidates it")
    func revokePinAndDisconnect() throws {
        let temporary = try TemporaryDirectory()
        let bookmark = Data("folder".utf8)
        let resource = TestScopedResource(url: temporary.url)
        let resolver = TestBookmarkResolver([bookmark: resource])
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            bookmarkResolver: resolver
        )
        let capability = try registry.grantProvisional(bookmarkData: bookmark, scope: scope)
        var pin: TorrentFolderCapabilityPin? = try registry.pin(
            capabilityID: capability.id,
            scope: scope
        )
        let descriptor = try #require(pin).directoryFileDescriptor()

        #expect(try registry.revoke(capabilityID: capability.id, scope: scope))
        #expect(resource.stopCount == 0)
        #expect(descriptorIsOpen(descriptor))
        expectCapabilityError(.unknownCapability) {
            _ = try registry.pin(capabilityID: capability.id, scope: scope)
        }

        registry.disconnect(scope: scope)
        #expect(resource.stopCount == 1)
        #expect(!descriptorIsOpen(descriptor))
        #expect(pin?.isValid == false)
        expectCapabilityError(.capabilityInvalidated) {
            _ = try pin?.directoryFileDescriptor()
        }
        expectCapabilityError(.controllerDisconnected) {
            _ = try registry.grantProvisional(bookmarkData: bookmark, scope: scope)
        }
        #expect(resource.startCount == 1)
        pin = nil
        #expect(resource.stopCount == 1)
        #expect(registry.capabilities(scope: scope).isEmpty)
    }

    @Test("Disconnect invalidates every access registered by a batch replacement")
    func disconnectInvalidatesBatchReplacement() throws {
        let temporary = try TemporaryDirectory()
        let firstBookmark = Data("first".utf8)
        let secondBookmark = Data("second".utf8)
        let firstResource = TestScopedResource(
            url: try temporary.makeDirectory("First")
        )
        let secondResource = TestScopedResource(
            url: try temporary.makeDirectory("Second")
        )
        let epoch = UUID()
        let scope = TorrentEngineServiceScope(engineEpoch: epoch, controllerID: UUID())
        let registry = TorrentFolderCapabilityRegistry(
            engineEpoch: epoch,
            bookmarkResolver: TestBookmarkResolver([
                firstBookmark: firstResource,
                secondBookmark: secondResource,
            ])
        )
        let capabilities = try registry.replaceCommittedGrants(
            bookmarkData: [firstBookmark, secondBookmark],
            scope: scope
        )
        let pins = try capabilities.map {
            try registry.pin(capabilityID: $0.id, scope: scope)
        }
        let descriptors = try pins.map { try $0.directoryFileDescriptor() }

        registry.disconnect(scope: scope)

        #expect(firstResource.stopCount == 1)
        #expect(secondResource.stopCount == 1)
        #expect(pins.allSatisfy { !$0.isValid })
        #expect(descriptors.allSatisfy { !descriptorIsOpen($0) })
    }
}

private final class TestScopedResource:
    TorrentSecurityScopedResourceAccessing,
    @unchecked Sendable
{
    let url: URL
    let bookmarkDataIsStale: Bool
    private let startsSuccessfully: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(
        url: URL,
        isStale: Bool = false,
        startsSuccessfully: Bool = true
    ) {
        self.url = url
        bookmarkDataIsStale = isStale
        self.startsSuccessfully = startsSuccessfully
    }

    func startAccessingSecurityScopedResource() -> Bool {
        startCount += 1
        return startsSuccessfully
    }

    func stopAccessingSecurityScopedResource() {
        stopCount += 1
    }
}

private final class TestBookmarkResolver: TorrentFolderBookmarkResolving, @unchecked Sendable {
    private let resourcesByBookmark: [Data: TestScopedResource]
    private(set) var resolveCount = 0

    init(_ resourcesByBookmark: [Data: TestScopedResource]) {
        self.resourcesByBookmark = resourcesByBookmark
    }

    func resolve(bookmarkData: Data) throws -> any TorrentSecurityScopedResourceAccessing {
        resolveCount += 1
        guard let resource = resourcesByBookmark[bookmarkData] else {
            throw TestBookmarkError.missing
        }
        return resource
    }
}

private enum TestBookmarkError: Error {
    case missing
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "TorrentEngineServiceSupportTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func makeDirectory(_ name: String) throws -> URL {
        let child = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        return child
    }
}

private func expectCapabilityError(
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

private func descriptorIsOpen(_ descriptor: Int32) -> Bool {
    Darwin.fcntl(descriptor, F_GETFD) != -1
}
