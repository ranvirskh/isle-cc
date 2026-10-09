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
        windows.filter { LimitFormat.isCurrent($0, now: now) && ($0.id == "five_hour" || $0.id == "seven_day") }
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
