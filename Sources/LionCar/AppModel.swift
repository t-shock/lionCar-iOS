import Foundation
import CoreLocation
import UIKit
import Observation
import LionCore

/// The app's state and actions (LionFlow's AppViewModel). This file holds the state, sign-in, loading the car's
/// data, the Car tab layout and the cache. The rest is in extensions: remote commands (AppModel+Remote), electric cars
/// and demo mode (AppModel+EV), costs, tags and warnings (AppModel+Extras), and the map (AppModel+Map).
/// @Observable needs every stored property in the class itself, so they are all here.
@Observable @MainActor
final class AppModel {
    enum Phase { case signedOut, loading, ready }

    // MARK: Account

    private let store = KeychainStore()
    let defaults = UserDefaults.standard
    var api: StellantisAPI
    private(set) var remote: RemoteControl
    var phase: Phase = .signedOut
    var brand: Brand
    var country: String
    var signingIn = false
    /// An error or notice, shown as an alert.
    var message: String?
    /// A short note that disappears by itself (e.g. "Lock — done").
    var toast: String?

    // MARK: The shown car

    var vehicles: [Vehicle] = []
    var vehicle: Vehicle?
    var status: VehicleStatus?
    /// The status exactly as the server sent it (without the lock state held after a command).
    var serverStatus: VehicleStatus?
    var statusMissing = false
    var alerts: [JSON] = []
    var refreshing = false
    var lastRefresh: Date?
    /// The answers as received. `status` and `trips` are parsed from them, again whenever a setting changes the result.
    var rawStatus: JSON?
    var rawMaintenance: JSON?
    var rawTrips: [JSON] = []

    // MARK: Trips

    var trips: [Trip] = []
    var tripsLoading = false
    /// The period shown on the Trips tab, in days.
    var tripDays: Int = UserDefaults.standard.object(forKey: "tripDays") as? Int ?? 30 {
        didSet {
            defaults.set(tripDays, forKey: "tripDays")
            if tripDays > loadedTripDays { Task { await loadTrips(days: tripDays) } }
        }
    }
    /// How far back the trips in memory reach (days).
    var loadedTripDays = 0
    /// The longest period asked for while a load was already running; loaded as soon as it finishes.
    private var pendingTripDays = 0

    // MARK: Remote commands (see AppModel+Remote.swift)

    /// The command on its way ("Lock") and what's happening with it ("Waking the car…").
    var commandLabel: String?
    var commandProgress: String?
    var commandLog: [String] = []
    var smsSent = false
    var setupBusy = false
    /// True while `wakeAndRefresh()` waits for the car's new report, so it can't be started twice.
    var updatingFromCar = false
    /// Lock state shown after a command until the car reports again (its status lags behind).
    var holdLock: (value: Bool, since: Date)?
    /// Same for pre-heating.
    var holdPrecond: (value: Bool, since: Date)?

    // MARK: Costs, tags and warnings (see AppModel+Extras.swift)

    var fuelPrice: Double? = UserDefaults.standard.object(forKey: "fuelPrice") as? Double {
        didSet { if let fuelPrice { defaults.set(fuelPrice, forKey: "fuelPrice") } else { defaults.removeObject(forKey: "fuelPrice") } }
    }
    var tagBook = TagBook.decode(UserDefaults.standard.string(forKey: "tagBook")) {
        didSet { defaults.set(tagBook.encoded(), forKey: "tagBook") }
    }
    var alertSettings = AppModel.loadAlertSettings() { didSet { saveAlertSettings() } }
    var alertState = AppModel.loadAlertState() { didSet { saveAlertState() } }

    // MARK: Electric cars and demo mode (see AppModel+EV.swift)

    /// Demo mode: a sample car; nothing is sent anywhere.
    var demo: DemoCar?
    var isDemo: Bool { demo != nil }
    /// Changes whenever the shown car changes (demo on/off, another car, sign-out). Work started before a change
    /// checks it after every wait and drops its result, so the real car's and the demo car's data never mix.
    var epoch = 0
    var power: ChargePower?
    var chargeLog: ChargeLog?
    /// Mirrors of the charge log, so the screens update.
    var chargeSessions: [ChargeSession] = []
    var activeSession: ChargeSession?
    var chargePlaces = PlacesConfig()
    /// Replaced with the shown car's own settings in `makeChargeData()`.
    var chargeSettings = AppModel.loadChargeSettings() { didSet { saveChargeSettings() } }
    var targetNotify: Bool = UserDefaults.standard.object(forKey: "targetNotify") as? Bool ?? true {
        didSet { defaults.set(targetNotify, forKey: "targetNotify") }
    }

