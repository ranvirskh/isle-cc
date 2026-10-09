import XCTest
@testable import IsleCore

final class ShelfStoreTests: XCTestCase {
    private var root: URL!
    private var shelfDir: URL { root.appendingPathComponent("Shelf") }
    private var sources: URL { root.appendingPathComponent("sources") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("isle-shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String, bytes: Int = 10) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    func testAddCopiesAndPersistsAcrossLaunches() throws {
        let file = try makeFile("report.pdf")
        let store = ShelfStore(directory: shelfDir)
        let added = store.add([file])
        XCTAssertEqual(added.count, 1)
        XCTAssertFalse(added[0].isReference)

        // The copy survives the original being deleted.
        try FileManager.default.removeItem(at: file)
        let relaunched = ShelfStore(directory: shelfDir)
        XCTAssertEqual(relaunched.load().map(\.name), ["report.pdf"])
        let url = try XCTUnwrap(relaunched.url(for: relaunched.items[0]))
        XCTAssertEqual(url.lastPathComponent, "report.pdf", "keeps the file name for dragging back out")
        XCTAssertEqual(try Data(contentsOf: url).count, 10)
    }

    func testSameNameTwiceDoesNotCollide() throws {
        let a = try makeFile("a.txt")
        let store = ShelfStore(directory: shelfDir)
        store.add([a])
        try Data("different".utf8).write(to: a)
        store.add([a])
        XCTAssertEqual(store.items.count, 2)
        let urls = store.items.compactMap { store.url(for: $0) }
        XCTAssertEqual(Set(urls).count, 2)
    }

    func testFoldersAreCopiedRecursively() throws {
        let folder = sources.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("sub/deep.txt"))
        let store = ShelfStore(directory: shelfDir)
        let item = try XCTUnwrap(store.add([folder]).first)
        XCTAssertTrue(item.isDirectory)
        let url = try XCTUnwrap(store.url(for: item))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("sub/deep.txt").path))
    }

    func testVeryLargeFilesAreReferencedNotCopied() throws {
        let big = try makeFile("movie.mov", bytes: 5000)
        let store = ShelfStore(directory: shelfDir, referenceThreshold: 1000)
        let item = try XCTUnwrap(store.add([big]).first)
        XCTAssertTrue(item.isReference)
        XCTAssertEqual(store.url(for: item)?.resolvingSymlinksInPath().path, big.resolvingSymlinksInPath().path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shelfDir.appendingPathComponent(item.id).path))

        // Removing a reference never deletes the original.
        store.remove(ids: [item.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: big.path))

        // Adding the same reference twice does not duplicate it.
        store.add([big])
        store.add([big])
        XCTAssertEqual(store.items.count, 1)
    }

    func testMissingReferenceIsDroppedOnLoad() throws {
        let big = try makeFile("gone.bin", bytes: 5000)
        let store = ShelfStore(directory: shelfDir, referenceThreshold: 1000)
        store.add([big])
        try FileManager.default.removeItem(at: big)
        XCTAssertTrue(ShelfStore(directory: shelfDir).load().isEmpty)
    }

    func testRemoveDeletesStoredCopy() throws {
        let store = ShelfStore(directory: shelfDir)
        let items = store.add([try makeFile("a.txt"), try makeFile("b.txt")])
        store.remove(ids: [items[0].id])
        XCTAssertEqual(store.items.map(\.name), ["b.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: shelfDir.appendingPathComponent(items[0].id).path))
        XCTAssertEqual(ShelfStore(directory: shelfDir).load().count, 1)
    }

    func testClearEmptiesShelfAndDisk() throws {
        let store = ShelfStore(directory: shelfDir)
        store.add([try makeFile("a.txt"), try makeFile("b.txt")])
        try FileManager.default.createDirectory(at: shelfDir.appendingPathComponent("orphan"), withIntermediateDirectories: true)
        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: shelfDir.path)
        XCTAssertEqual(left, ["index.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sources.appendingPathComponent("a.txt").path), "originals untouched")
    }

    func testAutoClearAfterNDays() throws {
        let store = ShelfStore(directory: shelfDir)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.add([try makeFile("old.txt")], now: now.addingTimeInterval(-8 * 86400))
        store.add([try makeFile("new.txt")], now: now.addingTimeInterval(-1 * 86400))
        XCTAssertEqual(store.purgeExpired(days: 0, now: now), 0, "0 disables auto-clear")
        XCTAssertEqual(store.purgeExpired(days: 7, now: now), 1)
        XCTAssertEqual(store.items.map(\.name), ["new.txt"])
    }

    func testMissingAndNonFileURLsAreSkipped() {
        let store = ShelfStore(directory: shelfDir)
        let added = store.add([sources.appendingPathComponent("nope.txt"), URL(string: "https://example.com")!])
        XCTAssertTrue(added.isEmpty)
    }

    func testDroppingAShelfItemBackOnTheShelfIsIgnored() throws {
        let store = ShelfStore(directory: shelfDir)
        let item = try XCTUnwrap(store.add([try makeFile("a.txt")]).first)
        let stored = try XCTUnwrap(store.url(for: item))
        XCTAssertTrue(store.add([stored]).isEmpty)
        XCTAssertEqual(store.items.count, 1)
    }

    func testCorruptIndexYieldsEmptyShelf() throws {
        try FileManager.default.createDirectory(at: shelfDir, withIntermediateDirectories: true)
        try Data("{{{".utf8).write(to: shelfDir.appendingPathComponent("index.json"))
        XCTAssertTrue(ShelfStore(directory: shelfDir).load().isEmpty)
    }

    func testTextSnippet() throws {
        let store = ShelfStore(directory: shelfDir)
        let item = try XCTUnwrap(store.addText("hello", suggestedName: "a/b:c", fileExtension: "txt"))
        XCTAssertEqual(item.name, "a-b-c.txt")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(store.url(for: item)), encoding: .utf8), "hello")
    }
}

