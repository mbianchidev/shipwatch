import ShipwatchCore
import SwiftUI

/// Above the list while the running or queued chip is on: the running and queued jobs per owner and kind of runner,
/// macOS against GitHub's concurrency limit.
struct ActiveJobsSection: View {
    let model: AppModel

    var body: some View {
        let owners = model.ownerJobs
        let busy = owners.filter { !$0.jobs.isEmpty }
        let kinds = RunnerKind.allCases.filter { kind in kind == .macOS || busy.contains { !$0.jobs[kind].isEmpty } }
        let unread = owners.reduce(0) { $0 + $1.unread }
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Jobs per account")
            if !busy.isEmpty {
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Color.clear
                            .gridCellUnsizedAxes([.horizontal, .vertical])
                            .gridColumnAlignment(.leading)
                        ForEach(kinds, id: \.self) { kind in
                            Text(kind.label)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(busy) { owner in
                        GridRow(alignment: .firstTextBaseline) {
                            Text(owner.login)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(owner.login)
                            ForEach(kinds, id: \.self) { kind in
                                JobCell(kind: kind, tally: owner.jobs[kind], owner: owner.login)
                            }
                        }
                    }
                }
            } else if unread == 0 {
                Text("No jobs are running or queued.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if unread > 0 {
                if model.isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Counting jobs…")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                } else {
                    Text("The jobs of \(unread.counted("repository", "repositories")) couldn't be read.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Text("Only tracked repositories count. GitHub runs up to \(OwnerJobs.macOSLimit) macOS jobs at once per account on Free, Pro and Team plans.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 4)
    }
}

/// "3/5" running macOS jobs, or "7" for other runners, with the queued ones under it.
private struct JobCell: View {
    let kind: RunnerKind
    let tally: JobTally
    let owner: String

    private var atLimit: Bool { kind == .macOS && tally.running >= OwnerJobs.macOSLimit }

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(kind == .macOS ? "\(tally.running)/\(OwnerJobs.macOSLimit)" : "\(tally.running)")
                .font(.system(size: 12, weight: atLimit ? .semibold : .regular))
                .foregroundStyle(atLimit ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.primary))
                .opacity(tally.isEmpty ? 0.45 : 1)
            if tally.queued > 0 {
                Text("\(tally.queued) queued")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
        .help(description)
    }

    private var description: String {
        var text = "\(owner): \(tally.running) \(kind.label) " + (tally.running == 1 ? "job" : "jobs") + " running"
        if kind == .macOS { text += " of \(OwnerJobs.macOSLimit) at once" }
        if tally.queued > 0 { text += ", \(tally.queued) queued" }
        return text
    }
}
