import XCTest
@testable import IsleCore

final class KwikBatteryLinkTests: XCTestCase {
    func testSummaryRequestNamesItsVersionAndSender() {
        let info = KwikBatteryLink.summaryRequest()
        XCTAssertEqual(info["v"] as? Int, 1)
        XCTAssertEqual(info["source"] as? String, "isle")
        XCTAssertEqual(KwikBatteryLink.summaryRequestNotification, "com.kwikbattery.requestSummary")
    }

    func testASnapshotIsFreshOnlyBrieflyAndOnlyIfThereIsOne() {
        let now = Date()
        XCTAssertTrue(KwikBatteryLink.isFresh(receivedAt: now.addingTimeInterval(-3), now: now))
        XCTAssertTrue(KwikBatteryLink.isFresh(receivedAt: now.addingTimeInterval(-KwikBatteryLink.freshFor), now: now))
        XCTAssertFalse(KwikBatteryLink.isFresh(receivedAt: now.addingTimeInterval(-KwikBatteryLink.freshFor - 1), now: now))
        XCTAssertFalse(KwikBatteryLink.isFresh(receivedAt: nil, now: now))
    }
}

final class KwikBatterySummaryTests: XCTestCase {
    private func message(_ overrides: [String: Any] = [:]) -> [AnyHashable: Any] {
        var m: [String: Any] = ["v": 1, "source": "kwikbattery", "percent": 33, "state": "discharging", "timeTitle": "TIME LEFT",
                                "timeValue": "56m", "sourceTitle": "Battery", "sourceDetail": "33%", "watts": 14.1]
        for (k, v) in overrides { m[k] = v }
        return m
    }

    func testValidSnapshotParses() {
        let s = KwikBatterySummary.parse(message())
        XCTAssertEqual(s, KwikBatterySummary(percent: 33, state: .discharging, timeTitle: "TIME LEFT", timeValue: "56m",
                                             watts: 14.1, sourceTitle: "Battery", sourceDetail: "33%"))
    }

    func testWrongSenderVersionOrMissingFieldsAreDropped() {
        XCTAssertNil(KwikBatterySummary.parse(nil))
        XCTAssertNil(KwikBatterySummary.parse(message(["source": "glance2"])))
        XCTAssertNil(KwikBatterySummary.parse(message(["v": 2])))
        XCTAssertNil(KwikBatterySummary.parse(message(["percent": "33"])))
        XCTAssertNil(KwikBatterySummary.parse(message(["timeValue": ""])))
        XCTAssertNil(KwikBatterySummary.parse(message(["sourceTitle": 7])))
    }

    func testLevelAndStateAreChecked() {
        XCTAssertNil(KwikBatterySummary.parse(message(["percent": 101])))
        XCTAssertNil(KwikBatterySummary.parse(message(["percent": -1])))
        XCTAssertNil(KwikBatterySummary.parse(message(["state": "exploding"])))
        for state in ["charging", "discharging", "full", "onAC", "noBattery"] {
            XCTAssertNotNil(KwikBatterySummary.parse(message(["state": state])), state)
        }
    }

    func testWattsAreOptionalAndMustBeSane() {
        XCTAssertEqual(KwikBatterySummary.parse(message())?.watts, 14.1)
        var noWatts = message(); noWatts["watts"] = nil
        XCTAssertNotNil(KwikBatterySummary.parse(noWatts))
        XCTAssertNil(KwikBatterySummary.parse(noWatts)?.watts)
        XCTAssertNil(KwikBatterySummary.parse(message(["watts": Double.nan]))?.watts)
        XCTAssertNil(KwikBatterySummary.parse(message(["watts": -3.0]))?.watts)
        XCTAssertNil(KwikBatterySummary.parse(message(["watts": 5_000.0]))?.watts)
    }

