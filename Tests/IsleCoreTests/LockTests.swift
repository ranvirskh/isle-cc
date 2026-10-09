import XCTest
@testable import IsleCore

final class LockStateMachineTests: XCTestCase {
    private func playing(enabled: Bool = true, supported: Bool = true) -> LockStateMachine {
        var m = LockStateMachine(enabled: enabled, supported: supported)
        _ = m.handle(.trackChanged(identity: "song-1"))
        _ = m.handle(.playbackChanged(isPlaying: true))
        return m
    }

    func testAppearsOnLockWhilePlayingAndDisappearsOnUnlock() {
        var m = playing()
        XCTAssertFalse(m.isCardVisible)
        XCTAssertEqual(m.handle(.screenLocked), [.showCard])
        XCTAssertTrue(m.isCardVisible)
        XCTAssertEqual(m.handle(.screenUnlocked), [.hideCard])
        XCTAssertFalse(m.isCardVisible)
    }

    func testNothingPlayingShowsNothing() {
        var m = LockStateMachine(enabled: true)
        XCTAssertEqual(m.handle(.screenLocked), [])
        XCTAssertFalse(m.isCardVisible)
    }

    func testPlaybackStartingWhileLockedShowsCard() {
        var m = LockStateMachine(enabled: true)
        _ = m.handle(.screenLocked)
        XCTAssertEqual(m.handle(.trackChanged(identity: "a")), [])
        XCTAssertEqual(m.handle(.playbackChanged(isPlaying: true)), [.showCard])
    }

    func testPlaybackStopWhileLockedHidesCard() {
        var m = playing()
        _ = m.handle(.screenLocked)
        XCTAssertEqual(m.handle(.playbackChanged(isPlaying: false)), [.hideCard])
        XCTAssertEqual(m.handle(.playbackChanged(isPlaying: true)), [.showCard])
        XCTAssertEqual(m.handle(.trackChanged(identity: nil)), [.hideCard], "nothing playing any more")
        XCTAssertFalse(m.isPlaying)
    }

    func testTrackChangeWhileLockedUpdatesCard() {
        var m = playing()
        _ = m.handle(.screenLocked)
        XCTAssertEqual(m.handle(.trackChanged(identity: "song-2")), [.updateCard])
        XCTAssertEqual(m.handle(.trackChanged(identity: "song-2")), [], "same track again is not an update")
        XCTAssertTrue(m.isCardVisible)
    }

    func testDisplaySleepHidesAndWakeShowsAgainWhileStillLocked() {
        var m = playing()
        _ = m.handle(.screenLocked)
        XCTAssertEqual(m.handle(.displaySlept), [.hideCard])
        XCTAssertEqual(m.handle(.trackChanged(identity: "song-2")), [], "no window work while the display is off")
        XCTAssertEqual(m.handle(.displayWoke), [.showCard])
    }

    func testSleepThenUnlockNeverShows() {
        var m = playing()
        _ = m.handle(.screenLocked)
        _ = m.handle(.displaySlept)
        XCTAssertEqual(m.handle(.screenUnlocked), [])
        XCTAssertEqual(m.handle(.displayWoke), [])
        XCTAssertFalse(m.isCardVisible)
    }

    func testUnlockClearsAStuckSleepFlag() {
        var m = playing()
        _ = m.handle(.screenLocked)
        _ = m.handle(.displaySlept)
        _ = m.handle(.screenUnlocked) // the wake notification got lost
        XCTAssertEqual(m.handle(.screenLocked), [.showCard])
    }

    func testFastUserSwitchHides() {
        var m = playing()
        _ = m.handle(.screenLocked)
        XCTAssertEqual(m.handle(.sessionResignedActive), [.hideCard])
        XCTAssertEqual(m.handle(.sessionBecameActive), [.showCard])
    }

