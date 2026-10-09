import AppKit
import Combine
import IsleCore
import ServiceManagement

/// Typed, observable wrapper over UserDefaults. Every value has its default registered in SettingsKey.defaults.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: SettingsKey.defaults)
        applyMotion()
    }

    func applyMotion() {
        Motion.speed = animationSpeed
        Motion.preset = animationPreset
        Motion.animationsEnabled = animationsEnabled
        Motion.disabledCategories = animationsOff
    }

    private func set(_ value: Any?, _ key: String) {
        objectWillChange.send()
        d.set(value, forKey: key)
        applyMotion()
        NotificationCenter.default.post(name: .settingsChanged, object: key)
    }

    var mediaSource: MediaSourceSetting {
        get { MediaSourceSetting(rawValue: d.string(forKey: SettingsKey.mediaSource) ?? "") ?? .system }
        set { set(newValue.rawValue, SettingsKey.mediaSource) }
    }
    var lyricsEnabled: Bool {
        get { d.bool(forKey: SettingsKey.lyricsEnabled) }
        set { set(newValue, SettingsKey.lyricsEnabled) }
    }
    var lockScreenEnabled: Bool {
        get { d.bool(forKey: SettingsKey.lockScreenEnabled) }
        set { set(newValue, SettingsKey.lockScreenEnabled) }
    }
    var lockScreenLyrics: Bool {
        get { d.bool(forKey: SettingsKey.lockScreenLyrics) }
        set { set(newValue, SettingsKey.lockScreenLyrics) }
    }
    var expandTrigger: ExpandTrigger {
        get { ExpandTrigger(rawValue: d.string(forKey: SettingsKey.expandTrigger) ?? "") ?? .hover }
        set { set(newValue.rawValue, SettingsKey.expandTrigger) }
    }
    var hoverDelay: Double {
        get { d.double(forKey: SettingsKey.hoverDelay) }
        set { set(newValue, SettingsKey.hoverDelay) }
    }
    var showCalendar: Bool {
        get { d.bool(forKey: SettingsKey.showCalendar) }
        set { set(newValue, SettingsKey.showCalendar) }
    }
    var hiddenCalendarIDs: Set<String> {
        get { Set(d.stringArray(forKey: SettingsKey.hiddenCalendarIDs) ?? []) }
        set { set(Array(newValue).sorted(), SettingsKey.hiddenCalendarIDs) }
    }
    var popupBluetooth: Bool {
        get { d.bool(forKey: SettingsKey.popupBluetooth) }
        set { set(newValue, SettingsKey.popupBluetooth) }
    }
    var popupPower: Bool {
        get { d.bool(forKey: SettingsKey.popupPower) }
        set { set(newValue, SettingsKey.popupPower) }
    }
    var batteryInHeader: Bool {
        get { d.bool(forKey: SettingsKey.batteryInHeader) }
        set { set(newValue, SettingsKey.batteryInHeader) }
    }
    var displayChoice: String {
        get { d.string(forKey: SettingsKey.displayChoice) ?? "cursor" }
        set { set(newValue, SettingsKey.displayChoice) }
    }
    var animationSpeed: Double {
        get { min(2, max(0.5, d.double(forKey: SettingsKey.animationSpeed))) }
        set { set(newValue, SettingsKey.animationSpeed) }
    }
    var shelfAutoClearDays: Int {
        get { d.integer(forKey: SettingsKey.shelfAutoClearDays) }
        set { set(newValue, SettingsKey.shelfAutoClearDays) }
    }
    var agentsEnabled: Bool {
        get { d.bool(forKey: SettingsKey.agentsEnabled) }
        set { set(newValue, SettingsKey.agentsEnabled) }
    }
    var agentsHidden: Set<AgentKind> {
        get { Set((d.stringArray(forKey: SettingsKey.agentsHidden) ?? []).compactMap(AgentKind.init(rawValue:))) }
        set { set(newValue.map(\.rawValue).sorted(), SettingsKey.agentsHidden) }
    }
    var agentNoticeEnabled: Bool {
        get { d.bool(forKey: SettingsKey.agentNoticeEnabled) }
        set { set(newValue, SettingsKey.agentNoticeEnabled) }
    }
    var agentNoticeMinutes: Double {
        get { max(0.5, d.double(forKey: SettingsKey.agentNoticeMinutes)) }
        set { set(newValue, SettingsKey.agentNoticeMinutes) }
    }
    var agentHeaderChip: Bool {
        get { d.bool(forKey: SettingsKey.agentHeaderChip) }
        set { set(newValue, SettingsKey.agentHeaderChip) }
    }
    var animationPreset: Motion.Preset {
        get { Motion.Preset(rawValue: d.string(forKey: SettingsKey.animationPreset) ?? "") ?? .smooth }
        set { set(newValue.rawValue, SettingsKey.animationPreset) }
    }
    var animationsEnabled: Bool {
        get { d.bool(forKey: SettingsKey.animationsEnabled) }
        set { set(newValue, SettingsKey.animationsEnabled) }
    }
    var animationsOff: Set<Motion.Category> {
        get { Set((d.stringArray(forKey: SettingsKey.animationsOff) ?? []).compactMap(Motion.Category.init(rawValue:))) }
        set { set(newValue.map(\.rawValue).sorted(), SettingsKey.animationsOff) }
    }
    var privacyIndicator: Bool {
        get { d.bool(forKey: SettingsKey.privacyIndicator) }
        set { set(newValue, SettingsKey.privacyIndicator) }
    }
    var liveActivity: Bool {
        get { d.bool(forKey: SettingsKey.liveActivity) }
        set { set(newValue, SettingsKey.liveActivity) }
    }
    var songBanner: Bool {
        get { d.bool(forKey: SettingsKey.songBanner) }
        set { set(newValue, SettingsKey.songBanner) }
    }
    var lyricsContact: String {
        get { d.string(forKey: SettingsKey.lyricsContact) ?? "" }
        set { set(newValue, SettingsKey.lyricsContact) }
    }

    // Launch at login lives in the system, not in UserDefaults.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.write("launch at login: \(error.localizedDescription)")
            }
        }
    }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("IsleSettingsChanged")
}

/// Tiny file + stderr logger. Never receives prompt text or media content beyond what the user sees on the island.
enum Log {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Isle")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("isle.log")
    }()
    private static let queue = DispatchQueue(label: "isle.log")
    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile(); h.write(data); try? h.close()
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }
}

enum Paths {
    static let support: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Isle")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
