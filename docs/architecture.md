# Architecture

Shipwatch is a Swift package with no third-party dependencies.

| Target | Role |
| --- | --- |
| `ShipwatchCore` | GitHub API client, device flow, token storage, models, CI evaluation. No UI. |
| `ShipwatchUI` | SwiftUI views hosted in AppKit, app state (`AppModel`), preferences. |
| `Shipwatch` | Executable entry point: starts `AppDelegate`. |
| `ShipwatchSnapshots` | Renders README screenshots from mocked data and the app iconset. |
| `ShipwatchCoreTests` | Swift Testing suites with mocked HTTP responses. |

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

## Logs

```bash
log stream --predicate 'subsystem == "dev.mbianchi.shipwatch"' --level info
```
