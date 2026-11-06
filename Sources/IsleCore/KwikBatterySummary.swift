import Foundation

/// The battery summary KwikBattery sends for Isle to draw in its island: level, time left and power flow.
///
/// KwikBattery posts it as a `DistributedNotificationCenter` notification named `notificationName`, in answer to Isle's request
/// (`KwikBatteryLink.summaryRequest`). Any process can post one, so it is validated like `ExternalPopup`: known sender, version 1,
/// level 0–100, a known state, short plain strings, a sane wattage. Anything else is dropped.
public struct KwikBatterySummary: Equatable {
    public enum State: String { case charging, discharging, full, onAC, noBattery }

    public static let notificationName = "com.ranvirskh.island.battery"

    public var percent: Int
    public var state: State
    /// "TIME LEFT" or "UNTIL FULL".
    public var timeTitle: String
    /// "56m", "1h 15m", "Calculating", "Full"…
    public var timeValue: String
    /// What the Mac is drawing right now, when known.
    public var watts: Double?
    /// "Battery" or "Adapter", and its detail ("33%", "96 W").
    public var sourceTitle: String
    public var sourceDetail: String

    public init(percent: Int, state: State, timeTitle: String, timeValue: String, watts: Double?, sourceTitle: String, sourceDetail: String) {
        self.percent = percent
        self.state = state
        self.timeTitle = timeTitle
        self.timeValue = timeValue
        self.watts = watts
        self.sourceTitle = sourceTitle
        self.sourceDetail = sourceDetail
    }

    public static func parse(_ info: [AnyHashable: Any]?) -> KwikBatterySummary? {
        guard let info,
              (info["v"] as? Int) == 1, (info["source"] as? String) == "kwikbattery",
              let percent = info["percent"] as? Int, (0...100).contains(percent),
              let rawState = info["state"] as? String, let state = State(rawValue: rawState),
              let timeTitle = ExternalPopup.clean(info["timeTitle"], limit: 12), !timeTitle.isEmpty,
              let timeValue = ExternalPopup.clean(info["timeValue"], limit: 12), !timeValue.isEmpty,
              let sourceTitle = ExternalPopup.clean(info["sourceTitle"], limit: 12), !sourceTitle.isEmpty,
              let sourceDetail = ExternalPopup.clean(info["sourceDetail"], limit: 16)
        else { return nil }
        let watts = (info["watts"] as? Double).flatMap { $0.isFinite && $0 >= 0 && $0 < 1_000 ? $0 : nil }
        return KwikBatterySummary(percent: percent, state: state, timeTitle: timeTitle, timeValue: timeValue,
                                  watts: watts, sourceTitle: sourceTitle, sourceDetail: sourceDetail)
    }
}
