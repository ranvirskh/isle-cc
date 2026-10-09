import SwiftUI

/// Every animation timing and spring parameter in Isle lives in this file.
/// Tune here; nothing else in the app hard-codes a duration or a spring.
public enum Motion {
    // MARK: Global modifiers (set from Settings / system)

    /// User "animation speed" multiplier. 1 = normal, 2 = twice as fast.
    public static var speed: Double = 1.0
    /// Mirrors the system Reduce Motion setting.
    public static var reduceMotion: Bool = false

    /// Groups of animation the user can switch off individually in Settings.
    public enum Category: String, CaseIterable, Codable {
        case shape      // the island opening, closing and resizing
        case content    // content fading / scaling in and out with the shape
        case tabs       // tab switches and drop-target changes
        case media      // artwork flip, title slide, play/pause icon, progress
        case lyrics     // line-to-line lyric motion and marquee
        case banner     // the song-change banner
        case buttons    // press feedback
    }

    /// Overall feel. Scales spring response and damping.
    public enum Preset: String, CaseIterable, Codable {
        case smooth, snappy, bouncy, minimal
        var responseScale: Double {
            switch self { case .smooth: return 1.0; case .snappy: return 0.8; case .bouncy: return 1.0; case .minimal: return 0.9 }
        }
        var dampingOffset: Double {
            switch self { case .smooth: return 0.0; case .snappy: return 0.04; case .bouncy: return -0.14; case .minimal: return 0.15 }
        }
    }

    public static var preset: Preset = .smooth
    /// Master switch; when false every animation is instant.
    public static var animationsEnabled = true
    public static var disabledCategories: Set<Category> = []

    public static func isOn(_ c: Category) -> Bool { animationsEnabled && !disabledCategories.contains(c) }

    public struct Spring: Equatable {
        public var response: Double
        public var damping: Double
        public init(response: Double, damping: Double) {
            self.response = response
            self.damping = damping
        }
    }

    // MARK: Hover / collapse delays (seconds)

    /// Default delay between the cursor entering the notch and expansion.
    public static let hoverExpandDelayDefault: Double = 0.12
    /// Delay between the cursor leaving and the collapse starting.
    public static let collapseDelay: Double = 0.18
    /// Extra time a pop-up stays after the cursor leaves it.
    public static let popupLingerAfterHover: Double = 1.0
    /// How long a pop-up (device, power, agent) stays open.
    public static let popupDuration: Double = 3.0
    /// Pop-ups older than this when their turn comes are dropped.
    public static let popupMaxQueueAge: Double = 20.0
    /// Gap between two queued pop-ups.
    public static let popupGap: Double = 0.35

    // MARK: Shape springs

    /// Collapsed -> expanded. Slight overshoot, quick settle.
    public static let expand = Spring(response: 0.33, damping: 0.90)
    /// Expanded -> collapsed. No overshoot so the shape never dips under the notch.
    public static let collapse = Spring(response: 0.34, damping: 1.0)
    /// Collapsed -> pop-up and back.
    public static let popup = Spring(response: 0.40, damping: 0.82)
    /// Size change between tabs while expanded.
    public static let tabResize = Spring(response: 0.34, damping: 0.88)

    // MARK: Content

    /// Content fades in after the shape has started to open.
    public static let contentInDelay: Double = 0.08
    public static let contentInDuration: Double = 0.24
    /// Content fades out before the shape finishes closing.
    public static let contentOutDuration: Double = 0.12
    /// Scale and blur the content starts from while the shape opens.
    public static let contentInScale: Double = 0.94
    public static let contentInBlur: Double = 0   // blur is costly on a large view; opacity + scale carry the effect
    /// Stagger between header, columns, and rows.
    public static let stagger: Double = 0.035
    /// Tab cross-fade.
    public static let tabSwitchDuration: Double = 0.22
    public static let tabSlideDistance: Double = 14

    // MARK: Media

    public static let trackChangeDuration: Double = 0.45
    public static let artworkFlip = Spring(response: 0.45, damping: 0.80)
    public static let playPauseSwap: Double = 0.18
    public static let lyricLineDuration: Double = 0.32
    public static let lyricLineOffset: Double = 10
    /// Points per second for a lyric line too long to fit.
    public static let lyricMarqueeSpeed: Double = 34
    public static let lyricMarqueePause: Double = 0.9
    /// Gliding a scrolled lyric back to its start on pause: slow ease in and out, longer for longer lines.
    public static let lyricReturnMin: Double = 0.7
    public static let lyricReturnMax: Double = 1.4
    public static let lyricReturnPointsPerSecond: Double = 120
    public static let buttonPressScale: Double = 0.86
    public static let buttonPress = Spring(response: 0.22, damping: 0.6)
    public static let progressTick: Double = 0.25

    // MARK: Song-change banner

    /// How long the banner stays up when a new song starts.
    public static let bannerDuration: Double = 1.5
    public static let bannerFlip = Spring(response: 0.6, damping: 0.72)

    // MARK: Lock screen card

    public static let lockCardIn = Spring(response: 0.5, damping: 0.85)
    public static let lockLyricDuration: Double = 0.4

    // MARK: Agents

    public static let activityPulse: Double = 0.9

    // MARK: Reduce Motion fallback

    public static let reducedFade: Double = 0.15

    // MARK: SwiftUI helpers

    private static let instant = Animation.linear(duration: 0.001)

    public static func spring(_ s: Spring, _ c: Category = .shape) -> Animation {
        guard isOn(c) else { return instant }
        if reduceMotion { return .easeOut(duration: reducedFade) }
        let damping = min(1, max(0.35, s.damping + preset.dampingOffset))
        return .spring(response: s.response * preset.responseScale / max(speed, 0.1), dampingFraction: damping)
    }

    public static func ease(_ duration: Double, delay: Double = 0, _ c: Category = .content) -> Animation {
        guard isOn(c) else { return instant }
        if reduceMotion { return .easeOut(duration: reducedFade) }
        let k = max(speed, 0.1)
        return .easeInOut(duration: duration * preset.responseScale / k).delay(delay / k)
    }

    public static func easeOut(_ duration: Double, delay: Double = 0, _ c: Category = .content) -> Animation {
        guard isOn(c) else { return instant }
        if reduceMotion { return .easeOut(duration: reducedFade) }
        let k = max(speed, 0.1)
        return .easeOut(duration: duration * preset.responseScale / k).delay(delay / k)
    }

    /// Seconds, scaled by the speed setting, for non-SwiftUI timers that must line up with animations.
    public static func scaled(_ seconds: Double) -> Double {
        seconds / max(speed, 0.1)
    }
}
