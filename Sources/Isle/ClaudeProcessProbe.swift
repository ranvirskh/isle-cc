import Foundation

/// Whether a process with this name (default: Claude Code's `claude`) is running. One sysctl call, made only when the frontmost app changes to a terminal,
/// never on a timer. Only process names are looked at.
enum ClaudeProcessProbe {
    static func isRunning(_ process: String = "claude") -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: size + size / 8)
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return false }
        let stride = MemoryLayout<kinfo_proc>.stride
        return buffer.withUnsafeBytes { raw in
            for i in 0..<(size / stride) {
                let p = raw.loadUnaligned(fromByteOffset: i * stride, as: kinfo_proc.self)
                let name = withUnsafeBytes(of: p.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if name == process { return true }
                // Claude Code's native build runs as `~/.local/share/claude/versions/2.1.308`, so the kernel names the process
                // after its version. Those (and only those) are checked further: the executable's path must end in /claude or contain /claude/.
                if process == "claude", looksLikeVersion(name), executablePath(p.kp_proc.p_pid).map { $0.hasSuffix("/claude") || $0.contains("/claude/") } == true { return true }
            }
            return false
        }
    }

    private static func looksLikeVersion(_ name: String) -> Bool {
        guard let first = name.first, first.isNumber else { return false }
        return name.allSatisfy { $0.isNumber || $0 == "." } && name.contains(".")
    }

    /// The path a process was started from (first string of its arguments block).
    private static func executablePath(_ pid: Int32) -> String? {
        var args: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&args, 3, nil, &size, nil, 0) == 0, size > 4, size < 1 << 20 else { return nil }
        var raw = [UInt8](repeating: 0, count: size)
        guard sysctl(&args, 3, &raw, &size, nil, 0) == 0 else { return nil }
        return String(decoding: raw.prefix(size).dropFirst(4).prefix { $0 != 0 }, as: UTF8.self)
    }

    /// The Gemini CLI is a Node script, so its process is called `node`; its name only shows in the arguments (`.../bin/gemini`).
    /// Looks at the arguments of `node` processes only, and only for whether one runs a script named `gemini`.
    static func geminiNodeRunning() -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: size + size / 8)
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return false }
        let stride = MemoryLayout<kinfo_proc>.stride
        for i in 0..<(size / stride) {
            let p = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * stride, as: kinfo_proc.self) }
            let name = withUnsafeBytes(of: p.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == "node" else { continue }
            var args: [Int32] = [CTL_KERN, KERN_PROCARGS2, p.kp_proc.p_pid]
            var argSize = 0
            guard sysctl(&args, 3, nil, &argSize, nil, 0) == 0, argSize > 0, argSize < 1 << 20 else { continue }
            var raw = [UInt8](repeating: 0, count: argSize)
            guard sysctl(&args, 3, &raw, &argSize, nil, 0) == 0 else { continue }
            // Layout: argc (Int32), the executable path, then the NUL-separated arguments. Only the first few are checked.
            let text = String(decoding: raw.prefix(argSize).dropFirst(4), as: UTF8.self)
            let parts = text.split(separator: "\0", omittingEmptySubsequences: true).prefix(6)
            if parts.contains(where: { $0.hasSuffix("/gemini") || $0 == "gemini" }) { return true }
        }
        return false
    }
}