    // MARK: Map (see AppModel+Map.swift)

    var places: [Charger] = []
    var placesLoading = false
    var placesError: String?
    var placesCenter: CLLocationCoordinate2D?

    // MARK: Car tab layout

    /// The cards in the user's order; hidden ones are left out of `visibleCards`.
    var homeOrder: [HomeCard] = AppModel.loadOrder() { didSet { saveLayout() } }
    var hiddenCards: Set<HomeCard> = Set((UserDefaults.standard.stringArray(forKey: "homeHidden") ?? []).compactMap(HomeCard.init)) {
        didSet { saveLayout() }
    }

    // MARK: - Start-up

    init() {
        let b = Brand.of(UserDefaults.standard.string(forKey: "brand"))
        let c = UserDefaults.standard.string(forKey: "country") ?? (Locale.current.region?.identifier ?? "GB")
        brand = b
        country = c
        let a = StellantisAPI(store: store, brand: b, country: c)
        api = a
        remote = Self.makeRemote(api: a, store: store)
        if api.isSignedIn {
            // Show the last known state straight away; the network catches up in afterSignIn.
            vehicles = api.cachedVehicles()
            vehicle = api.pick(vehicles)
            makeChargeData()
            loadCache()
            phase = vehicle == nil ? .loading : .ready
            Task { await afterSignIn(firstTime: vehicle == nil) }
        }
    }

    private static func makeRemote(api: StellantisAPI, store: KeychainStore) -> RemoteControl {
        RemoteControl(api: api, store: store, makeTransport: { NWTransport() })
    }

    // MARK: - Sign-in

    func setAccount(brand: Brand, country: String) {
        self.brand = brand; self.country = country
        defaults.set(brand.rawValue, forKey: "brand"); defaults.set(country, forKey: "country")
        api = StellantisAPI(store: store, brand: brand, country: country)
        remote = Self.makeRemote(api: api, store: store)
    }

    var authorizeURL: URL { api.authorizeURL() }
    var callbackScheme: String { api.cfg.scheme }

    func finishSignIn(redirect: URL) async {
        guard let code = StellantisAPI.code(fromRedirect: redirect) else {
            message = String(localized: "Sign-in was cancelled"); return
        }
        signingIn = true
        defer { signingIn = false }
        do {
            try await api.exchangeCode(code)
            phase = .loading
            await afterSignIn(firstTime: true)
        } catch {
            phase = .signedOut
            message = String(localized: "Sign-in failed — \(HTTP.describe(error))")
        }
    }

    /// Loads the account's cars, then the chosen car's status and trips.
    func afterSignIn(firstTime: Bool) async {
        let e = epoch
        do {
            try await api.loadUserInfo()
            let list = try await api.vehicles()
            guard e == epoch, !isDemo else { return }
            vehicles = list
            vehicle = api.pick(list)
            makeChargeData()
            guard vehicle != nil else {
                message = String(localized: "No car found on this account — add it in the \(brand.app) app first")
                phase = .signedOut; api.signOut(); return
            }
            phase = .ready
            await refresh()
            guard e == epoch else { return }
            // A background wake-up stops here: the warnings only need the status.
            if UIApplication.shared.applicationState == .background { return }
            await loadTrips(recentOnly: true)
            if loadedTripDays < tripDays { await loadTrips() }
        } catch is AuthExpiredError {
            expired()
        } catch {
            if firstTime && vehicle == nil { phase = .signedOut }
            message = String(localized: "Couldn't load your cars — \(HTTP.describe(error))")
        }
    }

    /// The server no longer accepts the sign-in: back to the sign-in screen.
    func expired() {
        api.signOut()
        clearCache()
        phase = .signedOut
        message = String(localized: "Your \(brand.display) session expired — please sign in again")
    }

    func signOut() {
        if isDemo { exitDemo(); return }
        epoch += 1
        let r = remote
        Task { await r.forget() }
        api.signOut()
        clearCache()
        vehicles = []; vehicle = nil; status = nil; trips = []; alerts = []
        phase = .signedOut
    }

    func select(_ v: Vehicle) {
        epoch += 1
        api.select(vin: v.vin)
        vehicle = v; status = nil; trips = []; alerts = []; rawTrips = []; loadedTripDays = 0
        makeChargeData()
        loadCache()
        Task { await refresh(); await loadTrips() }
    }

