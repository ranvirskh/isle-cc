import AppKit
import IsleCore

/// Recent text copies. Polls the pasteboard change count (no permission needed), keeps text in memory only and
/// skips anything marked concealed or transient by password managers.
@MainActor
final class ClipboardController: ObservableObject {
    @Published private(set) var history = ClipboardHistory()
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private let settings = Settings.shared

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if (n.object as? String) == SettingsKey.clipboardEnabled { self?.sync() } }
        }
        sync()
    }

    private func sync() {
        timer?.invalidate(); timer = nil
        guard settings.clipboardEnabled else { history.clear(); return }
        lastChange = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.3
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        let types = (pb.types ?? []).map(\.rawValue)
        guard let text = pb.string(forType: .string) else { return }
        history.add(text, types: types, now: Date())
    }

    /// Puts an item back on the pasteboard without recording it as a new copy.
    func copy(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.text, forType: .string)
        lastChange = pb.changeCount
        history.add(item.text, types: [], now: Date())
    }

    func remove(_ item: ClipboardItem) { history.remove(id: item.id) }
    func clear() { history.clear() }
}
