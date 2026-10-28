import AppKit
import IsleCore
import SQLite3

/// Tokens used in today's Antigravity conversations, for the notch while the Gemini app is in front. Gemini reports no usage
/// limit, so this is a plain count. Reads only two numbers per model call from the local conversation databases (see
/// `AntigravityTokens`), never any text, and only when the Gemini app comes to the front (no timer, no network).
@MainActor
final class AntigravityController: ObservableObject {
    static let bundleID = "com.google.GeminiMacOS"
    @Published private(set) var todayTokens: Int?

    private var observer: NSObjectProtocol?
    private var lastRead = Date.distantPast
    private var reading = false
    /// Per database: its modification time and its token total, so an unchanged file is not read again.
    private var cache: [String: (modified: Date, total: Int)] = [:]
    private let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/conversations")

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if id == Self.bundleID { self?.refresh() } }
        }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleID { refresh() }
    }

    private func refresh() {
        guard !reading, Date().timeIntervalSince(lastRead) > 20 else { return }
        reading = true
        lastRead = Date()
        let dir = directory
        let known = cache
        Task.detached(priority: .utility) {
            let result = Self.scan(dir, known: known)
            await MainActor.run {
                self.cache = result.cache
                self.todayTokens = result.total
                Log.write("antigravity: \(result.total.map { String($0) } ?? "no conversation today") tokens today")
                self.reading = false
            }
        }
    }

    nonisolated private static func scan(_ dir: URL, known: [String: (modified: Date, total: Int)]) -> (total: Int?, cache: [String: (modified: Date, total: Int)]) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { return (nil, known) }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        var cache: [String: (modified: Date, total: Int)] = [:]
        var total = 0
        var any = false
        for url in files where url.pathExtension == "db" {
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            // Only conversations touched today count; older ones are skipped without being opened.
            guard modified >= startOfDay else { continue }
            let sum: Int
            if let c = known[url.path], c.modified == modified { sum = c.total } else { sum = tokens(in: url) ?? 0 }
            cache[url.path] = (modified, sum)
            total += sum
            any = true
        }
        return (any ? total : nil, cache)
    }

    /// Total input plus output tokens across every model call in one conversation database.
    nonisolated private static func tokens(in url: URL) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM gen_metadata", -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        var total = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(stmt, 0) else { continue }
            let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
            if let c = AntigravityTokens.counts(inBlob: blob) { total += c.total }
        }
        return total
    }
}
