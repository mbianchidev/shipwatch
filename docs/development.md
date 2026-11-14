# Development

Requires macOS 14+ and Xcode 16+ (Swift 6). Packaging also needs Python 3.10+
for the installer layout. There are no third-party Swift package dependencies.

If `swift build` picks the Command Line Tools instead of Xcode and fails on
SwiftUI or Swift Testing, point it at Xcode:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Build, run, test

```bash
swift build
swift test
SHIPWATCH_CLIENT_ID=Iv23li... SHIPWATCH_APP_SLUG=shipwatch swift run Shipwatch
```

Without the variables, sign in with the GitHub CLI fallback or set the app in
Settings > Account. Launch at login only works from a packaged `.app`.

`swift test` runs both Swift Testing targets: `ShipwatchCoreTests` (GitHub API,
CI status, repo list, device flow, workspace scan and clone fast-forward) and
`ShipwatchUpdateTests` (feed, signature, download, install and rollback, all
against temporary directories and fake command runners). The clone tests create
temporary git repositories with your global git config ignored, and are
skipped when git isn't installed. Use `swift test --filter <SuiteName>` for one
suite.

`swift run Shipwatch` is a development build, so the self-updater stays off and
Settings > General shows "Development build". In-app updates only work from a
packaged `Shipwatch.app` with a release version, see [Updates](updates.md). It
uses your real preferences, so with clone sync on it updates your real clones.

## Screenshots

```bash
swift run ShipwatchSnapshots            # writes docs/screenshots/*.png
swift run ShipwatchSnapshots /tmp/shots # or anywhere else
```

The renderer uses mocked repos (octocat, acme-org), an offline transport and a
git stub, so it never touches the network, your Keychain or your clones.
Windows are drawn offscreen and the app is never activated, so native controls
(switches, checkboxes, default buttons) render in their inactive tint.

## Package

```bash
bash scripts/package-macos.sh                     # per-arch builds joined with lipo
bash scripts/package-macos.sh --universal-build   # one swiftbuild pass, as in CI
bash scripts/check-macos-package.sh               # verifies dist/Shipwatch.dmg
```

| Variable | Effect |
| --- | --- |
| `SHIPWATCH_VERSION` | `dev` (default) or `v1.2.3`, sets the bundle version |
| `SHIPWATCH_CLIENT_ID` | GitHub App Client ID baked into `Info.plist` |
| `SHIPWATCH_APP_SLUG` | GitHub App slug baked into `Info.plist` |
| `SHIPWATCH_PYTHON` | Python 3.10+ used for dmgbuild (default `python3`) |
| `SHIPWATCH_UPDATE_SIGNING_KEY` | Release signing key; only set by the [release workflow](releases.md) |

The output is `dist/Shipwatch.dmg` (+ `.sha256`): a universal, ad-hoc signed
app with the update helper in `Contents/Helpers`. It is not notarized;
`Install.txt` in the DMG explains how to open it. With a signing key and a
release version the script also writes `Shipwatch.dmg.sig`; it refuses to sign a
`dev` build. Local builds normally have no key, see
[Try a release locally](releases.md#try-a-release-locally).

The installer window is laid out by [dmgbuild](https://github.com/dmgbuild/dmgbuild)
from `scripts/dmg-layout.py`. On first use the scripts install the hash-locked
version from `packaging/macos/requirements-dmg.txt` into a private venv under
`.build/`, never into your Python. The check script mounts the DMG read-only and
reads its `.DS_Store` to verify the layout, so Finder is never opened.

`ShipwatchSnapshots` also renders the app icon (`--iconset`) from the same
sailboat path as the menu bar icon, and the installer background
(`--dmg-background`). `docs/logo.png` in the README is that iconset's
`icon_256x256.png`; copy it again if the icon changes.

## Update tooling

- `ShipwatchUpdate`: feed, download, signature and install logic shared by the
  app and the helper.
- `ShipwatchUpdateHelper`: bundled helper that swaps the app after Shipwatch
  quits, waits for the new version to start, and rolls back if it does not.
- `ShipwatchReleaseTool`: `keygen`, `sign` and `verify` for update signatures;
  not shipped in the app. See [Releases](releases.md#update-signing-key).

Never run the helper against a real install while developing. Its behavior is
covered by `ShipwatchUpdateTests` with temporary app bundles.

## CI

- `.github/workflows/ci.yml` runs on pushes to `main` and pull requests: build,
  test, package, verify the DMG, and upload it as the `Shipwatch-macOS` artifact.
- `.github/workflows/codeql.yml` scans the Swift code and the workflows on
  pushes and pull requests to `main`, and weekly.
- `.github/workflows/release.yml` publishes a release on every push to `main`,
  see [Releases](releases.md).
- Dependabot updates the pinned GitHub Actions and the locked dmgbuild weekly.

Actions are pinned to full commit SHAs with the version in a comment. Keep that
format when adding or updating one.
