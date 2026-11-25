import Foundation
import Testing
@testable import LionCore

/// Talks to the real servers with a signed-in account. Runs only when LIONCAR_LIVE points to a JSON file with
/// {"access": "...", "refresh": "...", "expires": <unix seconds>, "brand": "peugeot", "country": "GR"}. Read-only.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LIONCAR_LIVE"] != nil))
func liveReadOnlyTour() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["LIONCAR_LIVE"])
    let s = try #require(JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: path))) as? JSON)
    let store = MemoryStore()
    store.set("oauth_access", s.str("access"))
    store.set("oauth_refresh", s.str("refresh"))
    store.set("oauth_expires", s.str("expires"))
    let api = StellantisAPI(store: store, brand: .of(s.str("brand")), country: s.str("country") ?? "GR")

    let customer = try await api.loadUserInfo()
    #expect(customer != nil)
    let cars = try await api.vehicles()
    let car = try #require(cars.first)
    let st = car.parseStatus(try await api.status(car), maintenance: try await api.maintenance(car), override: nil)
    let trips = try await api.allTrips(car, from: Date().addingTimeInterval(-14 * 86_400))
    let alerts = try await api.alerts(car)
    let t0 = Date()
    let year = try await api.allTrips(car, from: Date().addingTimeInterval(-365 * 86_400))
    print("LIVE year of trips: \(year.count) in \(Int(Date().timeIntervalSince(t0))) s")
    #expect(year.count >= trips.count)
    print("LIVE car kind=\(car.kind(override: nil)) energy=\(st.energyType) fuel=\(st.batteryPct ?? -1)% range=\(st.rangeKm ?? -1)",
          "locked=\(String(describing: st.locked)) odo=\(st.odometerKm ?? -1) service=\(st.kmToService ?? -1)km/\(st.daysToService ?? -1)d",
          "trips14d=\(trips.count) alerts=\(alerts.count) updated=\(String(describing: st.updatedAt))")
    #expect(st.odometerKm != nil)
    #expect(store.get("oauth_refresh") == s.str("refresh"), "a live read must not have needed a refresh")
}
