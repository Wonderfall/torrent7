# Dependency patches

The ordered manifests are authoritative:

- [libtorrent](../libtorrent-patch-series.sh): ordered patches against the pinned commit.
- [Boost](../boost-patch-series.sh): ordered patches and header digests against the pinned source archive.
- [BoringSSL](../boringssl-patch-series.sh): ordered patches against the pinned commit.

Each patch describes one final implementation and includes its dependency-side
tests where applicable. Keep independently testable protocol boundaries separate.
Fold extensions of the same implementation into its existing patch so the series
does not introduce temporary state machines that later patches replace.

## Libtorrent

Names below omit the `libtorrent-2.1.2-` prefix and `.patch` suffix and follow
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
| [typed-allocation](libtorrent-2.1.2-typed-allocation.patch) | Typed pool and disk allocation, tracker pools, container allocation, and remaining temporary buffers. |
| `indirect-operation-pac` | Authenticates native indirect-operation callbacks. |
| `boringssl-compatibility` | Adapts the TLS integration to BoringSSL. |
| `boringssl-system-trust` | Uses macOS certificate trust and the constrained BoringSSL client policy. |
| `outbound-only-dht` | Separates DHT peer discovery from advertising incoming peer reachability. |
| [global-address-policy](libtorrent-2.1.2-global-address-policy.patch) | One session NAT64 discovery state for DHT, peers, web seeds, and HTTP/UDP trackers; endpoint admission, generation invalidation, PEX/holepunch policy, and private resume-peer rejection. Web-seed DNS callbacks carry the session generation, cached endpoints are rechecked before connection, and pending IPv6 never disables a seed. Builds on base network and outbound DHT changes. |
| `private-tracker-isolation` | Restricts private torrents to their authorized tracker generation; uses the shared peer policy. |
| `tracker-policy-generation` | Rejects stale public and private tracker callbacks after tracker-list replacement. |
| `current-dht-fallback` | Evaluates DHT fallback eligibility against current tracker state. |
| `dht-disable-late-response` | Discards outstanding DHT responses after the torrent disables DHT. |
| `revive-removed-web-seeds` | Re-enables a removed web seed when it is added again. |
| `disable-embedded-magnet-uri` | Rejects metainfo that would fall back to an embedded magnet URI. |
| [external-metainfo-import](libtorrent-2.1.2-external-metainfo-import.patch) | Imports preparsed metadata, requires the external swarm metadata parser, and rejects native resume-metainfo parsing. Retains the parser independently of add parameters. |
| `external-peer-message-parser` | External typed BEP 10/9/11 parsing; builds on peer policy and metainfo import. |
| `external-http-tracker-parser` | External typed tracker-body parsing; retains the shared address and TLS policies. |
| `external-dht-message-parser` | External typed DHT message parsing; retains outbound, address, and late-response policies. |
| `fail-closed-interface-binding` | Makes failed device binding terminal for peer, listener, and HTTP sockets. |
| `test-server-startup` | Removes reverse lookups from the Python web and HTTP proxy fixtures and binds both HTTP and SOCKS proxies to numeric loopback. The security suite exercises all three entry points with hostname resolution forbidden, verifying their readiness reports and listening sockets. |
| `bounded-tracker-deadlines` | Validates HTTP and UDP announce intervals before publishing checked deadlines; rejects negative, excessive, or overflowing values. |
| `acknowledged-skipped-storage` | Adds acknowledged, cancellable file-selection fences, keeps only needed skipped boundary fragments, and compacts private part storage after a durable checkpoint. Builds on the file-provider contract. |
| `checked-resume-checkpoints` | Reports disk-fence failures and tracks native resume revisions so only a successfully committed captured revision is acknowledged. Completes the checkpoint ordering used by skipped-storage reclamation. |

The shared address-policy patch includes the former tracker-endpoint, DHT-global,
peer-source, session-NAT64, and tracker-session-NAT64 changes. Its session state is
introduced in its final shared location, without separate tracker, DHT, or web-seed discovery
implementations that would immediately be replaced.

### 2.1.2 rebase

The series targets upstream tag `v2.1.2`, commit
`6da363d2994f17c0b3c0450d124cf73a31a73847`. At that rebase, all 25 pre-existing
patches remained necessary; upstream did not replace their application-specific
boundaries or hardening. The ordered manifest also includes subsequent fixes.
The rebase preserves upstream's hashing, piece-picker generation, Merkle-tree,
file-priority, and resume-bitfield fixes. The substantive adaptations are:

- `storage-confinement` now hardens upstream's shared `aux::rename_file`
  helper instead of duplicating rename logic in the pread and mmap backends.
  Relative-path confinement and symlink rejection also cover the posix caller.
  The regression checks existing and missing sources, escaping paths, source
  and destination symlinks, destination preservation, and successful renames.
  `file-provider` still rejects renaming broker-owned payloads before that helper.
- `network-security` retains upstream's proxy-hostname handling while requiring
  local endpoint validation whenever the address policy applies. Both SOCKS and
  HTTP proxy paths retain that requirement; the controlled stale-proxy test now
  explicitly enables remote DNS. Tracker patches preserve upstream's proxy DNS
  privacy guard while carrying the private and public tracker generations.
- `external-metainfo-import` retains the `piece_limit` parameter now used by
  upstream's resume-bitfield bounds checks. Nested native metainfo stays rejected.
- `boringssl-system-trust` passes its fixture certificate through upstream's new
  test-server startup protocol, which reports the OS-selected port over stdout.

The dependency security suite also runs upstream's hash-picker, piece-picker,
Merkle, request-merging, and resume-bitfield overflow regressions against the
complete patched build.

