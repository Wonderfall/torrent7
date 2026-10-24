# Troubleshooting and recovery

Start with the exact message shown by Torrent 7. Saved settings, folder access,
payload ownership, and engine state have different recovery paths. The
[architecture](Architecture.md) describes their contracts; this guide covers
supported actions and information useful for investigation.

## Settings cannot be loaded

“Saved settings could not be read” or “Settings Could Not Be Loaded” means the
saved record failed validation. Torrent networking remains blocked; displaying
default values does not authorize it to resume.

Open **Settings → Restore All Defaults…** to replace the unreadable settings,
then read the confirmation before proceeding. This resets General, Interface,
Transfers, Network, Discovery, and the saved default download folder. It also
allows torrent networking without the previous network-interface or VPN
restrictions. If those restrictions are required, account for that consequence
before confirming. Cancelling leaves the record preserved and networking blocked.

This action resets settings; it does not repair a corrupt storage journal or
reconstruct missing engine resume records. If saving the reset fails, retain the
error for a report. See [saved-settings recovery](Architecture.md#saved-settings-and-network-authorization).

## Download folder cannot be restored

For “The saved download folder could not be restored,” first make the intended
volume available, then use **Settings → General → Downloads → Choose...** or
choose a destination in the add dialog. Select the intended dedicated download
folder through the system picker.

The default folder is a preference for future adds. Selecting it again does not
rebind existing payload claims, restore deleted files, or repair a changed file
identity. Reconnect external storage before launching the app when existing
downloads depend on it.

## Saved payload verification did not finish

Startup validates saved storage authority and file identities before allowing
normal engine activity. If the error mentions the startup time budget, check
that download volumes are mounted, responsive, and accessible, then quit and
reopen Torrent 7 to retry.

The scan has a five-minute cooperative work budget. It runs outside the UI actor;
a filesystem call already waiting in the kernel can outlast that budget. Budget
expiry preserves the journal and payloads and stops engine startup. See the
[measurement rationale and limitations](StorageRestorationBenchmark.md).

Repeated failure warrants investigation. Report storage type, approximate torrent
and file counts, elapsed time, and the exact message. Do not remove
`StorageClaims.json` to bypass verification.

## Missing torrents or storage-recovery errors

During startup, the app retains only confirmed active claims with restored
storage authority. Unrestorable or unconfirmed torrents can be untracked while
their payloads are preserved. An already recorded explicit deletion intent has
a separate recovery path and may finish deleting its authorized payload.
Reopening therefore does not guarantee that a missing torrent row will return.

For a corrupt, incompatible, unavailable, or oversized storage journal, preserve
the journal, bookmarks, engine state, and payloads together. The app does not
provide a generic journal-repair or per-claim reassignment UI. Do not edit claim
identities, copy a different torrent's resume file, or delete one side of the
saved state to force a match. Report the error and the preceding operation.

When a resume record is rejected for invalid saved HTTPS policy, the ordinary
add flow can replace it after the torrent's HTTPS settings and destination have
been reviewed. This is the specific recovery described under
[persisted resume policy](Architecture.md#resume-persistence), not a general
repair procedure for every storage error.

## Engine interruptions and file selection

An interrupted add, removal, or file-priority change can have an unknown outcome.
An error does not prove that the engine rejected the operation. Torrent 7 keeps
the access required for teardown and reconciles confirmed state before enabling
networking again. Allow that recovery to finish and inspect the resulting file
priorities. If the engine remains unavailable, quit and reopen; report repeated
failures rather than manually altering saved permissions.

Skip stops downloading the selected files and retains only needed shared-piece
fragments in the helper's private partfile. It does not delete or truncate an already
existing user payload. Space reclamation can also fail after a selection has
committed; that error does not imply that the old selection was restored. See
[file-selection ordering](Architecture.md#activation-and-import).

## Network interface unavailable

Check the selected interface and VPN status in **Settings → Network**. A missing,
changed, or unverified required interface blocks networking. Reconnect the
intended interface or explicitly select the correct one; disabling the
restriction changes the protection the app provides. Settings recovery can
independently block networking even when the interface is available.

The helper validates interface authority. Hostname lookup still uses system DNS;
the interface setting is not a system-wide VPN kill switch.

## Data ownership and preservation

These locations are relative to each process's sandbox container. Container
roots differ between the regular, ASan, and TSan bundle identities; do not assume
that similarly named containers are interchangeable.

| Data | Owner and location | Why it matters |
| --- | --- | --- |
| Settings, folder bookmarks, labels, and completion history | GUI preferences in its container. | Preferences include user authorization and presentation state. |
| `StorageClaims.json` | GUI Application Support, `<app bundle identifier>/Storage/`. | Records exact payload identities, authority, and pending operations. |
| Resume records, removal markers, private skipped-file fragments | Helper Application Support, `Torrent7/EngineState/`. | Holds engine progress and data needed for resume and storage consistency. |
| Downloaded payloads | User-selected download folders. | User data lives outside the app containers. |
| Build products and caches | Repository and configured build directories. | Separate from application data; see [build cleanup](Development.md#reclaiming-build-space). |

For a diagnostic copy, quit the app normally first and retain related GUI state,
helper state, and payload context together. A copied bookmark or matching filename
alone does not recreate access or ownership. Raw state may contain private paths,
torrent identifiers, tracker credentials, and access bookmarks; share only the
specific material needed for an investigation through an appropriate channel.

## Reporting a problem

Include the app version and build from About, macOS version, build type
(distributed, local, ASan, or TSan), exact error text, approximate time, and
reproduction steps. For local builds include the source revision. For storage
failures include volume type, mount availability, and whether files were moved,
replaced, or removed before the failure. For a crash, retain the matching macOS
crash report and identify whether it names `Torrent 7` or `TorrentEngineExtension`.

Remove sensitive paths and tracker credentials from public reports. Use
[GitHub issues](https://github.com/Wonderfall/torrent7/issues) for ordinary bugs
and follow the [security policy](../SECURITY.md) for vulnerabilities. Contributors
can use the isolated [helper integration fixture](EnhancedSecurityExtensionIntegration.md)
and [UI diagnostics](ReleaseDiagnostics.md#native-menus-and-voiceover) to investigate
without experimenting on a user's live library.
