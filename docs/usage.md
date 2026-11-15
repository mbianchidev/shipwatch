# Usage

## Menu bar

Shipwatch shows a sailboat in the menu bar.

| Icon | Meaning |
| --- | --- |
| Sailboat only | Every visible repository is passing or has no runs |
| Yellow dot | A workflow is running or queued somewhere |
| Orange dot | A repository's latest jobs never started (config/billing), nothing is failing |
| Red dot | At least one repository is failing on its default branch |

By default the number of repositories with a running workflow shows next to the
sailboat. **Show count in menu bar** switches it to failing repositories or
turns it off. Left-click the sailboat to open the list. Right-click it for
**Refresh** (Cmd-R), **Settings…** (Cmd-comma), **Check for Updates…** and
**Quit Shipwatch** (Cmd-Q). When a newer Shipwatch is out, a line above
**Manage Repositories…** offers **Install**; see [Updates](updates.md).
The same shortcuts work while the list is open.

## Repository rows

<p align="center">
  <img src="screenshots/popover-dark.png" alt="Shipwatch list with release, Actions status, activity, issue and pull request counts per repository" width="420">
</p>

Each visible repository shows:

| Item | Click to open |
| --- | --- |
| `owner/name` | the repository |
| Latest release tag and age (or **No releases**) | that release |
| Actions status: checkmark passing, xmark failing, exclamation mark config/billing, dotted circle running | expands the row with running runs and the latest run per workflow on the default branch; each run links to GitHub |
| Open issues | the open issues list |
| Open pull requests | the open pull requests list |
| `N dependabot` | open pull requests by `app/dependabot` |
| Last activity | (hover for the exact date) |

Failing means the latest completed run of any workflow on the default branch
failed. A red run that was fixed by a later run is ignored. Running beats
failing, failing beats config/billing, config/billing beats passing.

**Config/billing** (orange exclamation mark) means the latest runs failed before
any job ran: GitHub failed every job without assigning a runner, or the workflow
file is invalid (`startup_failure`). That is what happens when a payment failed or
the Actions spending limit is reached, and also when a job's configuration (for
example `runs-on` or a matrix) can't be evaluated. Shipwatch can't tell the two
apart without the Checks permission, so open the run to see GitHub's message.

The chips under the title count running, failing, config/billing and passing
repositories. Click one to list only those repositories; click it again, or
close the list, to show all of them.

