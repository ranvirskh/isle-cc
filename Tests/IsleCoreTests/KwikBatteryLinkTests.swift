import XCTest
@testable import IsleCore

final class KwikBatteryLinkTests: XCTestCase {
    func testRequestCarriesTheAnchorRectangle() {
        let info = KwikBatteryLink.request(anchor: CGRect(x: 100, y: 800, width: 40, height: 14))
        XCTAssertEqual(info["v"] as? Int, 1)
        XCTAssertEqual(info["source"] as? String, "isle")
        XCTAssertEqual(info["x"] as? Double, 100)
        XCTAssertEqual(info["y"] as? Double, 800)
        XCTAssertEqual(info["w"] as? Double, 40)
        XCTAssertEqual(info["h"] as? Double, 14)
    }

    func testRequestWithoutAUsableAnchorOmitsIt() {
        for anchor in [nil, CGRect(x: 1, y: 1, width: 0, height: 10), CGRect(x: CGFloat.nan, y: 1, width: 5, height: 5),
                       CGRect(x: 1, y: CGFloat.infinity, width: 5, height: 5)] {
            let info = KwikBatteryLink.request(anchor: anchor)
            XCTAssertEqual(info["v"] as? Int, 1)
            XCTAssertNil(info["x"])
            XCTAssertNil(info["w"])
        }
    }
}
