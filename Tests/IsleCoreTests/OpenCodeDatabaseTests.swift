import SQLite3
import XCTest
@testable import IsleCore

final class OpenCodeDatabaseTests: XCTestCase {
    private var dir: URL!
    private var dbURL: URL!
    private let now = Date(timeIntervalSince1970: 1_792_457_000)   // just after the session below

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("isle-opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("opencode.db")
        // The same shape as OpenCode 2's own database, plus an account table that must never be read.
        try exec("""
        CREATE TABLE session (id text PRIMARY KEY, directory text NOT NULL);
        CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
        CREATE TABLE account (id text PRIMARY KEY, access_token text NOT NULL);
        INSERT INTO account VALUES ('a', 'SECRET-TOKEN');
        INSERT INTO session VALUES ('ses_1', '/Users/dev/code/webshop');
        INSERT INTO message VALUES ('msg_u', 'ses_1', 1792456936303, 1792456936303, '{"role":"user","time":{"created":1792456936303},"summary":"my private prompt"}');
        INSERT INTO message VALUES ('msg_a', 'ses_1', 1792456936331, 1792456938037,
          '{"role":"assistant","modelID":"openai/gpt-6-luna","tokens":{"total":15669,"input":3,"output":14,"reasoning":2,"cache":{"write":15652,"read":7}},"time":{"created":1792456936331,"completed":1792456938037},"finish":"stop","cost":0}');
        """)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func exec(_ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func engine() -> AgentsEngine {
        let missing = dir.appendingPathComponent("none")
        let roots = AgentsEngine.Roots(claude: missing, codex: missing, openCode: dir.appendingPathComponent("storage/message"), copilot: missing,
                                       claudeLimitsFile: dir.appendingPathComponent("limits.json"), openCodeDatabase: dbURL)
        return AgentsEngine(roots: roots, stateFile: nil)
    }

    func testRowsCarryOnlyTheCountedFields() throws {
        let rows = try XCTUnwrap(OpenCodeDatabase.messages(at: dbURL, updatedSince: 0))
        XCTAssertEqual(rows.map(\.messageID), ["msg_u", "msg_a"])
        XCTAssertEqual(rows[1].directory, "/Users/dev/code/webshop")
        let text = String(decoding: rows.map(\.json).reduce(Data(), +), as: UTF8.self)
        XCTAssertFalse(text.contains("private prompt"))
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertNil(OpenCodeDatabase.messages(at: dir.appendingPathComponent("missing.db"), updatedSince: 0))
    }

    func testEngineCountsTokensModelAndProjectFromTheDatabase() throws {
        let e = engine()
        XCTAssertTrue(e.isPresent(.openCode))
        e.initialScan(now: now)
        let snap = try XCTUnwrap(e.snapshots(now: now).first { $0.agent == .openCode })
        XCTAssertEqual(snap.todayTotal, TokenTotals(input: 3, output: 14, cacheRead: 7, cacheWrite: 15652, reasoning: 2))
        XCTAssertEqual(snap.today.first?.model, "openai/gpt-6-luna")
        XCTAssertEqual(snap.project, "webshop")
        XCTAssertEqual(snap.sessionsToday, 1)
    }

    func testAStreamingReplyIsCountedOnceAndReplacedNotAdded() throws {
        let e = engine()
        e.initialScan(now: now)
        try exec("UPDATE message SET time_updated = 1792456939000, data = '{\"role\":\"assistant\",\"modelID\":\"openai/gpt-6-luna\",\"tokens\":{\"input\":3,\"output\":90,\"reasoning\":0,\"cache\":{\"write\":15652,\"read\":7}},\"time\":{\"created\":1792456936331}}' WHERE id = 'msg_a'")
        e.ingest(path: dbURL.path + "-wal", now: now)
        e.ingest(path: dbURL.path, now: now)
        let snap = try XCTUnwrap(e.snapshots(now: now).first { $0.agent == .openCode })
        XCTAssertEqual(snap.todayTotal.output, 90)
        XCTAssertEqual(snap.todayTotal.input, 3)
    }

    func testWatchPathsIncludeTheDatabaseFolder() {
        let roots = AgentsEngine.Roots(claude: dir, codex: dir, openCode: dir.appendingPathComponent("storage/message"), copilot: dir,
                                       claudeLimitsFile: dir.appendingPathComponent("l.json"), openCodeDatabase: dbURL)
        XCTAssertTrue(roots.watchPaths.contains(dir.path))
        XCTAssertTrue(roots.exists(.openCode))
    }
}
