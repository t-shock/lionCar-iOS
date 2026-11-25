import Foundation
import UIKit
import Observation
import LocalAuthentication
import LionCore

/// The app's state and actions (LionFlow's AppViewModel, trimmed to what this version does).
@Observable @MainActor
final class AppModel {
    enum Phase { case signedOut, loading, ready }

    private let store = KeychainStore()
    let defaults = UserDefaults.standard
    var api: StellantisAPI
    private(set) var remote: RemoteControl

    var phase: Phase = .signedOut
    var brand: Brand
    var country: String
    var vehicles: [Vehicle] = []
    var vehicle: Vehicle?
    var status: VehicleStatus?
    var statusMissing = false
    var alerts: [JSON] = []
    var trips: [Trip] = []
    var tripsLoading = false
    var refreshing = false
    var signingIn = false
    var lastRefresh: Date?
    var message: String?
    /// A short note that disappears by itself (e.g. "Lock — done").
    var toast: String?
    /// The command on its way ("Lock") and what's happening with it ("Waking the car…").
    var commandLabel: String?
    var commandProgress: String?
    var commandLog: [String] = []
    var smsSent = false
    var setupBusy = false
    // Costs, tank, tags and warnings (see AppModel+Extras.swift)
    var fuelPrice: Double? = UserDefaults.standard.object(forKey: "fuelPrice") as? Double {
        didSet { if let fuelPrice { defaults.set(fuelPrice, forKey: "fuelPrice") } else { defaults.removeObject(forKey: "fuelPrice") } }
    }
    var tagBook = TagBook.decode(UserDefaults.standard.string(forKey: "tagBook")) {
        didSet { defaults.set(tagBook.encoded(), forKey: "tagBook") }
    }
    var alertSettings = AppModel.loadAlertSettings() { didSet { saveAlertSettings() } }
    var alertState = AppModel.loadAlertState() { didSet { saveAlertState() } }

    /// Lock state shown after a command until the car reports again (its status lags behind).
    private var holdLock: (value: Bool, since: Date)?
    /// Same for pre-heating.
    var holdPrecond: (value: Bool, since: Date)?

    // Electric cars (see AppModel+EV.swift)
    /// Demo mode: a sample electric car; nothing is sent anywhere.
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
    var chargeSettings = AppModel.loadChargeSettings() { didSet { saveChargeSettings() } }
    var targetNotify: Bool = UserDefaults.standard.object(forKey: "targetNotify") as? Bool ?? true {
        didSet { defaults.set(targetNotify, forKey: "targetNotify") }
    }

    init() {
        let b = Brand.of(UserDefaults.standard.string(forKey: "brand"))
        let c = UserDefaults.standard.string(forKey: "country") ?? (Locale.current.region?.identifier ?? "GB")
        brand = b
        country = c
        let a = StellantisAPI(store: store, brand: b, country: c)
        api = a
        remote = RemoteControl(api: a, store: store, makeTransport: { NWTransport() })
        if api.isSignedIn {
            vehicles = api.cachedVehicles()
            vehicle = api.pick(vehicles)
            makeChargeData()
            loadCache()
            phase = vehicle == nil ? .loading : .ready
            Task { await afterSignIn(firstTime: vehicle == nil) }
        }
    }

    // MARK: Sign-in

