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

## Accepted peer-extension dialect

- BEP 10 extension handshakes use the same canonical, bounded bencode scanner.
  Every field is optional. Repeated handshakes are additive updates: an omitted
  extension mapping leaves prior state unchanged, ID `0` disables an extension,
  and positive peer-local IDs must be unique bytes. Client version text is valid
  UTF-8 and at most 256 bytes. Metadata size, listen port, request queue,
  completion age, external address, and upload-only values have explicit typed
  bounds.
- BEP 9 metadata messages consist of one canonical control dictionary followed
  by an uninterpreted binary suffix. Request (`0`) and reject (`2`) messages
  carry no suffix. Data (`1`) requires a positive bounded total size and a block
  of 1 through 16 KiB. Unknown message types retain their numeric type and exact
  suffix range so native policy can ignore them as the protocol requires. The
  whole message is limited to 17 KiB and advertised metadata to 4 MiB.
- BEP 11 peer exchange accepts exact six-byte IPv4 and eighteen-byte IPv6
  compact contacts. Optional flag strings must match their contact count; only
  public protocol bits 0 through 4 survive. Ports are nonzero, address encodings
  are family-canonical, and unspecified, multicast, broadcast, IPv4-mapped IPv6,
  duplicate, and add/drop-contradictory addresses are rejected. The initial
  message is bounded to 100 additions and 100 drops; libtorrent retains its
  stricter 50-plus-50 limit for later messages and all peer-admission policy.
- Unknown dictionary fields are skipped structurally within the same depth,
  token, key-byte, and container budgets. Noncanonical dictionaries are rejected
  rather than normalized and passed onward.

## Accepted HTTP tracker-response dialect

- Only the final decompressed bencoded HTTP response body crosses into Swift.
  Native code continues to own DNS, TCP, TLS, HTTP status and header parsing,
  chunk framing, redirects, proxy behavior, and gzip inflation.
- Announce and scrape dictionaries use the shared canonical iterative scanner.
  Intervals and swarm statistics are fixed-width and bounded. Scrapes select
  only the exact binary 20-byte info-hash key requested by libtorrent.
- IPv4 and IPv6 compact peer strings must be exact multiples of six and
  eighteen bytes. Dictionary peers retain only bounded hostnames made of ASCII
  letters, digits, dot, dash, underscore, or colon, an optional exact 20-byte
  peer ID, and a `UInt16` port. Invalid dictionary entries are skipped only when
  at least one entry remains valid, matching the pinned compatibility dialect.
- The decompressed body is capped at 512 KiB before the Swift callback. A
  response may produce at most 3,000 typed peers; tracker IDs, human-readable
  failure and warning strings, hostnames, nesting, tokens, containers, keys,
  and integer syntax have independent bounds. Human-readable strings must be
  valid UTF-8 without NUL.
- A failure reason is terminal: scheduling and tracker-ID fields may survive,
  but peers, warnings, external addresses, and swarm statistics cannot.
  Endpoint/source admission remains native after typed parsing.

This cutover is deliberately HTTP-body-only. UDP tracker replies remain in
libtorrent because they are fixed binary records parsed from bounded,
length-checked spans and do not expose the same generic bencode surface.
WebTorrent and I2P are disabled in the product build.

## Accepted DHT KRPC dialect

- One complete canonical bencoded dictionary is accepted per UDP datagram, up
  to 1,500 bytes, nesting depth 10, 500 values, 128 containers, and bounded key
  and integer syntax. Transaction IDs and binary hashes remain bytes.
- Query envelopes recognize `ping`, `find_node`, `get_peers`, `announce_peer`,
  and `sample_infohashes`. Unknown queries are future-compatible only when they
  carry a fixed 20-byte target. `want`, read-only, scrape, seed, and announce
  controls are returned as typed fields for native policy and state handling.
- BEP 44 `get` and `put` are identified, but their arbitrary values are not
  decoded. Torrent7 uses DHT only for peer discovery and returns an explicit
  unsupported-method error for those queries.
- Responses may contain at most 64 compact nodes, 256 peers, and 64 sample
  hashes. Both IPv4 and IPv6 compact records are decoded. The Mainline
  single-string aggregate IPv4 peer form is interpreted only for an IPv4
  source, matching the pinned libtorrent behavior.
- Error messages and announced names must be bounded valid UTF-8 without NUL.
  Missing or malformed query-specific fields retain the typed query identity so
  libtorrent can issue a protocol error; a malformed envelope is dropped.

The Swift callback is synchronous and stateless. Libtorrent retains UDP
transport, global-address and IP-filter admission, routing tables, transaction
matching, token verification, rate limits, and all outgoing bencoding. C++
revalidates and copies the fixed callback result before dispatch. If the parser
is absent or rejects a datagram, the packet is dropped; no production native
bdecode fallback exists. Generic request plugins, direct-response payloads, and
BEP 44 item APIs are not exposed through Torrent7's bridge.

## Native interoperability

Swift parsers emit narrow types such as `ParsedMagnet`, `ValidatedInfoCore`,
and `ValidatedTorrentEnvelope`. They never emit or control a general
`add_torrent_params` object.

Local `.torrent` files are decoded as an info core plus a top-level envelope.
BEP 9 input is decoded through the same core path directly from the exact bare
`info` dictionary; no synthetic envelope is created and no tracker, web-seed,
or piece-layer state can enter through swarm metadata.

The production local-file route is now raw `.torrent` bytes to the isolated
Swift parser, then a validated metainfo capsule to native code. The public C ABI
has no raw-torrent add operation. Passing bencoded data where a capsule is
required fails capsule framing before any libtorrent construction occurs.

