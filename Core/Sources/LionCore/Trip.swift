import Foundation

/// One trip as the car reports it. Port of LionFlow's `Trip`, plus positions and a per-car fuel calibration.
public struct Trip: Identifiable, Equatable, Sendable {
    public let id: String
    public let start: Date?
    public let end: Date?
    public let distanceKm: Double
    public let durationSec: Double?
    public let kwh: Double?
    public let avgKwhPer100: Double?
    public let avgSpeedKmh: Double?
    public let maxSpeedKmh: Double?
    public let liters: Double?
    public let avgLPer100: Double?
    public let startLat: Double?, startLon: Double?
    public let stopLat: Double?, stopLon: Double?
    /// The car lost its connection during the trip, so some figures may be missing.
    public let dataLacking: Bool
    /// Tank / battery level (%) and range (km) at the start and end, for the car's main energy.
    public var startLevel: Double? = nil
    public var endLevel: Double? = nil
    public var startRangeKm: Double? = nil
    public var endRangeKm: Double? = nil
    public var startMileage: Double? = nil

    /// Peugeot doesn't document fuel units; pick the scale that gives a sane l/100 km (2–30).
    static func litersOf(_ raw: Double?, km: Double) -> Double? {
        guard let raw, raw > 0, km >= 0.5 else { return nil }
        return [1.0, 0.01, 0.001].map { raw * $0 }.first { (2.0...30.0).contains($0 / km * 100) }
    }

    static func per100Of(_ raw: Double?) -> Double? {
        guard let raw, raw > 0 else { return nil }
        return [1.0, 0.1, 0.01, 0.001].map { raw * $0 }.first { (2.0...30.0).contains($0) }
    }

    /// - Parameter litersPerUnit: the car's fuel unit in litres, when known from [FuelCalibration]; otherwise LionFlow's guess.
    public static func parse(_ t: JSON, mildHybrid: Bool = false, litersPerUnit: Double? = nil) -> Trip {
        let cons = t.objects("energyConsumptions")
        let electric = mildHybrid ? nil : cons.first { $0.optString("type") == "Electric" }
        let fuel = cons.first { $0.optString("type") == "Fuel" }
        let km = t.num("distance") ?? 0
        let rawFuel = fuel?.num("consumption")
        let liters: Double?
        if let scale = litersPerUnit, let rawFuel, rawFuel > 0, km >= 0.5 { liters = rawFuel * scale }
        else { liters = litersOf(rawFuel, km: km) }
        let duration = t.num("duration")
        // Work it out from distance and time: the car's own "avgSpeed" is in m/s on some models and km/h on others.
        let avgSpeed: Double? = {
            if let d = duration, d >= 60, km > 0 { return km / (d / 3600) }
            return km > 0 ? t.obj("kinetic")?.num("avgSpeed") : nil
        }()
        func point(_ key: String, _ i: Int) -> Double? {
            guard let c = t.obj(key, "geometry")?["coordinates"] as? [Any], c.count > i else { return nil }
            return (c[i] as? NSNumber)?.doubleValue
        }
        return Trip(
            id: t.optString("id"),
            start: ISODate.parse(t.str("startedAt") ?? t.str("createdAt")),
            end: ISODate.parse(t.str("stoppedAt")),
            distanceKm: km, durationSec: duration,
            kwh: electric?.num("consumption").map { $0 / 1000 },
            avgKwhPer100: electric?.num("avgConsumption").map { $0 / 1000 },
            avgSpeedKmh: avgSpeed, maxSpeedKmh: t.obj("kinetic")?.num("maxSpeed"),
            liters: liters,
            // Work it out from fuel used and distance; the car's own average comes in different units.
            avgLPer100: liters.map { $0 / km * 100 } ?? per100Of(fuel?.num("avgConsumption")),
            startLat: point("startPosition", 1), startLon: point("startPosition", 0),
            stopLat: point("stopPosition", 1), stopLon: point("stopPosition", 0),
            dataLacking: t.objects("faults").contains { $0.optString("fault") == "DataLacking" },
            startLevel: level(t, "startEnergies", "level", electric: electric != nil),
            endLevel: level(t, "endEnergies", "level", electric: electric != nil),
            startRangeKm: level(t, "startEnergies", "autonomy", electric: electric != nil),
            endRangeKm: level(t, "endEnergies", "autonomy", electric: electric != nil),
            startMileage: t.num("startMileage"))
    }

    /// Level or range at a trip's start or end: the battery for electric trips, otherwise the tank.
    private static func level(_ t: JSON, _ key: String, _ field: String, electric: Bool) -> Double? {
        let list = t.objects(key)
        let main = list.first { $0.optString("type") == (electric ? "Electric" : "Fuel") }
        return main?.num(field) ?? list.first { $0.num(field) != nil }?.num(field)
    }
}

/// Works out the car's fuel unit from its lifetime fuel counter and odometer. LionFlow guesses the unit per trip,
/// which reads about 2.5× too high on cars whose unit is about 4 ml (seen on some 48 V mild hybrids).
public enum FuelCalibration {
    /// Scales tried in order: the usual ones first, the ~4 ml unit last.
    static let candidates: [Double] = [0.01, 0.001, 1, 0.1, 0.004]

    /// Litres per raw unit, or nil when there's too little driving to tell or no scale gives a sane lifetime average (3–12 l/100 km).
    public static func litersPerUnit(totalRaw: Double?, odometerKm: Double?) -> Double? {
        guard let total = totalRaw, total > 0, let km = odometerKm, km >= 300 else { return nil }
        return candidates.first { (3.0...12.0).contains(total * $0 / km * 100) }
    }
}
