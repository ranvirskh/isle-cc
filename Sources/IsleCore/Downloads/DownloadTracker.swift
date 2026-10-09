import Foundation

/// One download in progress, recognised by the temporary file the browser writes while it downloads.
public struct DownloadItem: Equatable, Identifiable {
    public var id: String          // path of the partial file
    public var name: String        // final file name
    public var bytes: Int64
    public var startedAt: Date
    public var lastGrowth: Date
    /// Bytes per second over the recent past, 0 until two samples exist.
    public var rate: Double
}

public struct DownloadSummary: Equatable {
    public var count: Int
    public var bytes: Int64
    public var rate: Double
    public var firstName: String
}

/// Follows browser "partial" files in the Downloads folder. Pure: callers report what they see on disk.
/// Only file names and sizes are used; file contents are never read.
public struct DownloadTracker {
    public enum Event: Equatable {
        case started(name: String)
        /// The partial file went away and the finished file exists.
        case finished(name: String, bytes: Int64, duration: TimeInterval)
        /// The partial file went away without a finished file (cancelled).
        case cancelled(name: String)
    }

    /// Chrome / Edge / Brave / Arc, Safari (a folder), Firefox, Opera.
    public static let partialSuffixes = [".crdownload", ".download", ".part", ".opdownload"]
    /// A download that has not grown for this long is not shown as active any more.
    public var staleAfter: TimeInterval = 20
    /// Ignore partial files that finish almost at once, so tiny downloads do not flash the island.
    public var minimumDuration: TimeInterval = 1.5

    public private(set) var items: [String: DownloadItem] = [:]

    public init() {}

    public static func isPartial(_ path: String) -> Bool {
        let lower = path.lowercased()
        return partialSuffixes.contains { lower.hasSuffix($0) }
    }

    /// "Report.pdf.crdownload" -> "Report.pdf". Falls back to the file name when nothing remains.
    public static func finalName(forPartial path: String) -> String {
        let file = (path as NSString).lastPathComponent
        let lower = file.lowercased()
        for suffix in partialSuffixes where lower.hasSuffix(suffix) {
            let trimmed = String(file.dropLast(suffix.count))
            return trimmed.isEmpty ? file : trimmed
        }
        return file
    }

    /// Reports the partial file at `path`. `size` is nil when it no longer exists; `finalExists` says whether the
    /// finished file is now present (decides finished vs cancelled).
    @discardableResult
    public mutating func update(path: String, size: Int64?, finalExists: Bool = false, now: Date) -> [Event] {
        guard Self.isPartial(path) else { return [] }
        let name = Self.finalName(forPartial: path)
        guard let size else {
            guard let item = items.removeValue(forKey: path) else { return [] }
            let duration = now.timeIntervalSince(item.startedAt)
            if finalExists {
                return duration >= minimumDuration ? [.finished(name: name, bytes: max(item.bytes, 0), duration: duration)] : []
            }
            return [.cancelled(name: name)]
        }
        if var item = items[path] {
            let dt = now.timeIntervalSince(item.lastGrowth)
            if size > item.bytes {
                if dt > 0.05 { item.rate = Double(size - item.bytes) / dt }
                item.lastGrowth = now
            }
            item.bytes = size
            items[path] = item
            return []
        }
        items[path] = DownloadItem(id: path, name: name, bytes: size, startedAt: now, lastGrowth: now, rate: 0)
        return [.started(name: name)]
    }

    /// Drops downloads that stopped growing (paused or abandoned).
    public mutating func expireStale(now: Date) {
        items = items.filter { now.timeIntervalSince($0.value.lastGrowth) <= staleAfter }
    }

    public func summary(now: Date) -> DownloadSummary? {
        let active = items.values.filter { now.timeIntervalSince($0.lastGrowth) <= staleAfter }
        guard let first = active.min(by: { $0.startedAt < $1.startedAt }) else { return nil }
        return DownloadSummary(count: active.count, bytes: active.reduce(0) { $0 + $1.bytes },
                               rate: active.reduce(0) { $0 + $1.rate }, firstName: first.name)
    }

    /// The next moment `expireStale` would change something, so a single timer can be scheduled.
    public func nextExpiry() -> Date? {
        items.values.map { $0.lastGrowth.addingTimeInterval(staleAfter) }.min()
    }

    public static func format(bytes: Int64) -> String {
        let b = Double(max(0, bytes))
        if b >= 1_000_000_000 { return String(format: "%.1f GB", b / 1_000_000_000) }
        if b >= 1_000_000 { return String(format: "%.0f MB", b / 1_000_000) }
        if b >= 1_000 { return String(format: "%.0f KB", b / 1_000) }
        return "\(Int(b)) B"
    }
}
