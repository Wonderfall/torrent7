# Enhanced Security extension integration gate

`Scripts/test-enhanced-security-extension.zsh` assembles a dedicated ad-hoc host
with the production engine runtime packaged as a macOS 26 Enhanced Security
helper extension. It exercises the production client, bounded XPC protocol,
helper runtime, engine, and bridge across the real ExtensionFoundation process
boundary. The fixture uses the release entitlement files with isolated
`app.torrent7.integration` bundle identifiers and containers. Ad-hoc signing
preserves sandbox and entitlement fidelity for this local gate; it does not
exercise production identified-peer signing.

The automated lifecycle also supports `SANITIZER_PROFILE=address` and
`SANITIZER_PROFILE=thread`. These correctness-only variants use separate build
directories plus `app.torrent7.integration.asan` or
`app.torrent7.integration.tsan` identities, so their registrations and sandbox
containers cannot collide with the release fixture. They require `--automated`
or `--build-only`; interactive timing and maximum-dataset runs remain release
only.

The fixture has the same structural security properties as production:

- one helper under `Contents/PlugIns/*.appex`;
- one application-scoped, UI-less Enhanced Security point under
  `Contents/Extensions/*.appexpt`;
- Enhanced Security version 2 and network client/server authority only in the
  helper;
- no legacy `Contents/XPCServices` bundle;
- exact application/helper identity selection and explicit reduced-assurance
  mode only because the fixture is ad-hoc signed.

The positive folder-delegation and performance runs are intentionally
interactive. Apple documents simulated input in Open and Save dialogs as
incompatible with App Sandbox, and the system-owned Powerbox process ignores an
app trying to approve its own file access. A genuine approval is therefore part
of this security test rather than a runtime bypass.

CI runs `--automated`, which launches the real signed host and extension with no
folder grants. It verifies blocked-network startup and a nonempty local-interface
snapshot, reports the VPN-classified count, and exercises restart, shutdown, and
fresh-session reconnect.
The runner also kills the exact helper process, requires the client to observe
the interruption, requires ExtensionFoundation to launch a different PID, and
verifies a fresh blocked controller afterward. A final connection sends a
malformed nonempty bookmark and must receive the exact invalid-folder-grant
rejection. `--build-only` is available when only assembly, metadata, discovery
registration, and signature verification are needed.

## Practical dataset

Run:

```sh
SKIP_BUILD_DEPS=1 Scripts/test-enhanced-security-extension.zsh
```

The script prints and preselects an exact `PowerboxRoot` under its integration
output directory. Approve that folder in the system Open panel. The host creates
a UUID child inside the approved root and delegates only that child's transient
bookmark to the helper.

The default run adds 512 unique tracker-bearing magnets while network access is
blocked, verifies a real paged snapshot and tracker-host poll, restarts the
engine, verifies the full result again, shuts down, reconnects through a fresh
controller, and performs a final verification and shutdown.

## Maximum dataset

Run:

```sh
SKIP_BUILD_DEPS=1 Scripts/test-enhanced-security-extension.zsh --maximum
```

The maximum run uses the same single folder approval. It first adds and polls a
512-torrent realistic checkpoint, continues to the 20,000-torrent protocol
limit, then runs the full maximum poll, restart, shutdown, reconnect, and final
poll sequence.

Both modes enforce a hard timeout (`ENHANCED_SECURITY_TIMEOUT_SECONDS`, 600
seconds by default and 3,600 seconds for `--maximum`). They report
`ContinuousClock` operation timings and 100 ms sampled peak RSS for the exact
host and helper executables. Logs remain in
`.build/EnhancedSecurityExtensionIntegration`; the dedicated Powerbox root,
LaunchServices registration, and integration sandbox containers are removed on
exit.

[Apple App Sandbox guidance](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
explains why Open and Save dialog input cannot be simulated by the sandboxed
host.

## Automated lifecycle

Run the same gate as CI with:

```sh
SKIP_BUILD_DEPS=1 Scripts/test-enhanced-security-extension.zsh --automated
```

This mode needs no Powerbox interaction and does not add torrents. Its purpose
is the signed Enhanced Security process lifecycle, recovery path, network
observation, and negative folder-authorization boundary. The practical and
maximum modes provide positive delegation and transport measurements.

To run the same lifecycle with the fully instrumented ThreadSanitizer dependency
profile:

```sh
SANITIZER_PROFILE=thread SKIP_BUILD_DEPS=1 \
  Scripts/test-enhanced-security-extension.zsh --automated
```

The sanitizer runtime is verified in both the host and helper before launch.
TSan uses fail-fast options without suppressions; the Bridge also embeds those
defaults because the system-launched Enhanced Security helper is not guaranteed
to inherit the runner's environment.
