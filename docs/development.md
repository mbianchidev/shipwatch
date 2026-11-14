# Development

Requires macOS 14+ and Xcode 16+ (Swift 6).

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

## Screenshots

```bash
swift run ShipwatchSnapshots            # writes docs/screenshots/*.png
swift run ShipwatchSnapshots /tmp/shots # or anywhere else
```

The renderer uses mocked repos (octocat, acme-org) and an offline transport, so
it never touches the network or your Keychain. Windows are drawn offscreen and
the app is never activated, so native controls (switches, checkboxes, default
buttons) render in their inactive tint.

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

The output is `dist/Shipwatch.dmg` (+ `.sha256`): a universal, ad-hoc signed
app. It is not notarized; `Install.txt` in the DMG explains how to open it.
The app icon is rendered by `ShipwatchSnapshots --iconset` from the same
sailboat path as the menu bar icon.

## CI

`.github/workflows/ci.yml` runs on pushes to `main` and pull requests: build,
test, package, verify the DMG, and upload it as the `Shipwatch-macOS` artifact.
