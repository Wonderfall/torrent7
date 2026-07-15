#!/usr/bin/swift

import CoreFoundation
import Foundation

enum ComparisonError: Error, CustomStringConvertible {
    case usage
    case invalidRoot(String)

    var description: String {
        switch self {
        case .usage:
            "usage: compare-entitlements.swift EXPECTED_PLIST ACTUAL_PLIST"
        case let .invalidRoot(path):
            "Entitlements at \(path) are not a dictionary"
        }
    }
}

func loadDictionary(at path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    guard let dictionary = propertyList as? [String: Any] else {
        throw ComparisonError.invalidRoot(path)
    }
    return dictionary
}

func numberKind(_ value: Any) -> String {
    let typeCode = String(cString: (value as! NSNumber).objCType)
    return typeCode == "f" || typeCode == "d" ? "real" : "integer"
}

func propertyListKind(_ value: Any) -> String {
    let typeID = CFGetTypeID(value as CFTypeRef)
    return switch typeID {
    case CFDictionaryGetTypeID(): "dictionary"
    case CFArrayGetTypeID(): "array"
    case CFBooleanGetTypeID(): "boolean"
    case CFNumberGetTypeID(): numberKind(value)
    case CFStringGetTypeID(): "string"
    case CFDataGetTypeID(): "data"
    case CFDateGetTypeID(): "date"
    default: "unknown"
    }
}

func compare(expected: Any, actual: Any, path: String, differences: inout [String]) {
    let expectedKind = propertyListKind(expected)
    let actualKind = propertyListKind(actual)
    guard expectedKind == actualKind else {
        differences.append("\(path): expected \(expectedKind), found \(actualKind)")
        return
    }

    switch expectedKind {
    case "dictionary":
        let expectedDictionary = expected as! [String: Any]
        let actualDictionary = actual as! [String: Any]
        let expectedKeys = Set(expectedDictionary.keys)
        let actualKeys = Set(actualDictionary.keys)
        for key in expectedKeys.subtracting(actualKeys).sorted() {
            differences.append("\(path).\(key): missing key")
        }
        for key in actualKeys.subtracting(expectedKeys).sorted() {
            differences.append("\(path).\(key): unexpected key")
        }
        for key in expectedKeys.intersection(actualKeys).sorted() {
            compare(
                expected: expectedDictionary[key]!,
                actual: actualDictionary[key]!,
                path: "\(path).\(key)",
                differences: &differences
            )
        }
    case "array":
        let expectedArray = expected as! [Any]
        let actualArray = actual as! [Any]
        guard expectedArray.count == actualArray.count else {
            differences.append("\(path): expected \(expectedArray.count) values, found \(actualArray.count)")
            return
        }
        for index in expectedArray.indices {
            compare(
                expected: expectedArray[index],
                actual: actualArray[index],
                path: "\(path)[\(index)]",
                differences: &differences
            )
        }
    default:
        let expectedObject = expected as AnyObject
        if !expectedObject.isEqual(actual as AnyObject) {
            differences.append("\(path): value differs")
        }
    }
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw ComparisonError.usage
    }
    let expected = try loadDictionary(at: CommandLine.arguments[1])
    let actual = try loadDictionary(at: CommandLine.arguments[2])
    var differences: [String] = []
    compare(expected: expected, actual: actual, path: "entitlements", differences: &differences)
    guard differences.isEmpty else {
        for difference in differences {
            FileHandle.standardError.write(Data("\(difference)\n".utf8))
        }
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
