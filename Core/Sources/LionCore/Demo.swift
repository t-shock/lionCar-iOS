import Foundation

/// Demo mode: a sample electric car with made-up data, for trying LionCar (and seeing the electric-car screens)
/// without such a car. Nothing is sent anywhere; commands only change the sample car. Port of LionFlow's Demo.kt.
public final class DemoCar {
    public static let vin = "VR3DEMOLIONCAR001"
    public static let vehicle = Vehicle(id: "demo", vin: vin, motorization: "Electric", brand: "Peugeot")
    static let home = (lat: 48.8566, lon: 2.3522)   // a neutral spot in Paris

    public var battery = 64.0
    public var locked = true
    public var preconditioning = false
    public var charging = true
    public var plugged = true
    public var chargeType = "Partial"
    public var programs = [
        Program(slot: 1, days: ["Mon", "Tue", "Wed", "Thu", "Fri"], hour: 7, minute: 15, enabled: true),
        Program(slot: 2, days: ["Sat"], hour: 9, minute: 0, enabled: false),
    ]

    public init() {}

    /// The sample car's status, in the shape the brand's server sends (so the normal parsing is used).
    public func statusJSON(now: Date = Date()) -> JSON {
        let at = ISODate.format(now.addingTimeInterval(-120))
        var charge: JSON = ["plugged": plugged, "status": charging ? "InProgress" : (plugged ? "Stopped" : "Disconnected"),
                            "chargingMode": charging ? "Slow" : "No", "type": chargeType, "nextDelayedTime": "PT1H0M"]
        if charging {
            charge["chargingRate"] = 48
            charge["remainingTime"] = "PT\(Int(max(0, 100 - battery) * 9) / 60)H\(Int(max(0, 100 - battery) * 9) % 60)M"
        }
        let progs: [JSON] = programs.map {
            ["slot": $0.slot, "enabled": $0.enabled, "start": "PT\($0.hour)H\($0.minute)M", "occurence": ["day": $0.days] as JSON]
        }
        return [
            "updatedAt": at,
            "lastPosition": ["type": "Feature", "geometry": ["type": "Point", "coordinates": [Self.home.lon, Self.home.lat]] as JSON,
                             "properties": ["heading": 180, "signalQuality": 8] as JSON] as JSON,
            "doorsState": ["lockedStates": [locked ? "Locked" : "Unlocked"], "opening": [] as [Any]] as JSON,
            "environment": ["air": ["temp": 6.0] as JSON] as JSON,
            "odometer": ["mileage": 13_412.0] as JSON,
            "ignition": ["type": "Stop"] as JSON,
            "kinetic": ["speed": 0.0, "moving": false] as JSON,
            "privacy": ["state": "None"] as JSON,
            "preconditioning": ["airConditioning": ["status": preconditioning ? "Enabled" : "Disabled", "programs": progs] as JSON] as JSON,
            "energies": [[
                "type": "Electric", "level": battery.rounded(), "autonomy": (battery * 4.3).rounded(), "updatedAt": at,
                "extension": ["electric": [
                    "charging": charge,
                    "battery": ["load": ["capacity": 73_000, "residual": Int(battery / 100 * 73_000)] as JSON,
                                "health": ["capacity": 98] as JSON] as JSON,
                ] as JSON] as JSON,
            ] as JSON],
            "maintenance": ["mileageBeforeMaintenance": 11_588, "daysBeforeMaintenance": 270] as JSON,
        ]
    }

    /// Applies a simulated command to the sample car.
    public func apply(_ command: String, programs newPrograms: [Program]? = nil) {
        switch command {
        case "lock": locked = true
        case "unlock": locked = false
        case "precondOn": preconditioning = true
        case "precondOff": preconditioning = false
        case "chargeNow": plugged = true; charging = true
        case "chargeStop": charging = false
        case "limitDaily": chargeType = "Partial"
        case "limitFull": chargeType = "Full"
        default: break
        }
        if let newPrograms { programs = newPrograms }
    }

