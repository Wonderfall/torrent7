import CryptoKit
package import Foundation

package enum InventoryError: Error, Equatable {
    case invalidStamp
    case invalidField(String)
    case inconsistentBuild
}

package struct NativeBuildStamp {
    private let fields: [String: String]

    package init(_ data: Data) throws {
        guard data.count <= 131_072,
              let text = String(data: data, encoding: .utf8),
              !text.contains("\0"), !text.contains("\r") else {
            throw InventoryError.invalidStamp
        }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "="), separator != line.startIndex else {
                throw InventoryError.invalidStamp
            }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            guard fields.updateValue(value, forKey: key) == nil else {
                throw InventoryError.invalidStamp
            }
        }
        guard !fields.isEmpty else { throw InventoryError.invalidStamp }
        self.fields = fields
    }

    package func value(_ key: String) throws -> String {
        guard let value = fields[key], !value.isEmpty else { throw InventoryError.invalidField(key) }
        return value
    }

    package func hash(_ key: String, length: Int = 64) throws -> String {
        let value = try value(key)
        guard value.utf8.count == length,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw InventoryError.invalidField(key)
        }
        return value
    }

    package func patches(_ prefix: String) throws -> [InventoryProperty] {
        guard let count = try Int(value("\(prefix)-patch-count")), (0...128).contains(count) else {
            throw InventoryError.invalidField("\(prefix)-patch-count")
        }
        let expectedKeys = Set((0..<count).flatMap { offset in
            ["\(prefix)-patch-\(offset + 1)", "\(prefix)-patch-\(offset + 1)-sha256"]
        })
        let actualKeys = Set(fields.keys.filter {
            $0.hasPrefix("\(prefix)-patch-")
                && $0 != "\(prefix)-patch-count" && $0 != "\(prefix)-patch-helper-sha256"
        })
        guard actualKeys == expectedKeys else { throw InventoryError.invalidField("\(prefix)-patch-count") }
        return try (0..<count).flatMap { offset -> [InventoryProperty] in
            let key = "\(prefix)-patch-\(offset + 1)"
            let name = try value(key)
            guard name.hasSuffix(".patch"), !name.contains("/"), !name.contains("\\"),
                  name != ".patch" else { throw InventoryError.invalidField(key) }
            return [
                .init(name: "torrent7:\(key)", value: name),
                .init(name: "torrent7:\(key)-sha256", value: try hash("\(key)-sha256"))
            ]
        }
    }
}

package struct InventoryProperty: Codable, Equatable {
    package let name: String
    package let value: String

    package init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

private struct InventoryHash: Encodable {
    let alg = "SHA-256"
    let content: String
}

private struct InventoryReference: Encodable {
    let type: String
    let url: String
}

private struct InventoryComponent: Encodable {
    let type: String
    let name: String
    let version: String
    let hashes: [InventoryHash]
    let properties: [InventoryProperty]
    let externalReferences: [InventoryReference]

    enum CodingKeys: String, CodingKey {
        case type, name, version, hashes, properties, externalReferences
        case reference = "bom-ref"
    }

    var reference: String { name }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reference, forKey: .reference)
        try container.encode(type, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(hashes, forKey: .hashes)
        try container.encode(properties, forKey: .properties)
        try container.encode(externalReferences, forKey: .externalReferences)
    }
}

private struct NativeInventory: Encodable {
    let bomFormat = "CycloneDX"
    let specVersion = "1.7"
    let version = 1
    let serialNumber = "urn:uuid:\(UUID().uuidString.lowercased())"
    let components: [InventoryComponent]
    let dependencies: [Dependency]
    let properties: [InventoryProperty]

    struct Dependency: Encodable {
        let ref: String
        let dependsOn: [String]
    }
}

