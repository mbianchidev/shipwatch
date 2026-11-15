# Accessibility

Shipwatch is a native macOS menu bar app built with SwiftUI and AppKit.
Accessibility improvements are welcome. These are contribution and
verification guidelines, not a claim that the app has passed an accessibility
audit.

## Contribution guidelines

- Prefer native macOS controls and semantics. Custom views such as repository
  rows, status dots and count chips need accessible labels and values, not
  only tooltips or color.
- Every status must be readable without color: CI uses distinct symbols
  (check mark, cross, exclamation mark, dotted circle) as well as green, red,
  orange and yellow, and the same text is exposed to VoiceOver.
- Keep the popover and Settings usable from the keyboard. Preserve visible
  focus, a predictable focus order, and the existing shortcuts (Command-R
  refresh, Command-comma Settings, Command-Q quit).
- Periodic refreshes must not steal focus or flood VoiceOver with
  announcements. Announce failures that need action, such as an expired
  sign-in or a failed update.
- Check contrast in both the light and dark popover, and in the always-dark
  Settings window. Respect Increase Contrast, Reduce Transparency and
  Reduce Motion.
- Give icon-only buttons clear accessible names. Keep hit targets usable in the
  compact popover rows.
- Documentation needs clear headings, descriptive link text, alt text for
  screenshots, and text explanations of visual workflows.

Use [Apple's accessibility guidance](https://developer.apple.com/accessibility/)
for native behavior. WCAG 2.2 AA principles are a useful reference for contrast
and keyboard access, not a certification of this desktop app.

## Verification

`swift test` and the [package checks](docs/development.md#package) validate
logic and distribution, not the accessibility tree. UI changes also need manual
checks on macOS:

| Check | What to verify |
| --- | --- |
| Keyboard | Open the popover, move between rows and actions, open Settings, switch tabs, add and remove repositories, choose a workspace and excluded folders, toggle clone sync, sign in and out |
| VoiceOver | Each row reads the repository, release, CI status, activity, issue and pull request counts; each local clone reads its sync status; icon-only buttons have names |
| Display settings | Increase Contrast, Reduce Transparency, Reduce Motion, light and dark menu bar |
| Dynamic content | Refreshing and auto-updates do not move focus or repeat announcements |
| Errors | Sign-in, rate-limit, network, update and clone sync errors are shown as text |

Use synthetic repositories (for example a test account or `octocat`) and never
real private data in screenshots or recordings.

## Known limitations

- The popover is a fixed-width, dense list designed for quick scanning.
  Long repository names are truncated; the tooltip and the VoiceOver label
  carry the full `owner/name`.
- The Settings window is always dark, as approved in the design mockups, and
  has not been reviewed with every display setting.
- No manual VoiceOver, contrast or keyboard audit has been completed yet.

## Reporting barriers

Open an [issue](https://github.com/mbianchidev/shipwatch/issues/new/choose) for
non-security accessibility barriers. Include the macOS and Shipwatch versions,
the affected workflow, any assistive technology or display settings, expected
behavior, and synthetic reproduction steps. Follow [SECURITY.md](SECURITY.md)
for vulnerabilities instead.
