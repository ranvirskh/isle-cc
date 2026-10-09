import AppKit
import CoreAudio
import CoreMediaIO
import IsleCore

/// Watches whether the microphone, a camera or a screen recording is active. Mic and camera are event driven
/// (system property listeners); the screen check is a cheap window-list look every 2 s. Reads state only:
/// never audio, video or screen content, and it needs no permission.
@MainActor
final class PrivacyMonitor: ObservableObject {
    @Published private(set) var state = PrivacyState()

    private var micRunning = false
    private var camRunning = false
    private var screenTimer: Timer?
    private var micDevices: [AudioObjectID] = []
    private var camDevices: [CMIOObjectID] = []
    private let queue = DispatchQueue(label: "isle.privacy")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        registerAudio()
        registerCamera()
        Log.write("privacy: watching \(micDevices.count) input devices, \(camDevices.count) camera devices")
        refresh()
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 0.5
        screenTimer = t
    }

    func stop() {
        screenTimer?.invalidate()
        screenTimer = nil
        started = false
        if state != PrivacyState() { state = PrivacyState() }
    }

    // MARK: Evaluation

    private func refresh() {
        micRunning = micDevices.contains { Self.audioRunning($0) }
        camRunning = camDevices.contains { Self.cameraRunning($0) }
        let indicators = Self.statusIndicatorWindowCount()
        let new = PrivacyState(microphone: micRunning, camera: camRunning,
                               screen: ScreenRecordingDetector.isRecording(statusIndicatorWindows: indicators, microphone: micRunning, camera: camRunning))
        if new != state { state = new }
    }

    private static func statusIndicatorWindowCount() -> Int {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.reduce(0) { $0 + (($1[kCGWindowName as String] as? String) == "StatusIndicator" ? 1 : 0) }
    }

    // MARK: Microphone (CoreAudio)

    private static func audioRunning(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    private func registerAudio() {
        func inputDevices() -> [AudioObjectID] {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
            var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
            return ids.filter { id in
                var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                   mElement: kAudioObjectPropertyElementMain)
                var s: UInt32 = 0
                return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s) == noErr && s > 0
            }
        }
        func attach() {
            micDevices = inputDevices()
            for id in micDevices {
                var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
        }
        attach()
        var listAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listAddr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                // Devices appeared or went away: re-read the list. Duplicate listeners on old ids are harmless.
                self?.micDevices = inputDevices()
                for id in self?.micDevices ?? [] {
                    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                    AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.refresh() }
                    }
                }
                self?.refresh()
            }
        }
    }

    // MARK: Camera (CoreMediaIO)

    private static func cameraRunning(_ id: CMIOObjectID) -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &used, &value) == noErr && value != 0
    }

    private func registerCamera() {
        func devices() -> [CMIOObjectID] {
            var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                 mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                 mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var size: UInt32 = 0
            guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
            var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
            var used: UInt32 = 0
            guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
            return ids
        }
        camDevices = devices()
        for id in camDevices {
            var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                 mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                 mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            CMIOObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }
}
