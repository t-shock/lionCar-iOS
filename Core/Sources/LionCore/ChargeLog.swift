import Foundation

/// A place where you charge: Home or one of up to 5 known chargers. Price per kWh (0 = free).
public struct ChargePlace: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var lat: Double?
    public var lon: Double?
    public var price: Double
    public init(id: String, name: String, lat: Double? = nil, lon: Double? = nil, price: Double = 0) {
        self.id = id; self.name = name; self.lat = lat; self.lon = lon; self.price = price
    }
}

public struct PlacesConfig: Codable, Equatable, Sendable {
    public var home: ChargePlace?
    /// Up to 5.
    public var known: [ChargePlace] = []
    /// Estimates for unknown AC / fast chargers, per kWh (0 = don't estimate).
    public var publicAcPrice = 0.0
    public var publicDcPrice = 0.0
    public init() {}
}

/// One charging session, built from the car's own status reports.
public struct ChargeSession: Codable, Equatable, Identifiable, Sendable {
    public var id: Double { start }
    public var start: Double          // unix seconds
    public var end: Double
    public var startPct: Double
    public var endPct: Double
    public var kwh: Double
    public var peakKw: Double?
    /// Slow (AC) | Quick (DC)
    public var mode: String?
    public var lat: Double?
    public var lon: Double?
    public var address: String?
    /// True when kwh comes from the energy the car reported in the battery (not from % × battery size).
    public var measured = false

    public var hours: Double { (end - start) / 3600 }
    public var avgKw: Double? { hours > 0.05 ? kwh / hours : nil }
    public var isFast: Bool { mode == "Quick" }
}

/// Where a session happened and what it cost per kWh.
public struct PlaceMatch: Equatable, Sendable {
    /// home | known | public | unknown
    public let kind: String
    public let label: String
    public let price: Double?
}

/// Charging log. The car has no charging history, so LionCar watches its status reports and turns
/// "charging started → stopped" into sessions. Port of LionFlow's ChargeLog.kt. Everything stays on the phone.
///
/// Untested on a real electric car. On iPhone a session is only noticed when LionCar sees the car charging
/// (app open, or a background check iOS allowed), so short charges can be missed.
public final class ChargeLog {
    private let store: SecretStore
    private let vin: String
    private let power: ChargePower

    public init(store: SecretStore, vin: String, power: ChargePower) {
        self.store = store; self.vin = vin; self.power = power
    }

    private func k(_ name: String) -> String { vin.isEmpty ? "cl_\(name)" : "cl_\(name)_\(vin)" }