package enum NativeDependencyInventory {
    /// Read only build stamps and archives from the private release prefix. Paths
    /// and compiler command lines stay private; only reviewed provenance is exported.
    package static func encode(prefix: URL, expectedBuildID: String) throws -> Data {
        let inputNames = [
            ".torrent-app-boost-headers", ".torrent-app-boringssl-build", ".torrent-app-libtorrent-build",
            "lib/libtorrent-rasterbar.a", "lib/libssl.a", "lib/libcrypto.a"
        ]
        let labels = [
            "boost-headers-stamp", "boringssl-build-stamp", "libtorrent-build-stamp",
            "libtorrent-archive", "boringssl-ssl-archive", "boringssl-crypto-archive"
        ]
        let digests = try inputNames.map { try digest(prefix.appending(path: $0)) }
        let identity = zip(labels, digests).map { "\($0)=\($1)\n" }.joined()
        let actualBuildID = "v_" + hexadecimal(SHA256.hash(data: Data(identity.utf8)))
        guard actualBuildID == expectedBuildID else { throw InventoryError.inconsistentBuild }

        let boost = try readStamp(prefix.appending(path: inputNames[0]))
        let ssl = try readStamp(prefix.appending(path: inputNames[1]))
        let torrent = try readStamp(prefix.appending(path: inputNames[2]))
        for stamp in [ssl, torrent] {
            guard try stamp.value("target-arch") == "arm64e",
                  try stamp.value("deployment-target") == "27.0",
                  try stamp.value("sanitizer-profile") == "none" else { throw InventoryError.inconsistentBuild }
        }
        guard try torrent.hash("boringssl-build-stamp-sha256") == digests[1] else {
            throw InventoryError.inconsistentBuild
        }
        let boostVersion = try boost.value("boost-version")
        guard try torrent.value("boost-version") == boostVersion,
              try torrent.hash("boost-patched-files-tree") == boost.hash("boost-patched-files-tree") else {
            throw InventoryError.inconsistentBuild
        }
        let sslVersion = try ssl.hash("boringssl-commit", length: 40)
        let torrentVersion = try torrent.value("libtorrent-tag")
        let components = try [
            InventoryComponent(
                type: "library", name: "Boost", version: boostVersion,
                hashes: [.init(content: boost.hash("boost-archive-sha256"))],
                properties: boost.patches("boost") + [
                    .init(name: "torrent7:patch-helper-sha256", value: boost.hash("boost-patch-helper-sha256")),
                    .init(name: "torrent7:patched-files-sha256", value: boost.hash("boost-patched-files-tree"))
                ], externalReferences: [.init(type: "distribution", url: boost.value("boost-url"))]
            ),
            InventoryComponent(
                type: "library", name: "BoringSSL", version: sslVersion,
                hashes: [.init(content: ssl.hash("boringssl-archive-sha256"))],
                properties: ssl.patches("boringssl") + [
                    .init(name: "torrent7:patch-helper-sha256", value: ssl.hash("boringssl-patch-helper-sha256")),
                    .init(name: "torrent7:patched-tree", value: ssl.hash("boringssl-patched-tree", length: 40)),
                    .init(name: "torrent7:libssl.a:sha256", value: digests[4]),
                    .init(name: "torrent7:libcrypto.a:sha256", value: digests[5])
                ], externalReferences: [.init(type: "vcs", url: ssl.value("boringssl-repo"))]
            ),
            InventoryComponent(
                type: "library", name: "libtorrent", version: torrentVersion,
                hashes: [.init(content: digests[3])],
                properties: torrent.patches("libtorrent") + [
                    .init(name: "torrent7:patch-helper-sha256", value: torrent.hash("libtorrent-patch-helper-sha256")),
                    .init(name: "torrent7:commit", value: torrent.hash("libtorrent-commit", length: 40)),
                    .init(name: "torrent7:patched-tree", value: torrent.hash("libtorrent-patched-tree", length: 40))
                ], externalReferences: [.init(type: "vcs", url: "https://github.com/arvidn/libtorrent")]
            )
        ]
        let inventory = NativeInventory(
            components: components,
            dependencies: [
                .init(ref: "libtorrent", dependsOn: ["Boost", "BoringSSL"]),
                .init(ref: "Boost", dependsOn: []), .init(ref: "BoringSSL", dependsOn: [])
            ],
            properties: [
                .init(name: "torrent7:native-build-id", value: actualBuildID),
                .init(name: "torrent7:target", value: "arm64e-apple-macosx27.0"),
                .init(name: "torrent7:consumer", value: "TorrentEngineExtension"),
                .init(name: "torrent7:scope", value: "native dependencies; see adjacent SwiftPM product SBOMs")
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(inventory)
    }

    private static func readStamp(_ url: URL) throws -> NativeBuildStamp {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        // One extra byte makes an oversized stamp fail before decoding or allocation.
        return try NativeBuildStamp(file.read(upToCount: 131_073) ?? Data())
    }

    private static func digest(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw InventoryError.invalidStamp
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let data = try file.read(upToCount: 65_536), !data.isEmpty {
            hasher.update(data: data)
        }
        return hexadecimal(hasher.finalize())
    }

    private static func hexadecimal(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map {
            let value = String($0, radix: 16)
            return $0 < 16 ? "0" + value : value
        }.joined()
    }
}
