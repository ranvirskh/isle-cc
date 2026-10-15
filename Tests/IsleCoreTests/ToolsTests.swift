import XCTest
@testable import IsleCore

final class ToolsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testKeepAwakeDurations() {
        XCTAssertNil(KeepAwakeDuration.indefinite.seconds)
        XCTAssertEqual(KeepAwakeDuration.hour2.seconds, 7200)
        XCTAssertEqual(KeepAwakeDuration.min15.label, "15m")
        XCTAssertEqual(KeepAwakeDuration.hour4.label, "4h")
    }

    func testClipboardKeepsNewestFirstAndDedupes() {
        var h = ClipboardHistory(capacity: 3)
        h.add("a", types: [], now: t0); h.add("b", types: [], now: t0); h.add("a", types: [], now: t0)
        XCTAssertEqual(h.items.map(\.text), ["a", "b"])
        h.add("c", types: [], now: t0); h.add("d", types: [], now: t0)
        XCTAssertEqual(h.items.map(\.text), ["d", "c", "a"])
    }

    func testClipboardSkipsSecretsBlanksAndHuge() {
        var h = ClipboardHistory()
        XCTAssertFalse(h.add("hunter2", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], now: t0))
        XCTAssertFalse(h.add("  \n ", types: [], now: t0))
        XCTAssertFalse(h.add(String(repeating: "x", count: ClipboardHistory.maxLength + 1), types: [], now: t0))
        XCTAssertTrue(h.items.isEmpty)
    }

    func testClipboardPreviewAndRemove() {
        var h = ClipboardHistory()
        h.add("\n  first line \nsecond", types: [], now: t0)
        XCTAssertEqual(h.items[0].preview, "first line")
        h.remove(id: h.items[0].id)
        XCTAssertTrue(h.items.isEmpty)
    }

    func testCPUUsage() {
        let a = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let b = CPUTicks(user: 150, system: 80, idle: 970, nice: 0)
        XCTAssertEqual(CPUTicks.usage(from: a, to: b)!, 80.0 / 200.0, accuracy: 0.0001)
        XCTAssertNil(CPUTicks.usage(from: a, to: a))
    }

    func testNetRates() {
        let r = NetCounters.rates(from: .init(rx: 1000, tx: 500), to: .init(rx: 3000, tx: 500), seconds: 2)!
        XCTAssertEqual(r.down, 1000); XCTAssertEqual(r.up, 0)
        let reset = NetCounters.rates(from: .init(rx: 5000, tx: 5000), to: .init(rx: 10, tx: 10), seconds: 1)!
        XCTAssertEqual(reset.down, 0)
        XCTAssertNil(NetCounters.rates(from: .init(rx: 0, tx: 0), to: .init(rx: 1, tx: 1), seconds: 0))
    }

    func testStatsFormat() {
        XCTAssertEqual(StatsFormat.rate(1_500_000), "1.5 MB/s")
        XCTAssertEqual(StatsFormat.rate(340_000), "340 KB/s")
        XCTAssertEqual(StatsFormat.bytes(16_000_000_000), "16.0 GB")
        XCTAssertEqual(StatsFormat.percent(0.456), "46%")
    }

    func testVisibleTabsOrderAndHome() {
        XCTAssertEqual(IslandTab.visible(enabled: [.shelf]), [.home, .shelf])
        XCTAssertEqual(IslandTab.visible(enabled: [.shelf, .tools, .agents]), [.home, .shelf, .tools, .agents])
        XCTAssertEqual(IslandTab.visible(enabled: [.shelf, .tools, .agents], order: [.agents, .tools]), [.home, .agents, .tools, .shelf])
        XCTAssertEqual(IslandTab.visible(enabled: [], order: [.shelf]), [.home])
        XCTAssertEqual(IslandTab.visible(enabled: Set(IslandTab.allCases)).count, IslandTab.allCases.count)
    }
}

final class HUDTests: XCTestCase {
    func testParseKeyDownAndUp() {
        // Volume up, key down: code 0, flags 0x0A00. Key up: 0x0B00. Repeat bit set.
        XCTAssertEqual(MediaKeyPress.parse(data1: (0 << 16) | 0x0A00), MediaKeyPress(key: .volumeUp, isDown: true, isRepeat: false))
        XCTAssertEqual(MediaKeyPress.parse(data1: (3 << 16) | 0x0B00), MediaKeyPress(key: .brightnessDown, isDown: false, isRepeat: false))
        XCTAssertEqual(MediaKeyPress.parse(data1: (7 << 16) | 0x0A01), MediaKeyPress(key: .mute, isDown: true, isRepeat: true))
    }

    func testParseIgnoresOtherKeys() {
        XCTAssertNil(MediaKeyPress.parse(data1: (16 << 16) | 0x0A00))   // play/pause
        XCTAssertNil(MediaKeyPress.parse(data1: (0 << 16) | 0x0C00))    // unknown state
    }

