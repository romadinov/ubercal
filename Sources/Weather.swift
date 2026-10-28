import Foundation
import Observation

/// Daily forecast from Open-Meteo (free, no API key). The place is the city of the Mac's
/// time zone (it follows you when travelling) unless `weatherCity` is set in defaults.
/// Fetched at most once an hour, and only while a calendar view is on screen.
@MainActor @Observable
final class Weather {
    struct Day {
        let high: Int
        let low: Int
        let symbol: String
    }

    private(set) var days: [Date: Day] = [:]
    private var fetchedAt: Date?
    private var fetchedFor = ""
    private var task: Task<Void, Never>?

    var city: String {
        if let c = UserDefaults.standard.string(forKey: "weatherCity"), !c.isEmpty { return c }
        return TimeZone.current.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "London"
    }

    func day(_ date: Date) -> Day? { days[Calendar.current.startOfDay(for: date)] }

    func refreshIfStale() {
        let place = city
        if place == fetchedFor, let t = fetchedAt, Date().timeIntervalSince(t) < 3600 { return }
        guard task == nil else { return }
        task = Task {
            defer { task = nil }
            guard let (lat, lon) = await coordinates(for: place),
                  let parsed = await forecast(lat: lat, lon: lon) else { return }
            days = parsed
            fetchedAt = Date()
            fetchedFor = place
        }
    }

    private func coordinates(for place: String) async -> (Double, Double)? {
        let key = "geo:\(place)"
        if let cached = UserDefaults.standard.array(forKey: key) as? [Double], cached.count == 2 { return (cached[0], cached[1]) }
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [URLQueryItem(name: "name", value: place), URLQueryItem(name: "count", value: "1")]
        struct R: Decodable { struct P: Decodable { let latitude: Double; let longitude: Double }; let results: [P]? }
        guard let url = c.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let p = (try? JSONDecoder().decode(R.self, from: data))?.results?.first else { return nil }
        UserDefaults.standard.set([p.latitude, p.longitude], forKey: key)
        return (p.latitude, p.longitude)
    }

    private func forecast(lat: Double, lon: Double) async -> [Date: Day]? {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "16"),
        ]
        struct R: Decodable {
            struct D: Decodable {
                let time: [String]
                let weather_code: [Int?]
                let temperature_2m_max: [Double?]
                let temperature_2m_min: [Double?]
            }
            let daily: D
        }
        guard let url = c.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let r = try? JSONDecoder().decode(R.self, from: data) else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        var out: [Date: Day] = [:]
        for (i, t) in r.daily.time.enumerated() {
            guard let d = fmt.date(from: t), let hi = r.daily.temperature_2m_max[i], let lo = r.daily.temperature_2m_min[i] else { continue }
            out[Calendar.current.startOfDay(for: d)] = Day(high: Int(hi.rounded()), low: Int(lo.rounded()),
                                                          symbol: Self.symbol(r.daily.weather_code[i] ?? 0))
        }
        return out
    }

    /// WMO weather interpretation codes → SF Symbols.
    static func symbol(_ code: Int) -> String {
        switch code {
        case 0: "sun.max"
        case 1, 2: "cloud.sun"
        case 3: "cloud"
        case 45, 48: "cloud.fog"
        case 51...57: "cloud.drizzle"
        case 61...67: "cloud.rain"
        case 71...77, 85, 86: "cloud.snow"
        case 80...82: "cloud.heavyrain"
        case 95...99: "cloud.bolt.rain"
        default: "cloud"
        }
    }
}
