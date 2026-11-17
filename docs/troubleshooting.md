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
Settings > Account) and add the repository to the installation. A repository
that moved to another owner needs the app installed there too; once Shipwatch
can read it again, it switches to the new name on its own. Deleted repositories
show the same message: remove them.

## The GitHub CLI option is unavailable

Install the [GitHub CLI](https://cli.github.com) and run `gh auth login`.
Shipwatch looks for `gh` in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`
and then `PATH`.

## A banner or row says "GitHub returned HTTP 502" or "Something went wrong while executing your query"

GitHub gives up on queries that run too long, or fails them on its side.
Shipwatch splits the request into smaller ones and retries on its own, so
usually only the row of a repository GitHub can't answer shows the error. A
banner means GitHub kept failing: rows that never loaded say "Not loaded yet"
and the rest keep their last data. Check
[githubstatus.com](https://www.githubstatus.com) and click **Retry** later.

## A repository shows config/billing

Its latest runs on the default branch failed before any job ran. Open the run
from the row: GitHub's message says whether a payment failed or the spending
limit was reached (fix it under **Settings > Billing and plans** on GitHub), or
which part of the workflow file is invalid. Re-run or push again afterwards;
Shipwatch picks up the new run on the next refresh.

## The security alerts shield shows "?"

Shipwatch couldn't read at least one kind of alert and found none open in the
others. Hover the shield to see which kind is unknown. Dependabot and code
scanning alerts need write access to the repository and secret scanning alerts
need admin access (organization owners and security managers can read all of
them); code and secret scanning on private repositories need GitHub Advanced
Security; and each kind must
be turned on under the repository's **Settings > Advanced Security** (or
**Code security**). With the GitHub App, approve the
[alert permissions](github-app-setup.md#security-alert-permissions). Shipwatch
asks again every 15 minutes, or right away when you turn **Show security alerts**
off and on.

## Counts look stale or a banner says "GitHub rate limit reached"

Shipwatch waits for the rate limit reset and retries on its own. Use
**Refresh** (Cmd-R) to force a refresh otherwise. Watching many repositories
with a 1 minute interval uses more of the hourly limit; pick a longer interval
in Settings > General.

## Updates say "GitHub's rate limit for this network is used up"

Update checks don't use your GitHub token, so they share GitHub's limit of 60
API requests an hour with every other unauthenticated tool on your network.
When it's used up, Shipwatch reads the latest release from
`github.com/mbianchidev/shipwatch/releases/latest` instead until the limit
resets, so checks keep working. The message only appears if that fails too;
Shipwatch retries on its own, or click **Check Now** later. See
[Updates](updates.md#what-shipwatch-verifies).

## An update failed

Shipwatch keeps the installed version when an update can't be verified or
installed, and shows why in Settings > General. See
[Updates](updates.md#when-an-update-fails). You can always upgrade by hand.

## No release notification arrived

- Check that the bell next to the repository is on in Settings > Repositories,
  and that Settings > General doesn't say notifications are off. If it does,
  click **Open Notification Settings…** and allow them for Shipwatch.
- Click **Send Test** in Settings > General. If no banner shows, check Focus
  modes and the Shipwatch entry in System Settings > Notifications.
- Only GitHub releases notify. A pushed tag without a release, a draft, or a
  pre-release while **Include pre-releases** is off doesn't.
- Shipwatch finds new releases when it refreshes, so wait one refresh interval.
- Notifications need the app bundle; a build run with `swift run` can't show them.

## A local clone isn't listed in Settings > Workspace

- The repository must be tracked in Shipwatch. Clones of github.com
  repositories you don't track are counted under the table instead: click
  **Track N Found Here…** to add them.
- The clone must be inside the workspace folder, at most 3 levels deep, and not
  in an excluded folder. Hidden folders, `node_modules` and symlinked folders
  are never scanned. Click **Rescan** after cloning; Shipwatch also rescans
  every 5 minutes.
- One of its remotes must point at github.com: `git@github.com:owner/name`,
  `https://github.com/owner/name` or `ssh://git@github.com/owner/name`. SSH host
  aliases such as `git@github-work:owner/name` and `url.*.insteadOf` rewrites
  aren't recognized.
- Linked worktrees and submodules aren't listed on their own. The main clone is,
  and updating it updates the branch for all its worktrees.
- For a workspace in Documents, Desktop, Downloads or iCloud Drive, macOS asks
  once for access. If you declined, allow Shipwatch in System Settings > Privacy
  & Security > Files and Folders, then click **Rescan**. Folders Shipwatch
  couldn't read are listed in the `workspace` [logs](#collect-logs).

## A local clone was skipped or failed

Skipped clones show the reason in Settings > Workspace; see
[Usage](usage.md#workspace) for each one. Shipwatch never resolves them for you.
Failed clones are retried after 15 minutes, or now with **Sync Now**.

- **"Needs git"**: install git with `xcode-select --install` or Homebrew, then
  restart Shipwatch.
- **Authentication or "Permission denied (publickey)"**: Shipwatch can't
  answer prompts. For SSH remotes, add your key to the agent and Keychain
  (`ssh-add --apple-use-keychain ~/.ssh/id_ed25519`); apps started from the
  Dock or at login get the system SSH agent, not one started in a shell profile.
  For HTTPS remotes, use a credential helper such as `osxkeychain` or
  `gh auth setup-git`. Running `git fetch` in that clone once from Terminal
  shows the full error.
- **Host key verification failed**: connect once from Terminal
  (`ssh -T git@github.com`) to accept GitHub's host key.
- **Git hooks or Git LFS**: a fast-forward of the checked-out branch runs your
  `post-merge` hook and LFS downloads, just like `git pull`. If those need
  input, they fail; turn **Sync** off for that repository.

## Collect logs

Shipwatch logs to the unified log, never to files, and never logs tokens.

```bash
log show --last 30m --predicate 'subsystem == "dev.mbianchi.shipwatch"' --info
```

Use `log stream` instead of `log show --last 30m` to watch live. Add
`&& category == "workspace"` inside the predicate to see only workspace scans
and clone sync. Check the output for repository names and local paths you'd
rather not share before attaching it to an
[issue](https://github.com/mbianchidev/shipwatch/issues/new/choose).
