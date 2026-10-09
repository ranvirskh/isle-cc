import Foundation

/// Small NSRegularExpression wrapper. Patterns here are compile-time constants, so a bad one is a programmer error
/// that the unit tests catch; at runtime a failed compile simply never matches.
struct Rx {
    private let regex: NSRegularExpression?

    init(_ pattern: String, caseInsensitive: Bool = true) {
        regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func matches(_ s: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    func firstGroups(_ s: String) -> [String?]? {
        guard let regex, let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) }
        }
    }

    func firstMatchRange(_ s: String) -> Range<String.Index>? {
        guard let regex, let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return Range(m.range, in: s)
    }

    func replacing(_ s: String, with template: String) -> String {
        guard let regex else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

public enum LyricsNormalizer {
    private static let whitespace = Rx(#"\s+"#)

    /// Diacritic-fold, lowercase, trim. Applied to BOTH sides of every comparison.
    public static func fold(_ s: String) -> String {
        var out = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                            locale: Locale(identifier: "en_US_POSIX")).lowercased()
        out = out.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        out = whitespace.replacing(out, with: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum MetadataSanity {
    private static let placeholderArtist = Rx(#"^(?:unknown artist|unknown|artist unknown|no artist|<unknown>)$"#)
    // Disc-position titles. "Untitled" needs a number so a real song called "Untitled" is still looked up.
    private static let placeholderTitle = Rx(#"^(?:(?:audio\s+)?track\s*\d+|untitled\s*\d+|unknown(?:\s+track)?(?:\s*\d+)?)$"#)

    public static func isPlaceholderArtist(_ artist: String) -> Bool {
        placeholderArtist.matches(LyricsNormalizer.fold(artist))
    }

    public static func isPlaceholderTitle(_ title: String) -> Bool {
        placeholderTitle.matches(LyricsNormalizer.fold(title))
    }

    /// False when the metadata does not name a particular song; a search would return someone else's lyrics.
    public static func namesASong(title: String, artist: String) -> Bool {
        let t = LyricsNormalizer.fold(title), a = LyricsNormalizer.fold(artist)
        if t.isEmpty || a.isEmpty { return false }
        if isPlaceholderArtist(a) || isPlaceholderTitle(t) { return false }
        return true
    }
}

public enum TitleCleaner {
    private static let decoration = #"remaster(?:ed)?|live|mono|stereo|version|edit|mix|deluxe|bonus(?: track)?|feat\.?|ft\.?|featuring|with|explicit|clean|from|single|anniversary"#
    private static let bracketSuffix = Rx(#"\s*[\(\[][^\(\)\[\]]*\b(?:"# + decoration + #")(?![\p{L}\p{N}])[^\(\)\[\]]*[\)\]]\s*$"#)
    private static let dashSuffix = Rx(#"\s+[-–—]\s+(?:[^-–—]*\b)?(?:remaster(?:ed)?|live|mono|stereo|version|edit|deluxe|bonus track|single|anniversary)(?![\p{L}\p{N}])[^-–—]*$"#)

    /// Strips remaster / live / mono / stereo / featuring decoration from the end of a title, then folds diacritics.
    public static func clean(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<4 {
            var next = bracketSuffix.replacing(t, with: "")
            next = dashSuffix.replacing(next, with: "")
            next = next.trimmingCharacters(in: .whitespacesAndNewlines)
            if next == t || next.isEmpty { break }
            t = next
        }
        return t.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public enum VersionMarkers {
    /// Each marker matches on a leading word boundary only, so "undercover" is not "cover".
    /// "'s version" is the possessive form only, so "Album Version" is fine.
    private static let markers: [(name: String, rx: Rx)] = [
        ("karaoke", Rx(#"(?<![\p{L}\p{N}])karaoke"#)),
        ("instrumental", Rx(#"(?<![\p{L}\p{N}])instrumental"#)),
        ("sped up", Rx(#"(?<![\p{L}\p{N}])sped[\s-]?up"#)),
        ("slowed", Rx(#"(?<![\p{L}\p{N}])slowed"#)),
        ("nightcore", Rx(#"(?<![\p{L}\p{N}])nightcore"#)),
        ("remix", Rx(#"(?<![\p{L}\p{N}])remix"#)),
        ("re-record", Rx(#"(?<![\p{L}\p{N}])re-?record"#)),
        ("'s version", Rx(#"'s version"#)),
        ("cover", Rx(#"(?<![\p{L}\p{N}])cover"#)),
        ("tribute", Rx(#"(?<![\p{L}\p{N}])tribute"#)),
        ("acapella", Rx(#"(?<![\p{L}\p{N}])acapella"#)),
        ("a cappella", Rx(#"(?<![\p{L}\p{N}])a cappella"#)),
        ("made popular by", Rx(#"(?<![\p{L}\p{N}])made popular by"#)),
        ("originally performed by", Rx(#"(?<![\p{L}\p{N}])originally performed by"#)),
    ]

    public static func present(in title: String) -> Set<String> {
        let t = LyricsNormalizer.fold(title)
        return Set(markers.filter { $0.rx.matches(t) }.map(\.name))
    }

    /// True when the candidate carries a version marker the requested title does not.
    public static func candidateIsDifferentVersion(candidateTitle: String, requestedTitle: String) -> Bool {
        !present(in: candidateTitle).subtracting(present(in: requestedTitle)).isEmpty
    }
}

public enum LyricsPresentation {
    private static let creditLabels: [String] = [
        // English
        "lyrics by", "lyrics", "lyricist", "lyricists", "written by", "writer", "writers", "songwriter", "songwriters",
        "words by", "music by", "composer", "composers", "composed by", "composition", "producer", "producers",
        "produced by", "production", "co-producer", "executive producer", "arranger", "arranged by", "arrangement",
        "mixing", "mixed by", "mixing engineer", "mix engineer", "mastering", "mastered by", "mastering engineer",
        "engineer", "engineered by", "recording", "recorded by", "recording engineer", "vocals", "backing vocals",
        "background vocals", "guitar", "guitars", "bass", "drums", "keyboards", "programming", "publisher",
        "published by", "performed by", "translation", "translated by",
        // Chinese
        "作词", "作詞", "作曲", "编曲", "編曲", "词", "詞", "曲", "制作人", "製作人", "制作", "製作", "监制", "監製",
        "混音", "混音师", "混音師", "母带", "母帶", "母带工程师", "母帶工程師", "录音", "錄音", "录音师", "錄音師",
        "和声", "和聲", "演唱", "原唱", "出品", "发行", "發行", "填词", "填詞", "谱曲", "譜曲", "吉他", "贝斯", "鼓",
        // Japanese
        "歌", "唄", "プロデューサー", "プロデュース", "ミキシング", "ミックス", "マスタリング", "レコーディング",
        "アレンジ", "ボーカル", "ギター",
    ]

    // The whole label must be followed by a colon; a lyric that merely contains "mix" never matches.
    private static let creditRx: Rx = {
        let alternation = creditLabels.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return Rx(#"^\s*(?:"# + alternation + #")\s*[:：]"#)
    }()

    private static let placeholders: Set<String> = [
        "instrumental", "instrumentaltrack", "instrumentalsong", "instrumentalmusic", "nolyrics", "nolyricsavailable",
        "nolyricsfound", "thissongisinstrumental", "thistrackisinstrumental", "thissongisaninstrumental",
        "thistrackisaninstrumental", "纯音乐请欣赏", "純音樂請欣賞", "纯音乐", "純音樂",
    ]

    public static func isCreditLine(_ line: String) -> Bool {
        creditRx.matches(line)
    }

    /// "Instrumental", "[ no lyrics ]", "INSTRUMENTAL." and so on: a marker, not a lyric.
    public static func isInstrumentalPlaceholder(_ line: String) -> Bool {
        let squashed = String(line.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return placeholders.contains(squashed)
    }

    /// Timed lines as shown to the user: credit lines dropped, placeholder lines turned into markers.
    public static func displayLines(_ lines: [LyricLine]) -> [LyricLine] {
        lines.compactMap { line in
            if isCreditLine(line.text) { return nil }
            if isInstrumentalPlaceholder(line.text) {
                return LyricLine(time: line.time, text: "", isInstrumentalMarker: true)
            }
            return line
        }
    }

    /// True when the text has no real lyric: only placeholders, credits, and blanks.
    public static func isOnlyPlaceholder(plain: String) -> Bool {
        var sawPlaceholder = false
        for raw in plain.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || isCreditLine(line) { continue }
            if isInstrumentalPlaceholder(line) { sawPlaceholder = true; continue }
            return false
        }
        return sawPlaceholder
    }
}
