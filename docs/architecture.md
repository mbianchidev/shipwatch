# Architecture

Shipwatch is a Swift package with no third-party dependencies.

| Target | Role |
| --- | --- |
| `ShipwatchCore` | GitHub API client, device flow, token storage, models, CI evaluation. No UI. |
| `ShipwatchUpdate` | Self-update feed, download, Ed25519 signature check, staging, swap and rollback. No UI. |
| `ShipwatchUI` | SwiftUI views hosted in AppKit, app state (`AppModel`), preferences, `Updater`. |
| `Shipwatch` | Executable entry point: starts `AppDelegate`. |
| `ShipwatchUpdateHelper` | Bundled in `Contents/Helpers`; replaces the app after it quits and rolls back on failure. |
| `ShipwatchReleaseTool` | Release-only `keygen`, `sign` and `verify` for update signatures. Not shipped. |
| `ShipwatchSnapshots` | Renders README screenshots from mocked data, the app iconset and the DMG background. |
| `ShipwatchCoreTests` | Swift Testing suites with mocked HTTP responses. |
| `ShipwatchUpdateTests` | Swift Testing suites with temporary app bundles and fake command runners. |

## Menu bar

`StatusItemController` owns an `NSStatusItem` showing a sailboat template image
plus a status dot, and an `NSPopover` hosting `PopoverView`. The app runs as an
accessory (`LSUIElement`), so there is no Dock icon. Settings is a regular
window (`SettingsWindowController`) forced to dark appearance.

The dot summarizes visible repos: red if any repo is failing, else yellow if any
is running or queued, else no dot. Optionally the number of failing repos is shown
next to the icon (Settings > General).

## Data flow

```
AppModel ──refresh──▶ TokenVault ──token──▶ GitHubClient
   ▲                                            │
   └──────────── [RepoRef: RepoStatus] ◀────────┘
```

Per refresh, `GitHubClient.statuses(for:)`:

1. Sends one GraphQL query per 20 repos (`RepoQuery`): latest releases, open
   issue and PR counts, push and update dates, plus a search count of open PRs by
   `author:app/dependabot`. Names go through GraphQL variables, never into the query text.
2. Sends one REST call per repo for the 50 most recent workflow runs, with
   `If-None-Match` so unchanged repos come back as `304` and don't use rate limit.
3. `CIEvaluator` turns runs into a state. Running beats failing, failing beats
   passing. Only the latest completed run of each workflow on the default branch
   decides failing vs passing, so a red run that was fixed later is ignored.

Errors that would hit every request (offline, unauthorized, rate limited) stop
the refresh and show a banner. Per-repo problems (no access, renamed, deleted)
are shown on that row only.

## Refresh cadence

| Situation | Next refresh |
| --- | --- |
| Normal | every 1, 2 (default), 5, 10 or 15 minutes |
| A workflow is running or queued | every 20 seconds |
| Rate limited | at the reset time plus 2 seconds |
| Popover opens and data is older than 60 s | immediately |
| Mac wakes from sleep | 5 seconds after wake |

## Self-update

`Updater` (in `ShipwatchUI`) checks the latest GitHub release of
`mbianchidev/shipwatch` on a schedule, downloads `Shipwatch.dmg` and its `.sig`
into a temporary folder, and verifies the signature against the public keys in
`UpdateTrust` before mounting anything. It then stages the new app next to the
installed one, checks its bundle and code signature, and starts the helper
copied from the installed app. The helper waits for Shipwatch to quit, swaps the
bundles, launches the new version and waits for it to confirm startup; if it
does not, the helper restores the previous app. Only packaged builds update
themselves. See [Updates](updates.md) and [Releases](releases.md).

## Auth

`TokenVault` hands out a valid token: the GitHub App user token from the
Keychain (`KeychainTokenStore`), refreshed a few minutes before it expires, or
the `gh auth token` output when the CLI fallback is on and no app token exists.
After a `401` it drops the cached token, so the next request refreshes or
re-reads it. See [GitHub App setup](github-app-setup.md).

## Storage

| What | Where |
| --- | --- |
| App token | login Keychain, service `dev.mbianchi.shipwatch` |
| Tracked repos, order, hidden flags, settings | `UserDefaults` (`dev.mbianchi.shipwatch`) |
| `gh` token | memory only |
| Last update result, update lock | `~/Library/Application Support/Shipwatch/` |

## Logs

```bash
log stream --predicate 'subsystem == "dev.mbianchi.shipwatch"' --level info
```
