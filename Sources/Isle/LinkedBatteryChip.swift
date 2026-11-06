import SwiftUI
import AppKit

/// The header battery chip. With KwikBattery installed it becomes a button that opens KwikBattery's panel from the chip; without it
/// the chip is exactly what it always was.
struct LinkedBatteryChip: View {
    let state: BatteryState
    @State private var probe = ScreenRectProbe.Holder()

    var body: some View {
        if KwikBatteryLauncher.isInstalled {
            Button { KwikBatteryLauncher.open(anchor: probe.screenRect()) } label: { BatteryChip(state: state) }
                .buttonStyle(PressStyle())
                .background(ScreenRectProbe(holder: probe))
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
    }
    let holder: Holder
    func makeNSView(context: Context) -> NSView { let v = NSView(); holder.view = v; return v }
    func updateNSView(_ nsView: NSView, context: Context) { holder.view = nsView }
}
