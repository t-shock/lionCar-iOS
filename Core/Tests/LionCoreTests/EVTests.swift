import Foundation
import Testing
@testable import LionCore

// Electric-car logic, checked against made-up status reports (no real electric car was available).

private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private let t0 = ISODate.parse("2025-03-10T18:00:00Z")!

/// An electric car's status as the server would send it.
private func ev(_ level: Double, residualKwh: Double?, charging: Bool, plugged: Bool = true, range: Double? = nil,
                remaining: String? = nil, at: Date, mode: String = "Slow", lat: Double = 48.8566, lon: Double = 2.3522,
                nextDelayed: String? = "PT1H0M") -> VehicleStatus {
    var load: JSON = ["capacity": 73_000]
    if let r = residualKwh { load["residual"] = r * 1000 }
    var ch: JSON = ["plugged": plugged, "status": charging ? "InProgress" : (plugged ? "Stopped" : "Disconnected"), "chargingMode": mode]
    if let remaining { ch["remainingTime"] = remaining }
    if let nextDelayed { ch["nextDelayedTime"] = nextDelayed }
    var e: JSON = ["type": "Electric", "level": level, "updatedAt": ISODate.format(at),
                   "extension": ["electric": ["charging": ch, "battery": ["load": load] as JSON] as JSON] as JSON]
    if let range { e["autonomy"] = range }
    let j: JSON = ["updatedAt": ISODate.format(at), "energies": [e],
                   "lastPosition": ["geometry": ["coordinates": [lon, lat]] as JSON] as JSON]
    return VehicleStatus.parse(j, maintenance: nil)
}

