import AppKit
import Combine
import IsleCore

/// Everything the island views read. Controllers write it; views never mutate state machines directly.
@MainActor
final class IslandModel: ObservableObject {
    @Published var phase: IslandStateMachine.Phase = .collapsed
    @Published var tab: IslandTab = .home
    @Published var screen: ScreenInfo
    @Published var popup: PopupItem?
    /// A drag from another app is heading for the notch: show the AirDrop / Shelf drop targets.
    @Published var externalDrag = false
    @Published var agentsEnabled = false
    /// Drives the content fade, which trails the shape on the way in and leads it on the way out.
    @Published var contentVisible = false

    init(screen: ScreenInfo) { self.screen = screen }

    var collapsedSize: CGSize { NotchGeometry.collapsedSize(screen) }

    func expandedSize(for tab: IslandTab) -> CGSize {
        NotchGeometry.expandedSize(screen, tab: tab == .agents && !agentsEnabled ? .home : tab)
    }

    var showingDropTargets: Bool { externalDrag && phase == .expanded }

    var shapeSize: CGSize {
        switch phase {
        case .collapsed: return collapsedSize
        case .popup: return popup?.kind == .nowPlaying ? bannerSize : NotchGeometry.popupContentSize(screen)
        case .expanded: return showingDropTargets ? expandedSize(for: .airdrop) : expandedSize(for: tab)
        }
    }

    /// Song-change banner: cover on top, title and artist underneath.
    var bannerSize: CGSize {
        CGSize(width: max(collapsedSize.width + 40, 250), height: (screen.hasNotch ? collapsedSize.height : 8) + 128)
    }

    /// Height of the strip level with the notch where the header lives.
    var headerHeight: CGFloat { screen.hasNotch ? max(collapsedSize.height, 30) : NotchGeometry.headerHeight }

    /// Largest shape the island can take on this screen; the window is sized to this once.
    var maxContentSize: CGSize {
        let tabs: [IslandTab] = agentsEnabled ? IslandTab.allCases : [.home, .airdrop, .shelf]
        var w: CGFloat = max(NotchGeometry.popupContentSize(screen).width, bannerSize.width)
        var h: CGFloat = max(NotchGeometry.popupContentSize(screen).height, bannerSize.height)
        for t in tabs {
            let s = NotchGeometry.expandedSize(screen, tab: t)
            w = max(w, s.width); h = max(h, s.height)
        }
        return CGSize(width: w, height: h)
    }

    var isNotched: Bool { screen.hasNotch }
}

extension ScreenInfo {
    @MainActor init(_ screen: NSScreen) {
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        self.init(frame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                  auxiliaryTopLeft: left, auxiliaryTopRight: right,
                  menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY)
    }
}

/// All controllers, shared with the views through the environment.
@MainActor
final class AppEnv: ObservableObject {
    let media = MediaController()
    let calendar = CalendarController()
    let devices = DevicesController()
    let agents = AgentsController()
    let shelf = ShelfController()
    let settings = Settings.shared
    var island: IslandController!
    var lock: LockController?
}