Right-click a row for **Open Repository**, **Open Actions**, **Open Releases**,
**Copy Latest Tag**, **Move Up**, **Move Down**, **Hide** and
**Remove from Shipwatch…**. Removing or hiding never changes anything on GitHub.
When the repository has clones in your [workspace](#workspace), the menu also
offers **Update Local Clone Now** and **Show Local Clone in Finder**.

When clone sync skips or fails on a clone, a line at the bottom of the list says
"N local clones skipped". Click **Review** to see why in Settings > Workspace.

## Settings

Open Settings with **Manage Repositories…** (Cmd-comma) at the bottom of the list, or
**Settings…** in the right-click menu.

### Repositories

The repositories shown in the list, in order.

- Click **+** to pick repositories your token can read. Filter the list, or type
  `owner/name` to add one that isn't listed.
- Drag rows to reorder.
- Click the eye to hide or show a repository. Hidden ones stay configured and are
  counted at the bottom of the list.
- Select rows and click **-** to remove them from Shipwatch.
- The **Access** column shows whether the current sign-in can read each
  repository. **Grant…** opens the GitHub App installation page.

### Workspace

Optionally keeps the default branch (usually `main`) of your local clones in
step with GitHub, so it is current whenever you branch off it. Commit on feature
branches: Shipwatch only fast-forwards and never creates commits, resets,
stashes, forces, pushes or switches branches.

1. Click **Choose…** and pick the folder where you keep your clones, for example
   `~/Developer`. Shipwatch scans it up to 3 levels deep for folders whose git
   remote points at a repository you track on github.com. Nothing on disk
   changes yet.
2. When the folder holds clones of github.com repositories you don't track yet,
   a line under the table says how many. Click **Track N Found Here…**, untick
   any you don't want (all are ticked at first), and click
   **Track N Repositories**. They are added to Settings > Repositories like
   repositories added with **+**.
3. Optionally add **Excluded folders** with **+**. Shipwatch doesn't scan them or
   anything inside them. Hidden folders, `node_modules`, symlinks and app
   bundles are always skipped.
4. Turn on **Keep default branches up to date** (default off).

<p align="center">
  <img src="screenshots/settings-workspace.png" alt="Workspace settings with the workspace folder, the sync switch, two excluded folders, a table of local clones showing up to date, updated and skipped statuses, and a line saying 3 repositories cloned here aren't tracked yet with a Track 3 Found Here button" width="560">
</p>

<p align="center">
  <img src="screenshots/settings-track-found.png" alt="Track Repositories Found Here sheet listing three untracked repositories with their local paths, all ticked, and a Track 3 Repositories button" width="560">
</p>

After every refresh where GitHub reports a new commit on a default branch,
Shipwatch fetches that branch and fast-forwards the local one. A clone is
skipped, with the reason in the **Local clones** table, when:

| Reason | What to do |
| --- | --- |
| uncommitted changes on main | Commit, stash or discard them. Untracked files don't count. |
| main diverged from origin | The local branch has commits that aren't on GitHub. Move them to a branch. |
| rebase of main in progress | Finish or abort the rebase. |
| no local main branch | Nothing to update. Check it out once if you want it kept current. |

Errors such as an unreachable remote or a key that needs a passphrase show as
failed; Shipwatch retries them after 15 minutes. See
[Troubleshooting](troubleshooting.md#a-local-clone-was-skipped-or-failed).

- Untick a repository's **Sync** checkbox to leave all its clones alone.
- A clone on another branch still gets its default branch updated without
  switching; the table shows "on *branch*".
- **Sync Now** rescans and updates every clone right away, ignoring the
  15 minute wait. **Rescan** only looks for clones again.
- Right-click a clone for **Show in Finder**.

Shipwatch needs git for this: Homebrew's, or Apple's from the Command Line Tools
(`xcode-select --install`). It uses your existing SSH agent or credential
helper and never prompts.

### General

| Setting | Default | Effect |
| --- | --- | --- |
| Refresh every | 2 minutes | 1, 2, 5, 10 or 15 minutes. While a workflow runs, Shipwatch refreshes every 20 seconds. |
| Last activity means | Last push | **Last push**, or **Any update** (issues, pull requests, comments). |
| Include pre-releases | Off | Show the newest release even if it is a pre-release. |
| Show count in menu bar | Running | Show the number of **Running** or **Failing** repositories next to the sailboat, or **None**. |
| Launch at login | On after the first launch from Applications | Start Shipwatch when you log in. Only available for the app bundle. |
| Check automatically | On, every 6 hours | Check GitHub Releases for a newer Shipwatch every hour, 6 hours, 12 hours or day. |
| Install automatically | Off | Install a verified update found by a scheduled check, then restart. |

The same tab shows the installed **Version**, the **Updates** status, **Check Now**
and, when a newer release exists, **Install vX.Y.Z and Restart**. Builds run from
source show "Development build" and can't update themselves. See
[Updates](updates.md).

Shipwatch also refreshes when you open the list and the data is older than
60 seconds, and a few seconds after the Mac wakes. When GitHub rate limits the
token, it waits for the reset time. Details are in
[Architecture](architecture.md#refresh-cadence).

### Account

- The signed-in user, the sign-in method and the GitHub App permissions granted.
- **Manage Repository Access…** opens the app installation, where you choose
  which repositories Shipwatch can read.
- **Sign In…** and **Sign Out**. Signing out deletes the Keychain token.
- **Use GitHub CLI token if app sign-in is unavailable** (default off): reuse
  `gh auth token` when there is no GitHub App token. The token is kept in memory
  only.
- **GitHub App** Client ID and slug: only for builds without a bundled app, or to
  use your own. See [GitHub App setup](github-app-setup.md).

## Where data is stored

| What | Where |
| --- | --- |
| GitHub App token | login Keychain, service `dev.mbianchi.shipwatch` |
| Repositories and settings, including the workspace folder and exclusions | `UserDefaults` domain `dev.mbianchi.shipwatch` |
| Update state and lock | `~/Library/Application Support/Shipwatch` |
| GitHub CLI token | memory only |

Shipwatch sends no analytics. It only talks to `api.github.com`, `github.com`
and GitHub's release download hosts. With clone sync on, git also fetches from
your clones' github.com remotes, using your own git credentials.