Variable-sized native imports use a versioned flat capsule containing fixed-
width records and checked offsets into one byte blob. Capsules contain no
pointers, nested spans, Swift objects, C++ objects, function pointers, or
ABI-sized integers. Native code validates every range, derives redundant
values, copies all retained data, and commits fully constructed state
atomically.

Peer-extension parsing uses a smaller synchronous typed boundary. Libtorrent
passes one complete borrowed message to Swift and never exposes that pointer
after the callback. Handshake and metadata callbacks return fixed zero-reserved
POD records; PEX fills one caller-owned array of at most 200 fixed records.
Swift never allocates output memory for native ownership. C++ independently
checks every presence bit, enum, count, range, reserved byte, extension ID,
address, port, flag, and payload offset before constructing libtorrent values.
The callback context and each callback role are separately address-diversified
with pointer authentication on arm64e.

HTTP tracker responses use the same ownership pattern. Libtorrent supplies one
complete borrowed body and, for scrapes, the exact requested hash. Swift writes
one fixed result plus a caller-owned array of at most 3,000 peer records; all
retained strings are checked ranges into the borrowed body. C++ revalidates
every presence bit, enum, count, range, statistic, address family, hostname,
UTF-8 message, and reserved byte, constructs a temporary native response, and
commits it only after the full import succeeds. Swift retains no pointer and
transfers no allocation. The context and all callback roles have separate
arm64e pointer-authentication discriminators.

DHT messages use a still narrower synchronous boundary. Libtorrent supplies one
borrowed datagram and its source address family. Swift fills a fixed result and
caller-owned arrays of at most 64 nodes and 256 peers; sample hashes remain one
checked range of at most 64 fixed-width values. C++ rederives the query kind,
validates every optional-field combination and record, copies all retained
bytes, and commits only a complete owning `krpc_message`. Swift retains no
pointer and transfers no allocation. The context and all callback roles have
separate arm64e pointer-authentication discriminators.

The incoming BEP 10 handshake, BEP 9 control dictionary, BEP 11 compact-peer
dictionary, final HTTP tracker body, and inbound DHT KRPC datagram have no
native bdecode fallback.
Libtorrent still owns connection state, additive update semantics, metadata
hash verification and assembly, message-rate rules, peer filtering, tracker
transport, and admission. Its bencoding of outgoing self-generated messages is
intentionally unchanged.

### Metainfo capsule schema v1

Schema v1 is at most 96 MiB. Every multibyte integer is little-endian, every
offset is relative to the start of the capsule, and an absent range is encoded
as `(offset: 0, size: 0)`. Tables must appear once in the canonical order below;
the native reader rejects gaps other than required alignment padding.

| Bytes | Type | Meaning |
| --- | --- | --- |
| 0–3 | `u32` | Magic `0x494d3754` (`T7MI` in byte order) |
| 4–7 | `u16`, `u16` | Schema version `1`, header size `160` |
| 8–11 | `u32` | Total capsule size |
| 12–15 | four `u8` | Input kind, metainfo kind, content kind, private flag |
| 16–19 | `u16`, reserved | Envelope-presence bits, then zero |
| 20–23 | `u32` | Piece length |
| 24–63 | five ranges | Exact info, effective name, v1 hash, v2 hash, v1 piece hashes |
| 64–111 | six table descriptors | Files, path components, trackers, web seeds, piece layers, layer file indices |
| 112–127 | two ranges | Comment and creator |
| 128–135 | `i64` | Creation date, or `-1` when absent |
| 136–143 | `u32`, reserved | Payload offset, then zero |
| 144–153 | five `u16` | Record sizes: `32`, `8`, `16`, `24`, `4` |
| 154–159 | reserved | All zero |

Each table descriptor is `(u32 offset, u32 count)`. Tables are aligned and
encoded in this order: files to 8 bytes, then all remaining tables to 4 bytes;
the payload begins at the next 8-byte boundary.

| Record | Bytes | Fields |
| --- | ---: | --- |
| File | 32 | `i32 index`; component start/count; flags; `i64 size`; pieces-root range |
| Range | 8 | `u32 offset`; `u32 size` |
| Tracker | 16 | URL range; `u8 tier`; seven zero bytes |
| Piece layer | 24 | Root range; hash range; file-index start/count |
| File index | 4 | `i32` validated file index |

File roots and v1 piece hashes must point inside the copied exact-info range.
Layer bytes, paths, sources, and descriptions live in the payload. Bare BEP 9
info input must have zero envelope presence, tables, and descriptive ranges,
with a `-1` creation date. The native importer recomputes both advertised
identities, reconstructs file and Merkle state from typed records, owns every
retained byte, and never bdecodes the exact-info payload.

Exact original `info` bytes may be retained for info-hash calculation and BEP 9
metadata serving. They must never be decoded later, including through lazy or
compatibility accessors. Production has no fallback to `load_torrent_buffer`,
`parse_magnet_uri`, or generic bdecode after the corresponding route is cut
over. Libtorrent remains available as a corpus and differential-test oracle.

Resume persistence preserves the same boundary. Before calling libtorrent's
resume writer, the bridge removes `torrent_info` from the copied state and
stores the exact validated info dictionary as an opaque helper-private byte
string. A 64 MiB read cap applies before native resume-state decoding. During
restore, libtorrent may decode its own non-metainfo resume fields, but a
downstream guard rejects every conventional nested `info` dictionary. The
opaque bytes instead return through the same synchronous Swift `InfoCore`
callback and typed importer used for swarm metadata; native code then requires
an exact identity match and validates the reconstructed layout and storage
activation before adding the torrent. Legacy nested-metainfo resume records are
deleted rather than routed through a compatibility parser.
