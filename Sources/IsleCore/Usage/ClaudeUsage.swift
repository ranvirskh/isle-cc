import Foundation

/// Claude plan usage as Anthropic reports it for the signed-in Claude Code account (the 5-hour session and the weekly limit).
/// Pure parsing only; the network call and the Keychain read live in the app target.
public enum ClaudeUsage {
    /// The OAuth access token inside the "Claude Code-credentials" Keychain item. Nothing else in that JSON is read.
    public static func accessToken(fromCredentials data: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = o["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    /// Windows in display order. Returns nil when the response is not the expected shape, so the last good reading stays.
    public static func parse(_ data: Data, now: Date) -> [LimitWindow]? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let entries: [(key: String, minutes: Int)] = [
            ("five_hour", 300), ("seven_day", 10080), ("seven_day_opus", 10080), ("seven_day_sonnet", 10080),
        ]
        var out: [LimitWindow] = []
        for e in entries {
            guard let w = o[e.key] as? [String: Any], let used = Loose.double(w["utilization"]), used >= 0 else { continue }
            out.append(LimitWindow(id: e.key, usedPercent: min(100, used), windowMinutes: e.minutes,
                                   resetsAt: (w["resets_at"] as? String).flatMap(date), observedAt: now,
                                   source: "Claude usage (Anthropic account)"))
        }
        return out.isEmpty ? nil : out
    }

    /// Highest percentage among windows that have not reset yet.
    public static func highest(_ windows: [LimitWindow], now: Date) -> Double? {
        windows.filter { LimitFormat.isCurrent($0, now: now) }.map(\.usedPercent).max()
    }

    /// The 5-hour limit is only shown once it is above this; the weekly limit is always shown.
    public static let fiveHourShowAbove: Double = 50

    /// Windows for the header chip and the notch: the weekly one, and the 5-hour one only when it is above 50%.
    /// `alwaysShowFiveHour` is true while something is actively using Claude (see `UsageActivity`): the 5-hour limit is then shown at any level.
    public static func displayed(_ windows: [LimitWindow], now: Date, alwaysShowFiveHour: Bool = false) -> [LimitWindow] {
        windows.filter { w in
            guard LimitFormat.isCurrent(w, now: now) else { return false }
            switch w.id {
            case "five_hour": return alwaysShowFiveHour || w.usedPercent > fiveHourShowAbove
            case "seven_day": return true
            default: return false
            }
        }
    }

    /// Shown on the left of the collapsed notch once the 5-hour window passes this.
    public static let alertThreshold: Double = 90

    public struct Alert: Equatable {
        public var percent: Double
        public var resetsAt: Date
        public init(percent: Double, resetsAt: Date) { self.percent = percent; self.resetsAt = resetsAt }
    }

    /// The 5-hour window when it is at or above the alert threshold and has not reset yet.
    public static func alert(_ windows: [LimitWindow], now: Date) -> Alert? {
        guard let w = windows.first(where: { $0.id == "five_hour" }), w.usedPercent >= alertThreshold,
              let reset = w.resetsAt, reset > now else { return nil }
        return Alert(percent: w.usedPercent, resetsAt: reset)
    }

    /// Time until a reset for the notch readout: decimal hours from one hour up ("5", "4.4", "1.5"), minutes under an hour ("45m").
    public static func hoursLeftLabel(until reset: Date, now: Date) -> String {
        let minutes = max(0, Int((reset.timeIntervalSince(now) / 60).rounded(.up)))
        guard minutes >= 60 else { return "\(minutes)m" }
        let tenths = Int((Double(minutes) / 6).rounded())   // hours in tenths
        return tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
    }

    /// When `hoursLeftLabel` changes between now and the reset: every minute in the last hour, otherwise every 6 minutes
    /// (a tenth of an hour). Lets the view redraw exactly then instead of on a fixed short timer.
    public static func labelChangeDates(until reset: Date, now: Date) -> [Date] {
        var out: [Date] = []
        var t = reset
        while t > now, out.count < 120 {
            out.append(t)
            t = t.addingTimeInterval(t.timeIntervalSince(now) > 3600 + 360 ? -360 : -60)
        }
        return [now] + out.reversed()
    }

    /// Short time until a weekly reset: "3d 4h" from a day up, otherwise the hour/minute label. Keeps the header chip narrow.
    public static func resetLabel(until reset: Date, now: Date) -> String {
        let seconds = reset.timeIntervalSince(now)
        guard seconds >= 86400 else { return timeLeftLabel(until: reset, now: now) }
        let days = Int(seconds / 86400), hours = Int((seconds.truncatingRemainder(dividingBy: 86400)) / 3600)
        return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    }

    /// Time until reset: whole hours (nearest) from one hour up, minutes below one hour. "2h", "45m", "<1m".
    public static func timeLeftLabel(until reset: Date, now: Date) -> String {
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "0m" }
        if seconds >= 3600 { return "\(Int((seconds / 3600).rounded()))h" }
        let minutes = Int((seconds / 60).rounded(.up))
        return "\(max(1, min(59, minutes)))m"
    }

    /// "5h 70% · wk 20%" for the header chip.
    public static func summary(_ windows: [LimitWindow], now: Date) -> String {
        displayed(windows, now: now)
            .map { "\($0.id == "five_hour" ? "5h" : "wk") \(Int($0.usedPercent.rounded()))%" }
            .joined(separator: " · ")
    }

    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
