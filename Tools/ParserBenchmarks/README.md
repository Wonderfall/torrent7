# Parser microbenchmarks

This suite compares the bounded Swift parsers with a native baseline built
against Torrent 7's pinned libtorrent 2.1.1. It is a diagnostic benchmark, not
a release gate.

Run it from the repository root:

```sh
Tools/ParserBenchmarks/run.zsh
```

The runner builds unsanitized `release` executables for the project's `arm64e`
target, generates one shared fixture set, and runs the binaries in
native/Swift/Swift/native order. Each pass uses three warm-up batches and 15
measured batches. The table is the mean of the two per-pass medians; raw JSONL
is retained under `.build/parser-benchmarks/results/`.

## Recorded baseline

Lower is better. These measurements were taken at
`ce35626a04c82a49df790677b326baa63969f076` in an Apple M3 Max virtual machine
with 12 cores and 32 GB RAM, macOS 26.6.2 (25G83), and Swift 6.3.3.

| Workload | Bytes | Native ns | Swift ns | Swift/native |
|---|---:|---:|---:|---:|
| `magnet_basic` | 60 | 108.80 | 12,863.87 | 118.23x |
| `magnet_rich` | 321 | 1,838.96 | 124,865.74 | 67.90x |
| `torrent_small` | 400 | 3,102.47 | 10,533.94 | 3.40x |
| `torrent_128` | 8,306 | 101,925.21 | 542,637.29 | 5.32x |
| `torrent_4096` | 254,323 | 3,112,835.42 | 15,789,638.53 | 5.07x |
| `info_128` | 8,019 | 78,334.29 | 498,319.25 | 6.36x |
| `info_4096` | 254,036 | 2,463,656.25 | 15,622,480.20 | 6.34x |
| `extension_handshake` | 216 | 868.29 | 7,059.32 | 8.13x |
| `ut_metadata` | 16,431 | 319.96 | 1,413.30 | 4.42x |
| `ut_pex` | 1,339 | 1,433.21 | 23,158.57 | 16.16x |
| `tracker_512` | 3,248 | 3,181.24 | 42,166.71 | 13.25x |
| `tracker_3000` | 18,177 | 15,724.12 | 215,920.29 | 13.73x |
| `dht_ping` | 56 | 381.79 | 2,329.65 | 6.10x |
| `dht_dense` | 1,489 | 507.81 | 6,394.28 | 12.59x |
| `dht_maxwork` | 1,030 | — | 17,081.39 | — |

The magnet and metainfo rows call libtorrent's public native parsers. The peer,
tracker, and DHT rows use libtorrent bdecode plus the corresponding native
field extraction because those retired parser paths no longer exist in the
patched engine. The Swift side additionally performs its current bounded,
canonical, schema, and duplicate validation. These are accepted-intersection
microbenchmarks, so the ratios are not estimates of end-to-end application
slowdown.

`dht_maxwork` has no native result: it is accepted at the Swift parser's
500-value limit, while libtorrent's decoder uses different token accounting
and rejects it at its 500-token ingress limit.
