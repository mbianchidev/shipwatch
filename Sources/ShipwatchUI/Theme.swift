import AppKit
import ShipwatchCore
import SwiftUI

enum Theme {
    static let running = Color(red: 0.98, green: 0.80, blue: 0.10)
    static let failing = Color(red: 1.00, green: 0.27, blue: 0.23)
    static let passing = Color(red: 0.20, green: 0.80, blue: 0.35)
    static let warning = Color(red: 1.00, green: 0.62, blue: 0.04)
    static let link = Color(nsColor: .linkColor)
    /// Switches and checkboxes while on: macOS system blue in dark mode.
    static let toggleOn = Color(red: 0.04, green: 0.52, blue: 1.00)
    static let fill = Color.primary.opacity(0.07)
    static let fillStrong = Color.primary.opacity(0.11)
    static let settingsChrome = Color(white: 0.17)
    static let settingsContent = Color(white: 0.12)
    static let settingsCard = Color(white: 0.09)

    static let runningNS = NSColor(red: 0.98, green: 0.80, blue: 0.10, alpha: 1)
}

/// What the CI icon shows for a repo or a run.
enum CIGlyph: Equatable {
    case loading, running, queued, passing, failing, notStarted, neutral, none, unreadable, noAccess

    init(repo status: RepoStatus?) {
        guard let status else {
            self = .loading
            return
        }
        if status.problem != nil {
            self = .noAccess
            return
        }
        guard let ci = status.ci else {
            self = .unreadable
            return
        }
        switch ci.state {
        case .running: self = .running
        case .queued: self = .queued
        case .failing: self = .failing
        case .notStarted: self = .notStarted
        case .passing: self = .passing
        case .none: self = .none
        }
    }

    init(run: WorkflowRun) {
        if run.isActive {
            self = run.isQueued ? .queued : .running
        } else if run.didNotStart {
            self = .notStarted
        } else if run.isFailure {
            self = .failing
        } else if run.conclusion == "success" {
            self = .passing
        } else {
            self = .neutral
        }
    }

    var help: String {
        switch self {
        case .loading: "Loading"
        case .running: "Workflow running"
        case .queued: "Workflow queued"
        case .passing: "Passing on the default branch"
        case .failing: "Failing on the default branch"
        case .notStarted: "Config/billing: jobs never started, check billing or the workflow file"
        case .neutral: "Cancelled or skipped"
        case .none: "No workflow runs"
        case .unreadable: "Shipwatch can't read Actions for this repository"
        case .noAccess: "Shipwatch can't read this repository"
        }
    }
}

struct CIIcon: View {
    let glyph: CIGlyph
    var size: CGFloat = 16

    var body: some View {
        Group {
            switch glyph {
            case .running:
                RunningIndicator(color: Theme.running)
            case .queued:
                Image(systemName: "circle.dotted").foregroundStyle(Theme.running)
            case .passing:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Theme.passing)
            case .failing:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white, Theme.failing)
            case .notStarted:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, Theme.warning)
            case .neutral, .none:
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            case .unreadable:
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
            case .noAccess:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            case .loading:
                Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: size, weight: .medium))
        .frame(width: size + 2, height: size + 2)
        .accessibilityLabel(glyph.help)
    }
}

/// A ring with a gap that spins around a dot: "in progress".
struct RunningIndicator: View {
    let color: Color
    @State private var spinning = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let line = max(1.5, side * 0.13)
            ZStack {
                Circle().stroke(color.opacity(0.25), lineWidth: line)
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                Circle().fill(color).frame(width: side * 0.32, height: side * 0.32)
            }
            .padding(line / 2 + side * 0.06)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
    }
}

/// The Shipwatch sailboat drawn from scratch (SF Symbols can't be used in app icons),
/// in a unit square with y pointing down. Shared by the app glyph, the menu bar icon and `AppIcon`.
enum Sailboat {
    static func path(in rect: CGRect) -> CGPath {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let path = CGMutablePath()
        // Mainsail, right of the mast.
        path.addLines(between: [point(0.53, 0.08), point(0.53, 0.64), point(0.88, 0.64)])
        path.closeSubpath()
        // Jib, left of the mast.
        path.addLines(between: [point(0.44, 0.24), point(0.44, 0.64), point(0.16, 0.64)])
        path.closeSubpath()
        // Mast.
        path.addRect(CGRect(origin: point(0.465, 0.06), size: CGSize(width: rect.width * 0.045, height: rect.height * 0.64)))
        // Hull.
        path.addLines(between: [point(0.06, 0.72), point(0.94, 0.72), point(0.78, 0.90), point(0.22, 0.90)])
        path.closeSubpath()
        return path
    }

