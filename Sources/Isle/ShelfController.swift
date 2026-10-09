import AppKit
import IsleCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

@MainActor
final class ShelfController: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published var selection: Set<String> = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]

    let store: ShelfStore
    private let work = DispatchQueue(label: "isle.shelf", qos: .userInitiated)
    private var quickLookURLs: [URL] = []

    init() {
        let dir = Paths.support.appendingPathComponent("Shelf", isDirectory: true)
        store = ShelfStore(directory: dir)
    }

    func start() {
        items = store.load()
        purgeIfNeeded()
        items.forEach(loadThumbnail)
    }

    func purgeIfNeeded() {
        let days = Settings.shared.shelfAutoClearDays
        if days > 0, store.purgeExpired(days: days) > 0 { items = store.items; selection = selection.filter { id in items.contains { $0.id == id } } }
    }

    // MARK: Adding

    /// Copies off the main thread (large folders), then publishes.
    func add(urls: [URL]) {
        work.async { [weak self] in
            guard let self else { return }
            let added = self.store.add(urls)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.items = self.store.items
                    added.forEach(self.loadThumbnail)
                }
            }
        }
    }

    func add(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url, url.isFileURL else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.add(urls: [url]) } }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.addLink(url) } }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
                    guard let text, !text.isEmpty else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.addText(text) } }
                }
            }
        }
        return handled
    }

    func addText(_ text: String) {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Text"
        if let item = store.addText(text, suggestedName: firstLine, fileExtension: "txt") {
            items = store.items
            loadThumbnail(item)
        }
    }

    func addLink(_ url: URL) {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>URL</key><string>\(url.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</string></dict></plist>
        """
        let name = url.host ?? "Link"
        if let item = store.addText(plist, suggestedName: name, fileExtension: "webloc") {
            items = store.items
            loadThumbnail(item)
        }
    }

    // MARK: Actions

    func url(for item: ShelfItem) -> URL? { store.url(for: item) }

    func selectedItems() -> [ShelfItem] { items.filter { selection.contains($0.id) } }

    func removeSelected() { remove(ids: selection) }

    func remove(ids: Set<String>) {
        store.remove(ids: ids)
        items = store.items
        selection.subtract(ids)
        for id in ids { thumbnails[id] = nil }
    }

    func clearAll() {
        store.clear()
        items = []
        selection = []
        thumbnails = [:]
    }

    func reveal(_ items: [ShelfItem]) {
        let urls = items.compactMap(url(for:))
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func open(_ item: ShelfItem) {
        if let url = url(for: item) { NSWorkspace.shared.open(url) }
    }

    func share(_ items: [ShelfItem], from view: NSView?) {
        let urls = items.compactMap(url(for:))
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        if let view { picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY) }
    }

    func airDrop(_ items: [ShelfItem]) {
        let urls = items.compactMap(url(for:))
        AirDrop.send(urls)
    }

    // MARK: Thumbnails

    private func loadThumbnail(_ item: ShelfItem) {
        guard let url = store.url(for: item) else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96), scale: scale, representationTypes: .all)
        let id = item.id
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            let image = rep?.nsImage ?? NSWorkspace.shared.icon(forFile: url.path)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.thumbnails[id] = image } }
        }
    }
}

enum AirDrop {
    /// Opens the system AirDrop share. macOS does not tell apps which devices are nearby, so the system sheet picks.
    @MainActor static func send(_ items: [Any]) {
        guard !items.isEmpty else { return }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            Log.write("AirDrop sharing service unavailable")
            return
        }
        if service.canPerform(withItems: items) {
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: items)
        } else {
            Log.write("AirDrop cannot perform with these items")
        }
    }

    static func openInFinder() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else if let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            // Fallback: Finder's Go menu AirDrop window via AppleScript.
            _ = finder
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to activate\ntell application \"System Events\" to keystroke \"r\" using {command down, shift down}")?.executeAndReturnError(&err)
        }
    }
}
