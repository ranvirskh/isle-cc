import XCTest
@testable import IsleCore

final class UsageActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRecentSessionWriteMeansActiveWhateverAppIsInFront() {
        // A Claude Code session working in the background while Safari, Xcode or Finder is in front.
        for front in [nil, "com.apple.Safari", "com.apple.dt.Xcode", "com.apple.finder", "com.apple.Terminal"] {
            XCTAssertTrue(UsageActivity.isActive(lastSessionWrite: now.addingTimeInterval(-5), frontmostBundleID: front, now: now), "front: \(front ?? "nil")")
        }
    }

    func testAnOldWriteIsNotActive() {
        XCTAssertFalse(UsageActivity.isActive(lastSessionWrite: now.addingTimeInterval(-UsageActivity.activeWindow - 1), frontmostBundleID: nil, now: now))
        XCTAssertFalse(UsageActivity.isActive(lastSessionWrite: now.addingTimeInterval(-3600), frontmostBundleID: "com.apple.Terminal", now: now))
    }

    func testTheWindowEdge() {
        XCTAssertTrue(UsageActivity.isActive(lastSessionWrite: now.addingTimeInterval(-UsageActivity.activeWindow + 1), frontmostBundleID: nil, now: now))
        XCTAssertFalse(UsageActivity.isActive(lastSessionWrite: now.addingTimeInterval(-UsageActivity.activeWindow), frontmostBundleID: nil, now: now))
    }

    func testJustHavingATerminalOrEditorInFrontIsNoLongerEnough() {
        // The old rule showed the readout for any terminal or AI editor in front. Idle terminals don't spend the limit.
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode", "dev.zed.Zed", "com.openai.chat"] {
            XCTAssertFalse(UsageActivity.isActive(lastSessionWrite: nil, frontmostBundleID: id, now: now), id)
        }
    }

    func testTheClaudeAppInFrontCountsEvenWithoutSessionWrites() {
        XCTAssertTrue(UsageActivity.isActive(lastSessionWrite: nil, frontmostBundleID: "com.anthropic.claudefordesktop", now: now))
        XCTAssertTrue(UsageActivity.isActive(lastSessionWrite: now.addingTimeInterval(-9999), frontmostBundleID: "com.anthropic.claudefordesktop", now: now))
    }

    func testNothingHappeningIsNotActive() {
        XCTAssertFalse(UsageActivity.isActive(lastSessionWrite: nil, frontmostBundleID: nil, now: now))
    }

    func testAFutureDatedWriteNeverCounts() {
        XCTAssertFalse(UsageActivity.isActive(lastSessionWrite: now.addingTimeInterval(3600), frontmostBundleID: nil, now: now))
        XCTAssertNil(UsageActivity.expiry(lastSessionWrite: now.addingTimeInterval(3600), now: now))
        // A few seconds of clock skew is tolerated.
        XCTAssertTrue(UsageActivity.isActive(lastSessionWrite: now.addingTimeInterval(2), frontmostBundleID: nil, now: now))
    }

    func testExpiryIsWhenTheRecentWriteStopsCounting() {
        let w = now.addingTimeInterval(-30)
        XCTAssertEqual(UsageActivity.expiry(lastSessionWrite: w, now: now), w.addingTimeInterval(UsageActivity.activeWindow))
        XCTAssertNil(UsageActivity.expiry(lastSessionWrite: nil, now: now))
        XCTAssertNil(UsageActivity.expiry(lastSessionWrite: now.addingTimeInterval(-500), now: now), "already expired")
        // Right at the expiry moment it is no longer active, which is what the timer relies on.
        let at = UsageActivity.expiry(lastSessionWrite: w, now: now)!
        XCTAssertFalse(UsageActivity.isActive(lastSessionWrite: w, frontmostBundleID: nil, now: at))
    }

    func testTheFiveHourLimitIsShownAtAnyLevelWhileActive() {
        let w = LimitWindow(id: "five_hour", usedPercent: 12, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600), observedAt: now, source: "test")
        XCTAssertTrue(ClaudeUsage.displayed([w], now: now, alwaysShowFiveHour: false).isEmpty, "idle and low: hidden")
        XCTAssertEqual(ClaudeUsage.displayed([w], now: now, alwaysShowFiveHour: true).map(\.id), ["five_hour"], "actively used: shown even at 12%")
    }

    func testHoursLeftLabel() {
        let now = Date()
        func label(_ minutes: Double) -> String { ClaudeUsage.hoursLeftLabel(until: now.addingTimeInterval(minutes * 60), now: now) }
        XCTAssertEqual(label(300), "5h")
        XCTAssertEqual(label(160), "2h 40m")
        XCTAssertEqual(label(90), "1h 30m")
        XCTAssertEqual(label(60), "1h")
        XCTAssertEqual(label(5), "5m")
        XCTAssertEqual(label(4.2), "5m")
        XCTAssertEqual(ClaudeUsage.hoursLeftLabel(until: now.addingTimeInterval(-10), now: now), "0m")
    }

    func testTerminalWithClaudeRunningCountsAsOpen() {
        let now = Date()
        XCTAssertTrue(UsageActivity.isActive(lastSessionWrite: nil, frontmostBundleID: "com.apple.Terminal", claudeProcessRunning: true, now: now))
        XCTAssertFalse(UsageActivity.isActive(lastSessionWrite: nil, frontmostBundleID: "com.apple.Terminal", claudeProcessRunning: false, now: now))
        XCTAssertFalse(UsageActivity.isActive(lastSessionWrite: nil, frontmostBundleID: "com.apple.Safari", claudeProcessRunning: true, now: now))
    }

    func testLabelChangeDatesAreFewAndOrdered() {
        let now = Date()
        let d = ClaudeUsage.labelChangeDates(until: now.addingTimeInterval(5 * 3600), now: now)
        XCTAssertLessThan(d.count, 305)
        XCTAssertEqual(d, d.sorted())
        XCTAssertEqual(d.last, now.addingTimeInterval(5 * 3600))
    }
}
