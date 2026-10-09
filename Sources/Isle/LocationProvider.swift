import CoreLocation
import IsleCore

/// This Mac's location for the weather. Asks once per refresh (a single fix, never continuous tracking) and keeps the
/// last known place, so the weather still works with no fix, offline, or after the permission is turned off.
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var place: WeatherPlace?
    @Published private(set) var status: CLAuthorizationStatus
    var onChange: (() -> Void)?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let d = UserDefaults.standard

    override init() {
        status = CLLocationManager().authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer   // city-level is plenty, and cheaper
        if d.object(forKey: SettingsKey.weatherLastLat) != nil {
            place = WeatherPlace(name: d.string(forKey: SettingsKey.weatherLastName) ?? "Current location",
                                 latitude: d.double(forKey: SettingsKey.weatherLastLat), longitude: d.double(forKey: SettingsKey.weatherLastLon))
        }
    }

    var isDenied: Bool { status == .denied || status == .restricted }

    /// Ask for a fix (and for permission the first time).
    func request() {
        status = manager.authorizationStatus
        switch status {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: break
        default: manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.status = manager.authorizationStatus
            if !self.isDenied, self.status != .notDetermined { manager.requestLocation() }
            self.onChange?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
            // Name the place with Apple's geocoder; if that fails the coordinates still work.
            var name = self.place?.name ?? "Current location"
            if let mark = try? await self.geocoder.reverseGeocodeLocation(loc).first {
                name = mark.locality ?? mark.administrativeArea ?? name
            }
            let region = self.place?.region
            self.place = WeatherPlace(name: name, region: region, latitude: lat, longitude: lon)
            self.d.set(lat, forKey: SettingsKey.weatherLastLat)
            self.d.set(lon, forKey: SettingsKey.weatherLastLon)
            self.d.set(name, forKey: SettingsKey.weatherLastName)
            self.onChange?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.write("location: \(error.localizedDescription)")   // keep using the last known place
    }
}
