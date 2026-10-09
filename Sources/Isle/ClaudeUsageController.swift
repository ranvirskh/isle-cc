import AppKit
import IsleCore

/// Claude plan usage (5-hour session and weekly limit) for the signed-in Claude Code account. The one network call in
/// Isle: GET to Anthropic with the Claude Code token read from the Keychain, every 5 minutes and when the island opens.
/// The response is reduced to percentages and reset times; the token is never stored or logged.
@MainActor
final class ClaudeUsageController: ObservableObject {
    @Published private(set) var windows: [LimitWindow] = []
    @Published private(set) var failed = false

    /// Worst current window, for the collapsed pill. Nil below the warning level.
    var pillPercent: Double? {
        guard let top = ClaudeUsage.highest(windows, now: Date()), top >= 60 else { return nil }
        return top
    }

    private let settings = Settings.shared
    private var timer: Timer?
    private var inFlight = false
    private var lastFetch = Date.distantPast
    private static let interval: TimeInterval = 300

    func start() {
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                if (n.object as? String) == SettingsKey.claudeUsage { self?.sync() }
            }
        }
        sync()
    }

    private func sync() {
        timer?.invalidate()
        timer = nil
        guard settings.claudeUsage else { windows = []; failed = false; return }
        refresh()
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Called when the island opens: refreshes only if the last reading is older than a minute.
    func refreshIfStale() {
        guard settings.claudeUsage, Date().timeIntervalSince(lastFetch) > 60 else { return }
        refresh()
    }

    private func refresh() {
        // No point asking while nobody can see the result, and back off in Low Power Mode.
        guard settings.claudeUsage, !inFlight, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return }
        if ProcessInfo.processInfo.isLowPowerModeEnabled, Date().timeIntervalSince(lastFetch) < Self.interval * 2 { return }
        inFlight = true
        lastFetch = Date()
        DispatchQueue.global(qos: .utility).async {
            let result = Self.fetch()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.inFlight = false
                    if let result {
                        self.windows = result
                        self.failed = false
                        self.bridge(result)
                    } else {
                        // Keep the last good reading; it is dropped from view once its reset time passes.
                        self.failed = true
                    }
                }
            }
        }
    }

    /// Also feeds the Agents tab, which reads limits from this file.
    private func bridge(_ windows: [LimitWindow]) {
        let url = Paths.support.appendingPathComponent("Agents/claude-limits.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = ClaudeStatusline.encodeBridgeFile(windows: windows, now: Date()) { try? data.write(to: url, options: .atomic) }
    }

    nonisolated private static func fetch() -> [LimitWindow]? {
        guard let token = readToken() else { Log.write("usage: no Claude Code token in the Keychain"); return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Isle", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        var status = 0
        URLSession.shared.dataTask(with: request) { data, response, _ in
            body = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        sem.wait()
        guard status == 200, let body, let windows = ClaudeUsage.parse(body, now: Date()) else {
            Log.write("usage: request failed (HTTP \(status))")
            return nil
        }
        return windows
    }

    nonisolated private static func readToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? ClaudeUsage.accessToken(fromCredentials: data) : nil
    }
}
