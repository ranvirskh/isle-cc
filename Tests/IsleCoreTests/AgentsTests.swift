import XCTest
@testable import IsleCore

// Every fixture in this file is synthetic. No real session file is read by the tests.

private let secretPrompt = "SECRET_PROMPT_please_refactor_my_billing_module"
private let secretResponse = "SECRET_RESPONSE_here_is_the_refactored_code"
private let secretFile = "SECRET_FILE_CONTENT_api_key=sk-test-123"
private let secretTool = "SECRET_TOOL_OUTPUT_rm_rf_listing"
private let allSecrets = [secretPrompt, secretResponse, secretFile, secretTool]

private func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

private func line(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private enum Fixture {
    static func claudeUser(_ t: Date, session: String = "sess-1", cwd: String = "/Users/dev/code/billing-app", meta: Bool = false) -> String {
        var o: [String: Any] = ["type": "user", "timestamp": iso(t), "sessionId": session, "cwd": cwd, "uuid": UUID().uuidString,
                                "message": ["role": "user", "content": secretPrompt]]
        if meta { o["isMeta"] = true }
        return line(o)
    }

    static func claudeAssistant(_ t: Date, id: String, model: String = "claude-opus-5-5", input: Int = 100, output: Int = 50,
                                cacheRead: Int = 1000, cacheWrite: Int = 200, stop: String? = "tool_use", session: String = "sess-1",
                                cwd: String = "/Users/dev/code/billing-app", sidechain: Bool = false) -> String {
        var message: [String: Any] = [
            "id": id, "model": model, "role": "assistant",
            "content": [["type": "text", "text": secretResponse],
                        ["type": "tool_use", "name": "Write", "input": ["file_path": "/tmp/x", "content": secretFile]]],
            "usage": ["input_tokens": input, "output_tokens": output, "cache_read_input_tokens": cacheRead,
                      "cache_creation_input_tokens": cacheWrite, "service_tier": "standard", "brand_new_field": ["x": 1]],
        ]
        message["stop_reason"] = stop ?? NSNull()
        return line(["type": "assistant", "timestamp": iso(t), "sessionId": session, "cwd": cwd, "isSidechain": sidechain,
                     "requestId": "req_" + id, "message": message, "toolUseResult": ["stdout": secretTool]])
    }

    static func codexMeta(_ t: Date, id: String = "codex-sess", cwd: String = "/Users/dev/code/api-server") -> String {
        line(["type": "session_meta", "timestamp": iso(t), "payload": ["id": id, "cwd": cwd, "cli_version": "9.9", "base_instructions": secretPrompt]])
    }

    static func codexTurnContext(_ t: Date, model: String = "gpt-5.5-codex") -> String {
        line(["type": "turn_context", "timestamp": iso(t), "payload": ["model": model, "cwd": "/Users/dev/code/api-server", "user_instructions": secretPrompt]])
    }

    static func codexEvent(_ t: Date, _ kind: String, extra: [String: Any] = [:]) -> String {
        var payload: [String: Any] = ["type": kind]
        for (k, v) in extra { payload[k] = v }
        return line(["type": "event_msg", "timestamp": iso(t), "payload": payload])
    }

    static func codexTokenCount(_ t: Date, total: Int, input: Int = 500, cached: Int = 400, output: Int = 80, reasoning: Int = 30,
                                limits: [String: Any]? = nil) -> String {
        var extra: [String: Any] = [
            "info": ["last_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                                          "reasoning_output_tokens": reasoning, "total_tokens": input + output],
                     "total_token_usage": ["total_tokens": total], "model_context_window": 400_000],
        ]
        if let limits { extra["rate_limits"] = limits }
        return codexEvent(t, "token_count", extra: extra)
    }

    static func codexMessage(_ t: Date) -> String {
        line(["type": "response_item", "timestamp": iso(t), "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": secretResponse]]]])
    }
}

class AgentsFixtureCase: XCTestCase {
    var root: URL!
    var roots: AgentsEngine.Roots!
    var stateFile: URL!
    let now = Date(timeIntervalSince1970: 1_791_500_000) // 2026-10-08
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("isle-agents-\(UUID().uuidString)")
        roots = AgentsEngine.Roots(
            claude: root.appendingPathComponent("claude/projects"),
            codex: root.appendingPathComponent("codex/sessions"),
            openCode: root.appendingPathComponent("opencode/storage/message"),
            copilot: root.appendingPathComponent("copilot/session-state"),
            claudeLimitsFile: root.appendingPathComponent("support/Agents/claude-limits.json")
        )
        stateFile = root.appendingPathComponent("support/Agents/state.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func engine(persist: Bool = true) -> AgentsEngine {
        AgentsEngine(roots: roots, stateFile: persist ? stateFile : nil, calendar: calendar)
    }

    @discardableResult
    func write(_ lines: [String], to url: URL, append: Bool = false, trailingNewline: Bool = true) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        if append, let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
        return url
    }

    var claudeFile: URL { roots.claude.appendingPathComponent("-Users-dev-code-billing-app/sess-1.jsonl") }
    var codexFile: URL { roots.codex.appendingPathComponent("2026/10/08/rollout-2026-10-08T10-00-00-codex-sess.jsonl") }
}

