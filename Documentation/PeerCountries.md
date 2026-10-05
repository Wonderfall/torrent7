# Peer countries

The Peers tab uses an offline, country-only index derived from
[DB-IP Country Lite](https://db-ip.com/db/download/ip-to-country-lite), October
2026. IP geolocation data is provided by [DB-IP](https://db-ip.com/) under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Attribution also ships
in the application's ThirdPartyNotices.txt and native About panel.

No peer address leaves the app for a lookup. There is no reverse DNS, location
permission, web service, or runtime database download. Country flags describe an
estimated IP location, not a person's nationality or physical location; VPNs and
proxies may show their exit location. Local, reserved, documentation and unknown
addresses have no flag. The country name is available in the peer's tooltip.

## Updating

`Scripts/update-country-database.zsh` pins the monthly HTTPS download, SHA-256
and database date. It verifies the compressed archive before conversion. To
update, review a new DB-IP release, update these pins and this notice's release,
regenerate the resource, update the bundled-date test, and run the Swift checks.
Ship database changes with app releases; there is no background updater.

Pinned archive: `dbip-country-lite-2026-10.csv.gz`

SHA-256: `097426b8ddae89157d444a59ac1847e873f7943c32d52becc4371c8b0273af80`

The CSV is converted to sorted, disjoint IPv4 and IPv6 ranges. Adjacent ranges
with equal country codes are merged; uncovered ranges receive `ZZ` (unknown).
The checked-in `Packaging/PeerCountries.bin.lzfse` is 2,377,988 bytes and expands
losslessly to the original 8,449,572-byte index. It uses Apple's built-in LZFSE
compression, without a third-party compression or MMDB library.
LZFSE keeps decoder memory bounded; the system LZMA decoder accepts arbitrary
dictionary sizes from input without exposing a memory limit through its Swift API.

On first use, `TorrentCountryDatabase` decompresses and validates the resource
off the main actor. Swift's thread-safe static initialization runs this once per
app process, even when several torrent windows request it together. The decoded
immutable index is shared across windows and tab changes, and lookups use the
same binary search. It retains neither the compressed bytes nor a disk cache.
Failures are cached too. Caller cancellation is checked before and after the
shared initialization; it cannot leave a partially initialized cache. The index
carries no app authority.

Stored input and decoded output are each capped at 32 MiB. Decompression reads
bounded chunks and enforces the output limit before appending to the index.
The loader accepts only the compressed resource; there is no legacy file fallback.

## Binary format (version 1)

All integers are unsigned and big-endian. The 24-byte header contains the eight
ASCII bytes `T7CCDB01`, a UInt32 schema version, a UInt32 date (`YYYYMM01`), and
UInt32 IPv4 and IPv6 record counts. IPv4 records follow, then IPv6 records.
Each record has an inclusive upper address bound (4 or 16 network-order bytes)
and a two-byte uppercase country code. The lower bound is zero for the first
record and the preceding upper bound plus one otherwise. Both maps must end at
their address family's maximum. Unknown data uses `ZZ`.

The decoder rejects mismatched length, unsupported version, invalid date,
unordered boundaries, malformed codes and incomplete maps. It caps input at
32 MiB and each family at one million records. The build tool accepts the
upstream's unquoted, three-field CSV with the same range invariants and bounded
line, row and input sizes. It rejects overlaps rather than guessing precedence.

## Peer snapshots

The engine returns a coherent read-only snapshot of established BitTorrent IP
connections, excluding handshakes, connection attempts and web seeds. Each
request is bounded to 1,024 peers; the UI states when a larger list is truncated.
The helper validates counters and sanitizes bounded client strings before
publication. The XPC client validates lengths, enums, flags, counts and unique
endpoint/transport identities. Payload rates and byte totals are for this
connection; progress describes the peer's copy of the torrent.

SwiftUI owns both refresh tasks. Network snapshots refresh every three seconds
only while Peers is visible, and cancellation prevents stale results from being
published. Changing sort order prepares a new presentation without restarting
the network query. IP order is numeric, with endpoint tie-breaks for other
columns; row identity does not depend on progress, rate or country.
