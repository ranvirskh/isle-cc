import SwiftUI
import AppKit
import Quartz
import IsleCore
import UniformTypeIdentifiers

private let dropTypes: [UTType] = [.fileURL, .url, .plainText]

/// Reads dropped providers (files, folders, links, text) and hands them to the system AirDrop share.
@MainActor
func airDrop(providers: [NSItemProvider]) -> Bool {
    var urls: [URL] = []
    var texts: [String] = []
    let group = DispatchGroup()
    var handled = false
    for p in providers {
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            handled = true
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { urls.append(url) } }
                group.leave()
            }
        } else if p.canLoadObject(ofClass: String.self) {
            handled = true
            group.enter()
            _ = p.loadObject(ofClass: String.self) { s, _ in
                if let s { DispatchQueue.main.async { texts.append(s) } }
                group.leave()
            }
        }
    }
    group.notify(queue: .main) {
        MainActor.assumeIsolated { AirDrop.send(urls as [Any] + texts as [Any]) }
    }
    return handled
}

/// Compact AirDrop target that sits beside the shelf: drop anything on it and the system AirDrop sheet opens.
struct AirDropColumn: View {
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            DropZone(symbol: "dot.radiowaves.left.and.right", title: "AirDrop", subtitle: "Drop to send", targeted: targeted)
                .onDrop(of: dropTypes, isTargeted: $targeted) { airDrop(providers: $0) }
            Button { AirDrop.openInFinder() } label: { Label("Open in Finder", systemImage: "folder") }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .frame(width: 170)
    }
}

struct DropZone: View {
    let symbol: String
    let title: String
    let subtitle: String
    let targeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.white.opacity(targeted ? 0.9 : 0.3), style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: [7, 5]))
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(targeted ? 0.12 : 0.04)))
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 28)).symbolEffect(.pulse, isActive: targeted)
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                .foregroundStyle(.white.opacity(targeted ? 1 : 0.8))
            )
            .scaleEffect(targeted ? 1.015 : 1)
            .animation(Motion.spring(Motion.buttonPress, .buttons), value: targeted)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
    }
}

/// Shown while something is dragged toward the notch.
struct DropTargetsView: View {
    @EnvironmentObject var shelf: ShelfController
    @EnvironmentObject var env: AppEnv
    @State private var airTargeted = false
    @State private var shelfTargeted = false

    var body: some View {
        HStack(spacing: 14) {
            DropZone(symbol: "dot.radiowaves.left.and.right", title: "AirDrop", subtitle: "Send with AirDrop", targeted: airTargeted)
                .onDrop(of: dropTypes, isTargeted: $airTargeted) { airDrop(providers: $0) }
            DropZone(symbol: "tray.and.arrow.down.fill", title: "Shelf", subtitle: "Keep it here for later", targeted: shelfTargeted)
                .onDrop(of: dropTypes, isTargeted: $shelfTargeted) { providers in
                    let ok = shelf.add(providers: providers)
                    if ok { env.island.setTab(.shelf) }
                    return ok
                }
        }
        .foregroundStyle(.white)
    }
}

struct ShelfView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AirDropColumn()
            Divider().overlay(Color.white.opacity(0.12))
            ShelfColumn()
        }
        .foregroundStyle(.white)
    }
}

struct ShelfColumn: View {
    @EnvironmentObject var shelf: ShelfController
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(shelf.items.isEmpty ? "Shelf" : "\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !shelf.selection.isEmpty {
                    SmallButton(symbol: "square.and.arrow.up", label: "Share") { shelf.share(shelf.selectedItems(), from: NSApp.keyWindow?.contentView) }
                    SmallButton(symbol: "dot.radiowaves.left.and.right", label: "AirDrop") { shelf.airDrop(shelf.selectedItems()) }
                    SmallButton(symbol: "magnifyingglass", label: "Reveal in Finder") { shelf.reveal(shelf.selectedItems()) }
                    SmallButton(symbol: "xmark.circle", label: "Remove") { shelf.removeSelected() }
                }
                if !shelf.items.isEmpty {
                    SmallButton(symbol: "trash", label: "Clear all") { shelf.clearAll() }
                }
            }
            ZStack {
                if shelf.items.isEmpty {
                    DropZone(symbol: "tray.and.arrow.down.fill", title: "Drop files here", subtitle: "They stay on the shelf until you remove them", targeted: targeted)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(shelf.items) { item in ShelfTile(item: item) }
                        }
                        .padding(.horizontal, 2)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(targeted ? 0.8 : 0), lineWidth: 2))
                }
            }
            .onDrop(of: dropTypes, isTargeted: $targeted) { shelf.add(providers: $0) }
        }
        .foregroundStyle(.white)
    }
}

struct SmallButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 22)
        }
        .buttonStyle(PressStyle()).help(label).accessibilityLabel(label)
    }
}