    public var sessions: [ChargeSession] {
        guard let s = store.get(k("sessions")), let d = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ChargeSession].self, from: d)) ?? []
    }

    private func save(_ list: [ChargeSession]) {
        store.set(k("sessions"), (try? JSONEncoder().encode(list)).map { String(decoding: $0, as: UTF8.self) })
    }

    /// Places are shared by all cars.
    public var places: PlacesConfig {
        get {
            guard let s = store.get("cl_places"), let d = s.data(using: .utf8) else { return PlacesConfig() }
            return (try? JSONDecoder().decode(PlacesConfig.self, from: d)) ?? PlacesConfig()
        }
        set { store.set("cl_places", (try? JSONEncoder().encode(newValue)).map { String(decoding: $0, as: UTF8.self) }) }
    }

    private var activeJSON: JSON? {
        get { store.get(k("active")).flatMap { JSONValue.parse($0) as? JSON } }
        set { store.set(k("active"), newValue.map { String(decoding: JSONValue.data($0), as: UTF8.self) }) }
    }

    /// The session in progress (end = last report so far).
    public var active: ChargeSession? { activeJSON.map { toSession($0) } }

    /// Watches one status report. Returns a session when one has just finished (so the app can look up its address).
    @discardableResult
    public func observe(_ st: VehicleStatus, now: Date = Date()) -> ChargeSession? {
        guard st.energyType != "Fuel", let pct = st.batteryPct else { return nil }
        let t = (st.energyAt ?? st.updatedAt ?? now).timeIntervalSince1970
        var a = activeJSON
        var finished: ChargeSession?
        // A session left open for over a day (phone off, car asleep) is closed first.
        if let open = a, t - (open.num("lastT") ?? t) > 24 * 3600 { finished = finish(open, nil, nil, nil); a = nil }

        if st.isCharging {
            let kw = power.reading(st).flatMap { $0.measured ? $0.kw : nil }
            if var x = a {
                if x["lat"] == nil, let la = st.lat, let lo = st.lon { x["lat"] = la; x["lon"] = lo }
                if let kw, kw > (x.num("peak") ?? 0) { x["peak"] = kw }
                if st.chargingMode == "Quick" { x["mode"] = "Quick" }
                x["usable"] = power.usableKwh(st)
                a = x
            } else {
                var x: JSON = ["start": t, "startPct": pct, "usable": power.usableKwh(st)]
                if let r = st.residualKwh { x["startKwh"] = r }
                if let la = st.lat, let lo = st.lon { x["lat"] = la; x["lon"] = lo }
                if let m = st.chargingMode { x["mode"] = m }
                if let kw { x["peak"] = kw }
                a = x
            }
            if var x = a, t >= (x.num("lastT") ?? 0) {
                x["lastT"] = t; x["lastPct"] = pct
                if let r = st.residualKwh { x["lastKwh"] = r } else { x["lastKwh"] = nil }
                a = x
            }
            activeJSON = a
        } else if let open = a {
            // Charging stopped. If this report shows a higher level (finished while nobody was looking), use it.
            let higher = pct > (open.num("lastPct") ?? pct) && t > (open.num("lastT") ?? t)
            finished = finish(open, higher ? pct : nil, higher ? t : nil, higher ? st.residualKwh : nil) ?? finished
        }
        return finished
    }

    private func finish(_ a: JSON, _ endPct: Double?, _ endT: Double?, _ endKwh: Double?) -> ChargeSession? {
        activeJSON = nil
        let s = toSession(a, endPct, endT, endKwh)
        if s.kwh < 0.3 || (s.end - s.start < 120 && s.endPct - s.startPct < 1) { return nil }
        save(Array(([s] + sessions).prefix(500)))
        return s
    }

    private func toSession(_ a: JSON, _ endPct: Double? = nil, _ endT: Double? = nil, _ endKwh: Double? = nil) -> ChargeSession {
        let start = a.num("start") ?? 0
        let startPct = a.num("startPct") ?? 0
        let lastPct = endPct ?? a.num("lastPct") ?? startPct
        let startKwh = a.num("startKwh")
        let lastKwh = endKwh ?? a.num("lastKwh")
        let usable = a.num("usable") ?? 73
        let measured = startKwh != nil && lastKwh != nil && lastKwh! > startKwh!
        let kwh = measured ? lastKwh! - startKwh! : max(0, (lastPct - startPct) / 100 * usable)
        return ChargeSession(start: start, end: endT ?? a.num("lastT") ?? start, startPct: startPct, endPct: lastPct, kwh: kwh,
                             peakKw: a.num("peak"), mode: a.str("mode"), lat: a.num("lat"), lon: a.num("lon"), address: nil,
                             measured: measured)
    }

    public func delete(_ s: ChargeSession) { save(sessions.filter { $0.start != s.start }) }

    public func setAddress(_ address: String, for s: ChargeSession) {
        save(sessions.map { var x = $0; if x.start == s.start { x.address = address }; return x })
    }

    /// Replaces the whole log (demo mode).
    public func replace(_ list: [ChargeSession]) { save(list); activeJSON = nil }

    public func clear() { save([]); activeJSON = nil }

    /// Home within 50 m, a known charger within 75 m, otherwise a public AC or fast charger at the estimated price.
    public func match(_ s: ChargeSession) -> PlaceMatch { Self.match(s, places) }

    public static func match(_ s: ChargeSession, _ cfg: PlacesConfig) -> PlaceMatch {
        if let lat = s.lat, let lon = s.lon {
            if let h = cfg.home, let hl = h.lat, let ho = h.lon, Geo.distanceM(lat, lon, hl, ho) <= 50 {
                return PlaceMatch(kind: "home", label: "Home", price: h.price)
            }
            for p in cfg.known {
                if let pl = p.lat, let po = p.lon, Geo.distanceM(lat, lon, pl, po) <= 75 {
                    return PlaceMatch(kind: "known", label: p.name.isEmpty ? "Known charger" : p.name, price: p.price)
                }
            }
        }
        let price = s.isFast ? cfg.publicDcPrice : cfg.publicAcPrice
        let label = s.address ?? (s.lat == nil ? "Unknown place" : "Away")
        return PlaceMatch(kind: s.lat == nil ? "unknown" : "public", label: label, price: price > 0 ? price : nil)
    }

    /// Battery health from charging sessions: kWh that went in per 100 %, against the battery's size when new.
    /// Uses measured sessions that added at least 15 %; needs 3. Returns (health %, sessions used).
    /// Not an official number: it depends on how exactly the car reports energy and level.
    public static func healthEstimate(_ sessions: [ChargeSession], newKwh: Double?) -> (pct: Double, sessions: Int)? {
        guard let newKwh, newKwh >= 5 else { return nil }
        let caps = sessions.filter { $0.measured && $0.endPct - $0.startPct >= 15 && $0.kwh > 0 }
            .sorted { $0.start > $1.start }
            .map { $0.kwh / (($0.endPct - $0.startPct) / 100) }
            .filter { (newKwh * 0.5...newKwh * 1.15).contains($0) }
            .prefix(20)
        guard caps.count >= 3 else { return nil }
        let sorted = caps.sorted()
        let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        return (min(100, median / newKwh * 100), caps.count)
    }
}
