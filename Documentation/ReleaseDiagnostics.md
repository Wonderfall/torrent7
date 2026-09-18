# Release and UI diagnostics

These checks use Xcode 27 / Swift 6.4 and macOS 27. They complement the
compiler, native analysis, sanitizer, fuzz, and extension-lifecycle checks
described in [Toolchain.md](Toolchain.md).

## Repeated lifecycle tests

```sh
Scripts/test-lifecycle.zsh
SANITIZER_PROFILE=thread Scripts/test-lifecycle.zsh
```

The script repeats the reply-state, absolute-deadline, and shared-process
acquisition suites 25 times using Swift Testing's `--maximum-repetitions 25
--repeat-until fail`. It stops repeating a failing test and propagates the
failure; it does not retry until success. CI runs this after the complete Swift
suite in normal, ASan, and TSan jobs. `--skip-build` reuses the preceding Swift
test build; lint, repository tools, and fuzz-support checks still run.

## Release evidence

`Scripts/release-app.zsh` builds in a private prefix and publishes a new
directory named by Apple's notarization submission ID. The app ZIP, matching
symbol ZIP, product and native SBOMs, toolchain versions, notarization result,
and SHA-256 checksums are published together. Previous releases are preserved.
No release is published if either executable lacks a matching arm64e dSYM.

SwiftPM generates a CycloneDX 1.7 SBOM during each product build, so the selected
product and build graph determine the inventory. It cannot see the native
dependencies supplied as prebuilt archives. `write-native-sbom` supplements
these files with Boost's version and source archive digest, BoringSSL's pinned
commit and source archive digest, libtorrent's tag and commit, every applied
patch and patch-helper digest, patched source identities, and the linked native
archive digests. The three JSON files form the release inventory together.
Absolute local paths and compiler command lines are not exported by the native
inventory. Repository tools and test dependencies are not shipped app dependencies.

The native inventory recomputes the same native build ID embedded in the engine
and checks the stamps' cross-dependency identities. The archive helper is used
after `build-app.zsh` has verified the bundle and its native build identity.
Missing, duplicate, excessive, malformed, or incomplete stamp fields fail closed.
The evidence integration check also rejects missing and mismatched dSYMs and
checks that a rejected archive leaves no partially published evidence.

For a local release build without signing/notarizing a distribution release:

```sh
SKIP_BUILD_DEPS=1 SBOM_OUTPUT_DIR="$PWD/.build/release-sboms" Scripts/build-app.zsh
Scripts/test-release-evidence.zsh ".build/App/Torrent 7.app" \
  "$(xcrun swift build --configuration release --arch arm64e --show-bin-path)" \
  .build/deps/arm64e/prefix .build/release-sboms
```

Use a fresh SBOM output directory for each build. The archive helper deliberately
rejects multiple SBOMs for a product rather than guessing which one belongs to
the release. Keep the symbol archive privately alongside its matching release;
the app download does not contain it. Swift 6.4 no longer embeds binary Swift
modules in dSYMs. These archives support crash symbolication, not reconstruction
of an entire LLDB expression-evaluation environment.

**Xcode 27 packaging limitation:** the installed SwiftPM prints
`Bundle 'SwiftPM_SBOMModel' with schemas not found - skipping SBOM validation`.
The archive helper checks the format, version, and product identity, but does not
claim full schema validation. The generated native and both SwiftPM inventories
were independently checked against the official CycloneDX 1.7 JSON schema during
development. SBOMs are dependency inventories, not vulnerability assessments.

## Native menus and VoiceOver

The app uses native toggles and pickers for menu selection, so state does not
depend on macOS displaying decorative menu images. The aggregate label control
projects the selection's all/any bounds into the native toggle's off/mixed/on
states. Only one binding issues the bulk command. Native `NSHostingMenu` tests
verify all three states, empty selections, and one action per activation.

```sh
Scripts/test-ui.zsh --build-only
Scripts/test-ui.zsh
```

The Xcode UI diagnostic host compiles the production aggregate menu control with
strict compiler settings and owns only in-memory fixture state. It has no torrent
engine, user defaults, storage grants, or production data access. XCTest is used
only because Apple's UI runner and `XCUIVoiceOverService` require it. The runner
uses Xcode's normal non-hardened test-host configuration to load its ad-hoc signed
test bundle; this does not change production signing or hardening. CI compiles
the diagnostic host and tests. Execution requires a logged-in graphical session
and macOS approval to enable UI automation.

The UI tests exercise mixed-to-all-to-none selection and exactly one bulk command
per click. The VoiceOver test enables the service when needed, traverses the
native label menu, saves the spoken transcript in the `.xcresult`, and restores
the original enabled state, including on failures. Xcode's message that App
Intents metadata extraction was skipped is expected: this fixture and its UI
test bundle do not implement App Intents.

On this development machine, the native click test passes, but VoiceOver
automation remains unverified: `XCUIVoiceOverService.enable()` times out.
macOS logs show the VoiceOver process not running after startup, followed by
the test's successful request to disable it again. UI automation itself was
approved and works. The VoiceOver failure is not suppressed or converted into
a skipped/passing test. The fixture disables window restoration so each run
starts from the same mixed selection.

## Instruments

With a development app running, record one bounded, process-specific trace:

```sh
Scripts/profile-app.zsh swiftui PID
Scripts/profile-app.zsh concurrency PID
```

The scripts attach for 15 seconds and save `.trace` bundles under
`.build/profiles`. Exercise list selection, menus, settings, and window changes
during the SwiftUI recording. Use a representative transfer workload for the
Swift Concurrency recording. Inspect SwiftUI update/layout causes and long main
actor work, and the Swift Concurrency/Swift Executors tracks for actor contention
and task lifetimes. A fixture or idle-app trace only verifies the recording path;
it cannot establish transfer-load performance.

## Verification on 2026-09-18

- The complete Swift checks passed: 609 application/infrastructure tests and
  18 repository-tool tests; the release app also built and passed bundle checks.
- All 17 selected lifecycle tests passed 25 repetitions in normal, ASan, and
  TSan profiles. The inventory parser's focused ASan tests passed.
- Release evidence was generated from a real local build. Missing and mismatched
  dSYMs and an SBOM for the wrong product were rejected without partial output.
  All three generated inventories passed independent CycloneDX 1.7 validation.
- The native UI test passed; the VoiceOver startup failure is described above.
- A 15-second Swift Concurrency recording of the real client lifecycle suites
  captured 707 task creations and actor/executor queues. That workload completed
  250 repetitions successfully. A separate 15-second SwiftUI recording exercised
  the production aggregate menu in the isolated host, including mixed-to-all
  and all-to-none updates. These are focused diagnostic checks, not a benchmark
  of transfer throughput or a full application accessibility audit.

Developer ID signing and Apple notarization were not run for this change.

Sources: [SwiftPM SBOM documentation](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/GeneratingSBOMs.md),
[CycloneDX 1.7 schema](https://cyclonedx.org/schema/bom-1.7.schema.json),
[VoiceOver UI testing](https://developer.apple.com/documentation/xcuiautomation/xcuivoiceoverservice).
