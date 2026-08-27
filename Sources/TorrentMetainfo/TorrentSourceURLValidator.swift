import Foundation
import TorrentEngineModel

/// Strict syntax validation shared by protocol-specific parsers. Network
/// admission remains a separate policy boundary.
enum TorrentSourceURLValidator {
    static func isValid(
        _ value: String,
        maximumBytes: Int,
        allowedSchemes: Set<String>
    ) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              !containsControlOrWhitespace(value),
              hasValidPercentEscapes(value),
              !value.contains("\\") else {
            return false
        }
        guard let schemeEnd = value.range(of: "://")?.lowerBound else {
            return false
        }
        let scheme = value[..<schemeEnd]
        guard allowedSchemes.contains(scheme.lowercased()) else {
            return false
        }

        let authorityStart = value.index(schemeEnd, offsetBy: 3)
        let authorityEnd = value[authorityStart...].firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? value.endIndex
        return isValidAuthority(value[authorityStart..<authorityEnd])
    }

    private static func isValidAuthority(_ authority: Substring) -> Bool {
        guard !authority.isEmpty else {
            return false
        }
        let hostAndPort: Substring
        if let atSign = authority.firstIndex(of: "@") {
            guard atSign != authority.startIndex,
                  !authority[authority.index(after: atSign)...].contains("@") else {
                return false
            }
            hostAndPort = authority[authority.index(after: atSign)...]
        } else {
            hostAndPort = authority
        }
        guard !hostAndPort.isEmpty else {
            return false
        }

        if hostAndPort.first == "[" {
            guard let closingBracket = hostAndPort.firstIndex(of: "]"),
                  closingBracket != hostAndPort.index(after: hostAndPort.startIndex) else {
                return false
            }
            let host = hostAndPort[hostAndPort.index(after: hostAndPort.startIndex)..<closingBracket]
            let suffix = hostAndPort[hostAndPort.index(after: closingBracket)...]
            guard host.utf8.count < TorrentEngineLimits.trackerHostCapacity,
                  isValidIPv6Host(host) else {
                return false
            }
            return suffix.isEmpty
                || (suffix.first == ":" && isValidPort(suffix.dropFirst()))
        }

        guard !hostAndPort.contains("["), !hostAndPort.contains("]") else {
            return false
        }
        if let colon = hostAndPort.firstIndex(of: ":") {
            guard !hostAndPort[hostAndPort.index(after: colon)...].contains(":") else {
                return false
            }
            return isValidDNSOrIPv4Host(hostAndPort[..<colon])
                && isValidPort(hostAndPort[hostAndPort.index(after: colon)...])
        }
        return isValidDNSOrIPv4Host(hostAndPort)
    }

    private static func isValidPort(_ port: Substring) -> Bool {
        !port.isEmpty
            && port.utf8.allSatisfy(isASCIIDigit)
            && UInt16(port).map { $0 != 0 } == true
    }

    private static func isValidDNSOrIPv4Host(_ host: Substring) -> Bool {
        guard !host.isEmpty,
              host.utf8.count < TorrentEngineLimits.trackerHostCapacity,
              !host.contains("%"),
              host.utf8.allSatisfy({
                  isASCIIAlpha($0) || isASCIIDigit($0) || $0 == 45 || $0 == 46
              }) else {
            return false
        }
        let withoutTrailingDot = host.last == "." ? host.dropLast() : host
        guard !withoutTrailingDot.isEmpty else {
            return false
        }
        if withoutTrailingDot.utf8.allSatisfy({ isASCIIDigit($0) || $0 == 46 }) {
            return isValidIPv4Address(withoutTrailingDot)
        }
        return withoutTrailingDot
            .split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { label in
                !label.isEmpty
                    && label.utf8.count <= 63
                    && label.first != "-"
                    && label.last != "-"
            }
    }

    private static func isValidIPv6Host(_ host: Substring) -> Bool {
        let zoneSeparator = host.range(of: "%25")
        let address: Substring
        if let zoneSeparator {
            guard host[zoneSeparator.upperBound...].range(of: "%25") == nil,
                  isValidIPv6Zone(host[zoneSeparator.upperBound...]) else {
                return false
            }
            address = host[..<zoneSeparator.lowerBound]
        } else {
            address = host
        }
        return !address.contains("%") && isValidIPv6Address(address)
    }

    private static func isValidIPv6Zone(_ zone: Substring) -> Bool {
        guard !zone.isEmpty else {
            return false
        }
        let bytes = Array(zone.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if isASCIIAlpha(byte) || isASCIIDigit(byte) || [45, 46, 95, 126].contains(byte) {
                index += 1
                continue
            }
            guard byte == UInt8(ascii: "%"),
                  index + 2 < bytes.count,
                  isASCIIHexDigit(bytes[index + 1]),
                  isASCIIHexDigit(bytes[index + 2]) else {
                return false
            }
            index += 3
        }
        return true
    }

    private static func isValidIPv6Address(_ address: Substring) -> Bool {
        guard !address.isEmpty else {
            return false
        }
        let compression = address.range(of: "::")
        if let compression, address[compression.upperBound...].contains("::") {
            return false
        }
        let left = compression.map { address[..<$0.lowerBound] } ?? address[...]
        let right = compression.map { address[$0.upperBound...] } ?? ""[...]
        guard let leftCount = ipv6GroupCount(left),
              let rightCount = ipv6GroupCount(right) else {
            return false
        }
        let groupCount = leftCount + rightCount
        return compression == nil ? groupCount == 8 : groupCount < 8
    }

    private static func ipv6GroupCount(_ side: Substring) -> Int? {
        guard !side.isEmpty else {
            return 0
        }
        let groups = side.split(separator: ":", omittingEmptySubsequences: false)
        guard groups.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        var count = 0
        for (index, group) in groups.enumerated() {
            if group.contains(".") {
                guard index == groups.index(before: groups.endIndex),
                      isValidIPv4Address(group) else {
                    return nil
                }
                count += 2
            } else {
                guard group.utf8.count <= 4,
                      group.utf8.allSatisfy(isASCIIHexDigit) else {
                    return nil
                }
                count += 1
            }
        }
        return count
    }

    private static func isValidIPv4Address(_ address: Substring) -> Bool {
        let components = address.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else {
            return false
        }
        return components.allSatisfy { component in
            !component.isEmpty
                && component.utf8.allSatisfy(isASCIIDigit)
                && component.count <= 3
                && UInt8(component) != nil
        }
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] != UInt8(ascii: "%") {
                index += 1
                continue
            }
            guard index + 2 < bytes.count,
                  isASCIIHexDigit(bytes[index + 1]),
                  isASCIIHexDigit(bytes[index + 2]) else {
                return false
            }
            index += 3
        }
        return true
    }

    private static func containsControlOrWhitespace(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
                || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        isASCIIDigit(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}
