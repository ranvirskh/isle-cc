import XCTest
@testable import IsleCore

/// Canned transport: no test in this file touches the network.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URL] = []
    private var _headers: [[String: String]] = []
    var handler: @Sendable (URL) throws -> HTTPResponse

    init(handler: @escaping @Sendable (URL) throws -> HTTPResponse = { _ in HTTPResponse(status: 404) }) {
        self.handler = handler
    }

    var requests: [URL] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var headers: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return _headers
    }

    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse {
        record(url, headers)
        return try handler(url)
    }

    private func record(_ url: URL, _ headers: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        _requests.append(url)
        _headers.append(headers)
    }
}

final class StubProvider: LyricsProvider, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var _calls = 0
    let result: @Sendable () async throws -> LyricsPayload?

    init(name: String, result: @escaping @Sendable () async throws -> LyricsPayload?) {
        self.name = name
        self.result = result
    }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func lyrics(for query: LyricsQuery) async throws -> LyricsPayload? {
        bump()
        return try await result()
    }

    private func bump() {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
    }
}

private func json(_ rows: [[String: Any]]) -> Data {
    (try? JSONSerialization.data(withJSONObject: rows)) ?? Data()
}

private func row(_ title: String, _ artist: String, album: String = "", duration: Double? = 200, synced: Bool = false,
                 plain: Bool = true, instrumental: Bool = false, text: String = "hello world") -> [String: Any] {
    var r: [String: Any] = ["id": Int.random(in: 1...999_999), "trackName": title, "artistName": artist, "albumName": album,
                            "instrumental": instrumental, "extraFieldFromTheFuture": ["a": 1]]
    if let duration { r["duration"] = duration }
    r["plainLyrics"] = (plain && !instrumental) ? text : NSNull()
    r["syncedLyrics"] = (synced && !instrumental) ? "[00:01.00]\(text)\n[00:05.00]second line" : NSNull()
    return r
}

private func records(_ rows: [[String: Any]]) -> [LyricsRecord] {
    LyricsRecord.decodeList(json(rows))
}

final class MetadataSanityTests: XCTestCase {
    func testPlaceholderArtistsSkipped() {
        for artist in ["Unknown Artist", "unknown", "ARTIST UNKNOWN", "No Artist", "  Unknown Artist  ", ""] {
            XCTAssertFalse(MetadataSanity.namesASong(title: "Real Song", artist: artist), artist)
        }
    }

    func testDiscPositionTitlesSkipped() {
        for title in ["Track 7", "Audio Track 07", "Untitled 3", "Unknown", "Unknown Track 2", "track07", "TRACK 12", ""] {
            XCTAssertFalse(MetadataSanity.namesASong(title: title, artist: "Known Artist"), title)
        }
    }

    func testRealSongsNotSkipped() {
        XCTAssertTrue(MetadataSanity.namesASong(title: "Untitled", artist: "The Cure"), "anchored: a real song called Untitled")
        XCTAssertTrue(MetadataSanity.namesASong(title: "Untitled (How Does It Feel)", artist: "D'Angelo"))
        XCTAssertTrue(MetadataSanity.namesASong(title: "Unknown Pleasures", artist: "Joy Division"))
        XCTAssertTrue(MetadataSanity.namesASong(title: "Track Star", artist: "Mooski"))
        XCTAssertTrue(MetadataSanity.namesASong(title: "7", artist: "Prince"))
        XCTAssertTrue(MetadataSanity.namesASong(title: "Song", artist: "The Unknown Mortal Orchestra"))
    }
}

final class TitleCleanerTests: XCTestCase {
    func testStripsDecoration() {
        XCTAssertEqual(TitleCleaner.clean("Hey Jude - Remastered 2015"), "Hey Jude")
        XCTAssertEqual(TitleCleaner.clean("Come Together (2019 Mix)"), "Come Together")
        XCTAssertEqual(TitleCleaner.clean("Paranoid Android - 2011 Remaster"), "Paranoid Android")
        XCTAssertEqual(TitleCleaner.clean("Wonderwall (Live at Wembley)"), "Wonderwall")
        XCTAssertEqual(TitleCleaner.clean("Penny Lane [Mono]"), "Penny Lane")
        XCTAssertEqual(TitleCleaner.clean("Help! (Stereo)"), "Help!")
        XCTAssertEqual(TitleCleaner.clean("P power (feat. Drake)"), "P power")
        XCTAssertEqual(TitleCleaner.clean("Song (feat. X) [Remastered]"), "Song")
        XCTAssertEqual(TitleCleaner.clean("Song - Live"), "Song")
    }

    func testFoldsDiacritics() {
        XCTAssertEqual(TitleCleaner.clean("Déjà Vu"), "Deja Vu")
    }

    func testLeavesOrdinaryTitlesAlone() {
        XCTAssertEqual(TitleCleaner.clean("Live and Let Die"), "Live and Let Die")
        XCTAssertEqual(TitleCleaner.clean("Alive"), "Alive")
        XCTAssertEqual(TitleCleaner.clean("(I Can't Get No) Satisfaction"), "(I Can't Get No) Satisfaction")
        XCTAssertEqual(TitleCleaner.clean("Stereo Hearts"), "Stereo Hearts")
        XCTAssertEqual(TitleCleaner.clean("(Live)"), "(Live)", "never cleans a title down to nothing")
    }
}

