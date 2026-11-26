import Foundation
import CoreLocation
import Observation
import LionCore

/// Where the phone is, for the map (only while the app is open; asked once).
@Observable @MainActor
final class PhoneLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var coordinate: CLLocationCoordinate2D?
    var denied = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: denied = true
        default: manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            switch m.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: denied = false; manager.requestLocation()
            case .denied, .restricted: denied = true
            default: break
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        Task { @MainActor in coordinate = c }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}

/// Chargers (electric and plug-in hybrid cars) or fuel stations (other cars) from OpenStreetMap, kept 6 hours.
extension AppModel {
    var placesKind: OsmPlaces.Kind { status?.energyType == "Fuel" ? .fuel : .chargers }

    private var placesCacheURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("places.json")
    }

    private struct PlacesCache: Codable { var kind: String; var lat: Double; var lon: Double; var time: Double; var items: [Charger] }

    /// The saved list, if it is for the same kind of place, about the same spot (within a few km) and young enough.
    private func cachedPlaces(_ kind: OsmPlaces.Kind, _ lat: Double, _ lon: Double, maxAge: TimeInterval) -> [Charger]? {
        guard let url = placesCacheURL, let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(PlacesCache.self, from: d),
              c.kind == kind.rawValue, abs(c.lat - lat) < 0.03, abs(c.lon - lon) < 0.05,
              Date().timeIntervalSince1970 - c.time < maxAge else { return nil }
        return c.items
    }

    private func savePlaces(_ kind: OsmPlaces.Kind, _ lat: Double, _ lon: Double, _ items: [Charger]) {
        guard let url = placesCacheURL else { return }
        let c = PlacesCache(kind: kind.rawValue, lat: lat, lon: lon, time: Date().timeIntervalSince1970, items: items)
        try? JSONEncoder().encode(c).write(to: url, options: .atomic)
    }

    /// Stations within about 12 km of the point. Fresh results (under 6 h) come from the phone; older saved ones are
    /// shown while the free servers are asked.
    func loadPlaces(lat: Double, lon: Double, force: Bool = false) async {
        let kind = placesKind
        placesCenter = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        if !force, let fresh = cachedPlaces(kind, lat, lon, maxAge: 6 * 3600) {
            places = fresh; placesError = nil; return
        }
        if let old = cachedPlaces(kind, lat, lon, maxAge: 30 * 86_400) { places = old }
        placesLoading = true
        defer { placesLoading = false }
        do {
            let list = try await OsmPlaces.near(lat: lat, lon: lon, kind: kind)
            if !list.isEmpty { savePlaces(kind, lat, lon, list) }
            places = list
            placesError = list.isEmpty ? (kind == .fuel ? L("No fuel stations found nearby") : L("No chargers found nearby")) : nil
        } catch {
            let short = error is OsmPlaces.BusyError ? L("The free charger servers are busy right now")
                : (error is OsmPlaces.OfflineError ? L("No connection to the charger servers") : L("Couldn't load the map data"))
            placesError = places.isEmpty ? String(localized: "\(short) — try again in a minute") : String(localized: "\(short) — showing saved results")
        }
    }
}
