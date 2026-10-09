import Foundation

public enum ExpandTrigger: String, Codable, CaseIterable {
    case hover, click
}

/// Pure state machine for the island. The window controller feeds it events and performs the effects it returns.
public struct IslandStateMachine: Equatable {
    public enum Phase: Equatable { case collapsed, expanded, popup }

    public enum Event: Equatable {
        case mouseEntered
        case mouseExited
        case clicked
        case hoverTimerFired
        case collapseTimerFired
        case dragApproached
        case dragEnded
        case popupRequested
        case popupTimerFired
        case forceCollapse
        case forceExpand
    }

    public enum Effect: Equatable {
        case startHoverTimer(TimeInterval)
        case cancelHoverTimer
        case startCollapseTimer(TimeInterval)
        case cancelCollapseTimer
        case startPopupTimer(TimeInterval)
        case cancelPopupTimer
        /// The pop-up on screen is done (timed out, clicked through, or replaced by a drag).
        case popupFinished
    }

    public private(set) var phase: Phase = .collapsed
    public private(set) var isHovered = false
    public private(set) var isDragging = false

    public var trigger: ExpandTrigger
    public var hoverDelay: TimeInterval
    public var collapseDelay: TimeInterval
    public var popupDuration: TimeInterval
    public var popupLinger: TimeInterval

    public init(trigger: ExpandTrigger = .hover,
                hoverDelay: TimeInterval = Motion.hoverExpandDelayDefault,
                collapseDelay: TimeInterval = Motion.collapseDelay,
                popupDuration: TimeInterval = Motion.popupDuration,
                popupLinger: TimeInterval = Motion.popupLingerAfterHover) {
        self.trigger = trigger
        self.hoverDelay = hoverDelay
        self.collapseDelay = collapseDelay
        self.popupDuration = popupDuration
        self.popupLinger = popupLinger
    }

    /// A pop-up may only be shown from the collapsed state and never during a drag.
    public var canPresentPopup: Bool { phase == .collapsed && !isDragging }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .mouseEntered:
            isHovered = true
            switch phase {
            case .collapsed:
                guard trigger == .hover else { return [] }
                if hoverDelay <= 0 {
                    phase = .expanded
                    return []
                }
                return [.startHoverTimer(hoverDelay)]
            case .expanded:
                return [.cancelCollapseTimer]
            case .popup:
                return [.cancelPopupTimer]
            }

        case .mouseExited:
            isHovered = false
            switch phase {
            case .collapsed:
                return [.cancelHoverTimer]
            case .expanded:
                return isDragging ? [] : [.startCollapseTimer(collapseDelay)]
            case .popup:
                return [.startPopupTimer(popupLinger)]
            }

        case .clicked:
            switch phase {
            case .collapsed:
                phase = .expanded
                return [.cancelHoverTimer]
            case .popup:
                phase = .expanded
                return [.cancelPopupTimer, .popupFinished]
            case .expanded:
                return []
            }

        case .hoverTimerFired:
            if phase == .collapsed, isHovered, trigger == .hover {
                phase = .expanded
            }
            return []

        case .collapseTimerFired:
            if phase == .expanded, !isHovered, !isDragging {
                phase = .collapsed
            }
            return []

        case .dragApproached:
            isDragging = true
            switch phase {
            case .collapsed:
                phase = .expanded
                return [.cancelHoverTimer]
            case .popup:
                phase = .expanded
                return [.cancelPopupTimer, .popupFinished]
            case .expanded:
                return [.cancelCollapseTimer]
            }

        case .dragEnded:
            guard isDragging else { return [] }
            isDragging = false
            if phase == .expanded, !isHovered {
                return [.startCollapseTimer(collapseDelay)]
            }
            return []

        case .popupRequested:
            guard canPresentPopup else { return [] }
            phase = .popup
            // A pop-up that opens under the cursor waits for the cursor to leave.
            return isHovered ? [.cancelHoverTimer] : [.cancelHoverTimer, .startPopupTimer(popupDuration)]

        case .popupTimerFired:
            if phase == .popup, !isHovered {
                phase = .collapsed
                return [.popupFinished]
            }
            return []

        case .forceCollapse:
            let wasPopup = phase == .popup
            phase = .collapsed
            isDragging = false
            var effects: [Effect] = [.cancelHoverTimer, .cancelCollapseTimer, .cancelPopupTimer]
            if wasPopup { effects.append(.popupFinished) }
            return effects

        case .forceExpand:
            let wasPopup = phase == .popup
            phase = .expanded
            var effects: [Effect] = [.cancelHoverTimer, .cancelPopupTimer]
            if wasPopup { effects.append(.popupFinished) }
            return effects
        }
    }
}

// MARK: - Pop-up queue

public enum PopupKind: String, Codable, CaseIterable {
    case bluetoothDevice, power, agentCompletion, nowPlaying
}

public struct PopupItem: Equatable, Identifiable {
    public var id: String
    public var kind: PopupKind
    public var symbol: String
    public var title: String
    public var subtitle: String
    /// Battery percentages to show (label, percent), e.g. ("L", 80).
    public var batteries: [BatteryReading]
    public var enqueuedAt: Date

    public struct BatteryReading: Equatable {
        public var label: String
        public var percent: Int
        public init(label: String, percent: Int) {
            self.label = label
            self.percent = percent
        }
    }

    public init(id: String, kind: PopupKind, symbol: String, title: String, subtitle: String = "",
                batteries: [BatteryReading] = [], enqueuedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.batteries = batteries
        self.enqueuedAt = enqueuedAt
    }
}

/// FIFO of pending pop-ups. Duplicate ids replace the queued entry instead of stacking up.
public struct PopupQueue {
    public private(set) var pending: [PopupItem] = []
    public private(set) var current: PopupItem?
    public var maxAge: TimeInterval

    public init(maxAge: TimeInterval = Motion.popupMaxQueueAge) {
        self.maxAge = maxAge
    }

    public mutating func enqueue(_ item: PopupItem) {
        if current?.id == item.id { return }
        if let i = pending.firstIndex(where: { $0.id == item.id }) {
            var replacement = item
            replacement.enqueuedAt = pending[i].enqueuedAt
            pending[i] = replacement
        } else {
            pending.append(item)
        }
    }

    /// Returns the next pop-up to show, if one may be shown now. Stale entries are dropped.
    public mutating func dequeue(canPresent: Bool, now: Date = Date()) -> PopupItem? {
        pending.removeAll { now.timeIntervalSince($0.enqueuedAt) > maxAge }
        guard canPresent, current == nil, !pending.isEmpty else { return nil }
        let item = pending.removeFirst()
        current = item
        return item
    }

    public mutating func finishCurrent() {
        current = nil
    }

    public mutating func removeAll(kind: PopupKind) {
        pending.removeAll { $0.kind == kind }
    }

    public var isEmpty: Bool { pending.isEmpty && current == nil }
}
