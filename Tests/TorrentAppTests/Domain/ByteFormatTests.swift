import Testing
@testable import TorrentApp

@Suite("Byte format")
struct ByteFormatTests {
    @Test("Rate formatting appends a per-second suffix")
    func rateFormattingAppendsPerSecondSuffix() {
        #expect(ByteFormat.size(0) == "0 KB")
        #expect(ByteFormat.rate(Int64(0)) == "0 KB/s")
        #expect(ByteFormat.rate(Int32(1_024)) == ByteFormat.rate(Int64(1_024)))
    }
}
