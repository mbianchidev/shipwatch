import ShipwatchCore
import SwiftUI

struct RepoRowView: View {
    let model: AppModel
    let repo: TrackedRepo
    @State private var hovering = false

    private var status: RepoStatus? { model.status(for: repo) }
    private var isExpanded: Bool { model.expanded.contains(repo.id) }
    private var canExpand: Bool { status?.ci != nil && status?.problem == nil }
    private var isPendingRemoval: Bool { model.pendingRemoval == repo.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 20)
                    .opacity(canExpand ? 1 : 0)
                ciButton
                VStack(alignment: .leading, spacing: 6) {
                    titleLine
                    detailLine
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                guard canExpand else { return }
                withAnimation(.easeInOut(duration: 0.18)) { model.toggleExpanded(repo.id) }
            }
            if isExpanded, let ci = status?.ci {
                RunsPanel(model: model, ref: repo.ref, ci: ci, defaultBranch: status?.defaultBranch)
                    .padding(.leading, 48)
                    .padding(.trailing, 8)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isExpanded ? Theme.fill : (hovering ? Theme.fill.opacity(0.7) : .clear))
        )
        .opacity(repo.hidden ? 0.55 : 1)
        .onHover { hovering = $0 }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(repo.ref.fullName)
    }

    private var ciButton: some View {
        let glyph = CIGlyph(repo: status)
        return Button {
            if case .noAccess = glyph {
                model.open(model.manageAccessURL)
            } else if let run = status?.ci?.primaryRun {
                model.open(run.htmlUrl)
            } else {
                model.open(GitHubLinks.actions(repo.ref))
            }
        } label: {
            CIIcon(glyph: glyph, size: 16)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(glyph.help)
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button { model.open(status?.url ?? GitHubLinks.repo(repo.ref)) } label: {
                Text(repo.ref.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Open \(repo.ref.fullName) on GitHub")
            Text(repo.ref.owner)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if status?.isArchived == true {
                Badge(text: "archived")
            }
            if repo.hidden {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Hidden from the menu")
            }
            Spacer(minLength: 6)
            releaseView
        }
    }

    @ViewBuilder
    private var releaseView: some View {
        if let status, status.problem == nil {
            if let release = status.latestRelease {
                Button { model.open(release.url) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "tag")
                            .font(.system(size: 10))
                        Text(release.tagName)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                        if release.isPrerelease {
                            Badge(text: "pre")
                        }
                        if let published = release.publishedAt {
                            Text(RelativeTime.short(published))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Open release \(release.tagName)")
            } else {
                Text("No releases")
                    .font(.system(size: 11.5))
                    .italic()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        if isPendingRemoval {
            RemovalConfirmation(name: repo.ref.name) {
                model.pendingRemoval = nil
            } remove: {
                withAnimation { model.removeRepository(repo.id) }
            }
        } else if let status {
            switch status.problem {
            case .noAccess:
                HStack(spacing: 6) {
                    Text("Shipwatch can't read this repository.")
                        .foregroundStyle(.secondary)
                    Button("Grant access…") { model.open(model.manageAccessURL) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.link)
                }
                .font(.system(size: 11.5))
            case .error(let message):
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            case nil:
                CountsLine(model: model, status: status)
            }
        } else {
            Text(model.isRefreshing || model.banner == nil ? "Loading…" : "Not loaded yet")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        let ref = repo.ref
        Button("Open Repository") { model.open(GitHubLinks.repo(ref)) }
        Button("Open Actions") { model.open(GitHubLinks.actions(ref)) }
        Button("Open Releases") { model.open(GitHubLinks.releases(ref)) }
        if let tag = status?.latestRelease?.tagName {
            Button("Copy Latest Tag (\(tag))") { model.copyToPasteboard(tag) }
        }
        let clones = model.workspace.clones(of: ref)
        if !clones.isEmpty {
            Divider()
            Button(clones.count == 1 ? "Update Local Clone Now" : "Update Local Clones Now") { model.syncClones(of: repo) }
                .disabled(!model.workspace.canSync || model.workspace.isOptedOut(ref))
            Button(clones.count == 1 ? "Show Local Clone in Finder" : "Show Local Clones in Finder") { model.revealClones(of: repo) }
        }
        Divider()
        Button("Move Up") { model.move(repo.id, by: -1) }
            .disabled(repo.hidden || model.prefs.repos.visible.first?.id == repo.id)
        Button("Move Down") { model.move(repo.id, by: 1) }
            .disabled(repo.hidden || model.prefs.repos.visible.last?.id == repo.id)
        Button(repo.hidden ? "Show “\(ref.name)”" : "Hide “\(ref.name)”") {
            model.setHidden(repo.id, !repo.hidden)
        }
        Divider()
        Button("Remove from Shipwatch…", role: .destructive) {
            model.pendingRemoval = repo.id
        }
    }
}

/// "⊙ 4 issues  [⇅ 11 PRs | ⧉ 5 dependabot]      ◷ 4m ago"
struct CountsLine: View {
    let model: AppModel
    let status: RepoStatus

    var body: some View {
        HStack(spacing: 10) {
            Button { model.open(GitHubLinks.issues(status.ref)) } label: {
                Counter(count: status.openIssues, label: status.openIssues == 1 ? "issue" : "issues") {
                    Image(systemName: "smallcircle.filled.circle")
                }
                    .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .help("Open issues")

            HStack(spacing: 0) {
                Button { model.open(GitHubLinks.pullRequests(status.ref)) } label: {
                    Counter(count: status.openPullRequests, label: status.openPullRequests == 1 ? "PR" : "PRs") {
                        PullRequestGlyph()
                            .stroke(style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
                            .frame(width: 10.5, height: 10.5)
                    }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .help("Open pull requests")
                if status.dependabotPullRequests > 0 {
                    Divider().frame(height: 14)
                    Button { model.open(GitHubLinks.dependabotPullRequests(status.ref)) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "shippingbox")
                            Text("\(status.dependabotPullRequests)").fontWeight(.semibold)
                            Text("dependabot")
                        }
                        .foregroundStyle(Theme.link)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .help("Open Dependabot pull requests")
                }
            }
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6))

            Spacer(minLength: 4)

            if let activity = status.lastActivity(model.prefs.activityMode) {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(RelativeTime.ago(activity))
                }
                .foregroundStyle(.secondary)
                .help("\(model.prefs.activityMode.label): \(activity.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
    }
}

struct Counter<Icon: View>: View {
    let count: Int
    let label: String
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 4) {
            icon
                .foregroundStyle(.secondary)
            Text("\(count)").fontWeight(.semibold)
            Text(label).foregroundStyle(.secondary)
        }
        .opacity(count == 0 ? 0.6 : 1)
    }
}

struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.6), lineWidth: 0.5))
    }
}

