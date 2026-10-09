import CoreGraphics

/// Visual style of the expanded island. Classic is the default look.
public enum IslandTheme: String, CaseIterable, Codable {
    case classic, minimal, frutigerAero

    public var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .minimal: return "Minimalistic"
        case .frutigerAero: return "Frutiger Aero"
        }
    }

    /// The minimalistic look is smaller and drops secondary content (calendar column, time labels).
    public var isCompact: Bool { self == .minimal }

    /// Scales the expanded island for this theme.
    public func adjust(_ size: CGSize) -> CGSize {
        guard isCompact else { return size }
        return CGSize(width: (size.width * 0.76).rounded(), height: size.height - 34)
    }

    public var artworkSide: CGFloat { isCompact ? 84 : 118 }
}
