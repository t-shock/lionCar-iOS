import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A charging station or fuel station from OpenStreetMap.
public struct Charger: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let lat: Double
    public let lon: Double
    /// Highest power of any point (kW), 0 when not mapped.
    public let maxKw: Double
    /// Number of charging points (capacity), 0 when not mapped.
    public let points: Int
    public let address: String
    /// Plug types with how many of each, e.g. ["CCS": 4, "Type 2": 2].
    public var sockets: [String: Int] = [:]
    public var operatorName: String = ""
    public var openingHours: String = ""
    /// "yes", "no" or "" (not mapped).
    public var fee: String = ""

    public var isFast: Bool { maxKw >= 50 }
}

/// Chargers (or fuel stations) near a point, from OpenStreetMap through the free public Overpass servers — no key,
/// no account. Port of LionFlow's OsmChargers: the servers are checked first (they are often busy), the free ones are
/// asked at once and the others a little later, and the first good answer wins.
///
/// Only the search area's coordinates are sent to these servers; nothing about the car or the account.
public enum OsmPlaces {
    public static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    ]
    /// The Overpass servers ask for an app name and a way to reach its makers.
    static let userAgent = "LionCar/1.0 (github.com/t-shock/lionCar-iOS)"

    public enum Kind: String, Sendable { case chargers = "charging_station", fuel = "fuel" }

    public struct BusyError: Error, LocalizedError {
        public var errorDescription: String? { "The free charger servers are busy right now" }
    }

    public struct OfflineError: Error, LocalizedError {
        public var errorDescription: String? { "No internet connection, or all the free charger servers are down" }
    }

    /// The Overpass query: stations within [radiusM] of the point, nodes and areas (as their centre).
    public static func query(lat: Double, lon: Double, radiusM: Int, limit: Int, kind: Kind) -> String {
        let a = String(format: "%.5f,%.5f", lat, lon)
        let k = kind.rawValue
        return "[out:json][timeout:25];(node[\"amenity\"=\"\(k)\"](around:\(radiusM),\(a));way[\"amenity\"=\"\(k)\"](around:\(radiusM),\(a)););out center \(limit);"
    }

    /// Reads an Overpass answer.
    public static func parse(_ j: JSON, kind: Kind) -> [Charger] {
        j.objects("elements").compactMap { e in
            guard let la = e.num("lat") ?? e.obj("center")?.num("lat"), let lo = e.num("lon") ?? e.obj("center")?.num("lon") else { return nil }
            let t = e.obj("tags") ?? [:]
            let (maxKw, sockets) = powerAndSockets(t)
            let name = ["name", "operator", "brand", "network"].lazy.compactMap { t.str($0) }.first { !$0.isEmpty }
                ?? (kind == .fuel ? "Fuel station" : "Charging station")
            let address = [[t.str("addr:street"), t.str("addr:housenumber")].compactMap { $0 }.joined(separator: " "), t.optString("addr:city")]
                .filter { !$0.isEmpty }.joined(separator: ", ")
            var c = Charger(id: "osm-\(e.optString("type"))-\(e.optString("id"))", name: name, lat: la, lon: lo, maxKw: maxKw,
                            points: Int(t.optString("capacity")) ?? 0, address: address)
            c.sockets = sockets
            c.operatorName = t.str("operator") ?? t.str("network") ?? ""
            c.openingHours = t.optString("opening_hours")
            c.fee = t.optString("fee")
            return c
        }
    }

    /// The highest power mapped on a station (kW, 0 when none) and how many sockets of each plug type it has.
    private static func powerAndSockets(_ tags: JSON) -> (maxKw: Double, sockets: [String: Int]) {
        var maxKw = 0.0
        var sockets: [String: Int] = [:]
        for (k, v) in tags {
            let value = "\(v)".lowercased()
            if k.hasSuffix(":output") || k == "maxpower" {
                if let kw = power(value), kw > maxKw { maxKw = kw }
            }
            // socket:type2_combo = 4 (a count), but not socket:type2_combo:output etc.
            if k.hasPrefix("socket:"), k.split(separator: ":").count == 2 {
                let name = socketName(String(k.dropFirst("socket:".count)))
                let n = Int(value) ?? (value == "yes" ? 1 : 0)
                if n > 0 { sockets[name, default: 0] += n }
            }
        }
        return (maxKw, sockets)
    }

    /// "22 kW", "150kW", "0.35 MW", "50000" (plain watts), "11" → kW.
    static func power(_ v: String) -> Double? {
        guard let r = v.range(of: #"[0-9]+(?:[.,][0-9]+)?"#, options: .regularExpression),
              let num = Double(v[r].replacingOccurrences(of: ",", with: ".")) else { return nil }
        if v.contains("mw") { return num * 1000 }
        if v.contains("kw") { return num }
        return num > 1000 ? num / 1000 : num
    }

    static func socketName(_ s: String) -> String {
        switch s {
        case "type2_combo": "CCS"
        case "type2", "type2_cable": "Type 2"
        case "chademo": "CHAdeMO"
        case "type1_combo": "CCS1"
        case "type1": "Type 1"
        case "tesla_supercharger": "Tesla"
        case "schuko": "Schuko"
        default: s.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Stations near the point, from the first free server that answers.
    public static func near(lat: Double, lon: Double, radiusM: Int = 12_000, limit: Int = 80, kind: Kind) async throws -> [Charger] {
        parse(try await raw(query(lat: lat, lon: lon, radiusM: radiusM, limit: limit, kind: kind)), kind: kind)
    }

    /// Asks a server whether it has room right now: seconds to wait (0 = free), or nil when it doesn't answer (3 s at most).
    static func probe(_ url: String) async -> Int? {
        var r = URLRequest(url: URL(string: url.replacingOccurrences(of: "/interpreter", with: "/status"))!)
        r.timeoutInterval = 3
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await HTTP.session.data(for: r) else { return nil }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return 5 }
        let t = String(decoding: data, as: UTF8.self)
        if t.contains("available now") { return 0 }
        if let m = t.range(of: #"in (\d+) seconds"#, options: .regularExpression),
           let n = Int(t[m].filter(\.isNumber)) { return min(20, max(1, n)) }
        return 5
    }

    /// Runs a query on the first free server that answers: check them all (3 s), ask the free ones at once and the
    /// others a little later, take the first good answer, give up after 40 s. Unlike LionFlow, a server whose status page
    /// doesn't answer is still asked (last): some answer searches but not their status page.
    public static func raw(_ q: String) async throws -> JSON {
        let waits = await probeAll()
        // A server whose status page didn't answer is still asked, as if it had said "wait 1 s".
        let usable = waits.map { ($0.0, $0.1 ?? 1) }.sorted { $0.1 < $1.1 }
        let allSilent = waits.allSatisfy { $0.1 == nil }
        let body = "data=" + (q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q)
        return try await withThrowingTaskGroup(of: JSON?.self) { g in
            for (i, (url, wait)) in usable.enumerated() {
                g.addTask {
                    // Each server waits as long as it asked, plus 1.5 s per place in the queue.
                    try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000 + UInt64(i) * 1_500_000_000)
                    guard let j = try? await HTTP.json(searchRequest(url, body: body)) as? JSON else { return nil as JSON? }
                    // A server that ran out of time answers "OK" with a remark and no data.
                    if !(j.str("remark") ?? "").isEmpty && j.objects("elements").isEmpty { return nil }
                    return j
                }
            }
            g.addTask { try await Task.sleep(nanoseconds: 40_000_000_000); throw BusyError() }
            var answered = 0
            while let r = try await g.next() {
                if let j = r { g.cancelAll(); return j }
                answered += 1
                if answered == usable.count { g.cancelAll(); throw allSilent ? OfflineError() as Error : BusyError() }
            }
            throw BusyError()
        }
    }

    /// Every server's answer to [probe], at the same time.
    private static func probeAll() async -> [(String, Int?)] {
        await withTaskGroup(of: (String, Int?).self) { g in
            for u in endpoints { g.addTask { (u, await probe(u)) } }
            var out: [(String, Int?)] = []
            for await x in g { out.append(x) }
            return out
        }
    }

    private static func searchRequest(_ url: String, body: String) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"
        r.timeoutInterval = 35
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(body.utf8)
        return r
    }
}
