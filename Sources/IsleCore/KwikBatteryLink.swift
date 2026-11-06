import Foundation

/// How Isle gets its battery card from KwikBattery.
///
/// Isle draws the card itself, inside the island, so it opens and closes with the island and looks like the rest of Isle. KwikBattery
/// only supplies the numbers: Isle posts `summaryRequestNotification` and KwikBattery answers with a `KwikBatterySummary`. Isle only
/// offers the card when KwikBattery is installed and declares it understands this (see `IslandIntegration`).
public enum KwikBatteryLink {
    public static let bundleID = "com.kwikbattery.KwikBattery"
    public static let summaryRequestNotification = "com.kwikbattery.requestSummary"
    public static let version = 1

    public static func summaryRequest() -> [String: Any] {
        ["v": version, "source": "isle"]
    }

    /// A snapshot older than this is not shown as current: the card says it is reading the battery until a fresh one arrives.
    public static let freshFor: TimeInterval = 8

    public static func isFresh(receivedAt: Date?, now: Date = Date()) -> Bool {
        guard let receivedAt else { return false }
        return now.timeIntervalSince(receivedAt) <= freshFor
    }
}
