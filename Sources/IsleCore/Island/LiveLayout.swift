import CoreGraphics

/// Width the collapsed island extends past each side of the notch for its live activities.
public enum LiveLayout {
    public static let minimumSide: CGFloat = 34
    public static let coverSide: CGFloat = 44

    /// `privacyIcons` is how many mic / camera / screen dots are showing. `chargingText` is true when the charging
    /// readout takes the right slot (it yields to the equalizer when music is playing).
    public static func side(mediaLive: Bool, privacyIcons: Int, chargingLive: Bool, downloadLive: Bool = false, usageLive: Bool = false) -> CGFloat {
        var right: CGFloat = 12
        right += CGFloat(privacyIcons) * 15
        if usageLive { right += 30 }
        if mediaLive { right += 22 } else if chargingLive || downloadLive { right += downloadLive ? 40 : 30 }
        let left: CGFloat = mediaLive ? coverSide : 0
        let hasRightContent = privacyIcons > 0 || usageLive || mediaLive || chargingLive || downloadLive
        return max(left, hasRightContent ? right : 0, minimumSide)
    }
}

public enum ChargingIndicatorMode: String, CaseIterable, Codable {
    case off, brief, whileCharging

    /// How long the brief indicator stays after plugging in.
    public static let briefDuration: Double = 5
}