    /// A month of made-up trips, in the server's shape.
    public static func tripsJSON(now: Date = Date()) -> [JSON] {
        var rng = SeededRandom(seed: 42)
        let day: TimeInterval = 86_400
        let start = now.addingTimeInterval(-30 * day)
        var out: [JSON] = []
        for d in 0..<30 {
            for i in 0..<Int(rng.next(1, 4)) {
                let t = start.addingTimeInterval(Double(d) * day + (7 + Double(i) * 5 + rng.next(0, 3)) * 3600 + rng.next(0, 50) * 60)
                let km = Int(rng.next(0, 10)) == 0 ? rng.next(60, 140) : rng.next(3, 28)
                let speed = km > 50 ? rng.next(70, 95) : rng.next(28, 55)
                let sec = km / speed * 3600
                let per100 = rng.next(15.5, 21)
                let level = rng.next(40, 90)
                out.append([
                    "id": "demo-\(d)-\(i)", "startedAt": ISODate.format(t), "stoppedAt": ISODate.format(t.addingTimeInterval(sec)),
                    "duration": sec, "distance": (km * 10).rounded() / 10,
                    "energyConsumptions": [["type": "Electric", "consumption": km * per100 / 100 * 1000, "avgConsumption": per100 * 1000] as JSON],
                    "startEnergies": [["type": "Electric", "level": level.rounded(), "autonomy": (level * 4.3).rounded()] as JSON],
                    "endEnergies": [["type": "Electric", "level": (level - km * per100 / 73).rounded(), "autonomy": ((level - km * per100 / 73) * 4.3).rounded()] as JSON],
                    "startPosition": ["geometry": ["coordinates": [home.lon, home.lat]] as JSON] as JSON,
                    "stopPosition": ["geometry": ["coordinates": [home.lon + 0.04, home.lat + 0.03]] as JSON] as JSON,
                ])
            }
        }
        return out
    }

    public static func places() -> PlacesConfig {
        var p = PlacesConfig()
        p.home = ChargePlace(id: "home", name: "Home", lat: home.lat, lon: home.lon, price: 0.25)
        p.known = [ChargePlace(id: "k1", name: "Work", lat: home.lat + 0.03, lon: home.lon + 0.04, price: 0)]
        p.publicAcPrice = 0.45
        p.publicDcPrice = 0.69
        return p
    }

    public static func sessions(now: Date = Date()) -> [ChargeSession] {
        var rng = SeededRandom(seed: 7)
        return (1...14).map { i in
            let place = i % 5 == 0 ? 2 : (i % 5 == 3 ? 1 : 0)   // 0 home, 1 work, 2 fast charger
            let s = now.timeIntervalSince1970 - Double(i) * 2 * 86_400 - rng.next(0, 6) * 3600
            let from = rng.next(18, 50)
            let to = place == 2 ? rng.next(70, 82) : 80
            let kwh = (to - from) / 100 * 73
            let kw = place == 2 ? rng.next(70, 110) : rng.next(6.5, 10.5)
            let (lat, lon, addr): (Double, Double, String) = switch place {
            case 0: (home.lat, home.lon, "Sample street 1, Paris")
            case 1: (home.lat + 0.03, home.lon + 0.04, "Office car park")
            default: (home.lat + 0.4, home.lon - 0.3, "Motorway services A10")
            }
            return ChargeSession(start: s, end: s + kwh / kw * 3600, startPct: from.rounded(), endPct: to.rounded(), kwh: kwh,
                                 peakKw: kw * 1.15, mode: place == 2 ? "Quick" : "Slow", lat: lat, lon: lon, address: addr, measured: true)
        }
    }
}

/// Small repeatable random numbers for the demo data.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next(_ lo: Double, _ hi: Double) -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return lo + Double(state % 1_000_000) / 1_000_000 * (hi - lo)
    }
}
