import XCTest
@testable import IsleCore

final class MediaParsingTests: XCTestCase {
    func testSpotifyNotification() {
        let info: [AnyHashable: Any] = [
            "Player State": "Playing", "Name": "Halo", "Artist": "Beyoncé", "Album": "I Am... Sasha Fierce",
            "Duration": 261_000, "Playback Position": 12.5, "Track ID": "spotify:track:abc", "Popularity": 80,
        ]
        let snap = SpotifyParser.parse(userInfo: info)
        XCTAssertEqual(snap?.state, .playing)
        XCTAssertEqual(snap?.track?.title, "Halo")
        XCTAssertEqual(snap?.track?.artist, "Beyoncé")
        XCTAssertEqual(snap?.track?.duration, 261)
        XCTAssertEqual(snap?.position, 12.5)
        XCTAssertEqual(snap?.track?.bundleID, KnownBundle.spotify)
    }

    func testSpotifyStoppedHasNoTrack() {
        let snap = SpotifyParser.parse(userInfo: ["Player State": "Stopped"])
        XCTAssertEqual(snap?.state, .stopped)
        XCTAssertNil(snap?.track)
    }

    func testGarbageNotificationsAreRejected() {
        XCTAssertNil(SpotifyParser.parse(userInfo: nil))
        XCTAssertNil(SpotifyParser.parse(userInfo: [:]))
        XCTAssertNil(SpotifyParser.parse(userInfo: ["Player State": 42]))
        XCTAssertNil(AppleMusicParser.parse(userInfo: ["Name": "x"]))
    }

    func testWrongTypesAreTolerated() {
        let snap = SpotifyParser.parse(userInfo: ["Player State": "Paused", "Name": "Song", "Duration": "not a number", "Artist": 7])
        XCTAssertEqual(snap?.state, .paused)
        XCTAssertNil(snap?.track?.duration)
        XCTAssertEqual(snap?.track?.artist, "7")
    }

    func testAppleMusicNotification() {
        let snap = AppleMusicParser.parse(userInfo: ["Player State": "Paused", "Name": "Clair de Lune", "Artist": "Debussy",
                                                      "Album": "Suite", "Total Time": 303_000, "PersistentID": 1234])
        XCTAssertEqual(snap?.state, .paused)
        XCTAssertEqual(snap?.track?.duration, 303)
        XCTAssertNil(snap?.position)
        XCTAssertEqual(snap?.track?.bundleID, KnownBundle.appleMusic)
    }

    func testScriptStatus() {
        let sep = ScriptStatusParser.separator
        let raw = ["state=playing", "title=A = B", "artist=X", "album=Y", "duration=215000", "durationUnit=ms",
                   "position=3,5", "shuffle=true", "future=field"].joined(separator: sep)
        let snap = ScriptStatusParser.parse(raw, bundleID: KnownBundle.spotify)
        XCTAssertEqual(snap?.track?.title, "A = B", "only the first '=' splits key from value")
        XCTAssertEqual(snap?.track?.duration, 215)
        XCTAssertEqual(snap?.position, 3.5, "decimal comma from localized AppleScript")
        XCTAssertEqual(snap?.shuffle, true)
        XCTAssertNil(ScriptStatusParser.parse("nonsense", bundleID: "x"))
    }

    func testSystemHelperLine() {
        let line = #"{"title":"Video","artist":"","bundle":"com.apple.WebKit.GPU","parent":"com.apple.Safari","playing":true,"elapsed":10,"timestamp":1700000000,"duration":0,"rate":1,"unknownField":[1,2]}"#
        let snap = SystemNowPlayingParser.parse(line: line)
        XCTAssertEqual(snap?.track?.bundleID, "com.apple.Safari", "browser helper maps to its parent app")
        XCTAssertNil(snap?.track?.duration, "zero duration means unknown")
        XCTAssertEqual(snap?.isPlaying, true)
        XCTAssertEqual(snap?.elapsed, 10)
    }