final class LyricsSelectionTests: XCTestCase {
    func testDiacriticMismatchStillMatches() {
        let q = LyricsQuery(title: "Deja Vu", artist: "Beyonce", duration: 200)
        let pick = LyricsSelector.select(records([row("Déjà Vu", "Beyoncé", synced: true)]), for: q)
        XCTAssertEqual(pick?.kind, .timed)
        // And the other way round.
        let q2 = LyricsQuery(title: "Déjà Vu", artist: "Beyoncé")
        XCTAssertNotNil(LyricsSelector.select(records([row("Deja Vu", "Beyonce")]), for: q2))
    }

    func testTitleAndArtistMustBothMatch() {
        let q = LyricsQuery(title: "Hallelujah", artist: "Jeff Buckley")
        XCTAssertNil(LyricsSelector.select(records([row("Hallelujah", "Pentatonix", synced: true)]), for: q), "right title, wrong artist")
        XCTAssertNil(LyricsSelector.select(records([row("Grace", "Jeff Buckley", synced: true)]), for: q), "right artist, wrong title")
    }

    func testVersionMarkersRejectedUnlessRequested() {
        let q = LyricsQuery(title: "Blinding Lights", artist: "The Weeknd")
        for bad in ["Blinding Lights (Karaoke Version)", "Blinding Lights - Sped Up", "Blinding Lights (Remix)",
                    "Blinding Lights (Cover)", "Blinding Lights (Slowed + Reverb)", "Blinding Lights (Nightcore)",
                    "Blinding Lights (Instrumental)", "Blinding Lights (Acapella)", "Blinding Lights (A Cappella)",
                    "Blinding Lights (Made Popular By The Weeknd)", "Blinding Lights (Originally Performed by The Weeknd)",
                    "Blinding Lights (Re-Recorded)", "Blinding Lights (Rerecording)", "Blinding Lights (Tribute)",
                    "Blinding Lights (Remixed)", "Blinding Lights (sped-up)"] {
            XCTAssertNil(LyricsSelector.select(records([row(bad, "The Weeknd", synced: true)]), for: q), bad)
        }
        // If the user IS playing that version, its lyrics are allowed.
        let spedUp = LyricsQuery(title: "Blinding Lights - Sped Up", artist: "The Weeknd")
        XCTAssertNotNil(LyricsSelector.select(records([row("Blinding Lights - Sped Up", "The Weeknd", synced: true)]), for: spedUp))
        let remix = LyricsQuery(title: "Blinding Lights (Remix)", artist: "The Weeknd")
        XCTAssertNotNil(LyricsSelector.select(records([row("Blinding Lights (Remix)", "The Weeknd")]), for: remix))
    }

    func testPossessiveVersionOnly() {
        let q = LyricsQuery(title: "Love Story", artist: "Taylor Swift")
        XCTAssertNil(LyricsSelector.select(records([row("Love Story (Taylor's Version)", "Taylor Swift", synced: true)]), for: q))
        XCTAssertNil(LyricsSelector.select(records([row("Love Story (Taylor\u{2019}s Version)", "Taylor Swift", synced: true)]), for: q))
        XCTAssertNotNil(LyricsSelector.select(records([row("Love Story (Album Version)", "Taylor Swift", synced: true)]), for: q),
                        "\"Album Version\" is not a different recording")
        let tv = LyricsQuery(title: "Love Story (Taylor's Version)", artist: "Taylor Swift")
        XCTAssertNotNil(LyricsSelector.select(records([row("Love Story (Taylor's Version)", "Taylor Swift")]), for: tv))
    }

    func testMarkersNeedLeadingWordBoundary() {
        XCTAssertTrue(VersionMarkers.present(in: "Undercover of the Night").isEmpty, "undercover is not cover")
        XCTAssertTrue(VersionMarkers.present(in: "Discovery").isEmpty)
        XCTAssertEqual(VersionMarkers.present(in: "Song (Covers)"), ["cover"], "inflections match")
        XCTAssertEqual(VersionMarkers.present(in: "Song (Remixes)"), ["remix"])
        let q = LyricsQuery(title: "Undercover of the Night", artist: "The Rolling Stones")
        XCTAssertNotNil(LyricsSelector.select(records([row("Undercover of the Night", "The Rolling Stones")]), for: q))
    }

    func testRightArtistBeatsWrongArtistWithBetterTitleScore() {
        let q = LyricsQuery(title: "Yesterday (Remastered 2009)", artist: "The Beatles", album: "Help!")
        let wrong = row("Yesterday (Remastered 2009)", "Boyz II Men", album: "Help!", synced: true, text: "WRONG")
        let right = row("Yesterday", "The Beatles", album: "1", synced: false, text: "RIGHT")
        let pick = LyricsSelector.select(records([wrong, right]), for: q)
        XCTAssertEqual(pick?.record.plainLyrics, "RIGHT")
    }

    func testSyncedBeatsUnsyncedEvenWithWorseAlbumMatch() {
        let q = LyricsQuery(title: "Karma Police", artist: "Radiohead", album: "OK Computer")
        let plainExactAlbum = row("Karma Police", "Radiohead", album: "OK Computer", synced: false, text: "PLAIN")
        let syncedOtherAlbum = row("Karma Police", "Radiohead", album: "The Best Of", synced: true, text: "SYNCED")
        let pick = LyricsSelector.select(records([plainExactAlbum, syncedOtherAlbum]), for: q)
        XCTAssertEqual(pick?.kind, .timed)
        XCTAssertTrue(pick?.record.syncedLyrics?.contains("SYNCED") ?? false)
        XCTAssertLessThan(pick?.score ?? 99, 8 + 8 + 4 + 1, "it won on being synced, not on score")
    }

