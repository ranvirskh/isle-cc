import XCTest
@testable import IsleCore

final class ExternalPopupTests: XCTestCase {
    private func message(_ overrides: [String: Any] = [:]) -> [AnyHashable: Any] {
        var m: [String: Any] = ["v": 1, "source": "glance2", "id": "scan.ok", "symbol": "checkmark.circle.fill", "title": "Unlocked"]
        for (k, v) in overrides { m[k] = v }
        return m
    }

    func testValidMessageBecomesAnExternalPopup() {
        let item = ExternalPopup.parse(message(["subtitle": "Face matched", "batteries": [["label": "L", "percent": 80]]]))
        XCTAssertEqual(item?.id, "glance2.scan.ok")
        XCTAssertEqual(item?.kind, .external)
        XCTAssertEqual(item?.symbol, "checkmark.circle.fill")
        XCTAssertEqual(item?.title, "Unlocked")
        XCTAssertEqual(item?.subtitle, "Face matched")
        XCTAssertEqual(item?.batteries, [PopupItem.BatteryReading(label: "L", percent: 80)])
    }

    func testUnknownSenderOrVersionIsDropped() {
        XCTAssertNil(ExternalPopup.parse(message(["source": "someotherapp"])))
        XCTAssertNil(ExternalPopup.parse(message(["source": 5])))
        XCTAssertNil(ExternalPopup.parse(message(["v": 2])))
        XCTAssertNil(ExternalPopup.parse(message(["v": "1"])))
        XCTAssertNil(ExternalPopup.parse(nil))
    }

    func testBadIDsAreDropped() {
        for id in ["", "has space", "slash/inside", "naïve", String(repeating: "a", count: 65)] {
            XCTAssertNil(ExternalPopup.parse(message(["id": id])), "id \(id.debugDescription)")
        }
        XCTAssertNotNil(ExternalPopup.parse(message(["id": String(repeating: "a", count: 64)])))
    }

    func testIconMustLookLikeASymbolName() {
        for symbol in ["", "Checkmark", "../etc", "a b", "face id", String(repeating: "a", count: 41)] {
            XCTAssertNil(ExternalPopup.parse(message(["symbol": symbol])), "symbol \(symbol.debugDescription)")
        }
        XCTAssertNotNil(ExternalPopup.parse(message(["symbol": "faceid"])))
        XCTAssertNotNil(ExternalPopup.parse(message(["symbol": "battery.100percent"])))
    }

    func testTitleIsRequiredCleanedAndTruncated() {
        XCTAssertNil(ExternalPopup.parse(message(["title": ""])))
        XCTAssertNil(ExternalPopup.parse(message(["title": "   "])))
        XCTAssertNil(ExternalPopup.parse(message(["title": "\n\t\u{7}"])))
        XCTAssertNil(ExternalPopup.parse(message(["title": 42])))
        XCTAssertEqual(ExternalPopup.parse(message(["title": "Line one\nline two"]))?.title, "Line oneline two")
        XCTAssertEqual(ExternalPopup.parse(message(["title": String(repeating: "x", count: 100)]))?.title.count, 40)
        XCTAssertEqual(ExternalPopup.parse(message(["subtitle": String(repeating: "y", count: 200)]))?.subtitle.count, 80)
    }

    func testBatteriesAreRangeCheckedAndCapped() {
        let readings: [[String: Any]] = [["label": "A", "percent": 101], ["label": "B", "percent": -1], ["label": "C", "percent": 50],
                                         ["label": "D", "percent": 60], ["label": "E", "percent": 70], ["label": "F", "percent": 80],
                                         ["label": "G", "percent": 90]]
        let item = ExternalPopup.parse(message(["batteries": readings]))
        // Only the first four entries are considered; the two out-of-range ones among them are dropped.
        XCTAssertEqual(item?.batteries.map(\.label), ["C", "D"])
        XCTAssertEqual(ExternalPopup.parse(message(["batteries": [["label": "L", "percent": "80"]]]))?.batteries, [])
    }

    func testLimiterAllowsABurstThenBlocksUntilTheWindowPasses() {
        var limiter = ExternalPopupLimiter(limit: 3, window: 2)
        let t0 = Date()
        XCTAssertTrue(limiter.allow(now: t0))
        XCTAssertTrue(limiter.allow(now: t0.addingTimeInterval(0.1)))
        XCTAssertTrue(limiter.allow(now: t0.addingTimeInterval(0.2)))
        XCTAssertFalse(limiter.allow(now: t0.addingTimeInterval(0.3)))
        XCTAssertTrue(limiter.allow(now: t0.addingTimeInterval(2.5)))
    }
}
