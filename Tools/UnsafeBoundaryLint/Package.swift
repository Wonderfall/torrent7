// swift-tools-version: 6.4

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
    .strictMemorySafety(),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .defaultIsolation(nil)
]

let package = Package(
    name: "UnsafeBoundaryLint",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        .executable(
            name: "unsafe-boundary-lint",
            targets: ["UnsafeBoundaryLint"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            exact: "604.0.0"
        )
    ],
    targets: [
        .target(
            name: "UnsafeBoundaryLintCore",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax")
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "UnsafeBoundaryLint",
            dependencies: ["UnsafeBoundaryLintCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "UnsafeBoundaryLintTests",
            dependencies: ["UnsafeBoundaryLintCore"],
            swiftSettings: swiftSettings
        )
    ]
)
