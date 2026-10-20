import Foundation

/// Which AI tool's 5-hour reading the collapsed notch shows. Claude's comes from Anthropic's usage endpoint; the other
/// agents (Codex and any other that reports plan limits) come from their own session logs. The tool used most recently wins.
public enum AIUsage {
    public struct Reading: Equatable {
        public var agent: AgentKind
        public var percent: Double
        public var resetsAt: Date?
        public init(agent: AgentKind, percent: Double, resetsAt: Date? = nil) { self.agent = agent; self.percent = percent; self.resetsAt = resetsAt }
    }

    /// The window that behaves like a 5-hour session: the shortest current one, at most 6 hours long.
    static func sessionWindow(_ windows: [LimitWindow], now: Date) -> LimitWindow? {
        windows.filter { LimitFormat.isCurrent($0, now: now) && ($0.windowMinutes ?? Int.max) <= 360 }
            .min { ($0.windowMinutes ?? Int.max) < ($1.windowMinutes ?? Int.max) }
    }

    /// The tool an app belongs to, for showing that tool's usage while its app is in front. Nil for apps that belong to none
    /// (terminals and editors host several tools, so the most recently used one decides there).
    public static func agent(forBundleID id: String?) -> AgentKind? {
        switch id {
        case "com.anthropic.claudefordesktop": return .claudeCode
        case "com.openai.codex", "com.openai.chat": return .codex
        default: return nil
        }
    }

    /// "850", "12.4k", "1.2M": a token count short enough for the notch.
    public static func compactTokens(_ n: Int) -> String {
        func trim(_ v: Double, _ unit: String) -> String {
            let s = String(format: "%.1f", v)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + unit
        }
        if n >= 1_000_000 { return trim(Double(n) / 1_000_000, "M") }
        if n >= 1_000 { return trim(Double(n) / 1_000, "k") }
        return "\(max(0, n))"
    }

    /// Apps whose own usage Isle cannot read (Gemini publishes no way to check it).
    public static let unreadableBundleIDs: Set<String> = ["com.google.GeminiMacOS"]

    public static func pill(claude: [LimitWindow], snapshots: [AgentSnapshot], frontmostBundleID: String? = nil, now: Date) -> Reading? {
        if let id = frontmostBundleID, unreadableBundleIDs.contains(id) { return nil }
        // Per app: only the Claude/Codex apps and terminals or editors that host those tools show a reading. In any other app
        // (a browser, Gemini) the notch stays at its normal size.
        if let id = frontmostBundleID {
            if agent(forBundleID: id) == nil, !UsageActivity.terminalBundleIDs.contains(id) { return nil }
        } else { return nil }
        let preferred = agent(forBundleID: frontmostBundleID)
        var best: (reading: Reading, activity: Date)?
        var all: [(reading: Reading, activity: Date)] = []
        func consider(_ r: Reading, _ activity: Date?) {
            let a = activity ?? .distantPast
            all.append((r, a))
            if best == nil || a > best!.activity { best = (r, a) }
        }
        if let w = claude.first(where: { $0.id == "five_hour" && LimitFormat.isCurrent($0, now: now) }) {
            let activity = snapshots.first { $0.agent == .claudeCode }?.lastActivity
            consider(Reading(agent: .claudeCode, percent: w.usedPercent, resetsAt: w.resetsAt), activity)
        }
        for s in snapshots where s.agent != .claudeCode {
            guard case .available(let windows) = s.limits, let w = sessionWindow(windows, now: now) else { continue }
            consider(Reading(agent: s.agent, percent: w.usedPercent, resetsAt: w.resetsAt), s.lastActivity)
        }
        // The app in front decides, when it belongs to one tool and that tool has a reading.
        if let preferred, let match = all.first(where: { $0.reading.agent == preferred }) { return match.reading }
        return best?.reading
    }
}
