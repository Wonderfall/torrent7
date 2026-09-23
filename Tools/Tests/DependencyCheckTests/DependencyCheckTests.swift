import Foundation
import Testing
@testable import DependencyCheck

@Suite struct DependencyCheckTests {
    private let head = "62fb8ab5bd611e4a9fbc54151adb951af1d45c72"
    private let mirrorHead = "cff1385e77b9b2095558fa625b3c35d589ffe09b"
    private let older = "81913f592dcbcfb3d636e3183d08fe5264fa1cb7"

    private func commit(_ sha: String, parent: String?) -> GitilesCommit {
        GitilesCommit(
            commit: sha,
            tree: "218549b41b2ab4490bd95d197785f3774d21baca",
            parents: parent.map { [$0] } ?? [],
            committer: .init(time: "Tue Sep 22 16:06:30 2026 -0700")
        )
    }

    @Test func officialHistoryIncludesPinAheadOfMirror() throws {
        let page = GitilesLog(
            log: [commit(head, parent: mirrorHead), commit(mirrorHead, parent: older)],
            next: older
        )
        try page.validate(startingAt: head)
        #expect(page.log.first?.commit == head)
        #expect(page.next == older)
    }

    @Test func followsPaginationToRoot() throws {
        let first = GitilesLog(log: [commit(head, parent: mirrorHead)], next: mirrorHead)
        try first.validate(startingAt: head)
        let next = try #require(first.next)
        let last = GitilesLog(log: [commit(mirrorHead, parent: nil)], next: nil)
        try last.validate(startingAt: next)
    }

    @Test func rejectsMissingOrWrongHead() {
        #expect(throws: (any Error).self) {
            try GitilesLog(log: [], next: nil).validate(startingAt: head)
        }
        #expect(throws: (any Error).self) {
            try GitilesLog(log: [commit(mirrorHead, parent: older)], next: older)
                .validate(startingAt: head)
        }
    }

    @Test func rejectsBrokenOrRepeatedHistory() {
        for second in [commit(older, parent: nil), commit(head, parent: nil)] {
            #expect(throws: (any Error).self) {
                try GitilesLog(log: [commit(head, parent: mirrorHead), second], next: nil)
                    .validate(startingAt: head)
            }
        }
    }

    @Test func rejectsCyclicHistory() {
        #expect(throws: (any Error).self) {
            try GitilesLog(log: [commit(head, parent: head)], next: head)
                .validate(startingAt: head)
        }
        #expect(throws: (any Error).self) {
            try GitilesLog(
                log: [commit(head, parent: mirrorHead), commit(mirrorHead, parent: head)],
                next: head
            ).validate(startingAt: head)
        }
    }

    @Test func rejectsOversizedPage() {
        #expect(throws: (any Error).self) {
            try GitilesLog(
                log: Array(repeating: commit(head, parent: head), count: GitilesLog.pageSize + 1),
                next: head
            ).validate(startingAt: head)
        }
    }

    @Test(arguments: ["", "../main", "HEAD", "abc", String(repeating: "G", count: 40)])
    func rejectsMalformedCommitIdentifiers(_ value: String) {
        #expect(throws: (any Error).self) {
            try GitilesLog(log: [commit(value, parent: nil)], next: nil)
                .validate(startingAt: value)
        }
        #expect(throws: (any Error).self) {
            try GitilesLog(log: [commit(head, parent: value)], next: value)
                .validate(startingAt: head)
        }
    }

    @Test func rejectsMissingOrUnrelatedContinuation() {
        for next in [nil, head, older] {
            #expect(throws: (any Error).self) {
                try GitilesLog(log: [commit(head, parent: mirrorHead)], next: next)
                    .validate(startingAt: head)
            }
        }
    }

    @Test(arguments: ["boost-1.92.0", "boost-1.91.0-1"])
    func acceptsStableBoostReleaseTags(_ tag: String) {
        let release = GitHubRelease(tagName: tag, publishedAt: "2026-08-12T11:41:32Z",
                                    prerelease: false, draft: false)
        #expect(release.stableBoostVersion == String(tag.dropFirst("boost-".count)))
    }

    @Test(arguments: ["boost-1.92.0.beta1", "boost-1.92.0-rc1", "1.92.0", "boost-1.92",
                      "boost-1.92.0junk", "boost-1.92.0/../../latest", ""])
    func ignoresNonReleaseBoostTags(_ tag: String) {
        // Boost's API currently marks beta tags as prerelease=false.
        let release = GitHubRelease(tagName: tag, publishedAt: "2026-08-12T11:41:32Z",
                                    prerelease: false, draft: false)
        #expect(release.stableBoostVersion == nil)
    }

    @Test func ignoresDraftAndPrereleaseBoostReleases() {
        for (draft, prerelease) in [(true, false), (false, true), (true, true)] {
            let release = GitHubRelease(tagName: "boost-1.92.0", publishedAt: "2026-08-12T11:41:32Z",
                                        prerelease: prerelease, draft: draft)
            #expect(release.stableBoostVersion == nil)
        }
    }
}
