import Foundation

/// Whether a Claude Code process (`claude`) is running. One sysctl call, made only when the frontmost app changes to a terminal,
/// never on a timer. Only process names are looked at.
enum ClaudeProcessProbe {
    static func isRunning() -> Bool {
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
                if name == "claude" { return true }
            }
            return false
        }
    }
}
