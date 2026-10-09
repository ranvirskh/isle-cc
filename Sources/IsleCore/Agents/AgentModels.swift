import Foundation

// The agents feature reads METADATA ONLY from local session logs: timestamps, model names, token counts,
// the project folder name and the session id. No type in this file can hold prompt text, responses,
// file contents or tool output, and nothing here touches the network.

public enum AgentKind: String, Codable, CaseIterable, Identifiable {
    case claudeCode, codex, openCode, copilot

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .copilot: return "GitHub Copilot"
        }
    }

    public var symbol: String {
        switch self {
        case .claudeCode: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .openCode: return "terminal"
        case .copilot: return "airplane"
        }
    }

    /// Agents whose logs mark the end of a task explicitly. The others are judged by going quiet.
    public var hasExplicitTurnEnd: Bool {
        switch self {
        case .claudeCode, .codex: return true
        case .openCode, .copilot: return false
        }
    }
}

public struct TokenTotals: Codable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var reasoning: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, reasoning: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    public static let zero = TokenTotals()

    /// Fresh input plus output: the headline number.
    public var inOut: Int { input + output }
    public var cached: Int { cacheRead + cacheWrite }
    public var isZero: Bool { input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 && reasoning == 0 }

    public static func + (a: TokenTotals, b: TokenTotals) -> TokenTotals {
        TokenTotals(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                    cacheWrite: a.cacheWrite + b.cacheWrite, reasoning: a.reasoning + b.reasoning)
    }

    /// Field-wise difference, never negative.
    public func delta(from old: TokenTotals) -> TokenTotals {
        TokenTotals(input: max(0, input - old.input), output: max(0, output - old.output),
                    cacheRead: max(0, cacheRead - old.cacheRead), cacheWrite: max(0, cacheWrite - old.cacheWrite),
                    reasoning: max(0, reasoning - old.reasoning))
    }
}

public struct UsageEvent: Equatable {
    public var agent: AgentKind
    public var timestamp: Date
    public var model: String
    public var tokens: TokenTotals
    public var sessionID: String
    public var project: String?
    /// When set, a later event with the same key replaces this one instead of adding to it.
    public var replaceKey: String?
}

public enum TurnSignal: Equatable {
    /// A task started or is clearly in progress.
    case opened
    /// The agent finished its task.
    case closed
    /// The task was interrupted; closes without a completion notice.
    case aborted
    /// Something was written, without saying whether a task is open.
    case activity
}

public struct ActivityEvent: Equatable {
    public var agent: AgentKind
    public var timestamp: Date
    public var sessionID: String
    public var project: String?
    public var signal: TurnSignal
}

/// One plan-limit window as reported by the agent's own provider. Never derived from token counts.
public struct LimitWindow: Codable, Equatable, Identifiable {
    /// Stable id within an agent, e.g. "primary", "five_hour".
    public var id: String
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var resetsAt: Date?
    /// When the provider reported this value.
    public var observedAt: Date
    /// Where the number came from, shown in the UI and the report.
    public var source: String

    public init(id: String, usedPercent: Double, windowMinutes: Int?, resetsAt: Date?, observedAt: Date, source: String) {
        self.id = id
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.source = source
    }
}

public enum ParsedRecord: Equatable {
    case usage(UsageEvent)
    case activity(ActivityEvent)
    case limits([LimitWindow], plan: String?)
}

/// Per-file parser memory. Persisted with the byte offset so a relaunch can resume mid-file. Metadata only.
public struct FileContext: Codable, Equatable {
    public var model: String?
    public var project: String?
    public var sessionID: String?
    /// Recent message ids with the usage already counted for them, to de-duplicate repeated records.
    public var recentIDs: [String] = []
    public var recentTotals: [TokenTotals] = []
    /// Highest cumulative token count seen (Codex), to skip repeated token_count events.
    public var counter: Int = 0

    public init() {}

    mutating func remember(id: String, totals: TokenTotals) {
        if let i = recentIDs.firstIndex(of: id) {
            recentTotals[i] = totals
            return
        }
        recentIDs.append(id)
        recentTotals.append(totals)
        if recentIDs.count > 24 {
            recentIDs.removeFirst(recentIDs.count - 24)
            recentTotals.removeFirst(recentTotals.count - 24)
        }
    }

    func totals(forID id: String) -> TokenTotals? {
        recentIDs.firstIndex(of: id).map { recentTotals[$0] }
    }
}

public enum AgentLiveState: String, Equatable {
    case working, waiting, idle
}

public struct ModelUsage: Equatable, Identifiable {
    public var model: String
    public var tokens: TokenTotals
    public var id: String { model }
}

