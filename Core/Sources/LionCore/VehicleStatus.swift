import Foundation

public struct Program: Equatable, Sendable {
    public var slot: Int
    public var days: [String]
    public var hour: Int
    public var minute: Int
    public var enabled: Bool
    public init(slot: Int, days: [String], hour: Int, minute: Int, enabled: Bool) {
        self.slot = slot; self.days = days; self.hour = hour; self.minute = minute; self.enabled = enabled
    }
}

/// The car's state. Port of LionFlow's `VehicleStatus` (VehicleStatus.kt), plus the 12/48 V battery readings.
public struct VehicleStatus: @unchecked Sendable {
    public var raw: JSON
    public var batteryPct: Double?
    public var rangeKm: Double?
    public var plugged: Bool
    /// InProgress | Finished | Stopped | Disconnected | Failure
    public var chargingStatus: String?
    /// Slow | Quick | No
    public var chargingMode: String?
    public var chargingRateKmh: Double?
    public var remainingMinutes: Int?
    public var nextDelayedHour: Int?
    public var nextDelayedMinute: Int?
    public var batteryHealthPct: Double?
    public var odometerKm: Double?
    public var locked: Bool?
    public var openDoors: [String]
    public var outsideTempC: Double?
    public var preconditioningOn: Bool
    public var programs: [Program]
    public var lat: Double?
    public var lon: Double?
    public var ignition: String?
    public var moving: Bool
    public var updatedAt: Date?
    public var kmToService: Double?
    public var daysToService: Double?
    /// Energy in the traction battery now (kWh).
    public var residualKwh: Double?
    /// Usable traction-battery capacity reported by the car (kWh).
    public var capacityKwh: Double?
    public var energyAt: Date?
    public var rangeEstimated = false
    public var chargeType: String?
    /// Electric | Fuel | Hybrid
    public var energyType: String = "Electric"
    public var fuelPct: Double?
    public var fuelRangeKm: Double?
    public var isMildHybrid = false
    /// Mild hybrids: energy in the small 48 V battery (Wh) and its health (%), as reported.
    public var smallBatteryWh: Double?
    public var smallBatteryHealthPct: Double?
    /// Lifetime fuel counter (raw, undocumented unit) — used to calibrate trip fuel figures.
    public var fuelTotalRaw: Double?
    public var alarmActive: Bool?
    // More of what the car reports
    public var coolantTempC: Double?
    /// "Left/Front" style names of fog lights / indicators that are on.
    public var fogLightsOn: [String] = []
    public var indicatorsOn: [String] = []
    public var driveMode: String?
    public var gearboxMode: String?
    /// Stopped | Running | …
    public var powertrainStatus: String?
    public var speedKmh: Double?
    /// None | Geolocation | Full … ("None" = nothing blocked)
    public var privacyState: String?
    /// Compass heading the car is parked in (0 = north).
    public var heading: Double?
    public var gpsSignalQuality: Double?
    public var seatbelts: [String] = []
    /// battery.voltage as reported; the meaning varies by model.
    public var batteryVoltage: Double?
    /// The car's own current consumption figure (l/100 km on fuel cars).
    public var carConsumption: Double?

    /// The car is on or moving.
    public var isDriving: Bool { moving || ignition == "Start" || powertrainStatus == "Running" }
    /// Privacy mode blocks remote commands (error 422).
    public var privacyOn: Bool { privacyState.map { $0 != "None" && !$0.isEmpty } ?? false }

    public var isCharging: Bool { chargingStatus == "InProgress" }

    /// The program block the remote-preconditioning command expects. An empty slot is sent as 34:07, off (as MyPeugeot does).
    public static func programsJSON(_ programs: [Program]) -> JSON {
        var out: JSON = [:]
        let week = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        for slot in 1...4 {
            let p = programs.first { $0.slot == slot }
            out["program\(slot)"] = [
                "day": week.map { p?.days.contains($0) == true ? 1 : 0 },
                "hour": p?.hour ?? 34, "minute": p?.minute ?? 7, "on": p?.enabled == true ? 1 : 0,
            ] as JSON
        }
        return out
    }

    /// The battery level of the electric part. Some plug-in hybrids report "100 %" with 0 km of electric range
    /// while the battery is actually empty: 100 % with 0 km (and not charging) is shown as empty.
    private static func hybridLevel(_ electric: JSON, fuel: JSON?, charging: JSON?) -> Double? {
        guard let level = electric.num("level") else { return fuel != nil ? 0 : nil }
        let plugged = charging?.bool("plugged") == true || charging?.str("status") == "InProgress"
        if fuel != nil && !plugged && level >= 95 && electric.num("autonomy") == 0 { return 0 }
        return level
    }

