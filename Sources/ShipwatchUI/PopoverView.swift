import ShipwatchCore
import SwiftUI

/// Root of the menu bar popover: onboarding until signed in, then the dashboard.
public struct PopoverView: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.showsOnboarding {
                OnboardingView(model: model)
            } else {
                DashboardView(model: model)
            }
        }
        .frame(width: 430)
    }
}

struct DashboardView: View {
    let model: AppModel
    @State private var listHeight: CGFloat = 0

    private var repos: [TrackedRepo] { model.menuRepos }

    /// Grow with the list, but leave room for the header, footer and menu bar on the current screen.
    private var maxListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, min(screen - 260, 760))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner = model.banner {
                BannerView(banner: banner, lastUpdated: model.lastUpdated) { model.requestRefresh(force: true) }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            Divider()
            if model.prefs.repos.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(repos) { repo in
                            RepoRowView(model: model, repo: repo)
                        }
                    }
                    .padding(6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollIndicators(.automatic)
                .frame(height: min(max(listHeight, 60), maxListHeight))
                hiddenFooter
            }
            UpdateFooter(model: model)
            Divider()
            VStack(spacing: 0) {
                MenuRow(title: "Manage Repositories…", symbol: "list.bullet", shortcut: "⌘,") {
                    model.actions.showSettings(.repositories)
                }
                .keyboardShortcut(",", modifiers: .command)
                MenuRow(title: "Quit Shipwatch", symbol: "power", shortcut: "⌘Q") {
                    model.actions.quit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(6)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AppGlyph(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Shipwatch")
                        .font(.system(size: 14, weight: .semibold))
                    StatusLine(model: model)
                }
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh (⌘R)") {
                    model.requestRefresh(force: true)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRefreshing)
                IconButton(symbol: "gearshape", help: "Settings") {
                    model.actions.showSettings(.general)
                }
            }
            SummaryChips(overall: model.overall)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var hiddenFooter: some View {
        let hidden = model.prefs.repos.hiddenCount
        if hidden > 0 {
            HStack(spacing: 5) {
                Image(systemName: "eye.slash")
                Text("\(hidden.counted("hidden repository", "hidden repositories")) ·")
                Button(model.showHiddenInMenu ? "Hide" : "Show") {
                    model.showHiddenInMenu.toggle()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.link)
                Spacer()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("No repositories yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Pick the repositories Shipwatch should watch.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button { model.showAddRepositories() } label: {
                Text("Add Repositories…")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }
            .buttonStyle(AccentButtonStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// "✓ Updated 32 s ago · 5 repositories", ticking every second.
struct StatusLine: View {
    let model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                if model.isRefreshing {
                    ProgressView().controlSize(.mini)
                    Text("Refreshing…")
                } else if let updated = model.lastUpdated {
                    Image(systemName: model.banner == nil ? "checkmark" : "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Updated \(RelativeTime.updated(updated, now: context.date)) · \(model.prefs.repos.visible.count.counted("repository", "repositories"))")
                } else {
                    Text("Not updated yet")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

struct SummaryChips: View {
    let overall: OverallStatus

    var body: some View {
        let chips: [(CIGlyph, Int, String)] = [
            (.running, overall.running, "running"),
            (.failing, overall.failing, "failing"),
            (.passing, overall.passing, "passing"),
        ].filter { $0.1 > 0 }
        if !chips.isEmpty {
            HStack(spacing: 6) {
                ForEach(chips, id: \.2) { glyph, count, label in
                    HStack(spacing: 5) {
                        CIIcon(glyph: glyph, size: 11)
                        Text("\(count)").fontWeight(.semibold)
                        Text(label).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.fill, in: Capsule())
                }
            }
        }
    }
}

struct BannerView: View {
    let banner: Banner
    let lastUpdated: Date?
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if case .rateLimited = banner {
                EmptyView()
            } else {
                Button("Retry", action: retry)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.link)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
    }

    private var symbol: String {
        switch banner {
        case .rateLimited: "hourglass"
        case .offline: "wifi.slash"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch banner {
        case .rateLimited, .offline: Theme.warning
        case .error: Theme.failing
        }
    }

    private var message: String {
        let cached = lastUpdated.map { " Showing data from \(RelativeTime.ago($0))." } ?? ""
        switch banner {
        case .rateLimited(let until):
            return "GitHub rate limit reached. Retrying at \(until.formatted(date: .omitted, time: .shortened)).\(cached)"
        case .offline:
            return "Can't reach GitHub.\(cached)"
        case .error(let text):
            return text
        }
    }
}

/// One-line notice above the menu rows while an update is available, installing, or failed.
struct UpdateFooter: View {
    let model: AppModel

    var body: some View {
        let updater = model.updater
        if updater.isInstalling, let release = updater.availableRelease {
            row(symbol: nil) {
                Text("Installing Shipwatch \(release.version.description)…")
            }
        } else if updater.hasFailed || (updater.pause.message != nil && updater.availableRelease != nil) {
            row(symbol: "exclamationmark.triangle") {
                Text("Shipwatch update failed ·")
                Button("Details") { model.actions.showSettings(.general) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.link)
                    .accessibilityLabel("Show update details in Settings")
            }
        } else if let release = updater.availableRelease, !updater.isBusy {
            row(symbol: "arrow.down.circle") {
                Text("Shipwatch \(release.version.description) is available ·")
                Button("Install") { updater.install() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.link)
                    .accessibilityLabel("Install Shipwatch \(release.version.description) and restart")
            }
        }
    }

    private func row(symbol: String?, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.mini)
            }
            content()
            Spacer()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Menu-like row at the bottom of the popover.
struct MenuRow: View {
    let title: String
    let symbol: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
                Text(shortcut)
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(HoverButtonStyle(cornerRadius: 5))
    }
}
