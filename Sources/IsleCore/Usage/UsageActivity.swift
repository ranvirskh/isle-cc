import Foundation

/// When the Claude usage readout should be on screen: while something is actively spending the Claude usage limit.
///
/// The signal is activity, not which app happens to be in front. A Claude Code session writes to its session log every few
/// seconds while it streams a reply or runs tools, so a recent write means the 5-hour limit is being used right now, whether
/// that session runs in Terminal, an editor's integrated terminal, the Claude app's Code tab, or in the background while you
/// work in another app. Only the timing of a write is used; nothing is ever read from the log.
public enum UsageActivity {
    /// How long after the last session-log write something still counts as actively working. A turn writes at least every few
    /// seconds, and a long tool run (a build, a test suite) is covered by the margin.
    public static let activeWindow: TimeInterval = 90

    /// Claude's own apps: being in front of one means you are talking to Claude, which spends the limit.
    public static let claudeClientBundleIDs: Set<String> = ["com.anthropic.claudefordesktop"]

    /// Terminals and editors that host Claude Code sessions. With one in front and a `claude` process running, Claude is "open"
    /// even while it sits idle at its prompt.
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "com.jetbrains.intellij", "com.jetbrains.pycharm", "dev.zed.Zed", "dev.prism.terminal",
    ]

    /// True when a Claude client is in front, a terminal is in front with a Claude Code process running, or a session log was
    /// written within `activeWindow`. A write time in the future (clock change, odd file) never counts.
    public static func isActive(lastSessionWrite: Date?, frontmostBundleID: String?, claudeProcessRunning: Bool = false, now: Date) -> Bool {
        if let id = frontmostBundleID, claudeClientBundleIDs.contains(id) { return true }
        if claudeProcessRunning, let id = frontmostBundleID, terminalBundleIDs.contains(id) { return true }
        guard let w = lastSessionWrite, w <= now.addingTimeInterval(5) else { return false }
        return now.timeIntervalSince(w) < activeWindow
    }

    /// The moment the "recent write" part of the state runs out, so a single-shot timer can flip it off without polling.
    /// Nil when there is no recent write to expire.
    public static func expiry(lastSessionWrite: Date?, now: Date) -> Date? {
        guard let w = lastSessionWrite, w <= now.addingTimeInterval(5) else { return nil }
        let end = w.addingTimeInterval(activeWindow)
        return end > now ? end : nil
    }
}

/// Recognising Claude Code among running processes.
public enum ClaudeProcess {
    /// Claude Code's native build runs as `~/.local/share/claude/versions/2.1.308`, so the kernel names the process after
    /// its version ("2.1.308"), not "claude". Plain dotted numbers are checked further, by the path they were started from.
    public static func looksLikeVersion(_ name: String) -> Bool {
        guard let first = name.first, first.isNumber else { return false }
        return name.allSatisfy { $0.isNumber || $0 == "." } && name.contains(".")
    }

    /// True for a process called `claude`, or a version-named one started from a path ending in /claude or inside a /claude/ folder.
    public static func matches(name: String, path: String?) -> Bool {
        if name == "claude" { return true }
        guard looksLikeVersion(name), let path else { return false }
        return path.hasSuffix("/claude") || path.contains("/claude/")
    }
}

