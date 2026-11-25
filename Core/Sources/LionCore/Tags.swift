import Foundation

/// A trip label ("Work", "Home"…). With a place, trips that start or end within [radius] of it get the tag by themselves.
public struct TripTag: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var color: Int
    public var lat: Double?
    public var lon: Double?
    public var radius: Double

    public init(id: String = UUID().uuidString, name: String, color: Int, lat: Double? = nil, lon: Double? = nil, radius: Double = 200) {
        self.id = id; self.name = name; self.color = color; self.lat = lat; self.lon = lon; self.radius = radius
    }

    public var hasPlace: Bool { lat != nil && lon != nil }
}

/// The tags and the per-trip choices the user made. Stored as JSON by the app.
public struct TagBook: Codable, Equatable, Sendable {
    public var tags: [TripTag] = []
    /// Trip id -> tag id, or "" for "no tag" chosen by hand (overrides the automatic one).
    public var manual: [String: String] = [:]
    public var autoTag = true

    public init() {}

    /// The tag a trip has: the hand-picked one, or the first tag whose place is at its start or end.
    public func tag(for trip: Trip) -> TripTag? {
        if let m = manual[trip.id] { return tags.first { $0.id == m } }
        guard autoTag else { return nil }
        return tags.first { tag in
            guard let lat = tag.lat, let lon = tag.lon else { return false }
            return [(trip.startLat, trip.startLon), (trip.stopLat, trip.stopLon)].contains { p in
                guard let a = p.0, let b = p.1 else { return false }
                return Geo.distanceM(lat, lon, a, b) <= tag.radius
            }
        }
    }

    public mutating func set(_ tagID: String?, for tripID: String) { manual[tripID] = tagID ?? "" }
    public mutating func clearManual(for tripID: String) { manual[tripID] = nil }

    public mutating func remove(_ tagID: String) {
        tags.removeAll { $0.id == tagID }
        manual = manual.filter { $0.value != tagID }
    }

    public static func decode(_ s: String?) -> TagBook {
        guard let s, let d = s.data(using: .utf8), let b = try? JSONDecoder().decode(TagBook.self, from: d) else { return TagBook() }
        return b
    }

    public func encoded() -> String { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}" }
}

public enum Geo {
    /// Great-circle distance in metres.
    public static func distanceM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0, d2r = Double.pi / 180
        let dLat = (lat2 - lat1) * d2r, dLon = (lon2 - lon1) * d2r
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * d2r) * cos(lat2 * d2r) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    /// "N", "NE", … for a compass heading.
    public static func compass(_ heading: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let i = Int(((heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) + 22.5) / 45) % 8
        return names[i]
    }
}

/// Trips as a spreadsheet (comma-separated, UTF-8, "." decimals), for the share sheet.
public enum TripCSV {
    public static let header = ["start", "end", "distance_km", "duration_min", "avg_speed_kmh", "fuel_l", "l_per_100km",
                                "energy_kwh", "cost", "tag", "level_start_pct", "level_end_pct",
                                "start_lat", "start_lon", "end_lat", "end_lon"]

    public static func make(_ trips: [Trip], tag: (Trip) -> String?, cost: (Trip) -> Double?, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
        func n(_ v: Double?, _ digits: Int) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "" }
        var lines = [header.joined(separator: ",")]
        for t in trips.sorted(by: { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }) {
            let row = [t.start.map(f.string) ?? "", t.end.map(f.string) ?? "", n(t.distanceKm, 1), n(t.durationSec.map { $0 / 60 }, 0),
                       n(t.avgSpeedKmh, 0), n(t.liters, 2), n(t.avgLPer100, 1), n(t.kwh, 2), n(cost(t), 2), tag(t) ?? "",
                       n(t.startLevel, 0), n(t.endLevel, 0), n(t.startLat, 5), n(t.startLon, 5), n(t.stopLat, 5), n(t.stopLon, 5)]
            lines.append(row.map(quote).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func quote(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}