final class AgentParsingTests: AgentsFixtureCase {
    func testClaudeTokensModelAndProject() throws {
        try write([
            Fixture.claudeUser(now.addingTimeInterval(-60)),
            Fixture.claudeAssistant(now.addingTimeInterval(-50), id: "msg_1", input: 100, output: 50, cacheRead: 1000, cacheWrite: 200),
            Fixture.claudeAssistant(now.addingTimeInterval(-40), id: "msg_2", model: "claude-haiku-5-5", input: 10, output: 5, cacheRead: 0, cacheWrite: 0, stop: "end_turn"),
        ], to: claudeFile)
        let e = engine()
        e.initialScan(now: now)
        let snap = try XCTUnwrap(e.snapshots(now: now).first { $0.agent == .claudeCode })
        XCTAssertEqual(snap.project, "billing-app", "folder name only, not the path")
        XCTAssertEqual(snap.sessionsToday, 1)
        XCTAssertEqual(snap.today.map(\.model), ["claude-opus-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(snap.today.first?.tokens, TokenTotals(input: 100, output: 50, cacheRead: 1000, cacheWrite: 200))
        XCTAssertEqual(snap.todayTotal.inOut, 165)
        XCTAssertEqual(snap.state, .idle, "the turn ended")
    }

    func testClaudeRepeatedMessageIdCountedOnce() throws {
        // Claude Code logs one record per content block, all with the same message id and usage.
        try write([
            Fixture.claudeAssistant(now.addingTimeInterval(-50), id: "msg_1", input: 100, output: 20),
            Fixture.claudeAssistant(now.addingTimeInterval(-49), id: "msg_1", input: 100, output: 20),
            Fixture.claudeAssistant(now.addingTimeInterval(-48), id: "msg_1", input: 100, output: 55), // final block carries the full output count
        ], to: claudeFile)
        let e = engine()
        e.initialScan(now: now)
        let total = e.snapshots(now: now).first?.todayTotal
        XCTAssertEqual(total?.input, 100)
        XCTAssertEqual(total?.output, 55)
        XCTAssertEqual(total?.cacheRead, 1000)
    }

    func testClaudeSyntheticModelAndSidechain() throws {
        try write([
            Fixture.claudeAssistant(now.addingTimeInterval(-50), id: "msg_s", model: "<synthetic>", input: 999, output: 999),
            Fixture.claudeAssistant(now.addingTimeInterval(-40), id: "msg_sub", input: 7, output: 3, cacheRead: 0, cacheWrite: 0, stop: "end_turn", sidechain: true),
        ], to: claudeFile)
        let e = engine()
        e.initialScan(now: now)
        let snap = try XCTUnwrap(e.snapshots(now: now).first)
        XCTAssertEqual(snap.todayTotal.inOut, 10, "synthetic records carry no real usage; subagent tokens count")
    }

    func testCodexTokensModelProjectAndLimits() throws {
        let reset = now.addingTimeInterval(7 * 86400)
        try write([
            Fixture.codexMeta(now.addingTimeInterval(-100)),
            Fixture.codexTurnContext(now.addingTimeInterval(-99)),
            Fixture.codexEvent(now.addingTimeInterval(-98), "task_started"),
            Fixture.codexMessage(now.addingTimeInterval(-90)),
            Fixture.codexTokenCount(now.addingTimeInterval(-80), total: 580, limits: [
                "plan_type": "plus",
                "primary": ["used_percent": 42.5, "window_minutes": 300, "resets_at": Int(now.timeIntervalSince1970) + 3600],
                "secondary": ["used_percent": 71.0, "window_minutes": 10080, "resets_at": Int(reset.timeIntervalSince1970)],
            ]),
            // Same cumulative total again: only the rate limits were refreshed.
            Fixture.codexTokenCount(now.addingTimeInterval(-79), total: 580),
            Fixture.codexTokenCount(now.addingTimeInterval(-70), total: 1160),
            Fixture.codexEvent(now.addingTimeInterval(-60), "task_complete", extra: ["last_agent_message": secretResponse]),
        ], to: codexFile)
        let e = engine()
        e.initialScan(now: now)
        let snap = try XCTUnwrap(e.snapshots(now: now).first { $0.agent == .codex })
        XCTAssertEqual(snap.project, "api-server")
        XCTAssertEqual(snap.plan, "plus")
        XCTAssertEqual(snap.today.first?.model, "gpt-5.5-codex")
        // Two distinct token_count events; input_tokens includes the cached part.
        XCTAssertEqual(snap.todayTotal, TokenTotals(input: 200, output: 160, cacheRead: 800, cacheWrite: 0, reasoning: 60))
        guard case .available(let windows) = snap.limits else { return XCTFail("expected limits") }
        XCTAssertEqual(windows.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(windows[0].usedPercent, 42.5)
        XCTAssertEqual(windows[0].windowMinutes, 300)
        XCTAssertEqual(windows[1].resetsAt, Date(timeIntervalSince1970: Double(Int(reset.timeIntervalSince1970))))
        XCTAssertEqual(LimitFormat.windowName(windows[0]), "5-hour")
        XCTAssertEqual(LimitFormat.windowName(windows[1]), "Weekly")
        XCTAssertEqual(snap.state, .idle)
    }

    func testCodexOlderRelativeResetSchema() {
        var context = FileContext()
        let raw = Fixture.codexTokenCount(now, total: 10, limits: ["primary": ["used_percent": 5, "window_minutes": 300, "resets_in_seconds": 120]])
        let records = CodexParser.parse(line: Data(raw.utf8), context: &context, path: "/x/rollout.jsonl")
        guard case .limits(let windows, _)? = records.last else { return XCTFail("expected limits") }
        XCTAssertEqual(windows.first?.resetsAt, now.addingTimeInterval(120), "relative reset is anchored to the record's timestamp")
    }

    func testNewerLimitsReplaceOlderOnes() throws {
        try write([
            Fixture.codexMeta(now.addingTimeInterval(-500)),
            Fixture.codexTokenCount(now.addingTimeInterval(-400), total: 10, limits: ["primary": ["used_percent": 10, "window_minutes": 300, "resets_at": Int(now.timeIntervalSince1970) + 100]]),
            Fixture.codexTokenCount(now.addingTimeInterval(-300), total: 20, limits: ["primary": ["used_percent": 30, "window_minutes": 300, "resets_at": Int(now.timeIntervalSince1970) + 100]]),
        ], to: codexFile)
        let e = engine()
        e.initialScan(now: now)
        guard case .available(let windows)? = e.snapshots(now: now).first?.limits else { return XCTFail() }
        XCTAssertEqual(windows.map(\.usedPercent), [30])
    }

    func testOpenCodeMessageFilesAndRewrite() throws {
        let created = Int(now.addingTimeInterval(-30).timeIntervalSince1970 * 1000)
        func message(output: Int) -> String {
            line(["id": "msg_oc1", "sessionID": "ses_oc", "role": "assistant", "modelID": "claude-sonnet-5-5", "providerID": "anthropic",
                  "time": ["created": created], "path": ["cwd": "/Users/dev/code/webshop/src", "root": "/Users/dev/code/webshop"],
                  "tokens": ["input": 300, "output": output, "reasoning": 0, "cache": ["read": 50, "write": 5]], "summary": secretResponse])
        }
        let file = roots.openCode.appendingPathComponent("ses_oc/msg_oc1.json")
        try write([message(output: 10)], to: file)
        try write([line(["id": "msg_u", "sessionID": "ses_oc", "role": "user", "time": ["created": created]])],
                  to: roots.openCode.appendingPathComponent("ses_oc/msg_u.json"))
        let e = engine()
        e.initialScan(now: now)
        var snap = try XCTUnwrap(e.snapshots(now: now).first { $0.agent == .openCode })
        XCTAssertEqual(snap.project, "webshop")
        XCTAssertEqual(snap.todayTotal, TokenTotals(input: 300, output: 10, cacheRead: 50, cacheWrite: 5))

        // The message file is rewritten as the response streams: the new numbers replace the old ones.
        try write([message(output: 90)], to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        e.ingest(path: file.path, now: now)
        snap = try XCTUnwrap(e.snapshots(now: now).first { $0.agent == .openCode })
        XCTAssertEqual(snap.todayTotal, TokenTotals(input: 300, output: 90, cacheRead: 50, cacheWrite: 5))
        XCTAssertEqual(snap.today.first?.model, "claude-sonnet-5-5")
    }

    func testCopilotTolerantParsing() throws {
        let file = roots.copilot.appendingPathComponent("cop-sess-1/events.jsonl")
        try write([
            line(["type": "session.start", "timestamp": iso(now.addingTimeInterval(-50)), "data": ["context": ["cwd": "/Users/dev/code/infra"], "selectedModel": "gpt-5.5"]]),
            line(["type": "user.message", "timestamp": iso(now.addingTimeInterval(-49)), "data": ["content": secretPrompt]]),
            line(["type": "assistant.usage", "timestamp": iso(now.addingTimeInterval(-40)), "data": ["inputTokens": 120, "outputTokens": 30, "cacheReadTokens": 9]]),
            line(["type": "assistant.message", "timestamp": iso(now.addingTimeInterval(-39)), "data": ["content": secretResponse, "usage": ["input_tokens": 5, "output_tokens": 6]]]),
            line(["type": "some.future.event", "timestamp": iso(now.addingTimeInterval(-38)), "data": 17]),
        ], to: file)
        let e = engine()
        e.initialScan(now: now)
        let snap = try XCTUnwrap(e.snapshots(now: now).first { $0.agent == .copilot })
        XCTAssertEqual(snap.project, "infra")
        XCTAssertEqual(snap.today.first?.model, "gpt-5.5")
        XCTAssertEqual(snap.todayTotal, TokenTotals(input: 125, output: 36, cacheRead: 9))
        XCTAssertEqual(snap.limits, .unavailable)
    }

    func testMalformedLinesUnknownFieldsAndSchemaDriftAreTolerated() throws {
        try write([
            "this is not json at all",
            "{\"type\":\"assistant\",\"timestamp\":",                                 // cut off
            "[1,2,3]",                                                              // not an object
            "null",
            line(["type": "assistant"]),                                             // no timestamp
            line(["type": "assistant", "timestamp": "yesterday-ish", "message": ["usage": ["input_tokens": 5]]]),
            line(["type": "assistant", "timestamp": iso(now.addingTimeInterval(-30)), "message": "now a string"]),
            line(["type": "assistant", "timestamp": iso(now.addingTimeInterval(-29)), "message": ["model": ["nested": true], "usage": ["input_tokens": 5]]]),
            line(["type": "assistant", "timestamp": iso(now.addingTimeInterval(-28)), "message": ["model": "claude-opus-5-5", "usage": "n/a"]]),
            line(["type": "assistant", "timestamp": iso(now.addingTimeInterval(-27)), "message": ["model": "claude-opus-5-5", "id": "m1",
                                                                                                    "usage": ["input_tokens": "12", "output_tokens": -4, "cache_read_input_tokens": 1.0e30]]]),
            line(["type": "brand-new-record-type", "timestamp": iso(now.addingTimeInterval(-26)), "payload": [1, 2]]),
            line(["type": "summary", "summary": secretResponse]),
            Fixture.claudeAssistant(now.addingTimeInterval(-20), id: "m2", input: 1, output: 2, cacheRead: 3, cacheWrite: 4, stop: "end_turn"),
            "\u{0}\u{1}\u{2} binary junk \u{FFFD}",
        ], to: claudeFile)
        let e = engine()
        e.initialScan(now: now)
        let snap = try XCTUnwrap(e.snapshots(now: now).first)
        // "12" as a string is accepted, the negative count is clamped, the absurd count is dropped.
        XCTAssertEqual(snap.todayTotal, TokenTotals(input: 13, output: 2, cacheRead: 3, cacheWrite: 4))
    }

    func testCodexSchemaDrift() {
        var context = FileContext()
        let odd = [
            line(["type": "event_msg", "timestamp": iso(now), "payload": "string payload"]),
            line(["type": "event_msg", "timestamp": iso(now), "payload": ["type": "token_count", "info": NSNull()]]),
            line(["type": "event_msg", "timestamp": iso(now), "payload": ["type": "token_count", "info": ["last_token_usage": "x"], "rate_limits": ["primary": NSNull(), "secondary": ["used_percent": "high"]]]]),
            line(["type": "token_usage_record", "timestamp": iso(now), "payload": ["usage": ["total_tokens": 5]]]),
            line(["timestamp": iso(now)]),
        ]
        for raw in odd {
            let records = CodexParser.parse(line: Data(raw.utf8), context: &context, path: "/x/r.jsonl")
            XCTAssertFalse(records.contains { if case .usage = $0 { return true } else { return false } }, raw)
            XCTAssertFalse(records.contains { if case .limits = $0 { return true } else { return false } }, raw)
        }
    }

    func testMissingAgentFolders() {
        let e = engine()
        XCTAssertTrue(e.initialScan(now: now).isEmpty)
        XCTAssertTrue(e.snapshots(now: now).isEmpty, "clean empty state when no agent is installed")
        for agent in AgentKind.allCases {
            XCTAssertFalse(e.isPresent(agent))
            XCTAssertFalse(e.isUsed(agent))
        }
        XCTAssertTrue(e.ingest(path: "/nonexistent/file.jsonl", now: now).isEmpty)
        XCTAssertNil(e.nextDeadline(after: now), "nothing active: no timer")
    }

    func testPresentButNeverUsedIsNotShown() throws {
        try FileManager.default.createDirectory(at: roots.copilot, withIntermediateDirectories: true)
        let e = engine()
        e.initialScan(now: now)
        XCTAssertTrue(e.isPresent(.copilot))
        XCTAssertFalse(e.isUsed(.copilot))
        XCTAssertTrue(e.snapshots(now: now).isEmpty)
    }

    func testHiddenAgentsAreFilteredOut() throws {
        try write([Fixture.claudeAssistant(now.addingTimeInterval(-5), id: "m", stop: "end_turn")], to: claudeFile)
        try write([Fixture.codexMeta(now.addingTimeInterval(-5))], to: codexFile)
        let e = engine()
        e.initialScan(now: now)
        XCTAssertEqual(e.snapshots(now: now).map(\.agent), [.claudeCode, .codex])
        XCTAssertEqual(e.snapshots(now: now, visible: [.codex]).map(\.agent), [.codex])
    }

    func testOldIdleAgentStillDetectedFromItsNewestFile() throws {
        // Last used a month ago: outside the lookback window, but its newest file is still read once.
        let old = now.addingTimeInterval(-30 * 86400)
        try write([
            Fixture.codexMeta(old),
            Fixture.codexTokenCount(old, total: 10, limits: ["plan_type": "free", "primary": ["used_percent": 11, "window_minutes": 43200, "resets_at": Int(now.timeIntervalSince1970) + 86400]]),
        ], to: codexFile)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: codexFile.path)
        let e = engine()
        e.initialScan(now: now)
        let snap = try XCTUnwrap(e.snapshots(now: now).first)
        XCTAssertEqual(snap.lastActivity, Date(timeIntervalSince1970: (old.timeIntervalSince1970 * 1000).rounded() / 1000))
        XCTAssertTrue(snap.today.isEmpty)
        guard case .available(let w) = snap.limits else { return XCTFail() }
        XCTAssertEqual(w.first?.usedPercent, 11)
        XCTAssertEqual(LimitFormat.windowName(w[0]), "Monthly")
    }
}

final class IncrementalReadingTests: AgentsFixtureCase {
    func testOffsetsAdvanceAndNothingIsReadTwice() throws {
        try write([Fixture.claudeAssistant(now.addingTimeInterval(-50), id: "m1", input: 10, output: 1, cacheRead: 0, cacheWrite: 0)], to: claudeFile)
        let e = engine()
        e.initialScan(now: now)
        let firstOffset = try XCTUnwrap(e.cursorOffset(forPath: claudeFile.path))
        XCTAssertEqual(firstOffset, UInt64(try Data(contentsOf: claudeFile).count))

        // Re-ingesting an unchanged file adds nothing.
        e.ingest(path: claudeFile.path, now: now)
        e.ingest(path: claudeFile.path, now: now)
        XCTAssertEqual(e.snapshots(now: now).first?.todayTotal.input, 10)

        try write([Fixture.claudeAssistant(now.addingTimeInterval(-40), id: "m2", input: 5, output: 1, cacheRead: 0, cacheWrite: 0)], to: claudeFile, append: true)
        e.ingest(path: claudeFile.path, now: now)
        XCTAssertEqual(e.snapshots(now: now).first?.todayTotal.input, 15)
        XCTAssertGreaterThan(try XCTUnwrap(e.cursorOffset(forPath: claudeFile.path)), firstOffset)
    }

    func testPartialLastLineWaitsForItsNewline() throws {
        let full = Fixture.claudeAssistant(now.addingTimeInterval(-50), id: "m1", input: 10, output: 1, cacheRead: 0, cacheWrite: 0)
        let second = Fixture.claudeAssistant(now.addingTimeInterval(-40), id: "m2", input: 7, output: 1, cacheRead: 0, cacheWrite: 0)
        let cut = second.index(second.startIndex, offsetBy: second.count / 2)
        try write([full, String(second[..<cut])], to: claudeFile, trailingNewline: false)

        let e = engine()
        e.initialScan(now: now)
        XCTAssertEqual(e.snapshots(now: now).first?.todayTotal.input, 10, "the half-written line is not parsed")
        XCTAssertEqual(e.cursorOffset(forPath: claudeFile.path), UInt64(full.utf8.count + 1), "cursor stops before the partial line")

        // The writer finishes the line.
        try write([String(second[cut...])], to: claudeFile, append: true)
        e.ingest(path: claudeFile.path, now: now)
        XCTAssertEqual(e.snapshots(now: now).first?.todayTotal.input, 17, "counted exactly once, when complete")
    }

    func testOffsetsSurviveRelaunch() throws {
        try write([Fixture.claudeAssistant(now.addingTimeInterval(-50), id: "m1", input: 10, output: 1, cacheRead: 0, cacheWrite: 0)], to: claudeFile)
        let first = engine()
        first.initialScan(now: now)
        first.save()

        try write([Fixture.claudeAssistant(now.addingTimeInterval(-40), id: "m2", input: 5, output: 1, cacheRead: 0, cacheWrite: 0)], to: claudeFile, append: true)
        let second = engine()
        second.initialScan(now: now)
        XCTAssertEqual(second.snapshots(now: now).first?.todayTotal.input, 15, "old lines are not re-counted after a relaunch")
    }

    func testCodexModelContextSurvivesRelaunch() throws {
        try write([Fixture.codexMeta(now.addingTimeInterval(-100)), Fixture.codexTurnContext(now.addingTimeInterval(-99), model: "gpt-x")], to: codexFile)
        let first = engine()
        first.initialScan(now: now)
        first.save()
        try write([Fixture.codexTokenCount(now.addingTimeInterval(-10), total: 99)], to: codexFile, append: true)
        let second = engine()
        second.initialScan(now: now)
        XCTAssertEqual(second.snapshots(now: now).first?.today.first?.model, "gpt-x")
    }

    func testTruncationRestartsFromZero() throws {
        try write([
            Fixture.claudeAssistant(now.addingTimeInterval(-50), id: "m1", input: 10, output: 1, cacheRead: 0, cacheWrite: 0),
            Fixture.claudeAssistant(now.addingTimeInterval(-49), id: "m2", input: 10, output: 1, cacheRead: 0, cacheWrite: 0),
        ], to: claudeFile)
        var cursor = FileCursor()
        var seen = 0
        IncrementalReader.readNewLines(path: claudeFile.path, cursor: &cursor) { _, _ in seen += 1 }
        XCTAssertEqual(seen, 2)
        cursor.context.model = "stale"

        // Truncate in place (same inode), then write one shorter line.
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: claudeFile.path))
        try handle.truncate(atOffset: 0)
        handle.write(Data("{\"a\":1}\n".utf8))
        try handle.close()

        seen = 0
        let outcome = IncrementalReader.readNewLines(path: claudeFile.path, cursor: &cursor) { _, _ in seen += 1 }
        XCTAssertEqual(outcome, .read(bytes: 8, restarted: true))
        XCTAssertEqual(seen, 1)
        XCTAssertEqual(cursor.offset, 8)
        XCTAssertNil(cursor.context.model, "parser context is reset with the file")
    }

    func testRotationRestartsFromZero() throws {
        try write([String(repeating: "x", count: 50)], to: claudeFile)
        var cursor = FileCursor()
        IncrementalReader.readNewLines(path: claudeFile.path, cursor: &cursor) { _, _ in }
        let oldInode = cursor.inode

        // Rotate: the old file is moved away and a NEW, LONGER file appears at the same path.
        let rotated = claudeFile.deletingLastPathComponent().appendingPathComponent("sess-1.jsonl.1")
        try FileManager.default.moveItem(at: claudeFile, to: rotated)
        try write([String(repeating: "y", count: 80), String(repeating: "z", count: 80)], to: claudeFile)

        var lines: [String] = []
        let outcome = IncrementalReader.readNewLines(path: claudeFile.path, cursor: &cursor) { data, _ in lines.append(String(decoding: data, as: UTF8.self)) }
        XCTAssertNotEqual(cursor.inode, oldInode)
        XCTAssertEqual(outcome, .read(bytes: 162, restarted: true))
        XCTAssertEqual(lines.count, 2, "both lines of the new file are read from its start, not from the old offset")
        XCTAssertTrue(lines[0].hasPrefix("y"))
    }

    func testMissingFileAndUnchangedFile() throws {
        var cursor = FileCursor()
        XCTAssertEqual(IncrementalReader.readNewLines(path: "/nonexistent/x.jsonl", cursor: &cursor) { _, _ in }, .missing)
        try write(["{}"], to: claudeFile)
        XCTAssertEqual(IncrementalReader.readNewLines(path: claudeFile.path, cursor: &cursor) { _, _ in }, .read(bytes: 3, restarted: false))
        XCTAssertEqual(IncrementalReader.readNewLines(path: claudeFile.path, cursor: &cursor) { _, _ in }, .unchanged)
    }

    func testLinesLargerThanTheChunkSize() throws {
        let big = "{\"k\":\"" + String(repeating: "a", count: 5000) + "\"}"
        try write([big, "{}"], to: claudeFile)
        var cursor = FileCursor()
        var sizes: [Int] = []
        IncrementalReader.readNewLines(path: claudeFile.path, cursor: &cursor, chunkSize: 512) { data, _ in sizes.append(data.count) }
        XCTAssertEqual(sizes, [big.utf8.count, 2])
    }

    func testDeletedFileDropsItsCursor() throws {
        try write([Fixture.claudeAssistant(now.addingTimeInterval(-5), id: "m1")], to: claudeFile)
        let e = engine()
        e.initialScan(now: now)
        try FileManager.default.removeItem(at: claudeFile)
        XCTAssertTrue(e.ingest(path: claudeFile.path, now: now).isEmpty)
        XCTAssertNil(e.cursorOffset(forPath: claudeFile.path))
    }
}

final class CompletionTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_500_000)

    private func event(_ agent: AgentKind, _ offset: TimeInterval, _ signal: TurnSignal, session: String = "s1") -> ActivityEvent {
        ActivityEvent(agent: agent, timestamp: t0.addingTimeInterval(offset), sessionID: session, project: "proj", signal: signal)
    }

    func testLongTaskFiresOnceWhenItGoesIdle() {
        var tracker = CompletionTracker(threshold: 120)
        XCTAssertNil(tracker.record(event(.claudeCode, 0, .opened), now: t0))
        XCTAssertNil(tracker.record(event(.claudeCode, 60, .opened), now: t0.addingTimeInterval(60)))
        XCTAssertEqual(tracker.liveState(.claudeCode, now: t0.addingTimeInterval(61)), .working)
        let notice = tracker.record(event(.claudeCode, 200, .closed), now: t0.addingTimeInterval(200))
        XCTAssertEqual(notice?.agent, .claudeCode)
        XCTAssertEqual(notice?.project, "proj")
        XCTAssertEqual(notice?.duration, 200)
        XCTAssertEqual(tracker.liveState(.claudeCode, now: t0.addingTimeInterval(201)), .idle)
        // The same end marker logged again (duplicate record) must not fire twice.
        XCTAssertNil(tracker.record(event(.claudeCode, 200, .closed), now: t0.addingTimeInterval(200)))
        XCTAssertNil(tracker.record(event(.claudeCode, 201, .closed), now: t0.addingTimeInterval(201)))
    }

    func testShortTaskIsBelowThreshold() {
        var tracker = CompletionTracker(threshold: 120)
        _ = tracker.record(event(.codex, 0, .opened), now: t0)
        XCTAssertNil(tracker.record(event(.codex, 119, .closed), now: t0.addingTimeInterval(119)))
    }

    func testThresholdIsConfigurable() {
        var tracker = CompletionTracker(threshold: 30)
        _ = tracker.record(event(.codex, 0, .opened), now: t0)
        XCTAssertNotNil(tracker.record(event(.codex, 31, .closed), now: t0.addingTimeInterval(31)))
    }

    func testNewTaskInSameSessionCanFireAgain() {
        var tracker = CompletionTracker(threshold: 60)
        _ = tracker.record(event(.codex, 0, .opened), now: t0)
        let first = tracker.record(event(.codex, 100, .closed), now: t0.addingTimeInterval(100))
        _ = tracker.record(event(.codex, 500, .opened), now: t0.addingTimeInterval(500))
        let second = tracker.record(event(.codex, 700, .closed), now: t0.addingTimeInterval(700))
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.id, second?.id)
        XCTAssertEqual(second?.duration, 200, "measured from the start of the second task")
    }

    func testOldLogsNeverNotify() {
        // Catching up on a session that finished an hour ago.
        var tracker = CompletionTracker(threshold: 120)
        let now = t0.addingTimeInterval(3600)
        XCTAssertNil(tracker.record(event(.claudeCode, 0, .opened), now: now))
        XCTAssertNil(tracker.record(event(.claudeCode, 300, .closed), now: now))
    }

    func testAbortedTaskClosesSilently() {
        var tracker = CompletionTracker(threshold: 60)
        _ = tracker.record(event(.codex, 0, .opened), now: t0)
        XCTAssertNil(tracker.record(event(.codex, 300, .aborted), now: t0.addingTimeInterval(300)))
        XCTAssertEqual(tracker.liveState(.codex, now: t0.addingTimeInterval(301)), .idle)
    }

    func testWorkingThenWaitingThenAbandoned() {
        var tracker = CompletionTracker(threshold: 60)
        _ = tracker.record(event(.claudeCode, 0, .opened), now: t0)
        XCTAssertEqual(tracker.liveState(.claudeCode, now: t0.addingTimeInterval(5)), .working)
        XCTAssertEqual(tracker.liveState(.claudeCode, now: t0.addingTimeInterval(25)), .waiting, "open turn, but quiet")
        XCTAssertEqual(tracker.nextDeadline(after: t0), t0.addingTimeInterval(20))
        XCTAssertEqual(tracker.nextDeadline(after: t0.addingTimeInterval(21)), t0.addingTimeInterval(600))
        XCTAssertTrue(tracker.tick(now: t0.addingTimeInterval(601)).isEmpty, "an interrupted task ends without a notice")
        XCTAssertEqual(tracker.liveState(.claudeCode, now: t0.addingTimeInterval(602)), .idle)
        XCTAssertNil(tracker.nextDeadline(after: t0.addingTimeInterval(602)), "nothing open: no timer runs")
    }

    func testAgentsWithoutEndMarkerCompleteByGoingQuiet() {
        var tracker = CompletionTracker(threshold: 120)
        _ = tracker.record(event(.openCode, 0, .activity), now: t0)
        _ = tracker.record(event(.openCode, 150, .activity), now: t0.addingTimeInterval(150))
        XCTAssertTrue(tracker.tick(now: t0.addingTimeInterval(170)).isEmpty, "not quiet for long enough yet")
        let notices = tracker.tick(now: t0.addingTimeInterval(150 + 46))
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.duration, 150, "ends at the last activity, not at the tick")
        XCTAssertTrue(tracker.tick(now: t0.addingTimeInterval(400)).isEmpty, "no duplicate")
    }

    func testActivityAloneDoesNotOpenATurnForExplicitAgents() {
        var tracker = CompletionTracker(threshold: 1)
        _ = tracker.record(event(.codex, 0, .activity), now: t0)
        XCTAssertEqual(tracker.liveState(.codex, now: t0.addingTimeInterval(1)), .idle)
        XCTAssertNil(tracker.nextDeadline(after: t0))
    }

    func testSessionsAreIndependent() {
        var tracker = CompletionTracker(threshold: 60)
        _ = tracker.record(event(.claudeCode, 0, .opened, session: "a"), now: t0)
        _ = tracker.record(event(.claudeCode, 10, .opened, session: "b"), now: t0.addingTimeInterval(10))
        let a = tracker.record(event(.claudeCode, 100, .closed, session: "a"), now: t0.addingTimeInterval(100))
        XCTAssertEqual(a?.sessionID, "a")
        XCTAssertEqual(tracker.liveState(.claudeCode, now: t0.addingTimeInterval(101)), .waiting, "session b is still open")
        XCTAssertEqual(tracker.liveState(.codex, now: t0.addingTimeInterval(101)), .idle)
    }

    func testCompletionNoticeQueuesWithOtherPopups() {
        var tracker = CompletionTracker(threshold: 60)
        _ = tracker.record(event(.claudeCode, 0, .opened), now: t0)
        let notice = tracker.record(event(.claudeCode, 90, .closed), now: t0.addingTimeInterval(90))!
        var queue = PopupQueue()
        var island = IslandStateMachine()

        queue.enqueue(PopupItem(id: "bt-1", kind: .bluetoothDevice, symbol: "airpods", title: "AirPods", enqueuedAt: t0.addingTimeInterval(89)))
        queue.enqueue(PopupItem(id: notice.id, kind: .agentCompletion, symbol: "sparkle", title: "Claude Code", enqueuedAt: t0.addingTimeInterval(90)))
        queue.enqueue(PopupItem(id: notice.id, kind: .agentCompletion, symbol: "sparkle", title: "Claude Code", enqueuedAt: t0.addingTimeInterval(90)))
        XCTAssertEqual(queue.pending.count, 2, "the same notice id cannot be queued twice")

        let now = t0.addingTimeInterval(91)
        XCTAssertEqual(queue.dequeue(canPresent: island.canPresentPopup, now: now)?.id, "bt-1")
        _ = island.handle(.popupRequested)
        XCTAssertNil(queue.dequeue(canPresent: island.canPresentPopup, now: now), "waits behind the device pop-up")
        _ = island.handle(.popupTimerFired)
        queue.finishCurrent()
        XCTAssertEqual(queue.dequeue(canPresent: island.canPresentPopup, now: now)?.kind, .agentCompletion)

        // And it never interrupts a drag.
        var dragging = IslandStateMachine()
        _ = dragging.handle(.dragApproached)
        var q2 = PopupQueue()
        q2.enqueue(PopupItem(id: notice.id, kind: .agentCompletion, symbol: "sparkle", title: "Claude Code", enqueuedAt: now))
        XCTAssertNil(q2.dequeue(canPresent: dragging.canPresentPopup, now: now))
    }
}