struct RemovalConfirmation: View {
    let name: String
    let cancel: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Remove \(name) from Shipwatch? It stays on GitHub.")
                .font(.system(size: 11.5))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Cancel", action: cancel)
                .controlSize(.small)
            Button(role: .destructive, action: remove) {
                Text("Remove")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
            .buttonStyle(AccentButtonStyle(tint: Theme.failing, cornerRadius: 5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.failing.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Expanded part of a row: running runs, then the latest result per workflow on the default branch.
struct RunsPanel: View {
    let model: AppModel
    let ref: RepoRef
    let ci: CISummary
    let defaultBranch: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !ci.running.isEmpty {
                SectionLabel("Running now")
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                ForEach(ci.running.prefix(6)) { run in
                    RunRow(model: model, run: run)
                }
            }
            if !ci.latestOnDefault.isEmpty {
                SectionLabel("Latest on \(defaultBranch ?? "default branch")")
                    .padding(.horizontal, 8)
                    .padding(.top, ci.running.isEmpty ? 4 : 8)
                ForEach(ci.latestOnDefault.prefix(8)) { run in
                    RunRow(model: model, run: run)
                }
            }
            if ci.running.isEmpty && ci.latestOnDefault.isEmpty {
                Text("No workflow runs yet.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            Button { model.open(GitHubLinks.actions(ref)) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.square")
                    Text("All workflow runs")
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.link)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct RunRow: View {
    let model: AppModel
    let run: WorkflowRun

    var body: some View {
        Button { model.open(run.htmlUrl) } label: {
            HStack(spacing: 8) {
                CIIcon(glyph: CIGlyph(run: run), size: 12)
                Text(run.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if let branch = run.headBranch {
                    RefTag(name: branch)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(detail(now: context.date))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .buttonStyle(HoverButtonStyle(cornerRadius: 6, hoverFill: Theme.fillStrong))
        .help("Open run #\(run.runNumber)")
    }

    private func detail(now: Date) -> String {
        if run.isQueued { return "queued" }
        if run.isActive {
            let started = run.runStartedAt ?? run.createdAt
            return "#\(run.runNumber) · \(RelativeTime.duration(now.timeIntervalSince(started)))"
        }
        return RelativeTime.ago(run.updatedAt, now: now)
    }
}