    // MARK: - Car data

    var mildHybridOverride: Bool? {
        get {
            guard let vin = vehicle?.vin, let v = defaults.object(forKey: "mildHybrid_\(vin)") as? Bool else { return nil }
            return v
        }
        set {
            guard let vin = vehicle?.vin else { return }
            if let newValue { defaults.set(newValue, forKey: "mildHybrid_\(vin)") } else { defaults.removeObject(forKey: "mildHybrid_\(vin)") }
            reparse()
        }
    }

    var kind: String { vehicle?.kind(override: mildHybridOverride) ?? "Car" }

    /// Litres per raw fuel unit for this car, learnt from its lifetime fuel counter.
    var litersPerUnit: Double? {
        guard let vin = vehicle?.vin else { return nil }
        let v = defaults.double(forKey: "fuelScale_\(vin)")
        return v > 0 ? v : nil
    }

    /// Learns `litersPerUnit` from the latest status, when it has the counters for it.
    private func learnFuelScale(vin: String) {
        if let st = status, let scale = FuelCalibration.litersPerUnit(totalRaw: st.fuelTotalRaw, odometerKm: st.odometerKm) {
            defaults.set(scale, forKey: "fuelScale_\(vin)")
        }
    }

    /// Fetches the latest status, then saves it, posts any warnings, moves the "charged" notification and lets
    /// LionCar's charge limit and window act on it.
    func refresh() async {
        guard let v = vehicle else { return }
        if let demo {
            rawStatus = demo.statusJSON(); rawMaintenance = nil; statusMissing = false; lastRefresh = .now
            reparse()
            learnFuelScale(vin: v.vin)
            return
        }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let e = epoch
        do {
            var missing = false
            let s: JSON
            do { s = try await api.status(v) }
            catch let err as APIError where err.noData { s = [:]; missing = true }
            let maintenance = try await api.maintenance(v)
            let newAlerts = (try? await api.alerts(v)) ?? []
            // The shown car changed meanwhile (demo, another car): drop this answer.
            guard e == epoch, vehicle?.vin == v.vin else { return }
            statusMissing = missing
            rawStatus = s
            rawMaintenance = maintenance
            alerts = newAlerts
            lastRefresh = .now
            reparse()
            learnFuelScale(vin: v.vin)
            saveCache()
            checkAlerts()
            scheduleTargetNotification()
            // Its own task, as it may send commands and wait for the car.
            Task { await self.runChargeAutomation() }
        } catch is AuthExpiredError {
            expired()
        } catch {
            message = String(localized: "Couldn't update — \(HTTP.describe(error))")
        }
    }

    /// Trips in the chosen period, newest first.
    var shownTrips: [Trip] {
        let from = Date().addingTimeInterval(-Double(tripDays) * 86_400)
        return trips.filter { ($0.start ?? .distantPast) >= from }
    }

    /// Loads [days] of trips (default: the chosen period), or with [recentOnly] just the last two weeks, and merges
    /// them with what is already loaded.
    func loadTrips(days: Int? = nil, recentOnly: Bool = false) async {
        guard let v = vehicle else { return }
        if let demo { rawTrips = demo.tripsJSON(); loadedTripDays = 365; reparseTrips(); return }
        let want = recentOnly && loadedTripDays >= 14 ? 14 : max(days ?? tripDays, 7)
        if tripsLoading { pendingTripDays = max(pendingTripDays, want); return }
        tripsLoading = true
        await fetchTrips(v, days: want)
        tripsLoading = false
        if pendingTripDays > loadedTripDays {
            let next = pendingTripDays
            pendingTripDays = 0
            await loadTrips(days: next)
        } else {
            pendingTripDays = 0
        }
    }

    private func fetchTrips(_ v: Vehicle, days want: Int) async {
        let e = epoch
        do {
            let fresh = try await api.allTrips(v, from: Date().addingTimeInterval(-Double(want) * 86_400))
            guard e == epoch, vehicle?.vin == v.vin else { return }
            // Merge by trip id; a fresh copy replaces the old one.
            var byID: [String: JSON] = [:]
            for t in rawTrips + fresh { byID[t.optString("id")] = t }
            rawTrips = Array(byID.values)
            loadedTripDays = max(loadedTripDays, want)
            reparseTrips()
            saveCache()
        } catch is AuthExpiredError {
            expired()
        } catch {
            message = String(localized: "Couldn't load trips — \(HTTP.describe(error))")
        }
    }

