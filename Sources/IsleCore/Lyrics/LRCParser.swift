import Foundation

public struct LyricLine: Equatable, Codable {
    public var time: Double
    public var text: String
    public var isInstrumentalMarker: Bool

    public init(time: Double, text: String, isInstrumentalMarker: Bool = false) {
        self.time = time
        self.text = text
        self.isInstrumentalMarker = isInstrumentalMarker
    }
}

public enum LRCParser {
    private static let stamp = Rx(#"^\s*\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    private static let offsetTag = Rx(#"^\s*\[offset:\s*([+-]?\d+)\s*\]\s*$"#)
    private static let wordStamp = Rx(#"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#)

    /// Parses LRC text. Handles [mm:ss.xx] and [mm:ss.xxx], several stamps on one line, an [offset:] tag,
    /// blank lines and junk lines. The result is sorted by time. A positive offset shifts lyrics earlier.
    public static func parse(_ text: String) -> [LyricLine] {
        var offsetMs = 0.0
        var parsed: [(time: Double, text: String, order: Int)] = []
        var order = 0

        for rawLine in text.components(separatedBy: .newlines) {
            if let groups = offsetTag.firstGroups(rawLine), let value = groups[1].flatMap(Double.init) {
                offsetMs = value
                continue
            }
            var rest = rawLine
            var times: [Double] = []
            while let range = stamp.firstMatchRange(rest), let groups = stamp.firstGroups(rest) {
                let minutes = groups[1].flatMap(Double.init) ?? 0
                let seconds = groups[2].flatMap(Double.init) ?? 0
                var fraction = 0.0
                if let f = groups[3] ?? nil, let n = Double(f) {
                    fraction = n / pow(10, Double(f.count))
                }
                times.append(minutes * 60 + seconds + fraction)
                rest = String(rest[range.upperBound...])
            }
            guard !times.isEmpty else { continue }
            let lyric = wordStamp.replacing(rest, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            for t in times {
                parsed.append((t, lyric, order))
                order += 1
            }
        }

        let shift = offsetMs / 1000
        return parsed
            .map { (time: max(0, $0.time - shift), text: $0.text, order: $0.order) }
            .sorted { $0.time != $1.time ? $0.time < $1.time : $0.order < $1.order }
            .map { LyricLine(time: $0.time, text: $0.text) }
    }

    /// Drops stamps and tags, for showing synced lyrics as plain text.
    public static func plainText(fromSynced text: String) -> String {
        parse(text).map(\.text).joined(separator: "\n")
    }
}

/// Finds the current line for a playback position.
public struct LyricTimeline: Equatable {
    public let lines: [LyricLine]

    public init(lines: [LyricLine]) {
        self.lines = lines
    }

    /// Index of the last line that starts at or before `position`; nil before the first line.
    public func index(at position: Double) -> Int? {
        guard !lines.isEmpty, position.isFinite else { return nil }
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found
    }

    public func line(at position: Double) -> LyricLine? {
        index(at: position).map { lines[$0] }
    }

    /// The next line with text after the current one, for the dimmed "up next" line.
    public func nextLine(after position: Double) -> LyricLine? {
        let start = (index(at: position) ?? -1) + 1
        guard start < lines.count else { return nil }
        return lines[start...].first { !$0.text.isEmpty || $0.isInstrumentalMarker }
    }

    /// Time of the next line change after `position`, so a timer can sleep until exactly then.
    public func nextChange(after position: Double) -> Double? {
        let start = (index(at: position) ?? -1) + 1
        return start < lines.count ? lines[start].time : nil
    }
}
