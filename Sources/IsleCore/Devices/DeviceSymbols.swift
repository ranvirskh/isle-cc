import Foundation

public enum DeviceKind: String, Equatable {
    case headphones, keyboard, mouse, trackpad, speaker, gamepad, unknown
}

public enum DeviceSymbols {
    private static let generation = Rx(#"(?:\b|\()(\d)(?:st|nd|rd|th)?\s*gen|airpods\s*(\d)\b|gen(?:eration)?\s*(\d)"#)

    /// Apple (vendor 0x004C) audio products by Bluetooth product id; unknown Apple headphones with a charging case are AirPods.
    public static func appleAudioName(vendorID: Int?, productID: Int?, hasCase: Bool) -> String? {
        guard vendorID == 0x004C else { return nil }
        switch productID {
        case 0x200A?: return "AirPods Max"
        case 0x200E?, 0x2014?, 0x2024?, 0x2027?: return "AirPods Pro"
        case 0x2013?, 0x2019?: return "AirPods 3"
        case 0x2002?, 0x200F?: return "AirPods"
        default: return hasCase ? "AirPods" : nil
        }
    }

    /// SF Symbol candidates for a Bluetooth device, best first. The UI uses the first one this macOS has.
    public static func candidates(name: String, kind: DeviceKind = .unknown) -> [String] {
        let n = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()

        if n.contains("airpods") {
            if n.contains("max") { return ["airpodsmax", "airpods.max", "headphones"] }
            if n.contains("pro") { return ["airpodspro", "airpods.pro", "airpods"] }
            if let groups = generation.firstGroups(n),
               let digit = groups.dropFirst().compactMap({ $0 }).first.flatMap({ Int($0) }) {
                switch digit {
                case 3: return ["airpods.gen3", "airpods"]
                case 4...: return ["airpods.gen4", "airpods.gen3", "airpods"]
                default: return ["airpods"]
                }
            }
            return ["airpods"]
        }
        if n.contains("beats") {
            let earbuds = ["studio buds", "fit pro", "powerbeats", "flex", "beats x", "beatsx"].contains { n.contains($0) }
            if earbuds { return ["beats.earphones", "earbuds", "headphones"] }
            if n.contains("pill") { return ["hifispeaker", "speaker.wave.2.fill"] }
            return ["beats.headphones", "headphones"]
        }
        if n.contains("homepod") { return ["homepod", "hifispeaker"] }

        switch inferredKind(name: n, hint: kind) {
        case .keyboard: return ["keyboard"]
        case .mouse: return n.contains("magic") ? ["magicmouse", "computermouse"] : ["computermouse", "magicmouse"]
        case .trackpad: return ["trackpad", "rectangle.and.hand.point.up.left", "hand.point.up.left"]
        case .speaker: return ["hifispeaker", "speaker.wave.2.fill"]
        case .gamepad: return ["gamecontroller"]
        case .headphones:
            let buds = ["buds", "earbuds", "earphone", "in-ear", "wf-", "earfun", "jabra elite", "pixel buds", "freebuds", "nothing ear"]
            return buds.contains { n.contains($0) } ? ["earbuds", "headphones"] : ["headphones"]
        case .unknown: return ["headphones"]
        }
    }

    public static func primary(name: String, kind: DeviceKind = .unknown) -> String {
        candidates(name: name, kind: kind).first ?? "headphones"
    }

    /// The name wins when it is specific; otherwise the Bluetooth class hint decides.
    static func inferredKind(name n: String, hint: DeviceKind) -> DeviceKind {
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        if has(["keyboard", "keychron", "mx keys", "hhkb", "k380"]) { return .keyboard }
        if has(["trackpad"]) { return .trackpad }
        if has(["mouse", "mx master", "mx anywhere", "trackball"]) { return .mouse }
        if has(["controller", "gamepad", "dualsense", "dualshock", "xbox", "joy-con", "joycon", "8bitdo"]) { return .gamepad }
        if has(["speaker", "soundlink", "boom", "sonos", "jbl flip", "jbl charge", "soundcore", "megaboom", "echo"]) { return .speaker }
        if has(["headphone", "headset", "buds", "earbuds", "earphone", "wh-1000", "wf-1000", "quietcomfort", "bose qc"]) { return .headphones }
        return hint
    }

    /// Maps a Bluetooth class-of-device major/minor pair to a kind.
    public static func kind(majorClass: Int, minorClass: Int) -> DeviceKind {
        switch majorClass {
        case 0x04: // audio/video
            switch minorClass {
            case 0x05, 0x07, 0x0A: return .speaker // loudspeaker, portable audio, hi-fi
            default: return .headphones
            }
        case 0x05: // peripheral: the top two bits of the minor class say keyboard / pointing
            let type = (minorClass >> 4) & 0x3
            let sub = minorClass & 0xF
            if sub == 0x1 || sub == 0x2 { return .gamepad } // joystick, gamepad
            switch type {
            case 0x1: return .keyboard
            case 0x2: return .mouse
            case 0x3: return .keyboard
            default: return .unknown
            }
        default:
            return .unknown
        }
    }
}

public struct DeviceBattery: Equatable {
    public var left: Int?
    public var right: Int?
    public var caseLevel: Int?
    public var main: Int?

