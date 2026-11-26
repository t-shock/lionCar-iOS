import Foundation
import Testing
@testable import LionCore

// A made-up Overpass answer in the real shape: a node, an area (way, with its centre) and a fuel station.
private let answer = JSONValue.parse(#"""
{"version":0.6,"elements":[
 {"type":"node","id":101,"lat":48.8600,"lon":2.3400,"tags":{"amenity":"charging_station","name":"Sample Fast Hub",
  "operator":"Sample Energy","capacity":"6","socket:type2_combo":"4","socket:type2_combo:output":"150 kW",
  "socket:chademo":"1","socket:type2":"2","socket:type2:output":"22kW","fee":"yes","opening_hours":"24/7",
  "addr:street":"Rue Exemple","addr:housenumber":"12","addr:city":"Paris"}},
 {"type":"way","id":202,"center":{"lat":48.8700,"lon":2.3500},"tags":{"amenity":"charging_station","network":"City Net",
  "maxpower":"22000","capacity":"2","socket:type2":"yes"}},
 {"type":"node","id":303,"lat":48.8800,"lon":2.3600,"tags":{"amenity":"charging_station","charging_station:output":"0.35 MW"}},
 {"type":"node","id":404,"tags":{"amenity":"charging_station"}}
]}
"""#) as! JSON

@Test func overpassAnswerIsRead() throws {
    let list = OsmPlaces.parse(answer, kind: .chargers)
    #expect(list.count == 3)                       // the element without a position is skipped
    let hub = try #require(list.first { $0.id == "osm-node-101" })
    #expect(hub.name == "Sample Fast Hub" && hub.operatorName == "Sample Energy")
    #expect(hub.maxKw == 150 && hub.isFast)
    #expect(hub.points == 6)
    #expect(hub.sockets == ["CCS": 4, "CHAdeMO": 1, "Type 2": 2])
    #expect(hub.address == "Rue Exemple 12, Paris")
    #expect(hub.fee == "yes" && hub.openingHours == "24/7")
    let area = try #require(list.first { $0.id == "osm-way-202" })
    #expect(area.lat == 48.87 && area.name == "City Net")
    #expect(area.maxKw == 22 && !area.isFast)      // 22000 plain watts
    #expect(area.sockets == ["Type 2": 1])
    let unnamed = try #require(list.first { $0.id == "osm-node-303" })
    #expect(unnamed.name == "Charging station" && unnamed.maxKw == 350)
}

@Test func fuelStationsGetTheirOwnDefaultName() {
    let j = JSONValue.parse(#"{"elements":[{"type":"node","id":1,"lat":1,"lon":2,"tags":{"amenity":"fuel","brand":"Sample Fuel"}},{"type":"node","id":2,"lat":1,"lon":2,"tags":{"amenity":"fuel"}}]}"#) as! JSON
    let list = OsmPlaces.parse(j, kind: .fuel)
    #expect(list.map(\.name) == ["Sample Fuel", "Fuel station"])
}

@Test func powerValues() {
    #expect(OsmPlaces.power("22 kw") == 22)
    #expect(OsmPlaces.power("7,4 kw") == 7.4)
    #expect(OsmPlaces.power("0.35 mw") == 350)
    #expect(OsmPlaces.power("11000") == 11)
    #expect(OsmPlaces.power("11") == 11)
    #expect(OsmPlaces.power("unknown") == nil)
}

@Test func queryShape() {
    let q = OsmPlaces.query(lat: 48.8566, lon: 2.3522, radiusM: 12000, limit: 80, kind: .fuel)
    #expect(q == #"[out:json][timeout:25];(node["amenity"="fuel"](around:12000,48.85660,2.35220);way["amenity"="fuel"](around:12000,48.85660,2.35220););out center 80;"#)
}

/// Asks the real public servers for chargers around central Paris. Only runs with LIONCAR_LIVE_OSM set.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIONCAR_LIVE_OSM"] != nil))
func liveChargersInParis() async throws {
    let t0 = Date()
    let list = try await OsmPlaces.near(lat: 48.8566, lon: 2.3522, radiusM: 3000, limit: 40, kind: .chargers)
    print("LIVE OSM: \(list.count) chargers in \(Int(Date().timeIntervalSince(t0))) s; fast: \(list.filter(\.isFast).count); with sockets: \(list.filter { !$0.sockets.isEmpty }.count)")
    #expect(!list.isEmpty)
}
