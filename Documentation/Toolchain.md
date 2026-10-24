# Toolchain baseline

The project requires macOS 27 on Apple silicon and Xcode 27.1 (27A9275),
including the macOS 27.0 SDK, Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), and
Apple Clang 21.0.0 (`clang-2100.3.34.2`). All three packages require Swift tools
6.4. Build, test, analysis, benchmark, and fuzz entry points run
`Scripts/verify-xcode.zsh`;
the packaged GUI and extensions require macOS 27.0. Bundle verification checks
both the property lists and Mach-O deployment/SDK versions.

GitHub Actions uses the `xcode-27` Apple-silicon image and selects
`/Applications/Xcode_27.1.app`. The runner's published software inventory
includes build 27A9275; the exact Xcode build remains checked before compilation.
See the [installed tool versions](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

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

The project uses C++23. The Xcode 27.1 adoption probes exercised a partial C++26
subset: pack indexing, structured-binding packs in templates, `constexpr`
stable sorting, and `std::span::at()`. They did not expose reflection or
contracts feature macros, or the `<meta>`, `<contracts>`, `<hive>`, and
`<inplace_vector>` headers. These observations describe the pinned compiler,
not full C++26 conformance. See Apple's [C++ feature table](https://developer.apple.com/xcode/cpp/)
when considering a language-version change.

## Historical verification

The following record retains adoption evidence for its stated revision and
toolchain. Use the
[contributor verification requirements](../CONTRIBUTING.md#required-verification)
for new changes. The adoption review of
[Apple's 27.1 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes)
found no additional compiler security opt-ins or C++26 features. Enhanced
Security version 2 entitlements, checked allocations, pointer authentication,
typed allocation, stack initialization, and libc++ hardening remained enabled.

### Xcode 27.1 verification record

Recorded in repository revision `e35b0c6` on 2026-10-24. These test counts and
results describe that adoption, not the current suite size or evidence for later
changes. No persisted data format or migration changed in that update.

Validated on macOS 27.0.1 (26A434), Xcode 27.1 (27A9275), and Swift 6.4:

- `Scripts/build-deps.zsh` and `Scripts/build-app.zsh`: native dependencies,
  GUI, and engine extensions rebuilt in release, ASan, and TSan profiles and
  passed bundle, deployment target, signing, PAC, typed-allocation, and
  parser-reachability verification.
- `Scripts/test-swift.zsh`: 708 application tests passed in each of debug,
  release, ASan, and TSan configurations. The repository tool package passed
  34 tests in all four configurations, covering exact/bounded policy parsing,
  concurrent pipe draining, process groups, exit status, signals, cancellation,
  deadlines, output bounds, encoding, and child reaping. The unsafe-boundary
  linter also passed; its separate test package passed all 33 tests against
  SwiftSyntax 604.0.0.
- `Scripts/analyze-bridge.zsh`, followed by `Scripts/test-bridge.zsh`: static
  analysis passed; all 223 native tests and 7,807 assertions passed in each of
  normal, ASan, and TSan profiles, including PAC code-generation verification.
- `Scripts/test-libtorrent-security.zsh`: dependency security replay and
  hardening checks passed against rebuilt Xcode 27.1 dependencies in all three
  profiles.
- Bridge and IPC fuzz smoke suites: all 16 targets completed 1,000 executions
  each with ASan enabled.
- `Scripts/test-enhanced-security-extension.zsh` in automated mode: packaged
  launch, forced helper exit, replacement, restart, and reconnect passed in
  normal, ASan, and TSan profiles.

Final first-party builds and tests emitted no compiler warnings. The third-party
fuzz-only allocator advisory described above remains reviewed and unsuppressed.
Shell syntax, workflow YAML, packaging property lists, and whitespace checks
passed. An explicit macOS 26 deployment-target override was rejected by the
toolchain verifier. Hosted GitHub Actions execution had not yet been confirmed
when this record was written.
