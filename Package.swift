// swift-tools-version: 6.3

import PackageDescription

let environment = Context.environment
let packageRoot = Context.packageDirectory
let sanitizerProfile = environment["SANITIZER_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
let supportedSanitizerProfiles = ["address", "thread"]
if let sanitizerProfile, !supportedSanitizerProfiles.contains(sanitizerProfile) {
    fatalError("SANITIZER_PROFILE must be address or thread")
}
let enableDiagnostics = sanitizerProfile != nil
let defaultDepsProfile = sanitizerProfile.map { "arm64e-\($0)" } ?? "arm64e"
let depsPrefix = environment["DEPS_PREFIX"] ?? "\(packageRoot)/.build/deps/\(defaultDepsProfile)/prefix"
let boostPrefix = environment["BOOST_PREFIX"] ?? depsPrefix
let boringsslPrefix = environment["BORINGSSL_PREFIX"] ?? depsPrefix
let nativeDepsBuildID = environment["TORRENT7_NATIVE_DEPS_BUILD_ID"] ?? "unbound"
let nativeDepsBuildIDIsValid = nativeDepsBuildID == "unbound"
    || (nativeDepsBuildID.hasPrefix("v_")
        && nativeDepsBuildID.count == 66
        && nativeDepsBuildID.dropFirst(2).allSatisfy { "0123456789abcdef".contains($0) })
if !nativeDepsBuildIDIsValid {
    fatalError("TORRENT7_NATIVE_DEPS_BUILD_ID must be unbound or v_ followed by 64 lowercase hexadecimal digits")
}
let libcppHardeningMode = enableDiagnostics ? "_LIBCPP_HARDENING_MODE_DEBUG" : "_LIBCPP_HARDENING_MODE_EXTENSIVE"

let bridgeWarnings: [CXXSetting] = [
    .enableWarning("all"),
    .enableWarning("extra"),
    .enableWarning("conversion"),
    .enableWarning("implicit-fallthrough"),
    .enableWarning("shadow"),
    .enableWarning("empty-body"),
    .enableWarning("builtin-memcpy-chk-size"),
    .enableWarning("format"),
    .enableWarning("format-security"),
    .enableWarning("format-nonliteral"),
    .enableWarning("array-bounds"),
    .enableWarning("array-bounds-pointer-arithmetic"),
    .enableWarning("suspicious-memaccess"),
    .enableWarning("sizeof-array-div"),
    .enableWarning("sizeof-pointer-div"),
    .enableWarning("return-stack-address"),
    .enableWarning("pointer-arith"),
    .enableWarning("pragma-pack"),
    .enableWarning("pragma-pack-suspicious-include"),
    .enableWarning("unreachable-code-loop-increment"),
    .enableWarning("non-virtual-dtor"),
    .enableWarning("dangling"),
    .enableWarning("null-dereference"),
    .enableWarning("cast-align"),
    .enableWarning("cast-qual"),
    .enableWarning("undef"),
    .enableWarning("thread-safety"),
    .enableWarning("thread-safety-negative"),
    .enableWarning("thread-safety-pointer"),
    .enableWarning("alloca"),
    .enableWarning("vla"),
    .enableWarning("unsafe-buffer-usage")
]

// Test-framework-generated frames are outside the production Bridge budget.
let bridgeTargetWarnings: [CXXSetting] = [
    .enableWarning("frame-larger-than=16384")
]

let bridgeSystemIncludeFlags = [
    "-isystem", "\(depsPrefix)/include",
    "-isystem", "\(boostPrefix)/include",
    "-isystem", "\(boringsslPrefix)/include"
]
let bridgeLanguageAndRuntimeFlags = [
    "-std=c++23",
    "-fexceptions"
]
// Keep fortify out of sanitizer profiles so it cannot obscure reports.
let bridgeFortifyFlags = enableDiagnostics
    ? ["-U_FORTIFY_SOURCE"]
    : ["-U_FORTIFY_SOURCE", "-D_FORTIFY_SOURCE=3"]
let bridgeCompilerHardeningFlags = [
    "-fstack-protector-strong",
    "-fPIE",
    "-fapplication-extension",
    "-ftrivial-auto-var-init=zero",
    "-fno-delete-null-pointer-checks",
    "-fno-strict-aliasing",
    "-fzero-call-used-regs=used-gpr",
    "-fstrict-flex-arrays=3",
    "-fbranch-target-identification",
    "-mharden-sls=all",
    "-faarch64-jump-table-hardening"
]
let bridgeVisibilityFlags = [
    "-fvisibility=hidden",
    "-fvisibility-inlines-hidden"
]
// Keep global PAC options compatible with system C/C++ runtime contracts.
let bridgePointerAuthenticationFlags = [
    "-fptrauth-returns",
    "-fptrauth-calls",
    "-fptrauth-block-descriptor-pointers",
    "-fptrauth-init-fini",
    "-fptrauth-init-fini-address-discrimination",
    "-fptrauth-indirect-gotos",
    "-fptrauth-auth-traps",
    "-fptrauth-intrinsics",
    "-fptrauth-vtable-pointer-address-discrimination",
    "-fptrauth-vtable-pointer-type-discrimination"
]
let bridgeTypedAllocatorFlags = [
    "-ftyped-memory-operations-experimental",
    "-ftyped-cxx-new-delete",
    "-ftyped-cxx-delete"
]
// The undefined group already covers null, alignment, object-size,
// pointer-overflow, shift, integer-divide-by-zero, and array-bounds.
// local-bounds is intentionally outside Clang's undefined group. The
// remaining checks reject defined-but-suspicious unsigned overflow and
// lossy implicit integer conversions in the bridge surface we control.
let trapOnlyUBSanSanitizers =
    "undefined,local-bounds,unsigned-integer-overflow,implicit-conversion"
let trapOnlyUBSanFlags = [
    "-fsanitize=\(trapOnlyUBSanSanitizers)",
    "-fsanitize-trap=\(trapOnlyUBSanSanitizers)",
    "-fno-sanitize-recover=\(trapOnlyUBSanSanitizers)"
]
let addressSanitizerFlags = [
    "-g",
    "-fno-omit-frame-pointer",
    "-fsanitize=address,undefined,local-bounds",
    "-fsanitize-address-use-after-scope",
    "-fno-sanitize-recover=undefined,local-bounds"
]
let threadSanitizerFlags = [
    "-g",
    "-O1",
    "-fno-omit-frame-pointer",
    "-fsanitize=thread,undefined,local-bounds",
    "-fno-sanitize-recover=undefined,local-bounds"
]
let bridgeSanitizerFlags: [String]
switch sanitizerProfile {
case "address":
    bridgeSanitizerFlags = addressSanitizerFlags
case "thread":
    bridgeSanitizerFlags = threadSanitizerFlags
default:
    bridgeSanitizerFlags = trapOnlyUBSanFlags
}
let bridgeCompilerFlags = bridgeSystemIncludeFlags
    + bridgeLanguageAndRuntimeFlags
    + bridgeFortifyFlags
    + bridgeCompilerHardeningFlags
    + bridgeVisibilityFlags
    + bridgePointerAuthenticationFlags
    + bridgeTypedAllocatorFlags
    + bridgeSanitizerFlags
let bridgeTestCompilerFlags = [
    "-I", "\(packageRoot)/Sources/TorrentBridge",
    "-I", "\(packageRoot)/Sources/TorrentBridge/include",
    "-isystem", "\(packageRoot)/ThirdParty/doctest"
] + bridgeCompilerFlags

let bridgeDefines: [CXXSetting] = [
    .define("_LIBCPP_HARDENING_MODE", to: libcppHardeningMode),
    .define(
        "TORRENT7_NATIVE_DEPS_BUILD_ID",
        to: "\"torrent7-native-deps:\(nativeDepsBuildID)\""
    ),
    .define("BOOST_ASIO_ENABLE_CANCELIO"),
    .define("BOOST_ASIO_NO_DEPRECATED"),
    .define("BOOST_SYSTEM_USE_UTF8"),
    .define("TORRENT_ABI_VERSION", to: "100"),
    .define("TORRENT_USE_I2P", to: "0"),
    .define("TORRENT_USE_RTC", to: "0"),
    .define("TORRENT_DISABLE_LOGGING"),
    .define("TORRENT_DISABLE_MUTABLE_TORRENTS"),
    .define("TORRENT_DISABLE_STREAMING"),
    .define("TORRENT_DISABLE_SUPERSEEDING"),
    .define("TORRENT_DISABLE_SHARE_MODE"),
    .define("TORRENT_DISABLE_PREDICTIVE_PIECES"),
    // Libtorrent uses these names for its OpenSSL-compatible TLS API backend;
    // the linked implementation is the pinned BoringSSL build.
    .define("TORRENT_USE_OPENSSL"),
    .define("TORRENT_USE_LIBCRYPTO"),
    .define("TORRENT_SSL_PEERS")
] + (enableDiagnostics ? [
    // Sanitizer dependencies use libtorrent's CMake Debug configuration,
    // whose public assertion mode changes internal C++ object layouts.
    .define("TORRENT_USE_ASSERTS", to: "1")
] : [])
let bridgeStaticLibraryFlags = [
    "\(depsPrefix)/lib/libtorrent-rasterbar.a",
    "\(boringsslPrefix)/lib/libssl.a",
    "\(boringsslPrefix)/lib/libcrypto.a"
]
let bridgeLinkerHardeningFlags = [
    "-Xlinker", "-dead_strip",
    "-Xlinker", "-dead_strip_dylibs"
]
let appSwiftStrictnessFlags = [
    "-strict-concurrency=complete",
    "-warn-soft-deprecated"
]
let appSwiftPointerAuthenticationFlags = [
    "-swift-ptrauth-mode",
    "NewAndAuth"
]
let bridgeSafeInteropSwiftSettings: [SwiftSetting] = [
    // Limit the experimental Clang flag to Swift's importer. Applying it to the
    // C++ target also activates unrelated SDK bounds contracts in Boost.Asio.
    .enableExperimentalFeature("SafeInteropWrappers"),
    .unsafeFlags(["-Xcc", "-fexperimental-bounds-safety-attributes"])
]
// Swift 6.3 IRGen crashes when lifetime-dependent imported wrappers are emitted
// under whole-module optimization in this multi-file target. Keep normal -O
// per-file optimization until the compiler can emit this module under WMO.
let engineBridgeSafeInteropWorkaround: [SwiftSetting] = [
    .unsafeFlags(["-no-whole-module-optimization"], .when(configuration: .release))
]
let engineExtensionSwiftFlags = appSwiftStrictnessFlags
    + appSwiftPointerAuthenticationFlags
    + ["-application-extension"]
let engineExtensionLinkerFlags = [
    "-Xlinker", "-e",
    "-Xlinker", "_NSExtensionMain"
]
let diagnosticsExtensionIdentityFlags: [SwiftSetting]
let integrationExtensionIdentityFlags: [SwiftSetting]
switch sanitizerProfile {
case "address":
    diagnosticsExtensionIdentityFlags = [.define("TORRENT_ADDRESS_SANITIZER")]
    integrationExtensionIdentityFlags = [.define("TORRENT_ADDRESS_SANITIZER")]
case "thread":
    diagnosticsExtensionIdentityFlags = [.define("TORRENT_THREAD_SANITIZER")]
    integrationExtensionIdentityFlags = [.define("TORRENT_THREAD_SANITIZER")]
default:
    // The diagnostics product is never packaged without a sanitizer profile.
    diagnosticsExtensionIdentityFlags = [.define("TORRENT_ADDRESS_SANITIZER")]
    integrationExtensionIdentityFlags = []
}

let package = Package(
    name: "Torrent7",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Torrent7", targets: ["TorrentApp"]),
        .executable(name: "TorrentEngineExtension", targets: ["TorrentEngineExtension"]),
        .executable(
            name: "TorrentEngineDiagnosticsExtension",
            targets: ["TorrentEngineDiagnosticsExtension"]
        ),
        .executable(
            name: "TorrentEngineIntegrationExtension",
            targets: ["TorrentEngineIntegrationExtension"]
        ),
        .executable(
            name: "TorrentEngineXPCIntegrationHost",
            targets: ["TorrentEngineXPCIntegrationHost"]
        ),
        .executable(name: "TorrentBridgeTests", targets: ["TorrentBridgeTests"]),
        .library(
            name: "TorrentEngineIPCFuzzSupport",
            type: .dynamic,
            targets: ["TorrentEngineIPCFuzzSupport"]
        )
    ],
    targets: [
        .target(
            name: "TorrentEngineModel",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(engineExtensionSwiftFlags)
            ]
        ),
        .target(
            name: "TorrentEngineIPC",
            dependencies: ["TorrentEngineModel"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(engineExtensionSwiftFlags)
            ]
        ),
        .target(
            name: "TorrentEngineClient",
            dependencies: ["TorrentEngineIPC", "TorrentEngineModel"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(appSwiftStrictnessFlags + appSwiftPointerAuthenticationFlags)
            ]
        ),
        .executableTarget(
            name: "TorrentEngineXPCIntegrationHost",
            dependencies: ["TorrentEngineClient", "TorrentEngineModel"],
            path: "Tools/XPCIntegrationHost",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(appSwiftStrictnessFlags + appSwiftPointerAuthenticationFlags)
            ]
        ),
        .target(
            name: "TorrentNetworkSecurity",
            dependencies: ["TorrentEngineModel"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(engineExtensionSwiftFlags)
            ]
        ),
        .target(
            name: "TorrentEngineCore",
            dependencies: ["TorrentEngineModel", "TorrentBridge"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(engineExtensionSwiftFlags)
            ] + bridgeSafeInteropSwiftSettings + engineBridgeSafeInteropWorkaround
        ),
        .target(
            name: "TorrentEngineServiceSupport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(engineExtensionSwiftFlags)
            ]
        ),
        .target(
            name: "TorrentEngineService",
            dependencies: [
                "TorrentEngineCore",
                "TorrentEngineIPC",
                "TorrentEngineModel",
                "TorrentEngineServiceSupport",
                "TorrentNetworkSecurity"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(engineExtensionSwiftFlags)
            ]
        ),
        .executableTarget(
            name: "TorrentEngineExtension",
            dependencies: ["TorrentEngineService"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(engineExtensionSwiftFlags)
            ],
            linkerSettings: [
                .unsafeFlags(engineExtensionLinkerFlags)
            ]
        ),
        .executableTarget(
            name: "TorrentEngineDiagnosticsExtension",
            dependencies: ["TorrentEngineService"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(engineExtensionSwiftFlags)
            ] + diagnosticsExtensionIdentityFlags,
            linkerSettings: [
                .unsafeFlags(engineExtensionLinkerFlags)
            ]
        ),
        .executableTarget(
            name: "TorrentEngineIntegrationExtension",
            dependencies: ["TorrentEngineService"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(engineExtensionSwiftFlags)
            ] + integrationExtensionIdentityFlags,
            linkerSettings: [
                .unsafeFlags(engineExtensionLinkerFlags)
            ]
        ),
        .target(
            name: "TorrentBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .treatAllWarnings(as: .error),
                .unsafeFlags(bridgeCompilerFlags)
            ] + bridgeWarnings + bridgeTargetWarnings + bridgeDefines,
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
                .unsafeFlags(bridgeStaticLibraryFlags + bridgeLinkerHardeningFlags)
            ]
        ),
        .executableTarget(
            name: "TorrentApp",
            dependencies: ["TorrentEngineClient", "TorrentEngineModel"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(appSwiftStrictnessFlags + appSwiftPointerAuthenticationFlags)
            ],
        ),
        .testTarget(
            name: "TorrentAppTests",
            dependencies: ["TorrentApp", "TorrentEngineModel", "TorrentEngineCore", "TorrentBridge"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(appSwiftStrictnessFlags + appSwiftPointerAuthenticationFlags)
            ] + bridgeSafeInteropSwiftSettings
        ),
        .testTarget(
            name: "TorrentEngineIPCTests",
            dependencies: ["TorrentEngineIPC", "TorrentEngineModel"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(appSwiftStrictnessFlags + appSwiftPointerAuthenticationFlags)
            ]
        ),
        .testTarget(
            name: "TorrentEngineClientTests",
            dependencies: ["TorrentEngineClient", "TorrentEngineIPC"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(appSwiftStrictnessFlags + appSwiftPointerAuthenticationFlags)
            ]
        ),
        .testTarget(
            name: "TorrentEngineServiceSupportTests",
            dependencies: ["TorrentEngineServiceSupport"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(appSwiftStrictnessFlags + appSwiftPointerAuthenticationFlags)
            ]
        ),
        .testTarget(
            name: "TorrentEngineServiceTests",
            dependencies: ["TorrentEngineService", "TorrentEngineIPC"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(appSwiftStrictnessFlags + appSwiftPointerAuthenticationFlags)
            ]
        ),
        .testTarget(
            name: "TorrentNetworkSecurityTests",
            dependencies: ["TorrentNetworkSecurity", "TorrentEngineModel"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .strictMemorySafety(),
                .unsafeFlags(appSwiftStrictnessFlags + appSwiftPointerAuthenticationFlags)
            ]
        ),
        .target(
            name: "TorrentEngineIPCFuzzSupport",
            dependencies: ["TorrentEngineIPC"],
            path: "Tools/IPCFuzzing/Support",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .unsafeFlags(appSwiftStrictnessFlags)
            ]
        ),
        .executableTarget(
            name: "TorrentBridgeTests",
            path: ".",
            sources: [
                "Tests/TorrentBridgeTests/main.cpp",
                "Tests/TorrentBridgeTests/BridgeAuthorizedRootIntegrationTests.cpp",
                "Tests/TorrentBridgeTests/BridgeAuthorizedRootValidationTests.cpp",
                "Tests/TorrentBridgeTests/BridgeClientLifecycleTests.cpp",
                "Tests/TorrentBridgeTests/BridgeHashAndSnapshotTests.cpp",
                "Tests/TorrentBridgeTests/BridgeInputValidationTests.cpp",
                "Tests/TorrentBridgeTests/BridgePersistenceTests.cpp",
                "Tests/TorrentBridgeTests/BridgePointerAuthenticationTests.cpp",
                "Tests/TorrentBridgeTests/BridgeSLSThunks.cpp",
                "Tests/TorrentBridgeTests/BridgeStringTests.cpp",
                "Tests/TorrentBridgeTests/BridgeUnderTest.cpp"
            ],
            cxxSettings: [
                .treatAllWarnings(as: .error),
                .define("TORRENT_BRIDGE_TESTING"),
                .unsafeFlags(bridgeTestCompilerFlags)
            ] + bridgeWarnings + bridgeDefines,
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
                .unsafeFlags(bridgeStaticLibraryFlags + bridgeLinkerHardeningFlags)
            ]
        )
    ]
)