    func testSystemHelperUnsupportedAndJunk() {
        XCTAssertEqual(SystemNowPlayingParser.parse(line: #"{"supported":false,"error":"no class"}"#)?.supported, false)
        XCTAssertNil(SystemNowPlayingParser.parse(line: "not json"))
        XCTAssertNil(SystemNowPlayingParser.parse(line: "[1,2,3]"))
        XCTAssertNil(SystemNowPlayingParser.parse(line: #"{"log":"hello"}"#))
        let empty = SystemNowPlayingParser.parse(line: #"{"empty":true,"playing":false}"#)
        XCTAssertNotNil(empty)
        XCTAssertNil(empty?.track)
    }
}

final class SourceArbiterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)

    func testMusicAppBeatsBrowserVideoWhenBothPlay() {
        let pick = SourceArbiter.choose([
            SourceCandidate(bundleID: "com.apple.Safari", isPlaying: true, hasTrack: true, lastPlayedAt: t0.addingTimeInterval(50)),
            SourceCandidate(bundleID: KnownBundle.spotify, isPlaying: true, hasTrack: true, lastPlayedAt: t0),
        ])
        XCTAssertEqual(pick?.bundleID, KnownBundle.spotify)
    }

    func testPlayingBrowserBeatsPausedMusic() {
        let pick = SourceArbiter.choose([
            SourceCandidate(bundleID: "com.google.Chrome", isPlaying: true, hasTrack: true, lastPlayedAt: t0),
            SourceCandidate(bundleID: KnownBundle.appleMusic, isPlaying: false, hasTrack: true, lastPlayedAt: t0.addingTimeInterval(99)),
        ])
        XCTAssertEqual(pick?.bundleID, "com.google.Chrome")
    }

    func testNothingPlayingPicksMostRecent() {
        let pick = SourceArbiter.choose([
            SourceCandidate(bundleID: KnownBundle.spotify, isPlaying: false, hasTrack: true, lastPlayedAt: t0),
            SourceCandidate(bundleID: "com.apple.Safari", isPlaying: false, hasTrack: true, lastPlayedAt: t0.addingTimeInterval(5)),
        ])
        XCTAssertEqual(pick?.bundleID, "com.apple.Safari")
    }

    func testCandidatesWithoutTrackAreIgnored() {
        XCTAssertNil(SourceArbiter.choose([SourceCandidate(bundleID: KnownBundle.spotify, isPlaying: true, hasTrack: false)]))
        XCTAssertNil(SourceArbiter.choose([]))
    }

    func testTwoMusicAppsPicksMostRecentlyStarted() {
        let pick = SourceArbiter.choose([
            SourceCandidate(bundleID: KnownBundle.spotify, isPlaying: true, hasTrack: true, lastPlayedAt: t0),
            SourceCandidate(bundleID: KnownBundle.appleMusic, isPlaying: true, hasTrack: true, lastPlayedAt: t0.addingTimeInterval(1)),
        ])
        XCTAssertEqual(pick?.bundleID, KnownBundle.appleMusic)
    }
}

final class PlaybackClockTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 5000)

    func testInterpolatesWhilePlaying() {
        let clock = PlaybackClock(isPlaying: true, position: 10, sampledAt: t0)
        XCTAssertEqual(clock.position(at: t0.addingTimeInterval(2.5), duration: 200), 12.5, accuracy: 0.001)
    }

    func testFrozenWhilePaused() {
        let clock = PlaybackClock(isPlaying: false, position: 10, sampledAt: t0)
        XCTAssertEqual(clock.position(at: t0.addingTimeInterval(60), duration: 200), 10)
    }

    func testClampedToDurationAndZero() {
        let clock = PlaybackClock(isPlaying: true, position: 198, sampledAt: t0)
        XCTAssertEqual(clock.position(at: t0.addingTimeInterval(30), duration: 200), 200)
        let negative = PlaybackClock(isPlaying: false, position: -4, sampledAt: t0)
        XCTAssertEqual(negative.position(at: t0, duration: nil), 0)
        let early = PlaybackClock(isPlaying: true, position: 5, sampledAt: t0)
        XCTAssertEqual(early.position(at: t0.addingTimeInterval(-10), duration: nil), 5, "a sample from the future never rewinds")
    }

    func testRate() {
        let clock = PlaybackClock(isPlaying: true, position: 0, sampledAt: t0, rate: 2)
        XCTAssertEqual(clock.position(at: t0.addingTimeInterval(3), duration: nil), 6, accuracy: 0.001)
    }

    func testSeekDetection() {
        let a = PlaybackClock(isPlaying: true, position: 10, sampledAt: t0)
        let normal = PlaybackClock(isPlaying: true, position: 12.1, sampledAt: t0.addingTimeInterval(2))
        let seeked = PlaybackClock(isPlaying: true, position: 90, sampledAt: t0.addingTimeInterval(2))
        XCTAssertFalse(a.isSeek(comparedTo: normal))
        XCTAssertTrue(a.isSeek(comparedTo: seeked))
    }

    func testTimeFormat() {
        XCTAssertEqual(TimeFormat.clock(0), "0:00")
        XCTAssertEqual(TimeFormat.clock(7.9), "0:07")
        XCTAssertEqual(TimeFormat.clock(225), "3:45")
        XCTAssertEqual(TimeFormat.clock(3723), "1:02:03")
        XCTAssertEqual(TimeFormat.clock(-.infinity), "0:00")
        XCTAssertEqual(TimeFormat.clock(.nan), "0:00")
        XCTAssertEqual(TimeFormat.remaining(position: 30, duration: 200), "-2:50")
        XCTAssertEqual(TimeFormat.remaining(position: 300, duration: 200), "-0:00")
    }

    func testTrackIdentityIgnoresDuration() {
        let a = TrackInfo(title: "T", artist: "A", album: "B", duration: nil, bundleID: "x")
        let b = TrackInfo(title: "T", artist: "A", album: "B", duration: 200, bundleID: "x")
        XCTAssertEqual(a.identity, b.identity)
        XCTAssertNotEqual(a.identity, TrackInfo(title: "T2", artist: "A", album: "B", bundleID: "x").identity)
    }
}
