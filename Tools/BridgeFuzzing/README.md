# TorrentBridge Fuzzing

Developer-only fuzz harnesses for the C/C++ `TorrentBridge` boundary.

The suite uses Xcode's compiler and sanitizer runtime with Homebrew LLVM's
standalone `arm64` libFuzzer engine for coverage-guided discovery. This target
is intentional: Homebrew ships an `arm64` libFuzzer runtime, while the app can
continue to use `arm64e` elsewhere. Using Xcode's sanitizer runtime also keeps
mixed Swift/C++ targets on one compatible instrumentation ABI.

This suite intentionally lives under `Tools/BridgeFuzzing`. Fuzzing has its own
corpora, fuzz-only dependency builds, and generated artifacts, so keeping it
outside the app/package layout avoids product build churn and keeps the security
tooling self-contained.

## Targets

- `bridge_magnet`: mutates the flat parsed-magnet records, byte ranges, and
  session-backed native import path.
- `bridge_metainfo_capsule`: passes mutated typed-capsule bytes to
  `TorrentClientAddMetainfoCapsule`.
- `bridge_parser_callbacks`: sends arbitrary bare swarm metadata, peer
  extension messages, tracker bodies, and DHT datagrams through the exact
  production Swift callback sources and then through the production C++ typed
  import adapters. This exercises context retention, caller-owned record
  arrays, callback-owned capsule release, range validation, and atomic native
  commit under coverage guidance on both sides of the ABI.
- `bridge_resume_startup`: creates a temporary state directory with mutated
  `.fastresume` bytes, then exercises blocking and bounded asynchronous client
  destruction.
- `bridge_session_api`: runs short mutated operation sequences across add,
  preview, file priorities, settings, snapshots, detail batches, torrent
  options, queue movement, piece maps, wake/change, pause/resume/remove, save,
  network, health, payload-broker lifecycle, and alert APIs.
- `bridge_payload_broker`: drives the production native payload-provider
  adapter with valid and hostile callback tables, regular files in both access
  modes, directories, pipes, device files, closed descriptors, descriptors
  returned alongside errors, invalid sizes, and mutated callback arguments. It
  asserts descriptor closure, `CLOEXEC`, regular-file and write-access checks,
  errno propagation, exact activation forwarding, and balanced context
  retention.

All harness runtime state is written to temporary directories and removed on
normal exit. Network access is blocked or disabled by the bridge settings used
by the harnesses.

The capsule corpus may use a `hex:` prefix for checked-in binary seeds; the
capsule harness decodes those units before calling the production C ABI. Other
inputs are passed through unchanged.

## Build

The build creates separate fuzz-only BoringSSL/libtorrent archives under
`Tools/BridgeFuzzing/deps/arm64-libfuzzer`, leaving app deps untouched. The dependency
builder reads the already-cached source trees under `.build/deps`; if those
sources are missing, rebuild normal deps first.

```sh
Tools/BridgeFuzzing/build-libfuzzer.sh
```

Useful overrides:

```sh
Tools/BridgeFuzzing/build-libfuzzer.sh bridge_metainfo_capsule
JOBS=4 Tools/BridgeFuzzing/build-libfuzzer-deps.sh
ALLOW_EXTERNAL_LIBFUZZER_DEPS=1 \
  LIBFUZZER_DEPS_ROOT=/absolute/path/to/an/empty/cache \
  Tools/BridgeFuzzing/build-libfuzzer-deps.sh
```

An external dependency root must be empty on first use. The builder marks it as
owned, and only removes its fixed `prefix` and `build` children on later
rebuilds.

## Run

```sh
Tools/BridgeFuzzing/run-libfuzzer.sh
```

Useful overrides:

```sh
RUNS=1000000 Tools/BridgeFuzzing/run-libfuzzer.sh bridge_magnet
RUNS=10000 MAX_LEN=1048576 Tools/BridgeFuzzing/run-libfuzzer.sh bridge_metainfo_capsule
LIBFUZZER_ARGS="-jobs=4 -workers=4" Tools/BridgeFuzzing/run-libfuzzer.sh bridge_session_api
```

Crash artifacts are written under `Tools/BridgeFuzzing/libfuzzer-artifacts`.
Learned corpus units are written under `Tools/BridgeFuzzing/libfuzzer-artifacts/corpus`;
the checked-in `Tools/BridgeFuzzing/corpus` tree is used as seed input only.
The parser-callback harness also exercises a seed without one terminal newline,
which keeps checked-in text messages useful as accepted starting points.
The run script disables ASan container-overflow checks by default because the
Homebrew libFuzzer runtime can trip them while enumerating larger corpus
directories. Pass `ASAN_OPTIONS=detect_container_overflow=1` to override that.

## Notes

These harnesses intentionally compile the bridge `.cpp` files directly from the
tool scripts. That avoids changing `Package.swift` or exposing test-only hooks
from production code.

The parser-callback target also compiles the five production Swift callback and
capsule source files directly into an arm64, ASan-instrumented support library.
It imports only the C ABI declarations while the C++ half uses the fuzz-only
arm64 libtorrent build, avoiding any link to the app's arm64e native archives.
The fuzz-only callback-table factories live under this directory and are absent
from shipped products.
