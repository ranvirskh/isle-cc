import AppKit
import IOBluetooth
import IOKit.ps
import IsleCore

struct BatteryState: Equatable {
    var percent: Int?
    var isCharging: Bool
    var onAC: Bool
    var hasBattery: Bool
}

/// Bluetooth connection and power-adapter events, turned into pop-up items. Battery state for the header.
@MainActor
final class DevicesController: ObservableObject {
    @Published private(set) var battery = BatteryState(percent: nil, isCharging: false, onAC: false, hasBattery: false)
    var onPopup: ((PopupItem) -> Void)?
    /// Connected Bluetooth devices that report a battery. Read on demand (for the lock screen), never on a timer.
    @Published private(set) var connected: [ConnectedDevice] = []

    struct ConnectedDevice: Equatable, Identifiable {
        var name: String
        var battery: DeviceBattery
        var id: String { name }
    }

    func refreshConnected() {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var list: [ConnectedDevice] = []
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                list = BluetoothProfilerParser.parseConnected(data).map { ConnectedDevice(name: $0.name, battery: $0.battery) }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in if self?.connected != list { self?.connected = list } } }
        }
    }

    private let settings = Settings.shared
    private var connectNotification: IOBluetoothUserNotification?
    private var psSource: CFRunLoopSource?
    private var lastOnAC: Bool?
    private var registeredAt = Date()
    /// Addresses already seen connected, so a connect event with no usable address can be matched to the one new device.
    private var seenConnected: Set<String> = []

    func start() {
        readBattery()
        lastOnAC = battery.onAC
        // Registered once; the callback checks the setting so toggling needs no re-registration.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<DevicesController>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.powerChanged() } }
        }, ctx)?.takeRetainedValue() {
            psSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        registeredAt = Date()
        profile(address: "") { [weak self] _, _, all in self?.seenConnected = Set(all.filter { $0.value.connected }.keys) }
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
    }

    // MARK: Power

    private func readBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String?
        let onAC = providing == kIOPSACPowerValue
        var state = BatteryState(percent: nil, isCharging: false, onAC: onAC, hasBattery: false)
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            state.hasBattery = true
            if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                state.percent = Int((Double(cur) / Double(max) * 100).rounded())
            }
            state.isCharging = (d[kIOPSIsChargingKey] as? Bool) ?? false
        }
        if state != battery { battery = state }
    }

    private func powerChanged() {
        readBattery()
        let onAC = battery.onAC
        defer { lastOnAC = onAC }
        guard let last = lastOnAC, last != onAC, settings.popupPower, battery.hasBattery else { return }
        let sub = battery.percent.map { "\($0)%" } ?? ""
        onPopup?(PopupItem(id: "power-\(onAC)", kind: .power,
                           symbol: onAC ? "powerplug.fill" : "battery.50percent",
                           title: onAC ? "Power adapter connected" : "On battery power",
                           subtitle: sub,
                           batteries: battery.percent.map { [.init(label: "", percent: $0)] } ?? []))
    }

    // MARK: Bluetooth

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Registering replays every device that is already connected; only genuinely new connections get a pop-up.
        guard settings.popupBluetooth, Date().timeIntervalSince(registeredAt) > 3 else { return }
        // Phones, tablets and computers (Bluetooth major class 1 = computer, 2 = phone) are not accessories worth a pop-up.
        let major = Int(device.deviceClassMajor)
        if major == 1 || major == 2 { return }
        let address = device.addressString ?? ""
        let kind = DeviceSymbols.kind(majorClass: major, minorClass: Int(device.deviceClassMinor))
        let knownName = device.name.flatMap { $0.isEmpty ? nil : $0 }
        // The name, model and battery levels show up in the profiler a moment after the connection is made, so look
        // again a couple of times if the device is not listed yet.
        Log.write("bluetooth: connect event name \(knownName ?? "nil") address \(address.isEmpty ? "none" : "present")")
        resolve(address: address, knownName: knownName, attempt: 0, delays: [1.5, 3.0, 5.0]) { [weak self] info, battery in
            let name = knownName ?? info?.name ?? IOBluetoothDevice(addressString: address)?.nameOrAddress ?? "Bluetooth device"
            let lowered = name.lowercased()
            if ["iphone", "ipad", "macbook", "imac"].contains(where: lowered.contains) { return }
            // What the device is called by its maker, so AirPods named "Slatt" still get the AirPods icon.
            let model = DeviceSymbols.appleAudioName(vendorID: info?.vendorID, productID: info?.productID, hasCase: info?.hasCase ?? false)
            let symbolName = model ?? name
            let symbol = DeviceSymbols.firstAvailable(name: symbolName, kind: kind)
            Log.write("bluetooth: connected \(name) model \(model ?? "-") vendor \(info?.vendorID.map { String($0, radix: 16) } ?? "-")")
            let item = PopupItem(id: "bt-\(BluetoothProfilerParser.normalize(address: address.isEmpty ? name : address))", kind: .bluetoothDevice,
                                 symbol: symbol, title: name, subtitle: battery == nil ? (model ?? "Connected") : "",
                                 batteries: battery?.readings ?? [])
            self?.onPopup?(item)
        }
    }

    private func resolve(address: String, knownName: String?, attempt: Int, delays: [Double],
                         _ done: @escaping @MainActor (BluetoothProfilerParser.DeviceInfo?, DeviceBattery?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            self?.profile(address: address) { info, battery, all in
                guard let self else { return }
                var info = info, battery = battery
                // No usable address (or not listed under it): the one device that is connected now and was not before.
                if info == nil {
                    let fresh = all.filter { $0.value.connected && !self.seenConnected.contains($0.key) }
                    if fresh.count == 1, let match = fresh.first {
                        info = match.value
                        battery = match.value.battery
                    }
                }
                if (info?.connected == true) || attempt + 1 >= delays.count {
                    if let key = info.flatMap({ i in all.first(where: { $0.value == i })?.key }) { self.seenConnected.insert(key) }
                    done(info, battery)
                } else {
                    self.resolve(address: address, knownName: knownName, attempt: attempt + 1, delays: delays, done)
                }
            }
        }
    }

    private func profile(address: String, _ done: @escaping @MainActor (BluetoothProfilerParser.DeviceInfo?, DeviceBattery?, [String: BluetoothProfilerParser.DeviceInfo]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var info: BluetoothProfilerParser.DeviceInfo?
            var battery: DeviceBattery?
            var all: [String: BluetoothProfilerParser.DeviceInfo] = [:]
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let key = BluetoothProfilerParser.normalize(address: address)
                all = BluetoothProfilerParser.devices(data)
                info = all[key]
                battery = BluetoothProfilerParser.parse(data).byAddress[key]
            } catch {
                Log.write("system_profiler failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(info, battery, all) } }
        }
    }
}

extension DeviceSymbols {
    /// First candidate this macOS actually has an SF Symbol for.
    static func firstAvailable(name: String, kind: DeviceKind) -> String {
        for c in candidates(name: name, kind: kind) where NSImage(systemSymbolName: c, accessibilityDescription: nil) != nil { return c }
        return "headphones"
    }
}
