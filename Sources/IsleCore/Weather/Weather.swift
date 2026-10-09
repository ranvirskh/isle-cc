import Foundation

public enum TemperatureUnit: String, Codable, CaseIterable {
    case celsius, fahrenheit

    public var apiValue: String { rawValue }
    public var symbol: String { self == .celsius ? "°C" : "°F" }

    /// Fahrenheit for the US locale, Celsius elsewhere.
    public static func localeDefault(_ locale: Locale = .current) -> TemperatureUnit {
        locale.measurementSystem == .us ? .fahrenheit : .celsius
    }
}

public struct WeatherPlace: Equatable, Codable {
    public var name: String
    public var region: String?
    public var latitude: Double
    public var longitude: Double

    public init(name: String, region: String? = nil, latitude: Double, longitude: Double) {
        self.name = name
        self.region = region
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct WeatherReading: Equatable, Codable {
    public var place: WeatherPlace
    public var temperature: Double
    public var high: Double?
    public var low: Double?
    public var code: Int
    public var isDay: Bool
    public var unit: TemperatureUnit
    public var fetchedAt: Date

    public init(place: WeatherPlace, temperature: Double, high: Double?, low: Double?, code: Int, isDay: Bool,
                unit: TemperatureUnit, fetchedAt: Date) {
        self.place = place
        self.temperature = temperature
        self.high = high
        self.low = low
        self.code = code
        self.isDay = isDay
        self.unit = unit
        self.fetchedAt = fetchedAt
    }

    public var temperatureText: String { "\(Int(temperature.rounded()))°" }
    public var symbol: String { WeatherCondition.symbol(code: code, isDay: isDay) }
    public var summary: String { WeatherCondition.text(code: code) }
}

/// WMO weather interpretation codes, as used by Open-Meteo.
public enum WeatherCondition {
    public static func text(code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81, 82: return "Showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Unknown"
        }
    }

    public static func symbol(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1: return isDay ? "sun.max.fill" : "moon.fill"
        case 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 80, 81: return "cloud.rain.fill"
        case 65, 82, 66, 67: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

public enum OpenMeteoParser {
    private static func double(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// First result of a geocoding response; nil when there is none or the JSON is not what we expect.
    public static func parseGeocoding(_ data: Data) -> WeatherPlace? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]], let first = results.first,
              let name = first["name"] as? String, !name.isEmpty,
              let lat = double(first["latitude"]), let lon = double(first["longitude"]),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        let region = (first["admin1"] as? String) ?? (first["country"] as? String)
        return WeatherPlace(name: name, region: region, latitude: lat, longitude: lon)
    }

    public static func parseForecast(_ data: Data, place: WeatherPlace, unit: TemperatureUnit, now: Date) -> WeatherReading? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let temp = double(current["temperature_2m"]), let code = double(current["weather_code"]) else { return nil }
        let isDay = (double(current["is_day"]) ?? 1) != 0
        let daily = root["daily"] as? [String: Any]
        let high = (daily?["temperature_2m_max"] as? [Any])?.first.flatMap(double)
        let low = (daily?["temperature_2m_min"] as? [Any])?.first.flatMap(double)
        return WeatherReading(place: place, temperature: temp, high: high, low: low, code: Int(code), isDay: isDay, unit: unit, fetchedAt: now)
    }
}

/// Weather from Open-Meteo (open-meteo.com, free for non-commercial use, no key, CC-BY 4.0 attribution).
/// Sends only the city name you typed (once, to find coordinates) and those coordinates (to get the forecast).
public final class WeatherService: @unchecked Sendable {
    public static let attribution = "Weather data by Open-Meteo.com"
    public static let disclosure =
        "When on, Isle sends coordinates to Open-Meteo's forecast service about every 30 minutes: your Mac's location (macOS "
        + "asks permission once; Apple's service names the city) or, if you type a city instead, that city name to Open-Meteo's "
        + "geocoding service first. No account and no key. The last known place is kept as a fallback. Nothing is sent while this is off."