    public init(left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil, main: Int? = nil) {
        self.left = left
        self.right = right
        self.caseLevel = caseLevel
        self.main = main
    }

    public var isEmpty: Bool { left == nil && right == nil && caseLevel == nil && main == nil }

    public var readings: [PopupItem.BatteryReading] {
        var out: [PopupItem.BatteryReading] = []
        if let left { out.append(.init(label: "L", percent: left)) }
        if let right { out.append(.init(label: "R", percent: right)) }
        if let caseLevel { out.append(.init(label: "Case", percent: caseLevel)) }
        if out.isEmpty, let main { out.append(.init(label: "", percent: main)) }
        return out
    }
}

public enum BluetoothProfilerParser {
    static func percent(_ v: Any?) -> Int? {
        guard let s = Loose.string(v) else { return nil }
        let digits = s.trimmingCharacters(in: CharacterSet(charactersIn: "% ").union(.whitespaces))
        guard let n = Int(digits), (0...100).contains(n) else { return nil }
        return n
    }

    /// Normalizes "AA-BB-CC-DD-EE-FF" / "aa:bb:..." so addresses from different APIs compare equal.
    public static func normalize(address: String) -> String {
        address.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    /// Devices that are connected right now and report a battery level, from the same profiler output.
    public static func parseConnected(_ data: Data) -> [(name: String, battery: DeviceBattery)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var out: [(String, DeviceBattery)] = []
        for section in sections {
            guard let devices = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in devices {
                for (name, raw) in entry {
                    guard let props = raw as? [String: Any] else { continue }
                    let battery = DeviceBattery(
                        left: percent(props["device_batteryLevelLeft"]), right: percent(props["device_batteryLevelRight"]),
                        caseLevel: percent(props["device_batteryLevelCase"]),
                        main: percent(props["device_batteryLevelMain"]) ?? percent(props["device_batteryLevel"]))
                    if !battery.isEmpty { out.append((name, battery)) }
                }
            }
        }
        return out.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    public struct DeviceInfo: Equatable {
        public var name: String
        public var vendorID: Int?
        public var productID: Int?
        public var hasCase: Bool
        public var connected: Bool
    }

    private static func hex(_ v: Any?) -> Int? {
        guard let s = Loose.string(v) else { return nil }
        return Int(s.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive), radix: 16)
    }

    /// Name, vendor and product of every device the profiler lists, by normalized address. The connect notification
    /// often has no name yet, and the vendor / product ids are what tell AirPods apart from other headphones.
    public static func devices(_ data: Data) -> [String: DeviceInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var out: [String: DeviceInfo] = [:]
        for section in sections {
            for (key, value) in section where key.hasPrefix("device_") {
                guard let devices = value as? [[String: Any]] else { continue }
                for entry in devices {
                    for (name, raw) in entry {
                        guard let props = raw as? [String: Any], let address = Loose.string(props["device_address"]) else { continue }
                        out[normalize(address: address)] = DeviceInfo(
                            name: name, vendorID: hex(props["device_vendorID"]), productID: hex(props["device_productID"]),
                            hasCase: props["device_batteryLevelCase"] != nil, connected: key == "device_connected")
                    }
                }
            }
        }
        return out
    }

    /// Device names by normalized address.
    public static func names(_ data: Data) -> [String: String] { devices(data).mapValues(\.name) }

    /// Parses `system_profiler SPBluetoothDataType -json` into battery levels keyed by address and by name.
    public static func parse(_ data: Data) -> (byAddress: [String: DeviceBattery], byName: [String: DeviceBattery]) {
        var byAddress: [String: DeviceBattery] = [:]
        var byName: [String: DeviceBattery] = [:]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return (byAddress, byName) }
        for section in sections {
            for (key, value) in section where key.hasPrefix("device_") {
                guard let devices = value as? [[String: Any]] else { continue }
                for entry in devices {
                    for (name, raw) in entry {
                        guard let props = raw as? [String: Any] else { continue }
                        let battery = DeviceBattery(
                            left: percent(props["device_batteryLevelLeft"]),
                            right: percent(props["device_batteryLevelRight"]),
                            caseLevel: percent(props["device_batteryLevelCase"]),
                            main: percent(props["device_batteryLevelMain"]) ?? percent(props["device_batteryLevel"])
                        )
                        guard !battery.isEmpty else { continue }
                        byName[name] = battery
                        if let address = Loose.string(props["device_address"]) {
                            byAddress[normalize(address: address)] = battery
                        }
                    }
                }
            }
        }
        return (byAddress, byName)
    }
}
