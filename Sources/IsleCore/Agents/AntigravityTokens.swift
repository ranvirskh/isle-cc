import Foundation

/// Token counts from Antigravity's local conversation databases (`~/.gemini/antigravity/conversations/*.db`).
///
/// Each row of the `gen_metadata` table is a protobuf message for one model call. Its field 1 holds a message whose field 4
/// is the model's usage stats (`ModelUsageStats`, as named in Antigravity's own binary): field 2 is `input_tokens` and
/// field 3 is `output_tokens`. Only those two numbers are read; no text is ever decoded. The format is undocumented, so
/// anything that does not match yields nil and the readout simply stays hidden.
public enum AntigravityTokens {
    public struct Counts: Equatable {
        public var input: Int
        public var output: Int
        public var total: Int { input + output }
        public init(input: Int, output: Int) { self.input = input; self.output = output }
    }

    /// Input and output tokens for one `gen_metadata` blob, or nil if the blob doesn't have that shape.
    public static func counts(inBlob blob: Data) -> Counts? {
        guard let meta = firstMessage(in: blob, field: 1), let usage = firstMessage(in: meta, field: 4) else { return nil }
        var input: Int?, output: Int?
        var reader = Reader(usage)
        while let (field, wire) = reader.nextTag() {
            switch wire {
            case 0:
                guard let v = reader.varint() else { return nil }
                if field == 2 { input = Int(clamping: v) } else if field == 3 { output = Int(clamping: v) }
            default:
                guard reader.skip(wire) else { return nil }
            }
        }
        guard input != nil || output != nil else { return nil }
        return Counts(input: input ?? 0, output: output ?? 0)
    }

    // MARK: Minimal protobuf reader

    private static func firstMessage(in data: Data, field target: Int) -> Data? {
        var reader = Reader(data)
        while let (field, wire) = reader.nextTag() {
            if wire == 2 {
                guard let bytes = reader.lengthDelimited() else { return nil }
                if field == target { return bytes }
            } else if !reader.skip(wire) { return nil }
        }
        return nil
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        init(_ data: Data) { bytes = Array(data) }

        mutating func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let b = bytes[index]; index += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }

        mutating func nextTag() -> (field: Int, wire: Int)? {
            guard index < bytes.count, let tag = varint() else { return nil }
            return (Int(truncatingIfNeeded: tag >> 3), Int(tag & 7))
        }

        mutating func lengthDelimited() -> Data? {
            guard let len = varint(), len <= UInt64(bytes.count - index) else { return nil }
            let slice = Data(bytes[index..<index + Int(len)])
            index += Int(len)
            return slice
        }

        mutating func skip(_ wire: Int) -> Bool {
            switch wire {
            case 0: return varint() != nil
            case 1: index += 8; return index <= bytes.count
            case 2: return lengthDelimited() != nil
            case 5: index += 4; return index <= bytes.count
            default: return false
            }
        }
    }
}
