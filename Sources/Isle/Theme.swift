import SwiftUI
import IsleCore

/// Colors and surfaces for each theme. Views read it from the environment.
struct ThemeStyle {
    let theme: IslandTheme

    var accent: Color {
        switch theme {
        case .frutigerAero: return Color(red: 0.45, green: 0.95, blue: 0.85)
        default: return Color(red: 0.55, green: 0.8, blue: 1)
        }
    }

    /// Fill of the island. The top stays pure black in every theme so the shape merges with the hardware notch.
    var background: AnyShapeStyle {
        switch theme {
        case .frutigerAero:
            return AnyShapeStyle(LinearGradient(stops: [
                .init(color: .black, location: 0.0),
                .init(color: Color(red: 0.02, green: 0.16, blue: 0.28), location: 0.25),
                .init(color: Color(red: 0.0, green: 0.38, blue: 0.52), location: 0.7),
                .init(color: Color(red: 0.1, green: 0.62, blue: 0.62), location: 1.0),
            ], startPoint: .top, endPoint: .bottom))
        default:
            return AnyShapeStyle(Color.black)
        }
    }

    var hasGloss: Bool { theme == .frutigerAero }
    var selectedTab: Color { theme == .frutigerAero ? Color.white.opacity(0.28) : Color.white.opacity(0.18) }
    var progressFill: Color { theme == .frutigerAero ? Color(red: 0.6, green: 1, blue: 0.9) : Color.white.opacity(0.9) }
    var showsCalendar: Bool { !theme.isCompact }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = ThemeStyle(theme: .classic) }
extension EnvironmentValues {
    var themeStyle: ThemeStyle {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
