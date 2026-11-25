import Foundation

/// Figures worked out from the trips and the car's counters: monthly totals, fill-ups, records, fuel cost.
public enum Stats {
    public struct Month: Identifiable, Equatable, Sendable {
        public var id: Date { start }
        public let start: Date
        public var km = 0.0, trips = 0, liters = 0.0, kmWithFuel = 0.0, kwh = 0.0, seconds = 0.0
        public var lPer100: Double? { kmWithFuel > 0 && liters > 0 ? liters / kmWithFuel * 100 : nil }
        public func cost(pricePerLiter: Double?) -> Double? { pricePerLiter.flatMap { liters > 0 ? liters * $0 : nil } }
    }

    /// Totals per calendar month, newest first.
    public static func monthly(_ trips: [Trip], calendar: Calendar = .current) -> [Month] {
        var by: [Date: Month] = [:]
        for t in trips {
            guard let d = t.start, let m = calendar.dateInterval(of: .month, for: d)?.start else { continue }
            var x = by[m] ?? Month(start: m)
            x.km += t.distanceKm; x.trips += 1; x.seconds += t.durationSec ?? 0; x.kwh += t.kwh ?? 0
            if let l = t.liters { x.liters += l; x.kmWithFuel += t.distanceKm }
            by[m] = x
        }
        return by.values.sorted { $0.start > $1.start }
    }

    public struct FillUp: Identifiable, Equatable, Sendable {
        public var id: Date { date }
        /// Between the end of one trip and the start of the next.
        public let date: Date
        public let fromPct: Double
        public let toPct: Double
        /// Estimated litres added (needs the tank size).
        public let liters: Double?
        /// Distance driven since the previous fill-up, if there was one in the period.
        public let kmSincePrevious: Double?
    }

    /// Fill-ups (or charges): the level at a trip's start is clearly higher than at the previous trip's end.
    public static func fillUps(_ trips: [Trip], tankLiters: Double?, minJump: Double = 5) -> [FillUp] {
        let sorted = trips.filter { $0.start != nil }.sorted { $0.start! < $1.start! }
        var out: [FillUp] = []
        var kmSince = 0.0
        var seenOne = false
        for (prev, cur) in zip(sorted, sorted.dropFirst()) {
            kmSince += prev.distanceKm
            guard let a = prev.endLevel, let b = cur.startLevel, b - a >= minJump else { continue }
            out.append(FillUp(date: cur.start!, fromPct: a, toPct: b, liters: tankLiters.map { (b - a) / 100 * $0 },
                              kmSincePrevious: seenOne ? kmSince : nil))
            kmSince = 0; seenOne = true
        }
        return out.reversed()
    }

    /// Tank size estimated from the fuel used against how far the gauge fell, over trips where it moved.
    /// Needs at least 10 % of gauge movement; nil otherwise or if the result isn't a plausible tank (20–100 l).
    public static func tankEstimate(_ trips: [Trip]) -> Double? {
        var liters = 0.0, drop = 0.0
        for t in trips {
            guard let l = t.liters, let a = t.startLevel, let b = t.endLevel, a > b, a < 100 else { continue }
            liters += l; drop += a - b
        }
        guard drop >= 10 else { return nil }
        let tank = liters / drop * 100
        return (20...100).contains(tank) ? tank : nil
    }

    /// Lifetime average from the car's fuel counter and odometer (l/100 km).
    public static func lifetimeLPer100(totalRaw: Double?, odometerKm: Double?, litersPerUnit: Double?) -> Double? {
        guard let total = totalRaw, let km = odometerKm, km > 0, let scale = litersPerUnit else { return nil }
        return total * scale / km * 100
    }

    public static func lifetimeLiters(totalRaw: Double?, litersPerUnit: Double?) -> Double? {
        guard let total = totalRaw, let scale = litersPerUnit else { return nil }
        return total * scale
    }

    public struct Records: Equatable, Sendable {
        public var longest: Trip?
        public var longestTime: Trip?
        /// Lowest / highest l/100 km among trips of 10 km or more.
        public var mostEfficient: Trip?
        public var leastEfficient: Trip?
        public var bestDay: (day: Date, km: Double)?
        public static func == (a: Records, b: Records) -> Bool {
            a.longest == b.longest && a.longestTime == b.longestTime && a.mostEfficient == b.mostEfficient &&
                a.leastEfficient == b.leastEfficient && a.bestDay?.day == b.bestDay?.day && a.bestDay?.km == b.bestDay?.km
        }
    }

    public static func records(_ trips: [Trip], calendar: Calendar = .current) -> Records {
        var r = Records()
        r.longest = trips.max { $0.distanceKm < $1.distanceKm }
        r.longestTime = trips.filter { $0.durationSec != nil }.max { $0.durationSec! < $1.durationSec! }
        let rated = trips.filter { $0.distanceKm >= 10 && $0.avgLPer100 != nil }
        r.mostEfficient = rated.min { $0.avgLPer100! < $1.avgLPer100! }
        r.leastEfficient = rated.max { $0.avgLPer100! < $1.avgLPer100! }
        var days: [Date: Double] = [:]
        for t in trips { if let d = t.start { days[calendar.startOfDay(for: d), default: 0] += t.distanceKm } }
        if let best = days.max(by: { $0.value < $1.value }) { r.bestDay = (best.key, best.value) }
        return r
    }
}
