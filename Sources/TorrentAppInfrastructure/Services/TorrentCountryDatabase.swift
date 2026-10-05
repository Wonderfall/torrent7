package import Foundation

/// Immutable country-only index. The signed bundle contains the data; no lookup
/// performs networking or needs location permission. See Documentation/PeerCountries.md.
package struct TorrentCountryDatabase: Sendable {
    package enum Failure: Error { case unavailable, invalidDatabase }
    private let data: Data
    private let ipv4Count: Int
    private let ipv6Count: Int
    private let ipv6Offset: Int
    package let date: UInt32

    // A process-wide immutable resource, initialized on loadBundled's executor.
    // A failure is retained too, so unavailable flags cannot cause repeated I/O.
    private static let bundled: Result<Self, Failure> = {
        guard let url = Bundle.main.url(forResource: "PeerCountries", withExtension: "bin") else {
            return .failure(.unavailable)
        }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let bytes = try file.read(upToCount: 32 * 1_024 * 1_024 + 1) ?? Data()
            return .success(try Self(data: bytes))
        } catch { return .failure(.invalidDatabase) }
    }()

    @concurrent
    package static func loadBundled() async throws -> Self {
        try Task.checkCancellation()
        let database = try bundled.get()
        try Task.checkCancellation()
        return database
    }

    package init(data: Data) throws {
        guard (24...32 * 1_024 * 1_024).contains(data.count),
              data.prefix(8) == Data("T7CCDB01".utf8) else { throw Failure.invalidDatabase }
        let bytes = Data(data) // Normalize collection indices, including sliced test inputs.
        guard Self.number(bytes, at: 8, width: 4) == 1 else { throw Failure.invalidDatabase }
        let date = UInt32(Self.number(bytes, at: 12, width: 4))
        guard (2026...2099).contains(date / 10_000),
              (1...12).contains(date / 100 % 100), date % 100 == 1 else { throw Failure.invalidDatabase }
        let v4 = Int(Self.number(bytes, at: 16, width: 4))
        let v6 = Int(Self.number(bytes, at: 20, width: 4))
        guard (1...1_000_000).contains(v4), (1...1_000_000).contains(v6),
              bytes.count == 24 + v4 * 6 + v6 * 18 else { throw Failure.invalidDatabase }
        let offset = 24 + v4 * 6
        try Self.validate(bytes, offset: 24, count: v4, width: 4)
        try Self.validate(bytes, offset: offset, count: v6, width: 16)
        self.data = bytes
        self.ipv4Count = v4
        self.ipv6Count = v6
        self.ipv6Offset = offset
        self.date = date
    }

    package func countryCode(for address: Data) -> String? {
        guard address.count == 4 || address.count == 16 else { return nil }
        // IPv4-mapped IPv6 addresses use the same country as their IPv4 address.
        if address.count == 16, address.prefix(10).allSatisfy({ $0 == 0 }),
           address.dropFirst(10).prefix(2).allSatisfy({ $0 == 255 }) {
            return countryCode(for: Data(address.suffix(4)))
        }
        guard !Self.isLocal(address), !Self.isReserved(address) else { return nil }
        let width = address.count
        let offset = width == 4 ? 24 : ipv6Offset
        let target = address.reduce(UInt128(0)) { ($0 << 8) | UInt128($1) }
        var low = 0
        var high = width == 4 ? ipv4Count : ipv6Count
        while low < high {
            let mid = low + (high - low) / 2
            if Self.number(data, at: offset + mid * (width + 2), width: width) < target {
                low = mid + 1
            } else { high = mid }
        }
        let start = offset + low * (width + 2) + width
        let code = String(decoding: data[start..<start + 2], as: UTF8.self)
        return code == "ZZ" ? nil : code
    }

    package static func isLocal(_ address: Data) -> Bool {
        let bytes = Array(address)
        if bytes.count == 16, bytes.prefix(10).allSatisfy({ $0 == 0 }),
           bytes[10] == 255, bytes[11] == 255 {
            return isLocal(Data(bytes.suffix(4)))
        }
        if bytes.count == 4 {
            return bytes[0] == 10 || bytes[0] == 127
                || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254)
                || (bytes[0] == 100 && (64...127).contains(bytes[1]))
        }
        guard bytes.count == 16 else { return false }
        return bytes[0] & 0xFE == 0xFC
            || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)
            || (bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1)
    }

    private static func isReserved(_ address: Data) -> Bool {
        let bytes = Array(address)
        if bytes.count == 4 {
            return bytes[0] == 0 || bytes[0] >= 224
                || (bytes[0] == 192 && bytes[1] == 0 && (bytes[2] == 0 || bytes[2] == 2))
                || (bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19))
                || (bytes[0] == 198 && bytes[1] == 51 && bytes[2] == 100)
                || (bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113)
        }
        guard bytes.count == 16 else { return true }
        // Only global unicast IPv6 receives a geographic label. Local, multicast,
        // unspecified and other special-use address spaces must remain unlabelled.
        return bytes[0] & 0xE0 != 0x20
            || bytes.prefix(4).elementsEqual([0x20, 0x01, 0x0D, 0xB8])
            || (bytes[0] == 0x3F && bytes[1] == 0xFF && bytes[2] & 0xF0 == 0)
    }

    private static func validate(_ data: Data, offset: Int, count: Int, width: Int) throws {
        var previous: UInt128?
        for index in 0..<count {
            let start = offset + index * (width + 2)
            let end = number(data, at: start, width: width)
            guard previous.map({ $0 < end }) ?? true,
                  (65...90).contains(data[start + width]),
                  (65...90).contains(data[start + width + 1]) else { throw Failure.invalidDatabase }
            previous = end
        }
        guard previous == (width == 4 ? UInt128(UInt32.max) : UInt128.max) else {
            throw Failure.invalidDatabase
        }
    }

    private static func number(_ data: Data, at start: Int, width: Int) -> UInt128 {
        data[start..<start + width].reduce(0) { ($0 << 8) | UInt128($1) }
    }
}