    func testScoring() {
        let q = LyricsQuery(title: "Song", artist: "Artist", album: "Album")
        let exact = LyricsSelector.select(records([row("Song", "Artist", album: "Album", synced: true)]), for: q)
        XCTAssertEqual(exact?.score, 8 + 8 + 4 + 3)
        let contained = LyricsSelector.select(records([row("Song of Songs", "Artist & Friends", album: "Album Deluxe")]), for: q)
        XCTAssertEqual(contained?.score, 4 + 4 + 2)
        let noAlbum = LyricsSelector.select(records([row("Song", "Artist", album: "")]), for: q)
        XCTAssertEqual(noAlbum?.score, 16, "album only counts when both are non-empty")
    }

    func testHigherScoreWinsAmongSynced() {
        let q = LyricsQuery(title: "Song", artist: "Artist", album: "Album")
        let a = row("Song", "Artist feat. Someone", album: "Other", synced: true, text: "A")
        let b = row("Song", "Artist", album: "Album", synced: true, text: "B")
        XCTAssertTrue(LyricsSelector.select(records([a, b]), for: q)?.record.syncedLyrics?.contains("B") ?? false)
    }

    func testInstrumentalFlagNeedsExactTitleAndDuration() {
        let q = LyricsQuery(title: "Intro", artist: "The xx", duration: 128)
        XCTAssertEqual(LyricsSelector.select(records([row("Intro", "The xx", duration: 127, instrumental: true)]), for: q)?.kind, .instrumental)
        XCTAssertNil(LyricsSelector.select(records([row("Intro", "The xx", duration: 190, instrumental: true)]), for: q),
                     "duration mismatch: the flag belongs to some other recording")
        XCTAssertNil(LyricsSelector.select(records([row("Intro (Long)", "The xx", duration: 128, instrumental: true)]), for: q),
                     "title only contained, not exact")
        let unknownDuration = LyricsQuery(title: "Intro", artist: "The xx")
        XCTAssertEqual(LyricsSelector.select(records([row("Intro", "The xx", duration: 190, instrumental: true)]), for: unknownDuration)?.kind, .instrumental)
    }

    func testRowsWithNoWordsAreDiscarded() {
        let q = LyricsQuery(title: "Song", artist: "Artist")
        XCTAssertNil(LyricsSelector.select(records([row("Song", "Artist", synced: false, plain: false)]), for: q))
    }