@Test func fuelCarsPassThroughUnchanged() throws {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/synthetic_mhev_status", withExtension: "json"))
    let st = VehicleStatus.parse(try #require(JSONValue.parse(try Data(contentsOf: url)) as? JSON), maintenance: nil, mildHybrid: true)
    let store = MemoryStore()
    let power = ChargePower(store: store, vin: "X")
    let out = power.record(st)
    #expect(out.batteryPct == st.batteryPct && out.rangeKm == st.rangeKm && !out.rangeEstimated && out.programs == st.programs)
    #expect(ChargeLog(store: store, vin: "X", power: power).observe(out) == nil)
    #expect(store.get("cp_kmPerPct_X") == nil && store.get("cl_active_X") == nil)
}

@Test func rangeIsEstimatedWhenTheServerSaysZero() {
    let power = ChargePower(store: MemoryStore(), vin: "E")
    _ = power.record(ev(50, residualKwh: 36.5, charging: false, range: 215, at: t0))
    let fixed = power.record(ev(40, residualKwh: 29.2, charging: false, range: 0, at: t0.addingTimeInterval(3600)))
    #expect(fixed.rangeKm == 172)        // 40 % × 4.3 km per %
    #expect(fixed.rangeEstimated)
    // Nothing learnt yet: usable kWh at 19 kWh/100 km
    let fresh = ChargePower(store: MemoryStore(), vin: "F").record(ev(50, residualKwh: nil, charging: false, range: 0, at: t0))
    #expect(fresh.rangeKm == (50 * 73.0 / 19).rounded())
}

@Test func chargingPowerMeasuredAndEstimated() throws {
    let power = ChargePower(store: MemoryStore(), vin: "E")
    // One report: estimated from the time left — 73 − 30 kWh in 4 h 18 min ≈ 10 kW
    let a = power.record(ev(41, residualKwh: 30, charging: true, remaining: "PT4H18M", at: t0))
    let est = try #require(power.reading(a))
    #expect(!est.measured)
    #expect(abs(est.kw - 43 / 4.3) < 0.01)
    // Ten minutes later 1.2 kWh more: 7.2 kW measured
    let b = power.record(ev(43, residualKwh: 31.2, charging: true, remaining: "PT4H8M", at: t0.addingTimeInterval(600)))
    let m = try #require(power.reading(b))
    #expect(m.measured)
    #expect(abs(m.kw - 7.2) < 0.001)
    #expect(power.reading(ev(43, residualKwh: 31.2, charging: false, at: t0)) == nil)
}

@Test func timeLeftToTheLimit() throws {
    let power = ChargePower(store: MemoryStore(), vin: "E")
    let st = ev(50, residualKwh: 36.5, charging: true, remaining: "PT3H20M", at: t0)
    let toLimit = try #require(power.timeLeft(st, limitPct: 80))
    #expect(toLimit.minutes == 120 && toLimit.pct == 80)     // 200 min to 100 %, 30 of the 50 points to go
    let toFull = try #require(power.timeLeft(st, limitPct: nil))
    #expect(toFull.minutes == 200 && toFull.pct == nil)
}

@Test func levelDropWithTheSameEnergyIsBridged() {
    // E-5008: 89 % → 79 % the moment the daily limit came back on, with 68.5 kWh both times
    let power = ChargePower(store: MemoryStore(), vin: "E")
    _ = power.record(ev(89, residualKwh: 68.5, charging: false, at: t0))
    #expect(power.record(ev(79, residualKwh: 68.5, charging: false, at: t0.addingTimeInterval(60))).batteryPct == 89)
    #expect(power.record(ev(78, residualKwh: 68.0, charging: false, at: t0.addingTimeInterval(3600))).batteryPct == 88)
    // Once the car's own number has caught up, it is used again
    #expect(power.record(ev(87, residualKwh: 67.6, charging: false, at: t0.addingTimeInterval(7200))).batteryPct == 87)
}

@Test func justSentSchedulesStayUntilTheCarShowsThem() {
    let store = MemoryStore()
    let power = ChargePower(store: store, vin: "E")
    let mine = [Program(slot: 1, days: ["Mon"], hour: 7, minute: 0, enabled: true)]
    power.setPendingPrograms(mine, now: t0)
    let old = ev(60, residualKwh: 43.8, charging: false, at: t0)
    #expect(power.record(old, now: t0.addingTimeInterval(60)).programs == mine)
    #expect(power.pendingPrograms(now: t0.addingTimeInterval(3 * 3600)) == nil)   // given up after 2 hours
}

@Test func chargingSessionFromReports() throws {
    let store = MemoryStore()
    let power = ChargePower(store: store, vin: "E")
    let log = ChargeLog(store: store, vin: "E", power: power)
    var places = PlacesConfig()
    places.home = ChargePlace(id: "home", name: "Home", lat: 48.8566, lon: 2.3522, price: 0.25)
    places.publicDcPrice = 0.69
    log.places = places

    func see(_ st: VehicleStatus) -> ChargeSession? { log.observe(power.record(st)) }
    #expect(see(ev(40, residualKwh: 29.2, charging: true, remaining: "PT5H", at: t0)) == nil)
    #expect(log.active?.startPct == 40)
    #expect(see(ev(42, residualKwh: 30.4, charging: true, remaining: "PT4H50M", at: t0.addingTimeInterval(600))) == nil)
    // Charging ended while nobody looked: the next report is higher and not charging
    let s = try #require(see(ev(60, residualKwh: 43.8, charging: false, at: t0.addingTimeInterval(7200))))
    #expect(log.active == nil)
    #expect(s.startPct == 40 && s.endPct == 60)
    #expect(abs(s.kwh - 14.6) < 0.001 && s.measured)
    #expect(abs(s.peakKw! - 7.2) < 0.001)
    #expect(abs(s.hours - 2) < 0.001)
    #expect(log.sessions.count == 1)
    let m = log.match(s)
    #expect(m.kind == "home" && m.price == 0.25)
    var away = s; away.lat = 48.9; away.lon = 2.5; away.mode = "Quick"
    #expect(log.match(away).kind == "public" && log.match(away).price == 0.69)
    log.setAddress("Sample street 1", for: s)
    #expect(log.sessions[0].address == "Sample street 1")
}

@Test func tinySessionsAreDropped() {
    let store = MemoryStore()
    let power = ChargePower(store: store, vin: "E")
    let log = ChargeLog(store: store, vin: "E", power: power)
    _ = log.observe(power.record(ev(50, residualKwh: 36.5, charging: true, at: t0)))
    #expect(log.observe(power.record(ev(50, residualKwh: 36.6, charging: false, at: t0.addingTimeInterval(60)))) == nil)
    #expect(log.sessions.isEmpty)
}

@Test func batteryHealthFromSessions() throws {
    let list = (0..<4).map { i in
        ChargeSession(start: Double(i) * 1000, end: Double(i) * 1000 + 3600, startPct: 30, endPct: 80, kwh: 35, measured: true)
    }
    let h = try #require(ChargeLog.healthEstimate(list, newKwh: 73))
    #expect(abs(h.pct - 70 / 73 * 100) < 0.01 && h.sessions == 4)
    #expect(ChargeLog.healthEstimate(Array(list.prefix(2)), newKwh: 73) == nil)
}

@Test func ownLimitStopsRetriesAndGivesUp() {
    var s = ChargeAutomation.Settings()
    s.limitOn = true; s.limitPct = 80
    var state = ChargeAutomation.LimitState()
    let at22 = ISODate.parse("2025-03-10T22:00:00Z")!
    func check(_ pct: Double, _ when: Date, session: Double = 1) -> ChargeAutomation.Decision {
        ChargeAutomation.limit(ev(pct, residualKwh: nil, charging: true, at: when), s, state: &state, sessionStart: session,
                               kw: 7, usableKwh: 73, now: when, calendar: utc)
    }
    #expect(check(79, at22).action == nil)                       // 79 + 0.8 % gain < 80
    let first = check(79.5, at22)
    #expect(first.action == .stop(hour: 1, minute: 0))           // the car's 01:00 start is 3 h away: keep it
    #expect(first.note != nil)
    #expect(check(80, at22.addingTimeInterval(120)).action == nil) // wait 5 minutes before trying again
    #expect(check(81, at22.addingTimeInterval(400)).action != nil)
    #expect(check(82, at22.addingTimeInterval(800)).action != nil)
    let gaveUp = check(83, at22.addingTimeInterval(1200))
    #expect(gaveUp.action == nil && gaveUp.note?.contains("ignored") == true)
    #expect(check(84, at22.addingTimeInterval(1600)).note == nil)   // said once
    // A new charging session starts over
    #expect(check(81, at22.addingTimeInterval(2000), session: 2).action != nil)
}

@Test func delayedStartIsMovedWhenTooClose() {
    let st = ev(80, residualKwh: nil, charging: true, at: t0)
    let at0030 = ISODate.parse("2025-03-11T00:30:00Z")!
    let (h, m) = ChargeAutomation.delayTime(st, now: at0030, calendar: utc)
    #expect(h == 12 && m == 30)                                  // 01:00 is only 30 min away: 12 h from now instead
}

@Test func chargingWindowAcrossMidnight() {
    var s = ChargeAutomation.Settings()
    s.windowOn = true; s.windowFrom = 22 * 60; s.windowTo = 6 * 60
    #expect(ChargeAutomation.inside(23 * 60, from: s.windowFrom, to: s.windowTo))
    #expect(ChargeAutomation.inside(5 * 60, from: s.windowFrom, to: s.windowTo))
    #expect(!ChargeAutomation.inside(15 * 60, from: s.windowFrom, to: s.windowTo))
    var state = ChargeAutomation.WindowState()
    let afternoon = ISODate.parse("2025-03-10T15:00:00Z")!
    let stop = ChargeAutomation.window(ev(50, residualKwh: nil, charging: true, at: afternoon), s, state: &state, now: afternoon, calendar: utc)
    #expect(stop.action == .stop(hour: 22, minute: 0))
    #expect(ChargeAutomation.window(ev(50, residualKwh: nil, charging: true, at: afternoon), s, state: &state,
                                    now: afternoon.addingTimeInterval(60), calendar: utc).action == nil)   // retry waits
    var st2 = ChargeAutomation.WindowState()
    let night = ISODate.parse("2025-03-10T23:00:00Z")!
    let start = ChargeAutomation.window(ev(50, residualKwh: nil, charging: false, at: night), s, state: &st2, now: night, calendar: utc)
    #expect(start.action == .start(hour: 22, minute: 0))
    s.windowOn = false
    #expect(ChargeAutomation.window(ev(50, residualKwh: nil, charging: true, at: afternoon), s, state: &st2, now: afternoon, calendar: utc).action == nil)
}