    private let transport: HTTPTransport
    private let userAgent: String
    private let geocodingBase: String
    private let forecastBase: String
    private let lock = NSLock()
    private var cachedPlace: (query: String, place: WeatherPlace)?
    private var last: WeatherReading?
    private var lastAttempt: Date?

    public var refreshInterval: TimeInterval = 30 * 60
    public var retryInterval: TimeInterval = 5 * 60
    /// Consent and configuration gates, checked before every request.
    public var isEnabled: () -> Bool = { false }
    public var city: () -> String = { "" }
    /// Coordinates from the device's own location (or its last known one). When it returns a place, no city lookup happens.
    public var directPlace: () -> WeatherPlace? = { nil }
    public var unit: () -> TemperatureUnit = { .celsius }

    public init(transport: HTTPTransport, userAgent: String,
                geocodingBase: String = "https://geocoding-api.open-meteo.com", forecastBase: String = "https://api.open-meteo.com") {
        self.transport = transport
        self.userAgent = userAgent
        self.geocodingBase = geocodingBase
        self.forecastBase = forecastBase
    }

    public var latest: WeatherReading? { lock.withLock { last } }

    public func reset() {
        lock.withLock { cachedPlace = nil; last = nil; lastAttempt = nil }
    }

    private func url(_ base: String, _ path: String, _ items: [(String, String)]) -> URL? {
        var c = URLComponents(string: base + path)
        c?.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c?.url
    }

    /// Fetches if enabled, configured and due. Returns the reading to show (possibly the previous one).
    @discardableResult
    public func refresh(now: Date = Date(), force: Bool = false) async -> WeatherReading? {
        guard isEnabled() else { reset(); return nil }
        let direct = directPlace()
        let query = direct.map { String(format: "loc:%.2f,%.2f", $0.latitude, $0.longitude) }
            ?? city().trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = unit()
        guard !query.isEmpty else { reset(); return nil }

        let due: Bool = lock.withLock {
            if let last, last.unit != unit || last.place.name.isEmpty { return true }
            if cachedPlace?.query != query { return true }
            guard let attempt = lastAttempt else { return true }
            let interval = last == nil ? retryInterval : refreshInterval
            return force || now.timeIntervalSince(attempt) >= interval
        }
        guard due else { return latest }
        lock.withLock { lastAttempt = now }

        do {
            let place: WeatherPlace
            if let direct {
                place = direct
            } else if let cached = lock.withLock({ cachedPlace }), cached.query == query {
                place = cached.place
            } else {
                guard let u = url(geocodingBase, "/v1/search", [("name", query), ("count", "1"), ("language", "en"), ("format", "json")]) else { return latest }
                let response = try await transport.get(u, headers: ["User-Agent": userAgent], timeout: 6)
                guard response.status == 200, let found = OpenMeteoParser.parseGeocoding(response.body) else { return latest }
                place = found
                lock.withLock { cachedPlace = (query, found) }
            }
            guard let u = url(forecastBase, "/v1/forecast", [
                ("latitude", String(format: "%.4f", place.latitude)), ("longitude", String(format: "%.4f", place.longitude)),
                ("current", "temperature_2m,weather_code,is_day"), ("daily", "temperature_2m_max,temperature_2m_min"),
                ("temperature_unit", unit.apiValue), ("timezone", "auto"), ("forecast_days", "1"),
            ]) else { return latest }
            let response = try await transport.get(u, headers: ["User-Agent": userAgent], timeout: 6)
            guard response.status == 200, let reading = OpenMeteoParser.parseForecast(response.body, place: place, unit: unit, now: now) else { return latest }
            lock.withLock { last = reading }
            return reading
        } catch {
            return latest   // keep showing the last reading; the next try waits for the retry interval
        }
    }
}
