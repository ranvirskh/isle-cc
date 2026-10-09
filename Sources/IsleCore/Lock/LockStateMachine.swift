import Foundation

/// Decides when the lock screen card is on screen. Pure: the controller feeds events and performs the effects.
public struct LockStateMachine: Equatable {
    public enum Event: Equatable {
        case screenLocked
        case screenUnlocked
        case displaySlept
        case displayWoke
        /// Fast user switching: this session is no longer the one on screen.
        case sessionResignedActive
        case sessionBecameActive
        /// `identity` is nil when nothing is playing any more.
        case trackChanged(identity: String?)
        case playbackChanged(isPlaying: Bool)
        case settingChanged(enabled: Bool)
        case supportChanged(supported: Bool)
    }

    public enum Effect: Equatable {
        case showCard
        case hideCard
        /// The card is visible and its content changed.
        case updateCard
    }

    public private(set) var isLocked = false
    public private(set) var isDisplayAsleep = false
    public private(set) var isSessionActive = true
    public private(set) var isPlaying = false
    public private(set) var trackIdentity: String?
    public private(set) var isEnabled: Bool
    public private(set) var isSupported: Bool
    public private(set) var isCardVisible = false

    public init(enabled: Bool = false, supported: Bool = true) {
        isEnabled = enabled
        isSupported = supported
    }

    private var shouldShow: Bool {
        isEnabled && isSupported && isLocked && !isDisplayAsleep && isSessionActive && isPlaying && trackIdentity != nil
    }

    /// Media tracking and lyrics keep running (cheaply) only while this is true.
    public var needsMediaWhileLocked: Bool {
        isEnabled && isSupported && isLocked
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        var contentChanged = false
        switch event {
        case .screenLocked: isLocked = true
        case .screenUnlocked:
            isLocked = false
            // Unlocking implies the display is on, even if the wake notification is late or missing.
            isDisplayAsleep = false
        case .displaySlept: isDisplayAsleep = true
        case .displayWoke: isDisplayAsleep = false
        case .sessionResignedActive: isSessionActive = false
        case .sessionBecameActive: isSessionActive = true
        case .trackChanged(let identity):
            contentChanged = identity != trackIdentity
            trackIdentity = identity
            if identity == nil { isPlaying = false }
        case .playbackChanged(let playing):
            isPlaying = playing
        case .settingChanged(let enabled): isEnabled = enabled
        case .supportChanged(let supported): isSupported = supported
        }

        let show = shouldShow
        defer { isCardVisible = show }
        if show && !isCardVisible { return [.showCard] }
        if !show && isCardVisible { return [.hideCard] }
        if show && contentChanged { return [.updateCard] }
        return []
    }
}
