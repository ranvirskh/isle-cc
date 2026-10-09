import Foundation

/// UserDefaults keys and their defaults, in one place.
public enum SettingsKey {
    public static let mediaSource = "mediaSource"                 // MediaSourceSetting, default system
    public static let lyricsEnabled = "lyricsEnabled"             // default false (opt-in)
    public static let lockScreenEnabled = "lockScreenEnabled"     // default false
    public static let lockScreenLyrics = "lockScreenLyrics"       // default true (only matters when both above are on)
    public static let expandTrigger = "expandTrigger"             // ExpandTrigger, default hover
    public static let hoverDelay = "hoverDelay"                   // seconds
    public static let showCalendar = "showCalendar"               // default true
    public static let hiddenCalendarIDs = "hiddenCalendarIDs"     // [String]
    public static let popupBluetooth = "popupBluetooth"           // default true
    public static let popupPower = "popupPower"                   // default true
    public static let batteryInHeader = "batteryInHeader"         // default true
    public static let displayChoice = "displayChoice"             // "cursor", "main", or a display UUID
    public static let animationSpeed = "animationSpeed"           // 0.5 ... 2.0, default 1
    public static let shelfAutoClearDays = "shelfAutoClearDays"   // 0 = never
    public static let agentsEnabled = "agentsEnabled"             // default false
    public static let agentsHidden = "agentsHidden"               // [AgentKind.rawValue] switched off
    public static let agentNoticeEnabled = "agentNoticeEnabled"   // default true
    public static let agentNoticeMinutes = "agentNoticeMinutes"   // default 2
    public static let agentHeaderChip = "agentHeaderChip"         // default false
    public static let lyricsContact = "lyricsContact"             // optional contact appended to the User-Agent

    public static let defaults: [String: Any] = [
        mediaSource: MediaSourceSetting.system.rawValue,
        lyricsEnabled: false,
        lockScreenEnabled: false,
        lockScreenLyrics: true,
        expandTrigger: ExpandTrigger.hover.rawValue,
        hoverDelay: Motion.hoverExpandDelayDefault,
        showCalendar: true,
        hiddenCalendarIDs: [String](),
        popupBluetooth: true,
        popupPower: true,
        batteryInHeader: true,
        displayChoice: "cursor",
        animationSpeed: 1.0,
        shelfAutoClearDays: 0,
        agentsEnabled: false,
        agentsHidden: [String](),
        agentNoticeEnabled: true,
        agentNoticeMinutes: 2.0,
        agentHeaderChip: false,
        lyricsContact: "",
    ]
}

public enum IsleInfo {
    public static let version = "1.0.0"
    public static let bundleID = "local.isle.app"

    /// LRCLIB requires clients to identify themselves: name, version, and a homepage or contact.
    public static func lyricsUserAgent(contact: String) -> String {
        let trimmed = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = trimmed.isEmpty ? "personal macOS notch utility; no public homepage" : trimmed
        return "Isle v\(version) (\(detail))"
    }

    public static let lyricsDisclosure =
        "When on, Isle sends the current song's title, artist, album, and duration to LRCLIB (lrclib.net) to find lyrics. "
        + "Audio is never sent. Nothing is sent while this is off."
}
