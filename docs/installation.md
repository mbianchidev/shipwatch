# Installation

Shipwatch needs macOS 14 Sonoma or later, on Apple Silicon or Intel. The download
is a single universal app.

## Download

From the [latest release](https://github.com/mbianchidev/shipwatch/releases/latest),
download `Shipwatch.dmg`. Optionally download `Shipwatch.dmg.sha256` next to it and
check the file:

```bash
cd ~/Downloads
echo "$(cat Shipwatch.dmg.sha256)  Shipwatch.dmg" | shasum -a 256 -c -
```

It prints `Shipwatch.dmg: OK` when the download is intact.

## Install

1. Open `Shipwatch.dmg`.
2. Drag **Shipwatch** onto the **Applications** folder in the window that opens.
3. Eject the disk image.
4. Open Shipwatch from Applications. It appears in the menu bar as a sailboat,
   not in the Dock.

## First launch

Release builds are ad-hoc signed. They are **not** Developer ID signed or
notarized by Apple, so macOS may refuse to open Shipwatch the first time. If you
downloaded it from the release page above, follow Apple's
[safe app-opening steps](https://support.apple.com/en-us/102445):

1. Try to open Shipwatch and click **Done** on the warning.
2. Open **System Settings > Privacy & Security** and scroll to **Security**.
3. Click **Open Anyway** next to the Shipwatch message, then **Open**.

macOS remembers the choice. Don't disable Gatekeeper or remove quarantine flags
for this; on a managed Mac, ask your administrator.

On first launch from Applications, Shipwatch turns on **Launch at login** once.
Switch it off in Settings > General if you prefer.

## Sign in

Click the sailboat and choose one:

- **Sign in with GitHub**: approve a short code on github.com. Shipwatch gets a
  read-only GitHub App user token and stores it in your login Keychain. This
  needs a GitHub App Client ID. If the build has none, Shipwatch says so and you
  can add your own app in Settings > Account; see
  [GitHub App setup](github-app-setup.md).
- **Use GitHub CLI token**: reuses `gh auth token` if the
  [GitHub CLI](https://cli.github.com) is installed and signed in. Shipwatch only
  sends read requests, but that token keeps whatever scopes `gh` has.

Then click **Add Repositories…** and pick what to watch. See [Usage](usage.md).

## Upgrade

Shipwatch checks GitHub Releases for new versions and installs them after
verifying their signature. See [Updates](updates.md). You can also upgrade by
hand: quit Shipwatch, download the new DMG and replace the app in Applications.
Settings and the Keychain token are kept.

## Uninstall

1. In Settings > General, turn off **Launch at login**.
2. In Settings > Account, click **Sign Out**. This deletes the Keychain token.
   For a GitHub App sign-in you can also revoke it at
   <https://github.com/settings/apps/authorizations>.
3. Quit Shipwatch (right-click the sailboat > **Quit Shipwatch**).
4. Move `/Applications/Shipwatch.app` to the Trash.
5. Optionally remove settings and update state:

   ```bash
   defaults delete dev.mbianchi.shipwatch
   rm -rf ~/Library/Application\ Support/Shipwatch
   ```

Shipwatch never changes anything on GitHub, so nothing needs cleaning up there.
