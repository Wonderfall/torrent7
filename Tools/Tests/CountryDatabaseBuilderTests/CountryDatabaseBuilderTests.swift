import Foundation
import Testing
@testable import CountryDatabaseBuilder

@Suite("Country database generation")
struct CountryDatabaseBuilderTests {
    @Test("Ranges merge, gaps remain unknown and both address families are complete")
    func ranges() throws {
        let data = try CountryDatabaseBuilder.build(csv: """
        0.0.0.0,0.0.0.1,US
        0.0.0.2,0.0.0.3,US
        0.0.0.5,255.255.255.255,JP
        ::,::1,ZZ
        ::2,ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff,FR
        """, date: 20261001)
        #expect(data.count == 24 + 3 * 6 + 2 * 18)
        #expect(Array(data[16..<24]) == [0, 0, 0, 3, 0, 0, 0, 2])
        #expect(Array(data[24..<42]) == [0, 0, 0, 3, 85, 83, 0, 0, 0, 4, 90, 90, 255, 255, 255, 255, 74, 80])
    }

    @Test("Unknown gaps and tails coalesce with unknown input records")
    func unknownGaps() throws {
        let bytes = try CountryDatabaseBuilder.build(csv: "1.0.0.0,1.0.0.1,ZZ\n::1,::2,ZZ", date: 20261001)
        #expect(bytes.count == 24 + 6 + 18)
        #expect(Array(bytes[16..<24]) == [0, 0, 0, 1, 0, 0, 0, 1])
    }

    @Test("Malformed and overlapping upstream records fail closed", arguments: [
        "", "garbage", "0.0.0.0,::1,US", "0.0.0.2,0.0.0.1,US",
        "0.0.0.0,0.0.0.1,us", "0.0.0.0,0.0.0.1,USA",
        "0.0.0.0,0.0.0.1,US,extra", "fe80::1%3,fe80::2%3,US",
        "0.0.0.0,0.0.0.2,US\n0.0.0.2,0.0.0.3,JP",
        "0.0.0.0,255.255.255.255,US\n0.0.0.0,0.0.0.1,JP"
    ])
    func rejectsMalformed(_ csv: String) {
        #expect(throws: CountryDatabaseBuilder.Failure.self) {
            try CountryDatabaseBuilder.build(csv: csv, date: 20261001)
        }
    }

    @Test("Only a valid monthly release date is accepted", arguments: [20260001, 20261301, 20261002, 99999999])
    func date(_ date: UInt32) {
        #expect(throws: CountryDatabaseBuilder.Failure.self) {
            try CountryDatabaseBuilder.build(csv: "", date: date)
        }
    }
}
