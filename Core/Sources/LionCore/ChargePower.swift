import Foundation

/// Charging power in kW, range when the server says 0 km, and the battery level fix. Port of LionFlow's ChargePower.kt.
///
/// The car only reports "km of range per hour", so the power is worked out:
///  - measured: energy in the battery between two car reports (4–40 min apart) ÷ time between them
///  - estimated (until there are two reports): energy still needed ÷ time left reported by the car
///
/// Untested on a real electric car (none was available); the logic follows LionFlow line by line.
public final class ChargePower {
    public struct Reading: Equatable, Sendable {
        public let kw: Double
        public let measured: Bool
    }

    private let store: SecretStore
    private let vin: String
    /// The usable battery size the user set (kWh), if any.
    public var batteryKwhSetting: Double?

    /// Battery size assumed for an electric car when nothing better is known (also used by ChargeLog).
    static let defaultElectricKwh = 73.0
    private static let defaultHybridKwh = 11.5

    /// Plausible charging power: anything outside is a bad reading. AC charging tops out at 23 kW, fast (DC) at 250 kW.
    private static let minKw = 0.5
    private static let maxAcKw = 23.0
    private static let maxDcKw = 250.0
    /// Two samples this far apart give a measured power.
    private static let measureSpan: ClosedRange<TimeInterval> = 4 * 60...40 * 60
    /// Samples older than this are dropped; at most `maxSamples` are kept.
    private static let sampleMaxAge: TimeInterval = 45 * 60
    private static let maxSamples = 12

    /// A charging sample: when, and the energy in the battery then (kWh).
    private typealias Sample = (time: Double, kwh: Double)

    public init(store: SecretStore, vin: String, batteryKwhSetting: Double? = nil) {
        self.store = store; self.vin = vin; self.batteryKwhSetting = batteryKwhSetting
    }

    /// Store key "cp_<name>_<vin>". Saved data depends on these names.
    private func k(_ name: String) -> String { vin.isEmpty ? "cp_\(name)" : "cp_\(name)_\(vin)" }

    /// Usable battery size: the user's setting, else what the car reports (or works out from energy left and %),
    /// else a default for the car type (plug-in hybrids ~11.5 kWh, electric 73 kWh).
    public func usableKwh(_ st: VehicleStatus) -> Double {
        if let s = batteryKwhSetting, s > 0 { return s }
        if let c = st.capacityKwh, c > 1 { return c }
        if let r = st.residualKwh, let pct = st.batteryPct, pct >= 10 {
            let est = r / (pct / 100)
            if (5...150).contains(est) { return est }
        }
        return st.energyType == "Hybrid" ? Self.defaultHybridKwh : Self.defaultElectricKwh
    }

    private func energyIn(_ st: VehicleStatus) -> Double? {
        st.residualKwh ?? st.batteryPct.map { $0 / 100 * usableKwh(st) }
    }

    /// Call on every car report (it's safe to call again with the same one). Fixes a missing or 0 km range, the level
    /// drop seen on some cars, keeps just-sent schedules, and remembers charging samples. Returns the status to show.
    public func record(_ raw: VehicleStatus, now: Date = Date()) -> VehicleStatus {
        guard raw.energyType != "Fuel" else { return raw }
        let st = applyPendingPrograms(fixRange(fixLevel(raw, now: now)), now: now)
        guard st.isCharging else { store.set(k("s"), nil); return st }
        guard let time = (st.energyAt ?? st.updatedAt)?.timeIntervalSince1970, let kwh = energyIn(st) else { return st }
        var recent = samples()
        if recent.last?.time == time { return st }   // the same report again
        recent.append((time, kwh))
        recent = Array(recent.filter { time - $0.time <= Self.sampleMaxAge }.suffix(Self.maxSamples))
        store.storeJSON(k("s"), recent.map { [$0.time, $0.kwh] })
        return st
    }

