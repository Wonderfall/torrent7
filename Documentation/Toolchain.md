# Toolchain baseline

The project requires macOS 27 on Apple silicon and Xcode 27.2 (27B52),
including the macOS 27.2 SDK (26B118), Apple Swift 6.4.2 (`swiftlang-6.4.2.1.9`),
and Apple Clang 21.0.0 (`clang-2100.4.1.1`). All three packages require Swift tools
6.4. Build, test, analysis, benchmark, and fuzz entry points run
`Scripts/verify-xcode.zsh`;
the packaged GUI and extensions require macOS 27.0. Bundle verification checks
both the property lists and Mach-O deployment/SDK versions.

GitHub Actions uses the `xcode-27` Apple-silicon image and selects
`/Applications/Xcode_27.2.app`. The exact final build, 27B52, is checked before
compilation, and native cache keys include that build. As of 2026-11-02, the
[published runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
for image `20261026.0314.1` still maps that path to the 27.2 release candidate,
27B48. CI deliberately rejects that image until GitHub installs the final build.

## Xcode 27.2 adoption

[Apple's release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes)
document no new compiler security opt-ins for this project. The
[security update](https://support.apple.com/en-us/149589) fixes a CoreDevice
symlink-handling issue and an Instruments authorization issue. These protect
developer tooling and require no additional app entitlements. Existing Enhanced
Security, checked-allocation, PAC, typed-allocation, and compiler hardening
settings remain enabled.

The optional JSON `.xcproj` format does not affect the app's SwiftPM build.
Apple lists an SDK defect affecting the 27.1 deployment target; the app retains
its 27.0 minimum while building against the 27.2 SDK. Local verification runs
on macOS 27.2 (26B123).

## Current build configuration

The [coding standards](CodingStandards.md#baseline-and-target-isolation)
define the required Swift language features, compiler checks, import access,
and target isolation for every first-party Swift target, including tests and
tools. The following details explain their implementation in this toolchain:

- `InferIsolatedConformances` and `NonisolatedNonsendingByDefault` require
  explicit enablement: the installed compiler reports that they become defaults
  in Swift 7 language mode. The project uses Swift 6 language mode.
- Compiler import checks do not replace independent manifest dependency
  validation. Native builds and static analysis also enable
  `-Wconditional-uninitialized`.
- Safe return-value imports using `__lifetimebound` remain experimental in
  Xcode 27. The bridge does not use them, so their flag is absent.
- Apple Clang 21 exposes typed C allocation rewriting as
  `-ftyped-memory-operations-experimental`. Keep that flag, typed C++
  allocation/deallocation, and the existing allocation/codegen checks.
- Clang 21 rejects the driver spelling of `-fptrauth-returns` on link-only
  invocations. Dependency builds pass `-Xclang -fptrauth-returns`, preserving
  the same compiler protection without applying it to CMake's link driver.
- Swift Build's link-only Clang invocation does not infer the SDK version from
  `--sysroot` alone. App builds and the Swift and extension integration tests
  forward the selected SDK as `-Xclang-linker -isysroot` so `LC_BUILD_VERSION`
  records SDK 27.2 while retaining the 27.0 deployment target. Exporting
  `SDKROOT` alone does not fix the Swift Build invocation. The C++ bridge runner
  already receives `-isysroot` from Swift Build.
- Swift Build adds a configuration-dependent libc++ hardening define. The
  bridge explicitly replaces that default with the dependency profile's
  extensive/debug mode; mixing modes across C++ translation units is avoided.
- Xcode 27's `lipo -verify_arch arm64e` rejects executables carrying the
  versioned arm64e ABI capability bits emitted by Swift Build, although
  `lipo -archs` and `otool -hv` identify them as arm64e. Executable checks
  require the architecture inventory to be exactly `arm64e`, then inspect
  authenticated instructions and exercise the existing PAC replay tests.

The dependency patches implement current storage, protocol, allocation, and
authentication contracts and remain necessary with the pinned dependencies.
Their replay and code-generation checks remain enabled.

The arm64 libFuzzer dependency build emits an allocator-wrapper advisory for
libtorrent's untyped `allocator_new_delete::malloc` branch. That branch belongs
to the third-party compatibility allocator used when typed allocation is
disabled for the fuzz runtime. Its paired `new[]`/`delete[]` ownership remains
covered by ASan; production arm64e builds exercise the separate typed branch
and pass the typed-allocation code-generation and replay checks. No diagnostic
was suppressed to hide this advisory.

## Swift build and SDK contracts

SwiftPM uses its default Swift Build engine. Select `--arch arm64e` for app
products, or `arm64` for the standalone libFuzzer runtime, and query
`--show-bin-path` for product locations. Release targets use whole-module
optimization. The public C ABI has explicit default visibility so the
intermediate relocatable link preserves those entry points; native
implementation symbols remain hidden.

Annotated C pointer/count parameters import as standard `Span` and
`MutableSpan` overloads. Empty spans carry zero-capacity queries. Neither
`SafeInteropWrappers` nor an explicit importer
`-fexperimental-bounds-safety-attributes` flag is needed. Required SDK headers
are included directly. The narrow C ABI and ownership rules are described in
[protocol interoperability](MetainfoParsing.md#native-interoperability);
direct C++ interoperability is not needed for this boundary.

`XPCSession` supports compiler-checked `Sendable` conformance.
`AppExtensionProcess` does not conform in this SDK, so the
[process handle](../Sources/TorrentEngineClient/TorrentEngineExtensionProcessCoordinator.swift)
uses a narrowly documented wrapper. Recheck this exception when changing SDKs.
SwiftSyntax is pinned to the compiler's syntax generation by the
[linter package](../Tools/UnsafeBoundaryLint/Package.swift) and its resolved file.

Native dependency stamps include Xcode and SDK build identifiers alongside
compiler/archive-tool hashes, flags, and source provenance. Replacing Xcode or
its SDK at the same path invalidates the dependency cache even when compiler
executables do not change.

Developer tools launch subprocesses in separate process groups using
`posix_spawn`. A new-session launch takes Swift Subprocess's `fork` path,
which deadlocks in the sanitizer's allocator locks in the recorded ASan
reproduction. Group-wide cancellation includes transport helpers; see
[tool lifecycle contracts](../Tools/README.md).

## C++ language support

The project uses C++23. Xcode 27.2 probes exercised a partial C++26
subset: pack indexing, structured-binding packs in templates, `constexpr`
stable sorting, and `std::span::at()`. They did not expose reflection or
contracts feature macros, or the `<meta>`, `<contracts>`, `<hive>`, and
`<inplace_vector>` headers. These observations describe the pinned compiler,
not full C++26 conformance. See Apple's [C++ feature table](https://developer.apple.com/xcode/cpp/)
when considering a language-version change.
