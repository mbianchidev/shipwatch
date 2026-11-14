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
            .background(Theme.settingsCard, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
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
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                label("Refresh every:")
                Picker("Refresh every", selection: Binding(get: { prefs.refreshMinutes }, set: { model.setRefreshMinutes($0) })) {
                    ForEach(Preferences.refreshChoices, id: \.self) { minutes in
                        Text(minutes.counted("minute")).tag(minutes)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            caption("Refreshes faster (every 20 s) while a workflow is running.")

            GridRow {
                label("Last activity means:")
                Picker("Last activity means", selection: $prefs.activityMode) {
                    ForEach(ActivityMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.top, 8)
            caption("Last push, or any update (issues, PRs, comments).")

            GridRow {
                label("Include pre-releases:")
                Toggle("Include pre-releases", isOn: Binding(get: { prefs.includePrereleases }, set: { model.setIncludePrereleases($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.top, 8)

            GridRow {
                label("Show failing count in menu bar:")
                Toggle("Show failing count in menu bar", isOn: $prefs.showFailingCount)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.top, 4)

            GridRow {
                label("Launch at login:")
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!LoginItem.isAvailable)
            }
            .padding(.top, 4)
            if !LoginItem.isAvailable {
                caption("Available when Shipwatch runs from its app bundle.")
            } else if let error = model.launchAtLoginError {
                caption(error, color: Theme.failing)
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .gridColumnAlignment(.trailing)
    }

    private func caption(_ text: String, color: Color = .secondary) -> some View {
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Account

struct AccountSettingsView: View {
    let model: AppModel
    @State private var showsAppConfig = false

    private let permissionRows: [(symbol: String, title: String, keys: [String])] = [
        ("play.circle", "Actions", ["actions"]),
        ("tag", "Contents (releases)", ["contents"]),
        ("smallcircle.filled.circle", "Issues · Pull requests · Metadata", ["issues", "pull_requests", "metadata"]),
    ]

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
