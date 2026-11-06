import Foundation

/// Isle, KwikBattery and Glance 2 work together, but each may be installed on its own, and an older copy may not understand the
/// messages. Each app declares what it understands in its own Info.plist, and the others read that before relying on it, so a
/// missing or older app simply means no integration, never a half-working one.
public enum IslandIntegration {
    public static let infoKey = "IslandIntegration"
    /// The protocol version this Isle speaks (see ExternalPopup, KwikBatteryLink).
    public static let version = 1

    /// True when an app's Info.plist says it speaks at least this version of the protocol.
    public static func supports(_ infoDictionary: [String: Any]?, minimum: Int = version) -> Bool {
        ((infoDictionary?[infoKey] as? Int) ?? 0) >= minimum
    }
}