final class DeviceSymbolTests: XCTestCase {
    func testAirPodsVariants() {
        XCTAssertEqual(DeviceSymbols.primary(name: "Ranvir’s AirPods Pro"), "airpodspro")
        XCTAssertEqual(DeviceSymbols.primary(name: "AirPods Pro 2"), "airpodspro")
        XCTAssertEqual(DeviceSymbols.primary(name: "AirPods Max"), "airpodsmax")
        XCTAssertEqual(DeviceSymbols.primary(name: "Sam's AirPods"), "airpods")
        XCTAssertEqual(DeviceSymbols.primary(name: "AirPods (3rd generation)"), "airpods.gen3")
        XCTAssertEqual(DeviceSymbols.primary(name: "AirPods 3"), "airpods.gen3")
        XCTAssertEqual(DeviceSymbols.primary(name: "AirPods 4"), "airpods.gen4")
        XCTAssertEqual(DeviceSymbols.primary(name: "AirPods (2nd generation)"), "airpods")
        XCTAssertEqual(DeviceSymbols.primary(name: "airpods pro max"), "airpodsmax")
    }

    func testOtherDevicesByName() {
        XCTAssertEqual(DeviceSymbols.primary(name: "Magic Keyboard"), "keyboard")
        XCTAssertEqual(DeviceSymbols.primary(name: "Magic Mouse"), "magicmouse")
        XCTAssertEqual(DeviceSymbols.primary(name: "MX Master 3S"), "computermouse")
        XCTAssertEqual(DeviceSymbols.primary(name: "Magic Trackpad"), "trackpad")
        XCTAssertEqual(DeviceSymbols.primary(name: "JBL Flip 6"), "hifispeaker")
        XCTAssertEqual(DeviceSymbols.primary(name: "DualSense Wireless Controller"), "gamecontroller")
        XCTAssertEqual(DeviceSymbols.primary(name: "Xbox Wireless Controller"), "gamecontroller")
        XCTAssertEqual(DeviceSymbols.primary(name: "WH-1000XM5"), "headphones")
        XCTAssertEqual(DeviceSymbols.primary(name: "Galaxy Buds2 Pro"), "earbuds")
        XCTAssertEqual(DeviceSymbols.primary(name: "Beats Studio Pro"), "beats.headphones")
        XCTAssertEqual(DeviceSymbols.primary(name: "Beats Fit Pro"), "beats.earphones")
        XCTAssertEqual(DeviceSymbols.primary(name: "HomePod mini"), "homepod")
    }

