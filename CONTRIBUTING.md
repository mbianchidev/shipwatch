# Contributing to Shipwatch

Bug reports, documentation fixes, accessibility improvements, tests and focused
code changes are welcome. Please read the [Code of Conduct](CODE_OF_CONDUCT.md)
and the [documentation index](docs/README.md) first.

**Coding agents must read [AGENTS.md](AGENTS.md) before editing.** Everyone
remains responsible for their work, including
[AI-assisted contributions](README.md#ai-policy).

## Bugs, questions and proposals

Search [existing issues](https://github.com/mbianchidev/shipwatch/issues) first,
then use the [issue templates](https://github.com/mbianchidev/shipwatch/issues/new/choose).
For bugs, include the Shipwatch and macOS versions, your Mac (Apple Silicon or
Intel), the sign-in method, reproduction steps, and expected and actual
behavior. Use synthetic repositories and redact logs and screenshots: never
share access tokens or private repository data.

For new features or larger design changes, open an issue describing the problem
and the proposed approach before writing a lot of code. Shipwatch aims to stay
tiny and read-only, so proposals that need write access to GitHub are unlikely
to be accepted.

Report vulnerabilities through the [private security process](SECURITY.md), not
public issues. See [SUPPORT.md](SUPPORT.md) for where to ask questions.

## Development setup

You need macOS 14 or later, Git and Xcode 16 or later (Swift 6). There are no
third-party Swift package dependencies. A GitHub App is optional for local
development: the GitHub CLI fallback works with `gh auth login`.

The [development guide](docs/development.md) covers building, running, tests,
screenshots, packaging and debugging. The [architecture guide](docs/architecture.md)
explains the code layout. UI contributors should also read the
[accessibility guidelines](ACCESSIBILITY.md).

## Code, tests and documentation

- Follow the existing Swift style and target boundaries: GitHub and update
  logic in the core libraries, views in `ShipwatchUI`. Keep comments for
  non-obvious logic only.
- Add tests for behavior you introduce or fix. Use the mocked HTTP transport,
  temporary directories and synthetic fixtures, never real user data or live
  network calls.
- Shipwatch only reads from GitHub. Do not add requests that write to GitHub or
  widen the GitHub App permissions.
- Update the relevant guide in `docs/` when behavior, settings, defaults or
  setup change, and regenerate screenshots for visible UI changes. Keep the
  README a short landing page.

## Pull requests

1. Branch from `main` and keep unrelated changes in separate pull requests.
2. Make the change with its tests and documentation.
3. Run `swift build` (no warnings) and `swift test`. For packaging changes,
   also run the [package scripts](docs/development.md#package).
4. Describe what changed, why, how you verified it, and anything untested.
   Link related issues.
5. Address review feedback and failing CI before asking for another review.

Every merge to `main` publishes a new patch release automatically, see
[releases](docs/releases.md). Do not create tags or publish releases yourself.
