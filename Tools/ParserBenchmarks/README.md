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
`e430173` with the reporting changes in this directory, in an Apple M3 Max
virtual machine with 12 cores and 32 GB RAM, macOS 26.6.2 (25G83), and Swift
6.3.3.

| Workload | Bytes | Native median ns | Swift median ns | Swift p95 ns | Swift p99/max ns | msg/s | MiB/s | Swift/native |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `magnet_basic` | 60 | 109.05 | 10,848.78 | 11,002.46 | 11,040.62 | 92,176 | 5.27 | 99.48x |
| `magnet_rich` | 321 | 1,809.69 | 111,730.66 | 112,462.39 | 112,724.99 | 8,950 | 2.74 | 61.74x |
| `torrent_small` | 400 | 3,071.38 | 10,614.50 | 10,887.07 | 10,948.14 | 94,211 | 35.94 | 3.46x |
| `torrent_128` | 8,306 | 101,403.75 | 541,521.67 | 559,482.75 | 581,456.04 | 1,847 | 14.63 | 5.34x |
| `torrent_4096` | 254,323 | 3,112,829.17 | 15,984,862.50 | 16,238,947.93 | 16,258,947.93 | 63 | 15.17 | 5.14x |
| `info_128` | 8,019 | 79,220.71 | 509,576.29 | 515,799.38 | 516,233.79 | 1,962 | 15.01 | 6.43x |
| `info_4096` | 254,036 | 2,468,700.00 | 15,902,768.75 | 16,086,320.82 | 16,146,777.07 | 63 | 15.23 | 6.44x |
| `extension_handshake` | 216 | 886.07 | 6,058.42 | 6,172.50 | 6,214.09 | 165,059 | 34.00 | 6.84x |
| `ut_metadata` | 16,431 | 332.46 | 1,343.63 | 1,374.08 | 1,386.21 | 744,255 | 11,662.34 | 4.04x |
| `ut_pex` | 1,339 | 1,347.99 | 23,199.71 | 23,624.71 | 24,454.44 | 43,104 | 55.04 | 17.21x |
| `tracker_512` | 3,248 | 3,146.72 | 38,610.94 | 39,422.02 | 39,836.23 | 25,899 | 80.22 | 12.27x |
| `tracker_3000` | 18,177 | 14,762.75 | 206,584.04 | 209,581.58 | 211,843.12 | 4,841 | 83.91 | 13.99x |
| `dht_ping` | 56 | 383.42 | 2,348.72 | 2,392.16 | 2,428.01 | 425,764 | 22.74 | 6.13x |
| `dht_dense` | 1,489 | 547.29 | 5,958.02 | 6,106.98 | 6,126.39 | 167,841 | 238.34 | 10.89x |
| `dht_maxwork` | 1,030 | — | 18,499.82 | 18,931.90 | 18,990.34 | 54,055 | 53.10 | — |

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

Allocation counts and peak temporary memory are intentionally not inferred
from RSS or allocator high-water marks: both include Swift runtime state,
allocator caches, and earlier workloads, so attributing them to one parse would
be misleading. Use Instruments' Allocations template when investigating a
specific workload. The reproducible automated checks are absolute latency,
throughput, and the parsers' independently tested hard resource limits.