    public static func parse(_ j: JSON, maintenance: JSON?, mildHybrid: Bool = false, requireChargingEvidence: Bool = false) -> VehicleStatus {
        let energies = j.objects("energies")
        let reportedElectric = energies.first { $0.optString("type") == "Electric" }
        let reportedCharging = reportedElectric?.obj("extension", "electric", "charging")
        // Stellantis can report a full or partial charge target even when the car is unplugged.
        let supportsExternalCharging = reportedCharging?.bool("plugged") == true ||
            ["InProgress", "Finished"].contains(reportedCharging?.str("status") ?? "") ||
            ["Full", "Partial"].contains(reportedCharging?.str("type") ?? "")
        let fuelOnly = mildHybrid || (requireChargingEvidence && !supportsExternalCharging)
        let electric = fuelOnly ? nil : reportedElectric
        let fuel = energies.first { $0.optString("type") == "Fuel" }
        let charging = electric?.obj("extension", "electric", "charging")
        let health = electric?.obj("extension", "electric", "battery", "health")
        let load = electric?.obj("extension", "electric", "battery", "load")
        func kwh(_ k: String) -> Double? { load?.num(k).flatMap { $0 >= 1 ? $0 / 1000 : nil } }
        let cap = kwh("capacity").flatMap { (30...130).contains($0) ? $0 : nil }
        let res = kwh("residual").flatMap { cap == nil || $0 <= cap! * 1.05 ? $0 : nil }
        let doors = j.obj("doorsState")
        let lockedStates = doors?.strings("lockedStates") ?? []
        let openings = (doors?.objects("opening") ?? []).filter { $0.optString("state") == "Open" }.map { $0.optString("identifier") }
        let coords = j.obj("lastPosition", "geometry")?["coordinates"] as? [Any]
        let ac = j.obj("preconditioning", "airConditioning")
        let programs: [Program] = (ac?.objects("programs") ?? []).compactMap { p in
            guard let start = ISODate.parsePT(p.str("start")) else { return nil }
            let days = p.obj("occurence")?.strings("day") ?? []
            return Program(slot: Int(p.num("slot") ?? 0), days: days, hour: start.hours, minute: start.minutes, enabled: p.bool("enabled") ?? false)
        }
        let next = ISODate.parsePT(charging?.str("nextDelayedTime"))
        let remaining = ISODate.parsePT(charging?.str("remainingTime")).map { $0.hours * 60 + $0.minutes }
        let m = maintenance ?? j.obj("maintenance")
        // The small battery of a mild hybrid sits in the "Electric" energy even though it can't be charged from a plug.
        let small = (mildHybrid || fuelOnly) ? reportedElectric?.obj("extension", "electric", "battery") : nil

        func coord(_ i: Int) -> Double? {
            guard let c = coords, c.count > i else { return nil }
            if let n = c[i] as? NSNumber { return n.doubleValue }
            return nil
        }
        let batteryPct: Double? = electric.map { hybridLevel($0, fuel: fuel, charging: charging) } ?? fuel?.num("level")
        let rangeKm: Double? = electric.map { e in e.num("autonomy") ?? (fuel != nil && e.num("level") == nil ? 0 : nil) } ?? fuel?.num("autonomy")

        var st = VehicleStatus(
            raw: j,
            // Petrol/diesel cars: the fuel tank stands in for the battery. A plug-in hybrid never shows the tank as its battery.
            batteryPct: batteryPct,
            rangeKm: rangeKm,
            plugged: charging?.bool("plugged") ?? false,
            chargingStatus: charging?.str("status"),
            chargingMode: charging?.str("chargingMode"),
            chargingRateKmh: charging?.num("chargingRate"),
            remainingMinutes: remaining,
            nextDelayedHour: next?.hours, nextDelayedMinute: next?.minutes,
            batteryHealthPct: health?.num("capacity") ?? health?.num("resistance"),
            odometerKm: j.obj("odometer")?.num("mileage"),
            locked: lockedStates.isEmpty ? nil : lockedStates.contains { $0.contains("Locked") && !$0.contains("Unlocked") },
            openDoors: openings,
            outsideTempC: j.obj("environment", "air")?.num("temp"),
            preconditioningOn: ac?.optString("status") == "Enabled",
            programs: programs,
            lat: coord(1), lon: coord(0),
            ignition: j.obj("ignition")?.str("type"),
            moving: j.obj("kinetic")?.bool("moving") ?? false,
            updatedAt: ISODate.parse(j.str("updatedAt")),
            kmToService: m?.num("mileageBeforeMaintenance"),
            daysToService: m?.num("daysBeforeMaintenance"),
            residualKwh: res, capacityKwh: cap,
            energyAt: ISODate.parse(electric?.str("updatedAt")))
        st.chargeType = charging?.str("type")
        // Non-plug-in hybrids use the fuel-only display.
        st.energyType = (fuelOnly || (electric == nil && fuel != nil)) ? "Fuel" : (electric != nil && fuel != nil ? "Hybrid" : "Electric")
        st.isMildHybrid = mildHybrid
        st.fuelPct = fuel?.num("level")
        st.fuelRangeKm = fuel?.num("autonomy")
        st.smallBatteryWh = small?.obj("load")?.num("residual")
        st.smallBatteryHealthPct = small?.obj("health")?.num("capacity")
        st.fuelTotalRaw = fuel?.obj("extension", "fuel", "consumptions")?.num("total")
        st.alarmActive = j.obj("alarm", "status")?.str("activation").map { $0 == "Active" }
        st.coolantTempC = j.objects("engines").first?.obj("extension", "thermic", "coolant")?.num("temp")
        func lightsOn(_ key: String) -> [String] {
            (j.obj("lightingSystem")?.objects(key) ?? []).filter { $0.optString("status") == "On" }
                .map { [$0.str("direction"), $0.str("position")].compactMap { $0 }.joined(separator: " ") }
        }
        st.fogLightsOn = lightsOn("fog")
        st.indicatorsOn = lightsOn("turn")
        st.driveMode = j.obj("drivingBehavior")?.str("mode")
        st.gearboxMode = j.obj("transmission", "gearbox")?.str("mode")
        st.powertrainStatus = j.obj("powertrain")?.str("status")
        st.speedKmh = j.obj("kinetic")?.num("speed")
        st.privacyState = j.obj("privacy")?.str("state")
        st.heading = j.obj("lastPosition", "properties")?.num("heading")
        st.gpsSignalQuality = j.obj("lastPosition", "properties")?.num("signalQuality")
        st.seatbelts = (j.obj("safety")?.objects("beltStatus") ?? []).compactMap { $0.str("belt") }
        st.batteryVoltage = j.obj("battery")?.num("voltage")
        st.carConsumption = fuel?.obj("extension", "fuel", "consumptions")?.num("instant")
            ?? j.objects("energy").first { $0.optString("type") == "Fuel" }?.num("consumption")
        return st
    }

