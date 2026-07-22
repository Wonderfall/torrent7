# TorrentBridge Fuzzing

Developer-only fuzz harnesses for the C/C++ `TorrentBridge` boundary.

The suite uses `arm64` libFuzzer for coverage-guided discovery. This target is
intentional: Homebrew LLVM ships an `arm64` libFuzzer runtime, while the app can
continue to use `arm64e` elsewhere.

This suite intentionally lives under `Tools/BridgeFuzzing`. Fuzzing has its own
corpora, fuzz-only dependency builds, and generated artifacts, so keeping it
outside the app/package layout avoids product build churn and keeps the security
tooling self-contained.

## Targets

- `bridge_magnet`: inspects and adds mutated magnet C strings through both
  client-independent and session-backed bridge paths.
- `bridge_torrent_file`: passes mutated `.torrent` bytes to
  `TorrentClientAddTorrentFileData`.
- `bridge_resume_startup`: creates a temporary state directory with mutated
  `.fastresume` bytes, then exercises blocking and bounded asynchronous client
  destruction.
- `bridge_session_api`: runs short mutated operation sequences across add,
  preview, file priorities, settings, snapshots, detail batches, torrent
  options, queue movement, piece maps, wake/change, pause/resume/remove, save,
  network, health, authorized-root replacement, and alert APIs.

All harness runtime state is written to temporary directories and removed on
normal exit. Network access is blocked or disabled by the bridge settings used
by the harnesses.

## Build

The build creates separate fuzz-only OpenSSL/libtorrent archives under
`Tools/BridgeFuzzing/deps/arm64-libfuzzer`, leaving app deps untouched. The dependency
builder reads the already-cached source trees under `.build/deps`; if those
sources are missing, rebuild normal deps first.

```sh
Tools/BridgeFuzzing/build-libfuzzer.sh
```

Useful overrides:

```sh
Tools/BridgeFuzzing/build-libfuzzer.sh bridge_torrent_file
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
RUNS=10000 MAX_LEN=1048576 Tools/BridgeFuzzing/run-libfuzzer.sh bridge_torrent_file
LIBFUZZER_ARGS="-jobs=4 -workers=4" Tools/BridgeFuzzing/run-libfuzzer.sh bridge_session_api
```

Crash artifacts are written under `Tools/BridgeFuzzing/libfuzzer-artifacts`.
Learned corpus units are written under `Tools/BridgeFuzzing/libfuzzer-artifacts/corpus`;
the checked-in `Tools/BridgeFuzzing/corpus` tree is used as seed input only.
The run script disables ASan container-overflow checks by default because the
Homebrew libFuzzer runtime can trip them while enumerating larger corpus
directories. Pass `ASAN_OPTIONS=detect_container_overflow=1` to override that.

## Notes

These harnesses intentionally compile the bridge `.cpp` files directly from the
tool scripts. That avoids changing `Package.swift` or exposing test-only hooks
from production code.
