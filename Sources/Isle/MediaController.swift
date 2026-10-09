import AppKit
import Combine
import CoreAudio
import IsleCore

/// Owns what is playing: the source (system helper, Spotify or Music), the artwork, and the lyrics state.
@MainActor
final class MediaController: ObservableObject {
    @Published private(set) var now: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var lyrics: LyricsService.Snapshot?
    @Published private(set) var automationDenied = false
    @Published private(set) var systemUnsupportedReason: String?
    @Published private(set) var output: OutputDevice = OutputDevice.current()

    /// Fires when the track identity changes (nil = nothing playing) or play/pause flips.
    var onTrackChanged: ((String?) -> Void)?
    var onPlaybackChanged: ((Bool) -> Void)?

    private let settings = Settings.shared
    private let helper = SystemNowPlayingHelper()
    private var scripting: PlayerScripting?
    private var artworkCache: (id: String, image: NSImage)?
    private var helperArtwork: (bundle: String, image: NSImage)?
    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastIdentity: String?
    private var lastPlaying = false
    private let lyricsService: LyricsService
    private var demoMode = false
    /// Cover art remembered per track, so a track that comes back (or a re-open) shows its cover instantly.
    private var artworkByTrack: [String: NSImage] = [:]
    private var artworkOrder: [String] = []
    private let launchedAt = Date()
    /// Fires when a new song starts while something was already running; drives the song-change banner.
    var onSongStarted: ((TrackInfo) -> Void)?
    private var iconCache: [String: NSImage] = [:]

    private func remember(_ image: NSImage, for identity: String) {
        if artworkByTrack[identity] == nil { artworkOrder.append(identity) }
        artworkByTrack[identity] = image
        if artworkOrder.count > 30 { artworkByTrack[artworkOrder.removeFirst()] = nil }
        if now?.track.identity == identity || identity == pendingIdentity { artwork = image }
    }
    private var pendingIdentity: String?

    init() {
        let contact = settings.lyricsContact
        let provider = LRCLIBProvider(transport: URLSessionTransport(), userAgent: IsleInfo.lyricsUserAgent(contact: contact))
        let cacheDir = Paths.support.appendingPathComponent("Lyrics", isDirectory: true)
        let settings = Settings.shared
        lyricsService = LyricsService(resolver: LyricsResolver(providers: [provider]),
                                      cache: LyricsCache(directory: cacheDir),
                                      isEnabled: { settings.lyricsEnabled })
        lyricsService.onChange = { [weak self] snap in
            Task { @MainActor in self?.lyrics = snap }
        }
        helper.onSnapshot = { [weak self] snap in self?.handleSystem(snap) }
        helper.onUnsupported = { [weak self] reason in
            Log.write("system now playing unsupported: \(reason)")
            self?.systemUnsupportedReason = reason
        }
    }

