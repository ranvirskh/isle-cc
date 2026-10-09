import Foundation

/// Token totals bucketed by agent, local day and model. Holds counts only.
public struct UsageAggregator: Codable, Equatable {
    struct Replaced: Codable, Equatable {
        var bucket: String
        var tokens: TokenTotals
    }

    /// "agent|yyyy-MM-dd|model" -> totals
    private(set) var buckets: [String: TokenTotals] = [:]
    /// "agent|yyyy-MM-dd" -> session ids seen that day
    private(set) var sessions: [String: Set<String>] = [:]
    /// What was last counted for replaceable events (OpenCode message files).
    private(set) var replaced: [String: Replaced] = [:]

    public init() {}

    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public mutating func add(_ event: UsageEvent, calendar: Calendar = .current) {
        let day = Self.dayKey(event.timestamp, calendar: calendar)
        let bucket = [event.agent.rawValue, day, event.model].joined(separator: "|")
        if let key = event.replaceKey {
            if let old = replaced[key], let current = buckets[old.bucket] {
                let reduced = current.delta(from: old.tokens)
                buckets[old.bucket] = reduced.isZero ? nil : reduced
            }
            replaced[key] = Replaced(bucket: bucket, tokens: event.tokens)
        }
        buckets[bucket] = (buckets[bucket] ?? .zero) + event.tokens
        sessions[event.agent.rawValue + "|" + day, default: []].insert(event.sessionID)
    }

    public func usage(agent: AgentKind, days: Set<String>) -> [ModelUsage] {
        var byModel: [String: TokenTotals] = [:]
        for (key, totals) in buckets {
            let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[0] == agent.rawValue, days.contains(parts[1]) else { continue }
            byModel[parts[2]] = (byModel[parts[2]] ?? .zero) + totals
        }
        return byModel.map { ModelUsage(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens.inOut != $1.tokens.inOut ? $0.tokens.inOut > $1.tokens.inOut : $0.model < $1.model }
    }

    public func sessionCount(agent: AgentKind, day: String) -> Int {
        sessions[agent.rawValue + "|" + day]?.count ?? 0
    }

    public func hasAnyUsage(agent: AgentKind) -> Bool {
        buckets.keys.contains { $0.hasPrefix(agent.rawValue + "|") }
    }

    /// Drops everything older than `keepDays`.
    public mutating func prune(keepDays: Int, now: Date, calendar: Calendar = .current) {
        guard let cutoffDate = calendar.date(byAdding: .day, value: -keepDays, to: now) else { return }
        let cutoff = Self.dayKey(cutoffDate, calendar: calendar)
        func day(of key: String) -> String {
            let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
            return parts.count >= 2 ? parts[1] : ""
        }
        buckets = buckets.filter { day(of: $0.key) >= cutoff }
        sessions = sessions.filter { day(of: $0.key) >= cutoff }
        replaced = replaced.filter { day(of: $0.value.bucket) >= cutoff }
    }

    /// Days from the start of the calendar week through today.
    public static func weekDays(now: Date, calendar: Calendar) -> Set<String> {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return [dayKey(now, calendar: calendar)] }
        var days: Set<String> = []
        var d = week.start
        while d <= now {
            days.insert(dayKey(d, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return days
    }
}

/// Reads agent logs incrementally and turns them into snapshots. Not thread-safe: call from one serial queue.
/// This type performs no network access of any kind.
public final class AgentsEngine {
    public struct Roots: Equatable {
        public var claude: URL
        public var codex: URL
        public var openCode: URL
        public var copilot: URL
        /// Written by `Isle --statusline-bridge` when the user opted in to the Claude Code status line bridge.
        public var claudeLimitsFile: URL

        public init(claude: URL, codex: URL, openCode: URL, copilot: URL, claudeLimitsFile: URL) {
            self.claude = claude
            self.codex = codex
            self.openCode = openCode
            self.copilot = copilot
            self.claudeLimitsFile = claudeLimitsFile
        }

        public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser, support: URL) -> Roots {
            let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".local/share")
            return Roots(
                claude: home.appendingPathComponent(".claude/projects"),
                codex: home.appendingPathComponent(".codex/sessions"),
                openCode: dataHome.appendingPathComponent("opencode/storage/message"),
                copilot: home.appendingPathComponent(".copilot/session-state"),
                claudeLimitsFile: support.appendingPathComponent("Agents/claude-limits.json")
            )
        }

        public func root(for agent: AgentKind) -> URL {
            switch agent {
            case .claudeCode: return claude
            case .codex: return codex
            case .openCode: return openCode
            case .copilot: return copilot
            }
        }
    }

    /// Everything that is persisted between launches. Offsets, counts, limits: metadata only.
    struct State: Codable {
        /// Bumped when counting rules change, so old totals are rebuilt from the logs instead of kept.
        var version = 2
        var cursors: [String: FileCursor] = [:]
        /// OpenCode message files already counted: path -> modification time.
        var messageFiles: [String: Double] = [:]
        var usage = UsageAggregator()
        var limits: [String: [LimitWindow]] = [:]
        var plans: [String: String] = [:]
        var lastActivity: [String: Date] = [:]
        var projects: [String: String] = [:]
    }

    public let roots: Roots
    public let stateFile: URL?
    public var calendar: Calendar
    public var lookbackDays = 8
    public var keepDays = 15
    public var tracker: CompletionTracker
    /// Receives one-line diagnostics. Only counts and file names relative to an agent root ever go here.
    public var log: ((String) -> Void)?

    private var state = State()
    private let fileManager = FileManager.default
    private var dirty = false

    /// One spelling per file: symlinks resolved, so /var and /private/var (or a symlinked ~/.claude) compare equal.
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    public init(roots: Roots, stateFile: URL?, calendar: Calendar = .current, completionThreshold: TimeInterval = 120) {
        func canon(_ url: URL) -> URL { URL(fileURLWithPath: Self.canonical(url.path)) }
        self.roots = Roots(claude: canon(roots.claude), codex: canon(roots.codex), openCode: canon(roots.openCode),
                           copilot: canon(roots.copilot), claudeLimitsFile: canon(roots.claudeLimitsFile))
        self.stateFile = stateFile
        self.calendar = calendar
        self.tracker = CompletionTracker(threshold: completionThreshold)
        loadState()
    }

    // MARK: Persistence

    private func loadState() {
        guard let stateFile, let data = try? Data(contentsOf: stateFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let loaded = try? decoder.decode(State.self, from: data), loaded.version == 2 {
            state = loaded
        }
    }

    public func save() {
        guard dirty, let stateFile else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            try fileManager.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: stateFile, options: .atomic)
            dirty = false
        } catch {
            log?("agents: could not save state")
        }
    }

