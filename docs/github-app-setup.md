# GitHub App setup

Shipwatch signs in with a GitHub App through the device flow: you approve a short
code on github.com and Shipwatch gets a **read-only** user token. No client secret
is needed or stored. The token lives in your login Keychain (service
`dev.mbianchi.shipwatch`).

Don't want to register an app? Turn on **Use GitHub CLI token** in
Settings > Account and Shipwatch reuses `gh auth token`. See
[GitHub CLI fallback](#github-cli-fallback).

## 1. Register the app

Open <https://github.com/settings/apps/new> (or an organization's
Settings > Developer settings > GitHub Apps) and fill in:

| Field | Value |
| --- | --- |
| GitHub App name | `Shipwatch` or any unique name |
| Homepage URL | `https://github.com/mbianchidev/shipwatch` |
| Callback URL | leave empty |
| Expire user authorization tokens | keep checked, Shipwatch refreshes them |
| Enable Device Flow | **check** |
| Webhook > Active | **uncheck** |

Repository permissions, all **Read-only**:

| Permission | Used for |
| --- | --- |
| Actions | workflow runs and their status |
| Contents | releases |
| Issues | open issue count |
| Pull requests | open PR and Dependabot PR counts |
| Metadata | mandatory, repository basics |

No organization or account permissions are needed. Pick who can install it
(only your account, or any account), then **Create GitHub App**.

### Security alert permissions

Only needed for **Show security alerts** in Settings > General. Add these
repository permissions, also **Read-only**:

| Permission | Used for |
| --- | --- |
| Dependabot alerts | open Dependabot alert count |
| Code scanning alerts | open code scanning alert count |
| Secret scanning alerts | open secret scanning alert count |

Adding permissions to an existing app asks every installation to approve them:
accept the request under **Settings > Applications > Installed GitHub Apps** on
GitHub (an organization owner does it for organization installs). Until then,
those counts show as unknown. GitHub also needs your own access to allow it:
write access for Dependabot and code scanning alerts, admin for secret scanning
alerts (organization owners and security managers can read all of them).

## 2. Note the Client ID and slug

On the app's page:

- **Client ID** looks like `Iv23li...`. It is not a secret.
- The **slug** is the last part of the app URL, e.g. `shipwatch` in
  `https://github.com/apps/shipwatch`.

## 3. Install it

Open `https://github.com/apps/<slug>/installations/new` and install it on your
account and on any organization you want to watch. Choose **All repositories**
or pick them. Organization installs may need an owner's approval.

Shipwatch only sees repositories where the app is installed. Use
**Manage Repository Access...** in Settings > Account, or the
**Grant access to more repos** link in the Add Repositories sheet, to change that later.

## 4. Point Shipwatch at it

Any one of these, in priority order:

1. **Settings > Account > GitHub App**: paste the Client ID and slug. Overrides everything else.
2. **Packaged build**: bake them into `Info.plist` when packaging:
   ```bash
   SHIPWATCH_CLIENT_ID=Iv23li... SHIPWATCH_APP_SLUG=shipwatch bash scripts/package-macos.sh
   ```
   Official releases read them from the `SHIPWATCH_CLIENT_ID` and
   `SHIPWATCH_APP_SLUG` Actions variables, see [Releases](releases.md#configuration).
3. **`swift run`**: export the same `SHIPWATCH_CLIENT_ID` and `SHIPWATCH_APP_SLUG` variables.

Then click **Sign in with GitHub** in the menu bar popover and enter the code
on the page that opens.

## GitHub CLI fallback

With the fallback on and no app sign-in, Shipwatch runs `gh auth token` when it
needs a token and keeps it in memory only. It looks for `gh` in
`/opt/homebrew/bin`, `/usr/local/bin` and `/usr/bin`, since apps launched from
Finder don't inherit your shell `PATH`.

Note that `gh` tokens usually carry broad scopes such as `repo`, which already
covers security alerts. Shipwatch only issues read requests, but the GitHub App is
the least-privilege option.

## Sign out

Settings > Account > **Sign Out** deletes the app token from the Keychain. To
revoke it on GitHub too, go to <https://github.com/settings/apps/authorizations>.
