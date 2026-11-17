import ShipwatchCore
import SwiftUI

/// Expanded part of a row: this week's lines of code on the local default branch and the change since last week's count.
struct LinesPanel: View {
    let report: LineCountReport?
    let failure: LineCountFailure?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Lines of code")
                Spacer(minLength: 6)
                if let latest = report?.latest {
                    Text("\(latest.branch) · \(latest.commit.prefix(7))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Counted on the local \(latest.branch) branch at \(latest.commit)")
                }
            }
            if let report {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
                    row("Code", \.code, in: report)
                    row("Tests", \.tests, in: report)
                    row("Total", \.total, in: report, emphasized: true)
                    Divider()
                    row("Markdown", \.markdown, in: report)
                }
                .font(.system(size: 12))
                .monospacedDigit()
                Self.footer(report)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Text("Couldn't count lines: \(failure.message)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 9))
    }

    private func row(_ title: String, _ kind: KeyPath<LineCounts, Int>, in report: LineCountReport, emphasized: Bool = false) -> some View {
        let growth = report.growth(kind)
        return GridRow {
            Text(title)
                .foregroundStyle(emphasized ? .primary : .secondary)
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(report.latest.counts[keyPath: kind], format: .number)
                .fontWeight(emphasized ? .semibold : .regular)
            Group {
                if let growth {
                    Text(growth.lines, format: .number.sign(strategy: .always(includingZero: false)))
                    Self.percent(growth)
                } else {
                    Text(verbatim: "")
                    Text(verbatim: "")
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Two decimals like `+1.94%`; `new` when last week's count was 0.
    private static func percent(_ growth: LineGrowth) -> Text {
        guard let percent = growth.percent else { return growth.lines == 0 ? Text(0.0, format: .percent.precision(.fractionLength(2))) : Text("new") }
        return Text(percent / 100, format: .percent.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)))
    }

    private static let day = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)

    private static func footer(_ report: LineCountReport) -> Text {
        guard let previous = report.previous else {
            return Text("Counted \(report.latest.date, format: day). The change shows after next week's count.")
        }
        return Text("Counted \(report.latest.date, format: day), change since \(previous.date, format: day).")
    }
}
