import XCTest
@testable import IsleCore

final class GeometryTests: XCTestCase {
    /// 16" MacBook Pro at default scaling: 1728 x 1117 points, 32 pt notch area.
    private var notched: ScreenInfo {
        ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), safeAreaTop: 32,
                   auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 771, height: 32),
                   auxiliaryTopRight: CGRect(x: 957, y: 1085, width: 771, height: 32))
    }

    private var external: ScreenInfo {
        ScreenInfo(frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440), safeAreaTop: 0,
                   auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
    }

    func testCollapsedIsExactlyTheNotch() {
        XCTAssertTrue(notched.hasNotch)
        let frame = NotchGeometry.collapsedFrame(notched)
        XCTAssertEqual(frame, CGRect(x: 771, y: 1085, width: 186, height: 32))
    }

    func testNoNotchDrawsCenteredPillAtTop() {
        XCTAssertFalse(external.hasNotch)
        let frame = NotchGeometry.collapsedFrame(external)
        XCTAssertEqual(frame.size, NotchGeometry.pillSize)
        XCTAssertEqual(frame.midX, external.frame.midX, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, external.frame.maxY)
    }

    func testSafeAreaWithoutAuxiliaryAreasIsNotANotch() {
        let s = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), safeAreaTop: 24, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        XCTAssertFalse(s.hasNotch)
        XCTAssertEqual(NotchGeometry.collapsedSize(s), NotchGeometry.pillSize)
    }

    func testExpandedIsCenteredOnNotchAndHangsFromTop() {
        for tab in IslandTab.allCases {
            let size = NotchGeometry.expandedSize(notched, tab: tab)
            let frame = NotchGeometry.topAnchoredFrame(notched, size: size)
            XCTAssertEqual(frame.midX, NotchGeometry.collapsedFrame(notched).midX, accuracy: 0.5, "\(tab)")
            XCTAssertEqual(frame.maxY, notched.frame.maxY, "\(tab)")
            XCTAssertGreaterThan(size.width, NotchGeometry.collapsedSize(notched).width)
            XCTAssertGreaterThan(size.height, NotchGeometry.collapsedSize(notched).height)
        }
    }

    func testExpandedNeverWiderThanASmallDisplay() {
        let tiny = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 600, height: 400), safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        let size = NotchGeometry.expandedSize(tiny, tab: .home)
        let window = NotchGeometry.openWindowFrame(tiny, contentSize: size)
        XCTAssertLessThanOrEqual(window.width, tiny.frame.width)
        XCTAssertGreaterThanOrEqual(window.minX, tiny.frame.minX)
        XCTAssertLessThanOrEqual(window.maxX, tiny.frame.maxX)
    }

    func testOpenWindowContainsShapeWithMargins() {
        let size = NotchGeometry.expandedSize(notched, tab: .home)
        let window = NotchGeometry.openWindowFrame(notched, contentSize: size)
        let shape = NotchGeometry.topAnchoredFrame(notched, size: size)
        XCTAssertTrue(window.contains(shape))
        XCTAssertEqual(window.maxY, notched.frame.maxY)
        XCTAssertEqual(window.width, size.width + 2 * NotchGeometry.shadowMargin.width)
    }

    func testSecondaryDisplayOffsetIsRespected() {
        let frame = NotchGeometry.collapsedFrame(external)
        XCTAssertTrue(external.frame.contains(frame))
        XCTAssertGreaterThan(frame.minX, 1728)
    }

    func testDragActivationRectSurroundsNotch() {
        let rect = NotchGeometry.dragActivationRect(notched)
        XCTAssertTrue(rect.contains(NotchGeometry.collapsedFrame(notched)))
        XCTAssertTrue(rect.contains(CGPoint(x: 864, y: 1050)))
        XCTAssertFalse(rect.contains(CGPoint(x: 200, y: 1100)))
    }

    func testScreenUnderCursor() {
        let frames = [notched.frame, external.frame]
        XCTAssertEqual(NotchGeometry.screenIndex(containing: CGPoint(x: 100, y: 100), frames: frames), 0)
        XCTAssertEqual(NotchGeometry.screenIndex(containing: CGPoint(x: 3000, y: 700), frames: frames), 1)
        XCTAssertEqual(NotchGeometry.screenIndex(containing: CGPoint(x: -500, y: -500), frames: frames), 0)
        XCTAssertNil(NotchGeometry.screenIndex(containing: .zero, frames: []))
    }

    func testPopupCoversNotchAndIsWider() {
        let size = NotchGeometry.popupContentSize(notched)
        XCTAssertGreaterThan(size.width, NotchGeometry.collapsedSize(notched).width)
        XCTAssertGreaterThan(size.height, NotchGeometry.collapsedSize(notched).height)
    }
}

