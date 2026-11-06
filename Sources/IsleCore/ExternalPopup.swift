import Foundation

/// Pop-ups other Isle-family apps ask the island to show: Glance 2's face scan, KwikBattery's power events.
///
/// They arrive as a `DistributedNotificationCenter` notification named `ExternalPopup.notificationName`. Any process on the Mac can
/// post one, so nothing is trusted: the sender must be a known app, every string is trimmed of control characters and length-limited,
/// the icon must look like a plain SF Symbol name, and anything malformed is dropped. The worst a bad sender can do is show a short line.
///
/// userInfo (all keys required unless marked optional):
///   "v": 1                        protocol version
///   "source": "glance2" | "kwikbattery"
///   "id": String                  1–64 of A–Z a–z 0–9 . _ -. Isle prefixes it with the source. A pop-up with the id of the one on
///                                 screen is ignored, so give each state its own id (e.g. "scan.start", "scan.ok").
///   "symbol": String              SF Symbol name, lowercase letters, digits and dots
///   "title": String               ≤ 40 characters
///   "subtitle": String            optional, ≤ 80
///   "batteries": [[String: Any]]  optional, ≤ 4 entries of "label" (≤ 3 characters) and "percent" (0–100)
public enum ExternalPopup {
    public static let notificationName = "com.ranvirskh.island.popup"
    public static let version = 1
    public static let knownSources: Set<String> = ["glance2", "kwikbattery"]

    static let maxTitle = 40
    static let maxSubtitle = 80
    static let maxID = 64
    static let maxBatteries = 4

    public static func parse(_ info: [AnyHashable: Any]?, now: Date = Date()) -> PopupItem? {
        guard let info,
              (info["v"] as? Int) == version,
              let source = info["source"] as? String, knownSources.contains(source),
              let rawID = info["id"] as? String, isID(rawID),
              let symbol = info["symbol"] as? String, isSymbolName(symbol),
              let title = clean(info["title"], limit: maxTitle), !title.isEmpty
        else { return nil }

        let batteries = ((info["batteries"] as? [[String: Any]]) ?? []).prefix(maxBatteries).compactMap { entry -> PopupItem.BatteryReading? in
            guard let label = clean(entry["label"], limit: 3), let percent = entry["percent"] as? Int, (0...100).contains(percent) else { return nil }
            return PopupItem.BatteryReading(label: label, percent: percent)
        }
        return PopupItem(id: "\(source).\(rawID)", kind: .external, symbol: symbol, title: title,
                         subtitle: clean(info["subtitle"], limit: maxSubtitle) ?? "", batteries: Array(batteries), enqueuedAt: now)
    }

    static func isID(_ s: String) -> Bool {
        (1...maxID).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
    }

    static func isSymbolName(_ s: String) -> Bool {
        (1...40).contains(s.count) && s.allSatisfy { $0.isASCII && (($0.isLowercase && $0.isLetter) || $0.isNumber || $0 == ".") }
    }

    /// Trimmed, without control characters (newlines included), cut to `limit`. nil if it isn't a string.
    static func clean(_ value: Any?, limit: Int) -> String? {
        guard let s = value as? String else { return nil }
        let printable = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces).prefix(limit).description
    }
}

/// Keeps a burst of messages from flooding the island: at most `limit` accepted per `window` seconds.
public struct ExternalPopupLimiter {
    public var limit: Int
    public var window: TimeInterval
    private var accepted: [Date] = []

    public init(limit: Int = 6, window: TimeInterval = 2) {
        self.limit = limit
        self.window = window
    }

    public mutating func allow(now: Date = Date()) -> Bool {
        accepted.removeAll { now.timeIntervalSince($0) > window }
        guard accepted.count < limit else { return false }
        accepted.append(now)
        return true
    }
}