    func testSteps() {
        XCTAssertEqual(HUDStep.next(0.5, up: true, fine: false, percent: 7), 0.57, accuracy: 1e-9)
        XCTAssertEqual(HUDStep.next(0.5, up: false, fine: false, percent: 7), 0.43, accuracy: 1e-9)
        XCTAssertEqual(HUDStep.next(1, up: false, fine: false, percent: 7), 0.93, accuracy: 1e-9)
        XCTAssertEqual(HUDStep.next(0.98, up: true, fine: false, percent: 7), 1)
        XCTAssertEqual(HUDStep.next(0.03, up: false, fine: false, percent: 7), 0)
        XCTAssertEqual(HUDStep.next(0.5, up: true, fine: true, percent: 8), 0.52, accuracy: 1e-9)
        XCTAssertEqual(HUDStep.next(0.5, up: true, fine: true, percent: 1), 0.505, accuracy: 1e-9)
        XCTAssertEqual(HUDStep.next(0.5, up: true, fine: false, percent: 500), 0.75, accuracy: 1e-9)   // clamped to 25%
    }

    func testSymbolsAndLevel() {
        XCTAssertEqual(HUDState(kind: .volume, level: 0.2).symbol, "speaker.wave.1.fill")
        XCTAssertEqual(HUDState(kind: .volume, level: 0.9).symbol, "speaker.wave.3.fill")
        XCTAssertEqual(HUDState(kind: .volume, level: 0.5, muted: true).symbol, "speaker.slash.fill")
        XCTAssertEqual(HUDState(kind: .volume, level: 0.5, muted: true).shownLevel, 0)
        XCTAssertEqual(HUDState(kind: .brightness, level: 0.8).symbol, "sun.max.fill")
        XCTAssertEqual(HUDState(kind: .brightness, level: 3).level, 1)
    }
}

final class ScriptsAndUpdatesTests: XCTestCase {
    func testScriptCodingRoundTrip() {
        let items = [ScriptItem(name: "Hi", command: "echo hi"), ScriptItem(name: "", command: "  ls -la /tmp  ")]
        let back = ScriptItem.decode(ScriptItem.encode(items))
        XCTAssertEqual(back.map(\.name), ["Hi", ""])
        XCTAssertEqual(back.map(\.command), ["echo hi", "  ls -la /tmp  "])
        XCTAssertEqual(back[1].displayName, "ls -la /tmp")
        XCTAssertEqual(ScriptItem.decode([["only one"], ["a", "b", "c"]]).count, 0)
        XCTAssertFalse(ScriptItem(name: "x", command: "  ").isRunnable)
    }

    func testOutputKeepsTheTail() {
        XCTAssertEqual(ScriptOutput.trimmed("hello\n\n"), "hello")
        let long = String(repeating: "a", count: 5_000) + "END"
        let t = ScriptOutput.trimmed(long)
        XCTAssertTrue(t.hasSuffix("END"))
        XCTAssertEqual(t.count, ScriptOutput.maxCharacters + 1)
    }

    func testVersionCompare() {
        XCTAssertTrue(AppVersion.isNewer("1.10.0", than: "1.2.0"))
        XCTAssertTrue(AppVersion.isNewer("v1.2.1", than: "1.2.0"))
        XCTAssertTrue(AppVersion.isNewer("2", than: "1.9.9"))
        XCTAssertFalse(AppVersion.isNewer("1.2.0", than: "1.2"))
        XCTAssertFalse(AppVersion.isNewer("1.1.9", than: "1.2.0"))
    }

