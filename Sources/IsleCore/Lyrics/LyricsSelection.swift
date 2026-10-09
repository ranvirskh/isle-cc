import Foundation

public struct LyricsQuery: Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double?

    public init(title: String, artist: String, album: String = "", duration: Double? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    public init(track: TrackInfo) {
        self.init(title: track.title, artist: track.artist, album: track.album, duration: track.duration)
    }
}

/// One row of a provider's search response.
public struct LyricsRecord: Equatable {
    public var id: Int?
    public var trackName: String
    public var artistName: String
    public var albumName: String
    public var duration: Double?
    public var instrumental: Bool
    public var plainLyrics: String?
    public var syncedLyrics: String?

    public init(id: Int? = nil, trackName: String, artistName: String, albumName: String = "", duration: Double? = nil,
                instrumental: Bool = false, plainLyrics: String? = nil, syncedLyrics: String? = nil) {
        self.id = id
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.instrumental = instrumental
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
    }

    /// Decodes a JSON array of records, or a single record. Unknown fields are ignored; bad rows are skipped.
    public static func decodeList(_ data: Data) -> [LyricsRecord] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [Any]
        if let array = json as? [Any] { rows = array } else { rows = [json] }
        return rows.compactMap { row in
            guard let o = row as? [String: Any] else { return nil }
            guard let track = Loose.string(o["trackName"]) ?? Loose.string(o["name"]) else { return nil }
            let duration = Loose.double(o["duration"])
            return LyricsRecord(
                id: Loose.int(o["id"]),
                trackName: track,
                artistName: Loose.string(o["artistName"]) ?? "",
                albumName: Loose.string(o["albumName"]) ?? "",
                duration: duration.flatMap { $0 > 0 ? $0 : nil },
                instrumental: Loose.bool(o["instrumental"]) ?? false,
                plainLyrics: Loose.string(o["plainLyrics"]),
                syncedLyrics: Loose.string(o["syncedLyrics"])
            )
        }
    }

    var hasSynced: Bool {
        guard let s = syncedLyrics, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return LRCParser.parse(s).contains { !$0.text.isEmpty }
    }

    var hasPlain: Bool {
        guard let p = plainLyrics else { return false }
        return !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum LyricsKind: String, Codable, Equatable {
    case timed, untimed, instrumental, unavailable
}

/// What gets cached for a track: the resolution state together with the raw words.
public struct LyricsPayload: Codable, Equatable {
    public var kind: LyricsKind
    public var synced: String?
    public var plain: String?
    public var provider: String?

    public init(kind: LyricsKind, synced: String? = nil, plain: String? = nil, provider: String? = nil) {
        self.kind = kind
        self.synced = synced
        self.plain = plain
        self.provider = provider
    }

    public static let unavailable = LyricsPayload(kind: .unavailable)
}

public enum LyricsSelector {
    public struct Scored: Equatable {
        public var record: LyricsRecord
        public var kind: LyricsKind
        public var score: Int
    }

    private static func related(_ a: String, _ b: String) -> (exact: Bool, contained: Bool) {
        guard !a.isEmpty, !b.isEmpty else { return (false, false) }
        if a == b { return (true, true) }
        return (false, a.contains(b) || b.contains(a))
    }

    /// Filter first, then rank. Returns nil when no row is safe to show.
    public static func select(_ records: [LyricsRecord], for query: LyricsQuery) -> Scored? {
        // Both sides go through the same normalization.
        let reqTitleRaw = LyricsNormalizer.fold(query.title)
        let reqTitleClean = LyricsNormalizer.fold(TitleCleaner.clean(query.title))
        let reqArtist = LyricsNormalizer.fold(query.artist)
        let reqAlbum = LyricsNormalizer.fold(query.album)

        var best: (scored: Scored, synced: Bool, durationGap: Double, index: Int)?

        for (index, record) in records.enumerated() {
            let candTitleRaw = LyricsNormalizer.fold(record.trackName)
            let candTitleClean = LyricsNormalizer.fold(TitleCleaner.clean(record.trackName))
            let candArtist = LyricsNormalizer.fold(record.artistName)
            let candAlbum = LyricsNormalizer.fold(record.albumName)

            // Candidate filter: title AND artist must each equal or contain the other.
            let titleExact = reqTitleRaw == candTitleRaw || reqTitleClean == candTitleClean
                || reqTitleClean == candTitleRaw || reqTitleRaw == candTitleClean
            let titleContained = titleExact || related(reqTitleClean, candTitleRaw).contained
                || related(reqTitleRaw, candTitleRaw).contained
            guard titleContained, !reqTitleClean.isEmpty, !candTitleRaw.isEmpty else { continue }
            let artist = related(reqArtist, candArtist)
            guard artist.exact || artist.contained else { continue }

            // A version marker the requested title lacks means a different recording.
            if VersionMarkers.candidateIsDifferentVersion(candidateTitle: record.trackName, requestedTitle: query.title) {
                continue
            }

            let kind: LyricsKind
            if record.instrumental {
                // Trust the flag only on an exact title and, when both are known, agreeing durations.
                guard reqTitleRaw == candTitleRaw || reqTitleClean == candTitleRaw else { continue }
                if let a = query.duration, let b = record.duration, abs(a - b) > 2 { continue }
                kind = .instrumental
            } else if record.hasSynced {
                kind = .timed
            } else if record.hasPlain {
                kind = .untimed
            } else {
                continue
            }

            var score = titleExact ? 8 : 4
            score += artist.exact ? 8 : 4
            if !reqAlbum.isEmpty, !candAlbum.isEmpty {
                let album = related(reqAlbum, candAlbum)
                if album.exact { score += 4 } else if album.contained { score += 2 }
            }
            let synced = kind == .timed
            if synced { score += 3 }

            var gap = Double.greatestFiniteMagnitude
            if let a = query.duration, let b = record.duration { gap = abs(a - b) }

            let candidate = (scored: Scored(record: record, kind: kind, score: score), synced: synced, durationGap: gap, index: index)
            if let current = best {
                // Synced rows always beat unsynced ones; then score; then the closer duration; then response order.
                let better: Bool
                if candidate.synced != current.synced {
                    better = candidate.synced
                } else if candidate.scored.score != current.scored.score {
                    better = candidate.scored.score > current.scored.score
                } else if candidate.durationGap != current.durationGap {
                    better = candidate.durationGap < current.durationGap
                } else {
                    better = false
                }
                if better { best = candidate }
            } else {
                best = candidate
            }
        }
        return best?.scored
    }

    /// Turns the chosen row into what is cached and shown.
    public static func payload(for scored: Scored, provider: String) -> LyricsPayload {
        let record = scored.record
        switch scored.kind {
        case .instrumental:
            return LyricsPayload(kind: .instrumental, provider: provider)
        case .timed:
            let display = LyricsPresentation.displayLines(LRCParser.parse(record.syncedLyrics ?? ""))
            if !display.contains(where: { !$0.text.isEmpty }) {
                return LyricsPayload(kind: display.contains { $0.isInstrumentalMarker } ? .instrumental : .unavailable,
                                     synced: record.syncedLyrics, plain: record.plainLyrics, provider: provider)
            }
            return LyricsPayload(kind: .timed, synced: record.syncedLyrics, plain: record.plainLyrics, provider: provider)
        case .untimed:
            let plain = record.plainLyrics ?? ""
            if LyricsPresentation.isOnlyPlaceholder(plain: plain) {
                return LyricsPayload(kind: .instrumental, plain: plain, provider: provider)
            }
            return LyricsPayload(kind: .untimed, plain: plain, provider: provider)
        case .unavailable:
            return .unavailable
        }
    }
}

/// The resolved state of a track's lyrics, as the UI consumes it.
public enum LyricsState: Equatable {
    case loading
    case timed(LyricTimeline)
    case untimed(String)
    case instrumental
    case unavailable

    public init(payload: LyricsPayload) {
        switch payload.kind {
        case .timed:
            let lines = LyricsPresentation.displayLines(LRCParser.parse(payload.synced ?? ""))
            self = lines.isEmpty ? .unavailable : .timed(LyricTimeline(lines: lines))
        case .untimed:
            self = .untimed(payload.plain ?? "")
        case .instrumental:
            self = .instrumental
        case .unavailable:
            self = .unavailable
        }
    }

    public var kind: LyricsKind? {
        switch self {
        case .loading: return nil
        case .timed: return .timed
        case .untimed: return .untimed
        case .instrumental: return .instrumental
        case .unavailable: return .unavailable
        }
    }
}
