import Foundation

/// Tolerant readers for loosely typed dictionaries coming from notifications, AppleScript and JSON.
enum Loose {
    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func double(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber:
            let d = n.doubleValue
            return d.isFinite ? d : nil
        case let s as String:
            // AppleScript in some locales prints decimals with a comma.
            let d = Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
            return (d?.isFinite ?? false) ? d : nil
        default: return nil
        }
    }

    static func int(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber:
            let d = n.doubleValue
            guard d.isFinite, abs(d) < 9e15 else { return nil }
            return Int(d)
        case let s as String:
            return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func bool(_ v: Any?) -> Bool? {
        switch v {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }
}

public enum PlayerState: String, Equatable {
    case playing, paused, stopped

    init?(notificationValue: String?) {
        guard let v = notificationValue?.lowercased() else { return nil }
        switch v {
        case "playing": self = .playing
        case "paused": self = .paused
        case "stopped": self = .stopped
        default: return nil
        }
    }
}

/// What a player notification or script result told us.
public struct PlayerSnapshot: Equatable {
    public var state: PlayerState
    public var track: TrackInfo?
    public var position: Double?
    public var shuffle: Bool?

    public init(state: PlayerState, track: TrackInfo?, position: Double? = nil, shuffle: Bool? = nil) {
        self.state = state
        self.track = track
        self.position = position
        self.shuffle = shuffle
    }
}

public enum SpotifyParser {
    public static let notificationName = "com.spotify.client.PlaybackStateChanged"

    /// Parses the userInfo of com.spotify.client.PlaybackStateChanged. Duration arrives in milliseconds.
    public static func parse(userInfo: [AnyHashable: Any]?) -> PlayerSnapshot? {
        guard let info = userInfo, let state = PlayerState(notificationValue: Loose.string(info["Player State"])) else { return nil }
        let title = Loose.string(info["Name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var track: TrackInfo?
        if !title.isEmpty {
            let ms = Loose.double(info["Duration"])
            track = TrackInfo(
                title: title,
                artist: Loose.string(info["Artist"]) ?? "",
                album: Loose.string(info["Album"]) ?? "",
                duration: ms.flatMap { $0 > 0 ? $0 / 1000 : nil },
                bundleID: KnownBundle.spotify,
                sourceTrackID: Loose.string(info["Track ID"])
            )
        }
        return PlayerSnapshot(state: state, track: track, position: Loose.double(info["Playback Position"]))
    }
}

public enum AppleMusicParser {
    public static let notificationName = "com.apple.Music.playerInfo"

    /// Parses the userInfo of com.apple.Music.playerInfo. "Total Time" is in milliseconds; position is not included.
    public static func parse(userInfo: [AnyHashable: Any]?) -> PlayerSnapshot? {
        guard let info = userInfo, let state = PlayerState(notificationValue: Loose.string(info["Player State"])) else { return nil }
        let title = Loose.string(info["Name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var track: TrackInfo?
        if !title.isEmpty {
            let ms = Loose.double(info["Total Time"])
            track = TrackInfo(
                title: title,
                artist: Loose.string(info["Artist"]) ?? "",
                album: Loose.string(info["Album"]) ?? "",
                duration: ms.flatMap { $0 > 0 ? $0 / 1000 : nil },
                bundleID: KnownBundle.appleMusic,
                sourceTrackID: Loose.string(info["PersistentID"])
            )
        }
        return PlayerSnapshot(state: state, track: track)
    }
}

/// Parses the tab-free, line-based reply of Isle's own AppleScript status queries.
/// Fields are separated by U+001F and written as key=value so order and extra fields do not matter.
public enum ScriptStatusParser {
    public static let separator = "\u{1F}"

    public static func parse(_ raw: String, bundleID: String) -> PlayerSnapshot? {
        var fields: [String: String] = [:]
        for part in raw.components(separatedBy: separator) {
            guard let eq = part.firstIndex(of: "=") else { continue }
            fields[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        guard let state = PlayerState(notificationValue: fields["state"]) else { return nil }
        let title = (fields["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var track: TrackInfo?
        if !title.isEmpty {
            var duration = Loose.double(fields["duration"])
            // Spotify reports milliseconds, Music reports seconds; the scripts tag which.
            if fields["durationUnit"] == "ms", let d = duration { duration = d / 1000 }
            track = TrackInfo(
                title: title,
                artist: fields["artist"] ?? "",
                album: fields["album"] ?? "",
                duration: duration.flatMap { $0 > 0 ? $0 : nil },
                isExplicit: Loose.bool(fields["explicit"]),
                bundleID: bundleID,
                sourceTrackID: fields["id"]
            )
        }
        return PlayerSnapshot(state: state, track: track,
                              position: Loose.double(fields["position"]),
                              shuffle: Loose.bool(fields["shuffle"]))
    }
}

/// One line of JSON from the system Now Playing helper.
public struct SystemNowPlayingSnapshot: Equatable {
    public var supported: Bool
    public var track: TrackInfo?
    public var isPlaying: Bool
    public var elapsed: Double?
    /// When `elapsed` was sampled (seconds since 1970), if the system reported it.
    public var elapsedTimestamp: Double?
    public var rate: Double?
    public var artworkID: String?
    public var artworkBase64: String?
    public var error: String?

    public init(supported: Bool = true, track: TrackInfo? = nil, isPlaying: Bool = false, elapsed: Double? = nil,
                elapsedTimestamp: Double? = nil, rate: Double? = nil, artworkID: String? = nil,
                artworkBase64: String? = nil, error: String? = nil) {
        self.supported = supported
        self.track = track
        self.isPlaying = isPlaying
        self.elapsed = elapsed
        self.elapsedTimestamp = elapsedTimestamp
        self.rate = rate
        self.artworkID = artworkID
        self.artworkBase64 = artworkBase64
        self.error = error
    }
}

public enum SystemNowPlayingParser {
    public static func parse(line: String) -> SystemNowPlayingSnapshot? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let supported = Loose.bool(obj["supported"]), !supported {
            return SystemNowPlayingSnapshot(supported: false, error: Loose.string(obj["error"]))
        }
        // Lines that are neither a state nor a capability report (e.g. log lines) are ignored.
        guard obj["playing"] != nil || obj["title"] != nil || obj["bundle"] != nil || obj["empty"] != nil else { return nil }

        let title = Loose.string(obj["title"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A browser reports its GPU/WebContent helper as the client and the real app as the parent.
        let parent = Loose.string(obj["parent"]).flatMap { $0.isEmpty ? nil : $0 }
        let bundle = parent ?? Loose.string(obj["bundle"]).flatMap { $0.isEmpty ? nil : $0 }
        var track: TrackInfo?
        if !title.isEmpty {
            let duration = Loose.double(obj["duration"])
            track = TrackInfo(
                title: title,
                artist: Loose.string(obj["artist"]) ?? "",
                album: Loose.string(obj["album"]) ?? "",
                duration: duration.flatMap { $0 > 0 ? $0 : nil },
                isExplicit: Loose.bool(obj["explicit"]),
                bundleID: bundle,
                sourceTrackID: Loose.string(obj["id"])
            )
        }
        return SystemNowPlayingSnapshot(
            supported: true,
            track: track,
            isPlaying: Loose.bool(obj["playing"]) ?? false,
            elapsed: Loose.double(obj["elapsed"]),
            elapsedTimestamp: Loose.double(obj["timestamp"]),
            rate: Loose.double(obj["rate"]),
            artworkID: Loose.string(obj["artworkID"]),
            artworkBase64: Loose.string(obj["artwork"]),
            error: nil
        )
    }
}

// MARK: - Choosing between sources

public struct SourceCandidate: Equatable {
    public var bundleID: String
    public var isPlaying: Bool
    public var hasTrack: Bool
    /// Last time this candidate was seen playing.
    public var lastPlayedAt: Date?

    public init(bundleID: String, isPlaying: Bool, hasTrack: Bool, lastPlayedAt: Date? = nil) {
        self.bundleID = bundleID
        self.isPlaying = isPlaying
        self.hasTrack = hasTrack
        self.lastPlayedAt = lastPlayedAt
    }
}

public enum SourceArbiter {
    /// Picks which app to show in System mode.
    /// Playing beats paused; among playing apps a music app beats anything else (browser video);
    /// among paused apps the one that played most recently wins.
    public static func choose(_ candidates: [SourceCandidate]) -> SourceCandidate? {
        let usable = candidates.filter { $0.hasTrack }
        let playing = usable.filter { $0.isPlaying }
        if !playing.isEmpty {
            if let music = mostRecent(playing.filter { KnownBundle.isMusicApp($0.bundleID) }) { return music }
            if let other = mostRecent(playing.filter { !KnownBundle.browsers.contains($0.bundleID) }) { return other }
            return mostRecent(playing)
        }
        return mostRecent(usable)
    }

    private static func mostRecent(_ list: [SourceCandidate]) -> SourceCandidate? {
        guard var best = list.first else { return nil }
        for c in list.dropFirst() {
            let a = c.lastPlayedAt ?? .distantPast, b = best.lastPlayedAt ?? .distantPast
            if a > b { best = c }
        }
        return best
    }
}
