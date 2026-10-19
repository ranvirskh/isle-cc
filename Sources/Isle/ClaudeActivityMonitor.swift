import Foundation
import CoreServices

/// Tells the usage readout when something is actively working with Claude, by watching for writes to Claude's session logs.
/// File-system events, no polling. Only the time of a write is kept: the files are never opened or read.
final class ClaudeActivityMonitor {
    /// Called on the main thread with the time of the latest write to a Claude session log.
    var onWrite: ((Date) -> Void)?

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "isle.claude-activity", qos: .utility)

    /// Claude Code's transcripts (the CLI, editor integrations, and the Claude app's Code tab all write here), plus the Claude
    /// app's own session folders when they exist. Folders that don't exist are skipped.
    static func roots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let support = home.appendingPathComponent("Library/Application Support/Claude")
        let candidates = [
            home.appendingPathComponent(".claude/projects"),
            support.appendingPathComponent("claude-code-sessions"),
            support.appendingPathComponent("local-agent-mode-sessions"),
        ]
        var found = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        // A brand-new install has no projects folder yet: watch ~/.claude so the first session is noticed.
        if !found.contains(candidates[0]), FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) {
            found.append(home.appendingPathComponent(".claude"))
        }
        return found
    }

    /// Whether a changed path is a session-log write (as opposed to other files under ~/.claude, which change when idle too).
    static func isSessionWrite(path: String, flags: FSEventStreamEventFlags) -> Bool {
        let written = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemRenamed)
        guard flags & written != 0, flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 else { return false }
        if path.contains("/Library/Application Support/Claude/") { return true }
        return path.contains("/.claude/projects/") && path.hasSuffix(".jsonl")
    }

    func start() {
        guard stream == nil else { return }
        let paths = Self.roots().map(\.path)
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<ClaudeActivityMonitor>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            for i in 0..<min(count, list.count) where ClaudeActivityMonitor.isSessionWrite(path: list[i], flags: flags[i]) {
                let now = Date()
                DispatchQueue.main.async { me.onWrite?(now) }
                return
            }
        }
        guard let s = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
