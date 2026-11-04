import AppKit
import CoreLocation

// MARK: - Weather
//
// Open-Meteo (no key) for the forecast, CoreLocation or a city typed in Settings for where.
// Refreshes on start, every 30 minutes (the app's one periodic job), on wake and when the
// location moves. The last snapshot is cached on disk so Home shows something at launch.

enum WeatherMode: String, CaseIterable {
    case off, location, city
    var title: String {
        switch self {
        case .off: return "Off"
        case .location: return "My location"
        case .city: return "A city"
        }
    }
}

enum WeatherUnits: String, CaseIterable {
    case c, f
    static var localeDefault: WeatherUnits { Locale.current.measurementSystem == .us ? .f : .c }
    var title: String { self == .c ? "°C" : "°F" }
    /// Snapshots keep Celsius; this converts for display.
    func value(_ celsius: Double) -> Double { self == .c ? celsius : celsius * 9 / 5 + 32 }
    /// "21°"
    func format(_ celsius: Double) -> String { "\(Int(value(celsius).rounded()))°" }
}

struct WeatherHour: Codable, Equatable {
    var time: Date
    /// °C
    var temp: Double
    var code: Int
    var precipitationChance: Int?
}

struct WeatherDay: Codable, Equatable {
    var date: Date
    /// °C
    var high: Double
    var low: Double
    var code: Int
}

struct WeatherSnapshot: Codable, Equatable {
    var fetchedAt: Date
    var placeName: String
    var latitude: Double
    var longitude: Double
    /// All temperatures in °C.
    var temperature: Double
    var feelsLike: Double
    var high: Double
    var low: Double
    /// WMO weather interpretation code.
    var code: Int
    var isDay: Bool
    /// Percent.
    var humidity: Int
    var windKmh: Double
    /// Percent, for the current hour.
    var precipitationChance: Int
    /// The next 12 hours, starting with the current one.
    var hours: [WeatherHour]
    /// Today and the next four days.
    var days: [WeatherDay]

    /// Older than three hours: still shown, but worth a refresh.
    var isStale: Bool { Date().timeIntervalSince(fetchedAt) > 3 * 3600 }

    /// SF Symbol for a WMO code.
    static func symbol(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1: return isDay ? "sun.max.fill" : "moon.fill"
        case 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67: return code >= 65 ? "cloud.heavyrain.fill" : "cloud.rain.fill"
        case 71, 73, 75, 77: return "cloud.snow.fill"
        case 80, 81, 82: return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 85, 86: return "cloud.snow.fill"
        case 95: return "cloud.bolt.fill"
        case 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func phrase(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45: return "Fog"
        case 48: return "Icy fog"
        case 51: return "Light drizzle"
        case 53: return "Drizzle"
        case 55: return "Heavy drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71: return "Light snow"
        case 73: return "Snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80: return "Light showers"
        case 81: return "Showers"
        case 82: return "Heavy showers"
        case 85: return "Snow showers"
        case 86: return "Heavy snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Cloudy"
        }
    }

    /// The tile's colour for a condition: warm for sun, blue for rain, quiet for cloud.
    @MainActor static func tint(for code: Int, isDay: Bool) -> NSColor {
        let p = Pal
        switch code {
        case 0, 1: return isDay ? p.warning : p.accent
        case 2: return isDay ? p.warning : p.muted
        case 3, 45, 48: return p.muted
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82: return p.water
        case 71, 73, 75, 77, 85, 86: return p.info
        case 95, 96, 99: return p.accent
        default: return p.muted
        }
    }
}

// MARK: - Service

