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

    func testVisibleTabs() {
        XCTAssertEqual(IslandTab.visible(agents: false, clipboard: false, stats: false, tools: false), [.home, .shelf])
        XCTAssertEqual(IslandTab.visible(agents: true, clipboard: true, stats: true, tools: true), IslandTab.allCases)
    }
}
