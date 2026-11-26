import Foundation

/// Demo mode: a sample car with made-up data, for trying LionCar without such a car (or without an account).
/// Nothing is sent anywhere; commands only change the sample car. Port of LionFlow's Demo.kt, including its choice of
/// an electric car, a plug-in hybrid or a petrol / diesel car, of any brand.
public final class DemoCar {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case electric, hybrid, fuel
        public var id: String { rawValue }
    }

    public static let vin = "VR3DEMOLIONCAR001"
    static let home = (lat: 48.8566, lon: 2.3522)   // a neutral spot in Paris
    /// Where the sample car drives to and charges at work.
    private static let work = (lat: home.lat + 0.03, lon: home.lon + 0.04)
    private static let odometerKm = 13_412.0
    /// The tank of the hybrid and the petrol / diesel sample car.
    static let fuelPct = 58.0, fuelRange = 530.0

    public let kind: Kind
    public let brand: Brand
    public var battery = 64.0
    public var locked = true
    public var preconditioning = false
    public var charging = true
    public var plugged = true
    public var chargeType = "Partial"
    /// The car waits for its scheduled (delayed) start at 01:00.
    public var scheduledStart = true
    public var programs = [
        Program(slot: 1, days: ["Mon", "Tue", "Wed", "Thu", "Fri"], hour: 7, minute: 15, enabled: true),
        Program(slot: 2, days: ["Sat"], hour: 9, minute: 0, enabled: false),
    ]

    public init(kind: Kind = .electric, brand: Brand = .peugeot) {
        self.kind = kind; self.brand = brand
        if kind == .fuel { charging = false; plugged = false }
    }

    public var vehicle: Vehicle {
        Vehicle(id: "demo", vin: Self.vin, motorization: kind == .fuel ? "Thermal" : (kind == .hybrid ? "PHEV" : "Electric"),
                brand: brand.display)
    }

    /// A plug-in hybrid has a small battery: about 12 kWh and 55 km when full, charged at 3.7 kW.
    private var capacityKwh: Double { kind == .hybrid ? 12.4 : 73 }
    private var evRange: Double { kind == .hybrid ? battery * 0.55 : battery * 4.3 }

    /// The sample car's status, in the shape the brand's server sends (so the normal parsing is used).
    public func statusJSON(now: Date = Date()) -> JSON {
        let at = ISODate.format(now.addingTimeInterval(-120))
        var energies: [JSON] = []
        if kind != .fuel { energies.append(electricEnergy(updatedAt: at)) }
        if kind != .electric { energies.append(fuelEnergy(updatedAt: at)) }
        var j: JSON = [
            "updatedAt": at,
            "lastPosition": ["type": "Feature", "geometry": ["type": "Point", "coordinates": [Self.home.lon, Self.home.lat]] as JSON,
                             "properties": ["heading": 118, "signalQuality": 8] as JSON] as JSON,
            "doorsState": ["lockedStates": [locked ? "Locked" : "Unlocked"], "opening": [] as [Any]] as JSON,
            "environment": ["air": ["temp": 6.0] as JSON] as JSON,
            "odometer": ["mileage": Self.odometerKm] as JSON,
            "battery": ["voltage": 12.6] as JSON,
            "ignition": ["type": "Stop"] as JSON,
            "kinetic": ["speed": 0.0, "moving": false] as JSON,
            "privacy": ["state": "None"] as JSON,
            "alarm": ["status": ["activation": "Active"] as JSON] as JSON,
            "lightingSystem": ["fog": [["direction": "Front", "status": "Off"] as JSON]] as JSON,
            "energies": energies,
            "maintenance": ["mileageBeforeMaintenance": 11_588, "daysBeforeMaintenance": 270] as JSON,
        ]
        if kind == .fuel {
            j["engines"] = [["type": "Thermic", "extension": ["thermic": ["coolant": ["temp": 21.0] as JSON] as JSON] as JSON] as JSON]
            j["drivingBehavior"] = ["mode": "Normal"] as JSON
            j["transmission"] = ["gearbox": ["mode": "Auto"] as JSON] as JSON
        } else {
            // Petrol and diesel cars have no remote pre-heating, so the Pre-heating card is left out for them, as on a real one.
            j["preconditioning"] = ["airConditioning": preconditioningJSON] as JSON
        }
        return j
    }

    /// The traction battery and its charging state.
    private func electricEnergy(updatedAt at: String) -> JSON {
        let on = charging && plugged
        var charge: JSON = ["plugged": plugged, "status": on ? "InProgress" : (plugged ? "Stopped" : "Disconnected"),
                            "chargingMode": on ? "Slow" : "No", "type": chargeType]
        if scheduledStart { charge["nextDelayedTime"] = "PT1H0M" }
        if on {
            charge["chargingRate"] = kind == .hybrid ? 16 : 48
            let mins = kind == .hybrid ? Int(max(0, 100 - battery) * 2) : Int(max(0, 80 - battery) * 9)
            charge["remainingTime"] = "PT\(mins / 60)H\(mins % 60)M"
        }
        return [
            "type": "Electric", "level": battery.rounded(), "autonomy": evRange.rounded(), "updatedAt": at,
            "extension": ["electric": [
                "charging": charge,
                "battery": ["load": ["capacity": Int(capacityKwh * 1000), "residual": Int(battery / 100 * capacityKwh * 1000)] as JSON,
                            "health": ["capacity": 98] as JSON] as JSON,
            ] as JSON] as JSON,
        ]
    }

    /// The tank of the hybrid and the petrol / diesel car.
    private func fuelEnergy(updatedAt at: String) -> JSON {
        // The lifetime fuel counter, in hundredths of a litre: 5.9 l/100 km since new (3.6 for the plug-in hybrid).
        let total = Self.odometerKm * (kind == .fuel ? 5.9 : 3.6)
        return ["type": "Fuel", "level": Self.fuelPct, "autonomy": Self.fuelRange, "updatedAt": at,
                "extension": ["fuel": ["consumptions": ["total": total, "instant": kind == .fuel ? 6.1 : 4.2] as JSON] as JSON] as JSON]
    }

    private var preconditioningJSON: JSON {
        let progs: [JSON] = programs.map {
            ["slot": $0.slot, "enabled": $0.enabled, "start": "PT\($0.hour)H\($0.minute)M", "occurence": ["day": $0.days] as JSON]
        }
        return ["status": preconditioning ? "Enabled" : "Disabled", "programs": progs]
    }

    /// Applies a simulated command to the sample car.
    public func apply(_ command: String, programs newPrograms: [Program]? = nil) {
        switch command {
        case "lock": locked = true
        case "unlock": locked = false
        case "precondOn": preconditioning = true
        case "precondOff": preconditioning = false
        case "chargeNow": plugged = true; charging = true; scheduledStart = false
        case "chargeStop": charging = false; scheduledStart = true
        case "clearSchedule": scheduledStart = false; if plugged { charging = true }
        case "limitDaily": chargeType = "Partial"
        case "limitFull": chargeType = "Full"
        default: break
        }
        if let newPrograms { programs = newPrograms }
    }

    /// Made-up trips in the server's shape: a month for the electric car; four months for the other two, so fuel cost,
    /// fill-ups and records have something to show. The plug-in hybrid drives the first 40 km of a trip on the battery.
    public func tripsJSON(now: Date = Date()) -> [JSON] {
        var rng = SeededRandom(seed: 42)
        let drives = makeDrives(days: kind == .electric ? 30 : 120, now: now, rng: &rng)
        // The gauge before and after each trip (the battery for the electric car, the tank otherwise), with a fill-up
        // whenever the tank gets low.
        let tank = kind == .hybrid ? 43.0 : 47.0
        var level = kind == .electric ? 90.0 : 82.0
        var out: [JSON] = []
        for (n, drive) in drives.enumerated() {
            if kind == .electric && level < 30 { level = 80 }
            if kind != .electric && level < 18 { level = 95 + rng.next(0, 5).rounded(.down) }
            let used = kind == .electric ? (drive.kwh ?? 0) / capacityKwh * 100 : (drive.liters ?? 0) / tank * 100
            let after = max(3, level - used)
            out.append(tripJSON(n, drive, levelFrom: level, to: after))
            level = after
        }
        return out
    }

    private struct Drive {
        let start: Date
        let km: Double
        let seconds: Double
        let kwh: Double?
        let liters: Double?
    }

    /// One to three drives a day, from 7:00, mostly short, now and then a long one at a higher speed.
    /// The random draws must stay in this order: the demo data depends on it.
    private func makeDrives(days: Int, now: Date, rng: inout SeededRandom) -> [Drive] {
        let day: TimeInterval = 86_400
        let first = now.addingTimeInterval(-Double(days) * day)
        var drives: [Drive] = []
        for d in 0..<days {
            for i in 0..<Int(rng.next(1, 4)) {
                let t = first.addingTimeInterval(Double(d) * day + (7 + Double(i) * 5 + rng.next(0, 3)) * 3600 + rng.next(0, 50) * 60)
                let long = Int(rng.next(0, 10)) == 0
                let km = long ? rng.next(60, 140).rounded() : (rng.next(3, 28) * 10).rounded() / 10
                let speed = km > 50 ? rng.next(70, 95) : rng.next(28, 55)
                let seconds = km / speed * 3600
                let per100 = rng.next(15.5, 21)   // kWh/100 km on the battery (drawn for every car, even the petrol one)
                switch kind {
                case .electric:
                    drives.append(Drive(start: t, km: km, seconds: seconds, kwh: km * per100 / 100, liters: nil))
                case .fuel:
                    let l100 = km > 50 ? rng.next(4.6, 5.8) : rng.next(5.6, 8.4)
                    drives.append(Drive(start: t, km: km, seconds: seconds, kwh: nil, liters: km * l100 / 100))
                case .hybrid:
                    let evKm = min(km, 40)
                    let liters = km > evKm ? (km - evKm) * rng.next(5.8, 6.8) / 100 : nil
                    drives.append(Drive(start: t, km: km, seconds: seconds, kwh: evKm * per100 / 100, liters: liters))
                }
            }
        }
        return drives
    }

    /// One trip from home to work, with the gauge going from [levelFrom] to [to] %.
    private func tripJSON(_ n: Int, _ drive: Drive, levelFrom level: Double, to after: Double) -> JSON {
        let type = kind == .electric ? "Electric" : "Fuel"
        let kmPerPct = kind == .electric ? 4.3 : 9.1
        var cons: [JSON] = []
        if let k = drive.kwh { cons.append(["type": "Electric", "consumption": k * 1000, "avgConsumption": k / drive.km * 100 * 1000]) }
        if let l = drive.liters { cons.append(["type": "Fuel", "consumption": l * 100, "avgConsumption": l / drive.km * 100 * 100]) }
        return [
            "id": "demo-\(n)", "startedAt": ISODate.format(drive.start),
            "stoppedAt": ISODate.format(drive.start.addingTimeInterval(drive.seconds)),
            "duration": drive.seconds.rounded(), "distance": drive.km, "energyConsumptions": cons,
            "startEnergies": [["type": type, "level": level.rounded(), "autonomy": (level * kmPerPct).rounded()] as JSON],
            "endEnergies": [["type": type, "level": after.rounded(), "autonomy": (after * kmPerPct).rounded()] as JSON],
            "startPosition": ["geometry": ["coordinates": [Self.home.lon, Self.home.lat]] as JSON] as JSON,
            "stopPosition": ["geometry": ["coordinates": [Self.work.lon, Self.work.lat]] as JSON] as JSON,
        ]
    }

    public static func places() -> PlacesConfig {
        var p = PlacesConfig()
        p.home = ChargePlace(id: "home", name: "Home", lat: home.lat, lon: home.lon, price: 0.25)
        p.known = [ChargePlace(id: "k1", name: "Work", lat: work.lat, lon: work.lon, price: 0)]
        p.publicAcPrice = 0.45
        p.publicDcPrice = 0.69
        return p
    }

    private enum ChargeSpot { case home, work, fastCharger }

    /// Charging sessions for the log: none for the petrol / diesel car; the plug-in hybrid only charges slowly, at home
    /// and at work.
    public func sessions(now: Date = Date()) -> [ChargeSession] {
        guard kind != .fuel else { return [] }
        let hybrid = kind == .hybrid
        var rng = SeededRandom(seed: 7)
        return (1...14).map { i in
            let spot: ChargeSpot = i % 5 == 0 ? (hybrid ? .home : .fastCharger) : (i % 5 == 3 ? .work : .home)
            let fast = spot == .fastCharger
            let s = now.timeIntervalSince1970 - Double(i) * 2 * 86_400 - rng.next(0, 6) * 3600
            let from = rng.next(18, 50)
            let to = fast ? rng.next(70, 82) : (hybrid ? 100 : 80)
            let kwh = (to - from) / 100 * capacityKwh
            let kw = fast ? rng.next(70, 110) : (hybrid ? rng.next(3.3, 3.7) : rng.next(6.5, 10.5))
            let (lat, lon, addr): (Double, Double, String) = switch spot {
            case .home: (Self.home.lat, Self.home.lon, "Sample street 1, Paris")
            case .work: (Self.work.lat, Self.work.lon, "Office car park")
            case .fastCharger: (Self.home.lat + 0.4, Self.home.lon - 0.3, "Motorway services A10")
            }
            return ChargeSession(start: s, end: s + kwh / kw * 3600, startPct: from.rounded(), endPct: to.rounded(), kwh: kwh,
                                 peakKw: kw * 1.15, mode: fast ? "Quick" : "Slow", lat: lat, lon: lon, address: addr, measured: true)
        }
    }
}

/// Small repeatable random numbers for the demo data. Adding, removing or reordering draws changes the demo data.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next(_ lo: Double, _ hi: Double) -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return lo + Double(state % 1_000_000) / 1_000_000 * (hi - lo)
    }
}
