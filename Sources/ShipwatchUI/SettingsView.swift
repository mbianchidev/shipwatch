import AppKit
import ShipwatchCore
import SwiftUI

/// The Settings window content. Always dark, as approved in the mockups.
public struct SettingsView: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: Binding(get: { model.settingsTab }, set: { model.settingsTab = $0 }))
            Divider()
            Group {
                switch model.settingsTab {
                case .repositories: RepositoriesSettingsView(model: model)
                case .workspace: WorkspaceSettingsView(model: model)
                case .general: GeneralSettingsView(model: model)
                case .account: AccountSettingsView(model: model)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .top)
            .background(Theme.settingsContent)
        }
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }
}

struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button { selection = tab } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18, weight: .regular))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.system(size: 11.5))
                    }
                    .foregroundStyle(selection == tab ? Color.accentColor : .secondary)
                    .frame(minWidth: 70)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(selection == tab ? Color.white.opacity(0.1) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .background(Theme.settingsChrome)
    }
}

/// Rounded dark container used for grouped settings.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .settingsTable()
    }
}

extension View {
    /// Dark rounded container shared by Settings cards and tables.
    func settingsTable() -> some View {
        background(Theme.settingsCard, in: RoundedRectangle(cornerRadius: 9))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// One row of a Settings form `Grid`: a trailing label, then the control with any `FormCaption` under it.
///
/// Captions share the control's cell, which fills the second column, so the grid measures each row at the width it
/// draws it. As separate rows they were measured narrower than drawn and left uneven gaps.
struct FormRow<Content: View>: View {
    let label: String
    var dimmed: Bool
    let content: Content

    init(_ label: String, dimmed: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = label
        self.dimmed = dimmed
        self.content = content()
    }

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(dimmed ? .tertiary : .primary)
                .fixedSize()
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 6) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Small explanatory text under a control in a `FormRow`.
struct FormCaption: View {
    let text: String
    var color: Color = .secondary

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A Settings pop-up menu as wide as its longest option.
///
/// AppKit measures the width up front. With `fixedSize()`, SwiftUI sometimes measured the pop-up before it had any
/// items and kept it collapsed to its arrows.
struct SettingsPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .labelsHidden()
        .frame(width: PopUpWidth.fitting(options.map(label)))
    }
}

@MainActor
enum PopUpWidth {
    private static var cache: [[String]: CGFloat] = [:]

    /// The width AppKit gives a regular pop-up button holding `titles`.
    static func fitting(_ titles: [String]) -> CGFloat {
        if let width = cache[titles] { return width }
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: titles)
        let width = ceil(button.intrinsicContentSize.width)
        cache[titles] = width
        return width
    }
}

