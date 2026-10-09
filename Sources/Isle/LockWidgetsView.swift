import SwiftUI
import IsleCore

/// Status pills for the lock screen: weather, charging, Bluetooth device batteries. Display only.
struct LockWidgetsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var weather: WeatherController
    @ObservedObject var devices: DevicesController

    static let size = CGSize(width: 440, height: 44)

    var body: some View {
        HStack(spacing: 8) {
            if settings.lockWidgetWeather, settings.weatherEnabled, let w = weather.reading {
                pill {
                    Image(systemName: w.symbol).symbolRenderingMode(.multicolor)
                    Text("\(w.temperatureText) \(w.place.name)").lineLimit(1)
                }
            }
            if settings.lockWidgetCharging, devices.battery.hasBattery, let p = devices.battery.percent {
                pill {
                    Image(systemName: devices.battery.isCharging ? "bolt.fill" : "battery.50percent")
                        .foregroundStyle(devices.battery.isCharging ? Color.green : Color.white)
                    Text("\(p)%")
                }
            }
            if settings.lockWidgetBluetooth {
                ForEach(devices.connected.prefix(3)) { d in
                    pill {
                        Image(systemName: DeviceSymbols.firstAvailable(name: d.name, kind: .unknown))
                        Text(d.battery.readings.map { "\($0.percent)%" }.prefix(1).joined())
                    }
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .allowsHitTesting(false)
        .environment(\.colorScheme, .dark)
    }

    private func pill<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 5) { content() }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .modifier(LockGlass(cornerRadius: 22))
            .accessibilityElement(children: .combine)
    }

    /// True when at least one pill would show, so an empty panel is never put on the lock screen.
    static func hasContent(settings: Settings, weather: WeatherController, devices: DevicesController) -> Bool {
        (settings.lockWidgetWeather && settings.weatherEnabled && weather.reading != nil)
            || (settings.lockWidgetCharging && devices.battery.hasBattery)
            || (settings.lockWidgetBluetooth && !devices.connected.isEmpty)
    }
}
