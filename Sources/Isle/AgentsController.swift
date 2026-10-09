import AppKit
import CoreServices
import IsleCore

/// Watches the agents' local session folders (metadata only) and publishes snapshots and completion notices.
/// All engine work happens on one serial queue; nothing runs while the feature is off, and there is no polling:
/// the only timer is a single-shot one aimed at the engine's next state deadline.
@MainActor
final class AgentsController: ObservableObject {
    @Published private(set) var snapshots: [AgentSnapshot] = []
    @Published private(set) var isScanning = false
    var onNotice: ((CompletionNotice) -> Void)?

    private let settings = Settings.shared
    private let queue = DispatchQueue(label: "isle.agents", qos: .utility)
    private var engine: AgentsEngine?
    private var stream: FSEventStreamRef?
    private var deadlineTimer: DispatchSourceTimer?
    private var pending: Set<String> = []
    private var flushScheduled = false
    private var shownNotices: Set<String> = []
    private var running = false
    private var observer: NSObjectProtocol?

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let key = n.object as? String else { return }
                switch key {
                case SettingsKey.agentsEnabled: self.sync()
                case SettingsKey.agentsHidden: self.publish()
                case SettingsKey.agentNoticeMinutes:
                    let minutes = self.settings.agentNoticeMinutes
                    self.queue.async { self.engine?.tracker.threshold = minutes * 60 }
                default: break
                }
            }
        }
        sync()
    }

    private func sync() {
        if settings.agentsEnabled { begin() } else { end() }
    }

    private func begin() {
        guard !running else { return }
        running = true
        isScanning = true
        let threshold = settings.agentNoticeMinutes * 60
        let support = Paths.support
        queue.async { [weak self] in
            let roots = AgentsEngine.Roots.standard(support: support)
            let engine = AgentsEngine(roots: roots, stateFile: support.appendingPathComponent("Agents/state.json"),
                                      completionThreshold: threshold)
            engine.log = { Log.write($0) }
            // The initial scan only rebuilds totals; a task that ended before launch never raises a notice.
            _ = engine.initialScan()
            engine.save()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.engine = engine
                    self.isScanning = false
                    self.startWatching(roots: roots)
                    self.publish()
                    self.scheduleDeadline()
                }
            }
        }
    }

    private func end() {
        running = false
        stopWatching()
        deadlineTimer?.cancel()
        deadlineTimer = nil
        queue.async { [weak self] in self?.engine?.save() }
        engine = nil
        snapshots = []
        isScanning = false
    }

    // MARK: File watching

    private func startWatching(roots: AgentsEngine.Roots) {
        stopWatching()
        var paths: [String] = []
        for agent in AgentKind.allCases where FileManager.default.fileExists(atPath: roots.root(for: agent).path) {
            paths.append(roots.root(for: agent).path)
        }
        let limitsDir = roots.claudeLimitsFile.deletingLastPathComponent().path
        if FileManager.default.fileExists(atPath: limitsDir) { paths.append(limitsDir) }
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let me = Unmanaged<AgentsController>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(rawPaths, to: CFArray.self) as? [String]) ?? []
            DispatchQueue.main.async { MainActor.assumeIsolated { me.changed(paths) } }
        }, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.6, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    private func stopWatching() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    private func changed(_ paths: [String]) {
        guard running else { return }
        pending.formUnion(paths)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        let batch = pending
        pending = []
        guard let engine else { return }
        queue.async { [weak self] in
            var notices: [CompletionNotice] = []
            for p in batch { notices += engine.ingest(path: p) }
            engine.save()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.publish()
                    self?.deliver(notices)
                    self?.scheduleDeadline()
                }
            }
        }
    }

    // MARK: Deadlines

    private func scheduleDeadline() {
        deadlineTimer?.cancel()
        deadlineTimer = nil
        guard running, let engine else { return }
        queue.async { [weak self] in
            guard let deadline = engine.nextDeadline() else { return }
            let delay = max(0.5, deadline.timeIntervalSinceNow + 0.1)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    let t = DispatchSource.makeTimerSource(queue: self.queue)
                    t.schedule(deadline: .now() + delay, leeway: .milliseconds(500))
                    t.setEventHandler { [weak self] in
                        let notices = engine.tick()
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self?.publish()
                                self?.deliver(notices)
                                self?.scheduleDeadline()
                            }
                        }
                    }
                    t.resume()
                    self.deadlineTimer = t
                }
            }
        }
    }

    private func deliver(_ notices: [CompletionNotice]) {
        guard settings.agentNoticeEnabled else { return }
        for n in notices where !shownNotices.contains(n.id) && !settings.agentsHidden.contains(n.agent) {
            shownNotices.insert(n.id)
            onNotice?(n)
        }
    }

    func publish() {
        guard let engine else { return }
        let visible = Set(AgentKind.allCases).subtracting(settings.agentsHidden)
        queue.async { [weak self] in
            let snaps = engine.snapshots(visible: visible)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running, snaps != self.snapshots else { return }
                    self.snapshots = snaps
                }
            }
        }
    }

    /// Agents found on this Mac (for the Settings list), regardless of the per-agent toggle.
    func detected() -> [AgentKind] {
        let roots = AgentsEngine.Roots.standard(support: Paths.support)
        return AgentKind.allCases.filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: roots.root(for: $0).path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    func reset() {
        queue.async { [weak self] in
            self?.engine?.reset()
            self?.engine?.save()
            _ = self?.engine?.initialScan()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.publish() } }
        }
    }

    func appWillTerminate() { queue.sync { engine?.save() } }
}
