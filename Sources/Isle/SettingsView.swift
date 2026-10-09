import SwiftUI
import IsleCore

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var calendar: CalendarController
    let env: AppEnv
    @State private var cacheCleared = false
    @State private var confirmShelfReset = false

    private func binding<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: set)
    }

    static func title(_ c: Motion.Category) -> String {
        switch c {
        case .shape: return "Island opening and closing"
        case .content: return "Content fade and scale"
        case .tabs: return "Tab switches and drop targets"
        case .media: return "Artwork, title and play / pause"
        case .lyrics: return "Lyric line motion"
        case .banner: return "Song-change banner flip"
        case .buttons: return "Button press feedback"
        }
    }

    var body: some View {
        Form {
            Section("Music") {
                Picker("Source", selection: binding({ settings.mediaSource }, { settings.mediaSource = $0 })) {
                    Text("System (any app)").tag(MediaSourceSetting.system)
                    Text("Spotify").tag(MediaSourceSetting.spotify)
                    Text("Apple Music").tag(MediaSourceSetting.appleMusic)
                }
                if settings.mediaSource != .system {
                    Text("Isle asks macOS for permission to control \(settings.mediaSource == .spotify ? "Spotify" : "Music") the first time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Lyrics") {
                Toggle("Show synced lyrics", isOn: binding({ settings.lyricsEnabled }, { settings.lyricsEnabled = $0 }))
                Text("When on, Isle sends the current song's title, artist, album, and duration to LRCLIB (lrclib.net) to find lyrics. Audio is never sent. Nothing is sent while this is off.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Contact for LRCLIB (optional)", text: binding({ settings.lyricsContact }, { settings.lyricsContact = $0 }),
                          prompt: Text("email or website, added to the User-Agent"))
                HStack {
                    Button("Clear lyrics cache") { env.media.clearLyricsCache(); cacheCleared = true }
                    if cacheCleared { Text("Cleared").font(.caption).foregroundStyle(.secondary) }
                }
            }

            Section("Lock screen") {
                Toggle("Show on lock screen", isOn: binding({ settings.lockScreenEnabled }, { settings.lockScreenEnabled = $0 }))
                    .disabled(!(env.lock?.isSupported ?? false))
                if let reason = env.lock?.unsupportedReason {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Anyone who can see your screen can see what you're listening to. Display only; nothing on it can be clicked.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Show lyrics on the lock screen", isOn: binding({ settings.lockScreenLyrics }, { settings.lockScreenLyrics = $0 }))
                    .disabled(!settings.lockScreenEnabled || !settings.lyricsEnabled)
            }

            Section("Island") {
                Picker("Open on", selection: binding({ settings.expandTrigger }, { settings.expandTrigger = $0 })) {
                    Text("Hover").tag(ExpandTrigger.hover)
                    Text("Click").tag(ExpandTrigger.click)
                }
                .pickerStyle(.segmented)
                if settings.expandTrigger == .hover {
                    HStack {
                        Text("Hover delay")
                        Slider(value: binding({ settings.hoverDelay }, { settings.hoverDelay = $0 }), in: 0...0.8)
                        Text("\(Int(settings.hoverDelay * 1000)) ms").monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
                Picker("Display", selection: binding({ settings.displayChoice }, { settings.displayChoice = $0 })) {
                    Text("The display with the cursor").tag("cursor")
                    Text("Main display").tag("main")
                    ForEach(NSScreen.screens, id: \.self) { s in
                        if let id = s.uuidString { Text(s.localizedName).tag(id) }
                    }
                }
                Toggle("Battery in the header", isOn: binding({ settings.batteryInHeader }, { settings.batteryInHeader = $0 }))
            }

            Section("Animations") {
                Toggle("Animations", isOn: binding({ settings.animationsEnabled }, { settings.animationsEnabled = $0 }))
                if settings.animationsEnabled {
                    Picker("Style", selection: binding({ settings.animationPreset }, { settings.animationPreset = $0 })) {
                        Text("Smooth").tag(Motion.Preset.smooth)
                        Text("Snappy").tag(Motion.Preset.snappy)
                        Text("Bouncy").tag(Motion.Preset.bouncy)
                        Text("Minimal").tag(Motion.Preset.minimal)
                    }
                    HStack {
                        Text("Speed")
                        Slider(value: binding({ settings.animationSpeed }, { settings.animationSpeed = $0 }), in: 0.5...2)
                        Text(String(format: "%.1f×", settings.animationSpeed)).monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                    ForEach(Motion.Category.allCases, id: \.self) { cat in
                        Toggle(Self.title(cat), isOn: binding({ !settings.animationsOff.contains(cat) }, { on in
                            var off = settings.animationsOff
                            if on { off.remove(cat) } else { off.insert(cat) }
                            settings.animationsOff = off
                        }))
                    }
                    Text("Isle also follows the system Reduce Motion setting.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Cover and equalizer beside the notch while playing", isOn: binding({ settings.liveActivity }, { settings.liveActivity = $0 }))
                Toggle("Song-change banner (cover flips in, 1.5 s)", isOn: binding({ settings.songBanner }, { settings.songBanner = $0 }))
            }

            Section("Calendar") {
                Toggle("Show today's agenda", isOn: binding({ settings.showCalendar }, { settings.showCalendar = $0 }))
                if settings.showCalendar {
                    switch calendar.access {
                    case .denied:
                        HStack {
                            Text("Calendar access is off.").foregroundStyle(.secondary)
                            Button("Open Privacy Settings") { calendar.openPrivacySettings() }
                        }
                    case .unknown:
                        Button("Allow Calendar Access") { calendar.requestIfNeeded() }
                    case .granted:
                        ForEach(calendar.calendars, id: \.id) { cal in
                            Toggle(isOn: binding({ !settings.hiddenCalendarIDs.contains(cal.id) }, { on in
                                var hidden = settings.hiddenCalendarIDs
                                if on { hidden.remove(cal.id) } else { hidden.insert(cal.id) }
                                settings.hiddenCalendarIDs = hidden
                            })) {
                                Label { Text(cal.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: cal.color)) }
                            }
                        }
                    }
                }
            }

            Section("Pop-ups") {
                Toggle("Bluetooth device connected", isOn: binding({ settings.popupBluetooth }, { settings.popupBluetooth = $0 }))
                Toggle("Power adapter connected / disconnected", isOn: binding({ settings.popupPower }, { settings.popupPower = $0 }))
            }

            Section("AI agents") {
                Toggle("Show AI agents tab", isOn: binding({ settings.agentsEnabled }, { settings.agentsEnabled = $0 }))
                Text("Reads only metadata from each agent's local session files on this Mac: timestamps, model names, token counts, project folder name and session id. Never prompt text, responses or file contents. No network access.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.agentsEnabled {
                    let detected = env.agents.detected()
                    if detected.isEmpty {
                        Text("No supported agent found on this Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(detected) { agent in
                        Toggle(agent.displayName, isOn: binding({ !settings.agentsHidden.contains(agent) }, { on in
                            var h = settings.agentsHidden
                            if on { h.remove(agent) } else { h.insert(agent) }
                            settings.agentsHidden = h
                        }))
                    }
                    Toggle("Notify when a long task finishes", isOn: binding({ settings.agentNoticeEnabled }, { settings.agentNoticeEnabled = $0 }))
                    if settings.agentNoticeEnabled {
                        Stepper(value: binding({ settings.agentNoticeMinutes }, { settings.agentNoticeMinutes = $0 }), in: 0.5...60, step: 0.5) {
                            Text("Only if it ran at least \(settings.agentNoticeMinutes.formatted()) min")
                        }
                    }
                    Toggle("Show highest limit in the header", isOn: binding({ settings.agentHeaderChip }, { settings.agentHeaderChip = $0 }))
                    Text("Plan limits appear only when an agent itself reports them. Otherwise the card says \"Limit data not available\".")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Shelf") {
                Picker("Auto-clear", selection: binding({ settings.shelfAutoClearDays }, { settings.shelfAutoClearDays = $0 })) {
                    Text("Never").tag(0)
                    Text("After 1 day").tag(1)
                    Text("After 7 days").tag(7)
                    Text("After 30 days").tag(30)
                }
                Button("Reset shelf…", role: .destructive) { confirmShelfReset = true }
                    .confirmationDialog("Remove everything from the shelf?", isPresented: $confirmShelfReset) {
                        Button("Reset shelf", role: .destructive) { env.shelf.clearAll() }
                    }
            }

            Section("General") {
                Toggle("Launch at login", isOn: binding({ settings.launchAtLogin }, { settings.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 680)
    }
}