@MainActor
final class WeatherService: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    /// Posted when `snapshot` or `status` changes.
    nonisolated static let changed = Notification.Name("ZeraWeatherChanged")

    private enum Key {
        static let mode = "zera.weather.mode"
        static let city = "zera.weather.city"
        static let units = "zera.weather.units"
    }
    private static let refreshEvery: TimeInterval = 30 * 60
    private static let refreshLeeway: Int = 5 * 60
    /// Moving less than this keeps the place name (no new reverse geocode).
    private static let samePlaceMetres: CLLocationDistance = 2000

    private let defaults = UserDefaults.standard
    private let manager = CLLocationManager()
    private var timer: DispatchSourceTimer?
    private var started = false
    private var fetching = false
    /// Where the last forecast was for, and the name it resolved to.
    private var lastLocation: CLLocation?
    private var lastPlace: String?
    private var cityResolved: (name: String, lat: Double, lon: Double)?
    private var geocoder: CLGeocoder?

    private(set) var snapshot: WeatherSnapshot? {
        didSet { if snapshot != oldValue { post() } }
    }
    /// What the widget says when there is nothing better: "Location off", "Updating…", an error.
    private(set) var status: String = "Location off" {
        didSet { if status != oldValue { post() } }
    }

    private override init() {
        super.init()
        // Ready before `start()`, so Onboarding's `setMode(.location)` can ask for access at once.
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    // MARK: Settings

    var mode: WeatherMode { WeatherMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .off }
    var city: String { defaults.string(forKey: Key.city) ?? "" }
    var units: WeatherUnits {
        get { WeatherUnits(rawValue: defaults.string(forKey: Key.units) ?? "") ?? .localeDefault }
        set { defaults.set(newValue.rawValue, forKey: Key.units); post() }
    }

    /// Settings → Weather. A new city (or a switch to one) refreshes right away.
    func setMode(_ newMode: WeatherMode, city newCity: String? = nil) {
        let oldMode = mode, oldCity = city
        defaults.set(newMode.rawValue, forKey: Key.mode)
        if let c = newCity { defaults.set(c.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.city) }
        if newMode == .off {
            status = "Location off"
            post()
            return
        }
        if newMode != oldMode || (newMode == .city && city != oldCity) || snapshot == nil { refresh() }
    }

    // MARK: Lifecycle

    /// Call once at launch. Shows the cached snapshot at once and starts the 30-minute cycle.
    func start() {
        guard !started else { return }
        started = true
        snapshot = Self.loadCache()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + Self.refreshEvery, repeating: Self.refreshEvery, leeway: .seconds(Self.refreshLeeway))
        t.setEventHandler { MainActor.assumeIsolated { WeatherService.shared.refresh() } }
        t.resume()
        timer = t
        refresh()
    }

    @objc private func wokeUp() {
        // The network comes back a moment after the display does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { WeatherService.shared.refresh() } }
    }

    /// Fetches now (for the mode in Settings). Safe to call any time; overlapping calls coalesce.
    func refresh() {
        switch mode {
        case .off:
            status = "Location off"
        case .city:
            resolveCity()
        case .location:
            requestLocation()
        }
    }

    private func post() { NotificationCenter.default.post(name: Self.changed, object: nil) }

    // MARK: Location

    private func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            status = "Waiting for location access"
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = "Location access denied"
        default:
            status = "Updating…"
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let s = WeatherService.shared
                guard s.mode == .location else { return }
                s.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { WeatherService.shared.handle(location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let s = WeatherService.shared
                guard s.mode == .location else { return }
                s.status = denied ? "Location access denied" : "Location unavailable"
            }
        }
    }

    private func handle(_ location: CLLocation) {
        guard mode == .location else { return }
        let moved = lastLocation.map { $0.distance(from: location) > Self.samePlaceMetres } ?? true
        let knownName = moved ? nil : lastPlace
        lastLocation = location
        fetch(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
              place: knownName ?? snapshot?.placeName ?? "")
        if knownName == nil { reverseGeocode(location) }
    }

    private func reverseGeocode(_ location: CLLocation) {
        geocoder?.cancelGeocode()
        let g = CLGeocoder()
        geocoder = g
        g.reverseGeocodeLocation(location) { placemarks, _ in
            let name = placemarks?.first.flatMap { $0.locality ?? $0.subAdministrativeArea ?? $0.administrativeArea ?? $0.name }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { WeatherService.shared.placeResolved(name, for: location) }
            }
        }
    }

    private func placeResolved(_ name: String?, for location: CLLocation) {
        guard let name = name, !name.isEmpty else { return }
        lastPlace = name
        if var s = snapshot, abs(s.latitude - location.coordinate.latitude) < 0.05, abs(s.longitude - location.coordinate.longitude) < 0.05,
           s.placeName != name {
            s.placeName = name
            snapshot = s
            Self.saveCache(s)
        }
    }

    // MARK: City

    private func resolveCity() {
        let name = city
        guard !name.isEmpty else { status = "No city set"; return }
        if let r = cityResolved, r.name == name {
            fetch(latitude: r.lat, longitude: r.lon, place: name)
            return
        }
        status = "Finding \(name)…"
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        parts.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "1"),
                            URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "format", value: "json")]
        guard let url = parts.url else { status = "Can't find \(name)"; return }
        Task { @MainActor [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let hit = try JSONDecoder().decode(GeocodingResponse.self, from: data).results?.first
                guard let self = self, self.city == name else { return }
                guard let hit = hit else { self.status = "Can't find \(name)"; return }
                let place = hit.name ?? name
                self.cityResolved = (name, hit.latitude, hit.longitude)
                self.fetch(latitude: hit.latitude, longitude: hit.longitude, place: place)
            } catch {
                guard let self = self, self.city == name else { return }
                self.status = "Can't look up \(name)"
            }
        }
    }

    private struct GeocodingResponse: Decodable {
        struct Hit: Decodable { let name: String?; let latitude: Double; let longitude: Double }
        let results: [Hit]?
    }

    // MARK: Forecast

    private func fetch(latitude: Double, longitude: Double, place: String) {
        guard !fetching else { return }
        fetching = true
        status = "Updating…"
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,is_day,weather_code,relative_humidity_2m,wind_speed_10m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "5"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = parts.url else { fetching = false; status = "Weather unavailable"; return }
        Task { @MainActor [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                let snap = try Self.parse(data, place: place, latitude: latitude, longitude: longitude)
                guard let self = self else { return }
                self.fetching = false
                self.snapshot = snap
                self.status = "Updated"
                Self.saveCache(snap)
            } catch {
                guard let self = self else { return }
                self.fetching = false
                self.status = (error as? URLError)?.code == .notConnectedToInternet ? "Offline" : "Weather unavailable"
            }
        }
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let time: String
            let temperature_2m: Double
            let apparent_temperature: Double?
            let is_day: Int?
            let weather_code: Int?
            let relative_humidity_2m: Double?
            let wind_speed_10m: Double?
        }
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double?]
            let weather_code: [Int?]
            let precipitation_probability: [Int?]?
        }
        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int?]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
        }
        let utc_offset_seconds: Int?
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }

    nonisolated private static func parse(_ data: Data, place: String, latitude: Double, longitude: Double) throws -> WeatherSnapshot {
        let r = try JSONDecoder().decode(ForecastResponse.self, from: data)
        let zone = TimeZone(secondsFromGMT: r.utc_offset_seconds ?? 0) ?? .current
        let hourFormat = DateFormatter()
        hourFormat.locale = Locale(identifier: "en_US_POSIX"); hourFormat.timeZone = zone; hourFormat.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX"); dayFormat.timeZone = zone; dayFormat.dateFormat = "yyyy-MM-dd"

        let now = Date()
        var hours: [WeatherHour] = []
        for (i, t) in r.hourly.time.enumerated() {
            guard let date = hourFormat.date(from: t), date.addingTimeInterval(3600) > now,
                  i < r.hourly.temperature_2m.count, let temp = r.hourly.temperature_2m[i] else { continue }
            let code = i < r.hourly.weather_code.count ? (r.hourly.weather_code[i] ?? 3) : 3
            let chance = r.hourly.precipitation_probability.flatMap { i < $0.count ? $0[i] : nil }
            hours.append(WeatherHour(time: date, temp: temp, code: code, precipitationChance: chance))
            if hours.count == 12 { break }
        }
        var days: [WeatherDay] = []
        for (i, t) in r.daily.time.enumerated() {
            guard let date = dayFormat.date(from: t), i < r.daily.temperature_2m_max.count, i < r.daily.temperature_2m_min.count,
                  let high = r.daily.temperature_2m_max[i], let low = r.daily.temperature_2m_min[i] else { continue }
            let code = i < r.daily.weather_code.count ? (r.daily.weather_code[i] ?? 3) : 3
            days.append(WeatherDay(date: date, high: high, low: low, code: code))
            if days.count == 5 { break }
        }
        let today = days.first
        return WeatherSnapshot(fetchedAt: now, placeName: place, latitude: latitude, longitude: longitude,
                               temperature: r.current.temperature_2m,
                               feelsLike: r.current.apparent_temperature ?? r.current.temperature_2m,
                               high: today?.high ?? r.current.temperature_2m, low: today?.low ?? r.current.temperature_2m,
                               code: r.current.weather_code ?? 3, isDay: (r.current.is_day ?? 1) != 0,
                               humidity: Int((r.current.relative_humidity_2m ?? 0).rounded()),
                               windKmh: r.current.wind_speed_10m ?? 0,
                               precipitationChance: hours.first?.precipitationChance ?? 0,
                               hours: hours, days: days)
    }

    // MARK: Cache

    nonisolated private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zera", isDirectory: true)
        return base.appendingPathComponent("weather.json")
    }

    nonisolated private static func loadCache() -> WeatherSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WeatherSnapshot.self, from: data)
    }

    nonisolated private static func saveCache(_ snapshot: WeatherSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        let url = cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Home tile

/// Now, feels-like, hi / lo and the next six hours when the width allows. With weather off it
/// offers a "Turn on" button (`onEnable`); with it on and nothing fetched yet it shows the status.
final class WeatherWidget: NSView {
    static let height: CGFloat = 96
    var onTap: (() -> Void)?
    /// Settings → Weather, or the integrator's own prompt.
    var onEnable: (() -> Void)?
    /// Show the "Turn on" state even before anything was ever fetched (for first-run Homes).
    var alwaysVisible = false { didSet { needsDisplay = true } }

    private var enableButton: CardButton!
    private var hovered = false { didSet { restyle() } }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Home skips the tile when there is nothing to show and weather is off.
    var isAvailable: Bool {
        let s = WeatherService.shared
        return s.snapshot != nil || s.mode != .off || alwaysVisible
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        roundLayer(Radius.l)
        enableButton = CardButton("Turn on", style: .primary, symbol: "location.fill", target: self, action: #selector(enableTapped))
        addSubview(enableButton)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: WeatherService.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: Palette.changed, object: nil)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        restyle()
        changed()
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func enableTapped() { onEnable?() }

    @objc private func changed() {
        let s = WeatherService.shared
        enableButton.isHidden = s.mode != .off
        if let snap = s.snapshot {
            setAccessibilityLabel("Weather: \(s.units.format(snap.temperature)), \(WeatherSnapshot.phrase(for: snap.code)) in \(snap.placeName)")
        } else {
            setAccessibilityLabel(s.mode == .off ? "Weather, off" : "Weather, \(s.status)")
        }
        needsLayout = true
        needsDisplay = true
    }

    private func restyle() {
        let p = Pal
        layer?.backgroundColor = (hovered && onTap != nil ? p.surfaceHover : p.surfaceRow).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = p.divider.cgColor
    }

    // MARK: Layout

    private static let pad = Space.m
    private static let tile: CGFloat = 44
    private static let hourColumn: CGFloat = 44
    private static let hoursShown = 6
    /// The left block (tile, temperature, phrase) needs this much before the hour strip appears.
    private static let leftBlock: CGFloat = 300

    private var stripFrame: NSRect? {
        let w = CGFloat(Self.hoursShown) * Self.hourColumn
        guard bounds.width - Self.pad * 2 - Self.leftBlock >= w + Space.l else { return nil }
        return NSRect(x: bounds.width - Self.pad - w, y: Self.pad, width: w, height: bounds.height - Self.pad * 2)
    }

    override func layout() {
        super.layout()
        let bw = enableButton.fittedWidth, bh = Metrics.button
        enableButton.frame = NSRect(x: bounds.width - Self.pad - bw, y: (bounds.height - bh) / 2, width: bw, height: bh)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let p = Pal
        let s = WeatherService.shared
        let h = bounds.height
        let tileRect = NSRect(x: Self.pad, y: (h - Self.tile) / 2, width: Self.tile, height: Self.tile)
        let textX = tileRect.maxX + Space.m

        guard let snap = s.snapshot, s.mode != .off else {
            // Off, or on but nothing yet: a quiet title with the status (or an invitation).
            drawTile(symbol: "cloud.sun.fill", tint: p.info, in: tileRect)
            let right = enableButton.isHidden ? bounds.width - Self.pad : enableButton.frame.minX - Space.m
            draw("Weather", font: Typo.rowTitle, color: p.text, in: NSRect(x: textX, y: h / 2 - 18, width: right - textX, height: 18))
            let line = s.mode == .off ? "See the forecast at a glance" : s.status
            draw(line, font: Typo.meta, color: p.textSecondary, in: NSRect(x: textX, y: h / 2 + 1, width: right - textX, height: 16))
            return
        }

        drawTile(symbol: WeatherSnapshot.symbol(for: snap.code, isDay: snap.isDay), tint: WeatherSnapshot.tint(for: snap.code, isDay: snap.isDay), in: tileRect)
        let strip = stripFrame
        let right = strip.map { $0.minX - Space.l } ?? (bounds.width - Self.pad)
        let units = s.units

        // Big temperature, then the phrase and place, then hi / lo and feels-like.
        let bigFont = NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        let big = units.format(snap.temperature)
        let bigSize = (big as NSString).size(withAttributes: [.font: bigFont])
        draw(big, font: bigFont, color: p.text, in: NSRect(x: textX, y: 14, width: ceil(bigSize.width) + 2, height: ceil(bigSize.height)))
        let detailX = textX + ceil(bigSize.width) + Space.m
        let phrase = "\(WeatherSnapshot.phrase(for: snap.code))\(snap.placeName.isEmpty ? "" : " · \(snap.placeName)")"
        draw(phrase, font: Typo.rowTitle, color: p.text, in: NSRect(x: detailX, y: 18, width: max(0, right - detailX), height: 18))
        var meta = "H \(units.format(snap.high))  L \(units.format(snap.low))  ·  Feels \(units.format(snap.feelsLike))"
        if snap.precipitationChance > 0 { meta += "  ·  \(snap.precipitationChance)% rain" }
        draw(meta, font: Typo.meta, color: p.textSecondary, in: NSRect(x: detailX, y: 38, width: max(0, right - detailX), height: 16))
        let foot = snap.isStale ? "Updated \(relativeTime(snap.fetchedAt))" : "Humidity \(snap.humidity)%  ·  Wind \(Int(snap.windKmh.rounded())) km/h"
        draw(foot, font: Typo.caption, color: p.textTertiary, in: NSRect(x: textX, y: 62, width: max(0, right - textX), height: 14))

        // The next hours: label, symbol, temperature in a column each.
        guard let stripRect = strip else { return }
        let hourFormat = DateFormatter()
        hourFormat.setLocalizedDateFormatFromTemplate("j")
        let para = NSMutableParagraphStyle(); para.alignment = .center
        for (i, hour) in snap.hours.prefix(Self.hoursShown).enumerated() {
            let column = NSRect(x: stripRect.minX + CGFloat(i) * Self.hourColumn, y: stripRect.minY, width: Self.hourColumn, height: stripRect.height)
            let label = i == 0 ? "Now" : hourFormat.string(from: hour.time).replacingOccurrences(of: " ", with: "")
            draw(label, font: Typo.caption, color: p.textTertiary, in: NSRect(x: column.minX, y: column.minY, width: column.width, height: 14), paragraph: para)
            let isDay = Self.isDaytime(hour.time, reference: snap)
            drawSymbol(WeatherSnapshot.symbol(for: hour.code, isDay: isDay), tint: WeatherSnapshot.tint(for: hour.code, isDay: isDay),
                       center: NSPoint(x: column.midX, y: column.midY + 1), pointSize: 13)
            draw(units.format(hour.temp), font: Typo.bodyMedium, color: p.text,
                 in: NSRect(x: column.minX, y: column.maxY - 16, width: column.width, height: 16), paragraph: para)
        }
    }

    /// Day or night for an hour of the strip: between 6 and 20 counts as day unless the current
    /// reading says it is night already and the hour is the current one.
    private static func isDaytime(_ time: Date, reference: WeatherSnapshot) -> Bool {
        let hour = Calendar.current.component(.hour, from: time)
        if abs(time.timeIntervalSinceNow) < 3600 { return reference.isDay }
        return hour >= 6 && hour < 20
    }

    private func drawTile(symbol: String, tint: NSColor, in rect: NSRect) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: (rect.width * 0.32).rounded(), yRadius: (rect.width * 0.32).rounded())
        tint.withAlphaComponent(0.18).setFill(); shape.fill()
        drawSymbol(symbol, tint: tint.blended(withFraction: 0.12, of: .white) ?? tint, center: NSPoint(x: rect.midX, y: rect.midY), pointSize: 19)
    }

    private func drawSymbol(_ name: String, tint: NSColor, center: NSPoint, pointSize: CGFloat) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))?
            .withSymbolConfiguration(.init(paletteColors: [tint])) else { return }
        let size = image.size
        image.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, in rect: NSRect, paragraph: NSParagraphStyle? = nil) {
        guard rect.width > 0 else { return }
        let para = (paragraph?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    }

    // MARK: Hover & tap

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        resetHoverTracking()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onTap?() }
    override func accessibilityPerformPress() -> Bool {
        if WeatherService.shared.mode == .off { onEnable?() } else { onTap?() }
        return true
    }
    override func resetCursorRects() { if onTap != nil { addCursorRect(bounds, cursor: .pointingHand) } }
}