final class IslandStateMachineTests: XCTestCase {
    func testHoverExpandsAfterDelay() {
        var m = IslandStateMachine(trigger: .hover, hoverDelay: 0.1)
        XCTAssertEqual(m.handle(.mouseEntered), [.startHoverTimer(0.1)])
        XCTAssertEqual(m.phase, .collapsed)
        _ = m.handle(.hoverTimerFired)
        XCTAssertEqual(m.phase, .expanded)
    }

    func testHoverJitterDoesNotExpand() {
        var m = IslandStateMachine(trigger: .hover, hoverDelay: 0.1)
        _ = m.handle(.mouseEntered)
        XCTAssertEqual(m.handle(.mouseExited), [.cancelHoverTimer])
        // A timer that fires anyway (already in flight) must not expand.
        _ = m.handle(.hoverTimerFired)
        XCTAssertEqual(m.phase, .collapsed)
    }

    func testZeroDelayExpandsImmediately() {
        var m = IslandStateMachine(trigger: .hover, hoverDelay: 0)
        XCTAssertEqual(m.handle(.mouseEntered), [])
        XCTAssertEqual(m.phase, .expanded)
    }

    func testClickTriggerIgnoresHoverButExpandsOnClick() {
        var m = IslandStateMachine(trigger: .click)
        XCTAssertEqual(m.handle(.mouseEntered), [])
        _ = m.handle(.hoverTimerFired)
        XCTAssertEqual(m.phase, .collapsed)
        _ = m.handle(.clicked)
        XCTAssertEqual(m.phase, .expanded)
    }

    func testClickAlsoWorksInHoverMode() {
        var m = IslandStateMachine(trigger: .hover, hoverDelay: 5)
        _ = m.handle(.mouseEntered)
        XCTAssertEqual(m.handle(.clicked), [.cancelHoverTimer])
        XCTAssertEqual(m.phase, .expanded)
    }

    func testCollapsesAfterCursorLeaves() {
        var m = IslandStateMachine(trigger: .hover, hoverDelay: 0, collapseDelay: 0.3)
        _ = m.handle(.mouseEntered)
        XCTAssertEqual(m.handle(.mouseExited), [.startCollapseTimer(0.3)])
        _ = m.handle(.collapseTimerFired)
        XCTAssertEqual(m.phase, .collapsed)
    }

    func testReenteringCancelsCollapse() {
        var m = IslandStateMachine(trigger: .hover, hoverDelay: 0)
        _ = m.handle(.mouseEntered)
        _ = m.handle(.mouseExited)
        XCTAssertEqual(m.handle(.mouseEntered), [.cancelCollapseTimer])
        _ = m.handle(.collapseTimerFired)
        XCTAssertEqual(m.phase, .expanded)
    }

    func testDragExpandsAndHoldsOpenUntilDragEnds() {
        var m = IslandStateMachine()
        _ = m.handle(.dragApproached)
        XCTAssertEqual(m.phase, .expanded)
        XCTAssertTrue(m.isDragging)
        // The cursor is not "hovering" in the tracking sense during a drag; a collapse timer must not close it.
        XCTAssertEqual(m.handle(.mouseExited), [])
        _ = m.handle(.collapseTimerFired)
        XCTAssertEqual(m.phase, .expanded)
        XCTAssertEqual(m.handle(.dragEnded), [.startCollapseTimer(Motion.collapseDelay)])
        _ = m.handle(.collapseTimerFired)
        XCTAssertEqual(m.phase, .collapsed)
    }

    func testPopupOnlyFromCollapsedAndNeverDuringDrag() {
        var m = IslandStateMachine(hoverDelay: 0)
        _ = m.handle(.mouseEntered)
        XCTAssertFalse(m.canPresentPopup)
        XCTAssertEqual(m.handle(.popupRequested), [])
        XCTAssertEqual(m.phase, .expanded)

        var d = IslandStateMachine()
        _ = d.handle(.dragApproached)
        _ = d.handle(.forceCollapse)
        _ = d.handle(.dragApproached)
        XCTAssertFalse(d.canPresentPopup)
    }

