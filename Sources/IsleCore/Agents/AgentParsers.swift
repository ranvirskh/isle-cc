import Foundation

// Parsers pull a fixed set of metadata fields out of each log line and drop everything else.
// They never read "content", "text", "input", "output", "arguments" or similar free-text fields.
// Unknown record types, unknown fields, malformed JSON and missing fields all yield "no records".

private func object(_ line: Data) -> [String: Any]? {
    guard !line.isEmpty, let json = try? JSONSerialization.jsonObject(with: line) else { return nil }
    return json as? [String: Any]
}

private func sanitizedModel(_ v: Any?) -> String? {
    guard let s = v as? String else { return nil }
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    // Model ids are short, single-token identifiers. Anything else is not a model name.
    guard !trimmed.isEmpty, trimmed.count <= 80, !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
    return trimmed
}

private func sanitizedID(_ v: Any?) -> String? {
    guard let s = v as? String, !s.isEmpty, s.count <= 120, !s.contains(where: { $0.isWhitespace }) else { return nil }
    return s
}

private func sessionID(fromPath path: String) -> String {
    ((path as NSString).lastPathComponent as NSString).deletingPathExtension
}

public enum ClaudeCodeParser {
    /// One line of ~/.claude/projects/<project>/<session>.jsonl.
    public static func parse(line: Data, context: inout FileContext, path: String) -> [ParsedRecord] {
        guard let o = object(line), let type = o["type"] as? String, type == "assistant" || type == "user",
              let timestamp = AgentDates.parse(o["timestamp"]) else { return [] }

        if let sid = sanitizedID(o["sessionId"]) { context.sessionID = sid }
        if let project = AgentDates.projectName(fromPath: o["cwd"] as? String) { context.project = project }
        let session = context.sessionID ?? sessionID(fromPath: path)
        let isSidechain = Loose.bool(o["isSidechain"]) ?? false
        var records: [ParsedRecord] = []

        if type == "user" {
            // Meta records (local command echoes and the like) are not prompts and do not start a task.
            if !isSidechain, !(Loose.bool(o["isMeta"]) ?? false) {
                records.append(.activity(ActivityEvent(agent: .claudeCode, timestamp: timestamp, sessionID: session,
                                                       project: context.project, signal: .opened)))
            }
            return records
        }

        let message = o["message"] as? [String: Any]
        if let message, let usage = message["usage"] as? [String: Any],
           let model = sanitizedModel(message["model"]), model != "<synthetic>" {
            context.model = model
            let totals = TokenTotals(
                input: max(0, Loose.int(usage["input_tokens"]) ?? 0),
                output: max(0, Loose.int(usage["output_tokens"]) ?? 0),
                cacheRead: max(0, Loose.int(usage["cache_read_input_tokens"]) ?? 0),
                cacheWrite: max(0, Loose.int(usage["cache_creation_input_tokens"]) ?? 0),
                reasoning: max(0, Loose.int((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"]) ?? 0)
            )
            // The same API message is logged once per content block, and resumed or forked sessions replay it in
            // other files. Each event carries the message's cumulative totals under a per-message key, so the
            // aggregator replaces the earlier figure instead of adding to it: a message is counted exactly once.
            if let id = sanitizedID(message["id"]) {
                context.remember(id: id, totals: totals)
                if !totals.isZero {
                    records.append(.usage(UsageEvent(agent: .claudeCode, timestamp: timestamp, model: model, tokens: totals,
                                                     sessionID: session, project: context.project, replaceKey: "claude|" + id)))
                }
            } else if !totals.isZero {
                records.append(.usage(UsageEvent(agent: .claudeCode, timestamp: timestamp, model: model, tokens: totals,
                                                 sessionID: session, project: context.project, replaceKey: nil)))
            }
        }

        if !isSidechain {
            let stop = message?["stop_reason"] as? String
            let signal: TurnSignal
            switch stop {
            case "end_turn", "stop_sequence", "max_tokens", "refusal": signal = .closed
            default: signal = .opened
            }
            records.append(.activity(ActivityEvent(agent: .claudeCode, timestamp: timestamp, sessionID: session,
                                                   project: context.project, signal: signal)))
        } else {
            records.append(.activity(ActivityEvent(agent: .claudeCode, timestamp: timestamp, sessionID: session,
                                                   project: context.project, signal: .activity)))
        }
        return records
    }
}

public enum CodexParser {
    private static func window(_ v: Any?, id: String, observedAt: Date) -> LimitWindow? {
        guard let w = v as? [String: Any], let used = Loose.double(w["used_percent"]), used >= 0 else { return nil }
        var resets: Date?
        if let absolute = Loose.double(w["resets_at"]) {
            resets = AgentDates.fromEpoch(absolute)
        } else if let relative = Loose.double(w["resets_in_seconds"]), relative >= 0 {
            resets = observedAt.addingTimeInterval(relative)
        }
        return LimitWindow(id: id, usedPercent: used, windowMinutes: Loose.int(w["window_minutes"]),
                           resetsAt: resets, observedAt: observedAt, source: "Codex session log (rate_limits)")
    }

    /// One line of ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl.
    public static func parse(line: Data, context: inout FileContext, path: String) -> [ParsedRecord] {
        guard let o = object(line), let type = o["type"] as? String else { return [] }
        let payload = o["payload"] as? [String: Any] ?? [:]

        if type == "session_meta" {
            if let sid = sanitizedID(payload["id"]) { context.sessionID = sid }
            if let project = AgentDates.projectName(fromPath: payload["cwd"] as? String) { context.project = project }
        } else if type == "turn_context" {
            if let model = sanitizedModel(payload["model"]) { context.model = model }
            if let project = AgentDates.projectName(fromPath: payload["cwd"] as? String) { context.project = project }
        }

        guard let timestamp = AgentDates.parse(o["timestamp"]) else { return [] }
        let session = context.sessionID ?? sessionID(fromPath: path)
        func activity(_ signal: TurnSignal) -> ParsedRecord {
            .activity(ActivityEvent(agent: .codex, timestamp: timestamp, sessionID: session, project: context.project, signal: signal))
        }

        guard type == "event_msg", let kind = payload["type"] as? String else {
            // Every other record still shows the agent is alive.
            return [activity(.activity)]
        }

        switch kind {
        case "task_started", "turn_started":
            return [activity(.opened)]
        case "task_complete", "turn_complete":
            return [activity(.closed)]
        case "turn_aborted", "task_aborted":
            return [activity(.aborted)]
        case "thread_settings_applied":
            if let settings = payload["thread_settings"] as? [String: Any] {
                if let model = sanitizedModel(settings["model"]) { context.model = model }
                if let project = AgentDates.projectName(fromPath: settings["cwd"] as? String) { context.project = project }
            }
            return [activity(.activity)]
        case "token_count":
            var records: [ParsedRecord] = [activity(.activity)]
            if let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] {
                let cumulative = Loose.int((info["total_token_usage"] as? [String: Any])?["total_tokens"])
                // token_count is repeated when only the rate limits changed; the cumulative total tells them apart.
                let isNew = cumulative.map { $0 > context.counter } ?? true
                if let cumulative, isNew { context.counter = cumulative }
                if isNew {
                    let inputAll = max(0, Loose.int(last["input_tokens"]) ?? 0)
                    let cached = max(0, Loose.int(last["cached_input_tokens"]) ?? 0)
                    let totals = TokenTotals(
                        input: max(0, inputAll - cached), // input_tokens includes the cached part
                        output: max(0, Loose.int(last["output_tokens"]) ?? 0),
                        cacheRead: cached,
                        cacheWrite: max(0, Loose.int(last["cache_write_input_tokens"]) ?? 0),
                        reasoning: max(0, Loose.int(last["reasoning_output_tokens"]) ?? 0)
                    )
                    if !totals.isZero {
                        records.append(.usage(UsageEvent(agent: .codex, timestamp: timestamp, model: context.model ?? "unknown",
                                                         tokens: totals, sessionID: session, project: context.project, replaceKey: nil)))
                    }
                }
            }
            if let limits = payload["rate_limits"] as? [String: Any] {
                let windows = [window(limits["primary"], id: "primary", observedAt: timestamp),
                               window(limits["secondary"], id: "secondary", observedAt: timestamp)].compactMap { $0 }
                if !windows.isEmpty {
                    let plan = (limits["plan_type"] as? String).flatMap { $0.count <= 40 ? $0 : nil }
                    records.append(.limits(windows, plan: plan))
                }
            }
            return records
        default:
            return [activity(.activity)]
        }
    }
}

public enum OpenCodeParser {
    /// One message file: <data>/opencode/storage/message/<sessionID>/<messageID>.json.
    /// The file is rewritten as the message streams, so its usage REPLACES what was counted for it before.
    public static func parse(messageFile data: Data, path: String) -> [ParsedRecord] {
        guard let o = object(data) else { return [] }
        let time = o["time"] as? [String: Any]
        guard let created = AgentDates.parse(time?["created"]) else { return [] }
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let session = sanitizedID(o["sessionID"]) ?? folder
        let pathInfo = o["path"] as? [String: Any]
        let project = AgentDates.projectName(fromPath: (pathInfo?["root"] as? String) ?? (pathInfo?["cwd"] as? String))
        let completed = AgentDates.parse(time?["completed"])
        var records: [ParsedRecord] = [
            .activity(ActivityEvent(agent: .openCode, timestamp: completed ?? created, sessionID: session, project: project, signal: .activity)),
        ]
        guard (o["role"] as? String) == "assistant", let tokens = o["tokens"] as? [String: Any] else { return records }
        let cache = tokens["cache"] as? [String: Any]
        let totals = TokenTotals(
            input: max(0, Loose.int(tokens["input"]) ?? 0),
            output: max(0, Loose.int(tokens["output"]) ?? 0),
            cacheRead: max(0, Loose.int(cache?["read"]) ?? 0),
            cacheWrite: max(0, Loose.int(cache?["write"]) ?? 0),
            reasoning: max(0, Loose.int(tokens["reasoning"]) ?? 0)
        )
        let messageID = sanitizedID(o["id"]) ?? sessionID(fromPath: path)
        let model = sanitizedModel(o["modelID"]) ?? sanitizedModel((o["model"] as? [String: Any])?["modelID"]) ?? "unknown"
        if !totals.isZero {
            records.append(.usage(UsageEvent(agent: .openCode, timestamp: created, model: model, tokens: totals,
                                             sessionID: session, project: project, replaceKey: "opencode|" + messageID)))
        }
        return records
    }
}

public enum CopilotParser {
    private static func tokens(_ d: [String: Any]) -> TokenTotals? {
        let source = (d["usage"] as? [String: Any]) ?? d
        let input = Loose.int(source["inputTokens"]) ?? Loose.int(source["input_tokens"]) ?? Loose.int(source["promptTokens"]) ?? Loose.int(source["prompt_tokens"])
        let output = Loose.int(source["outputTokens"]) ?? Loose.int(source["output_tokens"]) ?? Loose.int(source["completionTokens"]) ?? Loose.int(source["completion_tokens"])
        guard input != nil || output != nil else { return nil }
        return TokenTotals(
            input: max(0, input ?? 0),
            output: max(0, output ?? 0),
            cacheRead: max(0, Loose.int(source["cacheReadTokens"]) ?? Loose.int(source["cache_read_tokens"]) ?? Loose.int(source["cachedTokens"]) ?? 0),
            cacheWrite: max(0, Loose.int(source["cacheWriteTokens"]) ?? Loose.int(source["cache_write_tokens"]) ?? 0)
        )
    }

    /// One line of ~/.copilot/session-state/<sessionID>/events.jsonl. The format is undocumented, so this reads
    /// only a few commonly named metadata fields and treats everything else as "the agent did something".
    public static func parse(line: Data, context: inout FileContext, path: String) -> [ParsedRecord] {
        guard let o = object(line), let timestamp = AgentDates.parse(o["timestamp"] ?? o["time"]) else { return [] }
        let data = o["data"] as? [String: Any] ?? [:]
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        if context.sessionID == nil { context.sessionID = sanitizedID(data["sessionId"]) ?? folder }
        let session = context.sessionID ?? folder

        if let model = sanitizedModel(data["model"]) ?? sanitizedModel(data["newModel"]) ?? sanitizedModel(data["selectedModel"]) {
            context.model = model
        }
        let cwd = (data["cwd"] as? String) ?? ((data["context"] as? [String: Any])?["cwd"] as? String)
        if let project = AgentDates.projectName(fromPath: cwd) { context.project = project }

        var records: [ParsedRecord] = [
            .activity(ActivityEvent(agent: .copilot, timestamp: timestamp, sessionID: session, project: context.project, signal: .activity)),
        ]
        if let totals = tokens(data), !totals.isZero {
            records.append(.usage(UsageEvent(agent: .copilot, timestamp: timestamp, model: context.model ?? "unknown",
                                             tokens: totals, sessionID: session, project: context.project, replaceKey: nil)))
        }
        return records
    }
}

public enum ClaudeStatusline {
    /// Reads the documented `rate_limits` object from the JSON Claude Code passes to a status line command
    /// (https://code.claude.com/docs/en/statusline). Present only for Pro and Max subscribers, after the first response.
    public static func limits(fromStatuslineInput data: Data, now: Date) -> [LimitWindow]? {
        guard let o = object(data) else { return nil }
        guard let limits = o["rate_limits"] as? [String: Any] else { return [] }
        let known: [(key: String, minutes: Int?)] = [("five_hour", 300), ("seven_day", 10080), ("spend_limit", nil)]
        return known.compactMap { entry in
            guard let w = limits[entry.key] as? [String: Any], let used = Loose.double(w["used_percentage"]), used >= 0 else { return nil }
            return LimitWindow(id: entry.key, usedPercent: used, windowMinutes: entry.minutes,
                               resetsAt: Loose.double(w["resets_at"]).flatMap(AgentDates.fromEpoch),
                               observedAt: now, source: "Claude Code status line (rate_limits)")
        }
    }

    /// The short line printed back to Claude Code so the status line still shows something useful.
    public static func statusText(fromStatuslineInput data: Data, now: Date) -> String {
        guard let o = object(data) else { return "" }
        var parts: [String] = []
        if let name = (o["model"] as? [String: Any])?["display_name"] as? String, name.count <= 40 { parts.append(name) }
        for w in limits(fromStatuslineInput: data, now: now) ?? [] {
            parts.append("\(LimitFormat.windowName(w)) \(Int(w.usedPercent.rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    public struct BridgeFile: Codable, Equatable {
        public var observedAt: Date
        public var windows: [LimitWindow]
    }

    public static func encodeBridgeFile(windows: [LimitWindow], now: Date) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(BridgeFile(observedAt: now, windows: windows))
    }

    public static func decodeBridgeFile(_ data: Data) -> BridgeFile? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(BridgeFile.self, from: data)
    }
}
