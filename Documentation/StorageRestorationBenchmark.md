# Startup storage verification measurements

`Scripts/benchmark-storage-restoration.zsh` measures the production
`TorrentStorageRestorer.restore` operation. It creates temporary libraries using
the real destination planner, filesystem identities, and ownership tags, then
verifies that every claim and torrent location survived restoration. It never
opens the user's saved library. Fixtures are removed after each workload.

Run from the repository root:

```sh
STORAGE_RESTORATION_SAMPLES=2 Scripts/benchmark-storage-restoration.zsh \
  > .build/storage-restoration-benchmark.log 2>&1
```

`STORAGE_RESTORATION_SAMPLES` controls repeated passes after the first pass
(default 5, range 1–20). `STORAGE_RESTORATION_WORKLOAD=journal-deep`, for example,
selects one workload. The full suite creates hundreds of thousands of temporary
files and takes several minutes. The ordinary Swift suite leaves this benchmark
disabled. Timings are diagnostic observations, not CI latency assertions.

The runner uses the project's hardened, unsanitized `release` configuration and
`arm64e` target. Fixture creation, claim JSON encoding, result assertions, and
cleanup are outside the timed interval. Within it are parent validation, claim
root validation, broker installation, and every `statBatch` file check. The
benchmark raises only the injected measurement deadline to ten minutes so that
it can characterize work exceeding the production budget.

Files are app-owned empty placeholders with a declared size of 16 MiB and a
1 MiB torrent piece size. Restoration checks their identities and ownership;
it does not read payload contents. Workloads respect the file, path-depth,
path-component, and piece-count limits. The claim dictionary must encode below
120 MiB, leaving room beneath the journal's 128 MiB limit. `directoryDepth`
excludes the leaf filename. Nested files share one directory branch per 100 leaves.

## Recorded measurements

Measured on 2026-10-24 against production revision `110b761`, with this benchmark
added: Apple M3 Max virtual machine, 12 logical CPUs, 32 GiB RAM, internal virtual
SSD with APFS, macOS 27.0.1 (26A434), Xcode 27.1 (27A9275), Swift 6.4
(swiftlang-6.4.0.34.1), macOS 27.0 SDK. Each workload uses one parent authority.

The first pass follows fixture creation, which itself touches filesystem
metadata. **It is not a cold-cache startup measurement.** No caches are forcibly
evicted, and later passes reuse the same files. The test host is not the
sandboxed GUI. Bookmark acquisition, journal loading, and engine startup are
outside both this measurement and the restoration budget.

Times are seconds, rounded to milliseconds. The two repeated passes are shown
individually; no tail percentile is inferred from this sample size. Claim size
is the encoded claim dictionary, not the complete journal.

| Workload | Torrents | Files | Directory depth | Claim MiB | First pass | Repeat 1 | Repeat 2 |
|---|---:|---:|---:|---:|---:|---:|---:|
| `ordinary` | 100 | 10,000 | 2 | 2.03 | 0.621 | 0.619 | 0.620 |
| `file-limit` | 1 | 20,000 | 2 | 4.01 | 1.300 | 1.386 | 1.317 |
| `component-limit` | 1 | 20,000 | 9 | 5.60 | 3.041 | 3.089 | 2.992 |
| `depth-limit` | 1 | 6,250 | 31 | 3.63 | 3.140 | 3.130 | 3.143 |
| `torrent-limit` | 20,000 | 20,000 | 0 | 18.36 | 1.193 | 1.214 | 1.221 |
| `large-library` | 1,000 | 100,000 | 2 | 20.29 | 7.207 | 7.022 | 7.075 |
| `dense-library` | 10 | 200,000 | 2 | 40.11 | 14.453 | 14.036 | 14.184 |
| `journal-dense` | 28 | 560,000 | 2 | 112.30 | 41.028 | 41.138 | 41.010 |
| `journal-deep` | 32 | 200,000 | 31 | 116.20 | 104.779 | 104.173 | 104.642 |

The original 30-second ceiling cannot accommodate the last two supported
workloads even with warm metadata caches. The default is therefore **five
minutes**, about 2.9 times the longest observed pass. This headroom is an
engineering policy choice. It retains a finite attempt while accommodating the
measured large-library cases. Small libraries finish immediately after their
verification; the ceiling does not add a minimum delay.

The cost depends on both file count and path traversal: the deeply nested
200,000-file case took over seven times as long as the shallow case with the
same file count. Torrent count alone is not a sufficient budget predictor.

Each workload prints a `STORAGE_RESTORATION` JSON record with full-precision
observations and encoded claim bytes to standard output. The command above
captures those records and reproduces the recorded calibration's sample count.

## Interpretation

These observations establish local filesystem verification cost, not a latency
guarantee for every storage device. Cold caches, external disks, filesystem
contention, and host scheduling may take longer. Repeat the benchmark on the
storage and hardware being investigated before drawing conclusions about them.

The budget remains an elapsed-time policy checked between filesystem calls.
It cannot preempt a blocked kernel call. Moving verification off MainActor
provides UI responsiveness; cancellation and expiry discard the entire staged
registry without changing the persisted claims or payloads. Increasing the
budget only allows a longer verification attempt before startup reports failure.