    /// Builds `status` (and the trips) from the raw answers, showing a value just sent until the car confirms it.
    func reparse() {
        guard let v = vehicle, let s = rawStatus else { return }
        var st = v.parseStatus(s, maintenance: rawMaintenance, override: mildHybridOverride)
        st = recordCharging(st)
        serverStatus = st
        if let h = holdPrecond {
            if Self.holdIsOver(h, reportedAt: st.updatedAt) { holdPrecond = nil } else { st.preconditioningOn = h.value }
        }
        if let h = holdLock {
            if Self.holdIsOver(h, reportedAt: st.updatedAt) { holdLock = nil } else { st.locked = h.value }
        }
        status = st
        reparseTrips()
    }

    /// A held value ends once the car reports something newer than the command, or after 5 minutes.
    /// A report without a time doesn't end it.
    private static func holdIsOver(_ hold: (value: Bool, since: Date), reportedAt: Date?) -> Bool {
        guard let at = reportedAt else { return false }
        return at > hold.since || Date().timeIntervalSince(hold.since) > 300
    }

    func reparseTrips() {
        let mild = status?.isMildHybrid ?? (vehicle?.isMildHybrid(override: mildHybridOverride) ?? false)
        let scale = status?.energyType == "Electric" ? nil : litersPerUnit
        trips = rawTrips.map { Trip.parse($0, mildHybrid: mild, litersPerUnit: scale) }
            .sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
    }

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            // Only clear it if no newer toast replaced it meanwhile.
            if self.toast == text { self.toast = nil }
        }
    }

    // MARK: - Car tab layout

    enum HomeCard: String, CaseIterable, Identifiable {
        case energy, charging, climate, doors, map, details
        var id: String { rawValue }
        var title: String {
            switch self {
            case .energy: "Fuel / battery and range"
            case .charging: "Charging"
            case .climate: "Pre-heating"
            case .doors: "Locks and remote control"
            case .map: "Where the car is"
            case .details: "Odometer, service and more"
            }
        }
        var icon: String {
            switch self {
            case .energy: "gauge.with.dots.needle.67percent"
            case .charging: "bolt.car"
            case .climate: "fan"
            case .doors: "lock.fill"
            case .map: "map"
            case .details: "square.grid.2x2"
            }
        }
    }

    var visibleCards: [HomeCard] { homeOrder.filter { !hiddenCards.contains($0) } }

    /// The saved order, with cards added in a newer version appended at the end.
    private static func loadOrder() -> [HomeCard] {
        let saved = (UserDefaults.standard.stringArray(forKey: "homeOrder") ?? []).compactMap(HomeCard.init)
        return saved + HomeCard.allCases.filter { !saved.contains($0) }
    }

    private func saveLayout() {
        defaults.set(homeOrder.map(\.rawValue), forKey: "homeOrder")
        defaults.set(hiddenCards.map(\.rawValue), forKey: "homeHidden")
    }

    func resetLayout() { homeOrder = HomeCard.allCases; hiddenCards = [] }

    // MARK: - Cache (so the app opens with the last known state, before the network answers)

    private var cacheURL: URL? {
        guard let vin = vehicle?.vin, let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("car-\(vin.suffix(6)).json")
    }

    func saveCache() {
        guard !isDemo, let url = cacheURL else { return }
        var j: JSON = ["trips": rawTrips]
        if let rawStatus { j["status"] = rawStatus }
        if let rawMaintenance { j["maintenance"] = rawMaintenance }
        if let lastRefresh { j["at"] = lastRefresh.timeIntervalSince1970 }
        j["tripDays"] = loadedTripDays
        try? JSONValue.data(j).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func loadCache() {
        guard let url = cacheURL, let d = try? Data(contentsOf: url), let j = JSONValue.parse(d) as? JSON else { return }
        rawStatus = j.obj("status")
        rawMaintenance = j.obj("maintenance")
        rawTrips = j.objects("trips")
        lastRefresh = j.num("at").map { Date(timeIntervalSince1970: $0) }
        loadedTripDays = Int(j.num("tripDays") ?? 0)
        reparse()
        // reparse() stops early without a status, so parse the trips here.
        if rawStatus == nil { reparseTrips() }
    }

    private func clearCache() {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix("car-") { try? FileManager.default.removeItem(at: f) }
    }
}