    func testTextIsCleanedAndCut() {
        let s = KwikBatterySummary.parse(message(["timeValue": "5\n6m", "sourceDetail": String(repeating: "x", count: 40)]))
        XCTAssertEqual(s?.timeValue, "56m")
        XCTAssertEqual(s?.sourceDetail.count, 16)
    }
}

final class IslandIntegrationTests: XCTestCase {
    func testAnAppSupportsIntegrationOnlyIfItSaysSo() {
        XCTAssertTrue(IslandIntegration.supports(["IslandIntegration": 1]))
        XCTAssertTrue(IslandIntegration.supports(["IslandIntegration": 2]))
        XCTAssertFalse(IslandIntegration.supports(["IslandIntegration": 0]))
        XCTAssertFalse(IslandIntegration.supports(["IslandIntegration": "1"]))
        XCTAssertFalse(IslandIntegration.supports([:]))
        XCTAssertFalse(IslandIntegration.supports(nil))
        XCTAssertFalse(IslandIntegration.supports(["IslandIntegration": 1], minimum: 2))
    }
}

final class GlanceLinkTests: XCTestCase {
    private func message(_ overrides: [String: Any] = [:]) -> [AnyHashable: Any] {
        var m: [String: Any] = ["v": 1, "source": "glance2", "enabled": true, "locked": false, "hasPassword": true,
                                "history": [["t": 1_700_000_000.0, "place": "Safari", "result": "Unlocked", "ok": true]]]
        for (k, v) in overrides { m[k] = v }
        return m
    }

    func testValidStatusParses() {
        let s = GlanceStatus.parse(message())
        XCTAssertEqual(s?.light, .ready)
        XCTAssertEqual(s?.history.first?.place, "Safari")
        XCTAssertEqual(s?.history.first?.ok, true)
    }

    func testLightAndUnlockFollowTheState() {
        XCTAssertEqual(GlanceStatus.parse(message(["enabled": false]))?.light, .off)
        let locked = GlanceStatus.parse(message(["locked": true]))
        XCTAssertEqual(locked?.light, .needsAttention)
        XCTAssertEqual(locked?.canUnlock, true)
        let noPassword = GlanceStatus.parse(message(["locked": true, "hasPassword": false]))
        XCTAssertEqual(noPassword?.light, .needsAttention)
        XCTAssertEqual(noPassword?.canUnlock, false)
    }

    func testWrongSenderVersionOrShapeIsDropped() {
        XCTAssertNil(GlanceStatus.parse(message(["source": "kwikbattery"])))
        XCTAssertNil(GlanceStatus.parse(message(["v": 2])))
        XCTAssertNil(GlanceStatus.parse(message(["locked": "yes"])))
        XCTAssertNil(GlanceStatus.parse(nil))
    }

    func testHistoryIsCleanedLimitedAndBadEntriesDropped() {
        let long = String(repeating: "a", count: 200)
        let entries: [[String: Any]] = [
            ["t": 1_700_000_000.0, "place": "Safari\n", "result": long, "ok": true],
            ["t": -5.0, "place": "Notes", "result": "Unlocked", "ok": true],
            ["t": 1_700_000_001.0, "place": "", "result": "Unlocked", "ok": true],
            ["t": 1_700_000_002.0, "place": "Notes", "result": "Unlocked"],
        ]
        let s = GlanceStatus.parse(message(["history": entries]))
        XCTAssertEqual(s?.history.count, 1)
        XCTAssertEqual(s?.history.first?.place, "Safari")
        XCTAssertEqual(s?.history.first?.result.count, GlanceStatus.maxText)

        let many = (0..<50).map { ["t": 1_700_000_000.0 + Double($0), "place": "P", "result": "R", "ok": true] as [String: Any] }
        XCTAssertEqual(GlanceStatus.parse(message(["history": many]))?.history.count, GlanceStatus.maxHistory)
    }

    func testCommandNamesItsVersionAndSender() {
        XCTAssertEqual(GlanceLink.command()["v"] as? Int, 1)
        XCTAssertEqual(GlanceLink.command()["source"] as? String, "isle")
    }
}