    private func samples() -> [Sample] {
        guard let pairs = store.storedJSON(k("s")) as? [[Any]] else { return [] }
        return pairs.compactMap { x in
            guard x.count == 2, let t = (x[0] as? NSNumber)?.doubleValue, let e = (x[1] as? NSNumber)?.doubleValue else { return nil }
            return (t, e)
        }
    }

    /// Charging power, measured from the last reports or estimated from the time left. nil when not charging.
    public func reading(_ st: VehicleStatus?) -> Reading? {
        guard let st, st.isCharging else { return nil }
        let plausible = Self.minKw...(st.chargingMode == "Quick" ? Self.maxDcKw : Self.maxAcKw)
        if let kw = Self.measuredKw(samples()), plausible.contains(kw) { return Reading(kw: kw, measured: true) }
        guard let kw = estimatedKw(st), plausible.contains(kw) else { return nil }
        return Reading(kw: kw, measured: false)
    }

    /// Energy gained between the newest sample and the latest one 4–40 min before it, per hour.
    private static func measuredKw(_ samples: [Sample]) -> Double? {
        guard let newest = samples.last, let base = samples.last(where: { measureSpan.contains(newest.time - $0.time) })
        else { return nil }
        return (newest.kwh - base.kwh) / ((newest.time - base.time) / 3600)
    }

    /// Energy still needed to full ÷ the time left the car reports.
    private func estimatedKw(_ st: VehicleStatus) -> Double? {
        guard let rem = st.remainingMinutes, rem > 0 else { return nil }
        let need: Double
        if let r = st.residualKwh, let c = st.capacityKwh { need = c - r }
        else if let pct = st.batteryPct { need = usableKwh(st) * (100 - pct) / 100 }
        else { return nil }
        return need / (Double(rem) / 60)
    }

    /// Minutes left and the % they lead to: to [limitPct] when it is set and still ahead, otherwise the car's own time to full.
    public func timeLeft(_ st: VehicleStatus, limitPct: Int?) -> (minutes: Int, pct: Int?)? {
        guard let rem = st.remainingMinutes else { return nil }
        if let limit = limitPct, let soc = st.batteryPct, soc < Double(limit), soc < 100 {
            return (max(1, Int(Double(rem) * (Double(limit) - soc) / (100 - soc))), limit)
        }
        return (rem, nil)
    }

    /// An electric car can suddenly report a much lower level with the same energy in the battery (an E-5008 went
    /// from 89 % to 79 % when its daily limit was switched back on, with 68.5 kWh both times). Only when exactly that
    /// is seen — a drop of 5 points or more while the energy stays put — the level from before the drop is kept and
    /// moved by the change in energy, until the car's own number catches up.
    private func fixLevel(_ st: VehicleStatus, now: Date) -> VehicleStatus {
        guard st.energyType == "Electric", let level = st.batteryPct, let res = st.residualKwh, let cap = st.capacityKwh, cap >= 30
        else { return st }
        // "lvl" = level,kWh of the previous report; "lvlAnchor" = level,kWh,time from just before a drop.
        let previous = numbers(k("lvl"))
        var anchor = numbers(k("lvlAnchor"))
        if previous.count == 2, previous[0] - level >= 5, abs(previous[1] - res) < 1 {
            anchor = [previous[0], previous[1], now.timeIntervalSince1970]
        }
        var out = st
        if anchor.count == 3 {
            let est = anchor[0] + (res - anchor[1]) / cap * 100
            // Let go after 3 days, once the car's level is back within 2 points, or if the estimate goes past full.
            if now.timeIntervalSince1970 - anchor[2] > 3 * 86_400 || est - level <= 2 || est > 100.5 { anchor = [] }
            else { out.batteryPct = est.rounded() }
        }
        store.set(k("lvl"), "\(level),\(res)")
        store.set(k("lvlAnchor"), anchor.map { String($0) }.joined(separator: ","))
        return out
    }

    /// Comma-separated numbers kept under [key] (empty when missing).
    private func numbers(_ key: String) -> [Double] {
        (store.get(key) ?? "").split(separator: ",").compactMap { Double($0) }
    }

