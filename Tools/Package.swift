// swift-tools-version: 6.4

import PackageDescription

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
    .strictMemorySafety(),
    .defaultIsolation(nil),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ImmutableWeakCaptures")
]

let package = Package(
    name: "RepositoryTools",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "compare-entitlements", targets: ["CompareEntitlements"]),
        .executable(name: "verify-enhanced-security-metadata", targets: ["VerifyEnhancedSecurityMetadata"]),
        .executable(name: "check-dependencies", targets: ["DependencyCheck"]),
        .executable(name: "write-native-sbom", targets: ["WriteNativeSBOM"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.0")
    ],
    targets: [
        .target(name: "ReleasePolicy", path: "ReleasePolicy", swiftSettings: strictSettings),
        .target(
            name: "ProcessRunner",
            dependencies: [.product(name: "Subprocess", package: "swift-subprocess")],
            path: "ProcessRunner",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "CompareEntitlements", dependencies: ["ReleasePolicy"],
            path: "CompareEntitlements", swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "VerifyEnhancedSecurityMetadata", dependencies: ["ReleasePolicy"],
            path: "VerifyEnhancedSecurityMetadata", swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "DependencyCheck", dependencies: ["ProcessRunner"],
            path: "DependencyCheck", swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "WriteNativeSBOM", dependencies: ["ReleasePolicy"],
            path: "WriteNativeSBOM", swiftSettings: strictSettings
        ),
        .testTarget(
            name: "ReleasePolicyTests", dependencies: ["ReleasePolicy"],
            path: "Tests/ReleasePolicyTests", swiftSettings: strictSettings
        ),
        .testTarget(
            name: "ProcessRunnerTests", dependencies: ["ProcessRunner"],
            path: "Tests/ProcessRunnerTests", swiftSettings: strictSettings
        ),
        .testTarget(
            name: "DependencyCheckTests", dependencies: ["DependencyCheck"],
            path: "Tests/DependencyCheckTests", swiftSettings: strictSettings
        )
    ]
)
