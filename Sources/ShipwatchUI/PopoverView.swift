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

    private var entries: [RepoListEntry] { model.menuEntries }

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
                        ForEach(entries) { entry in
                            switch entry {
                            case .repo(let repo):
                                RepoRowView(model: model, repo: repo)
                            case .group(let group, let members):
                                GroupRowView(model: model, group: group, members: members)
                            }
                        }
                        if entries.isEmpty, model.filter != nil {
                            filterEmptyNote
                        }
                    }
                    .padding(6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollIndicators(.automatic)
                .frame(height: min(max(listHeight, 60), maxListHeight))
                hiddenFooter
                workspaceNote
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
            if !model.prefs.repos.items.isEmpty {
                HStack(spacing: 6) {
                    SummaryChips(model: model)
                    Spacer(minLength: 0)
                    SortMenu(model: model)
                }
            }
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

    /// Says when a local clone was skipped or failed, so nothing fails silently.
    @ViewBuilder
    private var workspaceNote: some View {
        let count = model.workspace.attentionCount
        if count > 0 {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                Text("\(count.counted("local clone")) skipped ·")
                Button("Review") { model.actions.showSettings(.workspace) }
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

    /// A refresh can empty the filtered list, for example when the last running workflow finishes.
    private var filterEmptyNote: some View {
        HStack(spacing: 5) {
            Text("No repositories match this filter ·")
            Button("Show All") { model.filter = nil }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.link)
            Spacer()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
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

/// Counts per CI state and of repositories with Dependabot pull requests. Clicking one lists only those
/// repositories; clicking it again lists all. Labels drop to just icons and numbers when they don't fit.
struct SummaryChips: View {
    let model: AppModel

    private struct Chip {
        var filter: RepoFilter
        var count: Int
        var label: String
    }

    var body: some View {
        let overall = model.overall
        let chips = [
            Chip(filter: .ci(.running), count: overall.running, label: "running"),
            Chip(filter: .ci(.failing), count: overall.failing, label: "failing"),
            Chip(filter: .ci(.notStarted), count: overall.notStarted, label: "config/billing"),
            Chip(filter: .ci(.passing), count: overall.passing, label: "passing"),
            Chip(filter: .dependabot, count: model.dependabotCount, label: "dependabot"),
        ].filter { $0.count > 0 || $0.filter == model.filter }
        if !chips.isEmpty {
            ViewThatFits(in: .horizontal) {
                row(chips, labeled: true)
                row(chips, labeled: false)
            }
        }
    }

    private func row(_ chips: [Chip], labeled: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(chips, id: \.label) { chip in
                chipButton(chip, labeled: labeled, selected: model.filter == chip.filter)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func icon(_ filter: RepoFilter) -> some View {
        switch filter {
        case .ci(.running): CIIcon(glyph: .running, size: 11)
        case .ci(.failing): CIIcon(glyph: .failing, size: 11)
        case .ci(.notStarted): CIIcon(glyph: .notStarted, size: 11)
        case .ci: CIIcon(glyph: .passing, size: 11)
        case .dependabot:
            Image(systemName: "shippingbox")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.link)
                .frame(width: 13, height: 13)
        }
    }

    private func chipButton(_ chip: Chip, labeled: Bool, selected: Bool) -> some View {
        Button { model.toggleFilter(chip.filter) } label: {
            HStack(spacing: 5) {
                icon(chip.filter)
                Text("\(chip.count)").fontWeight(.semibold)
                if labeled {
                    Text(chip.label).foregroundStyle(selected ? .primary : .secondary)
                }
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(selected ? Theme.link.opacity(0.2) : Theme.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.link.opacity(selected ? 0.8 : 0), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(selected ? "Show all repositories" : "Show only \(chip.label) repositories")
        .accessibilityLabel("\(chip.count) \(chip.label)")
        .accessibilityHint(selected ? "Shows all repositories" : "Shows only \(chip.label) repositories")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Picks the list order: the custom one from Settings, by name, or most recent activity first.
struct SortMenu: View {
    let model: AppModel

    var body: some View {
        let sort = model.prefs.menuSort
        Menu {
            Picker("Sort By", selection: Binding(get: { model.prefs.menuSort }, set: { model.prefs.menuSort = $0 })) {
                ForEach(RepoSort.allCases, id: \.self) { option in
                    Text(option == .activity ? "\(option.label) (\(model.prefs.activityMode.label))" : option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(sort == .custom ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.link))
                .frame(width: 26, height: 20)
                .background(sort == .custom ? Theme.fill : Theme.link.opacity(0.2), in: Capsule())
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort: \(sort.label)")
        .accessibilityLabel("Sort repositories")
        .accessibilityValue(sort.label)
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
        } else if updater.hasFailed || updater.availableRelease.flatMap({ updater.pause.message(offering: $0.version) }) != nil {
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
