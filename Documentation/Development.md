# Development

Run commands from the repository root. Read the [contributor guide](../CONTRIBUTING.md)
and use the [pinned toolchain](Toolchain.md); these workflows do not replace the
required verification for a change. Distribution builds have a separate
[release procedure](ReleaseDiagnostics.md#preparing-a-release).

## Local builds

Install `cmake` and `ninja` with Homebrew, then check the selected Xcode:

```sh
brew install cmake ninja
Scripts/verify-xcode.zsh
Scripts/build-app.zsh
```

`build-app.zsh` builds or validates the native dependencies, compiles the GUI and
engine, packages and signs both, and verifies the result. Its default
configuration is `release`; ordinary tests default to `debug`.

| Build | Command | App output |
| --- | --- | --- |
| Optimized local app | `Scripts/build-app.zsh` | `.build/App/Torrent 7.app` |
| Debug app | `CONFIGURATION=debug Scripts/build-app.zsh` | `.build/App/Torrent 7.app` |
| AddressSanitizer | `SANITIZER_PROFILE=address Scripts/build-app.zsh` | `.build/App-Address/Torrent 7 (ASan).app` |
| ThreadSanitizer | `SANITIZER_PROFILE=thread Scripts/build-app.zsh` | `.build/App-Thread/Torrent 7 (TSan).app` |
| All three profiles | `Scripts/build-all-apps.zsh` | Regular, ASan, and TSan outputs above. |

Debug and release use the same default app destination: the last build replaces
that bundle. Sanitizer apps default to debug and have separate bundle identities,
dependency prefixes, and Swift scratch directories. They can coexist with the
regular app and each other. An explicit `CONFIGURATION=release` produces an
optimized sanitizer build. Debug and sanitizer bundles retain symbols; ordinary
release packaging strips its copies and retains the original products and dSYMs.

Local builds are ad-hoc signed unless `SIGN_IDENTITY` is set. Ad-hoc builds opt
into reduced-assurance development XPC authentication. Identified builds require
matching app/helper Team IDs. Use the release script for distribution.

## Incremental work and isolated outputs

The dependency builder compares source identities, patch manifests, compiler and
SDK identities, flags, and dependency stamps before reusing artifacts. Running
the normal app builder is the simplest incremental workflow. After verifying
the dependencies for the same native sources, toolchain, architecture, and sanitizer
profile, a Swift-only iteration can skip that step:

```sh
SKIP_BUILD_DEPS=1 CONFIGURATION=debug Scripts/build-app.zsh
```

Do not carry `SKIP_BUILD_DEPS=1` across dependency, patch, hardening, profile, or
toolchain changes. Run `Scripts/build-deps.zsh` again with the intended profile.
Keep one writer per scratch directory, source cache, and dependency prefix;
separate writable paths for concurrent experiments.

The main path controls are:

| Variable | Purpose |
| --- | --- |
| `SOURCE_CACHE_DIR` | Shared downloaded archives and source checkouts; defaults to `.build/deps/source-cache`. |
| `DEPS_DIR` / `DEPS_PREFIX` | Native profile's sources/builds and installed headers/archives. Keep them consistent when overriding defaults. |
| `SWIFT_BUILD_DIR` | App build scratch directory; defaults to `.build`, or `.build/swift-app-address` / `.build/swift-app-thread`. |
| `APP_OUTPUT_DIR` | Absolute destination directory for the packaged app. |
| `SWIFT_TEST_SCRATCH_PATH` | App test scratch directory; defaults to `.build/swift-test-default`, `-address`, or `-thread`. |

For example, a separate debug build can share the verified native dependencies:

```sh
CONFIGURATION=debug \
SWIFT_BUILD_DIR="$PWD/.build/local-debug" \
APP_OUTPUT_DIR="$PWD/.build/App-Debug" \
Scripts/build-app.zsh
```

The builder already verifies the bundle. To repeat verification, use
`Scripts/verify-app.zsh` for the default release output, or
`Scripts/verify-app.zsh --configuration debug` for the default debug output.
For custom output, supply the matching configuration, original products, and app:

```sh
Scripts/verify-app.zsh --configuration debug \
  --build-products "$(xcrun swift build --scratch-path .build/local-debug --configuration debug --arch arm64e --show-bin-path)" \
  ".build/App-Debug/Torrent 7.app"
```

Use the same native prefix and sanitizer profile as the build. Verification
needs the original executables and, for a regular release build, matching dSYMs;
a packaged app alone is insufficient for the full code audit.

## Tests and diagnostics

The [required-check matrix](../CONTRIBUTING.md#required-verification) is
authoritative. Build native dependencies first if this checkout has no matching
prefix. These are the common local entry points:

```sh
Scripts/build-deps.zsh
Scripts/test-swift.zsh
Scripts/analyze-bridge.zsh
Scripts/test-bridge.zsh
Scripts/test-libtorrent-security.zsh
```

`test-swift.zsh` includes unsafe-boundary lint, repository tool tests, and Swift
fuzz-support builds. It forwards arguments to the app's Swift test invocation;
for example, `Scripts/test-swift.zsh --filter TorrentFilePriorityChangeTests`
runs a focused app suite while retaining those preliminary checks.
`CONFIGURATION=release` selects optimized Swift tests. Install Homebrew `llvm`
when using the optional `clang-tidy` analysis or the libFuzzer harnesses.

For relevant sanitizer coverage, build that profile's dependencies first, then
run its suites. For example:

```sh
SANITIZER_PROFILE=thread Scripts/build-deps.zsh
SANITIZER_PROFILE=thread Scripts/test-bridge.zsh
SANITIZER_PROFILE=thread Scripts/test-swift.zsh
SANITIZER_PROFILE=thread Scripts/test-lifecycle.zsh --skip-build
SANITIZER_PROFILE=thread Scripts/test-enhanced-security-extension.zsh --automated
```

Use `address` for the corresponding ASan profile. These profiles instrument
BoringSSL, libtorrent, and the bridge, use libc++ debug hardening, and disable
fortify for the sanitizer configuration; libtorrent and the bridge also retain
supported undefined-behavior checks. The production hardening profile is unchanged.

| Purpose | Guide or entry point |
| --- | --- |
| Dependency security, PAC replay, TLS, allocation | [Patch verification](../Scripts/patches/README.md#verification-and-maintenance); focused scripts include `Scripts/test-boringssl-hardening.zsh`, `Scripts/test-boost-asio-pac.zsh`, and `Scripts/test-boost-asio-recycling-allocator.zsh`. |
| Native and Swift-to-native fuzzing | [Bridge fuzzing](../Tools/BridgeFuzzing/README.md). |
| Swift parser, IPC, and storage-authority fuzzing | [Swift/IPC fuzzing](../Tools/IPCFuzzing/README.md). |
| Real helper launch, shutdown, recovery, and payload quarantine | [Enhanced Security integration](EnhancedSecurityExtensionIntegration.md). |
| Repeated concurrency tests, UI/VoiceOver, Instruments | [Release and UI diagnostics](ReleaseDiagnostics.md). |
| Native/Swift parser comparison | [Parser microbenchmarks](../Tools/ParserBenchmarks/README.md). |
| Startup filesystem verification | `Scripts/benchmark-storage-restoration.zsh`; [methodology and limitations](StorageRestorationBenchmark.md). |
| Snapshot copying, mapping, latency, and footprint | `Scripts/benchmark-snapshot-transport.zsh`; [architecture review gates](Architecture.md#verification). |
| Bounded DHT callback cost and retained allocation | `Scripts/benchmark-dht-message-parser.zsh`; [parsing contract](MetainfoParsing.md). |

Benchmark timing is diagnostic. It does not replace correctness assertions or
establish transfer-load performance from an idle app or isolated fixture.

## CI coverage and reproduction

The workflow files define exact path filters, configurations, arguments, and
artifact uploads. Use the failed job's commands and profile when reproducing it:

| Workflow | Coverage and local entry points |
| --- | --- |
| [TorrentApp](../.github/workflows/torrent-app.yml) | Swift/tool/linter checks, repeated lifecycle tests, release app and packaging evidence, bundle verification, automated helper lifecycle, and UI test compilation. See the commands above and [release diagnostics](ReleaseDiagnostics.md). |
| [TorrentBridge](../.github/workflows/torrent-bridge.yml) | Dependency security regressions, bridge analysis, then bridge tests. |
| [Sanitizers](../.github/workflows/sanitizers.yml) | ASan and TSan native dependency instrumentation, security/bridge/Swift/lifecycle tests, app builds, and automated helper lifecycle. |
| [Bridge fuzzing](../.github/workflows/torrent-bridge-fuzzing.yml) / [storage boundary fuzzing](../.github/workflows/torrent-ipc-fuzzing.yml) | Their `run-libfuzzer.sh` entry points; weekly runs use the scheduled budgets defined in each workflow. |
| [Parser benchmarks](../.github/workflows/parser-benchmarks.yml) | `Tools/ParserBenchmarks/run.zsh` and uploaded results. |
| [Dependencies](../.github/workflows/dependencies.yml) | Checker tests and the read-only [upstream monitor](../Scripts/patches/README.md#dependency-monitor), also scheduled weekly. |

These workflows use path-filtered push/pull-request triggers and manual dispatch;
the dependency and fuzzing workflows also have schedules. The app, bridge,
sanitizer, dependency, and fuzzing jobs explicitly skip fork pull requests. The
parser benchmark workflow has no equivalent fork guard. Missing or skipped jobs
are not evidence that the affected checks passed; record required local results.

CI compiles UI/VoiceOver diagnostics with `--build-only`; execution needs a
logged-in graphical session and macOS UI-automation approval. Automated helper
tests also have [explicit coverage limits](EnhancedSecurityExtensionIntegration.md).
CI does not run the Developer ID/notarization release procedure.

## Reclaiming build space

Stop builds, tests, fuzzers, and diagnostic apps using the outputs before removing
them. Check custom path overrides too. Inspect sizes without changing anything:

```sh
du -sh .build Tools/BridgeFuzzing Tools/IPCFuzzing
```

| Location | Cleanup consequences |
| --- | --- |
| `.build/deps/source-cache` | Download/source cache; removing it requires refetching and preparing dependencies. Preserve any local patch-development work first. |
| `.build/deps/arm64e`, `.build/deps/arm64e-address`, `.build/deps/arm64e-thread` | Native sources, build trees, and installed prefixes. Removing a profile requires rebuilding it before dependent tests or apps. Preserve uncommitted dependency experiments. |
| `.build/out`, `.build/swift-app-*`, `.build/swift-test-*`, and configured tool/scratch directories | Rebuildable products and compiler state. Save any matching binaries/dSYMs needed for release audits or crash investigation first. |
| `.build/App`, `.build/App-Address`, `.build/App-Thread` | Packaged local apps; recreate with the corresponding build command. |
| `Tools/BridgeFuzzing/deps`, either fuzz tool's `libfuzzer-build` and `swift-build` | Rebuildable fuzz dependencies and harness outputs. Keep checked-in seeds and source. |
| Fuzz `libfuzzer-artifacts`, `.xcresult`, and `.build/profiles` | Preserve unresolved failures, useful corpora, test results, and measurements before pruning. |
| `.build/Release` | Retained distribution artifacts and private evidence, **not disposable cache**. Archive securely outside the checkout before any removal. |

Avoid treating all ignored files, or all of `.build`, as cache. A blanket
`git clean -xfd` would also remove retained evidence and local investigation
artifacts. Reclaim specific outputs after reviewing their contents, then rebuild
with the normal scripts. Build cleanup must not touch download folders or the
[app's persisted state](Troubleshooting.md#data-ownership-and-preservation).
