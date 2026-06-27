# TorrentBridge Fuzzing

Developer-only fuzz harnesses for the C/C++ `TorrentBridge` boundary.

The suite uses `arm64` libFuzzer for coverage-guided discovery. This target is
intentional: Homebrew LLVM ships an `arm64` libFuzzer runtime, while the app can
continue to use `arm64e` elsewhere.

This suite intentionally lives under `Tools/Fuzzing`, even while it is the only
tool under `Tools`. Fuzzing has its own corpora, fuzz-only dependency builds,
and generated artifacts, so keeping it outside the app/package layout avoids
product build churn and keeps the security tooling self-contained.

## Targets

- `bridge_magnet`: calls `TorrentClientAddMagnet` with mutated C strings.
- `bridge_torrent_file`: passes mutated `.torrent` bytes to
  `TorrentClientAddTorrentFileData`.
- `bridge_resume_startup`: creates a temporary state directory with mutated
  `.fastresume` bytes, then creates and destroys a bridge client.
- `bridge_session_api`: runs short mutated operation sequences across add,
  preview, file priorities, settings, snapshots, detail batches, torrent
  options, queue movement, piece maps, wake/change, pause/resume/remove, save,
  network, and alert APIs.

All harness runtime state is written to temporary directories and removed on
normal exit. Network access is blocked or disabled by the bridge settings used
by the harnesses.

## Build

The build creates separate fuzz-only OpenSSL/libtorrent archives under
`Tools/Fuzzing/deps/arm64-libfuzzer`, leaving app deps untouched. The dependency
builder reads the already-cached source trees under `.build/deps`; if those
sources are missing, rebuild normal deps first.

```sh
Tools/Fuzzing/build-libfuzzer.sh
```

Useful overrides:

```sh
Tools/Fuzzing/build-libfuzzer.sh bridge_torrent_file
JOBS=4 Tools/Fuzzing/build-libfuzzer-deps.sh
```

## Run

```sh
Tools/Fuzzing/run-libfuzzer.sh
```

Useful overrides:

```sh
RUNS=1000000 Tools/Fuzzing/run-libfuzzer.sh bridge_magnet
RUNS=10000 MAX_LEN=1048576 Tools/Fuzzing/run-libfuzzer.sh bridge_torrent_file
LIBFUZZER_ARGS="-jobs=4 -workers=4" Tools/Fuzzing/run-libfuzzer.sh bridge_session_api
```

Crash artifacts are written under `Tools/Fuzzing/libfuzzer-artifacts`.
Learned corpus units are written under `Tools/Fuzzing/libfuzzer-artifacts/corpus`;
the checked-in `Tools/Fuzzing/corpus` tree is used as seed input only.
The run script disables ASan container-overflow checks by default because the
Homebrew libFuzzer runtime can trip them while enumerating larger corpus
directories. Pass `ASAN_OPTIONS=detect_container_overflow=1` to override that.

## Notes

These harnesses intentionally compile the bridge `.cpp` files directly from the
tool scripts. That avoids changing `Package.swift` or exposing test-only hooks
from production code.
