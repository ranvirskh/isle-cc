import Foundation

// ALL private-API use in Isle's lock screen feature lives in this file.
//
// Third-party windows cannot normally appear above the lock screen. The window server does, however, let a
// process create its own window "space" at an absolute level above the lock screen and move a window into it.
// Those functions are in the private SkyLight framework. They are resolved at runtime with dlopen/dlsym and
// never linked, so if a symbol is missing or renamed the feature turns itself off instead of crashing.

/// Moves a window above the lock screen. The no-op implementation is the fallback everywhere this is unsupported.
public protocol LockWindowElevator: AnyObject {
    /// False when the mechanism is unavailable on this macOS version. The Settings toggle is disabled then.
    var isSupported: Bool { get }
    /// Human-readable reason when `isSupported` is false.
    var unsupportedReason: String? { get }
    /// Puts the window with this window number above the lock screen. Returns false on failure.
    func elevate(windowNumber: Int) -> Bool
    /// Tears down everything `elevate` created.
    func release()
}

public final class NoOpLockWindowElevator: LockWindowElevator {
    public let unsupportedReason: String?
    public init(reason: String? = "Not supported on this macOS version") {
        unsupportedReason = reason
    }
    public var isSupported: Bool { false }
    public func elevate(windowNumber: Int) -> Bool { false }
    public func release() {}
}

public final class SkyLightLockWindowElevator: LockWindowElevator {
    public typealias SymbolLookup = (String) -> UnsafeMutableRawPointer?

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetLevelFn = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpacesArrayFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindowsFn = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias SpaceDestroyFn = @convention(c) (Int32, Int32) -> Int32

    static let requiredSymbols = [
        "SLSMainConnectionID", "SLSSpaceCreate", "SLSSpaceSetAbsoluteLevel", "SLSShowSpaces",
        "SLSSpaceAddWindowsAndRemoveFromSpaces",
    ]
    /// Above the lock screen's own space, below nothing we care about.
    private static let lockScreenSpaceLevel: Int32 = 400

    private var mainConnection: MainConnectionFn?
    private var spaceCreate: SpaceCreateFn?
    private var spaceSetLevel: SpaceSetLevelFn?
    private var showSpaces: SpacesArrayFn?
    private var hideSpaces: SpacesArrayFn?
    private var addWindows: SpaceAddWindowsFn?
    private var destroySpace: SpaceDestroyFn?

    public private(set) var unsupportedReason: String?
    private var space: Int32 = 0

    /// Default lookup: dlopen SkyLight once, then dlsym.
    public static func systemLookup() -> SymbolLookup {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        return { name in
            guard let handle else { return nil }
            return dlsym(handle, name)
        }
    }

    /// `lookup` is injectable so tests can simulate a missing symbol.
    public init(lookup: SymbolLookup = SkyLightLockWindowElevator.systemLookup()) {
        var resolved: [String: UnsafeMutableRawPointer] = [:]
        for name in Self.requiredSymbols {
            guard let pointer = lookup(name) else {
                unsupportedReason = "Not supported on this macOS version (missing \(name))"
                return
            }
            resolved[name] = pointer
        }
        func cast<T>(_ name: String, _ type: T.Type) -> T? {
            resolved[name].map { unsafeBitCast($0, to: type) }
        }
        mainConnection = cast("SLSMainConnectionID", MainConnectionFn.self)
        spaceCreate = cast("SLSSpaceCreate", SpaceCreateFn.self)
        spaceSetLevel = cast("SLSSpaceSetAbsoluteLevel", SpaceSetLevelFn.self)
        showSpaces = cast("SLSShowSpaces", SpacesArrayFn.self)
        addWindows = cast("SLSSpaceAddWindowsAndRemoveFromSpaces", SpaceAddWindowsFn.self)
        // Optional: without these the space simply lives until the app quits.
        hideSpaces = lookup("SLSHideSpaces").map { unsafeBitCast($0, to: SpacesArrayFn.self) }
        destroySpace = lookup("SLSSpaceDestroy").map { unsafeBitCast($0, to: SpaceDestroyFn.self) }
    }

    public var isSupported: Bool {
        mainConnection != nil && spaceCreate != nil && spaceSetLevel != nil && showSpaces != nil && addWindows != nil
    }

    public func elevate(windowNumber: Int) -> Bool {
        guard isSupported, windowNumber > 0,
              let mainConnection, let spaceCreate, let spaceSetLevel, let showSpaces, let addWindows else { return false }
        let connection = mainConnection()
        guard connection != 0 else { return false }
        if space == 0 {
            let created = spaceCreate(connection, 1, 0)
            guard created != 0 else { return false }
            space = created
            _ = spaceSetLevel(connection, space, Self.lockScreenSpaceLevel)
            _ = showSpaces(connection, [NSNumber(value: space)] as CFArray)
        }
        _ = addWindows(connection, space, [NSNumber(value: Int32(truncatingIfNeeded: windowNumber))] as CFArray, 7)
        return true
    }

    public func release() {
        guard space != 0, let mainConnection else { return }
        let connection = mainConnection()
        if let hideSpaces { _ = hideSpaces(connection, [NSNumber(value: space)] as CFArray) }
        if let destroySpace { _ = destroySpace(connection, space) }
        space = 0
    }
}