struct SettingsCardRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var showsDivider = true
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if showsDivider {
                Divider().padding(.leading, 12)
            }
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    let model: AppModel

    var body: some View {
        @Bindable var prefs = model.prefs
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
            FormRow("Refresh every:") {
                SettingsPicker(
                    title: "Refresh every",
                    selection: Binding(get: { prefs.refreshMinutes }, set: { model.setRefreshMinutes($0) }),
                    options: Preferences.refreshChoices
                ) { $0.counted("minute") }
                FormCaption("Refreshes faster (every 20 s) while a workflow is running or queued.")
            }

            FormRow("Last activity means:") {
                SettingsPicker(title: "Last activity means", selection: $prefs.activityMode, options: ActivityMode.allCases, label: \.label)
                FormCaption("Last push, or any update (issues, PRs, comments).")
            }

            FormRow("Include pre-releases:") {
                Toggle("Include pre-releases", isOn: Binding(get: { prefs.includePrereleases }, set: { model.setIncludePrereleases($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            FormRow("Show security alerts:") {
                Toggle("Show security alerts", isOn: Binding(get: { prefs.showSecurityAlerts }, set: { model.setShowSecurityAlerts($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                FormCaption("Open Dependabot, code scanning and secret scanning alerts. Needs write access, admin for secret scanning.")
            }

            FormRow("Release notifications:") {
                ReleaseNotificationsRow(model: model)
            }

            FormRow("Show count in menu bar:") {
                SettingsPicker(title: "Show count in menu bar", selection: $prefs.menuBarCount, options: MenuBarCount.allCases, label: \.label)
                FormCaption("Number of running or failing repositories next to the sailboat.")
            }

            FormRow("Launch at login:") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!model.loginItemAvailable)
                if !model.loginItemAvailable {
                    FormCaption("Available when Shipwatch runs from its app bundle.")
                } else if let error = model.launchAtLoginError {
                    FormCaption(error, color: Theme.failing)
                }
            }
            updateRows
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .task { await model.notifier.refreshAuthorization() }
    }

    @ViewBuilder
    private var updateRows: some View {
        let updater = model.updater
        @Bindable var prefs = model.prefs
        Divider()
            .gridCellUnsizedAxes(.horizontal)
            .padding(.vertical, 4)

        FormRow("Version:") {
            Text(updater.isSupported ? updater.currentVersion.description : "Development build")
                .foregroundStyle(.secondary)
        }
        FormRow("Updates:") {
            UpdateStatusLine(updater: updater)
            if updater.isSupported {
                HStack(spacing: 8) {
                    Button("Check Now") { updater.checkNow() }
                        .disabled(updater.isBusy)
                    if let release = updater.availableRelease {
                        Button("Install \(release.tag) and Restart") { updater.install() }
                            .buttonStyle(.borderedProminent)
                            .disabled(updater.isBusy)
                        Button("Release notes") { model.open(release.pageURL) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.link)
                            .help(release.notes)
                            .accessibilityLabel("Release notes for \(release.tag)")
                    }
                }
                .padding(.top, 2)
            }
        }

        FormRow("Check automatically:") {
            HStack(spacing: 10) {
                Toggle("Check for updates automatically", isOn: Binding(get: { prefs.checkForUpdates }, set: { updater.setCheckForUpdates($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                SettingsPicker(
                    title: "Check for updates",
                    selection: Binding(get: { prefs.updateCheckHours }, set: { updater.setUpdateCheckHours($0) }),
                    options: Preferences.updateCheckChoices,
                    label: Self.checkInterval
                )
                .disabled(!prefs.checkForUpdates)
            }
            .disabled(!updater.isSupported)
        }

        FormRow("Install automatically:") {
            Toggle("Install updates automatically", isOn: $prefs.installUpdatesAutomatically)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!updater.isSupported)
            FormCaption("Updates are signed by the Shipwatch release key and checked before installing. Shipwatch restarts to finish.")
            if let message = updater.pause.message(offering: updater.availableRelease?.version), !updater.hasFailed {
                FormCaption(message, color: Theme.failing)
            }
        }
    }

    private static func checkInterval(_ hours: Int) -> String {
        switch hours {
        case 1: "Every hour"
        case 24: "Every day"
        default: "Every \(hours) hours"
        }
    }

}

/// How many repositories send release notifications, whether macOS lets Shipwatch show them, and a test button.
struct ReleaseNotificationsRow: View {
    let model: AppModel

    var body: some View {
        let notifier = model.notifier
        let count = model.releaseNotificationCount
        HStack(spacing: 8) {
            Text(count == 0 ? "Off" : "On for \(count.counted("repository", "repositories"))")
                .foregroundStyle(.secondary)
            Button("Choose…") { model.settingsTab = .repositories }
                .help("Click the bell next to a repository to get its release notifications")
            Button("Send Test") { notifier.postTest() }
                .disabled(notifier.authorization != .allowed)
                .help("Show a sample notification")
        }
        switch notifier.authorization {
        case .unavailable:
            FormCaption("Available when Shipwatch runs from its app bundle.")
        case .denied:
            HStack(spacing: 8) {
                FormCaption("Notifications are off for Shipwatch in System Settings.", color: Theme.warning)
                Button("Open Notification Settings…") { model.open(Self.systemSettingsURL) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.link)
                    .font(.system(size: 12))
            }
        case .notDetermined, .allowed:
            FormCaption("A notification when a repository with the bell on in Repositories publishes a GitHub release. Pushing a tag alone doesn't count.")
        }
    }

    private static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
}

/// One line describing the updater state. Uses a symbol and words, not only color.
struct UpdateStatusLine: View {
    let updater: Updater

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if updater.isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(text(now: context.date))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(updater.hasFailed ? Theme.failing : .secondary)
        }
    }

    private var symbol: String {
        if !updater.isSupported { return "info.circle" }
        switch updater.state {
        case .upToDate: return "checkmark.circle"
        case .available: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle"
        case .idle, .checking, .downloading, .verifying, .installing: return "clock"
        }
    }

    private func text(now: Date) -> String {
        if !updater.isSupported { return "Updates are available in the packaged app." }
        let version = updater.availableRelease?.version.description ?? ""
        switch updater.state {
        case .idle: return "Not checked yet"
        case .checking: return "Checking for updates…"
        case .upToDate(let checkedAt): return "Up to date (checked \(RelativeTime.updated(checkedAt, now: now)))"
        case .available(let release): return "Version \(release.version.description) available"
        case .downloading(let fraction?): return "Downloading \(version)… \(Int(fraction * 100))%"
        case .downloading(nil): return "Downloading \(version)…"
        case .verifying: return "Verifying the download…"
        case .installing: return "Installing \(version), Shipwatch will restart…"
        case .failed(let message): return message
        }
    }
}

// MARK: - Account

struct AccountSettingsView: View {
    let model: AppModel
    @State private var showsAppConfig = false

    private var permissionRows: [(symbol: String, title: String, keys: [String])] {
        var rows: [(symbol: String, title: String, keys: [String])] = [
            ("play.circle", "Actions", ["actions"]),
            ("tag", "Contents (releases)", ["contents"]),
            ("smallcircle.filled.circle", "Issues · Pull requests · Metadata", ["issues", "pull_requests", "metadata"]),
        ]
        if model.prefs.showSecurityAlerts {
            rows.append(("exclamationmark.shield", "Security alerts", ["vulnerability_alerts", "security_events", "secret_scanning_alerts"]))
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            accountCard
            if model.authMethod == .githubApp {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Permissions granted").padding(.leading, 4)
                    SettingsCard {
                        ForEach(permissionRows, id: \.title) { row in
                            SettingsCardRow(symbol: row.symbol, title: row.title) {
                                permissionLevel(row.keys)
                            }
                        }
                        SettingsCardRow(symbol: "list.bullet", title: "Installed on", showsDivider: false) {
                            Text(installedOn)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            fallbackSection
            appConfigSection
            HStack {
                Button { model.open(model.manageAccessURL) } label: {
                    Label("Manage Repository Access…", systemImage: "arrow.up.forward.square")
                }
                .disabled(model.authMethod == .githubCLI)
                Spacer()
                if model.authMethod == nil {
                    Button("Sign In…") { model.actions.showPopover() }
                } else {
                    Button("Sign Out") { model.signOut() }
                }
            }
            .controlSize(.large)
        }
        .font(.system(size: 13))
    }

    private var accountCard: some View {
        HStack(spacing: 14) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                Text(model.user.map { "@\($0.login)" } ?? (model.authMethod == nil ? "Not signed in" : "Loading…"))
                    .font(.system(size: 15, weight: .semibold))
                Label(methodDescription, systemImage: model.authMethod == .githubCLI ? "terminal" : "key")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.authMethod != nil {
                Text(model.authMethod == .githubApp ? "Read-only" : "Reads only")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.passing)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Theme.passing.opacity(0.16), in: Capsule())
                    .help(model.authMethod == .githubApp
                        ? "The Shipwatch GitHub App only has read permissions."
                        : "Shipwatch only sends GET requests, but the gh token keeps its own scopes.")
            }
        }
        .padding(14)
        .background(Theme.settingsCard, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }

    private var avatar: some View {
        let placeholder = Circle()
            .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.65, blue: 1), Color(red: 0.75, green: 0.6, blue: 0.98)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: "person").font(.system(size: 18, weight: .medium)).foregroundStyle(.white))
        return Group {
            if let url = model.user?.avatarUrl {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(Circle())
    }

    private var methodDescription: String {
        switch model.authMethod {
        case .githubApp: "Signed in with the Shipwatch GitHub App"
        case .githubCLI: "Using the GitHub CLI token"
        case nil: "Sign in from the menu bar to start watching repositories"
        }
    }

    private func permissionLevel(_ keys: [String]) -> some View {
        let granted = keys.compactMap { key in model.installations.lazy.compactMap { $0.permissions?[key] }.first }
        let text: String
        let color: Color
        if granted.isEmpty {
            text = model.installations.isEmpty ? "Not installed" : "None"
            color = Theme.warning
        } else if granted.allSatisfy({ $0 == "read" }) && granted.count == keys.count {
            text = "Read"
            color = Theme.passing
        } else if granted.contains(where: { $0 != "read" }) {
            text = "Write"
            color = Theme.warning
        } else {
            text = "Partial"
            color = Theme.warning
        }
        return Text(text)
            .fontWeight(.medium)
            .foregroundStyle(color)
    }

    private var installedOn: String {
        guard !model.installations.isEmpty else { return "Nowhere yet" }
        return model.installations.map { installation in
            if installation.repositorySelection == "all" {
                return "\(installation.account.login) (all repos)"
            }
            let count = model.installationRepoCounts[installation.id].map { " (\($0.counted("repo")))" } ?? ""
            return installation.account.login + count
        }
        .joined(separator: " · ")
    }

    private var fallbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Fallback").padding(.leading, 4)
            SettingsCard {
                SettingsCardRow(symbol: "terminal", title: "Use GitHub CLI token if app sign-in is unavailable") {
                    Toggle("Use GitHub CLI token", isOn: Binding(get: { model.prefs.cliFallback }, set: { model.setCLIFallback($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsCardRow(symbol: "key", title: model.cliPath.map { "gh at \($0)" } ?? "gh not found", showsDivider: false) {
                    Text(cliDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .task { await model.probeCLI() }
    }

    private var cliDetail: String {
        switch model.cliStatus {
        case .unknown: "checking…"
        case .notInstalled: "install the GitHub CLI"
        case .signedOut: "not signed in"
        case .signedIn(let login): "signed in as @\(login)"
        }
    }

    private var appConfigSection: some View {
        @Bindable var prefs = model.prefs
        return DisclosureGroup(isExpanded: $showsAppConfig) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Only needed for builds without a bundled GitHub App, for example when you register your own. See docs/github-app-setup.md.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Client ID:").gridColumnAlignment(.trailing)
                        TextField(model.config.clientID.isEmpty ? "Iv23li…" : model.config.clientID, text: $prefs.clientIDOverride)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    GridRow {
                        Text("App slug:").gridColumnAlignment(.trailing)
                        TextField(model.config.appSlug.isEmpty ? "shipwatch-app" : model.config.appSlug, text: $prefs.appSlugOverride)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                .font(.system(size: 12.5))
            }
            .padding(.top, 8)
            .onSubmit { model.applyConfig() }
            .onChange(of: prefs.clientIDOverride) { model.applyConfig() }
        } label: {
            SectionLabel("GitHub App")
        }
        .padding(.leading, 4)
    }
}
