# Developer Tools

Developer-only utilities that are useful for security, diagnostics, or release
engineering, but are not part of the shipped app product.

`BridgeFuzzing/` contains the TorrentBridge libFuzzer suite, including the
end-to-end Swift parser callback and native typed-import boundary. Keeping it
here lets the fuzz harnesses own their scripts, corpora, fuzz-only dependencies,
and generated artifacts without changing app targets or production build
settings.

`IPCFuzzing/` contains coverage-guided targets for the production bounded-JSON
preflight, storage authority, and bounded Swift parsers used at untrusted input
boundaries.

`XPCIntegrationHost/` contains the executable harness packaged by
`Scripts/test-enhanced-security-extension.zsh` to exercise the Enhanced Security
extension through its real ExtensionFoundation and XPC boundary. The script is
the supported entry point: it assembles, signs, and registers a temporary host
and extension fixture, then runs automated lifecycle recovery checks or
interactive dataset and scale checks with an explicitly authorized folder.

`DependencyCheck/` contains the read-only upstream dependency monitor for pinned
third-party source dependencies.

`Package.swift` compiles the dependency monitor and the entitlement/Enhanced
Security metadata verifiers with Swift 6.4, strict memory safety, complete
concurrency checking, and warnings as errors. Run them through the checked
entry point:

```sh
Scripts/run-tool.zsh check-dependencies --summary .build/dependency-check.md
Scripts/run-tool.zsh compare-entitlements expected.plist actual.plist
Scripts/run-tool.zsh verify-enhanced-security-metadata point.plist info.plist identifier
Scripts/run-tool.zsh write-native-sbom DEPS_PREFIX OUTPUT_JSON NATIVE_BUILD_ID
Scripts/test-tools.zsh
```

`Scripts/test-swift.zsh` includes these tool tests. `CONFIGURATION=release`
and `SANITIZER_PROFILE=address|thread` also apply to the tool test script.
`WriteNativeSBOM/` records the exact native dependency provenance from a verified
release prefix and refuses a mismatched native build ID. `UIDiagnostics/` hosts
the production menu control in isolation for XCTest and macOS 27 VoiceOver
automation. See [release and UI diagnostics](../Documentation/ReleaseDiagnostics.md)
for entry points, the symbol archive, and Instruments recording.
The policy verifiers bound input reads and compare typed plist values exactly,
including Boolean versus numeric distinctions. `ProcessRunner/` uses pinned
Swift Subprocess 1.0 to drain both output streams concurrently, bound each
stream to 1 MiB, enforce a 30-second deadline, and terminate/reap cancelled or
timed-out children with a one-second graceful shutdown allowance. Commands run
in a dedicated session, so teardown signals also reach their helper processes
without reaching the tool's process group. Tests cover
those resource and lifecycle boundaries. These dependencies are developer-only
and are not linked into the application.

`ParserBenchmarks/` contains reproducible native-versus-Swift parser
microbenchmarks, their recorded baseline, and the raw-result summarizer.
