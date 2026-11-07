import SwiftUI

/// The header battery chip. With KwikBattery installed it becomes a button that shows a brief battery card inside the island; without
/// KwikBattery the chip is exactly what it always was.
struct LinkedBatteryChip: View {
    let state: BatteryState
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var env: AppEnv

    var body: some View {
        if KwikBatteryFeed.isInstalled {
            Button {
                model.showGlanceCard = false
                model.showBatterySummary.toggle()
                if model.showBatterySummary { env.kwik.requestSummary() }
            } label: { BatteryChip(state: state) }
                .buttonStyle(PressStyle())
                .help("Battery details")
                .accessibilityHint("Shows time left and power flow")
        } else {
            BatteryChip(state: state)
        }
    }
}
