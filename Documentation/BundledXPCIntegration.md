# Bundled XPC integration gate

`Scripts/test-bundled-xpc.zsh` assembles a dedicated ad-hoc app/XPC pair and
runs the production client, IPC, service, engine, and bridge across a real XPC
boundary. The fixture uses the same app and service entitlement files as the
release bundle, but isolated `app.torrent7.integration` bundle identifiers and
containers. Ad-hoc signing preserves sandbox and entitlement fidelity for this
local gate; it does not exercise production identified-peer signing.

The positive folder-delegation and performance runs are intentionally
interactive. Apple documents
simulated input in Open and Save dialogs as incompatible with App Sandbox, and
the system-owned Powerbox process ignores an app trying to approve its own file
access. A genuine approval is therefore part of this security test rather than
a runtime test bypass.

CI runs `--automated`, which launches the real signed app and service with no
folder grants. It verifies the blocked-network empty poll, restart, shutdown,
fresh reconnect, and a second poll. A final fresh connection sends a malformed
nonempty bookmark and must receive the service's exact invalid-folder-grant
rejection. This exercises real XPC discovery, connection, lifecycle, and the
negative authorization boundary without weakening either sandbox. `--build-only`
is also available when only fixture assembly and signature verification are
needed.

## Practical dataset

Run:

```sh
SKIP_BUILD_DEPS=1 Scripts/test-bundled-xpc.zsh
```

The script prints and preselects an exact `PowerboxRoot` under its integration
output directory. Approve that folder in the system Open panel. The host creates
a UUID child inside the approved root and delegates only that child's transient
bookmark to the service.

The default run adds 512 unique tracker-bearing magnets while network access is
blocked, verifies a real paged snapshot and tracker-host poll, restarts the
engine, verifies the full result again, shuts down, reconnects through a fresh
controller, and performs a final verification and shutdown.

## Maximum dataset

Run:

```sh
SKIP_BUILD_DEPS=1 Scripts/test-bundled-xpc.zsh --maximum
```

The maximum run uses the same single folder approval. It first adds and polls a
512-torrent realistic checkpoint, continues to the 20,000-torrent protocol
limit, then runs the full maximum poll, restart, shutdown, reconnect, and final
poll sequence.

Both modes enforce a hard timeout (`BUNDLED_XPC_TIMEOUT_SECONDS`, 600 seconds by
default and 3,600 seconds for `--maximum`). They report `ContinuousClock`
operation timings and 100 ms sampled peak RSS for the exact host and service
executables. Logs remain in `.build/BundledXPCIntegration`; the dedicated
Powerbox root and integration sandbox containers are removed on exit.

[Apple App Sandbox guidance](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
explains why Open and Save dialog input cannot be simulated by the sandboxed
host.

## Automated lifecycle

Run the same gate as CI with:

```sh
SKIP_BUILD_DEPS=1 Scripts/test-bundled-xpc.zsh --automated
```

This mode needs no Powerbox interaction and does not add torrents. Its purpose
is the signed bundled-XPC lifecycle and negative folder-authorization boundary;
the practical and maximum modes provide the positive delegation and transport
measurements.
