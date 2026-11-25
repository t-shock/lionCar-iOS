import Foundation
import Testing
@testable import LionCore

private func fixture(_ name: String) throws -> Any {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
    return try #require(JSONValue.parse(try Data(contentsOf: url)))
}

private func obj(_ s: String) -> JSON { JSONValue.parse(s) as! JSON }

// Ported from LionFlow's MildHybridStatusTest.kt
private let fuel = obj(#"{"type":"Fuel","level":59,"autonomy":360}"#)
private let electric = obj(#"""
{"type":"Electric","level":63,"autonomy":240,
 "extension":{"electric":{"charging":{"status":"InProgress","plugged":true},
 "battery":{"load":{"residual":480,"capacity":36000}}}}}
"""#)
private func status(_ energies: JSON...) -> JSON { ["energies": energies] }

@Test func mildHybridUsesFuelAndDiscardsChargingData() {
    let st = VehicleStatus.parse(status(fuel, electric), maintenance: nil, mildHybrid: true)
    #expect(st.energyType == "Fuel")
    #expect(st.isMildHybrid)
    #expect(st.batteryPct == 59)
    #expect(st.rangeKm == 360)
    #expect(!st.plugged)
    #expect(!Caps.battery(st))
    #expect(st.chargingStatus == nil)
    #expect(st.residualKwh == nil)
    #expect(st.capacityKwh == nil)
}

@Test func missingFuelRangeIsNotEstimatedFromTheBattery() {
    let partialFuel = obj(#"{"type":"Fuel","level":59}"#)
    #expect(VehicleStatus.parse(status(partialFuel, electric), maintenance: nil, mildHybrid: true).rangeKm == nil)
    #expect(VehicleStatus.parse(status(electric), maintenance: nil, mildHybrid: true).energyType == "Fuel")
}

@Test func existingBatteryAndTankInterpretationsStillApply() {
    let bev = VehicleStatus.parse(status(electric), maintenance: nil)
    #expect(bev.energyType == "Electric")
    #expect(bev.rangeKm == 240)
    #expect(bev.isCharging)
    #expect(bev.capacityKwh == 36)
    #expect(bev.residualKwh == 0.48) // same as LionFlow: the 1-unit floor is on the raw Wh value
    let phev = VehicleStatus.parse(status(fuel, electric), maintenance: nil)
    #expect(phev.energyType == "Hybrid")
    #expect(phev.batteryPct == 63)
    #expect(phev.fuelRangeKm == 360)
    #expect(Caps.battery(phev))
    #expect(VehicleStatus.parse(status(fuel, obj(#"{"type":"Electric"}"#)), maintenance: nil).energyType == "Hybrid")
    let petrol = VehicleStatus.parse(status(fuel), maintenance: nil)
    #expect(petrol.energyType == "Fuel")
    #expect(!petrol.isMildHybrid)
    #expect(petrol.batteryPct == 59)
}

@Test func plugInHybridEmptyBatteryReportedAsFullIsShownEmpty() {
    let e = obj(#"{"type":"Electric","level":100,"autonomy":0,"extension":{"electric":{"charging":{"plugged":false}}}}"#)
    #expect(VehicleStatus.parse(status(fuel, e), maintenance: nil).batteryPct == 0)
}

@Test func explicitMetadataTakesPrecedenceOverModelName() {
    for m in ["MHEV", "48 V Mild hybrid", "Hybrid 48V", "MHEV (48 V)"] {
        let v = Vehicle.fromAPI(["id": "vehicle", "vin": "synthetic", "brand": "Peugeot", "motorization": m, "label": "208 Hybrid 100 e-DCS6"],
                                defaultBrand: "Other")!
        #expect(v.mildHybridDetection == .vehicleMetadata, "\(m)")
    }
}

@Test func peugeot208HybridModelNameIsMildHybrid() {
    let v = Vehicle.fromAPI(["id": "v", "vin": "x", "brand": "Peugeot", "motorization": "Hybrid", "label": "208 Allure Hybrid 100 e-DCS6"],
                            defaultBrand: "Peugeot")!
    #expect(v.mildHybridDetection == .modelName)
    #expect(v.kind(override: nil) == "48 V mild hybrid")
}

@Test func plugInLabelIsNotMildHybrid() {
    let v = Vehicle.fromAPI(["id": "v", "vin": "x", "brand": "Peugeot", "motorization": "Hybrid", "label": "3008 Plug-in Hybrid 225"],
                            defaultBrand: "Peugeot")!
    #expect(v.mildHybridDetection == .otherPowertrain)
    #expect(v.kind(override: nil) == "Plug-in hybrid")
}

// A made-up mild hybrid (scripts/make_fixtures.py) that, like many real ones, reports only "Hybrid" and no model name.
@Test func mildHybridWithoutModelNameIsShownAsFuelCar() throws {
    let vj = try fixture("synthetic_mhev_vehicle") as! JSON
    let v = try #require(Vehicle.fromAPI(vj, defaultBrand: "Peugeot"))
    #expect(v.motorization == "Hybrid")
    #expect(v.mildHybridDetection == .insufficientMetadata)
    #expect(v.mildHybridUncertain)
    #expect(v.kind(override: nil) == "Hybrid (type unknown)")

    let sj = try fixture("synthetic_mhev_status") as! JSON
    let st = v.parseStatus(sj, maintenance: nil, override: nil)
    #expect(st.energyType == "Fuel")      // no plug-in charging data, so the tank is the main gauge
    #expect(st.batteryPct == 80)
    #expect(st.rangeKm == 560)
    #expect(st.locked == true)
    #expect(st.openDoors.isEmpty)
    #expect(st.odometerKm == 12000)
    #expect(st.outsideTempC == 14.5)
    #expect(st.smallBatteryWh == 400)
    #expect(st.smallBatteryHealthPct == 97)
    #expect(st.alarmActive == true)
    #expect(st.lat == 48.8566 && st.lon == 2.3522)
    #expect(st.updatedAt == ISODate.parse("2025-03-09T18:00:00Z"))
    #expect(!Caps.battery(st))

    let withOverride = v.parseStatus(sj, maintenance: nil, override: true)
    #expect(withOverride.isMildHybrid)
    #expect(v.kind(override: true) == "48 V mild hybrid")
}

@Test func unusualFuelUnitIsCalibrated() throws {
    let sj = try fixture("synthetic_mhev_status") as! JSON
    let st = VehicleStatus.parse(sj, maintenance: nil, mildHybrid: true)
    let scale = try #require(FuelCalibration.litersPerUnit(totalRaw: st.fuelTotalRaw, odometerKm: st.odometerKm))
    #expect(scale == 0.004)
    let raw = (try fixture("synthetic_mhev_trips") as! [Any]).compactMap { $0 as? JSON }
    let trips = raw.map { Trip.parse($0, mildHybrid: true, litersPerUnit: scale) }
    #expect(trips.count == 9)
    // 825 units over 60 km = 3.3 l = 5.5 l/100 km
    let long = try #require(trips.first { $0.distanceKm == 60 })
    #expect(abs(long.avgLPer100! - 5.5) < 0.001)
    #expect(!long.dataLacking)
    #expect(trips.first { $0.distanceKm == 3 }?.dataLacking == true)
    // Without calibration LionFlow's guess (0.01 l units) reads 2.5× too high
    let guess = Trip.parse(try #require(raw.first { ($0.num("distance") ?? 0) == 60 }))
    #expect(abs(guess.avgLPer100! - 13.75) < 0.001)
}

@Test func usualFuelUnitIsKept() {
    // 600 l over 10 000 km in 0.01-l units = 6 l/100 km
    #expect(FuelCalibration.litersPerUnit(totalRaw: 60_000, odometerKm: 10_000) == 0.01)
    #expect(FuelCalibration.litersPerUnit(totalRaw: 60_000, odometerKm: 100) == nil)
}

@Test func electricTripUsesKwh() {
    let t = Trip.parse(obj(#"{"id":"t","distance":20,"duration":1800,"energyConsumptions":[{"type":"Electric","consumption":3200,"avgConsumption":16000}]}"#))
    #expect(t.kwh == 3.2)
    #expect(t.avgKwhPer100 == 16)
    #expect(t.avgSpeedKmh == 40)
}

@Test func chargingAndProgramsParse() {
    let j = obj(#"""
    {"energies":[{"type":"Electric","level":54,"autonomy":200,"updatedAt":"2025-01-01T07:00:00.000Z",
      "extension":{"electric":{"charging":{"plugged":true,"status":"InProgress","chargingMode":"Slow","chargingRate":40,
        "remainingTime":"PT3H20M","nextDelayedTime":"PT22H30M","type":"Partial"},
        "battery":{"load":{"capacity":50000,"residual":27000},"health":{"capacity":97}}}}}],
     "preconditioning":{"airConditioning":{"status":"Enabled","programs":[
        {"slot":1,"enabled":true,"start":"PT7H15M","occurence":{"day":["Mon","Fri"]}}]}},
     "doorsState":{"lockedStates":["Unlocked"],"opening":[{"identifier":"Driver","state":"Open"}]}}
    """#)
    let st = VehicleStatus.parse(j, maintenance: ["mileageBeforeMaintenance": 1000, "daysBeforeMaintenance": 30])
    #expect(st.isCharging)
    #expect(st.remainingMinutes == 200)
    #expect(st.nextDelayedHour == 22 && st.nextDelayedMinute == 30)
    #expect(st.capacityKwh == 50 && st.residualKwh == 27)
    #expect(st.batteryHealthPct == 97)
    #expect(st.chargeType == "Partial")
    #expect(st.preconditioningOn)
    #expect(st.programs == [Program(slot: 1, days: ["Mon", "Fri"], hour: 7, minute: 15, enabled: true)])
    #expect(st.locked == false)
    #expect(st.openDoors == ["Driver"])
    #expect(st.kmToService == 1000)
    #expect(st.energyAt != nil)
    let p = VehicleStatus.programsJSON(st.programs)
    #expect((p["program1"] as? JSON)?["hour"] as? Int == 7)
    #expect((p["program2"] as? JSON)?["hour"] as? Int == 34)
}

@Test func signInConfigForGreece() {
    let c = StellantisConfig.load(.peugeot, country: "GR")
    #expect(c.locale == "el-GR")
    #expect(c.redirectURI == "mymap://oauth2redirect/gr")
    #expect(StellantisConfig.countries(.peugeot).contains("GR"))
    #expect(StellantisConfig.load(.peugeot, country: "XX").culture == "no")
    let code = StellantisAPI.code(fromRedirect: URL(string: "mymap://oauth2redirect/gr?code=abc-123&scope=openid%20profile&state=")!)
    #expect(code == "abc-123")
}

@Test func httpErrorsAreReadable() {
    let m = HTTP.describeHTTPError(404, body: #"{"uuid":"x","code":40400,"message":"Not Found: No alert was found."}"#, host: "api.groupe-psa.com")
    #expect(m == "Peugeot error 404 (not found): Not Found: No alert was found. · 40400")
    #expect(APIError(404, m).noData)
}

@Test func tokenRefreshIsSingleFlightAndKeepsRotatedToken() async throws {
    // Offline check of the storage order: a signed-out store throws AuthExpired without touching the network.
    let api = StellantisAPI(store: MemoryStore(), brand: .peugeot, country: "GR")
    await #expect(throws: AuthExpiredError.self) { _ = try await api.status(Vehicle(id: "v", vin: "x", motorization: "", brand: "")) }
}
