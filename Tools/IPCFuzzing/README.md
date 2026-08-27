# Swift storage-boundary fuzzing

Developer-only coverage-guided fuzzing for the Swift parsers and authority
validators on the file-broker trust boundary.

The latest project Xcode and Homebrew LLVM are required:

```sh
brew install llvm
Scripts/verify-xcode.zsh
```

## Targets

- `ipc_json_preflight` feeds arbitrary bytes and both limit profiles to the
  production bounded JSON allocation preflight.
- `magnet_parser` feeds arbitrary UTF-8 and replacement-decoded text to the
  shared Swift magnet parser and checks typed Codable round trips and canonical
  file selections.
- `storage_broker_ipc` generates typed, malformed raw XPC dictionaries and
  exercises strict request/reply decoding, exact-key rejection, bounded binary
  fields, descriptor ownership, and canonical round trips.
- `storage_claim_validation` mutates structurally valid claims across digest,
  ownership, lifecycle, availability, file identity, directory topology, and
  path invariants. It also fuzzes hostile persisted JSON and ownership HMACs.
- `storage_manifest` feeds arbitrary bencoding to the production torrent
  manifest parser under standard and mutated tighter bounds, then checks
  deterministic parsing, advertised hash enforcement, canonical file indices,
  safe paths, and independently reproduced source digests.

The magnet, claim, and manifest targets depend on the same `TorrentMetainfo`
and `TorrentStorageAuthority` modules used by the app. SwiftPM links those
production modules into a fuzz-only dynamic library; no fuzz hook or
conditional is linked into the app.

## Build and run

```sh
Tools/IPCFuzzing/build-libfuzzer.sh
Tools/IPCFuzzing/run-libfuzzer.sh
```

One or more targets can be selected explicitly:

```sh
Tools/IPCFuzzing/build-libfuzzer.sh storage_broker_ipc storage_claim_validation
RUNS=1000000 Tools/IPCFuzzing/run-libfuzzer.sh storage_manifest
MAX_LEN=131072 LIBFUZZER_ARGS="-timeout=10" \
  Tools/IPCFuzzing/run-libfuzzer.sh storage_claim_validation
```

Crash artifacts are written to per-target directories below
`Tools/IPCFuzzing/libfuzzer-artifacts`. Learned corpus units live under its
`corpus` child; the checked-in `Tools/IPCFuzzing/corpus` tree contains seed
inputs only.

The fuzz support libraries are developer tools. Neither is linked into any
shipped app or extension.
