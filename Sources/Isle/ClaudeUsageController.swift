import AppKit
import IsleCore

/// Claude plan usage (5-hour session and weekly limit) for the signed-in Claude Code account. The one network call in
/// Isle: GET to Anthropic with the Claude Code token read from the Keychain, every 5 minutes and when the island opens.
/// The response is reduced to percentages and reset times; the token is never stored or logged.
@MainActor
final class ClaudeUsageController: ObservableObject {
    @Published private(set) var windows: [LimitWindow] = []
    @Published private(set) var failed = false
    /// A terminal or the Claude app is the frontmost app: the 5-hour limit is shown whatever its level.
    @Published private(set) var codingAppActive = false

    /// What the collapsed notch shows for usage: whenever a terminal or the Claude app is in front, at any level.
    /// In every other app (or with no reading) the notch stays plain black at the size of the real notch.
    var pillPercent: Double? {
        guard codingAppActive, let five = windows.first(where: { $0.id == "five_hour" }), LimitFormat.isCurrent(five, now: Date()) else { return nil }
        return five.usedPercent
    }

    /// 90% or more: percentage and time left on the left of the notch, again only while a terminal or Claude is in front.
    var pillAlert: ClaudeUsage.Alert? { codingAppActive ? ClaudeUsage.alert(windows, now: Date()) : nil }

    private let settings = Settings.shared
    private var timer: Timer?
    private var inFlight = false
    private var backoffUntil = Date.distantPast
    private var lastFetch = Date.distantPast
    nonisolated private static let interval: TimeInterval = 300

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.frontChanged(id) }
        }
        frontChanged(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                if (n.object as? String) == SettingsKey.claudeUsage { self?.sync() }
            }
        }
        sync()
    }

    private func frontChanged(_ bundleID: String?) {
        let active = bundleID.map { ClaudeUsage.codingBundleIDs.contains($0) } ?? false
        guard active != codingAppActive else { return }
        codingAppActive = active
        guard active else { return }
        refreshIfStale()

    }

    private func sync() {
        timer?.invalidate()
        timer = nil
        backoffUntil = .distantPast
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
                self.backoffUntil = .distantPast
                self.bridge(result)
            case .rateLimited(let wait):
                self.failed = true
                self.backoffUntil = Date().addingTimeInterval(wait)
            case .unauthorized, .noToken:
                // The token is expired or missing: retrying every few minutes only wastes energy until Claude Code signs in again.
                self.failed = true
                self.backoffUntil = Date().addingTimeInterval(Self.interval * 3)
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
                return .rateLimited(min(max(wait, interval), 3600))
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