struct ShelfTile: View {
    @EnvironmentObject var shelf: ShelfController
    @EnvironmentObject var env: AppEnv
    let item: ShelfItem

    var body: some View {
        let selected = shelf.selection.contains(item.id)
        VStack(spacing: 4) {
            Group {
                if let image = shelf.thumbnails[item.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 64, height: 64)
            Text(item.name).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center).frame(width: 78)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(selected ? 0.2 : 0.06)))
        .overlay(ShelfTileInteraction(item: item, shelf: shelf, island: env.island))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - AppKit interaction layer (selection, multi-file drag out, context menu, Space for Quick Look)

struct ShelfTileInteraction: NSViewRepresentable {
    let item: ShelfItem
    let shelf: ShelfController
    let island: IslandController

    func makeNSView(context: Context) -> TileNSView {
        let v = TileNSView()
        v.item = item; v.shelf = shelf; v.island = island
        return v
    }
    func updateNSView(_ v: TileNSView, context: Context) { v.item = item; v.shelf = shelf; v.island = island }
}

final class TileNSView: NSView, NSDraggingSource {
    var item: ShelfItem!
    weak var shelf: ShelfController!
    weak var island: IslandController!
    private var downPoint: NSPoint = .zero
    private var didDrag = false
    private var collapseSelectionOnUp = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor override func mouseDown(with event: NSEvent) {
        island.requestKey()
        window?.makeFirstResponder(self)
        downPoint = event.locationInWindow
        didDrag = false
        collapseSelectionOnUp = false
        if event.clickCount == 2 { shelf.open(item); return }
        if event.modifierFlags.contains(.command) {
            if shelf.selection.contains(item.id) { shelf.selection.remove(item.id) } else { shelf.selection.insert(item.id) }
        } else if event.modifierFlags.contains(.shift) {
            shelf.selection.insert(item.id)
        } else if !shelf.selection.contains(item.id) {
            shelf.selection = [item.id]
        } else if shelf.selection.count > 1 {
            collapseSelectionOnUp = true   // click on a member of a multi-selection selects just it, unless it turns into a drag
        }
    }

    @MainActor override func mouseUp(with event: NSEvent) {
        if collapseSelectionOnUp && !didDrag { shelf.selection = [item.id] }
    }

    @MainActor override func mouseDragged(with event: NSEvent) {
        guard !didDrag, hypot(event.locationInWindow.x - downPoint.x, event.locationInWindow.y - downPoint.y) > 4 else { return }
        didDrag = true
        if !shelf.selection.contains(item.id) { shelf.selection = [item.id] }
        let dragged = shelf.selectedItems()
        var draggingItems: [NSDraggingItem] = []
        for (i, it) in dragged.enumerated() {
            guard let url = shelf.url(for: it) else { continue }
            let di = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = shelf.thumbnails[it.id] ?? NSWorkspace.shared.icon(forFile: url.path)
            let frame = NSRect(x: CGFloat(i) * 6, y: CGFloat(-i) * 6, width: 56, height: 56)
            di.setDraggingFrame(frame, contents: image)
            draggingItems.append(di)
        }
        guard !draggingItems.isEmpty else { return }
        island.beginOwnDrag()
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { [.copy, .generic] }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    @MainActor override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: QuickLook.shared.show(shelf.selectedItems().compactMap(shelf.url(for:)))       // space
        case 51, 117: shelf.removeSelected()                                                     // delete, forward delete
        case 0 where event.modifierFlags.contains(.command): shelf.selection = Set(shelf.items.map(\.id))   // cmd-A
        default: super.keyDown(with: event)
        }
    }

    @MainActor override func menu(for event: NSEvent) -> NSMenu? {
        if !shelf.selection.contains(item.id) { shelf.selection = [item.id] }
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector) { let m = NSMenuItem(title: title, action: sel, keyEquivalent: ""); m.target = self; menu.addItem(m) }
        add("Open", #selector(menuOpen))
        add("Quick Look", #selector(menuQuickLook))
        add("Reveal in Finder", #selector(menuReveal))
        menu.addItem(.separator())
        add("Share…", #selector(menuShare))
        add("AirDrop…", #selector(menuAirDrop))
        menu.addItem(.separator())
        add("Remove from Shelf", #selector(menuRemove))
        return menu
    }

    @MainActor @objc private func menuOpen() { shelf.selectedItems().forEach(shelf.open) }
    @MainActor @objc private func menuQuickLook() { QuickLook.shared.show(shelf.selectedItems().compactMap(shelf.url(for:))) }
    @MainActor @objc private func menuReveal() { shelf.reveal(shelf.selectedItems()) }
    @MainActor @objc private func menuShare() { shelf.share(shelf.selectedItems(), from: self) }
    @MainActor @objc private func menuAirDrop() { shelf.airDrop(shelf.selectedItems()) }
    @MainActor @objc private func menuRemove() { shelf.removeSelected() }
}

@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { MainActor.assumeIsolated { urls.count } }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }
}
