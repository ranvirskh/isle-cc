import AppKit
import CoreServices
import IsleCore

/// Watches ~/Downloads for browser partial files (names and sizes only; contents are never read). Event driven:
/// the only timer is one single-shot aimed at the moment a stalled download should disappear.
@MainActor
final class DownloadsController: ObservableObject {
    @Published private(set) var summary: DownloadSummary?
    var onFinished: ((String, Int64) -> Void)?

    private var tracker = DownloadTracker()
    private var stream: FSEventStreamRef?
    private var expiry: Timer?
    private var observer: NSObjectProtocol?
    private let settings = Settings.shared
    private let fm = FileManager.default

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if (n.object as? String) == SettingsKey.downloadsIndicator { self?.sync() } }
        }
        sync()
    }

    private func sync() {
        if settings.downloadsIndicator { watch() } else { unwatch() }
    }

    private var downloadsURL: URL? { fm.urls(for: .downloadsDirectory, in: .userDomainMask).first }

    private func watch() {
        guard stream == nil, let dir = downloadsURL, fm.fileExists(atPath: dir.path) else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, { _, info, _, rawPaths, _, _ in
            guard let info else { return }
            let me = Unmanaged<DownloadsController>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(rawPaths, to: CFArray.self) as? [String]) ?? []
            DispatchQueue.main.async { MainActor.assumeIsolated { me.changed(paths) } }
        }, &ctx, [dir.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    private func unwatch() {
        if let s = stream {
            FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            stream = nil
        }
        expiry?.invalidate()
        expiry = nil
        tracker = DownloadTracker()
        summary = nil
    }

    private func changed(_ paths: [String]) {
        let now = Date()
        for path in paths where DownloadTracker.isPartial(path) {
            let size = Self.size(atPath: path, fm: fm)
            let final = (path as NSString).deletingLastPathComponent + "/" + DownloadTracker.finalName(forPartial: path)
            let events = tracker.update(path: path, size: size, finalExists: fm.fileExists(atPath: final), now: now)
            for e in events {
                if case .finished(let name, let bytes, _) = e { onFinished?(name, bytes) }
            }
        }
        publish(now)
    }

    private func publish(_ now: Date) {
        let s = tracker.summary(now: now)
        if s != summary { summary = s }
        expiry?.invalidate()
        expiry = nil
        if let next = tracker.nextExpiry() {
            let t = Timer.scheduledTimer(withTimeInterval: max(0.5, next.timeIntervalSinceNow + 0.2), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.tracker.expireStale(now: Date())
                    self.publish(Date())
                }
            }
            t.tolerance = 0.5
            expiry = t
        }
    }

    /// Size of a file, or the shallow total of a folder (Safari's .download is a folder). nil when it does not exist.
    private static func size(atPath path: String, fm: FileManager) -> Int64? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            return ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        let items = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        return items.reduce(Int64(0)) { sum, name in
            sum + (((try? fm.attributesOfItem(atPath: path + "/" + name))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}
