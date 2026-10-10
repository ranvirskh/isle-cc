import AppKit
import Carbon.HIToolbox
import IsleCore

/// Global shortcuts through Carbon hotkeys (public API, no permission):
/// Control-Option-Space opens or closes the island; Control-Option-1...6 jump to a tab.
@MainActor
final class HotkeyController {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var observer: NSObjectProtocol?
    private let settings = Settings.shared
    var onToggle: (() -> Void)?
    var onTab: ((Int) -> Void)?

    private static let digitKeys: [Int] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6]

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if (n.object as? String) == SettingsKey.shortcutsEnabled { self?.sync() } }
        }
        sync()
    }

    private func sync() {
        unregister()
        if settings.shortcutsEnabled { register() }
    }

    private func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.fire(Int(hk.id)) } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let mods = UInt32(controlKey | optionKey)
        add(id: 0, key: kVK_Space, mods: mods)
        for (i, k) in Self.digitKeys.enumerated() { add(id: i + 1, key: k, mods: mods) }
    }

    private func add(id: Int, key: Int, mods: UInt32) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x49534C45), id: UInt32(id))   // 'ISLE'
        if RegisterEventHotKey(UInt32(key), mods, hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref { refs.append(ref) }
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }; refs = []
        if let h = handler { RemoveEventHandler(h); handler = nil }
    }

    private func fire(_ id: Int) {
        if id == 0 { onToggle?() } else { onTab?(id - 1) }
    }
}