    func setAccount(brand: Brand, country: String) {
        self.brand = brand; self.country = country
        defaults.set(brand.rawValue, forKey: "brand"); defaults.set(country, forKey: "country")
        api = StellantisAPI(store: store, brand: brand, country: country)
        remote = RemoteControl(api: api, store: store, makeTransport: { NWTransport() })
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

    private func expired() {
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

    // MARK: Car data

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

    var rawStatus: JSON?
    /// The status exactly as the server sent it (without the lock state held after a command).
    var serverStatus: VehicleStatus?
    var rawMaintenance: JSON?
    var rawTrips: [JSON] = []

    func refresh() async {
        guard let v = vehicle else { return }
        if let demo {
            rawStatus = demo.statusJSON(); rawMaintenance = nil; statusMissing = false; lastRefresh = .now
            reparse()
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
            if let st = status, let scale = FuelCalibration.litersPerUnit(totalRaw: st.fuelTotalRaw, odometerKm: st.odometerKm) {
                defaults.set(scale, forKey: "fuelScale_\(v.vin)")
            }
            saveCache()
            checkAlerts()
            scheduleTargetNotification()
            Task { await self.runChargeAutomation() }
        } catch is AuthExpiredError {
            expired()
        } catch {
            message = String(localized: "Couldn't update — \(HTTP.describe(error))")
        }
    }

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

    /// Trips in the chosen period, newest first.
    var shownTrips: [Trip] {
        let from = Date().addingTimeInterval(-Double(tripDays) * 86_400)
        return trips.filter { ($0.start ?? .distantPast) >= from }
    }

    /// Loads [days] of trips (default: the chosen period), or with [recentOnly] just the last two weeks, and merges
    /// them with what is already loaded.
    func loadTrips(days: Int? = nil, recentOnly: Bool = false) async {
        guard let v = vehicle else { return }
        if isDemo { rawTrips = DemoCar.tripsJSON(); loadedTripDays = 365; reparseTrips(); return }
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

    func reparse() {
        guard let v = vehicle, let s = rawStatus else { return }
        var st = v.parseStatus(s, maintenance: rawMaintenance, override: mildHybridOverride)
        st = recordCharging(st)
        serverStatus = st
        if let h = holdPrecond {
            if let at = st.updatedAt, at > h.since || Date().timeIntervalSince(h.since) > 300 { holdPrecond = nil }
            else { st.preconditioningOn = h.value }
        }
        if let h = holdLock {
            // Keep showing what was sent until the car reports something newer than the command.
            if let at = st.updatedAt, at > h.since || Date().timeIntervalSince(h.since) > 300 { holdLock = nil }
            else { st.locked = h.value }
        }
        status = st
        reparseTrips()
    }

    func reparseTrips() {
        let mild = status?.isMildHybrid ?? (vehicle?.isMildHybrid(override: mildHybridOverride) ?? false)
        let scale = status?.energyType == "Electric" ? nil : litersPerUnit
        trips = rawTrips.map { Trip.parse($0, mildHybrid: mild, litersPerUnit: scale) }
            .sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
    }

    // MARK: Remote control

    var remoteReady: Bool { isDemo || remote.isSetUp }
    /// False when the brand has no remote-services link for this account: then don't offer setup at all.
    var remotePossible: Bool { isDemo || api.customerID != nil || remote.isSetUp }

    func requestSMS() async {
        guard !isDemo else { return }
        setupBusy = true
        defer { setupBusy = false }
        do {
            try await remote.requestSMS()
            smsSent = true
        } catch is AuthExpiredError { expired() } catch {
            message = String(localized: "Couldn't send the SMS — \(HTTP.describe(error))")
        }
    }

    func activateRemote(sms: String, pin: String) async -> Bool {
        guard !isDemo else { return false }
        setupBusy = true
        defer { setupBusy = false }
        do {
            try await remote.activate(sms: sms, pin: pin)
            smsSent = false
            showToast(String(localized: "Remote control is ready"))
            return true
        } catch is AuthExpiredError {
            expired(); return false
        } catch {
            message = String(localized: "Activation failed — \(HTTP.describe(error))")
            return false
        }
    }

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self.toast == text { self.toast = nil }
        }
    }

    func forgetRemote() {
        guard !isDemo else { return }
        let r = remote
        Task { await r.forget() }
    }

    func loadCommandLog() async { commandLog = await remote.log }

    /// Face ID / Touch ID, or the phone's passcode, before acting on the real car.
    func confirm(_ reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    @discardableResult
    func runCommand(_ label: String, confirmWith reason: String?, optimistic: ((inout VehicleStatus) -> Void)? = nil,
                    quiet: Bool = false, demoCommand: String? = nil, demoPrograms: [Program]? = nil,
                    _ block: @escaping (RemoteControl, Tracker) async -> CommandResult) async -> CommandResult? {
        if let demo {
            // Demo: nothing is sent; the sample car just changes.
            guard commandLabel == nil else { return nil }
            commandLabel = label
            commandProgress = "Sending…"
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if let demoCommand { demo.apply(demoCommand, programs: demoPrograms) }
            commandLabel = nil; commandProgress = nil
            await refresh()
            if !quiet { showToast(String(localized: "\(L(label)) — done (demo)")) }
            return .success
        }
        guard remote.isSetUp else { message = String(localized: "Set up remote control first (Settings › Remote control)"); return nil }
        guard commandLabel == nil else { return nil }
        if let reason, !(await confirm(reason)) { return nil }
        commandLabel = label
        commandProgress = "Sending…"
        let tracker = Tracker(
            onProgress: { p in Task { @MainActor in self.commandProgress = p } },
            // Arrives later only when we stopped waiting at "delivered".
            onFinal: { r in Task { @MainActor in
                if case .failed(let why) = r { self.holdLock = nil; self.holdPrecond = nil; self.reparse(); self.message = String(localized: "\(L(label)) didn't go through: \(why)") }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.refresh()
            } })
        let result = await block(remote, tracker)
        commandLabel = nil
        commandProgress = nil
        switch result {
        case .success, .delivered:
            optimistic.map { f in if var st = status { f(&st); status = st } }
            if !quiet {
                showToast(result == .delivered ? String(localized: "\(L(label)) — the car got it") : String(localized: "\(L(label)) — done"))
                Task {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    await self.refresh()
                }
            }
        case .failed(let why):
            holdLock = nil
            holdPrecond = nil
            reparse()
            message = String(localized: "\(L(label)): \(why)")
        }
        return result
    }

    func lockCar(_ lock: Bool) async {
        await runCommand(lock ? "Lock" : "Unlock", confirmWith: lock ? nil : "Unlock your car",
                         optimistic: { [weak self] st in st.locked = lock; self?.holdLock = (lock, Date()) },
                         demoCommand: lock ? "lock" : "unlock") { r, t in await r.lock(lock, t) }
    }

    func horn() async { await runCommand("Horn", confirmWith: "Sound the horn") { r, t in await r.horn(t) } }
    func lights() async { await runCommand("Flash lights", confirmWith: nil) { r, t in await r.lights(t) } }

    /// Asks the car to report now, then reads the fresh status.
    var updatingFromCar = false

    /// Wakes the car so it reports now, then checks every 10 s (up to 2 minutes) until a newer report arrives.
    func wakeAndRefresh() async {
        if isDemo { await refresh(); showToast(String(localized: "Updated — the car just reported")); return }
        guard !updatingFromCar else { return }
        updatingFromCar = true
        defer { updatingFromCar = false }
        let before = status?.updatedAt
        guard let r = await runCommand("Updating from the car", confirmWith: nil, quiet: true, { r, t in await r.wakeUp(t) })
        else { return }
        if case .failed = r { return }
        commandLabel = "Updating from the car"
        commandProgress = "Waiting for the car to report…"
        defer { commandLabel = nil; commandProgress = nil }
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await refresh()
            if let now = status?.updatedAt, before.map({ now > $0 }) ?? true {
                showToast(String(localized: "Updated — the car just reported"))
                await loadTrips(recentOnly: true)
                return
            }
        }
        message = String(localized: "The car didn't send a new report yet. It may be out of mobile coverage (for example in a garage); try again later.")
    }

    /// Opens the remote-control connection early, so a command goes out faster.
    func warmUpRemote() {
        guard !isDemo, remote.isSetUp else { return }
        let r = remote
        Task { await r.warmUp() }
    }

    // MARK: Car tab layout

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

    /// The cards in the user's order; hidden ones are left out of [visibleCards].
    var homeOrder: [HomeCard] = AppModel.loadOrder() { didSet { saveLayout() } }
    var hiddenCards: Set<HomeCard> = Set((UserDefaults.standard.stringArray(forKey: "homeHidden") ?? []).compactMap(HomeCard.init)) {
        didSet { saveLayout() }
    }
    var visibleCards: [HomeCard] { homeOrder.filter { !hiddenCards.contains($0) } }

    private static func loadOrder() -> [HomeCard] {
        let saved = (UserDefaults.standard.stringArray(forKey: "homeOrder") ?? []).compactMap(HomeCard.init)
        return saved + HomeCard.allCases.filter { !saved.contains($0) }
    }

    private func saveLayout() {
        defaults.set(homeOrder.map(\.rawValue), forKey: "homeOrder")
        defaults.set(hiddenCards.map(\.rawValue), forKey: "homeHidden")
    }

    func resetLayout() { homeOrder = HomeCard.allCases; hiddenCards = [] }

    // MARK: Cache (so the app opens with the last known state, before the network answers)

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
        if rawStatus == nil { reparseTrips() }
    }

    private func clearCache() {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix("car-") { try? FileManager.default.removeItem(at: f) }
    }
}
