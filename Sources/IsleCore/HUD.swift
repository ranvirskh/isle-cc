import Foundation

public enum HUDKind: String, Equatable { case volume, brightness, keyboard, microphone }

/// What the notch HUD shows: a level from 0 to 1 for volume or brightness.
public struct HUDState: Equatable {
    public var kind: HUDKind
    public var level: Double
    public var muted: Bool
    public init(kind: HUDKind, level: Double, muted: Bool = false) {
        self.kind = kind; self.level = min(1, max(0, level)); self.muted = muted
    }

    public var title: String {
        switch kind {
        case .volume: return "Volume"
        case .brightness: return "Brightness"
        case .keyboard: return "Keyboard backlight"
        case .microphone: return "Microphone"
        }
    }

    public var symbol: String {
        switch kind {
        case .brightness: return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .keyboard: return level <= 0 ? "light.min" : "light.max"
        case .microphone: return level <= 0 ? "mic.slash.fill" : "mic.fill"
        case .volume:
            if muted || level <= 0 { return "speaker.slash.fill" }
            return level < 1.0 / 3 ? "speaker.wave.1.fill" : level < 2.0 / 3 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }

    /// Fill shown by the bar: a muted speaker shows empty.
    public var shownLevel: Double { muted ? 0 : level }
}

/// The media keys that carry volume and brightness (IOKit NX_KEYTYPE_* values).
public enum MediaKey: Int, Equatable {
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7, keyboardUp = 21, keyboardDown = 22
}

public struct MediaKeyPress: Equatable {
    public var key: MediaKey
    public var isDown: Bool
    public var isRepeat: Bool

    /// Decodes `data1` of an NSSystemDefined event with subtype 8: key code in the high 16 bits, flags in the low 16
    /// (bits 8-15 are 0xA for key down, 0xB for key up; bit 0 marks an auto-repeat).
    public static func parse(data1: Int) -> MediaKeyPress? {
        let code = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0x0000_FFFF
        guard let key = MediaKey(rawValue: code) else { return nil }
        let state = (flags & 0xFF00) >> 8
        guard state == 0xA || state == 0xB else { return nil }
        return MediaKeyPress(key: key, isDown: state == 0xA, isRepeat: flags & 1 == 1)
    }
}

public enum HUDStep {
    public static let defaultPercent = 6.0
    public static let percentRange = 1.0...25.0

    /// One press moves the level by `percent` percentage points (a quarter of that with Shift-Option, at least 0.5),
    /// clamped to 0...1 and rounded to half a percent so repeated presses do not drift.
    public static func next(_ level: Double, up: Bool, fine: Bool, percent: Double = defaultPercent) -> Double {
        let p = min(percentRange.upperBound, max(percentRange.lowerBound, percent))
        let step = (fine ? max(0.5, p / 4) : p) / 100
        let target = min(1, max(0, level + (up ? step : -step)))
        return (target * 200).rounded() / 200
    }
}