    /// Forgets everything learned so far (used by "reset" and by tests).
    public func reset() {
        state = State()
        tracker = CompletionTracker(threshold: tracker.threshold)
        dirty = true
    }

    // MARK: Detection

    public func isPresent(_ agent: AgentKind) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: roots.root(for: agent).path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Present AND used: the folder exists and at least one session left a trace.
    public func isUsed(_ agent: AgentKind) -> Bool {
        isPresent(agent) && (state.lastActivity[agent.rawValue] != nil || state.usage.hasAnyUsage(agent: agent))
    }

    public func agent(forPath path: String) -> AgentKind? {
        for agent in AgentKind.allCases {
            let root = roots.root(for: agent).path
            if path == root || path.hasPrefix(root + "/") { return agent }
        }
        return nil
    }

    private func isSessionFile(_ path: String, agent: AgentKind) -> Bool {
        switch agent {
        case .claudeCode, .codex: return path.hasSuffix(".jsonl")
        case .copilot: return path.hasSuffix(".jsonl")
        case .openCode: return path.hasSuffix(".json")
        }
    }

    // MARK: Reading

    /// First pass after launch: reads files changed within the lookback window, plus each agent's newest file
    /// so the latest limits and "last used" are known even for an agent that has been idle for weeks.
    @discardableResult
    public func initialScan(now: Date = Date()) -> [CompletionNotice] {
        var notices: [CompletionNotice] = []
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86400)
        for agent in AgentKind.allCases where isPresent(agent) {
            var newest: (path: String, modified: Date)?
            var recent: [String] = []
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
            guard let enumerator = fileManager.enumerator(at: roots.root(for: agent), includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                guard isSessionFile(url.path, agent: agent),
                      let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate else { continue }
                if modified >= cutoff { recent.append(url.path) }
                if newest == nil || modified > (newest?.modified ?? .distantPast) { newest = (url.path, modified) }
            }
            var paths = Set(recent)
            if let newest { paths.insert(newest.path) }
            for path in paths.sorted() {
                notices += ingest(path: path, now: now)
            }
            log?("agents: \(agent.rawValue) scanned \(paths.count) files")
        }
        // Forget cursors for files that no longer exist.
        state.cursors = state.cursors.filter { fileManager.fileExists(atPath: $0.key) }
        state.messageFiles = state.messageFiles.filter { fileManager.fileExists(atPath: $0.key) }
        state.usage.prune(keepDays: keepDays, now: now, calendar: calendar)
        refreshClaudeLimits()
        dirty = true
        return notices
    }

    /// Reads what is new in one file. Called for every path the file watcher reports.
    @discardableResult
    public func ingest(path rawPath: String, now: Date = Date()) -> [CompletionNotice] {
        let path = Self.canonical(rawPath)
        if path == roots.claudeLimitsFile.path {
            refreshClaudeLimits()
            return []
        }
        guard let agent = agent(forPath: path), isSessionFile(path, agent: agent) else { return [] }
        var notices: [CompletionNotice] = []
        var records: [ParsedRecord] = []

        if agent == .openCode {
            guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return [] }
            if state.messageFiles[path] == modified { return [] }
            guard let size = (attrs[.size] as? NSNumber)?.intValue, size < 4 << 20, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
            state.messageFiles[path] = modified
            records = OpenCodeParser.parse(messageFile: data, path: path)
        } else {
            var cursor = state.cursors[path] ?? FileCursor()
            let outcome = IncrementalReader.readNewLines(path: path, cursor: &cursor) { line, context in
                switch agent {
                case .claudeCode: records += ClaudeCodeParser.parse(line: line, context: &context, path: path)
                case .codex: records += CodexParser.parse(line: line, context: &context, path: path)
                case .copilot: records += CopilotParser.parse(line: line, context: &context, path: path)
                case .openCode: break
                }
            }
            if outcome == .missing {
                state.cursors[path] = nil
                return []
            }
            state.cursors[path] = cursor
        }

        for record in records {
            switch record {
            case .usage(let event):
                state.usage.add(event, calendar: calendar)
            case .activity(let event):
                let key = event.agent.rawValue
                if event.timestamp > (state.lastActivity[key] ?? .distantPast) {
                    state.lastActivity[key] = event.timestamp
                    if let project = event.project { state.projects[key] = project }
                }
                if let notice = tracker.record(event, now: now) { notices.append(notice) }
            case .limits(let windows, let plan):
                merge(limits: windows, plan: plan, agent: agent)
            }
        }
        if !records.isEmpty { dirty = true }
        return notices
    }

    private func merge(limits windows: [LimitWindow], plan: String?, agent: AgentKind) {
        let existing = state.limits[agent.rawValue] ?? []
        let newestExisting = existing.map(\.observedAt).max() ?? .distantPast
        let newestIncoming = windows.map(\.observedAt).max() ?? .distantPast
        // A report always describes every window, so the newest report replaces the older one wholesale.
        guard newestIncoming >= newestExisting else { return }
        state.limits[agent.rawValue] = windows
        if let plan { state.plans[agent.rawValue] = plan }
        dirty = true
    }

    /// Picks up the file written by the opt-in Claude Code status line bridge, if it exists.
    public func refreshClaudeLimits() {
        guard let data = try? Data(contentsOf: roots.claudeLimitsFile),
              let file = ClaudeStatusline.decodeBridgeFile(data) else { return }
        if file.windows.isEmpty { return }
        merge(limits: file.windows, plan: nil, agent: .claudeCode)
    }

    /// Time-based transitions (working -> waiting -> idle). Call at `nextDeadline`.
    public func tick(now: Date = Date()) -> [CompletionNotice] {
        tracker.tick(now: now)
    }

    public func nextDeadline(after now: Date = Date()) -> Date? {
        tracker.nextDeadline(after: now)
    }

    // MARK: Output

    public func snapshots(now: Date = Date(), visible: Set<AgentKind> = Set(AgentKind.allCases)) -> [AgentSnapshot] {
        let today = UsageAggregator.dayKey(now, calendar: calendar)
        let week = UsageAggregator.weekDays(now: now, calendar: calendar)
        return AgentKind.allCases.filter { visible.contains($0) && isUsed($0) }.map { agent in
            let windows = state.limits[agent.rawValue] ?? []
            return AgentSnapshot(
                agent: agent,
                state: tracker.liveState(agent, now: now),
                project: tracker.currentProject(agent) ?? state.projects[agent.rawValue],
                sessionsToday: state.usage.sessionCount(agent: agent, day: today),
                today: state.usage.usage(agent: agent, days: [today]),
                week: state.usage.usage(agent: agent, days: week),
                // Shown only when the agent's own provider reported it. Never estimated from tokens.
                limits: windows.isEmpty ? .unavailable : .available(windows),
                plan: state.plans[agent.rawValue],
                lastActivity: state.lastActivity[agent.rawValue]
            )
        }
    }

    /// For tests: the exact bytes that would be written to disk.
    public func encodedStateForTesting() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return (try? encoder.encode(state)) ?? Data()
    }

    public func cursorOffset(forPath path: String) -> UInt64? {
        state.cursors[Self.canonical(path)]?.offset
    }
}
