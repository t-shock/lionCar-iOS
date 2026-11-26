import Foundation
import CoreLocation
import UserNotifications
import LionCore

/// Charging data kept on the phone, in UserDefaults (nothing secret in it).
final class DefaultsStore: SecretStore, @unchecked Sendable {
    private let d = UserDefaults.standard
    func get(_ key: String) -> String? { d.string(forKey: key) }
    func set(_ key: String, _ value: String?) { if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) } }
}

/// Electric and plug-in hybrid cars: charging, pre-heating, the charging log, LionCar's own limit and window,
/// and demo mode. All of this is untested on a real electric car.
extension AppModel {
    // MARK: Charging data per car

    /// Opens the charging data of the chosen car (a throw-away store in demo mode).
    func makeChargeData(store: SecretStore? = nil) {
        guard let v = vehicle else { power = nil; chargeLog = nil; return }
        let s = store ?? DefaultsStore()
        let p = ChargePower(store: s, vin: v.vin, batteryKwhSetting: batteryKwhSetting)
        power = p
        chargeSettings = Self.loadChargeSettings(vin: v.vin)
        chargeLog = ChargeLog(store: s, vin: v.vin, power: p)
        syncChargeLog()
    }

    func syncChargeLog() {
        chargeSessions = chargeLog?.sessions ?? []
        activeSession = chargeLog?.active
        chargePlaces = chargeLog?.places ?? PlacesConfig()
    }

    /// Usable battery size set by the user for this car (kWh), for the kW maths.
    var batteryKwhSetting: Double? {
        get { vehicle.flatMap { defaults.object(forKey: "batteryKwh_\($0.vin)") as? Double } }
        set {
            guard let vin = vehicle?.vin else { return }
            if let newValue, newValue > 0 { defaults.set(newValue, forKey: "batteryKwh_\(vin)") } else { defaults.removeObject(forKey: "batteryKwh_\(vin)") }
            power?.batteryKwhSetting = newValue
        }
    }

    /// Runs every car report through the charging data: range fix, kW samples, sessions.
    func recordCharging(_ raw: VehicleStatus) -> VehicleStatus {
        guard raw.energyType != "Fuel", let power, let chargeLog else { return raw }
        let st = power.record(raw)
        if let done = chargeLog.observe(st), !isDemo { lookUpAddress(done) }
        syncChargeLog()
        return st
    }

    var chargeReading: ChargePower.Reading? { power?.reading(status) }

    /// Minutes until the target and the % it leads to (LionCar's limit when on).
    var chargeTimeLeft: (minutes: Int, pct: Int?)? {
        guard let st = status, let power else { return nil }
        return power.timeLeft(st, limitPct: chargeSettings.limitOn ? chargeSettings.limitPct : nil)
    }

    var usableKwh: Double? { status.flatMap { power?.usableKwh($0) } }

    func deleteSession(_ s: ChargeSession) { chargeLog?.delete(s); syncChargeLog() }

    func updatePlaces(_ change: (inout PlacesConfig) -> Void) {
        guard let chargeLog else { return }
        var p = chargeLog.places
        change(&p)
        chargeLog.places = p
        syncChargeLog()
    }

    func placeMatch(_ s: ChargeSession) -> PlaceMatch { ChargeLog.match(s, chargePlaces) }

    func sessionCost(_ s: ChargeSession) -> Double? { placeMatch(s).price.map { $0 * s.kwh } }

    var healthEstimate: (pct: Double, sessions: Int)? {
        ChargeLog.healthEstimate(chargeSessions, newKwh: status?.capacityKwh ?? batteryKwhSetting)
    }

