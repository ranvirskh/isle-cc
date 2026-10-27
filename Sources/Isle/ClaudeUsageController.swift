import AppKit
import IsleCore

/// Claude plan usage (5-hour session and weekly limit) for the signed-in Claude Code account. The one network call in
/// Isle: GET to Anthropic with the Claude Code token read from the Keychain, when Claude, Codex or a terminal comes to the front and when the island opens (no timer).
/// The response is reduced to percentages and reset times; the token is never stored or logged.
@MainActor
final class ClaudeUsageController: ObservableObject {
    @Published private(set) var windows: [LimitWindow] = []
    @Published private(set) var failed = false
    /// Something is actively spending the Claude usage limit right now (a Claude Code session writing to its log, or the Claude
    /// app in front): the 5-hour limit is shown whatever its level. See `UsageActivity`.
    @Published private(set) var claudeActive = false

    /// What the collapsed notch shows for usage: whenever something is actively using Claude, at any level.
    /// While nothing is (or with no reading) the notch stays plain black at the size of the real notch.
    var pillPercent: Double? {
        guard claudeActive, let five = windows.first(where: { $0.id == "five_hour" }), LimitFormat.isCurrent(five, now: Date()) else { return nil }
        return five.usedPercent
    }

    /// Always nil: the usage readout stays on the right of the notch at every level, including 90% and above.
    /// (It used to move to the left with the time left until reset.)
    var pillAlert: ClaudeUsage.Alert? { nil }

