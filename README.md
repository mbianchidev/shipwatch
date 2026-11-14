# Shipwatch

Tiny macOS menu bar app that watches the GitHub repositories you pick.

<p align="center">
  <img src="docs/screenshots/popover-dark.png" alt="Shipwatch popover listing repositories with release, Actions status, activity, issues and pull requests" width="420">
</p>

Per repo, at a glance:

- latest release
- Actions status: ✓ passing, ✗ failing, ◐ running, linking to the run
- last activity
- open issues
- open PRs, with Dependabot PRs split out (`11 PRs (5 dependabot)`), each linking to its list

Add, reorder, hide and remove repos in Settings. Sign-in is read-only, through a
GitHub App or your existing `gh` login.

## Install

Requires macOS 14+ (Apple Silicon or Intel). Download `Shipwatch-macOS` from the
latest [CI run](https://github.com/mbianchidev/shipwatch/actions/workflows/ci.yml),
open the DMG and follow `Install.txt`. To build it yourself, see
[development](docs/development.md).

## Documentation

- [GitHub App setup](docs/github-app-setup.md)
- [Architecture](docs/architecture.md)
- [Development](docs/development.md)
- [Screenshots](docs/screenshots) and [mockups](docs/mockups)

## AI policy

You are responsible for everything you contribute, including AI-assisted code,
documentation, and assets. Review and test your contribution. Be able to explain
what the code does and why it is needed.

## License

[MIT](LICENSE)
