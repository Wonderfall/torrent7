# Documentation

Start with the [project README](../README.md) for product scope and build
instructions. The [contributor guide](../CONTRIBUTING.md) defines required
reading, verification, and documentation responsibilities.
[AGENTS.md](../AGENTS.md) adds project character and workflow guidance for agents.

## Foundations

| Document | Contents |
| --- | --- |
| [Architecture and security decisions](Architecture.md) | Process authority, module ownership, storage and network contracts, and security invariants. |
| [Coding standards](CodingStandards.md) | Swift, SwiftUI, concurrency, C++, ownership, and unsafe-boundary requirements. |
| [Toolchain baseline](Toolchain.md) | Pinned tools and platform, build configuration, necessary workarounds, and historical adoption evidence. |

## Subsystem contracts

| Document | Contents |
| --- | --- |
| [Metainfo and protocol parsing](MetainfoParsing.md) | Accepted torrent, magnet, peer-extension, tracker, and DHT inputs; bounds and native interoperability. |
| [Native parser inventory](NativeParserInventory.md) | Retired and reachable native parser routes, retained boundaries, and evidence required for reassessment. |
| [Peer countries](PeerCountries.md) | Offline country lookups, database format and updates, privacy, and attribution. |

## Verification and measurements

| Document | Contents |
| --- | --- |
| [Release and UI diagnostics](ReleaseDiagnostics.md) | Lifecycle checks, release evidence, packaging verification, accessibility, and Instruments. |
| [Enhanced Security extension integration](EnhancedSecurityExtensionIntegration.md) | Real helper-process integration fixtures, lifecycle recovery, dataset checks, and coverage limits. |
| [Startup storage verification measurements](StorageRestorationBenchmark.md) | Benchmark methodology, recorded workloads, and the rationale and limits of the startup work budget. |

## Guides alongside tools and scripts

- [Developer tools](../Tools/README.md): tool purposes, entry points, and lifecycle contracts.
- [Dependency patches](../Scripts/patches/README.md): ordered patch purposes, dependencies, verification, and maintenance.
- [Bridge fuzzing](../Tools/BridgeFuzzing/README.md): native and Swift-to-native boundary targets, builds, and runs.
- [Swift/IPC fuzzing](../Tools/IPCFuzzing/README.md): bounded parsers and storage-authority targets, corpora, and runs.
- [Unsafe-boundary lint](../Tools/UnsafeBoundaryLint/README.md): safety-comment placement checks and rule fixtures.
- [Parser microbenchmarks](../Tools/ParserBenchmarks/README.md): native/Swift comparisons, recorded baselines, and measurement limits.
