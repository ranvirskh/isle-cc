import XCTest
@testable import IsleCore

final class AntigravityTokensTests: XCTestCase {
    private func varint(_ v: UInt64) -> [UInt8] {
        var out: [UInt8] = [], n = v
        repeat { var b = UInt8(n & 0x7F); n >>= 7; if n != 0 { b |= 0x80 }; out.append(b) } while n != 0
        return out
    }
    private func field(_ number: Int, varint v: UInt64) -> [UInt8] { varint(UInt64(number << 3)) + varint(v) }
    private func field(_ number: Int, bytes: [UInt8]) -> [UInt8] { varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }

    /// The shape seen in Antigravity's `gen_metadata` rows: field 1 { field 4 { 2: input, 3: output } }.
    private func blob(input: UInt64, output: UInt64) -> Data {
        let usage = field(1, varint: 1318) + field(2, varint: input) + field(3, varint: output) + field(6, varint: 24)
        let meta = field(3, varint: 1318) + field(4, bytes: usage)
        return Data(field(2, bytes: Array("x".utf8)) + field(1, bytes: meta) + field(19, bytes: Array("model".utf8)))
    }

    func testReadsInputAndOutputTokens() {
        let c = AntigravityTokens.counts(inBlob: blob(input: 13351, output: 1577))
        XCTAssertEqual(c, .init(input: 13351, output: 1577))
        XCTAssertEqual(c?.total, 14928)
    }

    func testLargeValuesUseMultiByteVarints() {
        XCTAssertEqual(AntigravityTokens.counts(inBlob: blob(input: 5_000_000, output: 300_000)), .init(input: 5_000_000, output: 300_000))
    }

    func testUnexpectedOrBrokenDataGivesNil() {
        XCTAssertNil(AntigravityTokens.counts(inBlob: Data()))
        XCTAssertNil(AntigravityTokens.counts(inBlob: Data("not protobuf at all".utf8)))
        XCTAssertNil(AntigravityTokens.counts(inBlob: Data(field(1, bytes: field(3, varint: 5)))))   // no usage message
        XCTAssertNil(AntigravityTokens.counts(inBlob: blob(input: 1, output: 1).dropLast(30)))       // truncated
    }
}
