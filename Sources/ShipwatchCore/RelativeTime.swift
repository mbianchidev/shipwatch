import Foundation

public enum RelativeTime {
    /// Compact age used in release pills and activity: `now`, `4m`, `6h`, `3d`, `2w`, `5mo`, `1y`.
    public static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minute = 60.0, hour = 3600.0, day = 86400.0
        switch seconds {
        case ..<minute: return "now"
        case ..<hour: return "\(Int(seconds / minute))m"
        case ..<day: return "\(Int(seconds / hour))h"
        case ..<(day * 14): return "\(Int(seconds / day))d"
        case ..<(day * 60): return "\(Int(seconds / (day * 7)))w"
        case ..<(day * 365): return "\(Int(seconds / (day * 30)))mo"
        default: return "\(Int(seconds / (day * 365)))y"
        }
    }

    /// `4m ago`, `just now`.
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let value = short(date, now: now)
        return value == "now" ? "just now" : "\(value) ago"
    }

    /// Header text: `32 s ago`, `9 min ago`, `2 h ago`.
    public static func updated(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3600) h ago"
    }

    /// Run durations: `48s`, `3m 12s`, `1h 4m`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    /// `14:32` style countdown.
    public static func countdown(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
