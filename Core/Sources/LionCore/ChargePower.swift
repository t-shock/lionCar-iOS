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

    public init(store: SecretStore, vin: String, batteryKwhSetting: Double? = nil) {
        self.store = store; self.vin = vin; self.batteryKwhSetting = batteryKwhSetting
    }

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
        return st.energyType == "Hybrid" ? 11.5 : 73
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
        guard let t = (st.energyAt ?? st.updatedAt)?.timeIntervalSince1970, let e = energyIn(st) else { return st }
        var arr = samples()
        if arr.last?.0 == t { return st }
        arr.append((t, e))
        arr = Array(arr.filter { t - $0.0 <= 45 * 60 }.suffix(12))
        store.set(k("s"), String(decoding: JSONValue.data(arr.map { [$0.0, $0.1] }), as: UTF8.self))
        return st
    }

    private func samples() -> [(Double, Double)] {
        guard let s = store.get(k("s")), let a = JSONValue.parse(s) as? [[Any]] else { return [] }
        return a.compactMap { x in
            guard x.count == 2, let t = (x[0] as? NSNumber)?.doubleValue, let e = (x[1] as? NSNumber)?.doubleValue else { return nil }
            return (t, e)
        }
    }

    /// Charging power, measured from the last reports or estimated from the time left. nil when not charging.
    public func reading(_ st: VehicleStatus?) -> Reading? {
        guard let st, st.isCharging else { return nil }
        let max = st.chargingMode == "Quick" ? 250.0 : 23.0
        let s = samples()
        if let newest = s.last, let base = s.last(where: { (4 * 60...40 * 60).contains(newest.0 - $0.0) }) {
            let kw = (newest.1 - base.1) / ((newest.0 - base.0) / 3600)
            if (0.5...max).contains(kw) { return Reading(kw: kw, measured: true) }
        }
        guard let rem = st.remainingMinutes, rem > 0 else { return nil }
        let need: Double
        if let r = st.residualKwh, let c = st.capacityKwh { need = c - r }
        else if let pct = st.batteryPct { need = usableKwh(st) * (100 - pct) / 100 }
        else { return nil }
        let kw = need / (Double(rem) / 60)
        return (0.5...max).contains(kw) ? Reading(kw: kw, measured: false) : nil
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
        let last = (store.get(k("lvl")) ?? "").split(separator: ",").compactMap { Double($0) }
        var anchor = (store.get(k("lvlAnchor")) ?? "").split(separator: ",").compactMap { Double($0) }
        if last.count == 2, last[0] - level >= 5, abs(last[1] - res) < 1 { anchor = [last[0], last[1], now.timeIntervalSince1970] }
        var out = st
        if anchor.count == 3 {
            let est = anchor[0] + (res - anchor[1]) / cap * 100
            if now.timeIntervalSince1970 - anchor[2] > 3 * 86_400 || est - level <= 2 || est > 100.5 { anchor = [] }
            else { out.batteryPct = est.rounded() }
        }
        store.set(k("lvl"), "\(level),\(res)")
        store.set(k("lvlAnchor"), anchor.map { String($0) }.joined(separator: ","))
        return out
    }

    /// The server sometimes reports 0 km range (often when plugged in or asleep) even with a full battery. Then use
    /// km-per-% learnt from the last real reading, or a plain estimate (usable kWh at ~19 kWh/100 km).
    private func fixRange(_ st: VehicleStatus) -> VehicleStatus {
        guard let pct = st.batteryPct else { return st }
        if let range = st.rangeKm, range > 0, pct >= 5 {
            let perPct = range / pct
            if (1...10).contains(perPct) { store.set(k("kmPerPct"), String(perPct)) }
            return st
        }
        if let range = st.rangeKm, range > 0 { return st }
        guard pct >= 1 else { return st }
        let perPct = Double(store.get(k("kmPerPct")) ?? "").flatMap { $0 > 0 ? $0 : nil } ?? usableKwh(st) / 19
        var out = st
        out.rangeKm = (pct * perPct).rounded()
        out.rangeEstimated = true
        return out
    }

    // MARK: Pre-heating schedules just sent

    private static func key(_ p: Program) -> String { "\(p.days.sorted().joined(separator: ","))|\(p.hour)|\(p.minute)|\(p.enabled)" }

    /// Remember schedules sent to the car; its status can show the old ones for a while.
    public func setPendingPrograms(_ list: [Program], now: Date = Date()) {
        let j: JSON = ["time": now.timeIntervalSince1970,
                       "programs": list.map { ["slot": $0.slot, "days": $0.days, "hour": $0.hour, "minute": $0.minute, "on": $0.enabled] as JSON }]
        store.set(k("pending"), String(decoding: JSONValue.data(j), as: UTF8.self))
    }

    public func pendingPrograms(now: Date = Date()) -> [Program]? {
        guard let s = store.get(k("pending")), let j = JSONValue.parse(s) as? JSON, let t = j.num("time") else { return nil }
        if now.timeIntervalSince1970 - t > 2 * 3600 { store.set(k("pending"), nil); return nil }
        return j.objects("programs").map {
            Program(slot: Int($0.num("slot") ?? 0), days: $0.strings("days"), hour: Int($0.num("hour") ?? 0),
                    minute: Int($0.num("minute") ?? 0), enabled: $0.bool("on") ?? false)
        }
    }

    /// Until the car's status shows the new schedules, show the ones sent. If the car's list changes to something
    /// that is neither the old nor the new one, someone else edited them: show the car's list.
    private func applyPendingPrograms(_ st: VehicleStatus, now: Date) -> VehicleStatus {
        guard let pend = pendingPrograms(now: now), let s = store.get(k("pending")), var raw = JSONValue.parse(s) as? JSON else { return st }
        let car = Set(st.programs.map(Self.key)), want = Set(pend.map(Self.key))
        if car == want { store.set(k("pending"), nil); return st }
        let carKey = car.sorted().joined(separator: ";")
        let base = raw.optString("base")
        if base.isEmpty { raw["base"] = carKey; store.set(k("pending"), String(decoding: JSONValue.data(raw), as: UTF8.self)) }
        else if base != carKey { store.set(k("pending"), nil); return st }
        var out = st
        out.programs = pend
        return out
    }
}