    func testSettingGatesEverything() {
        var off = playing(enabled: false)
        XCTAssertEqual(off.handle(.screenLocked), [])
        XCTAssertFalse(off.needsMediaWhileLocked)
        XCTAssertEqual(off.handle(.settingChanged(enabled: true)), [.showCard], "turning it on while locked and playing shows it")
        XCTAssertEqual(off.handle(.settingChanged(enabled: false)), [.hideCard])
        XCTAssertEqual(LockStateMachine().isEnabled, false, "off by default")
    }

    func testUnsupportedNeverShows() {
        var m = playing(supported: false)
        XCTAssertEqual(m.handle(.screenLocked), [])
        XCTAssertFalse(m.isCardVisible)
        XCTAssertFalse(m.needsMediaWhileLocked)
        XCTAssertEqual(m.handle(.supportChanged(supported: true)), [.showCard])
    }

    func testNeedsMediaOnlyWhileLocked() {
        var m = playing()
        XCTAssertFalse(m.needsMediaWhileLocked)
        _ = m.handle(.screenLocked)
        XCTAssertTrue(m.needsMediaWhileLocked)
        _ = m.handle(.screenUnlocked)
        XCTAssertFalse(m.needsMediaWhileLocked, "resources are released on unlock")
    }

    func testRepeatedEventsDoNotRepeatEffects() {
        var m = playing()
        XCTAssertEqual(m.handle(.screenLocked), [.showCard])
        XCTAssertEqual(m.handle(.screenLocked), [])
        XCTAssertEqual(m.handle(.screenUnlocked), [.hideCard])
        XCTAssertEqual(m.handle(.screenUnlocked), [])
    }
}

final class LockWindowElevatorTests: XCTestCase {
    func testMissingSymbolDisablesFeatureWithoutCrashing() {
        for missing in SkyLightLockWindowElevator.requiredSymbols {
            // Every other symbol resolves to a harmless non-null address; the missing one must stop initialization
            // before anything is called.
            let elevator = SkyLightLockWindowElevator { name in
                name == missing ? nil : UnsafeMutableRawPointer(bitPattern: 0x1000)
            }
            XCTAssertFalse(elevator.isSupported, missing)
            XCTAssertTrue(elevator.unsupportedReason?.contains(missing) ?? false)
            XCTAssertFalse(elevator.elevate(windowNumber: 42), "elevate is a no-op when unsupported")
            elevator.release()
        }
    }

    func testAllSymbolsMissing() {
        let elevator = SkyLightLockWindowElevator { _ in nil }
        XCTAssertFalse(elevator.isSupported)
        XCTAssertFalse(elevator.elevate(windowNumber: 1))
        elevator.release()
    }

    func testNoOpFallback() {
        let elevator: LockWindowElevator = NoOpLockWindowElevator()
        XCTAssertFalse(elevator.isSupported)
        XCTAssertEqual(elevator.unsupportedReason, "Not supported on this macOS version")
        XCTAssertFalse(elevator.elevate(windowNumber: 7))
        elevator.release()
    }

    func testUnsupportedElevatorKeepsStateMachineOff() {
        let elevator = SkyLightLockWindowElevator { _ in nil }
        var m = LockStateMachine(enabled: true, supported: elevator.isSupported)
        _ = m.handle(.trackChanged(identity: "a"))
        _ = m.handle(.playbackChanged(isPlaying: true))
        XCTAssertEqual(m.handle(.screenLocked), [])
    }

    func testInvalidWindowNumberRejected() {
        let elevator = SkyLightLockWindowElevator { _ in nil }
        XCTAssertFalse(elevator.elevate(windowNumber: 0))
        XCTAssertFalse(elevator.elevate(windowNumber: -1))
    }

    func testRealSymbolsResolveOnThisMac() {
        // Informational: records whether the mechanism exists on the macOS running the tests. It does not call it.
        let elevator = SkyLightLockWindowElevator()
        if !elevator.isSupported {
            print("note: SkyLight lock screen symbols unavailable here: \(elevator.unsupportedReason ?? "?")")
        }
        elevator.release()
    }
}