    /// A template image for the status item, tinted by the menu bar.
    static func templateImage(side: CGFloat = 17) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(Sailboat.path(in: rect.insetBy(dx: 0.5, dy: 0.5)))
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Shipwatch"
        return image
    }
}

struct SailboatShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(Sailboat.path(in: rect))
    }
}

/// The app icon in miniature: a white sailboat on a blue rounded square.
struct AppGlyph: View {
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 0.16, green: 0.50, blue: 0.95), Color(red: 0.07, green: 0.26, blue: 0.62)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay {
                SailboatShape()
                    .fill(.white)
                    .padding(size * 0.2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Small uppercase section heading, as in "RUNNING NOW".
struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
    }
}

/// Branch or tag name in a tinted monospaced capsule.
struct RefTag: View {
    let name: String
    var maxLength = 22

    private var shown: String {
        name.count > maxLength ? String(name.prefix(maxLength - 1)) + "…" : name
    }

    var body: some View {
        Text(shown)
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .foregroundStyle(Theme.link)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.link.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
            .help(name)
    }
}

/// Plain button that highlights its background on hover.
struct HoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    var hoverFill: Color = Theme.fill

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, cornerRadius: cornerRadius, hoverFill: hoverFill)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let hoverFill: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(hovering || configuration.isPressed ? hoverFill : .clear)
                )
                .opacity(configuration.isPressed ? 0.75 : 1)
                .onHover { hovering = $0 }
        }
    }
}

/// A borderless icon button, as in the popover header.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

extension Int {
    func counted(_ singular: String, _ plural: String? = nil) -> String {
        "\(self) \(self == 1 ? singular : (plural ?? singular + "s"))"
    }
}

/// GitHub's pull request glyph, which SF Symbols has no close match for. Drawn in a unit square, y down.
struct PullRequestGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let radius = 0.13 * min(rect.width, rect.height)
        var path = Path()
        for center in [point(0.22, 0.16), point(0.22, 0.84), point(0.78, 0.84)] {
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        }
        path.move(to: point(0.22, 0.30))
        path.addLine(to: point(0.22, 0.70))
        path.move(to: point(0.78, 0.70))
        path.addLine(to: point(0.78, 0.38))
        path.addQuadCurve(to: point(0.58, 0.18), control: point(0.78, 0.18))
        path.addLine(to: point(0.44, 0.18))
        path.move(to: point(0.57, 0.05))
        path.addLine(to: point(0.44, 0.18))
        path.addLine(to: point(0.57, 0.31))
        return path
    }
}

/// A filled button that keeps its color when the popover's window isn't key, unlike `.borderedProminent`.
struct AccentButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var cornerRadius: CGFloat = 6
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(tint.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A switch that stays blue while on. AppKit's switch turns grey whenever its window isn't the active one, which for
/// a menu bar app's Settings window is most of the time. Draws only the switch, as with `.labelsHidden()`; the label
/// is still read by VoiceOver.
struct BlueSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let height: CGFloat = controlSize == .small || controlSize == .mini ? 18 : 22
        let width = height * 1.73
        return Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Theme.toggleOn : Color.white.opacity(0.2))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: width, height: height)
            .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .controlBaseline()
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

/// A checkbox that stays blue while ticked, for the same reason as `BlueSwitchStyle`. Draws only the box.
struct BlueCheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            RoundedRectangle(cornerRadius: 3.5)
                .fill(configuration.isOn ? Theme.toggleOn : Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 3.5)
                        .strokeBorder(configuration.isOn ? Color.clear : Color.white.opacity(0.35), lineWidth: 1)
                )
                .overlay {
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .controlBaseline()
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }
}

private extension View {
    /// A text baseline a little below the center, where a 13 pt label beside the control sits, so `Grid` rows aligned
    /// by first text baseline line the control up with its label, like AppKit's controls.
    func controlBaseline() -> some View {
        alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
            .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
    }
}

extension ToggleStyle where Self == BlueSwitchStyle {
    static var blueSwitch: BlueSwitchStyle { BlueSwitchStyle() }
}

extension ToggleStyle where Self == BlueCheckboxStyle {
    static var blueCheckbox: BlueCheckboxStyle { BlueCheckboxStyle() }
}