    func testClassHintUsedWhenNameSaysNothing() {
        XCTAssertEqual(DeviceSymbols.primary(name: "Sam's Thing", kind: .keyboard), "keyboard")
        XCTAssertEqual(DeviceSymbols.primary(name: "Sam's Thing", kind: .speaker), "hifispeaker")
        XCTAssertEqual(DeviceSymbols.primary(name: "Sam's Thing", kind: .gamepad), "gamecontroller")
        XCTAssertEqual(DeviceSymbols.primary(name: "Sam's Thing"), "headphones", "default")
        XCTAssertEqual(DeviceSymbols.primary(name: ""), "headphones")
        // A specific name beats a wrong class hint.
        XCTAssertEqual(DeviceSymbols.primary(name: "Magic Keyboard", kind: .mouse), "keyboard")
    }

    func testEveryMappingHasAFallbackChain() {
        for name in ["AirPods 4", "Magic Trackpad", "Beats Pill", "Unknown"] {
            XCTAssertFalse(DeviceSymbols.candidates(name: name).isEmpty)
        }
        XCTAssertGreaterThan(DeviceSymbols.candidates(name: "Magic Trackpad").count, 1, "trackpad symbol may not exist; needs a fallback")
    }

    func testBluetoothClassMapping() {
        XCTAssertEqual(DeviceSymbols.kind(majorClass: 0x04, minorClass: 0x06), .headphones)
        XCTAssertEqual(DeviceSymbols.kind(majorClass: 0x04, minorClass: 0x05), .speaker)
        XCTAssertEqual(DeviceSymbols.kind(majorClass: 0x05, minorClass: 0x10), .keyboard)
        XCTAssertEqual(DeviceSymbols.kind(majorClass: 0x05, minorClass: 0x20), .mouse)
        XCTAssertEqual(DeviceSymbols.kind(majorClass: 0x05, minorClass: 0x02), .gamepad)
        XCTAssertEqual(DeviceSymbols.kind(majorClass: 0x01, minorClass: 0x00), .unknown)
    }

    func testBatteryParsing() {
        let jsonText = """
        {"SPBluetoothDataType":[{"controller_properties":{"controller_address":"AA:BB"},
          "device_connected":[{"Sam’s AirPods Pro":{"device_address":"11-22-33-44-55-66","device_batteryLevelCase":"64%","device_batteryLevelLeft":"100%","device_batteryLevelRight":"98 %","device_minorType":"Headphones"}},
                              {"Magic Keyboard":{"device_address":"AA:BB:CC:DD:EE:FF","device_batteryLevelMain":"71%"}},
                              {"No Battery":{"device_address":"00:00:00:00:00:01"}},
                              {"Weird":{"device_address":"00:00:00:00:00:02","device_batteryLevelMain":"lots"}}],
          "device_not_connected":[{"Old Mouse":{"device_address":"00:00:00:00:00:03","device_batteryLevelMain":"250%"}}]}]}
        """
        let parsed = BluetoothProfilerParser.parse(Data(jsonText.utf8))
        XCTAssertEqual(parsed.byAddress["11:22:33:44:55:66"], DeviceBattery(left: 100, right: 98, caseLevel: 64))
        XCTAssertEqual(parsed.byName["Magic Keyboard"]?.main, 71)
        XCTAssertNil(parsed.byName["No Battery"])
        XCTAssertNil(parsed.byName["Weird"])
        XCTAssertNil(parsed.byName["Old Mouse"], "out-of-range value rejected")
        XCTAssertEqual(parsed.byAddress["11:22:33:44:55:66"]?.readings.map(\.label), ["L", "R", "Case"])
        XCTAssertEqual(parsed.byName["Magic Keyboard"]?.readings.map(\.percent), [71])
        XCTAssertTrue(BluetoothProfilerParser.parse(Data("garbage".utf8)).byName.isEmpty)
    }
}