    private let settings = Settings.shared
    private var timer: Timer?
    private var inFlight = false
    private var authFailures = 0
    private var backoffUntil = Date.distantPast
    private var lastFetch = Date.distantPast
    private let monitor = ClaudeActivityMonitor()
    private var lastSessionWrite: Date?
    /// The app in front; the notch picks that tool's usage. Published so the notch re-evaluates when it changes.
    @Published private(set) var frontmostID: String?
    private var claudeProcessRunning = false
    /// A terminal is in front and the Gemini CLI is running in it.
    @Published private(set) var geminiRunning = false
    private var expiryTimer: Timer?
    nonisolated private static let interval: TimeInterval = 300
    /// While Claude is writing to its logs, a reading older than this is refreshed.
    private static let staleAfter: TimeInterval = 600

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.frontChanged(id) }
        }
        monitor.onWrite = { [weak self] date in MainActor.assumeIsolated { self?.sessionWritten(at: date) } }
        frontChanged(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                if (n.object as? String) == SettingsKey.claudeUsage { self?.sync() }
            }
        }
        sync()
    }

    private func frontChanged(_ bundleID: String?) {
        frontmostID = bundleID
        // Look for a running Claude Code only when a terminal comes to the front (no polling).
        claudeProcessRunning = bundleID.map(UsageActivity.terminalBundleIDs.contains) == true && ClaudeProcessProbe.isRunning()
        let inTerminal = bundleID.map(UsageActivity.terminalBundleIDs.contains) == true
        geminiRunning = inTerminal && (ClaudeProcessProbe.isRunning("gemini") || ClaudeProcessProbe.isRunning("node") && ClaudeProcessProbe.geminiNodeRunning())
        recomputeActivity()
        // No polling: the reading is fetched when Claude, Codex or a terminal comes to the front (and when the island opens).
        if bundleID.map({ AIUsage.agent(forBundleID: $0) != nil || UsageActivity.terminalBundleIDs.contains($0) }) == true { refreshIfStale() }
    }

    private func sessionWritten(at date: Date) {
        lastSessionWrite = date
        recomputeActivity()
        // Claude is working (event-driven, no timer): keep the reading from going stale during a long session.
        if Date().timeIntervalSince(lastFetch) > Self.staleAfter { refreshIfStale() }
    }

    /// Active while a Claude client is in front or a session log was written recently. A single-shot timer flips it off when the
    /// last write ages out, so there is no polling.
    private func recomputeActivity() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        let now = Date()
        let active = settings.claudeUsage && UsageActivity.isActive(lastSessionWrite: lastSessionWrite, frontmostBundleID: frontmostID, claudeProcessRunning: claudeProcessRunning, now: now)
        if let end = UsageActivity.expiry(lastSessionWrite: lastSessionWrite, now: now) {
            let t = Timer(fireAt: end.addingTimeInterval(0.2), interval: 0, target: self, selector: #selector(expiryFired), userInfo: nil, repeats: false)
            RunLoop.main.add(t, forMode: .common)
            expiryTimer = t
        }
        // Coming back to Claude or a terminal is when the reading matters, so a stale "token rejected" or "rate limited" wait
        // should not hide it. At most one retry every two minutes, so switching apps cannot hammer the endpoint.
        if active, failed, Date().timeIntervalSince(lastFetch) > 120 { backoffUntil = .distantPast; refreshIfStale() }
        guard active != claudeActive else { return }
        claudeActive = active
        guard active else { return }
        if failed { backoffUntil = .distantPast }
        refreshIfStale()
    }

    @objc private func expiryFired() {
        // Claude may have been started after the terminal came to the front; look again before deciding it has gone quiet.
        if frontmostID.map(UsageActivity.terminalBundleIDs.contains) == true { claudeProcessRunning = ClaudeProcessProbe.isRunning() }
        recomputeActivity()
    }

    private func sync() {
        timer?.invalidate()
        timer = nil
        backoffUntil = .distantPast
        guard settings.claudeUsage else {
            windows = []; failed = false
            monitor.stop()
            lastSessionWrite = nil
            recomputeActivity()
            return
        }
        monitor.start()
        recomputeActivity()
        refresh()
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
        guard Date() >= backoffUntil else { return }
        inFlight = true
        lastFetch = Date()
        Task { [weak self] in
            let outcome = await Self.fetch()
            guard let self else { return }
            self.inFlight = false
            switch outcome {
            case .ok(let result):
                self.windows = result
                self.failed = false
                self.authFailures = 0
                self.backoffUntil = .distantPast
                self.bridge(result)
            case .rateLimited(let wait):
                self.failed = true
                self.backoffUntil = Date().addingTimeInterval(wait)
            case .unauthorized, .noToken:
                // Claude Code renews its token every few hours, so an expired one is usually fixed within minutes: retry
                // soon, then back off (1, 2, 4 ... up to 15 minutes) in case it really is signed out.
                self.failed = true
                self.authFailures += 1
                self.backoffUntil = Date().addingTimeInterval(min(60 * pow(2, Double(self.authFailures - 1)), Self.interval * 3))
            case .failed:
                // Keep the last good reading; it is dropped from view once its reset time passes.
                self.failed = true
            }
        }
    }

    /// Also feeds the Agents tab, which reads limits from this file.
    private func bridge(_ windows: [LimitWindow]) {
        let url = Paths.support.appendingPathComponent("Agents/claude-limits.json")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = ClaudeStatusline.encodeBridgeFile(windows: windows, now: Date()) { try data.write(to: url, options: .atomic) }
        } catch {
            Log.write("usage: could not write the limits bridge file: \(error.localizedDescription)")
        }
    }

    private enum FetchOutcome {
        case ok([LimitWindow])
        case noToken
        case unauthorized
        case rateLimited(TimeInterval)
        case failed
    }

    nonisolated private static func fetch() async -> FetchOutcome {
        guard let token = await readToken() else { Log.write("usage: no Claude Code token in the Keychain"); return .noToken }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Isle", forHTTPHeaderField: "User-Agent")
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200:
                if let windows = ClaudeUsage.parse(body, now: Date()) { return .ok(windows) }
                Log.write("usage: unexpected response format")
                return .failed
            case 401, 403:
                Log.write("usage: token rejected (HTTP \(http?.statusCode ?? 0))")
                return .unauthorized
            case 429:
                let wait = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? interval * 2
                Log.write("usage: rate limited, backing off \(Int(wait)) s")
                return .rateLimited(min(max(wait, interval), 600))
            default:
                Log.write("usage: request failed (HTTP \(http?.statusCode ?? 0))")
                return .failed
            }
        } catch {
            Log.write("usage: request error: \(error.localizedDescription)")
            return .failed
        }
    }

    /// Runs `security` off the main thread. If the Keychain prompt is left open, the process is ended after 20 s so
    /// the read cannot hang forever.
    nonisolated private static func readToken() async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { cont.resume(returning: nil); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: p.terminationStatus == 0 ? ClaudeUsage.accessToken(fromCredentials: data) : nil)
            }
        }
    }
}
