import Foundation

/// CPU tick counters from host_statistics (cumulative since boot).
public struct CPUTicks: Equatable {
    public var user, system, idle, nice: UInt64
    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) { self.user = user; self.system = system; self.idle = idle; self.nice = nice }
    var busy: UInt64 { user &+ system &+ nice }
    var total: UInt64 { busy &+ idle }

    /// Fraction 0...1 of non-idle time between two samples; nil when no time passed.
    public static func usage(from a: CPUTicks, to b: CPUTicks) -> Double? {
        guard b.total > a.total else { return nil }
        let busy = Double(b.busy &- a.busy), total = Double(b.total &- a.total)
        return min(1, max(0, busy / total))
    }
}

/// Cumulative network byte counters; the rate is the difference over the elapsed time.
public struct NetCounters: Equatable {
    public var rx: UInt64, tx: UInt64
    public init(rx: UInt64, tx: UInt64) { self.rx = rx; self.tx = tx }

    /// Bytes per second (down, up). A counter that went backwards (interface reset) counts as zero.
    public static func rates(from a: NetCounters, to b: NetCounters, seconds: TimeInterval) -> (down: Double, up: Double)? {
        guard seconds > 0 else { return nil }
        let d = b.rx >= a.rx ? Double(b.rx - a.rx) : 0
        let u = b.tx >= a.tx ? Double(b.tx - a.tx) : 0
        return (d / seconds, u / seconds)
    }
}

public enum StatsFormat {
    /// "1.2 MB/s", "340 KB/s", "0 B/s".
    public static func rate(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        if v >= 1_000_000_000 { return String(format: "%.1f GB/s", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.1f MB/s", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0f KB/s", v / 1_000) }
        return String(format: "%.0f B/s", v)
    }

    public static func bytes(_ n: UInt64) -> String {
        let v = Double(n)
        if v >= 1e12 { return String(format: "%.1f TB", v / 1e12) }
        if v >= 1e9 { return String(format: "%.1f GB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.0f MB", v / 1e6) }
        return String(format: "%.0f KB", v / 1e3)
    }

    public static func percent(_ fraction: Double) -> String { String(format: "%.0f%%", min(1, max(0, fraction)) * 100) }
}
