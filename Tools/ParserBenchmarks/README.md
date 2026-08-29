# Parser microbenchmarks

This suite compares the bounded Swift parsers with a native baseline built
against Torrent 7's pinned libtorrent 2.1.1. It is a diagnostic benchmark, not
a production latency benchmark. The runner does enforce deliberately broad
absolute Swift p99 regression tripwires from `p99-budgets.tsv`; native/Swift
ratios are reported only as context and never gate the run.

Run it from the repository root:

```sh
Tools/ParserBenchmarks/run.zsh
```

The runner builds unsanitized `release` executables for the project's `arm64e`
target, generates one shared fixture set, and runs the binaries in
native/Swift/Swift/native order. Each pass uses three warm-up batches and 20
measured batches. The table is the mean of the two per-pass distributions and
reports median throughput plus p95, p99, and maximum batch-average latency.
With 20 deterministic batches, p99 is intentionally the observed maximum; it
is a scheduling-tail sentinel rather than a claim about per-message production
latency. Raw JSONL is retained under `.build/parser-benchmarks/results/`.
Each Swift pass is checked independently, so averaging cannot hide a slow pass.

The p99 limits are unsanitized Apple-Silicon release-build tripwires rather
than service-level objectives. They leave several times the measured headroom
to tolerate host variation while still catching algorithmic regressions. The
parsers' byte, value, depth, container, key-byte, and record-count limits remain
the hard resource-security controls.

## Recorded baseline

Lower is better. These measurements were taken over the production code at
`9e31ff3` with the benchmark changes in this directory, in an Apple M3 Max
virtual machine with 12 cores and 32 GB RAM, macOS 26.6.2 (25G83), and Swift
6.3.3.

| Workload | Bytes | Native median ns | Swift median ns | Swift p95 ns | Swift p99 ns | Swift max ns | msg/s | MiB/s | Swift/native |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `magnet_basic` | 60 | 109.94 | 10,829.42 | 11,082.99 | 11,158.31 | 11,158.31 | 92,341 | 5.28 | 98.50x |
| `magnet_rich` | 321 | 1,792.50 | 111,285.65 | 112,334.03 | 113,186.86 | 113,186.86 | 8,986 | 2.75 | 62.08x |
| `torrent_small` | 400 | 3,100.80 | 8,069.44 | 8,281.76 | 8,310.85 | 8,310.85 | 123,924 | 47.27 | 2.60x |
| `torrent_128` | 8,306 | 101,157.62 | 338,236.88 | 349,574.67 | 352,558.50 | 352,558.50 | 2,957 | 23.42 | 3.34x |
| `torrent_4096` | 254,323 | 3,119,843.72 | 9,600,626.03 | 9,803,634.38 | 9,889,462.50 | 9,889,462.50 | 104 | 25.26 | 3.08x |
| `info_128` | 8,019 | 78,539.33 | 305,628.88 | 314,254.17 | 317,738.08 | 317,738.08 | 3,272 | 25.02 | 3.89x |
| `info_4096` | 254,036 | 2,449,206.25 | 9,590,383.30 | 10,260,096.88 | 13,512,140.62 | 13,512,140.62 | 104 | 25.26 | 3.92x |
| `extension_handshake` | 216 | 887.06 | 6,152.12 | 6,302.21 | 6,351.56 | 6,351.56 | 162,546 | 33.48 | 6.94x |
| `extension_unordered_maxkeys` | 64,514 | 19,402.08 | 938,657.50 | 959,794.58 | 967,015.52 | 967,015.52 | 1,065 | 65.55 | 48.38x |
| `ut_metadata` | 16,431 | 329.95 | 1,353.09 | 1,372.60 | 1,401.62 | 1,401.62 | 739,049 | 11,580.77 | 4.10x |
| `ut_pex` | 1,339 | 1,400.74 | 23,467.63 | 24,271.15 | 24,694.59 | 24,694.59 | 42,612 | 54.41 | 16.75x |
| `tracker_512` | 3,248 | 3,156.96 | 38,553.35 | 39,375.99 | 39,500.30 | 39,500.30 | 25,938 | 80.34 | 12.21x |
| `tracker_3000` | 18,177 | 14,397.42 | 208,661.54 | 216,692.87 | 222,542.79 | 222,542.79 | 4,792 | 83.08 | 14.49x |
| `tracker_unordered_maxkeys` | 494,594 | 17,746.88 | 6,531,755.20 | 6,681,039.58 | 6,901,167.70 | 6,901,167.70 | 153 | 72.21 | 368.05x |
| `dht_ping` | 56 | 391.87 | 2,366.12 | 2,426.22 | 2,441.28 | 2,441.28 | 422,633 | 22.57 | 6.04x |
| `dht_dense` | 1,489 | 538.74 | 6,004.01 | 6,118.05 | 6,151.80 | 6,151.80 | 166,555 | 236.51 | 11.14x |
| `dht_unordered_maxkeys` | 1,415 | 2,862.81 | 42,913.46 | 44,527.60 | 44,753.48 | 44,753.48 | 23,303 | 31.45 | 14.99x |
| `dht_maxwork` | 1,030 | — | 18,517.22 | 19,423.12 | 20,100.51 | 20,100.51 | 54,004 | 53.05 | — |

The magnet and metainfo rows call libtorrent's public native parsers. The peer,
tracker, and DHT rows use libtorrent bdecode plus the corresponding native
field extraction because those retired parser paths no longer exist in the
patched engine. The Swift side additionally performs its current bounded,
canonical-scalar, schema, and duplicate-key validation. The three
`unordered_maxkeys` rows use reverse-ordered unique keys with long common
prefixes near their respective input and aggregate key-byte limits. These are
accepted-intersection microbenchmarks, so the ratios are not estimates of
end-to-end application slowdown.

`dht_maxwork` has no native result: it is accepted at the Swift parser's
500-value limit, while libtorrent's decoder uses different token accounting
and rejects it at its 500-token ingress limit.

Allocation counts and peak temporary memory are intentionally not inferred
from RSS or allocator high-water marks: both include Swift runtime state,
allocator caches, and earlier workloads, so attributing them to one parse would
be misleading. Use Instruments' Allocations template when investigating a
specific workload. The reproducible automated checks are absolute latency,
throughput, and the parsers' independently tested hard resource limits.
