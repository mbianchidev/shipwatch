# Releases

Shipwatch is released by [`.github/workflows/release.yml`](../.github/workflows/release.yml).
Every push to `main` publishes a new release; nobody creates tags or releases by hand.

## How a release is made

1. **Version.** The workflow reads the latest published release and bumps its
   patch, so `v0.1.4` becomes `v0.1.5`. With no release yet, the first one is
   `v0.0.1`. To start a new minor or major line, open **Actions > Release > Run
   workflow** on `main` and enter a version such as `v0.2.0`. It must be
   `vMAJOR.MINOR.PATCH` and newer than the latest release. The workflow refuses
   to run on any other branch.
2. **Package.** `scripts/package-macos.sh --universal-build` builds the
   universal app and DMG, then signs the DMG for the self-updater with
   `ShipwatchReleaseTool sign`.
3. **Check.** `scripts/check-macos-package.sh` verifies the bundle, the
   bundled update helper, the DMG layout and the update signature.
4. **Publish.** `gh release create` tags the commit that triggered the run.
   `scripts/release-notes.sh` writes the release notes: the pull requests
   merged and the commits made since the previous release, and a link to the
   full comparison. Write pull request titles and commit subjects for users;
   they are the changelog, and installed apps show the start of it next to
   **Release notes**.

Releases run one at a time: a second push waits for the first release to finish
instead of cancelling it.

| Asset | Contents |
| --- | --- |
| `Shipwatch.dmg` | The universal app (Apple Silicon and Intel) in a drag-to-Applications window. |
| `Shipwatch.dmg.sha256` | The SHA-256 of the DMG, as a bare hex digest. |
| `Shipwatch.dmg.sig` | The update signature that installed apps verify, see [Updates](updates.md#what-shipwatch-verifies). |

Installed apps only look at the release GitHub marks as **Latest** and ignore
drafts and prereleases. Do not edit or replace the assets of a published
release: the signature covers the exact DMG and version. To fix a release,
merge the fix and let the next release replace it.

## Configuration

Set these under **Settings > Secrets and variables > Actions** in the repository.

| Name | Kind | Required | Purpose |
| --- | --- | --- | --- |
| `SHIPWATCH_UPDATE_SIGNING_KEY` | Secret | Yes | Base64 Ed25519 private key that signs `Shipwatch.dmg.sig`. The release fails without it. |
| `SHIPWATCH_CLIENT_ID` | Variable | No | GitHub App Client ID baked into the app, see [GitHub App setup](github-app-setup.md). |
| `SHIPWATCH_APP_SLUG` | Variable | No | GitHub App slug baked into the app, used for its install link. |

Without the two variables the released app asks for a Client ID in Settings, or
signs in through the GitHub CLI.

## Code signing status

The app is ad-hoc signed. It is not signed with an Apple Developer ID and not
notarized, so macOS asks before the first launch, see
[Installation](installation.md#first-launch). In-app updates do not rely on
Apple signing: each one is verified with the Shipwatch release key described below.

## Update signing key

The public half of the release key is built into every app, in
`UpdateTrust.publicKeysBase64` in
[`Sources/ShipwatchUpdate/UpdateSignature.swift`](../Sources/ShipwatchUpdate/UpdateSignature.swift).
The private half exists only as the `SHIPWATCH_UPDATE_SIGNING_KEY` secret and in
the maintainer's password manager. Never print it, commit it, or paste it into
an issue, log or chat.

`ShipwatchReleaseTool sign` refuses a private key whose public key is not in the
list, and the package check verifies the signature against the same list. A
misconfigured secret therefore fails the release instead of shipping an update
that installed apps would reject. Keep in mind that an installed app trusts the
list it was built with, not the list in the release it downloads.

### Create the first key

This has already been done for this repository. For a fork:

```bash
swift run ShipwatchReleaseTool keygen --public-key-out release-key.pub \
  | gh secret set SHIPWATCH_UPDATE_SIGNING_KEY --repo <owner>/<repo>
```

`keygen` prints only the private key on stdout, and `swift run` writes its build
output to stderr, so the private key goes straight into the secret without
appearing in the terminal. Put the contents of `release-key.pub` in
`publicKeysBase64` (replacing the existing entry), delete the file and commit.

### Rotate the key

Rotate in four steps so installed apps keep updating:

1. Create the next key pair. Keep the private key out of the terminal and shell history:

   ```bash
   (umask 077 && swift run ShipwatchReleaseTool keygen --public-key-out next-key.pub > next-key.secret)
   ```

   Store `next-key.secret` in your password manager, then delete it.
2. Add the contents of `next-key.pub` to `publicKeysBase64`, keeping the current
   key, and merge. This release is still signed with the current key, and every
   app that installs it trusts both keys.
3. After that release is published, and once installs have had time to pick it
   up (apps check every 6 hours by default and install only when the user
   agrees, unless they enabled automatic installs), replace the secret:

   ```bash
   gh secret set SHIPWATCH_UPDATE_SIGNING_KEY --repo mbianchidev/shipwatch
   ```

   Paste the next private key at the prompt. From now on releases are signed
   with the next key. Apps that never installed the release from step 2 show
   "The update signature is not valid for Shipwatch's release key" and need a
   manual [upgrade](installation.md#upgrade).
4. In a later release, remove the old key from `publicKeysBase64`.

### If the private key leaks

The key alone is not enough to reach users: installed apps only download
updates from this repository's releases on GitHub. Treat a leak as critical anyway.

1. Check who can publish releases in this repository and remove unexpected
   access. Review recent releases for assets you did not publish.
2. Follow the rotation steps without waiting between them: merge the release
   that trusts both keys, switch the secret right after it is published, then
   remove the leaked key in the next release.
3. Publish a [security advisory](../SECURITY.md) asking users to update, or to
   reinstall from the [releases page](https://github.com/mbianchidev/shipwatch/releases)
   if Shipwatch reports an invalid update signature.

Apps that never update keep trusting the leaked key. Only a manual reinstall
fixes them.

## Try a release locally

You can build and check a release DMG without the signing key:

```bash
SHIPWATCH_VERSION=v0.1.0 bash scripts/package-macos.sh
bash scripts/check-macos-package.sh
```

Without the key there is no `Shipwatch.dmg.sig`, and the check says it skipped
the signature. A throwaway key from `keygen` does not help: `sign` refuses any
key that is not in `publicKeysBase64`, and test keys must never be added to it.
See [Development](development.md#package) for the other packaging options.

## Verify a published release

Download the three assets, then check the checksum:

```bash
cd ~/Downloads
echo "$(cat Shipwatch.dmg.sha256)  Shipwatch.dmg" | shasum -a 256 -c -
```

To check the update signature as an installed app would, run this from a
checkout of the release tag (the version has no `v`):

```bash
swift run ShipwatchReleaseTool verify ~/Downloads/Shipwatch.dmg ~/Downloads/Shipwatch.dmg.sig --version 0.0.1
```

It prints `Verified … for version 0.0.1.` and exits 0 when the signature is valid.