    func testPopupTimesOut() {
        var m = IslandStateMachine(popupDuration: 3)
        XCTAssertEqual(m.handle(.popupRequested), [.cancelHoverTimer, .startPopupTimer(3)])
        XCTAssertEqual(m.phase, .popup)
        XCTAssertEqual(m.handle(.popupTimerFired), [.popupFinished])
        XCTAssertEqual(m.phase, .collapsed)
    }

    func testPopupStaysOpenWhileHovered() {
        var m = IslandStateMachine(trigger: .click, popupDuration: 3, popupLinger: 1)
        _ = m.handle(.popupRequested)
        XCTAssertEqual(m.handle(.mouseEntered), [.cancelPopupTimer])
        XCTAssertEqual(m.handle(.popupTimerFired), [])
        XCTAssertEqual(m.phase, .popup)
        XCTAssertEqual(m.handle(.mouseExited), [.startPopupTimer(1)])
        XCTAssertEqual(m.handle(.popupTimerFired), [.popupFinished])
        XCTAssertEqual(m.phase, .collapsed)
    }

    func testClickingPopupOpensIsland() {
        var m = IslandStateMachine()
        _ = m.handle(.popupRequested)
        XCTAssertEqual(m.handle(.clicked), [.cancelPopupTimer, .popupFinished])
        XCTAssertEqual(m.phase, .expanded)
    }

    func testDragDuringPopupReplacesIt() {
        var m = IslandStateMachine()
        _ = m.handle(.popupRequested)
        XCTAssertEqual(m.handle(.dragApproached), [.cancelPopupTimer, .popupFinished])
        XCTAssertEqual(m.phase, .expanded)
    }

    func testForceCollapseClearsEverything() {
        var m = IslandStateMachine()
        _ = m.handle(.dragApproached)
        _ = m.handle(.forceCollapse)
        XCTAssertEqual(m.phase, .collapsed)
        XCTAssertFalse(m.isDragging)
    }

    func testStrayEventsAreHarmless() {
        var m = IslandStateMachine()
        XCTAssertEqual(m.handle(.collapseTimerFired), [])
        XCTAssertEqual(m.handle(.popupTimerFired), [])
        XCTAssertEqual(m.handle(.dragEnded), [])
        XCTAssertEqual(m.handle(.mouseExited), [.cancelHoverTimer])
        XCTAssertEqual(m.phase, .collapsed)
    }
}

final class PopupQueueTests: XCTestCase {
    private func item(_ id: String, kind: PopupKind = .bluetoothDevice, at: Date = Date(timeIntervalSince1970: 1000)) -> PopupItem {
        PopupItem(id: id, kind: kind, symbol: "headphones", title: id, enqueuedAt: at)
    }

    func testFIFOOneAtATime() {
        var q = PopupQueue()
        let now = Date(timeIntervalSince1970: 1001)
        q.enqueue(item("a"))
        q.enqueue(item("b", kind: .power))
        XCTAssertEqual(q.dequeue(canPresent: true, now: now)?.id, "a")
        XCTAssertNil(q.dequeue(canPresent: true, now: now), "second pop-up waits for the first to finish")
        q.finishCurrent()
        XCTAssertEqual(q.dequeue(canPresent: true, now: now)?.id, "b")
        q.finishCurrent()
        XCTAssertTrue(q.isEmpty)
    }

    func testHeldWhileIslandBusy() {
        var q = PopupQueue()
        q.enqueue(item("a"))
        XCTAssertNil(q.dequeue(canPresent: false, now: Date(timeIntervalSince1970: 1001)))
        XCTAssertEqual(q.pending.count, 1)
    }

    func testDuplicateIdsDoNotStack() {
        var q = PopupQueue()
        q.enqueue(item("a"))
        q.enqueue(item("a"))
        XCTAssertEqual(q.pending.count, 1)
        _ = q.dequeue(canPresent: true, now: Date(timeIntervalSince1970: 1001))
        q.enqueue(item("a"))
        XCTAssertTrue(q.pending.isEmpty, "the pop-up on screen is not queued again")
    }

    func testStaleItemsAreDropped() {
        var q = PopupQueue(maxAge: 20)
        q.enqueue(item("old", at: Date(timeIntervalSince1970: 1000)))
        q.enqueue(item("new", at: Date(timeIntervalSince1970: 1030)))
        XCTAssertEqual(q.dequeue(canPresent: true, now: Date(timeIntervalSince1970: 1035))?.id, "new")
    }

    func testRemoveByKind() {
        var q = PopupQueue()
        q.enqueue(item("a"))
        q.enqueue(item("p", kind: .power))
        q.removeAll(kind: .bluetoothDevice)
        XCTAssertEqual(q.pending.map(\.id), ["p"])
    }
}