    func testDecoderToleratesJunk() {
        XCTAssertTrue(LyricsRecord.decodeList(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(LyricsRecord.decodeList(Data("{\"statusCode\":404}".utf8)).isEmpty)
        let mixed = Data(#"[{"trackName":"A","artistName":"B","duration":"12.5","instrumental":"false"}, 7, null, {"id": 3}]"#.utf8)
        let decoded = LyricsRecord.decodeList(mixed)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.duration, 12.5)
    }
}

final class LyricsPresentationTests: XCTestCase {
    func testCreditLinesHidden() {
        for line in ["Lyrics by: Someone", "Composer: X", "Producer: Y", "Mixing: Z", "Mastering: Q", "Written By : A",
                     "作词：林夕", "作曲: 周杰伦", "编曲：某人", "作詞：誰か", "プロデューサー：誰か", "Mix Engineer: M", "  produced by: P"] {
            XCTAssertTrue(LyricsPresentation.isCreditLine(line), line)
        }
    }

    func testRealLyricsKept() {
        for line in ["Mix it up tonight", "I'm in the mix: come on", "In the mix", "Producer of my dreams", "Composers and kings",
                     "Mastering the art of love", "She said: lyrics by the fire", "Remix: this is how we do it", "作词人的故事",
                     "Mixtape: side A"] {
            XCTAssertFalse(LyricsPresentation.isCreditLine(line), line)
        }
    }

    func testInstrumentalPlaceholders() {
        for line in ["Instrumental", "[Instrumental]", "  INSTRUMENTAL.  ", "No lyrics", "(no  lyrics)", "*** No Lyrics ***", "instru-mental"] {
            XCTAssertTrue(LyricsPresentation.isInstrumentalPlaceholder(line), line)
        }
        XCTAssertFalse(LyricsPresentation.isInstrumentalPlaceholder("Instrumental love"))
        XCTAssertFalse(LyricsPresentation.isInstrumentalPlaceholder("No lyrics could say it"))
    }

    func testDisplayLinesFilterButRawStaysIntact() {
        let raw = "[00:00.00]Lyrics by: A\n[00:01.00]Composer: B\n[00:10.00]Mix it up tonight\n[00:20.00]Instrumental\n[00:30.00]Last line"
        let payload = LyricsPayload(kind: .timed, synced: raw)
        guard case .timed(let timeline) = LyricsState(payload: payload) else { return XCTFail("expected timed") }
        XCTAssertEqual(timeline.lines.map(\.text), ["Mix it up tonight", "", "Last line"])
        XCTAssertTrue(timeline.lines[1].isInstrumentalMarker)
        XCTAssertEqual(payload.synced, raw, "filtering is presentation only")
        XCTAssertEqual(LRCParser.parse(raw).count, 5)
    }

    func testPlaceholderOnlyLyricsResolveAsInstrumental() {
        let q = LyricsQuery(title: "Song", artist: "Artist")
        let plainOnly = LyricsSelector.select(records([row("Song", "Artist", text: "Instrumental")]), for: q)
        XCTAssertEqual(plainOnly.map { LyricsSelector.payload(for: $0, provider: "t").kind }, .instrumental)
        var synced = row("Song", "Artist", synced: true)
        synced["syncedLyrics"] = "[00:00.00]Composer: X\n[00:05.00][Instrumental]"
        let chosen = LyricsSelector.select(records([synced]), for: q)
        XCTAssertEqual(chosen.map { LyricsSelector.payload(for: $0, provider: "t").kind }, .instrumental)
    }
}

final class LRCParserTests: XCTestCase {
    func testTwoAndThreeDigitFractions() {
        let lines = LRCParser.parse("[00:12.34]centi\n[01:02.345]milli\n[00:05]none\n[00:07:50]colon")
        XCTAssertEqual(lines.map(\.text), ["none", "colon", "centi", "milli"])
        XCTAssertEqual(lines[0].time, 5, accuracy: 0.0001)
        XCTAssertEqual(lines[1].time, 7.5, accuracy: 0.0001)
        XCTAssertEqual(lines[2].time, 12.34, accuracy: 0.0001)
        XCTAssertEqual(lines[3].time, 62.345, accuracy: 0.0001)
    }

    func testSeveralStampsOnOneLine() {
        let lines = LRCParser.parse("[00:10.00][00:30.00][00:50.00]chorus\n[00:20.00]verse")
        XCTAssertEqual(lines.map(\.text), ["chorus", "verse", "chorus", "chorus"])
        XCTAssertEqual(lines.map(\.time), [10, 20, 30, 50])
    }

    func testOffsetTag() {
        let later = LRCParser.parse("[offset:-500]\n[00:10.00]a")
        XCTAssertEqual(later[0].time, 10.5, accuracy: 0.0001, "negative offset delays lyrics")
        let sooner = LRCParser.parse("[00:10.00]a\n[offset: +2000]")
        XCTAssertEqual(sooner[0].time, 8, accuracy: 0.0001, "offset applies wherever the tag is")
        let clamped = LRCParser.parse("[offset:99999]\n[00:01.00]a")
        XCTAssertEqual(clamped[0].time, 0)
    }

    func testBlankAndJunkLines() {
        let text = "[ar:Artist]\n[ti:Title]\n\n   \njunk without stamp\n[00:01.00]\n[00:02.00]  padded  \r\n[xx:yy.zz]bad stamp\n[00:03.00]last"
        let lines = LRCParser.parse(text)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.map(\.text), ["", "padded", "last"])
    }

    func testSortsByTimeAndKeepsOrderForTies() {
        let lines = LRCParser.parse("[00:30.00]c\n[00:10.00]a\n[00:10.00]b")
        XCTAssertEqual(lines.map(\.text), ["a", "b", "c"])
    }

    func testWordLevelTagsStripped() {
        let lines = LRCParser.parse("[00:01.00]<00:01.00>Hello <00:01.50>world")
        XCTAssertEqual(lines.first?.text, "Hello world")
    }

    func testEmptyInput() {
        XCTAssertTrue(LRCParser.parse("").isEmpty)
        XCTAssertTrue(LRCParser.parse("just words\nno stamps").isEmpty)
    }

    func testLargeMinutes() {
        XCTAssertEqual(LRCParser.parse("[123:00.00]long").first?.time, 7380)
    }
}

final class LyricTimelineTests: XCTestCase {
    private let timeline = LyricTimeline(lines: [
        LyricLine(time: 5, text: "one"), LyricLine(time: 10, text: ""), LyricLine(time: 15, text: "two"), LyricLine(time: 20, text: "three"),
    ])

    func testNothingBeforeFirstLine() {
        XCTAssertNil(timeline.index(at: 0))
        XCTAssertNil(timeline.index(at: 4.99))
        XCTAssertNil(LyricTimeline(lines: []).index(at: 10))
    }

    func testCurrentLine() {
        XCTAssertEqual(timeline.index(at: 5), 0)
        XCTAssertEqual(timeline.index(at: 9.9), 0)
        XCTAssertEqual(timeline.index(at: 10), 1, "blank line: the gap shows nothing rather than the stale line")
        XCTAssertEqual(timeline.line(at: 12)?.text, "")
        XCTAssertEqual(timeline.index(at: 17), 2)
        XCTAssertEqual(timeline.index(at: 9999), 3)
        XCTAssertNil(timeline.index(at: .nan))
    }

    func testSeekBackwardsAndForwards() {
        XCTAssertEqual(timeline.index(at: 21), 3)
        XCTAssertEqual(timeline.index(at: 6), 0)
        XCTAssertEqual(timeline.index(at: 16), 2)
    }

    func testNextLineSkipsBlanks() {
        XCTAssertEqual(timeline.nextLine(after: 6)?.text, "two")
        XCTAssertEqual(timeline.nextLine(after: 0)?.text, "one")
        XCTAssertNil(timeline.nextLine(after: 25))
    }

