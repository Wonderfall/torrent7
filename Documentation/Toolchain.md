# Toolchain baseline

The project requires macOS 27 on Apple silicon and Xcode 27.1 (27A9275),
including the macOS 27.0 SDK and Apple Swift 6.4
(`swiftlang-6.4.0.34.1`). All three packages require Swift tools 6.4. Build, test,
analysis, benchmark, and fuzz entry points run `Scripts/verify-xcode.zsh`;
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
- Apple Clang 21 still exposes typed C allocation rewriting as
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

## Adoption records

These notes retain the reasons for toolchain-specific changes and the evidence
recorded during adoption. Use the
[contributor verification requirements](../CONTRIBUTING.md#required-verification)
for checks on new changes.

### Xcode 27.1 update

Xcode 27.1 retains Swift 6.4 and the macOS 27.0 SDK. The selected C++ compiler
reports Apple Clang 21.0.0 (`clang-2100.3.34.2`). Native dependency stamps now
include the Xcode and SDK build identifiers alongside compiler/archive-tool
hashes, flags, and source provenance. Replacing Xcode or its SDK at the same
path therefore invalidates the dependency cache even when compiler executables
do not change.

The rebuild exposed an ASan deadlock in the developer tools' subprocess runner:
requesting a new session takes Swift Subprocess's `fork` path, which stalled in
the sanitizer's allocator locks. Commands now use a separate process group via
`posix_spawn`. Group-wide cancellation still includes transport helpers, and
concurrent launch, deadline, cancellation, and reaping tests cover the change.

[Apple's 27.1 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes)
announce no new compiler security opt-ins or C++26 features. The existing
Enhanced Security version 2 entitlements, checked allocations, pointer
authentication, typed allocation, stack initialization, and libc++ hardening
remain enabled.

C++26 support was partial in the adoption probes. They exercised pack indexing,
structured-binding packs in templates, `constexpr` stable sorting, and
`std::span::at()`. The tested toolchain did not expose reflection or contracts
feature macros, or the `<meta>`, `<contracts>`, `<hive>`, and `<inplace_vector>`
headers. These results agree with the supported subset in Apple's
[C++ feature table](https://developer.apple.com/xcode/cpp/); they do not establish
full C++26 conformance. The project continues to use C++23.

### Swift 6.4 adoption

- Use SwiftPM's default Swift Build engine. Select the native architecture with
  `--arch arm64e` (or `arm64` for the standalone libFuzzer runtime), and query
  `--show-bin-path` instead of assuming the former build directory layout.
  Only the public C ABI has explicit default visibility so Swift Build's
  intermediate relocatable link preserves those entry points; native
  implementation symbols remain hidden.
- Annotated C pointer/count parameters import as standard `Span` and
  `MutableSpan` overloads. Empty spans replace optional-buffer branches and
  retain the bridge's zero-capacity query behavior. Neither
  `SafeInteropWrappers` nor an explicit importer
  `-fexperimental-bounds-safety-attributes` flag is needed. The required SDK
  headers are included directly instead of silently dropping annotations when
  a header is unavailable.
- Release targets use whole-module optimization again. The Swift 6.3 IRGen
  workaround that disabled it for the engine, bridge contract tests, and DHT
  benchmark is removed.
- SwiftSyntax 604.0.0 keeps the unsafe-boundary linter on the compiler's syntax
  generation. Its exact revision is recorded in `Package.resolved`.
  Benchmark JSON reports join typed string fields instead of relying on long
  overloaded concatenations that exceed the new compiler's type-checking limit.
- SwiftUI text fields use `.bordered` with a rounded rectangle input border.
  Checked continuations inherit isolation through the new
  `nonisolated(nonsending)` overload. Strict safety no longer needs redundant
  outer acknowledgements around borrowing closures whose actual unsafe
  operations are already acknowledged inside.
- ExtensionFoundation can be imported normally. The process wrapper still
  needs its narrowly documented `@unchecked Sendable` conformance because
  `AppExtensionProcess` itself does not conform to `Sendable` in this SDK.
- The XPC transport now has a compiler-checked `Sendable` conformance;
  `XPCSession` supports it. Reply slots own noncopyable `Continuation` values
  under a mutex and consume them once, resuming outside the lock. Early replies,
  cancellation, deadlines, duplicate replies, and descriptor cleanup retain
  their existing ownership contracts.
- Request-slot and poll-pipeline queues store noncopyable waiter records in
  `UniqueArray`. Cancellation, deadlines, FIFO handoff, and terminal draining
  remove each waiter before consuming its continuation. Queued cancellation
  consumes no wire sequence and leaves neighboring waiters in order.
- Polling uses asynchronous `defer` and `withTaskCancellationShield` for
  mandatory dataset cleanup. Cleanup completes before recovery and before
  releasing the polling slot. Each close retains its independent deadline;
  fatal protocol failures still stop sending requests to the peer.
- Filesystem metadata uses System's descriptor and descriptor-relative `Stat`
  APIs. Path observations explicitly reject symlink following, errors retain
  their existing fail-closed mapping, and interrupted calls remain failures.
  Raw metadata fields are read only to preserve existing identity/size checks
  and persisted encodings; descriptor ownership is unchanged.
- SwiftUI alerts and confirmation dialogs use optional item bindings. Actions
  receive the presented value, including a pending `false` setting, and model
  dismissal callbacks and destructive action roles are preserved.
- Release-policy verifiers and the dependency monitor are compiled SwiftPM
  products under `Tools/Package.swift`; none runs as an unchecked Swift script.
  Typed, bounded plist decoding and pinned Swift Subprocess replace dynamically
  typed comparisons and wait-before-drain process handling. See [developer
  tools](../Tools/README.md) for entry points and lifecycle limits.

See [Swift 6.4's release announcement](https://www.swift.org/blog/swift-6.4-released/)
and [Xcode 27's release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes).
The bridge continues to use a narrow C ABI: direct `std::span` interoperability
does not justify exposing native implementation types. There are no raw-span
loads or temporary unsafe allocations needing the new safe loading/allocation
APIs. Other new collection, observation, and concurrency facilities are not
added where they would only rewrite working abstractions.

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
