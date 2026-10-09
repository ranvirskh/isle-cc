import AppKit
import SwiftUI
import IsleCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate!
    let env = AppEnv()
    var lockController: LockController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let args = CommandLine.arguments

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        Log.write("launch v\(IsleInfo.version) on \(ProcessInfo.processInfo.operatingSystemVersionString)")

        let island = IslandController(env: env)
        env.island = island
        let simulate = args.contains("--simulate-lock")
        lockController = LockController(media: env.media, simulate: simulate)
        env.lock = lockController

        env.devices.onPopup = { [weak island] item in island?.enqueuePopup(item) }
        env.agents.onNotice = { [weak island] n in
            island?.enqueuePopup(PopupItem(id: n.id, kind: .agentCompletion, symbol: n.agent.symbol,
                                           title: "\(n.agent.displayName) finished",
                                           subtitle: [n.project, LimitFormat.duration(n.duration)].compactMap { $0 }.joined(separator: " · ")))
        }

        env.media.onSongStarted = { [weak island] t in island?.songStarted(t) }
        env.media.start()
        env.shelf.start()
        env.calendar.start()
        env.devices.start()
        env.agents.start()
        island.start()
        env.privacy.start()
        env.fullScreen.start { [weak island] in island?.model.screen ?? ScreenInfo(NSScreen.main ?? NSScreen.screens[0]) }
        lockController.start()
        Log.write("lock feature: supported=\(lockController.isSupported) \(lockController.unsupportedReason ?? "")")
        setUpStatusItem()

        if args.contains("--demo") { env.media.loadDemo() }
        if let i = args.firstIndex(of: "--expand") {
            let tab = args.indices.contains(i + 1) ? IslandTab(rawValue: args[i + 1]) : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { island.debugExpand(tab: tab) }
        }
        if let i = args.firstIndex(of: "--lyrics-probe"), args.indices.contains(i + 1) {
            // Developer check of the lyrics pipeline: "Title|Artist|Album|Duration". Logs the outcome, not the words.
            let f = args[i + 1].components(separatedBy: "|")
            if f.count >= 2 {
                let query = LyricsQuery(title: f[0], artist: f[1], album: f.count > 2 ? f[2] : "", duration: f.count > 3 ? Double(f[3]) : nil)
                Task {
                    let provider = LRCLIBProvider(transport: URLSessionTransport(), userAgent: IsleInfo.lyricsUserAgent(contact: ""))
                    do {
                        let outcome = try await LyricsResolver(providers: [provider]).resolve(query)
                        let lines = outcome.payload.synced.map { LRCParser.parse($0).count } ?? 0
                        Log.write("lyrics-probe \(f[0]) / \(f[1]): kind=\(outcome.payload.kind.rawValue) syncedLines=\(lines) plainChars=\(outcome.payload.plain?.count ?? 0) failure=\(outcome.hadFailure)")
                    } catch { Log.write("lyrics-probe error \(error)") }
                }
            }
        }
        if args.contains("--debug-control") { installDebugControl() }
        if args.contains("--settings") { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        env.agents.appWillTerminate()
        env.media.stop()
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            settingsWindow = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: Status item and settings

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Isle")
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Isle", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func openSettings() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    func showSettings() {
        if let w = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SettingsView(settings: env.settings, calendar: env.calendar, env: env))
        let w = NSWindow(contentViewController: host)
        w.title = "Isle Settings"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        settingsWindow = w
        // While Settings is open Isle shows in the Dock with its oasis icon; it goes back to menu-bar-only on close.
        NSApp.setActivationPolicy(.regular)
        if let icon = NSImage(named: "AppIcon") ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap({ NSImage(contentsOf: $0) }) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func snapshot(window name: String, to path: String) {
        let win: NSWindow?
        switch name {
        case "island": win = env.island.currentWindow
        case "lock": win = lockController.currentWindow
        default: win = settingsWindow
        }
        guard let view = win?.contentView, view.bounds.width > 0 else { Log.write("snapshot: no window \(name)"); return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Flatten onto mid-gray so the black island is visible against it.
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        let out = NSImage(size: view.bounds.size, flipped: false) { r in
            NSColor(white: 0.55, alpha: 1).setFill(); r.fill()
            image.draw(in: r)
            return true
        }
        if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            Log.write("snapshot \(name) -> \(path)")
        }
    }

    // MARK: Debug control (only with --debug-control): lets screenshots be scripted without a real cursor.

    private func installDebugControl() {
        DistributedNotificationCenter.default().addObserver(forName: .init("local.isle.debug"), object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let cmd = n.userInfo?["cmd"] as? String else { return }
                let arg = n.userInfo?["arg"] as? String
                let island = self.env.island!
                switch cmd {
                case "expand": island.debugExpand(tab: arg.flatMap(IslandTab.init(rawValue:)))
                case "collapse": island.debugCollapse()
                case "tab": if let t = arg.flatMap(IslandTab.init(rawValue:)) { island.setTab(t) }
                case "popup":
                    island.enqueuePopup(PopupItem(id: "debug-\(UUID().uuidString)", kind: .bluetoothDevice, symbol: "airpodspro",
                                                  title: "AirPods Pro", batteries: [.init(label: "L", percent: 82), .init(label: "R", percent: 78), .init(label: "Case", percent: 64)]))
                case "power":
                    island.enqueuePopup(PopupItem(id: "debug-\(UUID().uuidString)", kind: .power, symbol: "powerplug.fill",
                                                  title: "Power adapter connected", subtitle: "86%", batteries: [.init(label: "", percent: 86)]))
                case "agentnotice":
                    island.enqueuePopup(PopupItem(id: "debug-\(UUID().uuidString)", kind: .agentCompletion, symbol: AgentKind.claudeCode.symbol,
                                                  title: "Claude Code finished", subtitle: "isle-cc · 3m 12s"))
                case "lock": self.lockController.send(.screenLocked)
                case "unlock": self.lockController.send(.screenUnlocked)
                case "theme": if let t = arg.flatMap(IslandTheme.init(rawValue:)) { self.env.settings.theme = t }
                case "day": self.env.calendar.shiftDay(Int(arg ?? "1") ?? 1)
                case "demo": self.env.media.loadDemo()
                case "banner": if let t = self.env.media.now?.track { island.songStarted(t) }
                case "settings": self.showSettings()
                case "snapshot":
                    // arg: "<island|lock|settings>:<path>". Renders Isle's own window; needs no Screen Recording permission.
                    let parts = (arg ?? "").split(separator: ":", maxSplits: 1).map(String.init)
                    if parts.count == 2 { self.snapshot(window: parts[0], to: parts[1]) }
                default: break
                }
            }
        }
    }
}