    func start() {
        helper.start()
        applySourceSetting()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let key = note.object as? String else { return }
                if key == SettingsKey.mediaSource { self.applySourceSetting() }
                if key == SettingsKey.lyricsEnabled { self.lyricsEnabledChanged() }
            }
        })
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init(SpotifyParser.notificationName), object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo
            MainActor.assumeIsolated { self?.handleNotification(bundle: KnownBundle.spotify, snapshot: SpotifyParser.parse(userInfo: info)) }
        })
        observers.append(dnc.addObserver(forName: .init(AppleMusicParser.notificationName), object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo
            MainActor.assumeIsolated { self?.handleNotification(bundle: KnownBundle.appleMusic, snapshot: AppleMusicParser.parse(userInfo: info)) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let id, id == self.scripting?.bundleID else { return }
                self.setNow(nil)
            }
        })
        OutputDevice.observe { [weak self] in self?.output = OutputDevice.current() }
    }

    func stop() {
        helper.stop()
        pollTimer?.invalidate()
    }

    // MARK: Source selection

    private var mode: MediaSourceSetting { settings.mediaSource }

    private func applySourceSetting() {
        pollTimer?.invalidate()
        pollTimer = nil
        switch mode {
        case .system:
            scripting = nil
            setNow(nil)
            helper.send("poll")
        case .spotify:
            scripting = PlayerScripting(bundleID: KnownBundle.spotify)
            setNow(nil)
            refreshFromScript()
        case .appleMusic:
            scripting = PlayerScripting(bundleID: KnownBundle.appleMusic)
            setNow(nil)
            refreshFromScript()
        }
    }

    private func lyricsEnabledChanged() {
        if settings.lyricsEnabled { lyricsService.trackChanged(now?.track) } else { lyricsService.disable() }
    }

    // MARK: System helper

    private func handleSystem(_ snap: SystemNowPlayingSnapshot) {
        guard !demoMode else { return }
        systemUnsupportedReason = nil
        // Artwork from the helper is kept per app, so Spotify mode can use it without a network fetch.
        if let b64 = snap.artworkBase64, let data = Data(base64Encoded: b64), let image = NSImage(data: data) {
            let bundle = snap.track?.bundleID ?? ""
            helperArtwork = (bundle, image)
            if let id = snap.track?.identity, mode == .system || bundle == scripting?.bundleID {
                pendingIdentity = id
                remember(image, for: id)
            }
        }
        guard mode == .system else {
            if let spotify = scripting, spotify.bundleID == KnownBundle.spotify, snap.track?.bundleID == spotify.bundleID,
               let img = helperArtwork?.image { artwork = img }
            return
        }
        guard let track = snap.track else { setNow(nil); return }
        let ts = snap.elapsedTimestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
        let hasPosition = snap.elapsed != nil
        let clock = PlaybackClock(isPlaying: snap.isPlaying, position: snap.elapsed ?? 0, sampledAt: ts, rate: snap.rate ?? 1)
        var caps: Set<MediaCapability> = [.playPause, .next, .previous]
        if hasPosition, track.duration != nil { caps.insert(.seek) }
        setNow(NowPlaying(track: track, clock: clock, shuffle: nil, capabilities: caps), artworkID: snap.artworkID)
    }

    // MARK: Spotify / Music

    private func handleNotification(bundle: String, snapshot: PlayerSnapshot?) {
        guard mode != .system, scripting?.bundleID == bundle, let snapshot else { return }
        apply(snapshot, bundle: bundle)
        // Notifications lack position (Music) and artwork; ask once.
        refreshFromScript()
    }

    private func refreshFromScript() {
        guard let scripting else { return }
        scripting.query { [weak self] result in
            guard let self, self.scripting === scripting else { return }
            switch result {
            case .snapshot(let snap):
                self.automationDenied = false
                self.apply(snap, bundle: scripting.bundleID)
            case .notRunning:
                self.automationDenied = false
                self.setNow(nil)
            case .denied:
                self.automationDenied = true
                self.setNow(nil)
            case .failed: break
            }
        }
    }

    private func apply(_ snap: PlayerSnapshot, bundle: String) {
        guard snap.state != .stopped, let track = snap.track else { setNow(nil); return }
        let prior = now
        var position = snap.position
        if position == nil, let prior, prior.track.identity == track.identity {
            position = prior.clock.position(at: Date(), duration: prior.track.duration)
        }
        let clock = PlaybackClock(isPlaying: snap.state == .playing, position: position ?? 0, sampledAt: Date())
        var caps: Set<MediaCapability> = [.playPause, .next, .previous, .shuffle]
        if track.duration != nil { caps.insert(.seek) }
        let artID = "\(bundle)|\(track.identity)"
        setNow(NowPlaying(track: track, clock: clock, shuffle: snap.shuffle, capabilities: caps), artworkID: artID)
        if bundle == KnownBundle.appleMusic, artworkCache?.id != artID {
            scripting?.artworkData { [weak self] data in
                guard let self, self.now?.track.identity == track.identity, let data, let img = NSImage(data: data) else { return }
                self.artworkCache = (artID, img)
                self.remember(img, for: track.identity)
            }
        } else if bundle == KnownBundle.spotify, let img = helperArtwork?.image, helperArtwork?.bundle == bundle, artworkByTrack[track.identity] == nil {
            remember(img, for: track.identity)
        }
    }

    // MARK: Publishing

    private func setNow(_ new: NowPlaying?, artworkID: String? = nil) {
        let oldIdentity = now?.track.identity
        let newIdentity = new?.track.identity
        if new != now { now = new }
        if newIdentity != oldIdentity {
            artwork = newIdentity.flatMap { artworkByTrack[$0] }
            if artwork == nil, newIdentity != nil, mode == .system || scripting?.bundleID == KnownBundle.spotify {
                // The cover normally arrives with the track; if it has not shortly after, ask the helper to resend it.
                let wanted = newIdentity
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.now?.track.identity == wanted, self.artwork == nil else { return }
                        self.helper.send("artwork")
                    }
                }
            }
            pendingIdentity = nil
            lyricsService.trackChanged(new?.track)
            if let new, new.isPlaying, oldIdentity != nil || Date().timeIntervalSince(launchedAt) > 8, !demoMode {
                onSongStarted?(new.track)
            }
        } else if let new {
            lyricsService.refreshIfUnresolved(new.track)
        }
        if lastIdentity != newIdentity {
            lastIdentity = newIdentity
            onTrackChanged?(newIdentity)
        }
        let playing = new?.isPlaying ?? false
        if lastPlaying != playing {
            lastPlaying = playing
            onPlaybackChanged?(playing)
        }
        updatePolling()
    }

    /// Light polling only while a Spotify / Music track is playing, to resync the position. Nothing in System mode:
    /// the helper is event driven.
    private func updatePolling() {
        let need = scripting != nil && (now?.isPlaying ?? false)
        if need, pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFromScript() }
            }
            pollTimer?.tolerance = 1
        } else if !need {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: Position and lyrics

    func position(at date: Date = Date()) -> Double {
        guard let now else { return 0 }
        return now.clock.position(at: date, duration: now.track.duration)
    }

    /// Lyric line shown for the current playback position (timed lyrics only).
    func currentLyric(at date: Date = Date()) -> (current: LyricLine?, next: LyricLine?) {
        guard let snap = lyrics, snap.trackIdentity == now?.track.identity, case .timed(let timeline) = snap.state else { return (nil, nil) }
        let p = position(at: date)
        let display = LyricsPresentation.displayLines(timeline.lines)
        let t = LyricTimeline(lines: display)
        let cur = t.line(at: p)
        guard let cur, !cur.text.isEmpty, !cur.isInstrumentalMarker else { return (nil, t.nextLine(after: p)) }
        return (cur, t.nextLine(after: p))
    }

    // MARK: Controls

    func togglePlayPause() {
        if mode == .system { helper.send("toggle") } else { scripting?.perform(.playPause) }
        optimisticToggle()
        scheduleRefresh()
    }
    func next() { if mode == .system { helper.send("next") } else { scripting?.perform(.next) }; scheduleRefresh() }
    func previous() { if mode == .system { helper.send("previous") } else { scripting?.perform(.previous) }; scheduleRefresh() }
    func toggleShuffle() {
        guard mode != .system else { return }
        scripting?.perform(.shuffleToggle)
        if var n = now { n.shuffle = !(n.shuffle ?? false); now = n }
        scheduleRefresh()
    }
    func seek(to seconds: Double) {
        guard var n = now else { return }
        if mode == .system { helper.send("seek \(seconds)") } else { scripting?.perform(.seek(seconds)) }
        n.clock = PlaybackClock(isPlaying: n.clock.isPlaying, position: seconds, sampledAt: Date(), rate: n.clock.rate)
        now = n
        scheduleRefresh()
    }

    private func optimisticToggle() {
        guard var n = now else { return }
        let pos = n.clock.position(at: Date(), duration: n.track.duration)
        n.clock = PlaybackClock(isPlaying: !n.clock.isPlaying, position: pos, sampledAt: Date(), rate: n.clock.rate)
        now = n
        let playing = n.isPlaying
        if lastPlaying != playing { lastPlaying = playing; onPlaybackChanged?(playing) }
        updatePolling()
    }

    private func scheduleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.mode == .system { self.helper.send("poll") } else { self.refreshFromScript() }
            }
        }
    }

    func openSourceApp() {
        let id = now?.track.bundleID ?? (mode == .spotify ? KnownBundle.spotify : mode == .appleMusic ? KnownBundle.appleMusic : nil)
        guard let id, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func sourceAppIcon() -> NSImage? {
        guard let id = now?.track.bundleID else { return nil }
        if let cached = iconCache[id] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[id] = icon
        return icon
    }

    /// `--demo`: fixed fake playback so the UI can be inspected without a player. Never used otherwise.
    func loadDemo() {
        demoMode = true
        let track = TrackInfo(title: "Neon Harbor", artist: "The Lanterns", album: "Night Shift", duration: 243, isExplicit: true,
                              bundleID: "com.apple.Music")
        now = NowPlaying(track: track, clock: PlaybackClock(isPlaying: true, position: 61, sampledAt: Date()),
                         shuffle: true, capabilities: [.playPause, .next, .previous, .seek, .shuffle])
        let size = NSSize(width: 240, height: 240)
        artwork = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor.systemPink, NSColor.systemIndigo, NSColor.black])?.draw(in: rect, angle: 315)
            return true
        }
        let lines = [LyricLine(time: 0, text: "(intro)"), LyricLine(time: 58, text: "Streetlights hum along the water"),
                     LyricLine(time: 64, text: "Every window is a slow goodbye that goes on and on and on"),
                     LyricLine(time: 72, text: "We keep driving until morning")]
        lyrics = LyricsService.Snapshot(trackIdentity: track.identity, state: .timed(LyricTimeline(lines: lines)), payload: nil)
        onTrackChanged?(track.identity)
        onPlaybackChanged?(true)
    }

    func clearLyricsCache() { LyricsCache(directory: Paths.support.appendingPathComponent("Lyrics", isDirectory: true)).clear() }
}

