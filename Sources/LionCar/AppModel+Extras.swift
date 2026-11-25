import Foundation
import UserNotifications
import BackgroundTasks
import LionCore

/// Fuel cost and tank, trip tags, CSV export and the car warnings (notifications).
extension AppModel {
    // MARK: Fuel, tank and lifetime figures

    var currencySymbol: String { Locale.current.currencySymbol ?? "€" }

    func cost(_ t: Trip) -> Double? { fuelPrice.flatMap { p in t.liters.map { $0 * p } } }

    /// The tank size: set by the user, or worked out from how the gauge moved on recent trips.
    var tankLiters: Double? {
        get {
            if let vin = vehicle?.vin, let v = defaults.object(forKey: "tank_\(vin)") as? Double { return v }
            return Stats.tankEstimate(trips)
        }
        set {
            guard let vin = vehicle?.vin else { return }
            if let newValue { defaults.set(newValue, forKey: "tank_\(vin)") } else { defaults.removeObject(forKey: "tank_\(vin)") }
        }
    }
    var tankIsEstimated: Bool { vehicle.map { defaults.object(forKey: "tank_\($0.vin)") == nil } ?? true }

    var lifetimeLPer100: Double? {
        guard let st = status, st.energyType != "Electric" else { return nil }
        return Stats.lifetimeLPer100(totalRaw: st.fuelTotalRaw, odometerKm: st.odometerKm, litersPerUnit: litersPerUnit)
    }

    var lifetimeLiters: Double? {
        guard let st = status, st.energyType != "Electric" else { return nil }
        return Stats.lifetimeLiters(totalRaw: st.fuelTotalRaw, litersPerUnit: litersPerUnit)
    }

    // MARK: Trip tags

    static let tagColors = 8

    func tag(for t: Trip) -> TripTag? { tagBook.tag(for: t) }

    func setTag(_ tagID: String?, for t: Trip) { tagBook.set(tagID, for: t.id) }
    func resetTag(for t: Trip) { tagBook.clearManual(for: t.id) }

    @discardableResult
    func addTag(name: String) -> TripTag {
        let tag = TripTag(name: name, color: tagBook.tags.count % Self.tagColors)
        tagBook.tags.append(tag)
        return tag
    }

    func updateTag(_ tag: TripTag) {
        if let i = tagBook.tags.firstIndex(where: { $0.id == tag.id }) { tagBook.tags[i] = tag }
    }

    func removeTag(_ tag: TripTag) { tagBook.remove(tag.id) }

    // MARK: CSV

    /// The shown trips as a CSV file in the temporary folder, for the share sheet.
    func exportCSV() -> URL? {
        let text = TripCSV.make(shownTrips, tag: { self.tag(for: $0)?.name }, cost: { self.cost($0) })
        let name = "LionCar-trips-\(Date().formatted(.iso8601.year().month().day())).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try text.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }

    // MARK: Warnings

    static func loadAlertSettings() -> CarAlerts.Settings {
        let d = UserDefaults.standard
        var s = CarAlerts.Settings()
        s.unlocked = d.object(forKey: "alert_unlocked") as? Bool ?? true
        s.lowEnergy = d.object(forKey: "alert_low") as? Bool ?? true
        s.service = d.object(forKey: "alert_service") as? Bool ?? true
        s.lightsOn = d.object(forKey: "alert_lights") as? Bool ?? true
        s.lowPct = d.object(forKey: "alert_lowPct") as? Double ?? 15
        return s
    }

    func saveAlertSettings() {
        defaults.set(alertSettings.unlocked, forKey: "alert_unlocked")
        defaults.set(alertSettings.lowEnergy, forKey: "alert_low")
        defaults.set(alertSettings.service, forKey: "alert_service")
        defaults.set(alertSettings.lightsOn, forKey: "alert_lights")
        defaults.set(alertSettings.lowPct, forKey: "alert_lowPct")
    }

    static func loadAlertState() -> CarAlerts.State {
        guard let d = UserDefaults.standard.data(forKey: "alertState"), let s = try? JSONDecoder().decode(CarAlerts.State.self, from: d)
        else { return CarAlerts.State() }
        return s
    }

    func saveAlertState() { defaults.set(try? JSONEncoder().encode(alertState), forKey: "alertState") }

    var carName: String { vehicle.map { $0.brand.isEmpty ? brand.display : $0.brand } ?? brand.display }

    /// Looks at the latest status and posts a notification for each new warning.
    func checkAlerts() {
        guard !isDemo, let st = serverStatus else { return }
        var state = alertState
        let alerts = CarAlerts.check(st, carName: carName, settings: alertSettings, state: &state)
        if state != alertState { alertState = state }
        for a in alerts { post(a, st) }
    }

    private func post(_ a: CarAlerts.Alert, _ st: VehicleStatus) {
        let c = UNMutableNotificationContent()
        let car = carName
        switch a.kind {
        case .unlocked:
            c.title = String(localized: "\(car) is unlocked")
            c.body = String(localized: "It was parked unlocked. Open LionCar to lock it.")
        case .lowEnergy:
            c.title = st.energyType == "Electric" ? String(localized: "Battery is low") : String(localized: "Fuel is low")
            let pct = Int(st.energyType == "Hybrid" ? (st.fuelPct ?? 0) : (st.batteryPct ?? 0))
            c.body = String(localized: "\(car): \(pct) % left.")
        case .service:
            c.title = String(localized: "Service due soon")
            c.body = String(localized: "\(car): \(Int(st.kmToService ?? 0)) km or \(Int(st.daysToService ?? 0)) days until the next service.")
        case .lightsOn:
            c.title = String(localized: "Fog lights left on")
            c.body = String(localized: "\(car) is parked with its fog lights on.")
        }
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lioncar.\(a.kind.rawValue)", content: c, trigger: nil))
    }

    /// Asks once for permission to show notifications.
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: Background checks

    static let refreshTaskID = "lioncar.refresh"

    /// Asks iOS to wake LionCar in about 30 minutes. iOS decides the real time (often later, depending on use).
    nonisolated static func scheduleBackgroundRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// Runs in the background: fresh status and the warning check.
    func backgroundRefresh() async {
        Self.scheduleBackgroundRefresh()
        guard !isDemo else { return }
        // After a cold start in the background, the start-up load may still be running: wait for it (up to a minute).
        for _ in 0..<120 where phase == .loading || refreshing { try? await Task.sleep(nanoseconds: 500_000_000) }
        guard phase == .ready else { return }
        if lastRefresh.map({ Date().timeIntervalSince($0) > 120 }) ?? true { await refresh() }
        checkAlerts()
    }
}

/// Shows notifications as banners while the app is open too.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
