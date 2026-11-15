# Architecture

Shipwatch is a Swift package with no third-party dependencies.

| Target | Role |
| --- | --- |
| `ShipwatchCore` | GitHub API client, device flow, token storage, models, status cache, CI evaluation, workspace scan and clone fast-forward. No UI. |
| `ShipwatchUpdate` | Self-update feed, download, Ed25519 signature check, staging, swap and rollback. No UI. |
| `ShipwatchUI` | SwiftUI views hosted in AppKit, app state (`AppModel`, `WorkspaceModel`), preferences, `Updater`. |
| `Shipwatch` | Executable entry point: starts `AppDelegate`. |
| `ShipwatchUpdateHelper` | Bundled in `Contents/Helpers`; replaces the app after it quits and rolls back on failure. |
| `ShipwatchReleaseTool` | Release-only `keygen`, `sign` and `verify` for update signatures. Not shipped. |
| `ShipwatchSnapshots` | Renders README screenshots from mocked data, the app iconset and the DMG background. |
| `ShipwatchCoreTests` | Swift Testing suites with mocked HTTP responses and temporary git repositories. |
| `ShipwatchUpdateTests` | Swift Testing suites with temporary app bundles and fake command runners. |

## Menu bar

`StatusItemController` owns an `NSStatusItem` showing a sailboat template image
plus a status dot, and an `NSPopover` hosting `PopoverView`. The app runs as an
accessory (`LSUIElement`), so there is no Dock icon. Settings is a regular
window (`SettingsWindowController`) forced to dark appearance. The sort button
opens an AppKit `NSMenu`: a SwiftUI `Menu` inside the popover stops responding
after its first pick until the popover reopens.

The dot is yellow while any visible repo has a running or queued workflow, and
hidden otherwise; failing and config/billing repos show only in the list. The number of running repos (default) or failing repos is
shown next to the icon, or none (Settings > General).

## Data flow

```
AppModel ──refresh──▶ TokenVault ──token──▶ GitHubClient
   ▲                                            │
   └──────────── [RepoRef: RepoStatus] ◀────────┘
```

Per refresh, `GitHubClient.statuses(for:)`:

1. Sends one GraphQL query per 10 repos (`RepoQuery`): latest releases, open
   issue and PR counts, push and update dates, the default branch name and head
   commit, plus a search count of open PRs by
   `author:app/dependabot`. Names go through GraphQL variables, never into the query text.
   GitHub answers `5xx` (usually `502`) when a query runs too long, so a failed
   query is split in half and retried until it goes through, and later refreshes
   use batches of 5. A repo that still fails alone shows the error on its row.
   With security alerts on, the query also counts open `vulnerabilityAlerts`
   (Dependabot); a `FORBIDDEN` error on that field leaves only that count unknown.
2. Sends one REST call per repo for the 50 most recent workflow runs, with
   `If-None-Match` so unchanged repos come back as `304` and don't use rate limit.
   With security alerts on, it also lists open code scanning and secret scanning
   alerts (first page of 100, secrets hidden), the same way, in the same task per
   repo. `403` and `404` mean the token can't read them (not enough access to
   the repo, no GitHub Advanced Security, feature off, or a missing app
   permission): the count is unknown, not 0, and since those answers use rate
   limit the list is only asked for again after 15 minutes.
3. For each workflow whose latest run on the default branch failed, reads that
   run's jobs once (cached until the run changes). If every failed job ended
   without a runner or a single step, the run never started: GitHub does this when
   billing blocks Actions or a job's configuration is invalid. The exact message
   is only in check run annotations, which would need the Checks permission.
4. `CIEvaluator` turns runs into a state. Running (`in_progress`) beats queued
   (`queued`, `waiting`, `requested`, `pending`), queued beats failing, failing beats
   not started (shown as config/billing, which also covers `startup_failure`),
   not started beats passing. Only the latest completed run of each workflow on
   the default branch decides, so a red run that was fixed later is ignored.