## Boost and BoringSSL

| Patch | Purpose |
| --- | --- |
| `boost-1.92.0-asio-operation-pac.patch` | Scheduler and reactor callback authentication. |
| [boost-1.92.0-asio-executor-pac.patch](boost-1.92.0-asio-executor-pac.patch) | Executor function/view callbacks, erased executor dispatch, and their object/context/table pointers. Copying views re-signs address-diversified fields. |
| `boost-1.92.0-asio-service-destroy-pac.patch` | Service destruction callback authentication. |
| `boost-1.92.0-asio-recycling-allocator-typing.patch` | Typed recycling and cancellation-handler allocation. |
| `boringssl-active-pointer-hardening.patch` | Active TLS pointer authentication. |
| `boringssl-typed-allocation.patch` | Typed BoringSSL allocation. |

The BoringSSL pointer patch follows upstream's `bssl::SSLSession` implementation;
its session method and cipher pointers retain the same address-and-role PAC.
The hardening tests exercise session duplication to verify that both pointers
are re-signed for the new object. The typed-allocation patch applies unchanged.

Executor callback and carrier protections belong together because they protect
the same erased objects. Allocator typing remains a separate invariant. The Boost
manifest records each current stage's exact header digest; update those digests
when regrouping patches, and retain the unexpected-change rejection.

## Updating a dependency

Use a bounded dependency change with its patch adaptations and verification.
Keep an unrelated app-version bump or toolchain adoption separate. The
[build configuration](../build-deps.zsh) and manifests above are the source of
truth; environment overrides are for experiments, not a substitute for updating
the checked-in pins.

1. Review the upstream release or commit, its security changes, and the existing
   patch purposes. For every patch, establish whether upstream now provides the
   complete required behavior. Remove a redundant patch only after checking its
   security and lifecycle invariants and preserving relevant regression coverage.
2. Update source identities together:

   | Dependency | Pins to review |
   | --- | --- |
   | libtorrent | Repository/tag in `build-deps.zsh`, exact commit and ordered filenames in `libtorrent-patch-series.sh`, and required submodule identities. |
   | BoringSSL | Repository, commit, tree, and SHA-256 of the builder's reproducible Git archive in `build-deps.zsh`; matching commit in `boringssl-patch-series.sh`. |
   | Boost | Version, archive URL, and SHA-256 in `build-deps.zsh`; matching version, patched-file list, and every ordered stage digest in `boost-patch-series.sh`. |

3. Rebase patches against pristine verified sources in application order. Review
   the resulting code, not just whether `git apply` succeeds. Keep new upstream
   fixes intact. BoringSSL's authenticated pristine checkout stays separate from
   each profile's patched worktree. Preserve local experiments before replacing
   any build sources.
4. Use each helper's `apply`, `verify`, and `manifest` commands on the intended
   source directory. Check repeated application and unexpected-change rejection.
   Libtorrent/BoringSSL compute the expected patched Git tree; Boost compares the
   listed headers against explicit stage digests. Patch SHA-256 values are
   generated into manifests and build stamps, not maintained in a second table.
   Never make a mismatch pass by weakening verification or hand-editing a stamp.
5. Run the ordinary dependency builder without `SKIP_BUILD_DEPS=1`, then the
   checks below and a complete app build. Source, patch, and toolchain identities
   invalidate cached builds through the stamps. If fresh sources are needed,
   use reviewed isolated paths or the [cleanup guide](../../Documentation/Development.md#reclaiming-build-space).
   Rebuild each sanitizer/fuzz profile used for validation too.
6. Update this index and any affected protocol or toolchain contracts. Review
   [third-party notices](../../Packaging/ThirdPartyNotices.txt), license changes,
   and all references to the old pin. Generate release inventories from the
   newly verified artifacts; do not edit SBOMs by hand. Record the tested source
   revision, profiles, results, and remaining limitations with the change.

For Swift package dependencies, the package manifests and their corresponding
`Package.resolved` files are authoritative. Follow the same upstream review and
applicable verification policy; the native patch helpers do not manage them.

## Dependency monitor

The read-only [dependency checker](../../Tools/DependencyCheck/DependencyChecker.swift)
reports upstream changes; it does not update pins or patches:

```sh
Scripts/run-tool.zsh check-dependencies --summary .build/dependency-check.md
```

The [CI workflow](../../.github/workflows/dependencies.yml) runs it weekly and
on relevant changes. `DEPENDENCY_COOLDOWN_DAYS` defaults to 4 for libtorrent and
Boost releases. `BORINGSSL_COOLDOWN_DAYS` defaults to 30 for commits on the
official repository's first-parent history. These are notification age filters:
newer candidates are reported as cooling down, and an already newer pin does not
need downgrading. They do not establish security, compatibility, or approval to
upgrade, and do not prevent a reviewed urgent fix from being adopted earlier.

A nonzero result can mean an eligible update, a source-identity mismatch, or a
failed upstream/history check. Read the generated summary before changing pins;
a network/API failure is not proof that the dependency is outdated. The native
monitor does not replace review of Swift package or GitHub Actions updates.

## Verification and maintenance

Run [bridge analysis](../analyze-bridge.zsh) before
[bridge tests](../test-bridge.zsh). The
[dependency security suite](../test-libtorrent-security.zsh) exercises address
policy, trackers, storage, TLS, allocation, and the PAC replay/code-generation
checks. Use the relevant sanitizer, parser-fuzz, and [Swift](../test-swift.zsh)
checks when the imported surfaces or implementations change, as required by the
[contributor verification policy](../../CONTRIBUTING.md#required-verification).

### Regrouping without behavior changes

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

### Security regression coverage

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
