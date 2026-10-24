# Contributing to Torrent 7

These requirements apply to all contributors, human and agent. Start with the
[README](README.md) for product scope and build instructions. Agents must also
follow [AGENTS.md](AGENTS.md).

## Design and compatibility

Torrent 7 aims to be clean, elegant, and modern, with security as a first-class
principle. Make changes carefully with security hardening in mind.

- Choose the simplest implementation that fully meets the requirements. Avoid
  unnecessary features, redundant code, stopgaps, and accumulating workarounds.
  Fix the underlying problem and make architectural decisions for the long term.
- Target the modern platform and tools pinned in the
  [toolchain baseline](Documentation/Toolchain.md). Update that baseline
  deliberately; "latest" does not mean using an unverified local toolchain.
- Do not preserve compatibility with older platforms, toolchains, or APIs.
  Remove obsolete paths instead of adding compatibility layers or fallbacks.
  Any workaround for a current SDK defect must be documented and narrowly scoped.
- Consider compatibility and migrations for persisted user data case by case,
  with explicit maintainer approval. Any retained migration must be narrow,
  documented, and tested. Dropping support for an old platform does not authorize
  discarding user data or silently changing its meaning.

The [coding standards](Documentation/CodingStandards.md) define language,
concurrency, UI, ownership, and unsafe-boundary requirements. Exceptions must be
narrow, documented, and tested. The
[architecture invariants](Documentation/Architecture.md#non-negotiable-invariants)
remain non-negotiable.

## Task reading map

Before working on the project, read this guide, the README, the coding standards,
the toolchain baseline, and the opening architecture overview and invariants.
Then read the documents relevant to the area you will investigate or change:

| Area | Read before working |
| --- | --- |
| Module ownership, storage, bookmarks, file selection, or teardown | The affected sections of [Architecture and security decisions](Documentation/Architecture.md). For startup verification budgets, also read the [storage restoration measurements](Documentation/StorageRestorationBenchmark.md). |
| IPC, helper lifecycle, or process authority | The architecture's [command channel](Documentation/Architecture.md#command-channel) and [exact-file broker](Documentation/Architecture.md#exact-file-broker), plus [Enhanced Security integration](Documentation/EnhancedSecurityExtensionIntegration.md) and [lifecycle diagnostics](Documentation/ReleaseDiagnostics.md#repeated-lifecycle-tests). |
| Parsers, protocol input, or imported native interfaces | [Metainfo and protocol parsing](Documentation/MetainfoParsing.md), [Native parser inventory](Documentation/NativeParserInventory.md), and the relevant [Swift/IPC](Tools/IPCFuzzing/README.md) or [bridge](Tools/BridgeFuzzing/README.md) fuzzing guide. |
| Native dependencies, patches, or hardening | [Dependency patches](Scripts/patches/README.md) and the architecture's [native and dependency hardening](Documentation/Architecture.md#native-and-dependency-hardening). |
| SwiftUI, menus, or accessibility | The [SwiftUI standards](Documentation/CodingStandards.md#swiftui) and [native menu and VoiceOver diagnostics](Documentation/ReleaseDiagnostics.md#native-menus-and-voiceover). |
| Build, packaging, signing, or release verification | [Build instructions](README.md#build), [release diagnostics](Documentation/ReleaseDiagnostics.md), and [Enhanced Security integration](Documentation/EnhancedSecurityExtensionIntegration.md). |
| Offline IP-to-country data | [Peer countries](Documentation/PeerCountries.md). |
| Developer tools or unsafe-boundary lint | [Developer tools](Tools/README.md) and the [unsafe-boundary lint](Tools/UnsafeBoundaryLint/README.md) guide when changing that checker. |

The reading map routes work to the relevant contracts; it does not replace
reading the affected code, tests, and local invariant comments.

## Required verification

Run checks from the repository root using the supported scripts, which retain
the pinned toolchain and hardening settings. Apply every relevant row below;
additional risk-specific checks supplement the ordinary language checks.

| Change | Required checks |
| --- | --- |
| Swift source or Swift target settings | Run `Scripts/test-swift.zsh`. |
| First-party C/C++, the bridge ABI, or an imported interface | Run `Scripts/analyze-bridge.zsh` **first**, then `Scripts/test-bridge.zsh`. Also run the Swift checks if an imported Swift surface may have changed. |
| Memory, concurrency, parsers, ABI contracts, or untrusted input | Also run the relevant ASan, TSan, fuzz, and replay suites for the affected boundary. See the entry points below. |
| Dependency patches or hardening | Run the affected dependency security and code-generation/replay checks described in the [patch guide](Scripts/patches/README.md#verification-and-maintenance), along with the applicable language and risk-specific checks above. |
| Build tools, packaging, or release policy | Exercise the affected tool or build/verification entry point. Use the [release diagnostics](Documentation/ReleaseDiagnostics.md) and [extension integration](Documentation/EnhancedSecurityExtensionIntegration.md) gates for the affected packaged behavior. |
| UI behavior | Run the Swift checks and verify affected accessibility, keyboard, and focus behavior. Use the [UI diagnostics](Documentation/ReleaseDiagnostics.md#native-menus-and-voiceover) where applicable. |
| Documentation only | Check local links and section anchors, command accuracy, and `git diff --check`. A rebuild or sanitizer run is not required when source and build settings are unchanged. |

Risk-specific entry points are documented in the
[diagnostics and tests guide](README.md#diagnostics-and-tests),
[release and lifecycle diagnostics](Documentation/ReleaseDiagnostics.md),
[bridge fuzzing](Tools/BridgeFuzzing/README.md), and
[Swift/IPC fuzzing](Tools/IPCFuzzing/README.md). Select coverage based on the
behavior and boundary changed. A presentation-only Swift change does not by
itself require ASan; a Swift change to descriptor ownership, parsing, or
concurrent teardown does require the relevant additional checks.

Review every compiler, analyzer, test, and script warning or error. Do not
suppress diagnostics merely to obtain a passing run. Follow the coding standards
for [test design](Documentation/CodingStandards.md#performance-and-testing),
including cancellation, races, malformed input, and partial completion where
relevant.

Before handing off a change, review its diff for correctness, unnecessary
complexity, and scope. Record the checks actually run and their results,
including configurations, reviewed diagnostics, and any required verification
that remains blocked or unperformed. Historical results in documentation do
not establish that a new change passes.

## Maintaining documentation

Keep each kind of guidance in its authoritative home:

- `README.md`: product orientation, capabilities, and build/test entry points.
- `CONTRIBUTING.md`: shared contribution policy, reading routes, and verification
  requirements.
- `Documentation/CodingStandards.md`: shared engineering requirements.
- `Documentation/Toolchain.md`: exact supported versions, compiler-specific
  settings, and necessary build workarounds.
- `Documentation/Architecture.md`: authority boundaries, ownership, security
  invariants, and the reasoning behind cross-component decisions.
- Topic documents and `Tools/` guides: domain contracts, reproducible diagnostics,
  maintenance procedures, and evidence for the subsystem they cover.
- `AGENTS.md`: agent-specific workflow and mandatory reading instructions.

Document decisions, constraints, failure modes, and operational steps that are
hard to recover from code alone. Keep local `SAFETY:` and `PERF:` explanations
beside the code they justify. Avoid duplicating API catalogs, obvious control
flow, or the same policy in several files; link to the authoritative section.

Update or remove obsolete guidance as part of the change. Rewrite the relevant
explanation instead of appending a running history of pull requests. Keep
temporary investigation notes and agent plans out of permanent project docs.
Retain historical verification or benchmark evidence when it explains a decision,
but label its date, source revision, configuration, method, and limitations.
Separate those observations from current requirements and reproducible commands.
