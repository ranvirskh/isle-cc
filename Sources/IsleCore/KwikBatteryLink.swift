import Foundation
import CoreGraphics

/// How Isle asks KwikBattery to open its battery panel from Isle's battery icon.
///
/// KwikBattery listens for a `DistributedNotificationCenter` notification named `showPanelNotification`. The userInfo carries where
/// Isle's icon is on screen so KwikBattery can hang its panel from it. Everything is optional for KwikBattery: without a usable
/// rectangle it just opens the panel from its own menu bar item. Isle only offers this when KwikBattery is installed.
public enum KwikBatteryLink {
    public static let bundleID = "com.kwikbattery.KwikBattery"
    public static let showPanelNotification = "com.kwikbattery.showPanel"
    /// Sent when the island closes, so the summary it asked for closes with it.
    public static let hidePanelNotification = "com.kwikbattery.hidePanel"
    public static let version = 1

    /// `anchor` is in AppKit screen coordinates (origin bottom-left of the primary display), like `NSWindow.convertToScreen`.
    public static func request(anchor: CGRect?) -> [String: Any] {
        // "summary": just the battery level, time left and power flow, as a brief glance rather than the whole panel.
        var info: [String: Any] = ["v": version, "source": "isle", "style": "summary"]
        if let a = anchor, a.origin.x.isFinite, a.origin.y.isFinite, a.width.isFinite, a.height.isFinite, a.width > 0, a.height > 0 {
            info["x"] = Double(a.origin.x)
            info["y"] = Double(a.origin.y)
            info["w"] = Double(a.width)
            info["h"] = Double(a.height)
        }
        return info
    }
}