final class AgendaTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false, cal: String = "work") -> AgendaEvent {
        AgendaEvent(id: id, title: id, start: start, end: end, isAllDay: allDay, calendarID: cal)
    }

    func testTodayWithPastCurrentUpcoming() {
        let now = date(8, 12)
        let agenda = Agenda.build(events: [
            event("lunch", date(8, 11, 30), date(8, 12, 30)),
            event("standup", date(8, 9), date(8, 9, 15)),
            event("review", date(8, 15), date(8, 16)),
            event("tomorrow", date(9, 9), date(9, 10)),
        ], now: now, calendar: calendar)
        XCTAssertEqual(agenda.day, .today)
        XCTAssertEqual(agenda.rows.map(\.id), ["standup", "lunch", "review"])
        XCTAssertEqual(agenda.rows.map(\.status), [.past, .current, .upcoming])
    }

    func testTomorrowWhenTodayIsEmpty() {
        let agenda = Agenda.build(events: [event("tomorrow", date(9, 9), date(9, 10)), event("later", date(12, 9), date(12, 10))],
                                  now: date(8, 12), calendar: calendar)
        XCTAssertEqual(agenda.day, .tomorrow)
        XCTAssertEqual(agenda.rows.map(\.id), ["tomorrow"])
        XCTAssertEqual(agenda.rows.first?.status, .upcoming)
    }

    func testEmpty() {
        let agenda = Agenda.build(events: [], now: date(8, 12), calendar: calendar)
        XCTAssertEqual(agenda.day, .tomorrow)
        XCTAssertTrue(agenda.rows.isEmpty)
    }

    func testCalendarFiltering() {
        let events = [event("work-1", date(8, 13), date(8, 14), cal: "work"), event("home-1", date(8, 13), date(8, 14), cal: "home"),
                      event("holiday", date(8, 0), date(9, 0), allDay: true, cal: "holidays")]
        let all = Agenda.build(events: events, now: date(8, 12), calendar: calendar)
        XCTAssertEqual(all.rows.count, 3)
        let filtered = Agenda.build(events: events, now: date(8, 12), calendar: calendar, hiddenCalendarIDs: ["home", "holidays"])
        XCTAssertEqual(filtered.rows.map(\.id), ["work-1"])
        // Hiding every calendar that has events today falls through to tomorrow.
        let none = Agenda.build(events: events, now: date(8, 12), calendar: calendar, hiddenCalendarIDs: ["home", "holidays", "work"])
        XCTAssertEqual(none.day, .tomorrow)
        XCTAssertTrue(none.rows.isEmpty)
    }

    func testAllDayFirstAndNeverPast() {
        let agenda = Agenda.build(events: [
            event("meeting", date(8, 8), date(8, 9)),
            event("birthday", date(8, 0), date(9, 0), allDay: true),
        ], now: date(8, 23), calendar: calendar)
        XCTAssertEqual(agenda.rows.map(\.id), ["birthday", "meeting"])
        XCTAssertEqual(agenda.rows.map(\.status), [.current, .past])
    }

    func testMultiDayAndMidnightBoundaries() {
        let now = date(8, 12)
        let agenda = Agenda.build(events: [
            event("conference", date(7, 9), date(9, 17)),           // spans today
            event("ended-at-midnight", date(7, 22), date(8, 0)),    // belongs to yesterday
            event("starts-at-midnight", date(9, 0), date(9, 1)),    // belongs to tomorrow
            event("late", date(8, 23), date(9, 1)),                 // starts today, ends tomorrow
        ], now: now, calendar: calendar)
        XCTAssertEqual(agenda.rows.map(\.id), ["conference", "late"])
        XCTAssertEqual(agenda.rows.first?.status, .current)
    }

    func testZeroLengthAndInvertedEvents() {
        let agenda = Agenda.build(events: [
            event("reminder", date(8, 14), date(8, 14)),
            event("inverted", date(8, 16), date(8, 15)),
        ], now: date(8, 12), calendar: calendar)
        XCTAssertEqual(agenda.rows.map(\.id), ["reminder", "inverted"])
    }

    func testNextRefresh() {
        let now = date(8, 12)
        let agenda = Agenda.build(events: [event("a", date(8, 11), date(8, 12, 30)), event("b", date(8, 15), date(8, 16))],
                                  now: now, calendar: calendar)
        XCTAssertEqual(agenda.nextRefresh(after: now, calendar: calendar), date(8, 12, 30))
        XCTAssertEqual(Agenda.empty.nextRefresh(after: now, calendar: calendar), date(9, 0), "day rollover")
    }
}

final class AgendaDayNavigationTests: XCTestCase {
    private var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    private let now = Date(timeIntervalSince1970: 1_791_500_000) // 2026-10-08 22:13 UTC