@Test func demoCarIsAnElectricCar() {
    let demo = DemoCar()
    let st = demo.vehicle.parseStatus(demo.statusJSON(), maintenance: nil, override: nil)
    #expect(st.energyType == "Electric")
    #expect(st.isCharging && st.plugged)
    #expect(st.capacityKwh == 73)
    #expect(st.programs.count == 2)
    #expect(st.nextDelayedHour == 1)
    #expect(Caps.battery(st) && Caps.climate(st))
    demo.apply("chargeStop"); demo.apply("precondOn"); demo.apply("unlock")
    let after = demo.vehicle.parseStatus(demo.statusJSON(), maintenance: nil, override: nil)
    #expect(!after.isCharging && after.preconditioningOn && after.locked == false)
    demo.apply("clearSchedule")
    let cleared = demo.vehicle.parseStatus(demo.statusJSON(), maintenance: nil, override: nil)
    #expect(cleared.nextDelayedHour == nil && cleared.isCharging)   // plugged in: charges as soon as the schedule is off
    #expect(demo.tripsJSON().map { Trip.parse($0) }.allSatisfy { $0.kwh != nil })
    #expect(demo.sessions().count == 14)
}

@Test func demoPetrolCarHasFuelStats() throws {
    let demo = DemoCar(kind: .fuel, brand: .opel)
    #expect(demo.vehicle.brand == "Opel")
    #expect(demo.vehicle.kind(override: nil) == "Petrol / diesel")
    let st = demo.vehicle.parseStatus(demo.statusJSON(), maintenance: nil, override: nil)
    #expect(st.energyType == "Fuel" && st.batteryPct == 58 && !st.plugged)
    #expect(!Caps.climate(st) && !Caps.battery(st))
    #expect(demo.sessions().isEmpty)
    let scale = try #require(FuelCalibration.litersPerUnit(totalRaw: st.fuelTotalRaw, odometerKm: st.odometerKm))
    #expect(scale == 0.01)
    let avg = try #require(Stats.lifetimeLPer100(totalRaw: st.fuelTotalRaw, odometerKm: st.odometerKm, litersPerUnit: scale))
    #expect(abs(avg - 5.9) < 0.001)
    let trips = demo.tripsJSON().map { Trip.parse($0, litersPerUnit: scale) }
    #expect(trips.allSatisfy { $0.liters != nil && $0.kwh == nil })
    #expect(Stats.monthly(trips).count >= 4)                 // four months of drives
    #expect(Stats.fillUps(trips, tankLiters: 47).count >= 2)
    let tank = try #require(Stats.tankEstimate(trips))
    #expect(abs(tank - 47) < 2)
}

@Test func demoPlugInHybridUsesBothEnergies() throws {
    let demo = DemoCar(kind: .hybrid, brand: .citroen)
    let st = demo.vehicle.parseStatus(demo.statusJSON(), maintenance: nil, override: nil)
    #expect(st.energyType == "Hybrid")
    #expect(st.capacityKwh == nil || st.capacityKwh! < 30)  // 12.4 kWh is below the 30 kWh plausibility floor for capacity
    #expect(st.fuelPct == 58 && st.isCharging)
    #expect(Caps.battery(st) && Caps.climate(st))
    let trips = demo.tripsJSON().map { Trip.parse($0, litersPerUnit: 0.01) }
    #expect(trips.contains { $0.liters != nil && $0.kwh != nil })    // long trips: battery first, then fuel
    #expect(trips.contains { $0.liters == nil && $0.kwh != nil })    // short trips on the battery only
    #expect(trips.allSatisfy { $0.startLevel != nil })               // the gauge is the tank
    #expect(demo.sessions().allSatisfy { !$0.isFast })
}
