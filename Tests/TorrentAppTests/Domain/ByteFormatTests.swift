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

    @Test("Dock rates consistently separate values from units")
    func dockRateFormattingSeparatesValuesFromUnits() {
        #expect(DockTransferRateFormat.string(143) == "143 B/s")
        #expect(DockTransferRateFormat.string(999) == "999 B/s")
        #expect(DockTransferRateFormat.string(1_000) == "1.0 K/s")
        #expect(DockTransferRateFormat.string(12_000_000) == "12 M/s")
    }
}
