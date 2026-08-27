# Native parser inventory

This inventory applies to Torrent7's pinned libtorrent 2.1.1 build. It records
the parser boundary after the selective Swift cutovers described in
`MetainfoParsing.md`. A parser symbol merely existing in the static archive does
not make it a production route; reachability through the shipped bridge and
current feature configuration is the relevant property.

The phase-10 decision is to stop the current migration sequence here. No
clearly separable part of peer wire, uTP, protocol encryption, or web-seed
streaming would remove a meaningful native trust boundary without duplicating
their connection state machines. Those implementations remain native and are
covered by the pinned upstream fuzz targets and Torrent7's sanitizer and
security suites.

## Retired external-input parser routes

These raw inputs no longer reach their former native semantic parser in
production:

| Input | Production boundary | Native enforcement |
| --- | --- | --- |
| `.torrent` preview | Shared bounded Swift metainfo parser | No preview XPC or native parse |
| Magnet text | Swift `ParsedMagnet`, then flat hashes and checked ranges | No raw-magnet C ABI or `parse_magnet_uri` fallback |
| Local `.torrent` add | Swift `ValidatedInfoCore` plus envelope, then capsule | Capsule-only C ABI and typed `torrent_info` importer |
| Assembled BEP 9 info dictionary | Synchronous Swift `InfoCore` callback | Hash-first typed import; rejection is latched |
| Persisted exact info dictionary | Opaque resume byte string, then the same Swift callback | Nested resume `info` is rejected by the pinned reader |
| Incoming BEP 10, BEP 9 control, and BEP 11 dictionaries | Synchronous Swift peer-protocol callbacks | Typed fixed records; no native bdecode fallback |
| Final decompressed HTTP tracker body | Synchronous Swift announce/scrape callback | 512 KiB input cap and typed response import |
| Incoming DHT KRPC datagram | Synchronous Swift DHT callback | 1,500-byte cap, typed owning message, no fallback |

The `swarm_info_parser` fuzz target attacks arbitrary bare dictionaries without
requiring a valid outer torrent. The `bridge_parser_callbacks` target compiles
the exact production Swift callback and capsule sources, then passes their
outputs through the real native adapters for every callback route under
coverage guidance and sanitizers.

`Scripts/analyze-bridge.zsh` fails if the production bridge regains the retired
magnet or raw-torrent APIs, or if the patched swarm, peer-extension, HTTP
tracker-body, DHT, or resume-metainfo routes regain a native fallback.

## Reachable native parsers retained by design

| Surface and pinned source | Exposure in Torrent7 | Why it remains native | Existing controls and evidence |
| --- | --- | --- | --- |
| BitTorrent handshake, message framing, and core peer messages: `bt_peer_connection.cpp`, `peer_connection.cpp`, `receive_buffer.cpp` | Outgoing TCP and uTP are enabled during normal network operation. Incoming peers are optional and off by default. | Length prefixes, partial receive buffers, choke/request/piece state, disk queues, the piece picker, backpressure, and teardown form one hot state machine. Moving only the first fields would not remove the consequential native state transitions. | Libtorrent's `peer_conn` and `pe_conn` fuzzers; Torrent7 extension integration and sanitizer suites; BEP 10, BEP 9 control, and PEX payload dictionaries already leave this path for Swift. |
| uTP packet and extension processing: `utp_socket_manager.cpp`, `utp_stream.cpp` | Outgoing uTP is enabled during normal operation; incoming uTP follows the incoming-connections setting and is off by default. | Header parsing is coupled to sequence windows, SACK, retransmission, congestion control, MTU discovery, timers, and socket teardown. A callback would add a second representation without retiring the native protocol machine. | Libtorrent's `utp` and `utp_stream` fuzzers; fixed datagram/header bounds; bridge ASan, UBSan, and TSan profiles. |
| Message Stream Encryption and encrypted peer handshake: `pe_crypto.cpp` and `bt_peer_connection.cpp` | Protocol encryption is allowed by default for peer connections. | Parsing and negotiation directly mutate Diffie-Hellman, cipher, receive-buffer, and peer-connection state. The candidate boundary is neither flat nor independently committable. | Libtorrent's `pe_crypto_state` and `pe_conn` fuzzers; focused normal and degenerate-key tests in `Scripts/test-libtorrent-security.zsh`; BoringSSL is not used for this BitTorrent protocol layer. |
| URL, HTTP transport, redirects, headers, chunking, and gzip: `parse_url.cpp`, `http_parser.cpp`, `http_connection.cpp`, `http_tracker_connection.cpp`, `gzip.cpp`, `puff.cpp` | Trackers are active network sources; HTTPS is preferred while HTTP and UDP remain available. | Tracker-body bencode is gone, but transport parsing is shared with connection, proxy, redirect, TLS, buffering, and decompression state. Replacing it would be a tracker transport project rather than a selective parser cutover. | Typed source-policy validation before use; SSRF and global-address policy; certificate and hostname validation; 512 KiB bottled and inflated tracker-body cap; `http_parser`, `http_tracker`, and `gzip` upstream fuzzers plus focused redirect, TLS, and parser tests. |
| HTTP web-seed streaming and range/chunk handling: `web_connection_base.cpp`, `web_peer_connection.cpp`, plus the shared HTTP files above | A typed metainfo source may activate a web seed; HTTPS is required by default. | Response ranges and chunks are consumed incrementally into piece requests and are coupled to redirects, peer state, rate control, disk writes, cancellation, and retry behavior. A header-only Swift callback would retain most of the native attack surface. | Typed URL admission, HTTPS default, SSRF/IP-filter checks, upstream `web_seed` fuzzer, and focused proxy, certificate, redirect, and endpoint tests. |
| UDP tracker replies: `udp_tracker_connection.cpp` | UDP trackers remain an allowed fallback. | Replies are fixed binary records read from bounded spans and tied to transaction matching and tracker scheduling. This is separable, but its marginal safety value is below the migrated generic bencode surfaces. | Size checks before field reads, transaction validation, endpoint policy, upstream `udp_tracker` fuzzer, and tracker security tests. |

