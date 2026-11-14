# Security policy

## Supported versions

Security fixes target the **latest stable release only**.

| Version or branch | Receives security fixes |
| --- | --- |
| Latest stable published release | Yes |
| Older releases | No, upgrade to the latest stable release |
| Development builds / `main` | Not a separately supported release |

See [published releases](https://github.com/mbianchidev/shipwatch/releases).

## Report a vulnerability privately

Use GitHub's
[private vulnerability reporting form](https://github.com/mbianchidev/shipwatch/security/advisories/new).
Sign in to GitHub to submit a report. Do not publish vulnerability details in a
public issue or pull request.

Include:

- Affected version, macOS version, CPU architecture, and sign-in method
  (Shipwatch GitHub App or GitHub CLI token).
- The impact and affected component or workflow, for example sign-in, token
  storage, update download and verification, or app replacement.
- Minimal reproduction steps using synthetic repositories and accounts.
- Relevant redacted errors or a small proof of concept. Never include access
  tokens, Keychain contents, private repository data, or other people's data.

## Response and disclosure

Reports are handled on a **best-effort basis**, without a guaranteed
acknowledgment, update, or remediation timeline. Maintainers may request more
information through the private report and coordinate any fix and release
there.

Keep details private while coordinating with maintainers. Publish after a fix
is available or on a disclosure date agreed in the private report. There is no
fixed disclosure window.

For non-security bugs, use the [contribution process](CONTRIBUTING.md).