    func testNextChange() {
        XCTAssertEqual(timeline.nextChange(after: 0), 5)
        XCTAssertEqual(timeline.nextChange(after: 5), 10)
        XCTAssertNil(timeline.nextChange(after: 20))
    }
}

final class LRCLIBProviderTests: XCTestCase {
    private func provider(_ transport: MockTransport) -> LRCLIBProvider {
        LRCLIBProvider(transport: transport, userAgent: "Isle-Tests v0 (unit tests)", requestGap: 0)
    }

    func testSendsOnlyTitleArtistAlbumDurationAndIdentifiesItself() async throws {
        let transport = MockTransport { url in
            url.path == "/api/get" ? HTTPResponse(status: 200, body: singleObject(row("Halo", "Beyoncé", album: "I Am", duration: 261, synced: true))) : HTTPResponse(status: 404)
        }
        let result = try await provider(transport).lyrics(for: LyricsQuery(title: "Halo", artist: "Beyoncé", album: "I Am", duration: 261.4))
        XCTAssertEqual(result?.kind, .timed)
        XCTAssertEqual(transport.requests.count, 1, "an exact synced hit needs no search")
        let url = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(url.host, "lrclib.net")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(Set(items.map(\.name)), ["track_name", "artist_name", "album_name", "duration"])
        XCTAssertEqual(items.first { $0.name == "duration" }?.value, "261")
        XCTAssertEqual(transport.headers.first?["User-Agent"], "Isle-Tests v0 (unit tests)")
    }

