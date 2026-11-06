import SwiftUI
import AppKit

/// The header battery chip. With KwikBattery installed it becomes a button that opens KwikBattery's panel from the chip; without it
/// the chip is exactly what it always was.
struct LinkedBatteryChip: View {
    let state: BatteryState
    @State private var probe = ScreenRectProbe.Holder()

    var body: some View {
        if KwikBatteryLauncher.isInstalled {
            Button { KwikBatteryLauncher.open(anchor: probe.anchorBelowIsland(visibleIsland: AppDelegate.shared.env.island?.active?.visibleFrame)) } label: { BatteryChip(state: state) }
                .buttonStyle(PressStyle())
                .background(ScreenRectProbe(holder: probe))
                // The header leaves the screen when the island closes; the summary it opened should go with it.
                .onDisappear { KwikBatteryLauncher.close() }
                .help("Open KwikBattery")
                .accessibilityHint("Opens KwikBattery")
        } else {
            BatteryChip(state: state)
        }
    }
}

/// Reads where a SwiftUI view is on screen, at the moment it is asked.
struct ScreenRectProbe: NSViewRepresentable {
    final class Holder {
        fileprivate weak var view: NSView?
        func screenRect() -> CGRect? {
            guard let view, let window = view.window else { return nil }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }

        /// A thin strip on the island's visible bottom edge, directly under this view. KwikBattery hangs its panel from it, so the panel drops
        /// out of the island like a menu instead of overlapping it (the icon is at the top of the island, and the island is drawn
        /// over anything that hangs from there).
        func anchorBelowIsland(visibleIsland: CGRect?) -> CGRect? {
            guard let chip = screenRect(), let window = view?.window else { return nil }
            // The visible shape's bottom, not the (larger) window's, so there is no gap under a smaller island.
            return CGRect(x: chip.minX, y: visibleIsland?.minY ?? window.frame.minY, width: chip.width, height: 1)
        }
    }
    let holder: Holder
    func makeNSView(context: Context) -> NSView { let v = NSView(); holder.view = v; return v }
    func updateNSView(_ nsView: NSView, context: Context) { holder.view = nsView }
}