Errors that would hit every request (offline, unauthorized, rate limited, or
three repos in a row failing with `5xx` on their own) stop the refresh and show
a banner; the previous data stays. Per-repo problems (no access, deleted, a
query GitHub can't answer) are shown on that row only.

GraphQL's `repository(owner:, name:)` follows renames and transfers, and its
`nameWithOwner` is the current name. Statuses stay keyed by the requested name;
when they differ, `AppModel` points the tracked entry at the new name
(`RepoList.rename`), keeping its place, group, visibility and clone sync opt-out,
and records the old name in `formerRefs`. Search doesn't follow renames, so the
Dependabot count is only right after one more refresh, which runs right away.
`WorkspaceScanner` resolves remotes that still use a former name to the current one.

## Repository list

`RepoList` (in `ShipwatchCore`) holds the tracked repositories in custom order
and the groups. Each repository has an optional group; the members of a group are
kept next to each other, and the group sits where its first member is, so groups
and ungrouped repositories share one order without a separate position for
groups. `entries` turns the list into the popover's top-level rows and `rows`
into the Settings table's group headers and repositories, leaving out the members
of groups collapsed in Settings (`AppModel.collapsedSettingsGroups`, kept until
quit). `moveRows` maps a drag in that table back onto the list, translating
offsets past collapsed members, `setMembers` applies the group sheet, and
`sorted(by:activity:)` applies the Name and Last Activity orders without
changing it.

## Refresh cadence

| Situation | Next refresh |
| --- | --- |
| Normal | every 1, 2 (default), 5, 10 or 15 minutes |
| A workflow is running or queued | every 20 seconds |
| Rate limited | at the reset time plus 2 seconds |
| Popover opens and data is older than 60 s | immediately |
| Mac wakes from sleep | 5 seconds after wake |
| App launches | immediately, or on schedule when the cached statuses are newer than the interval |

On launch `AppModel` lists the statuses `StatusCache` saved after the last
successful refresh, so a relaunch (an update, logging in) shows every repository
right away instead of "Loading…". The cache only holds tracked repositories and is
ignored when unreadable or from another `StatusSnapshot.currentVersion`.

## Local clones

Off by default. Shipwatch only writes to disk here, and only when the user has
picked a workspace folder and turned the switch on.

- **`WorkspaceScanner`** walks the workspace up to 3 levels deep, skipping
  excluded folders, hidden folders, `node_modules`, symlinks and packages. A
  folder with a `.git` directory is a clone when one of its remotes in
  `.git/config` parses (`RepoRef(gitRemote:)`) to a github.com repository. A
  tracked remote wins, then `origin`. Clones of tracked repositories go to
  `clones`; the rest go to `untracked`, which Settings > Workspace offers to
  track. It reads files only and never runs git, and it does not descend into
  clones. Folders it can't list (usually
  macOS privacy prompts that were declined) are reported, not fatal.
- **`CloneSyncer`** fast-forwards one clone's local default branch to the head
  commit GitHub reported:
  1. Already at that commit: done, no network.
  2. Skip if the branch is being rebased, or if the worktree that has it checked
     out has uncommitted changes to tracked files.
  3. `git fetch <remote> +refs/heads/<branch>:refs/remotes/<remote>/<branch>`,
     without tags, submodules or `FETCH_HEAD`, and only when the tracking ref
     isn't already there.
  4. Skip if the local branch isn't an ancestor of the fetched one (diverged).
  5. If a worktree has the branch checked out, `git merge --ff-only` there;
     otherwise `git update-ref` with the old value, so it fails if the branch
     moved in the meantime.
  It never commits, resets, stashes, checks out, forces or pushes.
- **`GitRunning`** abstracts running git; `ProcessGit` finds Homebrew's git or,
  only when the Command Line Tools are installed, `/usr/bin/git` (otherwise that
  stub would pop up an install dialog). Every command runs with
  `GIT_TERMINAL_PROMPT=0`, no credential or SSH prompts (`BatchMode=yes` unless
  the repository sets `core.sshCommand`) and a timeout. Fetch and merge also
  disable automatic `gc` and maintenance. Updates are recorded in the reflog as
  `shipwatch fast-forward`.
- **`WorkspaceModel`** (UI) owns the scan, the last result per clone and the
  settings. After each successful refresh it rescans if the last scan is older
  than 5 minutes or the tracked repositories changed, then syncs the clones that
  aren't opted out. Clones that were up to date or updated at the same head are
  skipped; failures wait 15 minutes. Passes run one at a time, clones in a pass
  sequentially, off the main actor. **Sync Now** and the row menu force a pass.

## Self-update

`Updater` (in `ShipwatchUI`) checks the latest GitHub release of
`mbianchidev/shipwatch` on a schedule (the REST API, or github.com's
`releases/latest` redirect while the API is rate limited), downloads `Shipwatch.dmg` and its `.sig`
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
| Tracked repos, order, groups, hidden flags, former names, settings, workspace folder, exclusions, sync opt-outs | `UserDefaults` (`dev.mbianchi.shipwatch`) |
| `gh` token | memory only |
| Last update result, update lock | `~/Library/Application Support/Shipwatch/` |
| Statuses of the last refresh (`StatusCache.json`, deleted on sign-out) | `~/Library/Application Support/Shipwatch/` |

## Logs

```bash
log stream --predicate 'subsystem == "dev.mbianchi.shipwatch"' --level info
```

Categories: `core` (API and auth), `ui`, `update` and `workspace` (scans and
clone sync).