    func testFallsBackToSearchAndPrefersSynced() async throws {
        let transport = MockTransport { url in
            if url.path == "/api/get" { return HTTPResponse(status: 200, body: json([row("Song", "Artist", synced: false, text: "PLAIN")])) }
            return HTTPResponse(status: 200, body: json([row("Song", "Artist", album: "Other", synced: true, text: "SYNCED")]))
        }
        let result = try await provider(transport).lyrics(for: LyricsQuery(title: "Song (Remastered)", artist: "Artist"))
        XCTAssertEqual(result?.kind, .timed)
        XCTAssertEqual(transport.requests.map(\.path), ["/api/get", "/api/search"])
        let searchItems = URLComponents(url: transport.requests[1], resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(searchItems.first { $0.name == "track_name" }?.value, "Song", "search uses the cleaned title")
        XCTAssertEqual(Set(searchItems.map(\.name)), ["track_name", "artist_name"])
    }

    func testNothingFoundReturnsNil() async throws {
        let transport = MockTransport { url in
            url.path == "/api/get" ? HTTPResponse(status: 404, body: Data(#"{"statusCode":404,"name":"TrackNotFound"}"#.utf8)) : HTTPResponse(status: 200, body: Data("[]".utf8))
        }
        let result = try await provider(transport).lyrics(for: LyricsQuery(title: "Nope", artist: "Nobody"))
        XCTAssertNil(result)
    }

    func testRateLimitHonorsRetryAfter() async {
        let clock = TestClock()
        let transport = MockTransport { _ in HTTPResponse(status: 429, headers: ["Retry-After": "30"], body: Data("<html>slow down</html>".utf8)) }
        let p = LRCLIBProvider(transport: transport, userAgent: "t", requestGap: 0, now: { clock.now })
        do {
            _ = try await p.lyrics(for: LyricsQuery(title: "A", artist: "B"))
            XCTFail("expected rate limit")
        } catch {
            XCTAssertEqual(error as? LyricsError, .rateLimited(until: clock.now.addingTimeInterval(30)))
        }
        XCTAssertEqual(transport.requests.count, 1, "no second request after a 429")
        _ = try? await p.lyrics(for: LyricsQuery(title: "C", artist: "D"))
        XCTAssertEqual(transport.requests.count, 1, "nothing is sent until Retry-After has passed")
        clock.advance(31)
        _ = try? await p.lyrics(for: LyricsQuery(title: "C", artist: "D"))
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testNetworkErrorOnBothRequestsThrows() async {
        let transport = MockTransport { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await provider(transport).lyrics(for: LyricsQuery(title: "A", artist: "B"))
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }

    func testPlusSignIsEscaped() async throws {
        let transport = MockTransport()
        _ = try await provider(transport).lyrics(for: LyricsQuery(title: "1+1", artist: "Beyoncé"))
        XCTAssertTrue(transport.requests.first?.absoluteString.contains("1%2B1") ?? false)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_700_000_000)
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(seconds)
    }
}

/// /api/get returns a single record object, not an array.
private func singleObject(_ row: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: row)) ?? Data()
}

final class LyricsResolverTests: XCTestCase {
    func testPrimaryThrowsThenFallbackStillRuns() async throws {
        let primary = StubProvider(name: "primary") { throw URLError(.timedOut) }
        let fallback = StubProvider(name: "fallback") { LyricsPayload(kind: .untimed, plain: "from fallback", provider: "fallback") }
        let outcome = try await LyricsResolver(providers: [primary, fallback]).resolve(LyricsQuery(title: "A", artist: "B"))
        XCTAssertEqual(primary.calls, 1)
        XCTAssertEqual(fallback.calls, 1)
        XCTAssertEqual(outcome.payload.plain, "from fallback")
        XCTAssertTrue(outcome.hadFailure)
    }

    func testPrimaryEmptyThenFallbackRuns() async throws {
        let primary = StubProvider(name: "primary") { nil }
        let fallback = StubProvider(name: "fallback") { LyricsPayload(kind: .instrumental) }
        let outcome = try await LyricsResolver(providers: [primary, fallback]).resolve(LyricsQuery(title: "A", artist: "B"))
        XCTAssertEqual(outcome.payload.kind, .instrumental)
        XCTAssertFalse(outcome.hadFailure)
    }

    func testPrimaryHitSkipsFallback() async throws {
        let primary = StubProvider(name: "primary") { LyricsPayload(kind: .untimed, plain: "x") }
        let fallback = StubProvider(name: "fallback") { nil }
        _ = try await LyricsResolver(providers: [primary, fallback]).resolve(LyricsQuery(title: "A", artist: "B"))
        XCTAssertEqual(fallback.calls, 0)
    }

    func testAllFailIsUnavailableWithFailureFlag() async throws {
        let a = StubProvider(name: "a") { throw URLError(.timedOut) }
        let b = StubProvider(name: "b") { nil }
        let outcome = try await LyricsResolver(providers: [a, b]).resolve(LyricsQuery(title: "A", artist: "B"))
        XCTAssertEqual(outcome.payload.kind, .unavailable)
        XCTAssertTrue(outcome.hadFailure)
    }

    func testCancellationIsNotSwallowed() async {
        let slow = StubProvider(name: "slow") {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return nil
        }
        let fallback = StubProvider(name: "fallback") { LyricsPayload(kind: .untimed, plain: "x") }
        let task = Task { try await LyricsResolver(providers: [slow, fallback]).resolve(LyricsQuery(title: "A", artist: "B")) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(fallback.calls, 0, "a cancelled lookup must not fall through to the next provider")
    }
}

final class LyricsCacheTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("isle-lyrics-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCacheKeepsStateWithWords() {
        let cache = LyricsCache(directory: dir)
        let q = LyricsQuery(title: "Song", artist: "Artist", album: "Album", duration: 200)
        cache.store(LyricsPayload(kind: .timed, synced: "[00:01.00]hi", plain: "hi", provider: "LRCLIB"), for: q)
        let loaded = cache.load(q)
        XCTAssertEqual(loaded?.kind, .timed)
        XCTAssertEqual(loaded?.synced, "[00:01.00]hi")
        cache.store(LyricsPayload(kind: .instrumental), for: LyricsQuery(title: "Other", artist: "Artist"))
        XCTAssertEqual(cache.load(LyricsQuery(title: "Other", artist: "Artist"))?.kind, .instrumental)
    }

    func testKeyIgnoresCaseAndDiacritics() {
        let cache = LyricsCache(directory: dir)
        cache.store(LyricsPayload(kind: .untimed, plain: "x"), for: LyricsQuery(title: "Déjà Vu", artist: "Beyoncé", duration: 200))
        XCTAssertNotNil(cache.load(LyricsQuery(title: "deja vu", artist: "BEYONCE", duration: 200.4)))
        XCTAssertNil(cache.load(LyricsQuery(title: "deja vu", artist: "Someone Else", duration: 200)))
    }

    func testUnavailableExpires() {
        let cache = LyricsCache(directory: dir)
        let q = LyricsQuery(title: "Song", artist: "Artist")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        cache.store(.unavailable, for: q, now: t0)
        XCTAssertEqual(cache.load(q, now: t0.addingTimeInterval(3600))?.kind, .unavailable, "not re-requested on every play")
        XCTAssertNil(cache.load(q, now: t0.addingTimeInterval(25 * 3600)), "but retried after it expires")
    }

    func testFailureMissExpiresSooner() {
        let cache = LyricsCache(directory: dir)
        let q = LyricsQuery(title: "Song", artist: "Artist")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        cache.store(.unavailable, for: q, afterFailure: true, now: t0)
        XCTAssertNotNil(cache.load(q, now: t0.addingTimeInterval(60)))
        XCTAssertNil(cache.load(q, now: t0.addingTimeInterval(11 * 60)))
    }

    func testClear() {
        let cache = LyricsCache(directory: dir)
        cache.store(.unavailable, for: LyricsQuery(title: "A", artist: "B"))
        XCTAssertEqual(cache.entryCount, 1)
        cache.clear()
        XCTAssertEqual(cache.entryCount, 0)
    }

    func testCorruptEntryIsAMiss() throws {
        let cache = LyricsCache(directory: dir)
        let q = LyricsQuery(title: "A", artist: "B")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: dir.appendingPathComponent(LyricsCache.key(for: q) + ".json"))
        XCTAssertNil(cache.load(q))
    }
}

@MainActor
final class LyricsServiceTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("isle-lyrics-svc-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func service(_ transport: MockTransport, enabled: @escaping () -> Bool, cache: Bool = true, debounce: TimeInterval = 0) -> LyricsService {
        let provider = LRCLIBProvider(transport: transport, userAgent: "t", requestGap: 0)
        return LyricsService(resolver: LyricsResolver(providers: [provider]), cache: cache ? LyricsCache(directory: dir) : nil,
                             debounce: debounce, isEnabled: enabled)
    }

    private let song = TrackInfo(title: "Song", artist: "Artist", album: "Album", duration: 200, bundleID: "x")

    func testNothingIsSentWhenToggleIsOff() async {
        let transport = MockTransport { _ in HTTPResponse(status: 200, body: json([row("Song", "Artist", synced: true)])) }
        let s = service(transport, enabled: { false })
        s.trackChanged(song)
        await s.waitForIdle()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(s.snapshot)
    }

