import Darwin
import Foundation
import IsleCore

/// CPU, memory, network and disk. Samples once a second, and only while the System tab is on screen.
@MainActor
final class StatsController: ObservableObject {
    @Published private(set) var cpu: Double?
    @Published private(set) var memory: Double?
    @Published private(set) var memoryUsed: UInt64 = 0
    @Published private(set) var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var down: Double = 0
    @Published private(set) var up: Double = 0
    @Published private(set) var diskFree: UInt64 = 0
    @Published private(set) var diskTotal: UInt64 = 0
    @Published private(set) var cpuHistory: [Double] = []

    private var timer: Timer?
    private var lastTicks: CPUTicks?
    private var lastNet: NetCounters?
    private var lastNetDate = Date()

    func start() {
        guard timer == nil else { return }
        lastTicks = Self.readTicks(); lastNet = Self.readNet(); lastNetDate = Date()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil; lastTicks = nil; lastNet = nil }

    private func sample() {
        if let t = Self.readTicks() {
            if let prev = lastTicks, let u = CPUTicks.usage(from: prev, to: t) {
                cpu = u
                cpuHistory.append(u)
                if cpuHistory.count > 40 { cpuHistory.removeFirst(cpuHistory.count - 40) }
            }
            lastTicks = t
        }
        if let (used, total) = Self.readMemory() {
            memoryUsed = used; memoryTotal = total
            memory = total > 0 ? Double(used) / Double(total) : nil
        }
        let nowDate = Date()
        if let n = Self.readNet() {
            if let prev = lastNet, let r = NetCounters.rates(from: prev, to: n, seconds: nowDate.timeIntervalSince(lastNetDate)) {
                down = r.down; up = r.up
            }
            lastNet = n; lastNetDate = nowDate
        }
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = UInt64(max(0, v.volumeAvailableCapacityForImportantUsage ?? 0))
            diskTotal = UInt64(max(0, v.volumeTotalCapacity ?? 0))
        }
    }

    private static func readTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return CPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1), idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }

    /// "Used" the way Activity Monitor counts it: app (active + wired + compressed) memory.
    private static func readMemory() -> (UInt64, UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (used, ProcessInfo.processInfo.physicalMemory)
    }

    private static func readNet() -> NetCounters? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
               let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self).pointee as if_data? {
                rx += UInt64(data.ifi_ibytes); tx += UInt64(data.ifi_obytes)
            }
            p = ifa.ifa_next
        }
        return NetCounters(rx: rx, tx: tx)
    }
}
