import Foundation

/// How Isle shows Glance 2 (face unlock) in its header and card.
///
/// Isle asks Glance for its status with a `DistributedNotificationCenter` notification and Glance answers with another. Any process on
/// the Mac can post either one, so a reply is only believed when it is well-formed and from "glance2", every string is cleaned and
/// length-limited, and anything malformed is dropped. A status carries only state flags and a short history of where a scan happened
/// and what came of it: never the password or the face. Isle also sends Glance two commands, "unlock" (which only raises Glance's own
/// Touch ID prompt) and "open settings".
public enum GlanceLink {
    public static let version = 1
    /// The released Glance and the dev copy built from source.
    public static let bundleIDs: Set<String> = ["com.jonathan.glance", "com.ranvir.glance.dev"]
    public static let statusNotification = "com.ranvirskh.glance2.status"
    public static let requestStatusNotification = "com.ranvirskh.glance2.requestStatus"
    public static let unlockNotification = "com.ranvirskh.glance2.unlock"
    public static let openSettingsNotification = "com.ranvirskh.glance2.openSettings"

    /// What Isle sends with every request and command.
    public static func command() -> [String: Any] { ["v": version, "source": "isle"] }
}

public struct GlanceStatus: Equatable {
    public struct Entry: Equatable {
        public let date: Date
        public let place: String
        public let result: String
        public let ok: Bool
    }

    /// What the header chip shows.
    public enum Light: Equatable { case off, needsAttention, ready }

    public let enabled: Bool
    /// Glance's session is locked: it can't type the password until it is unlocked with Touch ID.
    public let locked: Bool
    public let hasPassword: Bool
    /// Newest first.
    public let history: [Entry]

    static let maxHistory = 10
    static let maxText = 30

    public var light: Light {
        if !enabled { return .off }
        return locked || !hasPassword ? .needsAttention : .ready
    }

    /// True when the card should offer an Unlock button: face unlock is on, a password is stored, and only the session is locked.
    public var canUnlock: Bool { enabled && hasPassword && locked }

    public static func parse(_ info: [AnyHashable: Any]?) -> GlanceStatus? {
        guard let info, (info["v"] as? Int) == GlanceLink.version, info["source"] as? String == "glance2",
              let enabled = info["enabled"] as? Bool, let locked = info["locked"] as? Bool, let hasPassword = info["hasPassword"] as? Bool
        else { return nil }
        let entries = ((info["history"] as? [[String: Any]]) ?? []).prefix(maxHistory).compactMap { e -> Entry? in
            guard let t = e["t"] as? Double, t.isFinite, t > 0, let ok = e["ok"] as? Bool,
                  let place = ExternalPopup.clean(e["place"], limit: maxText), !place.isEmpty,
                  let result = ExternalPopup.clean(e["result"], limit: maxText), !result.isEmpty
            else { return nil }
            return Entry(date: Date(timeIntervalSince1970: t), place: place, result: result, ok: ok)
        }
        return GlanceStatus(enabled: enabled, locked: locked, hasPassword: hasPassword, history: Array(entries))
    }
}