final class MotionOptionsTests: XCTestCase {
    override func tearDown() {
        Motion.animationsEnabled = true
        Motion.disabledCategories = []
        Motion.preset = .smooth
    }

    func testCategoryCanBeSwitchedOff() {
        Motion.disabledCategories = [.banner]
        XCTAssertFalse(Motion.isOn(.banner))
        XCTAssertTrue(Motion.isOn(.shape))
    }

    func testMasterSwitchDisablesEverything() {
        Motion.animationsEnabled = false
        for c in Motion.Category.allCases { XCTAssertFalse(Motion.isOn(c)) }
    }

    func testEveryCategoryHasADefaultPreset() {
        for p in Motion.Preset.allCases { Motion.preset = p; XCTAssertTrue(Motion.isOn(.content)) }
    }

    func testNowPlayingBannerQueuesAndReplaces() {
        var q = PopupQueue()
        q.enqueue(PopupItem(id: "np-a", kind: .nowPlaying, symbol: "music.note", title: "A"))
        q.removeAll(kind: .nowPlaying)
        q.enqueue(PopupItem(id: "np-b", kind: .nowPlaying, symbol: "music.note", title: "B"))
        XCTAssertEqual(q.pending.map(\.id), ["np-b"])
    }
}

final class PrivacyStateTests: XCTestCase {
    func testActiveListIsOrderedAndEmptyWhenIdle() {
        XCTAssertTrue(PrivacyState().active.isEmpty)
        XCTAssertFalse(PrivacyState().isActive)
        XCTAssertEqual(PrivacyState(microphone: true, camera: true, screen: true).active, [.camera, .microphone, .screen])
    }

    func testScreenRecordingNeedsIndicatorWindowsAndNoMicOrCamera() {
        XCTAssertTrue(ScreenRecordingDetector.isRecording(statusIndicatorWindows: 2, microphone: false, camera: false))
        XCTAssertFalse(ScreenRecordingDetector.isRecording(statusIndicatorWindows: 0, microphone: false, camera: false))
        XCTAssertFalse(ScreenRecordingDetector.isRecording(statusIndicatorWindows: 2, microphone: true, camera: false),
                       "windows may belong to the mic dot, so the screen is not claimed")
        XCTAssertFalse(ScreenRecordingDetector.isRecording(statusIndicatorWindows: 2, microphone: false, camera: true))
    }

    func testEveryKindHasASymbolAndTitle() {
        for k in PrivacyState.Kind.allCases { XCTAssertFalse(k.symbol.isEmpty); XCTAssertFalse(k.title.isEmpty) }
    }
}

final class FullScreenDetectorTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    private func w(_ pid: Int32, layer: Int = 0, height: CGFloat = 1117, width: CGFloat = 1728) -> FullScreenDetector.Window {
        .init(ownerPID: pid, layer: layer, frame: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func testFullHeightWindowOfFrontmostAppIsFullScreen() {
        XCTAssertTrue(FullScreenDetector.isFullScreen(windows: [w(5)], frontmostPID: 5, screenFrame: screen, safeAreaTop: 33))
    }

    func testWindowBelowTheNotchCountsOnNotchedDisplays() {
        XCTAssertTrue(FullScreenDetector.isFullScreen(windows: [w(5, height: 1084)], frontmostPID: 5, screenFrame: screen, safeAreaTop: 33))
        XCTAssertFalse(FullScreenDetector.isFullScreen(windows: [w(5, height: 1084)], frontmostPID: 5, screenFrame: screen, safeAreaTop: 0))
    }

    func testOrdinaryOrOtherAppWindowsAreNotFullScreen() {
        XCTAssertFalse(FullScreenDetector.isFullScreen(windows: [w(5, height: 900, width: 1400)], frontmostPID: 5, screenFrame: screen, safeAreaTop: 33))
        XCTAssertFalse(FullScreenDetector.isFullScreen(windows: [w(9)], frontmostPID: 5, screenFrame: screen, safeAreaTop: 33), "another app's window")
        XCTAssertFalse(FullScreenDetector.isFullScreen(windows: [w(5, layer: 25)], frontmostPID: 5, screenFrame: screen, safeAreaTop: 33), "a menu-bar layer window")
        XCTAssertFalse(FullScreenDetector.isFullScreen(windows: [w(5)], frontmostPID: nil, screenFrame: screen, safeAreaTop: 33))
    }
}
