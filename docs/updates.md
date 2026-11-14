# Updates

Shipwatch updates itself from
[GitHub Releases](https://github.com/mbianchidev/shipwatch/releases). Every
update is checked against a signing key built into the app before anything on
disk changes.

- [Check for updates](#check-for-updates)
- [What Shipwatch verifies](#what-shipwatch-verifies)
- [How an update is installed](#how-an-update-is-installed)
- [When an update fails](#when-an-update-fails)
- [Files and logs](#files-and-logs)
- [Limitations](#limitations)

## Check for updates

Shipwatch checks about 30 seconds after launch, then on the interval chosen in
Settings > General (**Check automatically**: every hour, 6 hours, 12 hours or
day; 6 hours by default). Failed checks retry from 5 minutes, backing off up to
that interval. To check right away, use **Check for Updates…** in the
right-click menu or **Check Now** in Settings > General.

When a newer release exists:

- The list shows "Shipwatch X.Y.Z is available · **Install**" above
  **Manage Repositories…**.
- Settings > General shows **Install vX.Y.Z and Restart** and a
  **Release notes** link.

With **Install automatically** on, a scheduled check installs the update
without asking. **Check Now** never installs by itself. Turn off
**Check automatically** to stop scheduled checks; nothing is downloaded then
unless you check by hand.

Only the packaged app updates itself. A build run from source shows
"Development build" and "Updates are available in the packaged app."

## What Shipwatch verifies

1. **Release feed.** Shipwatch reads
   `https://api.github.com/repos/mbianchidev/shipwatch/releases/latest` with its
   own session, without your GitHub token or cookies. Drafts, pre-releases,
   tags that aren't `vMAJOR.MINOR.PATCH`, and versions not newer than the
   installed one are ignored, so it never downgrades.
2. **Download locations.** `Shipwatch.dmg` and `Shipwatch.dmg.sig` must come
   from `https://github.com/mbianchidev/shipwatch/releases/download/<tag>/`.
   Redirects may only go to `github.com`, `objects.githubusercontent.com` or
   `release-assets.githubusercontent.com` over HTTPS. The DMG may be at most
   64 MiB and the signature 4 KiB.
3. **Signature.** `Shipwatch.dmg.sig` is a small JSON document with the bundle
   identifier, version, size and SHA-256 of the DMG, plus an Ed25519 signature
   over those fields. Shipwatch checks the signature against the release public
   keys built into the app (normally one, two during a key rotation), then
   checks that every field matches the downloaded file and the release. Any
   mismatch stops the update.
4. **App bundle.** After mounting the verified DMG read-only, Shipwatch checks
   that the app inside has the Shipwatch bundle identifier and executable, the
   expected version, and a valid code signature.

The release key, its rotation and its handling are described in
[Releases](releases.md).

## How an update is installed

1. The verified app is copied into a private `.Shipwatch-update-<UUID>` folder
   next to the installed app (usually in `/Applications`) and checked again.
2. Shipwatch starts the update helper, a copy of
   `Contents/Helpers/ShipwatchUpdateHelper` from the installed app, waits until
   it reports ready, then quits.
3. The helper swaps the old and new app in one atomic step, so
   `/Applications/Shipwatch.app` always holds a complete app.
4. It opens the new Shipwatch and waits up to 30 seconds for it to confirm that
   it started. If it doesn't, the helper stops it, swaps the previous app back
   and opens that.
5. The helper records the result and removes the staging folder.

Shipwatch must be able to replace itself in place. Updates are refused when the
app runs from the DMG, from a translocated path, or from a folder your account
can't write to. Move it to `/Applications` or `~/Applications` first.

## When an update fails

Shipwatch keeps the installed version whenever a check, download,
verification or install fails. The list shows "Shipwatch update failed ·
**Details**", and Settings > General shows the reason next to **Updates**.

- A version that failed to install is not installed automatically again in
  that session, or after the helper rolled it back. **Install vX.Y.Z and
  Restart** retries by hand. A newer release clears the warning and installs
  as usual, and so does installing that version or a newer one by hand.
- If Shipwatch can't read the result of the last update, it pauses automatic
  installs for every version until an update installs successfully.
- "The update signature is not valid for Shipwatch's release key", "does not
  match its signed SHA-256 checksum", or "This build has no valid update
  signing key" mean the download can't be trusted. Don't work around it;
  report it as described in [SECURITY.md](../SECURITY.md).
- "Shipwatch can't update itself here": move Shipwatch to `/Applications` or
  `~/Applications` and open it from there.

You can always upgrade by hand: quit Shipwatch, download the new DMG from
[Releases](https://github.com/mbianchidev/shipwatch/releases), check it as in
[Installation](installation.md#download), and replace the app.

## Files and logs

| What | Where |
| --- | --- |
| Settings | `defaults read dev.mbianchi.shipwatch` (`checkForUpdates`, `updateCheckHours`, `installUpdatesAutomatically`) |
| Result of the last update | `~/Library/Application Support/Shipwatch/LastUpdate.json` |
| Lock against parallel updates | `~/Library/Application Support/Shipwatch/update.lock` |
| Download and mount point | A `Shipwatch-update-<UUID>` folder in your temporary folder, removed after each attempt |
| Staged app | `.Shipwatch-update-<UUID>` next to the installed app, removed after each attempt |

Update activity is logged under the `update` category:

```bash
log show --last 1h --predicate 'subsystem == "dev.mbianchi.shipwatch" AND category == "update"' --info
```

## Limitations

- Shipwatch is ad-hoc signed and not notarized. The Ed25519 signature proves an
  update came from the Shipwatch release key; it is not an Apple Developer ID
  signature.
- Only the latest release is offered. There are no update channels.
- Release notes are plain text, shortened to 4000 characters, and shown as the
  tooltip of **Release notes**.
