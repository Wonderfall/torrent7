# Dependency patches

The ordered manifests are authoritative:

- [libtorrent](../libtorrent-patch-series.sh): 25 patches against the pinned commit.
- [Boost](../boost-patch-series.sh): 4 patches against the pinned source archive.
- [BoringSSL](../boringssl-patch-series.sh): 2 patches against the pinned commit.

Each patch describes one final implementation and includes its dependency-side
tests where applicable. Keep independently testable protocol boundaries separate.
Fold extensions of the same implementation into its existing patch so the series
does not introduce temporary state machines that later patches replace.

## Libtorrent

Names below omit the `libtorrent-2.1.1-` prefix and `.patch` suffix and follow
application order. Apply the complete series; the dependency notes identify
important relationships, not alternative supported patch subsets.

| Patch | Purpose and dependencies |
| --- | --- |
| `packet-flexible-array` | Replaces the UDP packet buffer’s fake one-byte tail with a true flexible array under strict bounds hardening. |
| `network-security` | Base network endpoint, redirect, peer admission, and transport hardening. |
| `storage-confinement` | Confined filesystem operations and storage safety. |
| `file-provider` | Pathless payload descriptors, building on storage confinement; rejects unsupported storage backends and provider-to-path fallback. |
| `bounded-pread-hashing` | Bounds pread hashing memory independently of torrent piece size. |
| `listen-socket-id` | Defines listen-socket ID allocation in one translation unit. |
| `session-settings-lock` | Uses one scoped lock for settings copy assignment. |
| `disabled-streaming-fields` | Keeps disabled streaming configuration internally consistent. |
| [typed-allocation](libtorrent-2.1.1-typed-allocation.patch) | Typed pool and disk allocation, tracker pools, container allocation, and remaining temporary buffers. |
| `indirect-operation-pac` | Authenticates native indirect-operation callbacks. |
| `boringssl-compatibility` | Adapts the TLS integration to BoringSSL. |
| `boringssl-system-trust` | Uses macOS certificate trust and the constrained BoringSSL client policy. |
| `outbound-only-dht` | Separates DHT peer discovery from advertising incoming peer reachability. |
| [global-address-policy](libtorrent-2.1.1-global-address-policy.patch) | One session NAT64 discovery state for DHT, peers, web seeds, and HTTP/UDP trackers; endpoint admission, generation invalidation, PEX/holepunch policy, and private resume-peer rejection. Web-seed DNS callbacks carry the session generation, cached endpoints are rechecked before connection, and pending IPv6 never disables a seed. Builds on base network and outbound DHT changes. |
| `private-tracker-isolation` | Restricts private torrents to their authorized tracker generation; uses the shared peer policy. |
| `tracker-policy-generation` | Rejects stale public and private tracker callbacks after tracker-list replacement. |
| `current-dht-fallback` | Evaluates DHT fallback eligibility against current tracker state. |
| `dht-disable-late-response` | Discards outstanding DHT responses after the torrent disables DHT. |
| `revive-removed-web-seeds` | Re-enables a removed web seed when it is added again. |
| `disable-embedded-magnet-uri` | Rejects metainfo that would fall back to an embedded magnet URI. |
| [external-metainfo-import](libtorrent-2.1.1-external-metainfo-import.patch) | Imports preparsed metadata, requires the external swarm metadata parser, and rejects native resume-metainfo parsing. Retains the parser independently of add parameters. |
| `external-peer-message-parser` | External typed BEP 10/9/11 parsing; builds on peer policy and metainfo import. |
| `external-http-tracker-parser` | External typed tracker-body parsing; retains the shared address and TLS policies. |
| `external-dht-message-parser` | External typed DHT message parsing; retains outbound, address, and late-response policies. |
| `fail-closed-interface-binding` | Makes failed device binding terminal for peer, listener, and HTTP sockets. |

The shared address-policy patch includes the former tracker-endpoint, DHT-global,
peer-source, session-NAT64, and tracker-session-NAT64 changes. Its session state is
introduced in its final shared location, without separate tracker, DHT, or web-seed discovery
implementations that would immediately be replaced.

## Boost and BoringSSL

| Patch | Purpose |
| --- | --- |
| `boost-1.92.0-asio-operation-pac.patch` | Scheduler and reactor callback authentication. |
| [boost-1.92.0-asio-executor-pac.patch](boost-1.92.0-asio-executor-pac.patch) | Executor function/view callbacks, erased executor dispatch, and their object/context/table pointers. Copying views re-signs address-diversified fields. |
| `boost-1.92.0-asio-service-destroy-pac.patch` | Service destruction callback authentication. |
| `boost-1.92.0-asio-recycling-allocator-typing.patch` | Typed recycling and cancellation-handler allocation. |
| `boringssl-active-pointer-hardening.patch` | Active TLS pointer authentication. |
| `boringssl-typed-allocation.patch` | Typed BoringSSL allocation. |

Executor callback and carrier protections belong together because they protect
the same erased objects. Allocator typing remains a separate invariant. The Boost
manifest records each current stage's exact header digest; update those digests
when regrouping patches, and retain the unexpected-change rejection.

## Verification and maintenance

For a regrouping, capture the original series' resulting source trees first.
Generate each consolidated patch as a diff between its prerequisite tree and its
completed tree. Replay the new series from pristine pinned sources using the
ordinary patch helpers, and compare complete trees, including file modes and
dependency tests. Verify repeated application is a no-op and unexpected local
changes are still rejected. Matching final trees is required for a change that
claims to reorganize patches without changing behavior.

The consolidation from repository revision `e73722f` preserved:

- Libtorrent's complete patched Git tree:
  `e945b922c76227aceb22cf7d5147425d71cbf366`.
- Boost's patched-header digest, using the manifest's ordered file list:
  `41c2d583d20ec9768db0b70e12f01e50d2a388c7d7301da908009ebe943d83c0`.
- Both BoringSSL patches without modification.

Run [bridge analysis](../analyze-bridge.zsh) before
[bridge tests](../test-bridge.zsh). The
[dependency security suite](../test-libtorrent-security.zsh) exercises address
policy, trackers, storage, TLS, allocation, and the PAC replay/code-generation
checks, including the consolidated patches' existing tests. Use the relevant
sanitizer, parser-fuzz, and [Swift](../test-swift.zsh) checks when the imported
surfaces or implementations change, as required by the root `AGENTS.md`.

The dependency suite also replays all 140 pinned AES-GCM and 300 CTR-DRBG known
answers, checks allocator failure and alignment boundaries, and exercises v1,
v2, and hybrid hashing across pad-file boundaries under both worker-pool
configurations. Controlled callbacks cover web-seed remove/re-add, teardown,
and private-tracker failover, including stale peer DNS and tracker replies.
Authenticated TLS transfer, wrong-hostname rejection, and HTTPS downgrade
rejection run against a fixture root scoped to each test SecTrust object. The
TLS test compiles the actual verifier with one platform-call substitution; it
uses Apple's real trust evaluation and never modifies a keychain or exposes a
production trust override.
