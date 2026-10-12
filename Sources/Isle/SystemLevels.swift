import AppKit
import CoreAudio

/// Reads and writes the default output device's volume and the built-in display's brightness.
/// Every call reports failure instead of guessing, so the HUD never swallows a key it cannot act on.
enum SystemLevels {
    // MARK: Volume (CoreAudio, public API)

    private static func outputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: AudioObjectPropertySelector(0x766D7663),   // 'vmvc': virtual main volume
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    static func volume() -> Double? {
        guard let dev = outputDevice() else { return nil }
        var addr = volumeAddress
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return Double(v)
    }

    @discardableResult
    static func setVolume(_ level: Double) -> Bool {
        guard let dev = outputDevice() else { return false }
        var addr = volumeAddress
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(dev, &addr), AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return false }
        var v = Float32(min(1, max(0, level)))
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    static func isMuted() -> Bool {
        guard let dev = outputDevice() else { return false }
        var addr = muteAddress
        guard AudioObjectHasProperty(dev, &addr) else { return false }
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr && m != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let dev = outputDevice() else { return false }
        var addr = muteAddress
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(dev, &addr), AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return false }
        var m = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) == noErr
    }

    // MARK: Brightness (private DisplayServices, loaded at run time; absent symbols just disable the feature)

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn: GetFn? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }

    static var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return nil }
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var brightnessAvailable: Bool { getFn != nil && setFn != nil && builtInDisplay != nil }

    static func brightness() -> Double? {
        guard let get = getFn, let id = builtInDisplay else { return nil }
        var v = Float(0)
        return get(id, &v) == 0 ? Double(v) : nil
    }

    @discardableResult
    static func setBrightness(_ level: Double) -> Bool {
        guard let set = setFn, let id = builtInDisplay else { return false }
        return set(id, Float(min(1, max(0, level)))) == 0
    }

    // MARK: Keyboard backlight (private CoreBrightness KeyboardBrightnessClient, found at run time)

    private static let keyboardClient: NSObject? = {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        return (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
    }()

    private static var keyboardID: UInt64 {
        let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard let c = keyboardClient, c.responds(to: sel),
              let ids = c.perform(sel)?.takeRetainedValue() as? [NSNumber], let first = ids.first else { return 1 }
        return first.uint64Value
    }

    static var keyboardBacklightAvailable: Bool {
        guard let c = keyboardClient else { return false }
        return c.responds(to: NSSelectorFromString("brightnessForKeyboard:")) && c.responds(to: NSSelectorFromString("setBrightness:forKeyboard:"))
    }

    static func keyboardBacklight() -> Double? {
        guard keyboardBacklightAvailable, let c = keyboardClient else { return nil }
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        typealias Fn = @convention(c) (AnyObject, Selector, UInt64) -> Float
        return Double(unsafeBitCast(c.method(for: sel), to: Fn.self)(c, sel, keyboardID))
    }

    @discardableResult
    static func setKeyboardBacklight(_ level: Double) -> Bool {
        guard keyboardBacklightAvailable, let c = keyboardClient else { return false }
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        typealias Fn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        return unsafeBitCast(c.method(for: sel), to: Fn.self)(c, sel, Float(min(1, max(0, level))), keyboardID)
    }

    // MARK: Microphone input level (CoreAudio, public API)

    private static func inputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// The first element (main, then channel 1) that carries an input volume.
    private static func inputVolumeAddress(_ dev: AudioDeviceID) -> AudioObjectPropertyAddress? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput, mElement: element)
            if AudioObjectHasProperty(dev, &addr) { return addr }
        }
        return nil
    }

    static func inputVolume() -> Double? {
        guard let dev = inputDevice(), var addr = inputVolumeAddress(dev) else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? Double(v) : nil
    }

    /// Calls `onChange` (on the main queue) when the default input device's volume changes. Returns a cancel closure.
    static func observeInputVolume(_ onChange: @escaping () -> Void) -> () -> Void {
        guard let dev = inputDevice(), var addr = inputVolumeAddress(dev) else { return {} }
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(dev, &addr, .main, block)
        return { var a = addr; AudioObjectRemovePropertyListenerBlock(dev, &a, .main, block) }
    }
}