struct URLSessionTransport: HTTPTransport {
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        var h: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] { if let k = k as? String, let v = v as? String { h[k] = v } }
        return HTTPResponse(status: http?.statusCode ?? 0, headers: h, body: data)
    }
}

/// Current audio output, for the output indicator on the Home tab.
struct OutputDevice: Equatable {
    var name: String
    var symbol: String

    static func current() -> OutputDevice {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else {
            return OutputDevice(name: "Speakers", symbol: "speaker.wave.2.fill")
        }
        var nameRef: Unmanaged<CFString>?
        var nsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var naddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var name = "Output"
        if AudioObjectGetPropertyData(id, &naddr, 0, nil, &nsize, &nameRef) == noErr, let ref = nameRef { name = ref.takeRetainedValue() as String }
        var transport: UInt32 = 0
        var tsize = UInt32(MemoryLayout<UInt32>.size)
        var taddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &transport)
        let symbol: String
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
            symbol = DeviceSymbols.primary(name: name, kind: .headphones)
        } else if transport == kAudioDeviceTransportTypeAirPlay {
            symbol = "airplayaudio"
        } else if transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort {
            symbol = "display"
        } else if transport == kAudioDeviceTransportTypeBuiltIn, name.lowercased().contains("headphone") {
            symbol = "headphones"
        } else {
            symbol = "speaker.wave.2.fill"
        }
        return OutputDevice(name: name, symbol: symbol)
    }

    private static var handler: (() -> Void)?
    static func observe(_ change: @escaping () -> Void) {
        handler = change
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { _, _ in handler?() }
    }
}
