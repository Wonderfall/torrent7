import Foundation
import Network

/// Converts the pinned DB-IP country CSV into disjoint, complete address maps.
/// Each record stores an inclusive upper bound and a two-byte country code.
/// The complete index is stored as an LZFSE-compressed resource.
struct CountryDatabaseBuilder {
    enum Failure: Error { case invalidInput }
    private struct Record {
        var end: UInt128
        let country: [UInt8]
    }

    static func build(csv: String, date: UInt32) throws -> Data {
        guard csv.utf8.count <= 80 * 1_024 * 1_024,
              (2026...2099).contains(date / 10_000),
              (1...12).contains(date / 100 % 100), date % 100 == 1 else {
            throw Failure.invalidInput
        }
        var ipv4 = [Record]()
        var ipv6 = [Record]()
        var count = 0
        for line in csv.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            count += 1
            guard count <= 1_000_000, line.utf8.count <= 128 else { throw Failure.invalidInput }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 3 else { throw Failure.invalidInput }
            let country = Array(fields[2].utf8)
            guard country.count == 2, country.allSatisfy({ (65...90).contains($0) }) else {
                throw Failure.invalidInput
            }
            let first = try address(String(fields[0]))
            let last = try address(String(fields[1]))
            guard first.count == last.count else { throw Failure.invalidInput }
            if first.count == 4 {
                try append(first: number(first), last: number(last), country: country, to: &ipv4)
            } else {
                try append(first: number(first), last: number(last), country: country, to: &ipv6)
            }
        }
        guard !ipv4.isEmpty, !ipv6.isEmpty else { throw Failure.invalidInput }
        finish(&ipv4, maximum: UInt128(UInt32.max))
        finish(&ipv6, maximum: .max)
        guard ipv4.count <= 1_000_000, ipv6.count <= 1_000_000 else { throw Failure.invalidInput }
        var data = Data("T7CCDB01".utf8)
        write(1, width: 4, to: &data)
        write(UInt128(date), width: 4, to: &data)
        write(UInt128(ipv4.count), width: 4, to: &data)
        write(UInt128(ipv6.count), width: 4, to: &data)
        for (records, width) in [(ipv4, 4), (ipv6, 16)] {
            for record in records {
                write(record.end, width: width, to: &data)
                data.append(contentsOf: record.country)
            }
        }
        return try (data as NSData).compressed(using: .lzfse) as Data
    }

    private static func address(_ text: String) throws -> Data {
        if let ipv4 = IPv4Address(text) { return ipv4.rawValue }
        if !text.contains("%"), let ipv6 = IPv6Address(text) { return ipv6.rawValue }
        throw Failure.invalidInput
    }

    private static func number(_ bytes: Data) -> UInt128 {
        bytes.reduce(0) { ($0 << 8) | UInt128($1) }
    }

    private static func append(first: UInt128, last: UInt128, country: [UInt8], to records: inout [Record]) throws {
        guard first <= last, records.last.map({ $0.end < first }) ?? true else {
            throw Failure.invalidInput
        }
        let next = records.last.map { $0.end + 1 } ?? 0
        if next < first { append(end: first - 1, country: [90, 90], to: &records) }
        append(end: last, country: country, to: &records)
    }

    private static func append(end: UInt128, country: [UInt8], to records: inout [Record]) {
        if records.last?.country == country { records[records.count - 1].end = end }
        else { records.append(Record(end: end, country: country)) }
    }

    private static func finish(_ records: inout [Record], maximum: UInt128) {
        if let last = records.last, last.end < maximum {
            append(end: maximum, country: [90, 90], to: &records)
        }
    }

    private static func write(_ value: UInt128, width: Int, to data: inout Data) {
        for offset in (0..<width).reversed() {
            data.append(UInt8(truncatingIfNeeded: value >> (offset * 8)))
        }
    }
}

@main
enum CountryDatabaseCommand {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let date = UInt32(arguments[3]) else {
            throw CountryDatabaseBuilder.Failure.invalidInput
        }
        let input = URL(filePath: arguments[1])
        let file = try FileHandle(forReadingFrom: input)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: 80 * 1_024 * 1_024 + 1) ?? Data()
        guard let csv = String(data: bytes, encoding: .utf8) else { throw CountryDatabaseBuilder.Failure.invalidInput }
        let data = try CountryDatabaseBuilder.build(csv: csv, date: date)
        try data.write(to: URL(filePath: arguments[2]), options: .atomic)
        print("Wrote \(data.count) bytes of country data.")
    }
}
