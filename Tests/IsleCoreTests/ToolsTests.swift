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