    func testEnabledLooksUpAndPublishes() async {
        let transport = MockTransport { _ in HTTPResponse(status: 200, body: json([row("Song", "Artist", synced: true)])) }
        let s = service(transport, enabled: { true })
        var published: [LyricsKind?] = []
        s.onChange = { published.append($0?.state.kind) }
        s.trackChanged(song)
        XCTAssertEqual(s.snapshot?.state, .loading)
        await s.waitForIdle()
        XCTAssertEqual(s.snapshot?.state.kind, .timed)
        XCTAssertEqual(published, [nil, .timed], "loading (no kind) then timed")
        XCTAssertNotNil(s.snapshot?.payload?.synced, "raw lyrics stay available")
    }

    func testPlaceholderMetadataNeverHitsTheNetwork() async {
        let transport = MockTransport()
        let s = service(transport, enabled: { true })
        s.trackChanged(TrackInfo(title: "Track 7", artist: "Unknown Artist"))
        await s.waitForIdle()
        s.trackChanged(TrackInfo(title: "Real Song", artist: ""))
        await s.waitForIdle()
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(s.snapshot?.state, .unavailable)
    }

    func testUntitledByKnownArtistIsLookedUp() async {
        let transport = MockTransport()
        let s = service(transport, enabled: { true })
        s.trackChanged(TrackInfo(title: "Untitled", artist: "The Cure"))
        await s.waitForIdle()
        XCTAssertFalse(transport.requests.isEmpty)
    }

    func testCacheHitSendsNothingAndKeepsState() async {
        let transport = MockTransport { _ in HTTPResponse(status: 200, body: json([row("Song", "Artist", duration: 200, instrumental: true)])) }
        let first = service(transport, enabled: { true })
        first.trackChanged(song)
        await first.waitForIdle()
        XCTAssertEqual(first.snapshot?.state, .instrumental)
        let sent = transport.requests.count

        let second = service(transport, enabled: { true })
        second.trackChanged(song)
        XCTAssertEqual(second.snapshot?.state, .instrumental, "state comes back from the cache synchronously")
        await second.waitForIdle()
        XCTAssertEqual(transport.requests.count, sent)
    }

    func testUnavailableIsCachedToo() async {
        let transport = MockTransport()
        let s = service(transport, enabled: { true })
        s.trackChanged(song)
        await s.waitForIdle()
        XCTAssertEqual(s.snapshot?.state, .unavailable)
        let sent = transport.requests.count
        s.trackChanged(nil)
        s.trackChanged(song)
        await s.waitForIdle()
        XCTAssertEqual(transport.requests.count, sent)
    }

    func testRapidTrackChangesAreDebounced() async {
        let transport = MockTransport { _ in HTTPResponse(status: 200, body: json([row("Final", "Artist", synced: true)])) }
        let s = service(transport, enabled: { true }, debounce: 0.15)
        for i in 0..<6 {
            s.trackChanged(TrackInfo(title: "Skip \(i)", artist: "Artist"))
        }
        s.trackChanged(TrackInfo(title: "Final", artist: "Artist"))
        await s.waitForIdle()
        let titles = transport.requests.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "track_name" }?.value }
        XCTAssertEqual(Set(titles), ["Final"], "only the track that stuck was requested")
        XCTAssertEqual(s.snapshot?.state.kind, .timed)
    }

    func testBetweenTracksShowsNothing() async {
        let transport = MockTransport { _ in HTTPResponse(status: 200, body: json([row("Song", "Artist", synced: true)])) }
        let s = service(transport, enabled: { true })
        s.trackChanged(song)
        await s.waitForIdle()
        s.trackChanged(nil)
        XCTAssertNil(s.snapshot, "no stale lines once the track is gone")
    }

    func testDisableDropsStateAndStopsRequests() async {
        var enabled = true
        let transport = MockTransport { _ in HTTPResponse(status: 200, body: json([row("Song", "Artist", synced: true)])) }
        let s = service(transport, enabled: { enabled }, cache: false, debounce: 0.2)
        s.trackChanged(song)
        enabled = false
        s.disable()
        await s.waitForIdle()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(s.snapshot)
    }

    func testNetworkFailureResolvesUnavailable() async {
        let transport = MockTransport { _ in throw URLError(.timedOut) }
        let s = service(transport, enabled: { true })
        s.trackChanged(song)
        await s.waitForIdle()
        XCTAssertEqual(s.snapshot?.state, .unavailable)
    }
}

// MARK: - Weather (canned responses; no live network)

