import Foundation

public enum MediaSourceSetting: String, Codable, CaseIterable {
    case system, spotify, appleMusic
}

public enum MediaCapability: String, Hashable, CaseIterable {
    case playPause, next, previous, seek, shuffle
}

public enum KnownBundle {
    public static let spotify = "com.spotify.client"
    public static let appleMusic = "com.apple.Music"

    /// Apps whose main purpose is music. Used to prefer them over browser video in System mode.
    public static let musicApps: Set<String> = [
        spotify, appleMusic, "com.apple.podcasts", "com.tidal.desktop", "com.amazon.music",
        "com.deezer.deezer-desktop", "com.qobuz.QobuzDesktop", "org.videolan.vlc", "com.coppertino.Vox",
        "com.swinsian.Swinsian", "app.cider.Cider", "sh.cider.electron", "com.plexamp.Plexamp",
        "com.apple.iTunes", "com.roon.Roon", "com.audirvana.Audirvana-Studio", "org.cogx.cog",
        "com.colliderli.iina", "com.doppler.mac", "tv.plex.plexamp",
    ]

    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "org.mozilla.firefox",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "company.thebrowser.dia", "com.kagi.kagimacOS", "app.zen-browser.zen",
        "org.chromium.Chromium", "com.google.Chrome.canary", "com.apple.WebKit.GPU", "com.apple.WebKit.WebContent",
    ]

    public static func isMusicApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return musicApps.contains(bundleID)
    }
}

public struct TrackInfo: Equatable {
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds. Nil when the source does not report one (live streams, some web video).
    public var duration: Double?
    public var isExplicit: Bool?
    /// The app that is playing, e.g. com.spotify.client. For browsers this is the browser, not its helper.
    public var bundleID: String?
    /// Source-specific identifier, when there is one.
    public var sourceTrackID: String?

    public init(title: String, artist: String = "", album: String = "", duration: Double? = nil,
                isExplicit: Bool? = nil, bundleID: String? = nil, sourceTrackID: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.isExplicit = isExplicit
        self.bundleID = bundleID
        self.sourceTrackID = sourceTrackID
    }

    /// Stable key for "is this the same song". Duration is left out because sources refine it after a track starts.
    public var identity: String {
        [bundleID ?? "", title, artist, album].joined(separator: "\u{1F}")
    }

    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A position sample plus what is needed to extrapolate it.
public struct PlaybackClock: Equatable {
    public var isPlaying: Bool
    public var position: Double
    public var sampledAt: Date
    public var rate: Double

    public init(isPlaying: Bool, position: Double, sampledAt: Date, rate: Double = 1) {
        self.isPlaying = isPlaying
        self.position = position
        self.sampledAt = sampledAt
        self.rate = rate
    }

    /// Position at `now`, interpolated from the last sample and clamped to the track.
    public func position(at now: Date, duration: Double?) -> Double {
        var p = position
        if isPlaying {
            let effectiveRate = rate > 0 ? rate : 1
            p += max(0, now.timeIntervalSince(sampledAt)) * effectiveRate
        }
        if !p.isFinite { p = 0 }
        p = max(0, p)
        if let duration, duration > 0 { p = min(p, duration) }
        return p
    }

    /// True when `other` describes a jump that plain playback would not produce (a seek).
    public func isSeek(comparedTo other: PlaybackClock, tolerance: Double = 1.5) -> Bool {
        let expected = position(at: other.sampledAt, duration: nil)
        return abs(expected - other.position) > tolerance
    }
}

public struct NowPlaying: Equatable {
    public var track: TrackInfo
    public var clock: PlaybackClock
    public var shuffle: Bool?
    public var capabilities: Set<MediaCapability>
    public var lastUpdate: Date

    public init(track: TrackInfo, clock: PlaybackClock, shuffle: Bool? = nil,
                capabilities: Set<MediaCapability> = [], lastUpdate: Date = Date()) {
        self.track = track
        self.clock = clock
        self.shuffle = shuffle
        self.capabilities = capabilities
        self.lastUpdate = lastUpdate
    }

    public var isPlaying: Bool { clock.isPlaying }
}

public enum TimeFormat {
    /// 0:07, 3:45, 1:02:03. Negative and non-finite input render as 0:00.
    public static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    public static func remaining(position: Double, duration: Double) -> String {
        "-" + clock(max(0, duration - position))
    }
}
