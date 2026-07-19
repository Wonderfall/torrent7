import Darwin
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    Darwin.exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail(
        "Usage: verify-enhanced-security-metadata.swift "
            + "<extension-point.appexpt> <extension-Info.plist> <point-identifier>"
    )
}

func propertyList(at path: String) -> [String: Any] {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        fail("Could not read property list at \(path): \(error.localizedDescription)")
    }

    let value: Any
    do {
        value = try PropertyListSerialization.propertyList(from: data, format: nil)
    } catch {
        fail("Could not decode property list at \(path): \(error.localizedDescription)")
    }
    guard let dictionary = value as? [String: Any] else {
        fail("Property list root is not a dictionary: \(path)")
    }
    return dictionary
}

let extensionPointPath = CommandLine.arguments[1]
let extensionInfoPath = CommandLine.arguments[2]
let expectedIdentifier = CommandLine.arguments[3]

let extensionPoint = propertyList(at: extensionPointPath)
guard Set(extensionPoint.keys) == ["EXVersion", expectedIdentifier],
      let version = extensionPoint["EXVersion"] as? Int,
      version == 2,
      let definition = extensionPoint[expectedIdentifier] as? [String: Any],
      Set(definition.keys) == [
          "EXExtensionPointName",
          "EXPresentsUserInterface",
          "EXRequiresEnhancedSecurity",
          "_EXScopeRestriction"
      ],
      definition["EXExtensionPointName"] as? String == "torrent-engine",
      definition["EXPresentsUserInterface"] as? Bool == false,
      definition["EXRequiresEnhancedSecurity"] as? Bool == true,
      definition["_EXScopeRestriction"] as? String == "application" else {
    fail("Extension-point metadata does not match the reviewed Enhanced Security schema")
}

let extensionInfo = propertyList(at: extensionInfoPath)
guard extensionInfo["XPCService"] == nil,
      extensionInfo["NSExtension"] == nil,
      let attributes = extensionInfo["EXAppExtensionAttributes"] as? [String: Any],
      Set(attributes.keys) == ["EXExtensionPointIdentifier"],
      attributes["EXExtensionPointIdentifier"] as? String == expectedIdentifier else {
    fail("Engine extension Info.plist does not exactly bind the expected extension point")
}
