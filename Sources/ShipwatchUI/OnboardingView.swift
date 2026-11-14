import ShipwatchCore
import SwiftUI

/// First run: GitHub App device flow, or the `gh` CLI token.
struct OnboardingView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            switch model.signInStep {
            case .welcome, .requesting, .failed:
                WelcomeStep(model: model)
            case let .authorize(code, url, expiresAt):
                AuthorizeStep(model: model, code: code, url: url, expiresAt: expiresAt)
            case .install:
                InstallStep(model: model)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }
}

private struct StepDots: View {
    let step: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...2, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 22, height: 3)
            }
        }
        .accessibilityLabel("Step \(step) of 2")
    }
}

private struct StepTitle: View {
    let title: String
    let subtitle: Text

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            subtitle
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    let symbol: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                }
                Text(title)
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(AccentButtonStyle(cornerRadius: 8))
    }
}

private struct WelcomeStep: View {
    let model: AppModel

    private var hasClientID: Bool { !model.config.clientID.isEmpty }

    var body: some View {
        VStack(spacing: 16) {
            AppGlyph(size: 52)
            StepTitle(
                title: "Welcome to Shipwatch",
                subtitle: Text("Releases, Actions, issues and PRs for the repos you care about, one click away.")
            )

            VStack(spacing: 8) {
                PrimaryButton(
                    title: "Sign in with GitHub",
                    symbol: "key.fill",
                    busy: model.signInStep == .requesting
                ) {
                    model.startSignIn()
                }
                .disabled(!hasClientID || model.signInStep == .requesting)

                if case .failed(let message) = model.signInStep {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.failing)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if hasClientID {
                    Label {
                        Text("Read-only. Shipwatch only sees the repositories you grant to its GitHub App.")
                    } icon: {
                        Image(systemName: "lock")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 4) {
                        Text("This build has no GitHub App Client ID.")
                        Button("Add one in Settings") { model.actions.showSettings(.account) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.link)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                VStack { Divider() }
                Text("or")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                VStack { Divider() }
            }

            cliButton

            HStack(spacing: 16) {
                Button("Settings…") { model.actions.showSettings(.account) }
                Button("Quit") { model.actions.quit() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
    }

    private var cliButton: some View {
        let ready: Bool
        let detail: String
        switch model.cliStatus {
        case .unknown:
            ready = false
            detail = "Looking for gh…"
        case .notInstalled:
            ready = false
            detail = "gh not found · install the GitHub CLI first"
        case .signedOut:
            ready = false
            detail = "gh found · not signed in (run gh auth login)"
        case .signedIn(let login):
            ready = true
            detail = "gh found · signed in as @\(login)"
        }
        return Button { model.useCLI() } label: {
            VStack(spacing: 2) {
                Label("Use GitHub CLI token", systemImage: "terminal")
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!ready)
        .help("Reads `gh auth token` on demand. Shipwatch never stores this token.")
    }
}

private struct AuthorizeStep: View {
    let model: AppModel
    let code: String
    let url: URL
    let expiresAt: Date

    var body: some View {
        VStack(spacing: 16) {
            StepDots(step: 1)
            StepTitle(
                title: "Authorize on GitHub",
                subtitle: Text("Enter this code at \(Text(url.host().map { $0 + url.path() } ?? url.absoluteString).fontWeight(.semibold).foregroundStyle(.primary))")
            )
            HStack(spacing: 12) {
                Text(code)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .kerning(3)
                    .textSelection(.enabled)
                Button { model.copyToPasteboard(code) } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 26, height: 26)
                        .background(Theme.fillStrong, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))

            PrimaryButton(title: "Copy Code & Open GitHub", symbol: "arrow.up.forward.square") {
                model.copyCodeAndOpenGitHub(code: code, url: url)
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for authorization · expires in \(RelativeTime.countdown(expiresAt.timeIntervalSince(context.date)))")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            Button("Cancel") { model.cancelSignIn() }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }
}

private struct InstallStep: View {
    let model: AppModel

    private let permissions: [(String, String)] = [
        ("play.circle", "Actions"),
        ("tag", "Contents (releases)"),
        ("smallcircle.filled.circle", "Issues"),
        ("arrow.triangle.pull", "Pull requests"),
        ("list.bullet", "Metadata"),
    ]

    var body: some View {
        VStack(spacing: 16) {
            StepDots(step: 2)
            StepTitle(
                title: "Choose repositories",
                subtitle: Text("Install the Shipwatch app and pick exactly which repositories it may read. You can change this any time.")
            )
            VStack(spacing: 8) {
                ForEach(permissions, id: \.1) { symbol, name in
                    HStack(spacing: 8) {
                        Image(systemName: symbol)
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text(name)
                        Spacer()
                        Text("Read-only")
                            .fontWeight(.medium)
                            .foregroundStyle(Theme.passing)
                    }
                    .font(.system(size: 12.5))
                }
            }
            .padding(12)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))

            PrimaryButton(title: "Install on GitHub", symbol: "arrow.up.forward.square") {
                model.open(model.manageAccessURL)
            }
            Button("I've installed it · Continue") { model.finishInstall() }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }
}
