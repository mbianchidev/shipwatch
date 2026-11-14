# Troubleshooting

## macOS says Shipwatch can't be opened

Release builds are not notarized. Use **System Settings > Privacy & Security >
Open Anyway**, as described in [Installation](installation.md#first-launch).
If macOS says the app is damaged or contains malware, don't open it: delete it
and download it again from the
[releases page](https://github.com/mbianchidev/shipwatch/releases/latest).

## I can't find Shipwatch after opening it

It has no Dock icon or window. Look for the sailboat in the menu bar. If the
menu bar is crowded, the icon may be hidden behind the notch or another app;
quit a few menu bar apps or hold Cmd and drag icons to make room.

## "This build has no GitHub App Client ID"

You are running a build without a bundled GitHub App (for example
`swift run`). Either set one in Settings > Account
([GitHub App setup](github-app-setup.md)) or use the GitHub CLI token.

## Sign-in code expired or was denied

Click **Sign in with GitHub** again to get a new code. Approve it at the
address Shipwatch shows, signed in as the GitHub user you want to use.

## A repository says Shipwatch can't read it

The GitHub App is not installed on that repository, or the CLI token can't see
it. Click **Grant access…** on the row (or **Manage Repository Access…** in
Settings > Account) and add the repository to the installation. Renamed or
deleted repositories show the same message: remove and add them again.

## The GitHub CLI option is unavailable

Install the [GitHub CLI](https://cli.github.com) and run `gh auth login`.
Shipwatch looks for `gh` in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`
and then `PATH`.

## Counts look stale or a banner says "GitHub rate limit reached"

Shipwatch waits for the rate limit reset and retries on its own. Use
**Refresh** (Cmd-R) to force a refresh otherwise. Watching many repositories
with a 1 minute interval uses more of the hourly limit; pick a longer interval
in Settings > General.

## An update failed

Shipwatch keeps the installed version when an update can't be verified or
installed, and shows why in Settings > General. See
[Updates](updates.md#when-an-update-fails). You can always upgrade by hand.

## Collect logs

Shipwatch logs to the unified log, never to files, and never logs tokens.

```bash
log show --last 30m --predicate 'subsystem == "dev.mbianchi.shipwatch"' --info
```

Use `log stream` instead of `log show --last 30m` to watch live. Check the
output for repository names you'd rather not share before attaching it to an
[issue](https://github.com/mbianchidev/shipwatch/issues/new/choose).
