import SwiftUI
import IsleCore

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var calendar: CalendarController
    @ObservedObject var weather: WeatherController
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

            Section("Lock screen widgets") {
                Toggle("Show status widgets on the lock screen", isOn: binding({ settings.lockWidgets }, { settings.lockWidgets = $0 }))
                    .disabled(!(env.lock?.isSupported ?? false))
                Text("Weather, charging and connected Bluetooth devices appear near the bottom of the lock screen, display only. Anyone who can see the screen can see them.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.lockWidgets {
                    Toggle("Weather (needs Weather turned on below)", isOn: binding({ settings.lockWidgetWeather }, { settings.lockWidgetWeather = $0 }))
                    Toggle("Charging and battery", isOn: binding({ settings.lockWidgetCharging }, { settings.lockWidgetCharging = $0 }))
                    Toggle("Bluetooth device batteries", isOn: binding({ settings.lockWidgetBluetooth }, { settings.lockWidgetBluetooth = $0 }))
                }
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
                HUDSettingsRow(hud: env.hud, settings: settings)
                Toggle("Show the island on external displays (off: built-in display only)", isOn: binding({ settings.externalDisplays }, { settings.externalDisplays = $0 }))
                Picker("Display", selection: binding({ settings.displayChoice }, { settings.displayChoice = $0 })) {
                    Text("The display with the cursor").tag("cursor")
                    Text("Main display").tag("main")
                    ForEach(NSScreen.screens.filter(IslandController.isAllowed), id: \.self) { s in
                        if let id = s.uuidString { Text(s.localizedName).tag(id) }
                    }
                }
                Toggle("Battery in the header", isOn: binding({ settings.batteryInHeader }, { settings.batteryInHeader = $0 }))
            }

            Section("Weather") {
                Toggle("Show weather in the header", isOn: binding({ settings.weatherEnabled }, { settings.weatherEnabled = $0 }))
                Text(WeatherService.disclosure).font(.caption).foregroundStyle(.secondary)
                if settings.weatherEnabled {
                    Picker("Place", selection: binding({ settings.weatherUseLocation }, { settings.weatherUseLocation = $0 })) {
                        Text("This Mac's location").tag(true)
                        Text("A city I type").tag(false)
                    }
                    if settings.weatherUseLocation {
                        if weather.location.isDenied {
                            Button("Open Location Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { NSWorkspace.shared.open(url) }
                            }
                        }
                    } else {
                        TextField("City", text: binding({ settings.weatherCity }, { settings.weatherCity = $0 }), prompt: Text("e.g. Seattle"))
                    }
                    Picker("Units", selection: binding({ settings.weatherUnit }, { settings.weatherUnit = $0 })) {
                        Text("Celsius").tag(TemperatureUnit.celsius)
                        Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
                    }
                    .pickerStyle(.segmented)
                    if let w = weather.reading { Text("\(w.place.name)\(w.place.region.map { ", " + $0 } ?? ""): \(w.temperatureText) \(w.summary)").font(.caption) }
                    else if let p = weather.problem { Text(p).font(.caption).foregroundStyle(.orange) }
                    Link(WeatherService.attribution, destination: URL(string: "https://open-meteo.com/")!).font(.caption)
                }
            }

            Section("Look") {
                Picker("Theme", selection: binding({ settings.theme }, { settings.theme = $0 })) {
                    ForEach(IslandTheme.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("Minimalistic is smaller and hides the calendar. Frutiger Aero is a glossy aqua glass look.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Picker("Charging indicator", selection: binding({ settings.chargingIndicator }, { settings.chargingIndicator = $0 })) {
                    Text("Off").tag(ChargingIndicatorMode.off)
                    Text("For 2.5 seconds after plugging in").tag(ChargingIndicatorMode.brief)
                    Text("While charging").tag(ChargingIndicatorMode.whileCharging)
                }
                Toggle("Show browser downloads in the notch (watches your Downloads folder for file names and sizes)", isOn: binding({ settings.downloadsIndicator }, { settings.downloadsIndicator = $0 }))
                Toggle("Indicator when the microphone, camera or screen recording is on", isOn: binding({ settings.privacyIndicator }, { settings.privacyIndicator = $0 }))
                Toggle("Widen the notch for live items (cover, charging, downloads). Off keeps it hidden inside the real notch (always on for displays without a notch)", isOn: binding({ settings.liveWings }, { settings.liveWings = $0 }))
                Toggle("Cover and equalizer beside the notch while playing", isOn: binding({ settings.liveActivity }, { settings.liveActivity = $0 }))
                Toggle("Song-change banner (cover flips in, 1.5 s)", isOn: binding({ settings.songBanner }, { settings.songBanner = $0 }))
                Toggle("Shelf & AirDrop tab", isOn: binding({ settings.shelfEnabled }, { settings.shelfEnabled = $0 }))
                Toggle("Calendar tab: month view with the selected day's agenda", isOn: binding({ settings.calendarTabEnabled }, { settings.calendarTabEnabled = $0 }))
                Toggle("Mirror tab: camera preview, on only while the tab is open (asks for Camera access)", isOn: binding({ settings.mirrorEnabled }, { settings.mirrorEnabled = $0 }))
                Toggle("Scripts tab: run your saved shell commands (add them in the Scripts section below)", isOn: binding({ settings.scriptsEnabled }, { settings.scriptsEnabled = $0 }))
                Toggle("Parallax: content shifts slightly with the pointer while the island is open", isOn: binding({ settings.parallaxHover }, { settings.parallaxHover = $0 }))
                TabOrderRow(settings: settings)
                Toggle("Tools tab: Keep Awake (stop the Mac from sleeping for a set time)", isOn: binding({ settings.toolsEnabled }, { settings.toolsEnabled = $0 }))
                Toggle("Clipboard tab: last 12 copied texts, memory only, password-manager copies skipped", isOn: binding({ settings.clipboardEnabled }, { settings.clipboardEnabled = $0 }))
                Toggle("System tab: CPU, memory, network and disk (sampled only while the tab is open)", isOn: binding({ settings.statsEnabled }, { settings.statsEnabled = $0 }))
                Toggle("Global shortcuts: Control-Option-Space opens or closes the island, Control-Option-1 to 6 pick a tab", isOn: binding({ settings.shortcutsEnabled }, { settings.shortcutsEnabled = $0 }))
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

            Section("Scripts") {
                ScriptsEditor(scripts: env.scripts)
            }

            Section("Updates") {
                UpdatesRow(updates: env.updates, settings: settings)
            }

            Section("Pop-ups") {
                Toggle("Bluetooth device connected", isOn: binding({ settings.popupBluetooth }, { settings.popupBluetooth = $0 }))
                Toggle("Power adapter connected / disconnected", isOn: binding({ settings.popupPower }, { settings.popupPower = $0 }))
                HStack {
                    Text("To show AirPods only in the notch, turn off Bluetooth notifications in macOS (apps cannot hide that banner themselves).")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Notifications Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                }
            }

            Section("AI agents") {
                Toggle("Show AI agents tab", isOn: binding({ settings.agentsEnabled }, { settings.agentsEnabled = $0 }))
                Text("Reads only metadata from each agent's local session files on this Mac: timestamps, model names, token counts, project folder name and session id. Never prompt text, responses or file contents. The scan itself uses no network.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Notify when a long task finishes", isOn: binding({ settings.agentNoticeEnabled }, { settings.agentNoticeEnabled = $0 }))
                if settings.agentNoticeEnabled {
                    Stepper(value: binding({ settings.agentNoticeMinutes }, { settings.agentNoticeMinutes = $0 }), in: 0.5...60, step: 0.5) {
                        Text("Only if it ran at least \(settings.agentNoticeMinutes.formatted()) min")
                    }
                }
                Toggle("Show Claude plan usage (5-hour and weekly) in the header and notch", isOn: binding({ settings.claudeUsage }, { settings.claudeUsage = $0 }))
                Text("Reads your Claude Code sign-in token from the Keychain and asks Anthropic for your usage every 5 minutes. Nothing else is sent or stored.")
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

/// Volume and brightness indicator in the island. Needs the Accessibility permission to see the media keys.
struct HUDSettingsRow: View {
    @ObservedObject var hud: HUDController
    @ObservedObject var settings: Settings

    var body: some View {
        Toggle("Volume and brightness indicator in the island (replaces the macOS overlay)", isOn: Binding(get: { settings.hudReplacement }, set: { settings.hudReplacement = $0 }))
        if settings.hudReplacement {
            HStack {
                Text("Change per key press")
                Slider(value: Binding(get: { settings.hudStepPercent }, set: { settings.hudStepPercent = $0.rounded() }), in: HUDStep.percentRange, step: 1)
                Text("\(Int(settings.hudStepPercent))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            Toggle("Also show keyboard backlight and microphone level", isOn: Binding(get: { settings.hudMicrophone }, set: { settings.hudMicrophone = $0 }))
            if hud.trusted {
                Text(SystemLevels.brightnessAvailable ? "Active. Shift-Option moves a quarter of that per press."
                     : "Active for volume. Brightness control is not available on this Mac, so the macOS overlay is used for it.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Needs the Accessibility permission to see the volume and brightness keys.").font(.caption).foregroundStyle(.secondary)
                    Button("Open Accessibility Settings") { hud.openAccessibilitySettings() }
                }
            }
        }
    }
}

/// Reorder the tabs that are switched on.
struct TabOrderRow: View {
    @ObservedObject var settings: Settings

    var body: some View {
        let tabs = settings.visibleTabs.filter { $0 != .home }
        if tabs.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tab order (Home is always first)").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(tabs.enumerated()), id: \.element) { i, tab in
                    HStack {
                        Text(Self.title(tab))
                        Spacer()
                        Button { move(tab, by: -1, in: tabs) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                        Button { move(tab, by: 1, in: tabs) } label: { Image(systemName: "chevron.down") }.disabled(i == tabs.count - 1)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func move(_ tab: IslandTab, by delta: Int, in tabs: [IslandTab]) {
        var order = tabs
        guard let i = order.firstIndex(of: tab), order.indices.contains(i + delta) else { return }
        order.swapAt(i, i + delta)
        settings.tabOrder = order
    }

    static func title(_ t: IslandTab) -> String {
        switch t {
        case .home: return "Home"
        case .shelf: return "Shelf & AirDrop"
        case .tools: return "Tools"
        case .clipboard: return "Clipboard"
        case .stats: return "System"
        case .calendar: return "Calendar"
        case .mirror: return "Mirror"
        case .scripts: return "Scripts"
        case .agents: return "AI agents"
        }
    }
}

/// Saved shell commands for the Scripts tab. They only ever run when clicked in the island.
struct ScriptsEditor: View {
    @ObservedObject var scripts: ScriptsController

    var body: some View {
        Text("Commands run with /bin/zsh as you, from your home folder, only when you click them in the Scripts tab (30 second limit).")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(scripts.items) { item in
            HStack {
                TextField("Name", text: Binding(get: { item.name }, set: { update(item.id) { $0.name = $1 }($0) }), prompt: Text("Name"))
                    .frame(width: 110)
                TextField("Command", text: Binding(get: { item.command }, set: { update(item.id) { $0.command = $1 }($0) }), prompt: Text("echo hello"))
                Button(role: .destructive) { scripts.save(scripts.items.filter { $0.id != item.id }) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
        Button("Add script") { scripts.save(scripts.items + [ScriptItem(name: "", command: "")]) }
    }

    /// Returns a setter that edits one item and saves the list.
    private func update(_ id: UUID, _ edit: @escaping (inout ScriptItem, String) -> Void) -> (String) -> Void {
        { text in
            var items = scripts.items
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            edit(&items[i], text)
            scripts.save(items)
        }
    }
}

struct UpdatesRow: View {
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var settings: Settings

    var body: some View {
        Toggle("Check for a new Isle release once a day (one request to GitHub; nothing else is sent)", isOn: Binding(get: { settings.autoUpdateCheck }, set: { settings.autoUpdateCheck = $0 }))
        HStack {
            Text("Isle \(IsleInfo.version)")
            Spacer()
            switch updates.status {
            case .idle: EmptyView()
            case .checking: Text("Checking…").foregroundStyle(.secondary)
            case .upToDate: Text("You have the latest version").foregroundStyle(.secondary)
            case .failed: Text("Could not check").foregroundStyle(.secondary)
            case .available(let info): Button("Version \(info.version) is available") { updates.openRelease(info) }
            }
            Button("Check now") { updates.check() }
        }
    }
}
