import Foundation
import Testing
@testable import LionCore

// Made-up data from scripts/make_fixtures.py
private func sampleTrips(scale: Double? = 0.004) throws -> [Trip] {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/synthetic_mhev_trips", withExtension: "json"))
    let arr = try #require(JSONValue.parse(try Data(contentsOf: url)) as? [Any])
    return arr.compactMap { $0 as? JSON }.map { Trip.parse($0, mildHybrid: true, litersPerUnit: scale) }
}

private func sampleStatus() throws -> VehicleStatus {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/synthetic_mhev_status", withExtension: "json"))
    return VehicleStatus.parse(try #require(JSONValue.parse(try Data(contentsOf: url)) as? JSON), maintenance: nil, mildHybrid: true)
}

@Test func moreStatusFields() throws {
    let st = try sampleStatus()
    #expect(st.coolantTempC == 75)
    #expect(st.fogLightsOn.isEmpty && st.indicatorsOn.isEmpty)
    #expect(st.driveMode == "Eco")
    #expect(st.gearboxMode == "Auto")
    #expect(st.powertrainStatus == "Stopped")
    #expect(st.speedKmh == 0)
    #expect(!st.isDriving)
    #expect(st.privacyState == "None" && !st.privacyOn)
    #expect(st.heading == 90)
    #expect(Geo.compass(90) == "E")
    #expect(Geo.compass(267) == "W")
    #expect(st.gpsSignalQuality == 7)
    #expect(st.seatbelts == ["Omission", "Omission"])
    #expect(st.batteryVoltage == 13.2)
    #expect(st.carConsumption == 5.8)
}

@Test func tripLevelsAndRanges() throws {
    let t = try #require(try sampleTrips().first { $0.distanceKm == 60 })
    #expect(t.startLevel == 56 && t.endLevel == 48)
    #expect(t.startRangeKm == 400 && t.endRangeKm == 330)
    #expect(t.startMileage == 11616.2)
}

@Test func lifetimeAverageFromCounters() throws {
    let st = try sampleStatus()
    let avg = try #require(Stats.lifetimeLPer100(totalRaw: st.fuelTotalRaw, odometerKm: st.odometerKm, litersPerUnit: 0.004))
    #expect(abs(avg - 6.0) < 0.001)
}

@Test func tankSizeAndFillUpsFromTheGauge() throws {
    let trips = try sampleTrips()
    let tank = try #require(Stats.tankEstimate(trips))
    #expect(abs(tank - 43.09) < 0.01)    // 14.22 l for 33 % of gauge
    let fills = Stats.fillUps(trips, tankLiters: 44)
    #expect(fills.count == 1)            // 40 % at the end of one trip, 100 % at the start of the next
    #expect(fills[0].fromPct == 40 && fills[0].toPct == 100)
    #expect(abs(fills[0].liters! - 26.4) < 0.001)
}

@Test func monthlyTotalsAndRecords() throws {
    let trips = try sampleTrips()
    let months = Stats.monthly(trips)
    #expect(months.count == 1)
    #expect(abs(months[0].km - 283.7) < 0.001)
    #expect(months[0].trips == 9)
    #expect(months[0].lPer100 != nil)
    #expect(months[0].cost(pricePerLiter: 2) == months[0].liters * 2)
    let r = Stats.records(trips)
    #expect(r.longest?.distanceKm == 80)
    #expect(r.bestDay.map { abs($0.km - 118) < 0.001 } == true)
    #expect(abs(r.mostEfficient!.avgLPer100! - 5.5) < 0.001)
    #expect(abs(r.leastEfficient!.avgLPer100! - 7) < 0.001)   // the 8 l/100 trip is under 10 km, so it doesn't count
    #expect(r.mostEfficient != nil && r.leastEfficient != nil)
}

@Test func tagsByPlaceAndByHand() throws {
    let trips = try sampleTrips()
    var book = TagBook()
    // Every sample trip starts at the same spot: a "Home" tag there catches them all.
    let home = TripTag(name: "Home", color: 0, lat: 48.8566, lon: 2.3522)
    let work = TripTag(name: "Work", color: 1)
    book.tags = [home, work]
    #expect(trips.allSatisfy { book.tag(for: $0)?.name == "Home" })
    book.set(work.id, for: trips[0].id)
    #expect(book.tag(for: trips[0])?.name == "Work")
    book.set(nil, for: trips[1].id)
    #expect(book.tag(for: trips[1]) == nil)
    book.remove(work.id)
    #expect(book.tag(for: trips[0])?.name == "Home")   // its hand-picked tag was deleted: back to the automatic one
    let back = TagBook.decode(book.encoded())
    #expect(back == book)
    #expect(Geo.distanceM(48.8566, 2.3522, 48.8584, 2.2945) > 4000)
}

@Test func csvExport() throws {
    let trips = try sampleTrips()
    let csv = TripCSV.make(trips, tag: { _ in "Work, daily" }, cost: { ($0.liters ?? 0) * 2 }, timeZone: TimeZone(identifier: "UTC")!)
    let lines = csv.split(separator: "\n")
    #expect(lines.count == 10)
    #expect(lines[0].hasPrefix("start,end,distance_km"))
    #expect(lines[1].hasPrefix("2025-03-03 07:30,2025-03-03 07:55,18.0,25,"))
    #expect(lines[1].contains("\"Work, daily\""))
}

@Test func alertsFireOnceAndRearm() throws {
    var st = try sampleStatus()
    let later = st.updatedAt!.addingTimeInterval(3600)
    var state = CarAlerts.State()
    var s = CarAlerts.Settings()
    #expect(CarAlerts.check(st, carName: "Test car", settings: s, state: &state, now: later).isEmpty)   // locked, full, service far

    st.locked = false
    var a = CarAlerts.check(st, carName: "Test car", settings: s, state: &state, now: later)
    #expect(a.map(\.kind) == [.unlocked])
    #expect(CarAlerts.check(st, carName: "Test car", settings: s, state: &state, now: later).isEmpty)  // only once
    // Not yet: the report is fresh (someone may be loading the car)
    var fresh = CarAlerts.State()
    #expect(CarAlerts.check(st, carName: "Test car", settings: s, state: &fresh, now: st.updatedAt!.addingTimeInterval(60)).isEmpty)
    st.locked = true
    _ = CarAlerts.check(st, carName: "Test car", settings: s, state: &state, now: later)
    #expect(!state.active.contains(.unlocked))

    st.batteryPct = 12; st.kmToService = 800; st.fogLightsOn = ["Left Front"]
    a = CarAlerts.check(st, carName: "Test car", settings: s, state: &state, now: later)
    #expect(Set(a.map(\.kind)) == [.lowEnergy, .service, .lightsOn])
    s.lowEnergy = false
    var other = CarAlerts.State()
    #expect(!CarAlerts.check(st, carName: "Test car", settings: s, state: &other, now: later).map(\.kind).contains(.lowEnergy))
}
