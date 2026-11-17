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
                        if model.showsActiveJobs {
                            ActiveJobsSection(model: model)
                        }
                        ForEach(entries) { entry in
                            switch entry {
                            case .repo(let repo):
                                RepoRowView(model: model, repo: repo)
                            case .group(let group, let members):
                                GroupRowView(model: model, group: group, members: members)
                            }
                        }
                        if entries.isEmpty, model.isMenuFiltered {
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
                    ResetFiltersButton(model: model)
                    OwnerMenu(model: model)
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
            Button("Show All") { model.resetFilters() }
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

/// Counts per CI state and of repositories with Dependabot pull requests or, when turned on, security alerts.
/// Clicking one lists only those repositories, also after the popover reopens; clicking it again lists all. Labels
/// drop to just icons and numbers when they don't fit.
struct SummaryChips: View {
    let model: AppModel

    private struct Chip {
        var filter: RepoFilter
        var count: Int
        var label: String
        var subject: String? = nil

        var repositories: String { subject ?? "\(label) repositories" }
    }

    var body: some View {
        let overall = model.menuOverall
        let chips = [
            Chip(filter: .ci(.running), count: overall.running, label: "running"),
            Chip(filter: .ci(.queued), count: overall.queued, label: "queued"),
            Chip(filter: .ci(.failing), count: overall.failing, label: "failing"),
            Chip(filter: .ci(.notStarted), count: overall.notStarted, label: "config/billing"),
            Chip(filter: .ci(.passing), count: overall.passing, label: "passing"),
            Chip(filter: .dependabot, count: model.visibleCount(.dependabot), label: "dependabot"),
            Chip(
                filter: .reviewRequests, count: model.visibleCount(.reviewRequests), label: "to review",
                subject: "repositories with pull requests waiting for your review"
            ),
            Chip(
                filter: .securityAlerts, count: model.visibleCount(.securityAlerts), label: "with alerts",
                subject: "repositories with security alerts"
            ),
        ].filter { $0.count > 0 || $0.filter == model.filter }
        if !chips.isEmpty {
            ViewThatFits(in: .horizontal) {
                row(chips, labeled: true)
                row(chips, labeled: false)
                // With many kinds of chips even the icons may not fit; scrolling beats pushing the popover wider.
                ScrollView(.horizontal, showsIndicators: false) {
                    row(chips, labeled: false)
                }
            }
        }
    }

    private func row(_ chips: [Chip], labeled: Bool) -> some View {
        HStack(spacing: labeled ? 6 : 4) {
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
        case .ci(.queued): CIIcon(glyph: .queued, size: 11)
        case .ci(.failing): CIIcon(glyph: .failing, size: 11)
        case .ci(.notStarted): CIIcon(glyph: .notStarted, size: 11)
        case .ci: CIIcon(glyph: .passing, size: 11)
        case .dependabot:
            Image(systemName: "shippingbox")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.link)
                .frame(width: 13, height: 13)
        case .reviewRequests:
            Image(systemName: "person.badge.clock")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.link)
                .frame(width: 13, height: 13)
        case .securityAlerts:
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.failing)
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
            .padding(.horizontal, labeled ? 8 : 6)
            .padding(.vertical, 3)
            .background(selected ? Theme.link.opacity(0.2) : Theme.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.link.opacity(selected ? 0.8 : 0), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(selected ? "Show all repositories" : "Show only \(chip.repositories)")
        .accessibilityLabel("\(chip.count) \(chip.label)")
        .accessibilityHint(selected ? "Shows all repositories" : "Shows only \(chip.repositories)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Picks the list order: the custom one from Settings, by name, or most recent activity first. Opens an AppKit
/// menu: a SwiftUI `Menu` in the popover stops responding after its first pick until the popover reopens.
struct SortMenu: View {
    let model: AppModel
    @State private var anchor = ViewAnchor()

    var body: some View {
        let sort = model.prefs.menuSort
        Button(action: showMenu) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(sort == .custom ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.link))
                .frame(width: 26, height: 20)
                .background(sort == .custom ? Theme.fill : Theme.link.opacity(0.2), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(ViewAnchor.Reader(anchor: anchor))
        .fixedSize()
        .help("Sort: \(sort.label)")
        .accessibilityLabel("Sort repositories")
        .accessibilityValue(sort.label)
    }

    private func showMenu() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Sort By"))
        let actions = MenuActions()
        for option in RepoSort.allCases {
            let title = option == .activity ? "\(option.label) (\(model.prefs.activityMode.label))" : option.label
            let item = actions.item(title) { [model] in model.prefs.menuSort = option }
            item.state = option == model.prefs.menuSort ? .on : .off
            menu.addItem(item)
        }
        // Drops down from the button's bottom-left corner, like a pop-up button.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }
}

/// Turns off the summary chip and the organization, listing every repository again. Only there while either
/// narrows the list.
struct ResetFiltersButton: View {
    let model: AppModel

    var body: some View {
        if model.isMenuFiltered {
            Button { model.resetFilters() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 20)
                    .background(Theme.fill, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Reset Filters")
            .accessibilityLabel("Reset all filters")
            .accessibilityHint("Shows all repositories of every organization")
        }
    }
}

/// Narrows the list to the repositories of one organization or user, or shows all of them. Only there while the
/// shown repositories have more than one owner, or one is chosen. Opens an AppKit menu, like `SortMenu`.
struct OwnerMenu: View {
    let model: AppModel
    @State private var anchor = ViewAnchor()

    var body: some View {
        let owners = model.menuOwners
        let chosen = model.menuOwner.flatMap { key in owners.first { $0.id == key } }
        if owners.count > 1 || chosen != nil {
            Button(action: showMenu) {
                HStack(spacing: 4) {
                    Image(systemName: "building.2")
                        .font(.system(size: 10.5, weight: .semibold))
                    if let chosen {
                        Text(chosen.login)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 110)
                    }
                }
                .foregroundStyle(chosen == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.link))
                .padding(.horizontal, chosen == nil ? 0 : 8)
                .frame(minWidth: 26, minHeight: 20)
                .background(chosen == nil ? Theme.fill : Theme.link.opacity(0.2), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(ViewAnchor.Reader(anchor: anchor))
            .fixedSize()
            .help("Organization: \(chosen?.login ?? "All")")
            .accessibilityLabel("Filter by organization")
            .accessibilityValue(chosen?.login ?? "All organizations")
        }
    }

    private func showMenu() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let actions = MenuActions()
        let chosen = model.menuOwner
        let all = actions.item("All Organizations") { [model] in model.prefs.menuOwner = nil }
        all.state = chosen == nil ? .on : .off
        menu.addItem(all)
        menu.addItem(.separator())
        for owner in model.menuOwners {
            let item = actions.item("\(owner.login) (\(owner.count))") { [model] in model.prefs.menuOwner = owner.id }
            item.state = owner.id == chosen ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }
}

/// The AppKit view behind a SwiftUI control, to open an `NSMenu` from.
@MainActor
private final class ViewAnchor {
    weak var view: NSView?

    struct Reader: NSViewRepresentable {
        let anchor: ViewAnchor

        func makeNSView(context: Context) -> NSView {
            let view = PassthroughView()
            anchor.view = view
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            anchor.view = nsView
        }
    }

    /// Leaves clicks to the SwiftUI control in front of it.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Targets for menu items that run closures.
@MainActor
private final class MenuActions: NSObject {
    private var handlers: [@MainActor () -> Void] = []

    func item(_ title: String, handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        // `target` is weak; the item keeps its target alive for as long as the menu lives.
        item.representedObject = self
        item.tag = handlers.count
        handlers.append(handler)
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard handlers.indices.contains(sender.tag) else { return }
        handlers[sender.tag]()
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