    /// The server sometimes reports 0 km range (often when plugged in or asleep) even with a full battery. Then use
    /// km-per-% learnt from the last real reading, or a plain estimate (usable kWh at ~19 kWh/100 km).
    private func fixRange(_ st: VehicleStatus) -> VehicleStatus {
        guard let pct = st.batteryPct else { return st }
        if let range = st.rangeKm, range > 0 {
            // A real reading: learn km per % from it (from 5 % up, and only a plausible 1–10 km).
            if pct >= 5 {
                let perPct = range / pct
                if (1...10).contains(perPct) { store.set(k("kmPerPct"), String(perPct)) }
            }
            return st
        }
        guard pct >= 1 else { return st }
        let perPct = Double(store.get(k("kmPerPct")) ?? "").flatMap { $0 > 0 ? $0 : nil } ?? usableKwh(st) / 19
        var out = st
        out.rangeKm = (pct * perPct).rounded()
        out.rangeEstimated = true
        return out
    }

    // MARK: Pre-heating schedules just sent

    /// How long schedules just sent are shown before the car's own list is trusted again.
    private static let pendingMaxAge: TimeInterval = 2 * 3600

    private static func programKey(_ p: Program) -> String { "\(p.days.sorted().joined(separator: ","))|\(p.hour)|\(p.minute)|\(p.enabled)" }

    /// Remember schedules sent to the car; its status can show the old ones for a while.
    public func setPendingPrograms(_ list: [Program], now: Date = Date()) {
        let j: JSON = ["time": now.timeIntervalSince1970,
                       "programs": list.map { ["slot": $0.slot, "days": $0.days, "hour": $0.hour, "minute": $0.minute, "on": $0.enabled] as JSON }]
        store.storeJSON(k("pending"), j)
    }

    public func pendingPrograms(now: Date = Date()) -> [Program]? {
        guard let j = store.storedJSON(k("pending")) as? JSON, let t = j.num("time") else { return nil }
        if now.timeIntervalSince1970 - t > Self.pendingMaxAge { store.set(k("pending"), nil); return nil }
        return j.objects("programs").map {
            Program(slot: Int($0.num("slot") ?? 0), days: $0.strings("days"), hour: Int($0.num("hour") ?? 0),
                    minute: Int($0.num("minute") ?? 0), enabled: $0.bool("on") ?? false)
        }
    }

    /// Until the car's status shows the new schedules, show the ones sent. If the car's list changes to something
    /// that is neither the old nor the new one, someone else edited them: show the car's list.
    private func applyPendingPrograms(_ st: VehicleStatus, now: Date) -> VehicleStatus {
        guard let sent = pendingPrograms(now: now), var pending = store.storedJSON(k("pending")) as? JSON else { return st }
        let car = Set(st.programs.map(Self.programKey)), want = Set(sent.map(Self.programKey))
        if car == want { store.set(k("pending"), nil); return st }
        // "base" is the car's list as first seen after sending: the old schedules.
        let carKey = car.sorted().joined(separator: ";")
        let base = pending.optString("base")
        if base.isEmpty { pending["base"] = carKey; store.storeJSON(k("pending"), pending) }
        else if base != carKey { store.set(k("pending"), nil); return st }
        var out = st
        out.programs = sent
        return out
    }
}

// MARK: JSON in the store

// Shared by ChargePower and ChargeLog. Each kind of value keeps the format it was saved in: plain JSON objects go
// through JSONSerialization (sorted keys), Codable values through JSONEncoder.
extension SecretStore {
    func storedJSON(_ key: String) -> Any? { get(key).flatMap { JSONValue.parse($0) } }

    /// Saves [object] as JSON text, or removes the key when it is nil.
    func storeJSON(_ key: String, _ object: Any?) {
        set(key, object.map { String(decoding: JSONValue.data($0), as: UTF8.self) })
    }

    func storedCodable<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let s = get(key), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    /// Saves [value] as JSON text (the key is removed if encoding fails).
    func storeCodable<T: Encodable>(_ key: String, _ value: T) {
        set(key, (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) })
    }
}
