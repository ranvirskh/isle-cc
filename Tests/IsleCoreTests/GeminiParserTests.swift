import XCTest
@testable import IsleCore

final class GeminiParserTests: XCTestCase {
    private let path = "/Users/x/.gemini/tmp/myproj/chats/session-2026-10-20T00-28-a15c8ac6.jsonl"
    private func parse(_ json: String, _ ctx: inout FileContext) -> [ParsedRecord] {
        GeminiParser.parse(line: Data(json.utf8), context: &ctx, path: path)
    }
    private func usage(_ records: [ParsedRecord]) -> [UsageEvent] {
        records.compactMap { if case .usage(let u) = $0 { return u } else { return nil } }
    }

    func testReplyCountsTokensWithCachedSplitOut() {
        var ctx = FileContext()
        let line = #"{"id":"m1","timestamp":"2026-10-20T00:28:29.337Z","type":"gemini","content":"SECRET reply text","thoughts":"SECRET","tokens":{"input":10074,"output":81,"cached":4065,"thoughts":12,"tool":0,"total":10155},"model":"gemini-3-flash-preview"}"#
        let u = usage(parse(line, &ctx))
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].tokens, TokenTotals(input: 6009, output: 81, cacheRead: 4065, cacheWrite: 0, reasoning: 12))
        XCTAssertEqual(u[0].model, "gemini-3-flash-preview")
        XCTAssertEqual(u[0].replaceKey, "gemini|m1")
        XCTAssertEqual(u[0].project, "myproj")
    }

    func testRewrittenReplyHasTheSameKeySoItIsNotCountedTwice() {
        var ctx = FileContext()
        let a = #"{"id":"m1","timestamp":"2026-10-20T00:28:29.337Z","type":"gemini","tokens":{"input":100,"output":5,"cached":0,"thoughts":0,"tool":0,"total":105},"model":"g"}"#
        let b = #"{"id":"m1","timestamp":"2026-10-20T00:28:29.337Z","type":"gemini","tokens":{"input":100,"output":5,"cached":0,"thoughts":0,"tool":0,"total":105},"model":"g","toolCalls":[]}"#
        XCTAssertEqual(usage(parse(a, &ctx)).first?.replaceKey, usage(parse(b, &ctx)).first?.replaceKey)
    }

    func testUserMessagesAreActivityOnlyAndOtherLinesIgnored() {
        var ctx = FileContext()
        let user = #"{"id":"u1","timestamp":"2026-10-20T00:28:12.994Z","type":"user","content":"SECRET prompt"}"#
        let records = parse(user, &ctx)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(usage(records).isEmpty)
        XCTAssertTrue(parse(#"{"$set":{"lastUpdated":"x"}}"#, &ctx).isEmpty)
        XCTAssertTrue(parse("not json", &ctx).isEmpty)
        XCTAssertTrue(parse(#"{"id":"m","timestamp":"2026-10-20T00:28:29.337Z","type":"gemini","tokens":{"input":0,"output":0}}"#, &ctx).filter { if case .usage = $0 { return true } else { return false } }.isEmpty)
    }
}
