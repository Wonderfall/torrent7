<p align="center">
  <img src="Documentation/Assets/torrent7-app-icon-dark.png" width="128" alt="Torrent 7 app icon">
</p>

<h1 align="center">Torrent 7</h1>

<p align="center">
  A modern and hardened torrent client for macOS.
</p>

<p align="center">
  <strong>Requires macOS 26 on Apple silicon.</strong>
</p>

<p align="center">
  <img src="Documentation/Assets/torrent7-main-window.png" alt="Torrent 7 main window showing torrent cards, sidebar filters, transfer controls, and VPN interface status">
</p>

## Table of Contents

- [Purpose](#purpose)
- [Features](#features)
- [Security and Hardening](#security-and-hardening)
- [Sandbox Model](#sandbox-model)
- [Dependencies](#dependencies)
- [Build](#build)
- [Diagnostics and Tests](#diagnostics-and-tests)

## Purpose

Torrent 7 is a minimal macOS 26 torrent client built with SwiftUI and
libtorrent-rasterbar 2.x. It targets Apple silicon as an arm64e app and leans
into Apple's pointer-authentication model, including PAC-enabled Swift, C, and
C++ code where the toolchain supports it. It also opts into Apple's Enhanced
Security entitlements, including hardened heap, dyld read-only, platform
restrictions, and checked allocations for hardware memory tagging / MTE-class
mitigation on supported systems. The app is designed around App Sandbox, static
third-party linking, and a hardened native app bundle.

The goal is not to be the largest torrent client. The goal is to keep the common
workflow fast and understandable: add a torrent or magnet link, choose where it
downloads, inspect transfer details when needed, and keep the security boundary
as small and explicit as possible.

## Features

- Add `.torrent` files, magnet links, Finder-opened torrents, and dragged files.
- Preview torrent contents before adding, including selected files and priorities.
- Pause, resume, remove, reannounce, force recheck, reveal in Finder, and inspect transfers.
- Configure global and per-torrent transfer limits, queue priority, labels, and discovery policy.
- Inspect trackers, web seeds, files, piece maps, peer sources, hashes, and transfer metadata.
- Filter the library by status, priority, labels, and tracker host.
- Show native notifications, Dock badges, and optional Dock transfer-rate labels.
- Persist resume data and active download-folder access across launches.

## Security and Hardening

Torrent 7 treats hardening as part of the product, not a release afterthought.

- **Pure native UI:** SwiftUI for the interface, with tiny AppKit helpers only where
  macOS still requires them, such as Dock and notification integration.
- **Swift safety:** Swift 6, strict concurrency checking, strict memory-safety
  checking, and pointer-authentication settings for the app target.
- **C++ bridge discipline:** C++23, RAII ownership, `std::span`, `std::expected`,
  bounded C ABI buffers, explicit error returns, and no exception crossing into Swift.
- **Input bounds:** caps for torrent files, magnets, file counts, tracker/web-seed
  counts, tracker host rows, snapshots, and piece-map data.
- **Static dependencies:** libtorrent and OpenSSL are linked statically. The final
  app bundle contains no third-party dylibs.
- **Signing:** hardened runtime, `restrict`, library validation, and narrow sandbox
  entitlements are enabled by the build script.
- **Enhanced Security entitlements:** hardened process, hardened heap, dyld
  read-only, platform restrictions, and checked allocations are enabled. The
  soft-mode checked-allocation entitlement is intentionally not used, so memory
  tag violations are treated as hard failures on systems that enforce them.
- **Compiler hardening:** arm64e builds use stack protection, PIE codegen, fortify,
  hidden visibility, pointer authentication, branch target identification,
  straight-line speculation hardening, jump-table hardening, typed allocation
  hardening, libc++ hardening, and trap-only UBSan for release bridge code.
- **Network privacy defaults:** a coarse libtorrent client identity is used, anonymous
  mode is enabled by default, DHT privacy lookups are enabled, and local discovery
  is disabled by default.

Torrent 7 can bind libtorrent connections to a selected interface and can use VPN
interfaces only, but hostname lookup still uses macOS system DNS. This is app-level
policy, not a system-wide VPN kill switch.

## Sandbox Model

Torrent 7 uses the App Sandbox with a deliberately small entitlement set:

- `com.apple.security.app-sandbox`
- `com.apple.security.network.client`
- `com.apple.security.network.server`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.files.bookmarks.app-scope`
- `com.apple.security.hardened-process`
- `com.apple.security.hardened-process.dyld-ro`
- `com.apple.security.hardened-process.hardened-heap`
- `com.apple.security.hardened-process.checked-allocations`
- `com.apple.security.hardened-process.enhanced-security-version-string`
- `com.apple.security.hardened-process.platform-restrictions-string`

Downloads are written to folders chosen by the user. Persistent access is stored
only as app-scoped security bookmarks for the default download folder and active
torrent-specific folders. Resume data lives in the app container and is written
with owner-only permissions. Downloaded files are explicitly quarantined by the
app bundle policy.

## Dependencies

The production app builds pinned dependencies into local static artifacts:

| Dependency | Version | Use |
| --- | --- | --- |
| libtorrent-rasterbar | 2.1.0 | Torrent engine |
| OpenSSL | 3.5.7 LTS | TLS support for libtorrent |
| Boost | 1.91.0 headers | Header-only Boost pieces used by libtorrent |

Homebrew supplies build tools only; it is not a runtime dependency source for the
app bundle. OpenSSL archives are verified with SHA-256 and a pinned upstream PGP
signing fingerprint. Boost is verified by SHA-256. Libtorrent is fetched from a
pinned tag and commit through a local source cache, then receives an ordered,
hashed patch series for Xcode compatibility, network boundaries, and storage
confinement. WebTorrent support stays disabled to avoid adding its unused
protocol and dependency surface.

## Build

Requirements:

- macOS 26 on Apple silicon
- Xcode 26 or newer
- Homebrew build tools

Install build tools:

```sh
brew install cmake ninja gnupg
```

Build the app:

```sh
Scripts/build-app.zsh
```

The output is:

```text
.build/App/Torrent 7.app
```

By default the app is ad-hoc signed for local development. This default does not
require a signing identity or Apple Developer credentials.

Verify the built app:

```sh
Scripts/verify-app.zsh
```

The verifier requires the signed entitlements to exactly match the canonical
allowlist in `Packaging/Torrent7.entitlements`; missing, changed, or unexpected
entitlements fail verification.

Use a shared dependency source cache if desired:

```sh
SOURCE_CACHE_DIR=/path/to/source-cache Scripts/build-app.zsh
```

### Distribution release

Store notarization credentials in the login keychain once, rather than placing
credentials in the repository or command history:

```sh
xcrun notarytool store-credentials torrent7-notary
```

Build, Developer ID sign, notarize, staple, verify with Gatekeeper, and archive
a distribution release with:

```sh
SIGN_IDENTITY="Developer ID Application: Example, Inc. (ABCDE12345)" \
EXPECTED_TEAM_ID="ABCDE12345" \
NOTARYTOOL_PROFILE="torrent7-notary" \
Scripts/release-app.zsh
```

The release script requires a release build, a Developer ID Application
identity with the expected Team ID, a trusted signing timestamp, an accepted
notarization result, a valid stapled ticket, and successful `spctl` assessment.
Its final output is:

```text
.build/Release/Torrent 7.zip
```

To re-verify an already notarized app:

```sh
EXPECTED_TEAM_ID="ABCDE12345" \
Scripts/verify-app.zsh --mode distribution
```

## Diagnostics and Tests

Run the Swift test suite:

```sh
Scripts/test-swift.zsh
```

Run the C++ bridge test suite:

```sh
Scripts/test-bridge.zsh
```

Run the focused libtorrent network and storage security regressions:

```sh
Scripts/test-libtorrent-security.zsh
```

Run the bridge static-analysis pass:

```sh
Scripts/analyze-bridge.zsh
```

`clang-tidy` support is optional:

```sh
brew install llvm
```

Build a sanitizer diagnostics app:

```sh
SANITIZER_DIAGNOSTICS=1 Scripts/build-app.zsh
```

Diagnostics builds use a separate dependency prefix, ASan/UBSan reporting
instrumentation for libtorrent and the bridge, and a separate app identity:

```text
.build/App-Diagnostics/Torrent 7 (debug).app
app.torrent7.debug
```
