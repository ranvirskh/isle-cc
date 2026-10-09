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
        let name = device.name ?? "Bluetooth device"
        let address = device.addressString ?? name
        let kind = DeviceSymbols.kind(majorClass: Int(device.deviceClassMajor), minorClass: Int(device.deviceClassMinor))
        // Battery levels show up in the profiler a moment after the connection is made.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.fetchBattery(address: address, name: name) { battery in
                let symbol = DeviceSymbols.firstAvailable(name: name, kind: kind)
                let item = PopupItem(id: "bt-\(BluetoothProfilerParser.normalize(address: address))", kind: .bluetoothDevice,
                                     symbol: symbol, title: name, subtitle: battery == nil ? "Connected" : "",
                                     batteries: battery?.readings ?? [])
                self?.onPopup?(item)
            }
        }
    }

    private func fetchBattery(address: String, name: String, _ done: @escaping @MainActor (DeviceBattery?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var result: DeviceBattery?
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let parsed = BluetoothProfilerParser.parse(data)
                result = parsed.byAddress[BluetoothProfilerParser.normalize(address: address)] ?? parsed.byName[name]
            } catch {
                Log.write("system_profiler failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
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