    private func lookUpAddress(_ s: ChargeSession) {
        guard let lat = s.lat, let lon = s.lon else { return }
        Task {
            let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon))
            guard let m = marks?.first else { return }
            let street = [m.thoroughfare, m.subThoroughfare].compactMap { $0 }.joined(separator: " ")
            let text = [street.isEmpty ? nil : street, m.locality].compactMap { $0 }.joined(separator: ", ")
            guard !text.isEmpty else { return }
            self.chargeLog?.setAddress(text, for: s)
            self.syncChargeLog()
        }
    }

    // MARK: Commands

    /// Turns off the car's scheduled (delayed) start, so it charges as soon as it is plugged in. "Stop charging" (also
    /// from the charge limit or charging times) works by setting that scheduled start, so it can stay on afterwards.
    func clearScheduledStart() async {
        // The charging command always carries a start time; keep the car's own.
        let h = status?.nextDelayedHour ?? 1, m = status?.nextDelayedMinute ?? 0
        await runCommand("Turn off scheduled start", confirmWith: nil,
                         optimistic: { s in s.nextDelayedHour = nil; s.nextDelayedMinute = nil },
                         demoCommand: "clearSchedule") { r, t in await r.charging(startNow: true, hour: h, minute: m, t) }
    }

    /// Plug-in hybrids only pre-heat on the battery, and the car ignores the request below 50 % unless plugged in.
    func preconditioning(_ on: Bool) async {
        guard let st = status else { return }
        if on && !isDemo && st.energyType == "Hybrid" && (st.batteryPct ?? 100) < 50 && !st.plugged {
            message = String(localized: "Plug-in hybrids can only pre-heat with at least 50 % battery. Charge the car first.")
            return
        }
        let programs = VehicleStatus.programsJSON(st.programs)
        await runCommand(on ? "Pre-heating" : "Stop pre-heating", confirmWith: nil,
                         optimistic: { [weak self] s in s.preconditioningOn = on; self?.holdPrecond = (on, Date()) },
                         demoCommand: on ? "precondOn" : "precondOff") { r, t in await r.preconditioning(on, programs: programs, t) }
    }

    /// Sends the 4 schedule slots to the car, keeping pre-heating on or off as it is.
    func savePrograms(_ list: [Program]) async {
        guard let st = status else { return }
        let on = st.preconditioningOn
        let r = await runCommand("Saving schedule", confirmWith: nil, optimistic: { s in s.programs = list },
                                 demoCommand: "programs", demoPrograms: list) { r, t in
            await r.preconditioning(on, programs: VehicleStatus.programsJSON(list), t)
        }
        // The car reports a new schedule late: remember what was sent, to show it meanwhile.
        guard let r else { return }
        if case .failed = r { return }
        power?.setPendingPrograms(list)
    }

    /// The car's own limit: daily (stops at the limit set in the car) or a full charge for a trip.
    func setCarChargeLimit(daily: Bool) async {
        await runCommand(daily ? "Daily charge limit" : "Full charge for a trip", confirmWith: nil,
                         optimistic: { s in s.chargeType = daily ? "Partial" : "Full" },
                         demoCommand: daily ? "limitDaily" : "limitFull") { r, t in await r.chargeLimit(daily: daily, t) }
    }

    func charging(startNow: Bool) async {
        // As above: keep the car's own scheduled start time.
        let h = status?.nextDelayedHour ?? 1, m = status?.nextDelayedMinute ?? 0
        await runCommand(startNow ? "Charge now" : "Stop charging", confirmWith: nil,
                         optimistic: { s in s.chargingStatus = startNow ? "InProgress" : "Stopped" },
                         demoCommand: startNow ? "chargeNow" : "chargeStop") { r, t in
            await r.charging(startNow: startNow, hour: h, minute: m, t)
        }
    }

    /// Sets the car's delayed start to the window's start, so it begins charging by itself then.
    func applyChargeWindow() async {
        let s = chargeSettings
        guard s.windowOn else { return }
        let h = s.windowFrom / 60, m = s.windowFrom % 60
        await runCommand("Charging times on", confirmWith: nil) { r, t in
            await r.charging(startNow: false, hour: h, minute: m, t)
        }
    }

    // MARK: LionCar's own limit and window (act only while the app runs)

    static func loadChargeSettings(vin: String? = nil) -> ChargeAutomation.Settings {
        let d = UserDefaults.standard
        let k = { (name: String) in vin.map { "\(name)_\($0)" } ?? name }
        var s = ChargeAutomation.Settings()
        s.limitOn = d.bool(forKey: k("limitOn"))
        s.limitPct = d.object(forKey: k("limitPct")) as? Int ?? 80
        s.windowOn = d.bool(forKey: k("windowOn"))
        s.windowFrom = d.object(forKey: k("windowFrom")) as? Int ?? 22 * 60
        s.windowTo = d.object(forKey: k("windowTo")) as? Int ?? 6 * 60
        return s
    }

    func saveChargeSettings() {
        guard let vin = vehicle?.vin else { return }
        let s = chargeSettings
        defaults.set(s.limitOn, forKey: "limitOn_\(vin)"); defaults.set(s.limitPct, forKey: "limitPct_\(vin)")
        defaults.set(s.windowOn, forKey: "windowOn_\(vin)"); defaults.set(s.windowFrom, forKey: "windowFrom_\(vin)")
        defaults.set(s.windowTo, forKey: "windowTo_\(vin)")
    }

    /// Per-car memory of what the automation already tried, so it doesn't resend the same command on every refresh.
    private func loadState<T: Codable>(_ key: String, _ empty: T) -> T {
        guard let vin = vehicle?.vin, let d = defaults.data(forKey: "\(key)_\(vin)"), let v = try? JSONDecoder().decode(T.self, from: d) else { return empty }
        return v
    }

    private func saveState<T: Codable>(_ key: String, _ v: T) {
        guard let vin = vehicle?.vin else { return }
        defaults.set(try? JSONEncoder().encode(v), forKey: "\(key)_\(vin)")
    }

    /// After each refresh: stop at LionCar's limit, or outside the charging times.
    func runChargeAutomation() async {
        guard !isDemo, remote.isSetUp, commandLabel == nil, let st = serverStatus, st.energyType != "Fuel", let power else { return }
        let s = chargeSettings
        guard s.limitOn || s.windowOn else { return }
        var limitState = loadState("limitState", ChargeAutomation.LimitState())
        let limit = ChargeAutomation.limit(st, s, state: &limitState, sessionStart: activeSession?.start,
                                           kw: power.reading(st)?.kw, usableKwh: power.usableKwh(st))
        saveState("limitState", limitState)
        var windowState = loadState("windowState", ChargeAutomation.WindowState())
        // The limit's decision wins; the window is checked again on the next refresh.
        let window = limit.action == nil ? ChargeAutomation.window(st, s, state: &windowState) : ChargeAutomation.Decision()
        saveState("windowState", windowState)
        for d in [limit, window] {
            if let note = d.note { showToast(L(note)) }
            guard let action = d.action else { continue }
            let label = d == limit ? "Charge limit" : "Charging times"
            await runCommand(label, confirmWith: nil, quiet: true) { r, t in
                switch action {
                case .stop(let h, let m): await r.charging(startNow: false, hour: h, minute: m, t)
                case .start(let h, let m): await r.charging(startNow: true, hour: h, minute: m, t)
                }
            }
        }
    }

    // MARK: "Charged to X %" notification

    /// While charging, a notification is set for when the car should reach the target (iOS delivers it on time even
    /// when LionCar isn't running). It moves with every new report and is removed when charging stops.
    func scheduleTargetNotification() {
        let center = UNUserNotificationCenter.current()
        let id = "lioncar.chargeTarget"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard targetNotify, !isDemo, let st = status, st.isCharging, let left = chargeTimeLeft else { return }
        let at = (st.updatedAt ?? Date()).addingTimeInterval(Double(left.minutes) * 60)
        let wait = at.timeIntervalSinceNow
        guard wait > 30 else { return }
        let c = UNMutableNotificationContent()
        if let pct = left.pct {
            c.title = String(localized: "Charged to \(pct) %")
            c.body = chargeSettings.limitOn ? String(localized: "\(carName) should be at your limit now. If LionCar couldn't stop it, unplug it.")
                                            : String(localized: "\(carName) should be at \(pct) % now.")
        } else {
            c.title = String(localized: "Charging should be done")
            c.body = String(localized: "\(carName) should have finished charging.")
        }
        c.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)))
    }

    // MARK: Demo mode

    /// Shows a sample car of the chosen kind and brand. Your real account, remote-control setup and data are left alone.
    func enterDemo(kind: DemoCar.Kind = .electric, brand: Brand = .peugeot) {
        epoch += 1
        let d = DemoCar(kind: kind, brand: brand)
        demo = d
        vehicles = [d.vehicle]
        vehicle = d.vehicle
        rawTrips = []; loadedTripDays = 0; alerts = []
        makeChargeData(store: MemoryStore())
        if kind != .fuel { chargeLog?.places = DemoCar.places() }
        chargeLog?.replace(d.sessions())
        syncChargeLog()
        phase = .ready
        Task { await refresh(); await loadTrips() }
    }

    func exitDemo() {
        epoch += 1
        demo = nil
        rawStatus = nil; rawMaintenance = nil; rawTrips = []; loadedTripDays = 0; status = nil; serverStatus = nil; trips = []
        holdPrecond = nil
        guard api.isSignedIn else {
            vehicles = []; vehicle = nil; power = nil; chargeLog = nil; syncChargeLog()
            phase = .signedOut
            return
        }
        vehicles = api.cachedVehicles()
        vehicle = api.pick(vehicles)
        makeChargeData()
        loadCache()
        if vehicle == nil {
            phase = .loading
            Task { await afterSignIn(firstTime: true) }
        } else {
            phase = .ready
            Task { await refresh(); await loadTrips() }
        }
    }
}