    private func event(_ id: String, dayOffset: Int, hour: Int) -> AgendaEvent {
        let start = cal.date(byAdding: .hour, value: hour, to: cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now))!)!
        return AgendaEvent(id: id, title: id, start: start, end: start.addingTimeInterval(3600), calendarID: "c")
    }

    func testChosenFutureDayShowsOnlyThatDayAsUpcoming() {
        let events = [event("today", dayOffset: 0, hour: 9), event("d3", dayOffset: 3, hour: 10), event("d4", dayOffset: 4, hour: 10)]
        let day = cal.date(byAdding: .day, value: 3, to: now)!
        let a = Agenda.build(day: day, events: events, now: now, calendar: cal)
        XCTAssertEqual(a.rows.map(\.event.id), ["d3"])
        XCTAssertEqual(a.rows.first?.status, .upcoming)
        if case .other = a.day {} else { XCTFail("expected .other") }
    }

    func testPastDayIsAllPastAndTodayIsLabelledToday() {
        let events = [event("y", dayOffset: -1, hour: 9)]
        let a = Agenda.build(day: cal.date(byAdding: .day, value: -1, to: now)!, events: events, now: now, calendar: cal)
        XCTAssertEqual(a.rows.first?.status, .past)
        XCTAssertEqual(Agenda.build(day: now, events: [], now: now, calendar: cal).day, .today)
    }

    func testHiddenCalendarsAreFilteredOnAChosenDay() {
        let a = Agenda.build(day: now, events: [event("a", dayOffset: 0, hour: 20)], now: now, calendar: cal, hiddenCalendarIDs: ["c"])
        XCTAssertTrue(a.rows.isEmpty)
    }
}

final class BluetoothConnectedParserTests: XCTestCase {
    func testOnlyConnectedDevicesWithBatteriesAreListed() {
        let json = #"""
        {"SPBluetoothDataType":[{
          "device_connected":[
            {"AirPods Pro":{"device_address":"AA-BB","device_batteryLevelLeft":"80%","device_batteryLevelRight":"78%","device_batteryLevelCase":"64%"}},
            {"Magic Keyboard":{"device_address":"CC-DD","device_batteryLevel":"55%"}},
            {"Speaker":{"device_address":"EE-FF"}}
          ],
          "device_not_connected":[{"Old Mouse":{"device_batteryLevel":"12%"}}]
        }]}
        """#
        let list = BluetoothProfilerParser.parseConnected(Data(json.utf8))
        XCTAssertEqual(list.map(\.name), ["AirPods Pro", "Magic Keyboard"])
        XCTAssertEqual(list.first?.battery.left, 80)
        XCTAssertEqual(list.last?.battery.main, 55)
    }

    func testGarbageYieldsNothing() {
        XCTAssertTrue(BluetoothProfilerParser.parseConnected(Data("nope".utf8)).isEmpty)
        XCTAssertTrue(BluetoothProfilerParser.parseConnected(Data("{}".utf8)).isEmpty)
    }
}

final class BluetoothDeviceInfoTests: XCTestCase {
    func testReadsNameVendorAndProductByAddress() throws {
        let json = #"{"SPBluetoothDataType":[{"device_connected":[{"Slatt":{"device_address":"6C:12:70:0B:73:07","device_vendorID":"0x004C","device_productID":"0x2024","device_batteryLevelCase":"52%","device_batteryLevelLeft":"75%"}}],"device_not_connected":[{"g82":{"device_address":"20:DF:B9:D2:5A:8A"}}]}]}"#
        let all = BluetoothProfilerParser.devices(Data(json.utf8))
        let airpods = try XCTUnwrap(all["6C:12:70:0B:73:07"])
        XCTAssertEqual(airpods.name, "Slatt")
        XCTAssertTrue(airpods.connected)
        XCTAssertTrue(airpods.hasCase)
        XCTAssertEqual(airpods.vendorID, 0x4C)
        XCTAssertEqual(airpods.productID, 0x2024)
        XCTAssertFalse(try XCTUnwrap(all["20:DF:B9:D2:5A:8A"]).connected)
        XCTAssertEqual(BluetoothProfilerParser.normalize(address: "6c-12-70-0b-73-07"), "6C:12:70:0B:73:07")
    }

    func testAppleHeadphonesAreRecognisedAsAirPods() {
        XCTAssertEqual(DeviceSymbols.appleAudioName(vendorID: 0x4C, productID: 0x2024, hasCase: true), "AirPods Pro")
        XCTAssertEqual(DeviceSymbols.appleAudioName(vendorID: 0x4C, productID: 0x200A, hasCase: false), "AirPods Max")
        XCTAssertEqual(DeviceSymbols.appleAudioName(vendorID: 0x4C, productID: 0x9999, hasCase: true), "AirPods")
        XCTAssertNil(DeviceSymbols.appleAudioName(vendorID: 0x4C, productID: 0x9999, hasCase: false))
        XCTAssertNil(DeviceSymbols.appleAudioName(vendorID: 0x054C, productID: 0x2024, hasCase: true))
    }
}