Native DNS, TCP/IP, and TLS record parsing performed by the operating system,
Boost.Asio, or BoringSSL is outside this libtorrent parser inventory. It remains
inside the isolated helper's network boundary.

## Optional native network parsers

These paths are compiled, but require an explicit product setting:

| Surface | Activation | Current disposition |
| --- | --- | --- |
| UPnP SSDP, HTTP, SOAP, and XML in `upnp.cpp` and `xml_parse.cpp` | Incoming connections and port forwarding must both be enabled. Both are off by default; VPN-only mode disables effective port forwarding. | Retain. It is local-network exposed when enabled and has upstream `upnp` and `xml_parse` fuzzers. Reassess before making port forwarding a default. |
| NAT-PMP in `natpmp.cpp` | Same effective port-forwarding gate as UPnP. | Retain. The protocol is fixed binary and has an upstream `natpmp` fuzzer. |
| Local Service Discovery in `lsd.cpp` and the shared HTTP parser | The global LSD setting and per-torrent policy must enable it. Both defaults are off, and VPN-only mode disables the service. | Retain. It is a relatively separable future candidate if the feature becomes default or sanitizer evidence changes its priority. |

Incoming TCP and uTP do not create separate parsers; enabling them increases the
number of peers that can reach the retained peer and uTP state machines.

## Helper-private and generated parsing

- `read_resume_data.cpp` still bdecodes bounded helper-private resume state such
  as priorities, counters, peer caches, and source state. Files are read through
  descriptor-relative, no-follow persistence code with a 64 MiB cap. Exact
  metainfo is not part of that semantic parse: it is opaque, returns through
  Swift, and a conventional nested `info` dictionary is rejected. The
  `bridge_resume_startup` fuzzer covers corrupted resume files.
- Libtorrent continues to bencode its own outgoing messages and generated
  persistence values. Logging is disabled, so the outgoing PEX diagnostic
  bdecode block is compiled out.
- `torrent_info.cpp`, `load_torrent.cpp`, and `magnet_uri.cpp` remain in the
  static archive for libtorrent internals and test oracles. The production
  bridge has no raw-input call site for them. Deprecated APIs, including the
  lazy `torrent_info::info()` decoder, are compiled out by the high ABI build.
- Session-state bdecode APIs are compiled into libtorrent, but Torrent7 creates
  `session_params` directly and exposes no load-state bridge operation.
- DHT packet-alert formatting, direct-response decoding, and arbitrary BEP 44
  item storage exist in the library. Torrent7 excludes DHT packet/log alerts,
  exposes no generic direct-request API, and its typed KRPC path returns an
  unsupported-method error for BEP 44 get/put before arbitrary values can reach
  item storage.
- SOCKS and HTTP proxy protocol parsers are compiled with libtorrent, but the
  shipped settings model and bridge expose no proxy configuration and leave the
  proxy type at `none`.

## Build-excluded surfaces

The dependency build disables deprecated functions, I2P, WebTorrent/RTC,
libtorrent logging, mutable torrents, SSL torrents, and streaming piece-deadline
features. The CMake options are pinned in `Scripts/build-deps.zsh`; changing one
is a parser-reachability change and requires updating this inventory and the
security gates.

## Evidence and reassessment policy

The repository contains no production crash-history dataset or parser-specific
runtime telemetry. That absence is not evidence that a native parser is safe.
The current decision instead rests on reachable code review, state-machine
coupling, fixed resource bounds, upstream coverage-guided harnesses, and
Torrent7's focused bridge and libtorrent security suites.

The next separable candidates, if new evidence justifies more work, are:

1. UDP tracker response records, to complete the typed tracker-response boundary.
2. LSD messages, especially if local discovery becomes enabled by default.
3. UPnP XML/SSDP, especially if port forwarding becomes enabled by default.

Peer wire, uTP, encryption, and web-seed streaming should be reconsidered only
when at least one of these triggers exists:

- a crash, sanitizer finding, or reproducible upstream issue identifies a
  bounded sub-parser;
- coverage review finds an externally reachable branch without a practical
  native fuzz harness;
- a protocol slice can return a flat typed value and commit atomically without
  duplicating connection state;
- a currently optional feature becomes enabled by default or gains a new bridge
  entry point;
- a pinned libtorrent upgrade changes parser ownership, limits, or fallback
  reachability.

Any new cutover must keep the established completion rule: Swift consumes the
raw external bytes, native code receives a narrow typed representation, and the
old production parser route is removed or poisoned rather than retained as a
fallback.
