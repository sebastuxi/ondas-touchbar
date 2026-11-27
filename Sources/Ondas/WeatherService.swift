import CoreLocation
import Foundation

/// El clima de donde estás, para la pantalla de reposo.
/// - Ubicación: la de macOS, con tu permiso. Antes de salir del Mac se redondea a ~1 km.
/// - Datos: Open-Meteo (https://open-meteo.com), gratis y sin cuenta; licencia CC BY 4.0.
final class WeatherService: NSObject, CLLocationManagerDelegate {
    struct Report: Equatable {
        /// En °C (la barra lo muestra en la unidad de tu Mac).
        let temperature: Double
        /// Código del tiempo de la OMM (el que usa Open-Meteo).
        let code: Int
        let isDay: Bool
        let date: Date
        /// Salida y puesta del sol de hoy en tu zona (para el cielo del paisaje).
        var sunrise: Date?
        var sunset: Date?
    }

    enum Access { case pending, allowed, denied }

    var onChange: ((Report?) -> Void)?
    var onAccessChange: (() -> Void)?
    private(set) var report: Report?
    private(set) var access: Access = .pending

    private let manager = CLLocationManager()
    private var location: CLLocation?
    private var timer: Timer?
    private var retryWork: DispatchWorkItem?
    private var requestingLocation = false
    private var fetching = false
    private var asked = false

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        updateAccess()
        let timer = Timer(timeInterval: Theme.Weather.refresh, repeats: true) { [weak self] _ in self?.refresh(force: true) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Pide el clima otra vez. Sin `force` (al despertar la Mac) no repite si es reciente.
    func refresh(force: Bool = false) {
        if let report, Date().timeIntervalSince(report.date) > Theme.Weather.staleAfter { publish(nil) }
        guard access == .allowed, !requestingLocation, !fetching else { return }
        if !force, let report, Date().timeIntervalSince(report.date) < Theme.Weather.minInterval { return }
        if let location, -location.timestamp.timeIntervalSinceNow < Theme.Weather.locationMaxAge {
            fetch(at: location)
        } else {
            requestingLocation = true
            manager.requestLocation()
        }
    }

    // MARK: - Ubicación

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateAccess()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        location = latest
        // macOS puede avisar varias veces por una sola petición: con la primera basta.
        guard requestingLocation else { return }
        requestingLocation = false
        fetch(at: latest)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        requestingLocation = false
        if (error as? CLError)?.code == .denied {
            setAccess(.denied)   // también pasa con la Localización apagada en Ajustes
            return
        }
        Log.app.error("Clima: sin ubicación (\(error.localizedDescription, privacy: .public))")
        scheduleRetry()
    }

    private func updateAccess() {
        switch manager.authorizationStatus {
        case .notDetermined:
            if !asked {
                asked = true
                manager.requestWhenInUseAuthorization()
            }
            setAccess(.pending)
        case .denied, .restricted:
            setAccess(.denied)
        default:
            setAccess(.allowed)
        }
    }

    private func setAccess(_ next: Access) {
        guard next != access else { return }
        access = next
        Log.app.notice("Clima: ubicación \(String(describing: next), privacy: .public)")
        onAccessChange?()
        switch next {
        case .allowed: refresh(force: true)
        case .denied: publish(nil)
        case .pending: break
        }
    }

    // MARK: - Open-Meteo

    private func fetch(at location: CLLocation) {
        guard !fetching else { return }
        fetching = true
        // ~1 km: de sobra para el clima, sin mandar tu posición exacta.
        let latitude = String(format: "%.2f", location.coordinate.latitude)
        let longitude = String(format: "%.2f", location.coordinate.longitude)
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: latitude),
            URLQueryItem(name: "longitude", value: longitude),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "sunrise,sunset"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = components?.url else {
            fetching = false
            return
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let report = status == 200 ? data.flatMap { Self.parse($0) } : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                if let report {
                    self.publish(report)
                } else {
                    Log.app.error("Clima: no llegó (HTTP \(status, privacy: .public)) \(error?.localizedDescription ?? "", privacy: .public)")
                    self.scheduleRetry()
                }
            }
        }.resume()
    }

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature: Double
            let weatherCode: Int
            let isDay: Int

            enum CodingKeys: String, CodingKey {
                case temperature = "temperature_2m"
                case weatherCode = "weather_code"
                case isDay = "is_day"
            }
        }
        struct Daily: Decodable {
            let sunrise: [String]
            let sunset: [String]
        }
        let current: Current
        let daily: Daily?
        let utcOffset: Int?

        enum CodingKeys: String, CodingKey {
            case current, daily
            case utcOffset = "utc_offset_seconds"
        }
    }

    private static func parse(_ data: Data) -> Report? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let current = response.current
        var report = Report(temperature: current.temperature, code: current.weatherCode, isDay: current.isDay == 1, date: Date())
        // Las horas vienen en la hora local del lugar («2026-11-26T06:12»).
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = TimeZone(secondsFromGMT: response.utcOffset ?? 0) ?? .current
        report.sunrise = response.daily?.sunrise.first.flatMap { formatter.date(from: $0) }
        report.sunset = response.daily?.sunset.first.flatMap { formatter.date(from: $0) }
        return report
    }

    /// Guarda siempre el último (su hora dice cuándo está viejo); la barra solo se entera si cambia lo que se ve.
    private func publish(_ next: Report?) {
        let changed = next?.code != report?.code || next?.isDay != report?.isDay
            || next.map { Int($0.temperature.rounded()) } != report.map { Int($0.temperature.rounded()) }
        report = next
        guard changed else { return }
        if let next {
            Log.app.notice("Clima: \(Int(next.temperature.rounded()), privacy: .public)° · código \(next.code, privacy: .public)")
        }
        onChange?(next)
    }

    private func scheduleRetry() {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(force: true) }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Weather.retry, execute: work)
    }
}

extension WeatherService.Report {
    /// Símbolo SF del tiempo (de día o de noche).
    var symbol: String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63: return "cloud.rain.fill"
        case 65: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81, 82: return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95: return "cloud.bolt.rain.fill"
        case 96, 99: return "cloud.hail.fill"
        default: return "cloud.fill"
        }
    }

    /// Nombre corto del tiempo, en palabras de todos los días.
    var summary: String {
        switch code {
        case 0: return "Despejado"
        case 1: return "Casi despejado"
        case 2: return "Algo nublado"
        case 45, 48: return "Niebla"
        case 51, 53, 55: return "Llovizna"
        case 56, 57: return "Llovizna helada"
        case 61: return "Lluvia débil"
        case 63: return "Lluvia"
        case 65: return "Lluvia fuerte"
        case 66, 67: return "Lluvia helada"
        case 71: return "Nieve débil"
        case 73, 77: return "Nieve"
        case 75: return "Nieve fuerte"
        case 80, 81: return "Chubascos"
        case 82: return "Chubascos fuertes"
        case 85, 86: return "Chubascos de nieve"
        case 95: return "Tormenta"
        case 96, 99: return "Tormenta con granizo"
        default: return "Nublado"
        }
    }
}
