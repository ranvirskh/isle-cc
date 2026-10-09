import Foundation

/// Tracks which agent sessions are busy and decides when a long task has finished.
/// Pure: driven by log timestamps, with `now` used only to judge freshness and quiet periods.
public struct CompletionTracker {
    struct Session: Equatable {
        var agent: AgentKind
        var sessionID: String
        var project: String?
        var startedAt: Date?
        var lastActivity: Date
        var isOpen: Bool
    }

    /// A task must have run at least this long for a notice. Default 2 minutes.
    public var threshold: TimeInterval
    /// Busy but silent for this long reads as "waiting" instead of "working".
    public var waitingAfter: TimeInterval = 20
    /// Agents without an explicit end marker are considered done after this much silence.
    public var quietTimeout: TimeInterval = 45
    /// A task with an explicit end marker that never arrives is dropped silently after this long.
    public var abandonTimeout: TimeInterval = 600
    /// Completions older than this (found while catching up on old logs) never produce a notice.
    public var freshness: TimeInterval = 90

    private var sessions: [String: Session] = [:]
    private var fired: Set<String> = []

    public init(threshold: TimeInterval = 120) {
        self.threshold = threshold
    }

    private func key(_ agent: AgentKind, _ session: String) -> String {
        agent.rawValue + "|" + session
    }

    private mutating func close(_ k: String, endedAt: Date, now: Date, notify: Bool) -> CompletionNotice? {
        guard var s = sessions[k], s.isOpen else { return nil }
        s.isOpen = false
        let started = s.startedAt
        s.startedAt = nil
        sessions[k] = s
        guard notify, let started else { return nil }
        let notice = CompletionNotice(agent: s.agent, sessionID: s.sessionID, project: s.project, startedAt: started, endedAt: endedAt)
        guard notice.duration >= threshold, now.timeIntervalSince(endedAt) <= freshness, !fired.contains(notice.id) else { return nil }
        fired.insert(notice.id)
        return notice
    }

    /// Feeds one activity record. Returns a notice when this record completes a long task.
    public mutating func record(_ event: ActivityEvent, now: Date) -> CompletionNotice? {
        let k = key(event.agent, event.sessionID)
        var s = sessions[k] ?? Session(agent: event.agent, sessionID: event.sessionID, project: event.project,
                                       startedAt: nil, lastActivity: event.timestamp, isOpen: false)
        if let project = event.project { s.project = project }
        // Logs can be read slightly out of order; never move time backwards.
        s.lastActivity = max(s.lastActivity, event.timestamp)

        // Without an explicit end marker, any activity means a task is running.
        let opens = event.signal == .opened || (event.signal == .activity && !event.agent.hasExplicitTurnEnd)
        if opens, !s.isOpen {
            s.isOpen = true
            s.startedAt = event.timestamp
        }
        sessions[k] = s

        switch event.signal {
        case .closed:
            return close(k, endedAt: event.timestamp, now: now, notify: true)
        case .aborted:
            return close(k, endedAt: event.timestamp, now: now, notify: false)
        case .opened, .activity:
            return nil
        }
    }

    /// Applies time-based transitions. Call at `nextDeadline`.
    public mutating func tick(now: Date) -> [CompletionNotice] {
        var notices: [CompletionNotice] = []
        for (k, s) in sessions where s.isOpen {
            let quiet = now.timeIntervalSince(s.lastActivity)
            if !s.agent.hasExplicitTurnEnd {
                if quiet >= quietTimeout {
                    // The task ended when the agent last wrote something, not now.
                    let fresh = now.timeIntervalSince(s.lastActivity) <= quietTimeout + freshness
                    if let n = close(k, endedAt: s.lastActivity, now: fresh ? s.lastActivity : now, notify: true) { notices.append(n) }
                }
            } else if quiet >= abandonTimeout {
                _ = close(k, endedAt: s.lastActivity, now: now, notify: false)
            }
        }
        // Forget sessions that have been closed for a day.
        sessions = sessions.filter { $0.value.isOpen || now.timeIntervalSince($0.value.lastActivity) < 86400 }
        return notices.sorted { $0.endedAt < $1.endedAt }
    }

    public func liveState(_ agent: AgentKind, now: Date) -> AgentLiveState {
        var state = AgentLiveState.idle
        for s in sessions.values where s.agent == agent && s.isOpen {
            let quiet = now.timeIntervalSince(s.lastActivity)
            let limit = agent.hasExplicitTurnEnd ? abandonTimeout : quietTimeout
            if quiet >= limit { continue }
            if quiet < waitingAfter { return .working }
            state = .waiting
        }
        return state
    }

    /// Project of the most recently active session for this agent.
    public func currentProject(_ agent: AgentKind) -> String? {
        sessions.values.filter { $0.agent == agent && $0.project != nil }
            .max { $0.lastActivity < $1.lastActivity }?.project
    }

    public func lastActivity(_ agent: AgentKind) -> Date? {
        sessions.values.filter { $0.agent == agent }.map(\.lastActivity).max()
    }

    public var hasOpenSessions: Bool {
        sessions.values.contains { $0.isOpen }
    }

    /// The next moment a displayed state can change by time alone. Nil when nothing is busy: no timer is needed.
    public func nextDeadline(after now: Date) -> Date? {
        var deadlines: [Date] = []
        for s in sessions.values where s.isOpen {
            deadlines.append(s.lastActivity.addingTimeInterval(waitingAfter))
            deadlines.append(s.lastActivity.addingTimeInterval(s.agent.hasExplicitTurnEnd ? abandonTimeout : quietTimeout))
        }
        let future = deadlines.filter { $0 > now }
        if let next = future.min() { return next }
        // An open session already past its deadlines still needs one tick to be closed.
        return hasOpenSessions ? now.addingTimeInterval(1) : nil
    }
}
