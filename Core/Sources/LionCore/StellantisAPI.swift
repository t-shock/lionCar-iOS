import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where secrets live: the Keychain on iOS, memory in tests.
public protocol SecretStore: AnyObject, Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String?)
}

public final class MemoryStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ key: String, _ value: String?) { lock.lock(); defer { lock.unlock() }; values[key] = value }
}

/// The Stellantis (ex-PSA) connected-car API, used the way the brand apps use it. Port of LionFlow's StellantisApi.kt.
///
/// Staying signed in: the server hands out a **new refresh token on every refresh** and the old one stops working.
/// So only one refresh may run at a time, and the new refresh token is saved before anything else happens.
public actor StellantisAPI {
    public static let api = "https://api.groupe-psa.com"
    static let kAccess = "oauth_access", kRefresh = "oauth_refresh", kExpires = "oauth_expires"
    static let kCustomer = "customer_id", kVehicles = "vehicles", kSelected = "selected_vin"

    private let store: SecretStore
    public let brand: Brand
    public let country: String
    public nonisolated let cfg: BrandConfig
    private var refreshing: Task<Void, Error>?

    public init(store: SecretStore, brand: Brand, country: String) {
        self.store = store; self.brand = brand; self.country = country
        cfg = StellantisConfig.load(brand, country: country)
    }

    public nonisolated var isSignedIn: Bool { store.get(Self.kRefresh) != nil }
    public nonisolated var customerID: String? { store.get(Self.kCustomer) }

    // Some countries' listed locale is refused by the server ("Invalid parameter: locale"). Then the next one is tried
    // and remembered: the country's own language, then British English.
    private nonisolated var localeKey: String { "locale_\(brand.rawValue)_\(country)" }
    private nonisolated var locale: String { store.get(localeKey) ?? cfg.locale }
    /// Switches to the next locale to try; false when there is none left.
    private func nextLocale() -> Bool {
        let countryCode = country.uppercased()
        let ownLanguage = ["IS": "is", "NO": "nb", "DK": "da", "SE": "sv", "FI": "fi", "EE": "et", "LV": "lv", "LT": "lt"][countryCode]
        var candidates: [String] = []
        for candidate in [cfg.locale, ownLanguage.map { "\($0)-\(countryCode)" }, "en-GB", "fr-FR"].compactMap({ $0 })
        where !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        guard let i = candidates.firstIndex(of: locale), i + 1 < candidates.count else { return false }
        store.set(localeKey, candidates[i + 1])
        return true
    }

    private nonisolated func clientQuery() -> String { "client_id=\(cfg.clientID)&locale=\(locale)" }

    private static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }

    public nonisolated func authorizeURL() -> URL {
        URL(string: "\(cfg.oauthURL)/am/oauth2/authorize?client_id=\(cfg.clientID)&response_type=code" +
            "&redirect_uri=\(cfg.redirectURI)&scope=openid%20profile%20email&locale=\(locale)")!
    }

    /// The code from the sign-in page's redirect (`mymap://oauth2redirect/gr?code=…`).
    public static func code(fromRedirect url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
    }

    // MARK: OAuth

    public func exchangeCode(_ code: String) async throws {
        try await tokenRequest("\(cfg.oauthURL)/am/oauth2/access_token?redirect_uri=\(cfg.redirectURI)" +
                               "&grant_type=authorization_code&code=\(Self.percentEncode(code))")
    }

    /// Single flight: callers that arrive during a refresh wait for it instead of spending the refresh token again.
    private func refreshOAuth() async throws {
        if let running = refreshing { return try await running.value }
        let task = Task { try await self.doRefresh() }
        refreshing = task
        defer { refreshing = nil }
        try await task.value
    }

    private func doRefresh() async throws {
        guard let refresh = store.get(Self.kRefresh) else { throw AuthExpiredError() }
        do {
            try await tokenRequest("\(cfg.oauthURL)/am/oauth2/access_token?grant_type=refresh_token&refresh_token=\(Self.percentEncode(refresh))")
        } catch let e as APIError where e.code == 400 || e.code == 401 {
            // The refresh token itself was refused: only signing in again helps.
            throw AuthExpiredError()
        }
    }

    private func tokenRequest(_ url: String) async throws {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.httpBody = Data()
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Basic \(cfg.basicToken)", forHTTPHeaderField: "Authorization")
        guard let j = try await HTTP.json(req) as? JSON else { throw APIError(0, "Empty token response") }
        guard let access = j.str("access_token") else { throw APIError(0, "No access token in response") }
        // The new refresh token first: the old one is already dead on the server.
        if let r = j.str("refresh_token") { store.set(Self.kRefresh, r) }
        store.set(Self.kAccess, access)
        let expiresIn = j.num("expires_in") ?? 3600
        store.set(Self.kExpires, String(Date().timeIntervalSince1970 + expiresIn))
    }

    /// A valid access token, refreshed when it has less than 5 minutes left.
    private func accessToken() async throws -> String {
        let expires = Double(store.get(Self.kExpires) ?? "") ?? 0
        if store.get(Self.kAccess) == nil || Date().timeIntervalSince1970 > expires - 5 * 60 { try await refreshOAuth() }
        guard let token = store.get(Self.kAccess) else { throw AuthExpiredError() }
        return token
    }

    /// Runs a call with an access token; on a "bad locale" answer, switches locale (see nextLocale) and tries again.
    private func authed<T>(_ block: (String) async throws -> T) async throws -> T {
        var localeSwitches = 0
        while true {
            do { return try await authedOnce(block) } catch let e as APIError {
                if e.code == 400 && e.message.localizedCaseInsensitiveContains("locale") && localeSwitches < 3 && nextLocale() {
                    localeSwitches += 1; continue
                }
                throw e
            }
        }
    }

    /// One try, plus one more with a refreshed token if the server says the token is no longer valid (401).
    private func authedOnce<T>(_ block: (String) async throws -> T) async throws -> T {
        let token = try await accessToken()
        do { return try await block(token) } catch let e as APIError where e.code == 401 {
            try await refreshOAuth()
            guard let fresh = store.get(Self.kAccess) else { throw AuthExpiredError() }
            return try await block(fresh)
        }
    }

    /// otpStyle: the headers the brand app sends to the remote-control endpoints (car associations, SMS, token).
    private func request(_ url: String, token: String, otpStyle: Bool = false) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(cfg.realm, forHTTPHeaderField: "x-introspect-realm")
        if otpStyle {
            r.setValue("okhttp/4.8.0", forHTTPHeaderField: "User-Agent")
            r.setValue("application/hal+json", forHTTPHeaderField: "Accept")
        }
        return r
    }

    // MARK: Account & vehicles

    /// Returns the customer id (needed for remote control) and stores it.
    @discardableResult
    public func loadUserInfo() async throws -> String? {
        try await authed { token in
            var r = request("\(Self.api)/applications/cvs/v4/mauv/car-associations?\(clientQuery())", token: token, otpStyle: true)
            r.setValue("1234", forHTTPHeaderField: "x-transaction-id")
            let arr = try await HTTP.json(r) as? [Any] ?? []
            // Some cars have no remote-services link here; status still works without it.
            let customer = arr.compactMap { ($0 as? JSON)?.optString("customer") }.first { !$0.isEmpty }
            if let customer { store.set(Self.kCustomer, customer) }
            return customer
        }
    }

    public func vehicles() async throws -> [Vehicle] {
        let before = cachedVehicles()
        let list: [Vehicle] = try await authed { token in
            let r = request("\(Self.api)/connectedcar/v4/user/vehicles?\(clientQuery())&extension=branding", token: token)
            guard let j = try await HTTP.json(r) as? JSON else { throw APIError(0, "Empty vehicle list") }
            let all = (j.obj("_embedded")?.objects("vehicles") ?? []).compactMap { Vehicle.fromAPI($0, defaultBrand: brand.display) }
            return Self.onePerVIN(all, preferring: before)
        }
        // Fill in model details for the chosen car when the list doesn't say enough to tell what kind of hybrid it is.
        var updated = list
        if let selected = pick(list), selected.needsBranding, let i = updated.firstIndex(of: selected) {
            let detail: JSON? = try? await authed { token in
                try await HTTP.json(request("\(Self.api)/connectedcar/v4/user/vehicles/\(selected.id)?\(clientQuery())&extension=branding", token: token)) as? JSON
            }
            updated[i] = selected.withBrandingDetail(detail)
        }
        store.set(Self.kVehicles, String(decoding: JSONValue.data(updated.map { $0.toJSON() }), as: UTF8.self))
        return updated
    }

    /// The same car can come twice (e.g. shared with another account): keep the one already in use, else the first.
    /// The list keeps the server's order.
    private static func onePerVIN(_ all: [Vehicle], preferring inUse: [Vehicle]) -> [Vehicle] {
        var byVIN: [String: [Vehicle]] = [:]
        var vinOrder: [String] = []
        for v in all {
            if byVIN[v.vin] == nil { vinOrder.append(v.vin) }
            byVIN[v.vin, default: []].append(v)
        }
        return vinOrder.map { vin in
            let copies = byVIN[vin]!
            return copies.first { copy in inUse.contains { $0.id == copy.id } } ?? copies[0]
        }
    }

    public nonisolated func cachedVehicles() -> [Vehicle] {
        guard let s = store.get(Self.kVehicles), let arr = JSONValue.parse(s) as? [Any] else { return [] }
        return arr.compactMap { ($0 as? JSON).flatMap(Vehicle.fromJSON) }
    }

    /// The car chosen in the app (accounts can have several).
    public nonisolated var selectedVIN: String? { store.get(Self.kSelected).flatMap { $0.isEmpty ? nil : $0 } }
    public nonisolated func select(vin: String?) { store.set(Self.kSelected, vin ?? "") }

    public nonisolated func pick(_ list: [Vehicle]) -> Vehicle? { list.first { $0.vin == selectedVIN } ?? list.first }

    public func status(_ v: Vehicle) async throws -> JSON {
        try await authed { token in
            guard let j = try await HTTP.json(request("\(Self.api)/connectedcar/v4/user/vehicles/\(v.id)/status?\(clientQuery())", token: token)) as? JSON
            else { throw APIError(0, "Empty status response") }
            return j
        }
    }

    /// Service figures; optional, so failures other than being signed out give nil.
    public func maintenance(_ v: Vehicle) async throws -> JSON? {
        var urls = [v.maintenanceHref, "\(Self.api)/connectedcar/v4/user/vehicles/\(v.id)/maintenance"].compactMap { $0 }
        if urls.count == 2 && urls[0] == urls[1] { urls.removeLast() }
        for href in urls {
            do {
                let j: JSON? = try await authed { token in
                    let sep = href.contains("?") ? "&" : "?"
                    return try await HTTP.json(request("\(href)\(sep)\(clientQuery())", token: token)) as? JSON
                }
                if let j, j.has("mileageBeforeMaintenance") || j.has("daysBeforeMaintenance") { return j }
            } catch is AuthExpiredError { throw AuthExpiredError() } catch { continue }
        }
        return nil
    }

    /// Warnings the car has reported (empty when there are none).
    public func alerts(_ v: Vehicle) async throws -> [JSON] {
        do {
            return try await authed { token in
                let j = try await HTTP.json(request("\(Self.api)/connectedcar/v4/user/vehicles/\(v.id)/alerts?\(clientQuery())", token: token)) as? JSON
                return j?.obj("_embedded")?.objects("alerts") ?? []
            }
        } catch let e as APIError where e.noData { return [] }
    }

    /// One page of trips since [since] (and until [until]), or the page at [next] (the server's own "next" link).
    public func trips(_ v: Vehicle, since: String?, until: String? = nil, next: String? = nil) async throws -> JSON {
        try await authed { token in
            var url: String
            if let next, next.hasPrefix(Self.api) {
                url = next.contains("client_id=") ? next : next + (next.contains("?") ? "&" : "?") + clientQuery()
            } else {
                url = "\(Self.api)/connectedcar/v4/user/vehicles/\(v.id)/trips?\(clientQuery())&distance=0.1-&pageSize=60"
                if let since { url += "&timestamps=\(since)/\(until ?? "")" }
            }
            return try await HTTP.json(request(url, token: token)) as? JSON ?? [:]
        }
    }

    /// All trips from [from] until now, asked for week by week following the server's "next" links (asking for the
    /// whole period at once could stop after the first page and leave out the newest trips). Four weeks are fetched
    /// at the same time.
    public func allTrips(_ v: Vehicle, from: Date, until: Date = Date()) async throws -> [JSON] {
        let windows = Self.weekWindows(from: from, until: until)
        let results: [[JSON]] = try await withThrowingTaskGroup(of: (Int, [JSON]).self) { group in
            var out = [[JSON]](repeating: [], count: windows.count)
            var next = 0
            func startNextWindow() {
                guard next < windows.count else { return }
                let i = next, (start, end) = windows[i]
                next += 1
                group.addTask { (i, try await self.tripsWindow(v, from: start, until: end)) }
            }
            for _ in 0..<4 { startNextWindow() }
            while let (i, list) = try await group.next() { out[i] = list; startNextWindow() }
            return out
        }
        var seen = Set<String>()
        return results.joined().filter { seen.insert($0.optString("id")).inserted }
    }

    /// Week-long periods going back from [until] to [from], newest first. When [until] is about now, the newest period
    /// is left open-ended (nil end).
    private static func weekWindows(from: Date, until: Date) -> [(Date, Date?)] {
        let week: TimeInterval = 7 * 86_400
        var windows: [(Date, Date?)] = []
        var end: Date? = until.timeIntervalSinceNow > -60 ? nil : until
        var start = until.addingTimeInterval(-week)
        while true {
            windows.append((max(start, from), end))
            if start <= from { break }
            end = start; start = start.addingTimeInterval(-week)
        }
        return windows
    }

    /// The trips of one period, page by page (at most 20 pages).
    private func tripsWindow(_ v: Vehicle, from start: Date, until end: Date?) async throws -> [JSON] {
        var byID: [String: JSON] = [:]
        var order: [String] = []
        var next: String? = nil
        var pages = 0
        repeat {
            let page: JSON
            // "404 / 40400 No trip was found" just means no trips in this period.
            do { page = try await trips(v, since: ISODate.format(start), until: end.map(ISODate.format), next: next) }
            catch let e as APIError where e.noData { break }
            var newTrips = 0
            for trip in page.obj("_embedded")?.objects("trips") ?? [] {
                let id = trip.optString("id")
                if byID[id] == nil { order.append(id); newTrips += 1 }
                byID[id] = trip
            }
            next = page.obj("_links", "next")?.str("href").flatMap { $0.isEmpty ? nil : $0 }
            pages += 1
            // Stop when a page brings nothing new, so a "next" link that repeats can't loop.
            if newTrips == 0 { break }
        } while next != nil && pages < 20
        return order.compactMap { byID[$0] }
    }

    // MARK: Remote control setup

    public func requestSMSCode() async throws {
        _ = try await authed { token in
            var r = request("\(Self.api)/applications/cvs/v4/mobile/smsCode?\(clientQuery())", token: token, otpStyle: true)
            r.httpMethod = "POST"; r.httpBody = Data()
            return try await HTTP.text(r)
        }
    }

    /// POSTs to the virtual-key token endpoint (password grant with an OTP, or refresh grant).
    public func mqttToken(_ body: JSON) async throws -> JSON {
        try await authed { token in
            var r = request("\(Self.api)/connectedcar/v4/virtualkey/remoteaccess/token?\(clientQuery())", token: token, otpStyle: true)
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = JSONValue.data(body)
            return try await HTTP.json(r) as? JSON ?? [:]
        }
    }

    /// The current access token; its start becomes the OTP device id at activation, like the reference implementation.
    public nonisolated var currentAccessToken: String? { store.get(Self.kAccess) }

    public nonisolated func signOut() {
        for k in [Self.kAccess, Self.kRefresh, Self.kExpires, Self.kCustomer, Self.kVehicles, Self.kSelected] { store.set(k, nil) }
    }
}
