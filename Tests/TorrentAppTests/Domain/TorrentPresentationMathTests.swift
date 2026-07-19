import Testing
@testable import TorrentApp

@Suite("Torrent presentation arithmetic")
struct TorrentPresentationMathTests {
    @Test("ETA calculation remains defined at the hostile reply limit")
    func etaCalculationHandlesInt64Limit() {
        #expect(TorrentPresentationMath.estimatedRemainingSeconds(
            totalWanted: Int64.max,
            totalDone: 0,
            downloadRate: 1
        ) == Int64.max)
        #expect(TorrentPresentationMath.estimatedRemainingSeconds(
            totalWanted: Int64.max,
            totalDone: 0,
            downloadRate: 2
        ) == (Int64.max / 2) + 1)
    }

    @Test("ETA calculation rejects values without a meaningful estimate")
    func etaCalculationRejectsInvalidInputs() {
        #expect(TorrentPresentationMath.estimatedRemainingSeconds(
            totalWanted: 100,
            totalDone: 100,
            downloadRate: 1
        ) == nil)
        #expect(TorrentPresentationMath.estimatedRemainingSeconds(
            totalWanted: 100,
            totalDone: 0,
            downloadRate: 0
        ) == nil)
        #expect(TorrentPresentationMath.estimatedRemainingSeconds(
            totalWanted: 100,
            totalDone: -1,
            downloadRate: 1
        ) == nil)
    }

    @Test("Selected file size saturates instead of overflowing")
    func selectedFileSizeSaturates() {
        #expect(TorrentPresentationMath.saturatingNonnegativeSum(
            [Int64.max, 1]
        ) == Int64.max)
        #expect(TorrentPresentationMath.saturatingNonnegativeSum(
            [-1, 20, 22]
        ) == 42)
    }
}