private final class CannedWeatherTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [URL] = []
    private(set) var headers: [[String: String]] = []
    var geocoding = Data(#"{"results":[{"id":1,"name":"Seattle","latitude":47.60621,"longitude":-122.33207,"country":"United States","admin1":"Washington","timezone":"America/Los_Angeles"}]}"#.utf8)
    var forecast = Data(#"{"current":{"temperature_2m":14.6,"weather_code":61,"is_day":1},"daily":{"temperature_2m_max":[17.2],"temperature_2m_min":[9.1]}}"#.utf8)
    var failForecast = false

    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse {
        lock.withLock { urls.append(url); self.headers.append(headers) }
        if url.host?.contains("geocoding") == true { return HTTPResponse(status: 200, body: geocoding) }
        if failForecast { throw URLError(.notConnectedToInternet) }
        return HTTPResponse(status: 200, body: forecast)
    }
    var count: Int { lock.withLock { urls.count } }
}

final class WeatherTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_500_000)

    private func service(_ transport: CannedWeatherTransport, enabled: Bool = true, city: String = "Seattle") -> WeatherService {
        let s = WeatherService(transport: transport, userAgent: "Isle test")
        s.isEnabled = { enabled }
        s.city = { city }
        s.unit = { .celsius }
        return s
    }

    func testParsesGeocodingAndForecast() async {
        let t = CannedWeatherTransport()
        let r = await service(t).refresh(now: t0)
        XCTAssertEqual(r?.place.name, "Seattle")
        XCTAssertEqual(r?.place.region, "Washington")
        XCTAssertEqual(r?.temperatureText, "15°")
        XCTAssertEqual(r?.high, 17.2)
        XCTAssertEqual(r?.low, 9.1)
        XCTAssertEqual(r?.symbol, "cloud.rain.fill")
        XCTAssertEqual(r?.summary, "Rain")
        XCTAssertEqual(t.headers.first?["User-Agent"], "Isle test")
    }

    func testNothingIsSentWhileOffOrWithoutACity() async {
        let off = CannedWeatherTransport()
        let r1 = await service(off, enabled: false).refresh(now: t0)
        XCTAssertNil(r1)
        XCTAssertEqual(off.count, 0)
        let blank = CannedWeatherTransport()
        let r2 = await service(blank, city: "   ").refresh(now: t0)
        XCTAssertNil(r2)
        XCTAssertEqual(blank.count, 0)
    }

    func testGeocodingIsCachedAndRefreshIsRateLimited() async {
        let t = CannedWeatherTransport()
        let s = service(t)
        await s.refresh(now: t0)
        XCTAssertEqual(t.count, 2, "one geocoding call and one forecast call")
        await s.refresh(now: t0.addingTimeInterval(60))
        XCTAssertEqual(t.count, 2, "not due yet")
        await s.refresh(now: t0.addingTimeInterval(31 * 60))
        XCTAssertEqual(t.count, 3, "only the forecast is repeated")
    }

    func testChangingTheCityGeocodesAgain() async {
        let t = CannedWeatherTransport()
        var city = "Seattle"
        let s = WeatherService(transport: t, userAgent: "x")
        s.isEnabled = { true }
        s.city = { city }
        await s.refresh(now: t0)
        city = "Portland"
        await s.refresh(now: t0.addingTimeInterval(10))
        XCTAssertEqual(t.count, 4)
    }

    func testNetworkFailureKeepsTheLastReading() async {
        let t = CannedWeatherTransport()
        let s = service(t)
        await s.refresh(now: t0)
        t.failForecast = true
        let r = await s.refresh(now: t0.addingTimeInterval(31 * 60))
        XCTAssertEqual(r?.temperatureText, "15°")
    }

    func testMalformedResponsesAreIgnored() {
        XCTAssertNil(OpenMeteoParser.parseGeocoding(Data("not json".utf8)))
        XCTAssertNil(OpenMeteoParser.parseGeocoding(Data(#"{"results":[]}"#.utf8)))
        XCTAssertNil(OpenMeteoParser.parseGeocoding(Data(#"{"results":[{"name":"X","latitude":999,"longitude":0}]}"#.utf8)))
        let p = WeatherPlace(name: "X", latitude: 1, longitude: 1)
        XCTAssertNil(OpenMeteoParser.parseForecast(Data(#"{"current":{}}"#.utf8), place: p, unit: .celsius, now: t0))
    }

    func testEveryCodeHasASymbolAndText() {
        for code in [0, 1, 2, 3, 45, 51, 56, 61, 66, 71, 80, 85, 95, 96, 12345] {
            XCTAssertFalse(WeatherCondition.symbol(code: code, isDay: true).isEmpty)
            XCTAssertFalse(WeatherCondition.text(code: code).isEmpty)
        }
        XCTAssertEqual(WeatherCondition.symbol(code: 0, isDay: false), "moon.stars.fill")
    }
}

final class WeatherLocationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_500_000)

    func testDeviceLocationSkipsCityLookupAndNeedsNoCity() async {
        let t = CannedWeatherTransport()
        let s = WeatherService(transport: t, userAgent: "x")
        s.isEnabled = { true }
        s.city = { "" }
        s.directPlace = { WeatherPlace(name: "Here", latitude: 47.6, longitude: -122.3) }
        let r = await s.refresh(now: t0)
        XCTAssertEqual(r?.place.name, "Here")
        XCTAssertEqual(t.count, 1, "only the forecast call; no geocoding")
        XCTAssertTrue(t.urls.allSatisfy { $0.host?.contains("geocoding") != true })
    }

    func testMovingToANewLocationFetchesAgain() async {
        let t = CannedWeatherTransport()
        var lat = 47.6
        let s = WeatherService(transport: t, userAgent: "x")
        s.isEnabled = { true }
        s.directPlace = { WeatherPlace(name: "Here", latitude: lat, longitude: -122.3) }
        await s.refresh(now: t0)
        lat = 40.7
        await s.refresh(now: t0.addingTimeInterval(10))
        XCTAssertEqual(t.count, 2)
    }

    func testBriefChargingIndicatorLastsFiveSeconds() {
        XCTAssertEqual(ChargingIndicatorMode.briefDuration, 2.5)
    }
}
