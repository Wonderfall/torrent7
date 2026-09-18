import CoreFoundation
package import Foundation

package enum PolicyError: Error, CustomStringConvertible, Equatable {
    case usage(String)
    case invalidPropertyList
    case invalidRoot
    case excessiveSize
    case invalidMetadata

    package var description: String {
        switch self {
        case .usage(let message): message
        case .invalidPropertyList: "Unsupported property-list value"
        case .invalidRoot: "Property-list root is not a dictionary"
        case .excessiveSize: "Property list exceeds the verification limit"
        case .invalidMetadata: "Extension metadata does not match the reviewed Enhanced Security schema"
        }
    }
}

package indirect enum PropertyListValue: Equatable, Sendable {
    package static let maximumBytes = 4 * 1_024 * 1_024

    case dictionary([String: PropertyListValue])
    case array([PropertyListValue])
    case boolean(Bool)
    case integer(String)
    case real(Double)
    case string(String)
    case data(Data)
    case date(Date)

    package static func dictionary(from data: Data) throws -> [String: Self] {
        guard data.count <= maximumBytes else { throw PolicyError.excessiveSize }
        // SAFETY: Foundation owns the decoded values; passing nil requests no write
        // through the optional format pointer. No borrowed storage escapes decoding.
        let object = try unsafe PropertyListSerialization.propertyList(from: data, format: nil)
        guard case .dictionary(let result) = try Self(object, depth: 0) else {
            throw PolicyError.invalidRoot
        }
        return result
    }

    // Foundation's dynamically typed decoder is confined to this conversion. Check
    // CF value kinds before bridging so a Boolean cannot masquerade as an integer.
    private init(_ object: Any, depth: Int) throws {
        guard depth <= 64 else { throw PolicyError.excessiveSize }
        switch CFGetTypeID(object as CFTypeRef) {
        case CFDictionaryGetTypeID():
            guard let values = object as? [String: Any] else { throw PolicyError.invalidPropertyList }
            self = .dictionary(try values.mapValues { try Self($0, depth: depth + 1) })
        case CFArrayGetTypeID():
            guard let values = object as? [Any] else { throw PolicyError.invalidPropertyList }
            self = .array(try values.map { try Self($0, depth: depth + 1) })
        case CFBooleanGetTypeID():
            guard let value = object as? NSNumber else { throw PolicyError.invalidPropertyList }
            self = .boolean(value.boolValue)
        case CFNumberGetTypeID():
            guard let value = object as? NSNumber else { throw PolicyError.invalidPropertyList }
            // SAFETY: NSNumber retains its NUL-terminated Objective-C type encoding
            // throughout this synchronous copy; no pointer is stored or returned.
            let kind = unsafe String(cString: value.objCType)
            if kind == "f" || kind == "d" {
                guard value.doubleValue.isFinite else { throw PolicyError.invalidPropertyList }
                self = .real(value.doubleValue)
            } else {
                self = .integer(value.stringValue)
            }
        case CFStringGetTypeID():
            guard let value = object as? String else { throw PolicyError.invalidPropertyList }
            self = .string(value)
        case CFDataGetTypeID():
            guard let value = object as? Data else { throw PolicyError.invalidPropertyList }
            self = .data(value)
        case CFDateGetTypeID():
            guard let value = object as? Date else { throw PolicyError.invalidPropertyList }
            self = .date(value)
        default:
            throw PolicyError.invalidPropertyList
        }
    }

    package func differences(from actual: Self, path: String = "entitlements") -> [String] {
        switch (self, actual) {
        case (.dictionary(let expected), .dictionary(let observed)):
            let expectedKeys = Set(expected.keys)
            let observedKeys = Set(observed.keys)
            var differences = expectedKeys.subtracting(observedKeys).sorted().map { "\(path).\($0): missing key" }
            differences += observedKeys.subtracting(expectedKeys).sorted().map { "\(path).\($0): unexpected key" }
            for key in expectedKeys.intersection(observedKeys).sorted() {
                if let left = expected[key], let right = observed[key] {
                    differences += left.differences(from: right, path: "\(path).\(key)")
                }
            }
            return differences
        case (.array(let expected), .array(let observed)):
            guard expected.count == observed.count else {
                return ["\(path): expected \(expected.count) values, found \(observed.count)"]
            }
            return zip(expected, observed).enumerated().flatMap { index, pair in
                pair.0.differences(from: pair.1, path: "\(path)[\(index)]")
            }
        default:
            return self == actual ? [] : ["\(path): value or property-list type differs"]
        }
    }
}

package func readPropertyList(at url: URL) throws -> Data {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var data = Data()
    while let chunk = try file.read(upToCount: min(65_536, PropertyListValue.maximumBytes + 1 - data.count)),
          !chunk.isEmpty {
        data.append(chunk)
        guard data.count <= PropertyListValue.maximumBytes else { throw PolicyError.excessiveSize }
    }
    return data
}

package func verifyExtensionMetadata(point: Data, info: Data, identifier: String) throws {
    let point = try PropertyListValue.dictionary(from: point)
    let expected: [String: PropertyListValue] = [
        "EXVersion": .integer("2"),
        identifier: .dictionary([
            "EXExtensionPointName": .string("torrent-engine"),
            "EXPresentsUserInterface": .boolean(false),
            "EXRequiresEnhancedSecurity": .boolean(true),
            "_EXScopeRestriction": .string("application")
        ])
    ]
    let info = try PropertyListValue.dictionary(from: info)
    guard point == expected,
          info["XPCService"] == nil,
          info["NSExtension"] == nil,
          info["EXAppExtensionAttributes"] == .dictionary([
              "EXExtensionPointIdentifier": .string(identifier)
          ]) else { throw PolicyError.invalidMetadata }
}