public enum LimitAvailability: Equatable {
    case available([LimitWindow])
    case unavailable

    public static let unavailableText = "Limit data not available"
}

public struct AgentSnapshot: Equatable, Identifiable {
    public var agent: AgentKind
    public var state: AgentLiveState
    public var project: String?
    public var sessionsToday: Int
    public var today: [ModelUsage]
    public var week: [ModelUsage]
    public var limits: LimitAvailability
    public var plan: String?
    public var lastActivity: Date?
    public var id: String { agent.rawValue }

    public var todayTotal: TokenTotals { today.reduce(.zero) { $0 + $1.tokens } }
    public var weekTotal: TokenTotals { week.reduce(.zero) { $0 + $1.tokens } }
}

public struct CompletionNotice: Equatable {
    public var agent: AgentKind
    public var sessionID: String
    public var project: String?
    public var startedAt: Date
    public var endedAt: Date
    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    /// Unique per task, so a notice can never be shown twice.
    public var id: String { "\(agent.rawValue)|\(sessionID)|\(Int(startedAt.timeIntervalSince1970))" }
}

// MARK: - Presentation helpers

public enum LimitSeverity: Equatable {
    case calm, warning, critical

    public init(usedPercent: Double) {
        if usedPercent >= 85 { self = .critical } else if usedPercent >= 60 { self = .warning } else { self = .calm }
    }
}

public enum LimitFormat {
    public static func windowName(_ w: LimitWindow) -> String {
        switch w.id {
        case "spend_limit": return "Spend limit"
        default: break
        }
        guard let minutes = w.windowMinutes, minutes > 0 else {
            return w.id.replacingOccurrences(of: "_", with: " ").capitalized
        }
        switch minutes {
        case 300: return "5-hour"
        case 1440: return "Daily"
        case 10080: return "Weekly"
        case 43200, 44640: return "Monthly"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
            if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
            return "\(minutes)-minute"
        }
    }

    /// "3d 4h", "2h 14m", "45m", "<1m". Nil when the reset time is unknown or already passed.
    public static func countdown(to reset: Date?, now: Date) -> String? {
        guard let reset, reset > now else { return nil }
        let seconds = Int(reset.timeIntervalSince(now))
        let days = seconds / 86400, hours = (seconds % 86400) / 3600, minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    /// A window whose reset time has passed no longer describes the current window; its percentage is not shown.
    public static func isCurrent(_ w: LimitWindow, now: Date) -> Bool {
        guard let reset = w.resetsAt else { return true }
        return reset > now
    }

    /// Highest percentage across windows that are still current. Used by the header chip.
    public static func highestPercent(_ snapshots: [AgentSnapshot], now: Date) -> Double? {
        var best: Double?
        for snapshot in snapshots {
            guard case .available(let windows) = snapshot.limits else { continue }
            for w in windows where isCurrent(w, now: now) {
                best = max(best ?? 0, w.usedPercent)
            }
        }
        return best
    }

    public static func tokens(_ n: Int) -> String {
        let value = Double(n)
        if n >= 1_000_000_000 { return String(format: "%.1fB", value / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", value / 1e6) }
        if n >= 10_000 { return String(format: "%.0fK", value / 1e3) }
        if n >= 1_000 { return String(format: "%.1fK", value / 1e3) }
        return String(n)
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// Shortens model ids for the narrow UI without changing which model they name.
    public static func modelName(_ raw: String) -> String {
        var name = raw
        if let range = name.range(of: #"-\d{8}$"#, options: .regularExpression) { name.removeSubrange(range) }
        return String(name.prefix(32))
    }
}

enum AgentDates {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    /// Accepts ISO 8601 strings (with or without fractional seconds) and epoch numbers in seconds or milliseconds.
    static func parse(_ v: Any?) -> Date? {
        if let s = v as? String {
            if let d = fractional.date(from: s) ?? plain.date(from: s) { return d }
            if let n = Double(s) { return fromEpoch(n) }
            return nil
        }
        if let n = Loose.double(v) { return fromEpoch(n) }
        return nil
    }

    static func fromEpoch(_ n: Double) -> Date? {
        guard n.isFinite, n > 0 else { return nil }
        // Anything past the year 33658 in seconds is really milliseconds.
        let seconds = n > 1e11 ? n / 1000 : n
        guard seconds > 946_684_800, seconds < 4_102_444_800 else { return nil } // 2000 ... 2100
        return Date(timeIntervalSince1970: seconds)
    }

    /// The folder name only; never the full path.
    static func projectName(fromPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : String(name.prefix(80))
    }
}