final class AgentsEngineLiveTests: AgentsFixtureCase {
    func testCompletionNoticeFromLogsEndToEnd() throws {
        // Use the real clock: notices are only for tasks that finished moments ago.
        let end = Date()
        let start = end.addingTimeInterval(-300)
        try write([Fixture.claudeUser(start), Fixture.claudeAssistant(start.addingTimeInterval(10), id: "m1")], to: claudeFile)
        let e = engine()
        XCTAssertTrue(e.initialScan(now: start.addingTimeInterval(11)).isEmpty)
        XCTAssertEqual(e.snapshots(now: start.addingTimeInterval(12)).first?.state, .working)
        XCTAssertNotNil(e.nextDeadline(after: start.addingTimeInterval(12)), "a timer runs only while an agent is busy")

        try write([Fixture.claudeAssistant(end, id: "m2", stop: "end_turn")], to: claudeFile, append: true)
        let notices = e.ingest(path: claudeFile.path, now: end)
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.project, "billing-app")
        XCTAssertEqual(notices.first.map { Int($0.duration.rounded()) }, 300)
        XCTAssertTrue(e.ingest(path: claudeFile.path, now: end).isEmpty, "never twice for the same task")
        XCTAssertNil(e.nextDeadline(after: end))
    }

    func testMetaUserRecordsDoNotStartATask() throws {
        let t = Date().addingTimeInterval(-5)
        try write([Fixture.claudeUser(t, meta: true)], to: claudeFile)
        let e = engine()
        e.initialScan(now: Date())
        XCTAssertEqual(e.snapshots().first?.state ?? .idle, .idle)
    }

    func testTodayAndWeekSplit() throws {
        // now is Thursday 2026-10-08 (UTC), week starts Monday 10-05.
        try write([
            Fixture.claudeAssistant(now.addingTimeInterval(-3600), id: "today", input: 1, output: 0, cacheRead: 0, cacheWrite: 0),
            Fixture.claudeAssistant(now.addingTimeInterval(-2 * 86400), id: "tuesday", input: 10, output: 0, cacheRead: 0, cacheWrite: 0, session: "sess-2"),
            Fixture.claudeAssistant(now.addingTimeInterval(-5 * 86400), id: "last-week", input: 100, output: 0, cacheRead: 0, cacheWrite: 0, session: "sess-3"),
        ], to: claudeFile)
        let e = engine()
        e.initialScan(now: now)
        let snap = try XCTUnwrap(e.snapshots(now: now).first)
        XCTAssertEqual(snap.todayTotal.input, 1)
        XCTAssertEqual(snap.weekTotal.input, 11, "last week's usage is not in this week")
        XCTAssertEqual(snap.sessionsToday, 1)
    }

    func testClaudeLimitsUnavailableWithoutABridgeAndAvailableWithIt() throws {
        try write([Fixture.claudeAssistant(now.addingTimeInterval(-5), id: "m", stop: "end_turn")], to: claudeFile)
        let e = engine()
        e.initialScan(now: now)
        XCTAssertEqual(e.snapshots(now: now).first?.limits, .unavailable)
        XCTAssertEqual(LimitAvailability.unavailableText, "Limit data not available")
        XCTAssertNil(LimitFormat.highestPercent(e.snapshots(now: now), now: now), "no number is invented for the header chip")

        // The user opts in to the documented status line bridge; Claude Code then hands Isle its rate_limits.
        let input = Data(#"{"model":{"display_name":"Opus"},"session_id":"abc","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":\#(Int(now.timeIntervalSince1970) + 7200)},"seven_day":{"used_percentage":88,"resets_at":\#(Int(now.timeIntervalSince1970) + 86400)}},"transcript_path":"/secret/path"}"#.utf8)
        let windows = try XCTUnwrap(ClaudeStatusline.limits(fromStatuslineInput: input, now: now))
        XCTAssertEqual(windows.map(\.id), ["five_hour", "seven_day"])
        try FileManager.default.createDirectory(at: roots.claudeLimitsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(ClaudeStatusline.encodeBridgeFile(windows: windows, now: now)).write(to: roots.claudeLimitsFile)
        e.ingest(path: roots.claudeLimitsFile.path, now: now)

        guard case .available(let shown)? = e.snapshots(now: now).first?.limits else { return XCTFail("expected limits") }
        XCTAssertEqual(shown.map(\.usedPercent), [23.5, 88])
        XCTAssertEqual(LimitFormat.highestPercent(e.snapshots(now: now), now: now), 88)
        XCTAssertEqual(ClaudeStatusline.statusText(fromStatuslineInput: input, now: now), "Opus · 5-hour 24% · Weekly 88%")
        let bridge = String(decoding: try Data(contentsOf: roots.claudeLimitsFile), as: UTF8.self)
        XCTAssertFalse(bridge.contains("secret"), "the bridge file holds limits only")
        XCTAssertFalse(bridge.contains("abc"))
    }

    func testStatuslineWithoutRateLimits() {
        XCTAssertEqual(ClaudeStatusline.limits(fromStatuslineInput: Data(#"{"model":{"display_name":"Opus"}}"#.utf8), now: now), [])
        XCTAssertNil(ClaudeStatusline.limits(fromStatuslineInput: Data("garbage".utf8), now: now))
        XCTAssertEqual(ClaudeStatusline.limits(fromStatuslineInput: Data(#"{"rate_limits":{"five_hour":{"used_percentage":"n/a"},"seven_day":17}}"#.utf8), now: now), [])
        XCTAssertEqual(ClaudeStatusline.statusText(fromStatuslineInput: Data("garbage".utf8), now: now), "")
    }

    func testLimitPresentation() {
        XCTAssertEqual(LimitSeverity(usedPercent: 10), .calm)
        XCTAssertEqual(LimitSeverity(usedPercent: 60), .warning)
        XCTAssertEqual(LimitSeverity(usedPercent: 85), .critical)
        XCTAssertEqual(LimitSeverity(usedPercent: 140), .critical)
        XCTAssertEqual(LimitFormat.countdown(to: now.addingTimeInterval(3 * 86400 + 4 * 3600 + 60), now: now), "3d 4h")
        XCTAssertEqual(LimitFormat.countdown(to: now.addingTimeInterval(2 * 3600 + 14 * 60), now: now), "2h 14m")
        XCTAssertEqual(LimitFormat.countdown(to: now.addingTimeInterval(45 * 60), now: now), "45m")
        XCTAssertEqual(LimitFormat.countdown(to: now.addingTimeInterval(20), now: now), "<1m")
        XCTAssertNil(LimitFormat.countdown(to: now.addingTimeInterval(-1), now: now))
        XCTAssertNil(LimitFormat.countdown(to: nil, now: now))

        // A window whose reset time has passed describes the previous window; its number is not shown as current.
        let stale = LimitWindow(id: "primary", usedPercent: 99, windowMinutes: 300, resetsAt: now.addingTimeInterval(-60), observedAt: now.addingTimeInterval(-9000), source: "t")
        let live = LimitWindow(id: "secondary", usedPercent: 40, windowMinutes: 10080, resetsAt: now.addingTimeInterval(600), observedAt: now, source: "t")
        XCTAssertFalse(LimitFormat.isCurrent(stale, now: now))
        let snap = AgentSnapshot(agent: .codex, state: .idle, project: nil, sessionsToday: 0, today: [], week: [], limits: .available([stale, live]), plan: nil, lastActivity: nil)
        XCTAssertEqual(LimitFormat.highestPercent([snap], now: now), 40)

        XCTAssertEqual(LimitFormat.tokens(999), "999")
        XCTAssertEqual(LimitFormat.tokens(1500), "1.5K")
        XCTAssertEqual(LimitFormat.tokens(250_000), "250K")
        XCTAssertEqual(LimitFormat.tokens(3_400_000), "3.4M")
        XCTAssertEqual(LimitFormat.duration(125), "2m 5s")
        XCTAssertEqual(LimitFormat.duration(3725), "1h 2m")
        XCTAssertEqual(LimitFormat.modelName("claude-opus-4-5-20251101"), "claude-opus-4-5")
    }
}

final class AgentsPrivacyTests: AgentsFixtureCase {
    /// Proves that prompt text, response text, file contents and tool output never reach the model objects,
    /// the log sink, or the on-disk cache.
    func testNoPromptResponseOrFileContentLeaksAnywhere() throws {
        let t = Date().addingTimeInterval(-200)
        try write([
            Fixture.claudeUser(t),
            Fixture.claudeAssistant(t.addingTimeInterval(5), id: "m1"),
            Fixture.claudeAssistant(t.addingTimeInterval(190), id: "m2", stop: "end_turn"),
            line(["type": "summary", "summary": secretResponse, "timestamp": iso(t)]),
            line(["type": "last-prompt", "lastPrompt": secretPrompt, "timestamp": iso(t)]),
        ], to: claudeFile)
        try write([
            Fixture.codexMeta(t), Fixture.codexTurnContext(t), Fixture.codexEvent(t, "task_started"),
            Fixture.codexEvent(t.addingTimeInterval(1), "user_message", extra: ["message": secretPrompt]),
            Fixture.codexMessage(t.addingTimeInterval(2)),
            line(["type": "event_msg", "timestamp": iso(t.addingTimeInterval(3)), "payload": ["type": "item_completed", "item": ["aggregated_output": secretTool, "changes": ["/a/b.swift": ["unified_diff": secretFile]]]]]),
            Fixture.codexTokenCount(t.addingTimeInterval(4), total: 100, limits: ["primary": ["used_percent": 5, "window_minutes": 300, "resets_at": Int(Date().timeIntervalSince1970) + 500]]),
            Fixture.codexEvent(t.addingTimeInterval(195), "task_complete", extra: ["last_agent_message": secretResponse]),
        ], to: codexFile)
        try write([line(["id": "msg1", "sessionID": "ses1", "role": "assistant", "modelID": "m", "time": ["created": Int(t.timeIntervalSince1970 * 1000)],
                         "tokens": ["input": 1, "output": 1], "summary": secretResponse, "parts": [["text": secretPrompt]]])],
                  to: roots.openCode.appendingPathComponent("ses1/msg1.json"))
        try write([line(["type": "user.message", "timestamp": iso(t), "data": ["content": secretPrompt, "cwd": "/Users/dev/code/infra", "attachments": [["text": secretFile]]]]),
                   line(["type": "tool.execution_complete", "timestamp": iso(t), "data": ["result": secretTool, "outputTokens": 4]])],
                  to: roots.copilot.appendingPathComponent("cs1/events.jsonl"))

        var logged: [String] = []
        let e = engine()
        e.log = { logged.append($0) }
        var notices = e.initialScan()
        notices += e.tick()
        e.save()

        let snapshots = e.snapshots()
        XCTAssertEqual(Set(snapshots.map(\.agent)), Set(AgentKind.allCases), "all four fixtures were actually parsed")
        XCTAssertFalse(notices.isEmpty, "the long tasks produced completion notices")

        var surfaces: [String: String] = [:]
        surfaces["snapshots"] = String(reflecting: snapshots)
        surfaces["notices"] = String(reflecting: notices)
        surfaces["log"] = logged.joined(separator: "\n")
        surfaces["encoded state"] = String(decoding: e.encodedStateForTesting(), as: UTF8.self)
        surfaces["state file on disk"] = String(decoding: try Data(contentsOf: stateFile), as: UTF8.self)
        var dump = ""
        Swift.dump(e, to: &dump, maxDepth: 12)
        surfaces["engine memory dump"] = dump

        for (name, text) in surfaces {
            XCTAssertFalse(text.isEmpty, name)
            for secret in allSecrets {
                XCTAssertFalse(text.contains(secret), "\(name) contains \(secret)")
            }
            XCTAssertFalse(text.contains("/Users/dev/code"), "\(name) contains a full path; only the folder name may be kept")
        }
        // Sanity: the fixtures really did contain the secrets, so the assertions above mean something.
        let rawClaude = String(decoding: try Data(contentsOf: claudeFile), as: UTF8.self)
        XCTAssertTrue(allSecrets.allSatisfy { rawClaude.contains($0) })
    }

    func testFreeTextCannotMasqueradeAsAModelName() {
        var context = FileContext()
        let raw = line(["type": "assistant", "timestamp": iso(now), "message": ["id": "m", "model": "\(secretPrompt) with spaces in it", "usage": ["input_tokens": 5, "output_tokens": 5]]])
        let records = ClaudeCodeParser.parse(line: Data(raw.utf8), context: &context, path: "/x/s.jsonl")
        XCTAssertFalse(records.contains { if case .usage = $0 { return true } else { return false } })
        XCTAssertNil(context.model)
    }

    /// The agents feature has no network route at all (no credential-free one exists), so there is nothing to opt in to.
    /// This guards that: no file belonging to the feature may reference a networking API.
    func testAgentsFeatureContainsNoNetworkCode() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sources = testsDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let forbidden = ["URLSession", "URLRequest", "NWConnection", "CFNetwork", "http://", "https://api", "NSURLConnection", "WebSocket", "Keychain", "SecItem", "auth.json", "oauth", "access_token"]
        var checked = 0
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let isAgentsFile = url.path.contains("/Agents/") || url.lastPathComponent.hasPrefix("Agents")
            guard isAgentsFile else { continue }
            checked += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for word in forbidden {
                XCTAssertFalse(text.range(of: word, options: .caseInsensitive) != nil && !text.contains("// allow: \(word)"),
                               "\(url.lastPathComponent) references \(word)")
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 5, "the agents sources were found and scanned")
    }

    func testEngineOffMeansNothingIsReadOrWritten() {
        // With the feature off the app never constructs an engine; constructing one must itself be inert.
        let e = engine()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.path))
        e.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.path), "nothing learned, nothing written")
    }
}
