# Agent instructions

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the relevant guide under
[docs/](docs/README.md) before editing. Keep changes focused and preserve
existing user changes.

## Repository map

- `Package.swift`: SwiftPM package, macOS 14+, Swift tools 6.0, no third-party
  Swift package dependencies.
- `Sources/ShipwatchCore`: GitHub API client, device flow, token storage, models,
  CI evaluation, workspace scan (`Workspace.swift`) and clone fast-forward
  (`CloneSyncer.swift`, git via `GitRunning` in `Git.swift`). No UI.
- `Sources/ShipwatchUI`: SwiftUI views hosted in AppKit, `AppModel`,
  `WorkspaceModel`, preferences and the `Updater`. `Sources/Shipwatch` is only
  the entry point.
- `Sources/ShipwatchUpdate` and `Sources/ShipwatchUpdateHelper`: self-update
  logic and the bundled helper that swaps and rolls back the app.
- `Sources/ShipwatchReleaseTool`: update signing for releases. Not shipped.
- `Sources/ShipwatchSnapshots`: screenshots, iconset and DMG background from mocked data.
- `Tests/ShipwatchCoreTests` and `Tests/ShipwatchUpdateTests`: Swift Testing suites.
- `scripts/` and `packaging/macos/`: packaging, package checks, release notes,
  the dmgbuild layout and its hash-locked requirements.
- `.github/workflows`: CI, CodeQL and continuous releases.
- `docs/`: user and developer docs, generated `screenshots/` and the original `mockups/`.

See [architecture](docs/architecture.md) and [development](docs/development.md)
for detail.

## Commands

Run on macOS 14+ with Xcode 16+. Packaging also needs Python 3.10+.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer  # if the Command Line Tools are selected
swift build
swift test
swift run ShipwatchSnapshots            # regenerates docs/screenshots/*.png
bash scripts/package-macos.sh
bash scripts/check-macos-package.sh
```

Use the smallest relevant checks for a change; run the package scripts for
packaging, updater or `Info.plist` changes. `swift build` must stay free of
warnings. No formatter is configured. Run `shellcheck` on changed scripts and
`actionlint` on changed workflows when they are installed.

## Safety and implementation

- Shipwatch only reads from GitHub. Do not add requests that change GitHub
  data or ask for write permissions. The only POSTs are GraphQL queries, the
  OAuth device flow and token refresh.
- Local clone sync is opt-in and fast-forward only. Never add git commands that
  commit, reset, stash, check out, rebase, force, push or delete anything, and
  keep git non-interactive. `CloneSyncerTests` use temporary repositories
  (`GitFixture`, `IsolatedGit` ignores your global git config); snapshots use
  `OfflineGit`. Never point tests or snapshots at real clones.
- Tests and snapshots use synthetic data (`octocat`, `acme-org`) and mocked
  transports. Never use real tokens, accounts or private repository data.
- Do not launch the app (`swift run Shipwatch`) as validation: it reads the
  real Keychain and preferences, and can update real clones. Prefer tests and
  `ShipwatchSnapshots`.
- Never run `ShipwatchUpdateHelper` or an install against a real
  `Shipwatch.app`. Updater tests use temporary bundles and fake command runners.
- Keep update checks failing closed: signature before mounting, allowed
  download hosts, size limits and bundle validation. Do not change the signed
  message format; installed apps depend on it.
- Never print, log or commit the update signing private key, and never add a
  test key to `UpdateTrust.publicKeysBase64`. Key changes follow
  [rotation](docs/releases.md#rotate-the-key).
- Pin GitHub Actions to full commit SHAs with the version in a comment.
- Keep the README short and move detail into `docs/`. Update the affected docs,
  and regenerate screenshots when the UI changes.

Every push to `main` publishes a release, see [releases](docs/releases.md). Do
not create tags, publish releases or edit release assets.
