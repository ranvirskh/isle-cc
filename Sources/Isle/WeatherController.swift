import AppKit
import IsleCore

@MainActor
final class WeatherController: ObservableObject {
    @Published private(set) var reading: WeatherReading?
    /// Shown in Settings when a city could not be found.
    @Published private(set) var problem: String?

    private let settings = Settings.shared
    private let service: WeatherService
    let location = LocationProvider()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var debounce: DispatchWorkItem?

    init() {
        let s = Settings.shared
        service = WeatherService(transport: URLSessionTransport(), userAgent: IsleInfo.lyricsUserAgent(contact: s.lyricsContact))
        service.isEnabled = { Settings.shared.weatherEnabled }
        service.city = { Settings.shared.weatherCity }
        service.unit = { Settings.shared.weatherUnit }
        let location = self.location
        service.directPlace = { Settings.shared.weatherUseLocation ? location.place : nil }
        location.onChange = { [weak self] in self?.scheduleRefresh(force: true) }
    }

    func start() {
        observers.append(NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let key = n.object as? String,
                      [SettingsKey.weatherEnabled, SettingsKey.weatherCity, SettingsKey.weatherUnit, SettingsKey.weatherUseLocation].contains(key) else { return }
                self?.scheduleRefresh(force: true)
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh(force: false) }
        })
        scheduleRefresh(force: false)
    }

    /// Typing a city must not send a request per keystroke.
    func scheduleRefresh(force: Bool) {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh(force: force) } }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (force ? 0.8 : 0.1), execute: w)
    }

    private func refresh(force: Bool) {
        timer?.invalidate()
        timer = nil
        if settings.weatherEnabled, settings.weatherUseLocation { location.request() }
        let hasSource = settings.weatherUseLocation ? location.place != nil : !settings.weatherCity.trimmingCharacters(in: .whitespaces).isEmpty
        guard settings.weatherEnabled, hasSource else {
            service.reset()
            reading = nil
            problem = nil
            return
        }
        let service = self.service
        Task { @MainActor [weak self] in
            let r = await service.refresh(force: force)
            guard let self else { return }
            self.reading = r
            self.problem = r == nil ? (self.settings.weatherUseLocation ? (self.location.isDenied ? "Location access is off for Isle. Turn it on in System Settings > Privacy & Security > Location Services, or type a city instead." : "Waiting for your location, or the weather service is unreachable.") : "Could not find that city, or the weather service is unreachable.") : nil
            // One wake-up for the next due refresh; nothing runs in between.
            if self.settings.weatherEnabled {
                let t = Timer.scheduledTimer(withTimeInterval: r == nil ? service.retryInterval : service.refreshInterval, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh(force: false) }
                }
                t.tolerance = 30
                self.timer = t
            }
        }
    }
}
