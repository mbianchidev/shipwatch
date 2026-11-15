import ShipwatchCore
import SwiftUI

/// A group in the popover: summed issues and pull requests and the CI states of its members, without releases.
/// Expanding it lists the member rows.
struct GroupRowView: View {
    let model: AppModel
    let group: RepoGroup
    let members: [TrackedRepo]
    @State private var hovering = false

    private var statuses: [RepoStatus] { members.compactMap { model.status(for: $0) } }
    private var isExpanded: Bool { model.isExpanded(group) }
    /// A filter shows the matching members, so the group stays open until it's cleared.
    private var canToggle: Bool { model.filter == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 20)
                    .opacity(canToggle ? 1 : 0)
                CIIcon(glyph: CIGlyph(group: statuses, members: members.count), size: 16)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 6) {
                    titleLine
                    if statuses.isEmpty {
                        Text(model.isRefreshing || model.banner == nil ? "Loading…" : "Not loaded yet")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    } else if statuses.allSatisfy({ $0.problem != nil }) {
                        HStack(spacing: 6) {
                            Text("Shipwatch can't read these repositories.")
                                .foregroundStyle(.secondary)
                            Button("Grant access…") { model.open(model.manageAccessURL) }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.link)
                        }
                        .font(.system(size: 11.5))
                    } else {
                        CountsLine(model: model, statuses: statuses)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                guard canToggle else { return }
                withAnimation(.easeInOut(duration: 0.18)) { model.toggleGroup(group.id) }
            }
            .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") {
                guard canToggle else { return }
                model.toggleGroup(group.id)
            }
            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(members) { repo in
                        RepoRowView(model: model, repo: repo)
                    }
                }
                .padding(.leading, 14)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hovering && !isExpanded ? Theme.fill.opacity(0.7) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.fillStrong, lineWidth: isExpanded ? 1 : 0)
        )
        .onHover { hovering = $0 }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Group \(group.displayName)")
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(group.displayName)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
            Text(members.count.counted("repo"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            GroupCIBreakdown(statuses: statuses)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if canToggle {
            Button(isExpanded ? "Collapse" : "Expand") { model.toggleGroup(group.id) }
            Divider()
        }
        let refs = statuses.filter { $0.problem == nil }.map(\.ref)
        Button("Open Issues") { model.open(GitHubLinks.issues(refs)) }
            .disabled(refs.isEmpty)
        Button("Open Pull Requests") { model.open(GitHubLinks.pullRequests(refs)) }
            .disabled(refs.isEmpty)
        Divider()
        Button("Move Up") { model.move(group.entryID, by: -1) }
            .disabled(!model.canMove(group.entryID, by: -1))
        Button("Move Down") { model.move(group.entryID, by: 1) }
            .disabled(!model.canMove(group.entryID, by: 1))
        Divider()
        Button("Edit Group…") { model.showGroupEditor(.edit(group.id)) }
    }
}

/// "◌ 1 running  ✕ 2 failing", or "✓ all green" when every member with workflows passes.
struct GroupCIBreakdown: View {
    let statuses: [RepoStatus]

    var body: some View {
        let overall = OverallStatus(statuses)
        let unreadable = statuses.count { $0.problem != nil }
        let parts: [(glyph: CIGlyph, count: Int, label: String)] = [
            (.running, overall.running, "running"),
            (.queued, overall.queued, "queued"),
            (.failing, overall.failing, "failing"),
            (.notStarted, overall.notStarted, "config/billing"),
            (.noAccess, unreadable, "can't read"),
        ].filter { $0.count > 0 }
        if parts.isEmpty, overall.passing > 0 {
            item(.passing, text: "all green")
        } else if !parts.isEmpty {
            ViewThatFits(in: .horizontal) {
                row(parts, labeled: true)
                row(parts, labeled: false)
            }
        }
    }

    private func row(_ parts: [(glyph: CIGlyph, count: Int, label: String)], labeled: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(parts, id: \.label) { part in
                item(part.glyph, text: labeled ? "\(part.count) \(part.label)" : "\(part.count)")
                    .help("\(part.count) \(part.label)")
                    .accessibilityLabel("\(part.count) \(part.label)")
            }
        }
        .fixedSize()
    }

    private func item(_ glyph: CIGlyph, text: String) -> some View {
        HStack(spacing: 4) {
            CIIcon(glyph: glyph, size: 11)
            Text(text).fontWeight(.medium)
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6))
    }
}

extension CIGlyph {
    /// What needs attention first: failing, then config/billing, then running, then queued, then passing.
    init(group statuses: [RepoStatus], members: Int) {
        guard !statuses.isEmpty else {
            self = members == 0 ? .none : .loading
            return
        }
        let overall = OverallStatus(statuses)
        if overall.failing > 0 {
            self = .failing
        } else if overall.notStarted > 0 {
            self = .notStarted
        } else if overall.running > 0 {
            self = .running
        } else if overall.queued > 0 {
            self = .queued
        } else if overall.passing > 0 {
            self = .passing
        } else if statuses.allSatisfy({ $0.problem != nil }) {
            self = .noAccess
        } else {
            self = .none
        }
    }
}
