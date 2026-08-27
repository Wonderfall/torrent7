# Metainfo parsing boundary

Torrent7 replaces native parsing of untrusted torrent protocol bytes with
bounded, protocol-specific Swift parsers. A route is migrated only when the
original bytes can no longer reach the retired native parser in production.
Validation followed by passing the same bytes to libtorrent is not a cutover.

## Accepted metainfo dialect

- Bencoding is canonical: integers and string lengths use their shortest
  representation, dictionary keys are strictly ordered and unique, nesting and
  token counts are bounded, and trailing data is rejected.
- V1, v2, hybrid, and rootless-v2 layouts are supported. A synthesized display
  name for rootless metadata is not treated as a hash-defining wire name.
- Paths and human-readable fields used by Torrent7 must be valid UTF-8. Unsafe,
  ambiguous, duplicate, case-equivalent, normalization-equivalent, traversing,
  and symlink paths are rejected rather than sanitized.
- SSL torrents and mutable-torrent semantics are unsupported. Top-level DHT
  bootstrap nodes are ignored by product policy.
- V2 piece layers may be wholly absent. When a piece-layer dictionary is
  supplied, it must completely and correctly describe every applicable file;
  partial, unknown, duplicate, malformed, and root-mismatching layers fail.
- File and aggregate payload sizes are checked against both product work
  budgets and the fixed-width limits of the native importer. Empty v2 files do
  not carry a semantic pieces root in the validated core.
- Unknown extension fields are skipped structurally under the same byte, token,
  depth, and work budgets. They never grant engine or storage authority.
- Tracker and web-seed syntax is parsed separately from network admission.
  Source-policy checks remain authoritative after parsing.

## Accepted magnet dialect

- V1 and v2 exact topics are supported, including hybrid magnets. Repeated
  equal topics are accepted and conflicting topics are rejected.
- Percent decoding is strict. A literal `+` decodes as a space to preserve the
  current Torrent7 and pinned-libtorrent behavior.
- `tr`, `ws`, and numeric-suffixed forms such as `tr.7` are recognized.
  Trackers are limited to HTTP, HTTPS, and UDP URLs; web seeds are limited to
  HTTP and HTTPS URLs. Authorities, ports, escapes, and aggregate retained bytes
  are bounded before the typed value is created.
- Display names are never storage names. Tracker tiers and select-only hints are
  canonical bounded data for a later engine-policy stage, not authority-bearing
  `add_torrent_params` input.
- Peer and DHT bootstrap hints remain ignored unless a later product policy
  explicitly authorizes them.
- Raw magnet text terminates in Swift. XPC carries `ParsedMagnet`, and the C ABI
  accepts only fixed hashes plus checked flat ranges. Test code may use
  libtorrent as a differential oracle; production contains no raw-magnet bridge
  entry point or embedded-`.torrent` fallback to `parse_magnet_uri`.

## Native interoperability

Swift parsers emit narrow types such as `ParsedMagnet`, `ValidatedInfoCore`,
and `ValidatedTorrentEnvelope`. They never emit or control a general
`add_torrent_params` object.

Local `.torrent` files are decoded as an info core plus a top-level envelope.
BEP 9 input is decoded through the same core path directly from the exact bare
`info` dictionary; no synthetic envelope is created and no tracker, web-seed,
or piece-layer state can enter through swarm metadata.

Variable-sized native imports use a versioned flat capsule containing fixed-
width records and checked offsets into one byte blob. Capsules contain no
pointers, nested spans, Swift objects, C++ objects, function pointers, or
ABI-sized integers. Native code validates every range, derives redundant
values, copies all retained data, and commits fully constructed state
atomically.

Exact original `info` bytes may be retained for info-hash calculation and BEP 9
metadata serving. They must never be decoded later, including through lazy or
compatibility accessors. Production has no fallback to `load_torrent_buffer`,
`parse_magnet_uri`, or generic bdecode after the corresponding route is cut
over. Libtorrent remains available as a corpus and differential-test oracle.
