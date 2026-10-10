import Foundation

/// How long Keep Awake holds the Mac awake. `nil` duration means until turned off.
public enum KeepAwakeDuration: Int, CaseIterable, Identifiable {
    case indefinite = 0, min15 = 15, min30 = 30, hour1 = 60, hour2 = 120, hour4 = 240
    public var id: Int { rawValue }
    public var seconds: TimeInterval? { self == .indefinite ? nil : TimeInterval(rawValue * 60) }
    public var label: String {
        switch self {
        case .indefinite: return "∞"
        case .min15, .min30: return "\(rawValue)m"
        default: return "\(rawValue / 60)h"
        }
    }
}