    func testReleaseParsing() {
        let json = #"{"tag_name":"v1.3.0","html_url":"https://github.com/o/r/releases/tag/v1.3.0","body":"notes","draft":false,"prerelease":false}"#
        let info = ReleaseInfo.parse(Data(json.utf8))
        XCTAssertEqual(info?.version, "1.3.0")
        XCTAssertEqual(info?.notes, "notes")
        XCTAssertNil(ReleaseInfo.parse(Data(#"{"tag_name":"v2","html_url":"https://x.y","prerelease":true}"#.utf8)))
        XCTAssertNil(ReleaseInfo.parse(Data("nope".utf8)))
    }

    func testNewHUDKinds() {
        XCTAssertEqual(MediaKeyPress.parse(data1: (21 << 16) | 0x0A00)?.key, .keyboardUp)
        XCTAssertEqual(MediaKeyPress.parse(data1: (22 << 16) | 0x0B00)?.key, .keyboardDown)
        XCTAssertEqual(HUDState(kind: .microphone, level: 0).symbol, "mic.slash.fill")
        XCTAssertEqual(HUDState(kind: .keyboard, level: 0.4).title, "Keyboard backlight")
    }
}

final class CompletionRestoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testRestoredTaskKeepsItsRealStart() {
        var t = CompletionTracker(threshold: 120)
        t.restore([.init(agent: "claudeCode", sessionID: "s", project: "p", startedAt: t0, lastActivity: t0.addingTimeInterval(100))], now: t0.addingTimeInterval(110))
        let end = t0.addingTimeInterval(200)
        let n = t.record(ActivityEvent(agent: .claudeCode, timestamp: end, sessionID: "s", project: "p", signal: .closed), now: end.addingTimeInterval(1))
        XCTAssertEqual(n?.duration ?? 0, 200, accuracy: 0.001)
    }

    func testStaleRestoredTaskIsDropped() {
        var t = CompletionTracker(threshold: 120)
        t.restore([.init(agent: "claudeCode", sessionID: "s", project: nil, startedAt: t0, lastActivity: t0)], now: t0.addingTimeInterval(5_000))
        XCTAssertTrue(t.openSessions().isEmpty)
    }

    func testOpenSessionsRoundTrip() {
        var t = CompletionTracker(threshold: 120)
        _ = t.record(ActivityEvent(agent: .claudeCode, timestamp: t0, sessionID: "s", project: "p", signal: .opened), now: t0)
        let saved = t.openSessions()
        XCTAssertEqual(saved.count, 1)
        var u = CompletionTracker(threshold: 120)
        u.restore(saved, now: t0.addingTimeInterval(10))
        XCTAssertEqual(u.openSessions(), saved)
    }
}

final class MonthGridTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1   // Sunday
        return c
    }

    func testOctober2026Layout() {
        let oct = cal.date(from: DateComponents(year: 2026, month: 10, day: 15))!
        let weeks = MonthGrid.weeks(for: oct, calendar: cal)
        // 1 Oct 2026 is a Thursday: 4 empty slots first; 31 days; 5 weeks.
        XCTAssertEqual(weeks.count, 5)
        XCTAssertEqual(weeks[0].prefix(4).compactMap { $0 }.count, 0)
        XCTAssertEqual(cal.component(.day, from: weeks[0][4]!), 1)
        XCTAssertEqual(weeks.flatMap { $0 }.compactMap { $0 }.count, 31)
        XCTAssertTrue(weeks.allSatisfy { $0.count == 7 })
    }

    func testMondayFirstAndHeaders() {
        var c = cal; c.firstWeekday = 2
        let oct = c.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        XCTAssertEqual(c.component(.day, from: MonthGrid.weeks(for: oct, calendar: c)[0][3]!), 1)   // Thursday is the 4th column
        XCTAssertEqual(MonthGrid.weekdayHeaders(calendar: c).count, 7)
        XCTAssertEqual(MonthGrid.weekdayHeaders(calendar: c).first, "M")
    }
}

final class ReminderListsTests: XCTestCase {
    func testPicksTheBusiestList() {
        XCTAssertEqual(ReminderLists.pick(counts: ["a": 2, "b": 9, "c": 4], preferred: "a"), "b")
    }

    func testTiePrefersTheDefaultThenIsStable() {
        XCTAssertEqual(ReminderLists.pick(counts: ["a": 3, "b": 3, "c": 1], preferred: "b"), "b")
        XCTAssertEqual(ReminderLists.pick(counts: ["z": 3, "b": 3], preferred: "q"), "b")
        XCTAssertEqual(ReminderLists.pick(counts: ["a": 0, "b": 0], preferred: nil), "a")
    }

    func testNoListsGivesNil() {
        XCTAssertNil(ReminderLists.pick(counts: [:], preferred: "a"))
    }
}

final class LiveLayoutTests_Equalizer: XCTestCase {
    func testEqualizerYieldsToUsageReadout() {
        let withEq = LiveLayout.side(mediaLive: true, privacyIcons: 0, chargingLive: false)
        let withUsage = LiveLayout.side(mediaLive: true, privacyIcons: 0, chargingLive: false, usageLive: true)
        // Usage replaces the equalizer in the right slot: 12 + 50 = 62 (the cover side is 44).
        XCTAssertEqual(withUsage, 62)
        XCTAssertEqual(withEq, max(LiveLayout.coverSide, 12 + 22))
    }
}

final class ResetLabelTests: XCTestCase {
    func testResetLabelIsCompact() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ClaudeUsage.resetLabel(until: now.addingTimeInterval(6.9 * 3600), now: now), "7h")
        XCTAssertEqual(ClaudeUsage.resetLabel(until: now.addingTimeInterval(86400 * 3 + 4.2 * 3600), now: now), "3d 4h")
        XCTAssertEqual(ClaudeUsage.resetLabel(until: now.addingTimeInterval(86400 * 2 + 60), now: now), "2d")
        XCTAssertEqual(ClaudeUsage.resetLabel(until: now.addingTimeInterval(1500), now: now), "25m")
    }
}