    public init(raw: JSON, batteryPct: Double?, rangeKm: Double?, plugged: Bool, chargingStatus: String?, chargingMode: String?,
                chargingRateKmh: Double?, remainingMinutes: Int?, nextDelayedHour: Int?, nextDelayedMinute: Int?,
                batteryHealthPct: Double?, odometerKm: Double?, locked: Bool?, openDoors: [String], outsideTempC: Double?,
                preconditioningOn: Bool, programs: [Program], lat: Double?, lon: Double?, ignition: String?, moving: Bool,
                updatedAt: Date?, kmToService: Double?, daysToService: Double?, residualKwh: Double? = nil,
                capacityKwh: Double? = nil, energyAt: Date? = nil) {
        self.raw = raw; self.batteryPct = batteryPct; self.rangeKm = rangeKm; self.plugged = plugged
        self.chargingStatus = chargingStatus; self.chargingMode = chargingMode; self.chargingRateKmh = chargingRateKmh
        self.remainingMinutes = remainingMinutes; self.nextDelayedHour = nextDelayedHour; self.nextDelayedMinute = nextDelayedMinute
        self.batteryHealthPct = batteryHealthPct; self.odometerKm = odometerKm; self.locked = locked; self.openDoors = openDoors
        self.outsideTempC = outsideTempC; self.preconditioningOn = preconditioningOn; self.programs = programs
        self.lat = lat; self.lon = lon; self.ignition = ignition; self.moving = moving; self.updatedAt = updatedAt
        self.kmToService = kmToService; self.daysToService = daysToService; self.residualKwh = residualKwh
        self.capacityKwh = capacityKwh; self.energyAt = energyAt
    }
}

/// What the car can do, so screens can hide what doesn't apply. Unknown (no status yet) = show. Port of `Caps`.
public enum Caps {
    public static func battery(_ st: VehicleStatus?) -> Bool { st == nil || st!.energyType != "Fuel" }
    public static func fuel(_ st: VehicleStatus?) -> Bool { st != nil && st!.energyType != "Electric" }
    public static func position(_ st: VehicleStatus?) -> Bool { st?.lat != nil && st?.lon != nil }
    public static func climate(_ st: VehicleStatus?) -> Bool {
        guard let st else { return true }
        return st.raw.has("preconditioning") || st.raw.has("airConditioning") || st.energyType != "Fuel"
    }
    public static func lockState(_ st: VehicleStatus?) -> Bool { st == nil || st!.locked != nil }
}
