import CoreGraphics
import Foundation

/// The facts about a display that the island layout needs. Coordinates are AppKit global (origin bottom-left).
public struct ScreenInfo: Equatable {
    public var frame: CGRect
    public var safeAreaTop: CGFloat
    public var auxiliaryTopLeft: CGRect?
    public var auxiliaryTopRight: CGRect?
    public var menuBarHeight: CGFloat

    public init(frame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?, menuBarHeight: CGFloat = 24) {
        self.frame = frame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
        self.menuBarHeight = menuBarHeight
    }

    public var hasNotch: Bool {
        guard safeAreaTop > 0, let l = auxiliaryTopLeft, let r = auxiliaryTopRight else { return false }
        return frame.width - l.width - r.width > 20
    }
}

public enum IslandTab: String, CaseIterable, Codable {
    case home, shelf, agents
}

public enum NotchGeometry {
    /// Pill drawn on displays without a notch.
    public static let pillSize = CGSize(width: 150, height: 9)
    /// Room around the expanded shape for the shadow and spring overshoot.
    public static let shadowMargin = CGSize(width: 36, height: 44)
    public static let popupSize = CGSize(width: 330, height: 78)
    /// Height of the lip under the notch that shows pop-up content beside it on notched displays.
    public static let headerHeight: CGFloat = 30

    /// Size of the collapsed island: the notch itself, or the pill.
    public static func collapsedSize(_ s: ScreenInfo) -> CGSize {
        if s.hasNotch, let l = s.auxiliaryTopLeft, let r = s.auxiliaryTopRight {
            let width = s.frame.width - l.width - r.width
            return CGSize(width: width.rounded(), height: s.safeAreaTop)
        }
        return pillSize
    }

    /// Collapsed island frame in global coordinates, flush with the top edge.
    public static func collapsedFrame(_ s: ScreenInfo) -> CGRect {
        let size = collapsedSize(s)
        let x: CGFloat
        if s.hasNotch, let l = s.auxiliaryTopLeft {
            x = s.frame.minX + l.width
        } else {
            x = s.frame.midX - size.width / 2
        }
        return CGRect(x: x.rounded(), y: s.frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Expanded content size per tab. Never wider than the display allows.
    public static func expandedSize(_ s: ScreenInfo, tab: IslandTab) -> CGSize {
        let base: CGSize
        switch tab {
        case .home: base = CGSize(width: 700, height: 208)
        case .shelf: base = CGSize(width: 700, height: 208)
        case .agents: base = CGSize(width: 700, height: 236)
        }
        let collapsed = collapsedSize(s)
        let maxWidth = max(collapsed.width, s.frame.width - 2 * shadowMargin.width - 16)
        // The expanded shape always covers the notch, so it is at least as tall as the notch plus content.
        let height = base.height + (s.hasNotch ? max(0, collapsed.height - 32) : 0)
        return CGSize(width: min(base.width, maxWidth), height: height)
    }

    public static func popupContentSize(_ s: ScreenInfo) -> CGSize {
        let collapsed = collapsedSize(s)
        let width = max(popupSize.width, collapsed.width + 150)
        let height = (s.hasNotch ? collapsed.height : 0) + popupSize.height - (s.hasNotch ? 22 : 0)
        return CGSize(width: min(width, s.frame.width - 16), height: height)
    }

    /// A rect of `size` hanging from the top center of the screen (centered on the notch when there is one).
    public static func topAnchoredFrame(_ s: ScreenInfo, size: CGSize) -> CGRect {
        let c = collapsedFrame(s)
        var x = c.midX - size.width / 2
        x = min(max(x, s.frame.minX), s.frame.maxX - size.width)
        return CGRect(x: x.rounded(), y: s.frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Window frame used while the island is open: the largest shape plus shadow margins.
    public static func openWindowFrame(_ s: ScreenInfo, contentSize: CGSize) -> CGRect {
        let size = CGSize(width: contentSize.width + 2 * shadowMargin.width, height: contentSize.height + shadowMargin.height)
        return topAnchoredFrame(s, size: size)
    }

    /// The area in which a drag counts as "heading for the notch" while collapsed.
    public static func dragActivationRect(_ s: ScreenInfo) -> CGRect {
        let c = collapsedFrame(s)
        return CGRect(x: c.minX - 110, y: c.minY - 70, width: c.width + 220, height: c.height + 70)
    }

    /// Hover area while expanded: the shape plus a small tolerance so tiny overshoots do not collapse it.
    public static func expandedHoverRect(_ s: ScreenInfo, contentSize: CGSize, tolerance: CGFloat = 10) -> CGRect {
        topAnchoredFrame(s, size: contentSize).insetBy(dx: -tolerance, dy: -tolerance)
    }

    /// Picks the display the cursor is on; falls back to the first screen.
    public static func screenIndex(containing point: CGPoint, frames: [CGRect]) -> Int? {
        if let i = frames.firstIndex(where: { $0.insetBy(dx: -0.5, dy: -0.5).contains(point) }) { return i }
        return frames.isEmpty ? nil : 0
    }
}
