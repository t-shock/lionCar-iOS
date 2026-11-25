import Foundation

public enum CommandResult: Equatable, Sendable {
    case success
    /// The car has received the command; its final answer may follow later.
    case delivered
    case failed(String)
}

/// Follows one command: progress lines while waiting, and the car's final answer if it comes after we stopped waiting.
public struct Tracker: Sendable {
    public var onProgress: @Sendable (String) -> Void
    public var onFinal: @Sendable (CommandResult) -> Void
    public init(onProgress: @escaping @Sendable (String) -> Void = { _ in }, onFinal: @escaping @Sendable (CommandResult) -> Void = { _ in }) {
        self.onProgress = onProgress; self.onFinal = onFinal
    }
}

/// Remote commands (lock, horn, lights, climate, charging) go over MQTT, exactly like the brand apps. The MQTT password
/// is a short-lived token obtained with a one-time password from [Otp]; a refresh token (valid ~3 days) avoids asking
/// for new one-time passwords too often. Port of LionFlow's RemoteControl.kt.
public actor RemoteControl {
    static let kOTP = "otp_state", kPIN = "security_code"
    static let kMqttAccess = "mqtt_access", kMqttExp = "mqtt_expires", kMqttRefresh = "mqtt_refresh", kMqttRefreshExp = "mqtt_refresh_expires"
    static let broker = (host: "mwa.mpsa.com", port: 8885)
    static let inProgress: Set<String> = ["900", "901", "902"]

    private let api: StellantisAPI
    private let store: SecretStore
    private let makeTransport: @Sendable () -> MQTTTransport
    private var client: MQTTClient?
    private var busy = false
    /// The one "get a token and connect" in progress: a warm-up and a command must not both fetch tokens (each fresh
    /// one-time code advances the generator, and only a few are allowed a day) or open two connections.
    private var preparing: Task<MQTTClient, Error>?
    var controlTimeout: Double = 20

    /// Listeners for answers, by correlation id.
    private var waiters: [String: CheckedContinuation<String?, Never>] = [:]
    private var early: [String: String] = [:]
    private var expected: Set<String> = []
    private var progress: [String: @Sendable (String) -> Void] = [:]
    private var finals: [String: @Sendable (CommandResult) -> Void] = [:]
    private var services: [String: String] = [:]
    private var reasons: [String: String] = [:]
    private var brandReasons: [String: String] = [:]

    /// Last answers from the car, newest first — for troubleshooting.
    public private(set) var log: [String] = []
    /// Waits are shortened in tests.
    var timeoutScale: Double = 1

    public init(api: StellantisAPI, store: SecretStore, makeTransport: @escaping @Sendable () -> MQTTTransport) {
        self.api = api; self.store = store; self.makeTransport = makeTransport
    }

    public nonisolated var isSetUp: Bool { store.get(Self.kOTP) != nil }

    public func addLog(_ line: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.insert("\(f.string(from: Date()))  \(line)", at: 0)
        if log.count > 40 { log.removeLast(log.count - 40) }
    }

    // MARK: Setup

    public func requestSMS() async throws { try await api.requestSMSCode() }

    /// Activate remote control with the SMS code and the brand app's security code.
    public func activate(sms: String, pin: String) async throws {
        let deviceID = String((api.currentAccessToken ?? Otp.randomHex(8)).prefix(16))
        let otp = Otp(deviceID: deviceID)
        try await otp.activate(sms: sms.trimmingCharacters(in: .whitespaces), pin: pin.trimmingCharacters(in: .whitespaces))
        store.set(Self.kOTP, otp.toJSON())
        store.set(Self.kPIN, pin.trimmingCharacters(in: .whitespaces))
        // Trade a first OTP for an MQTT token so the setup is verified end to end. The server sometimes rejects the
        // very first code right after activation, so try a few fresh codes.
        var last: Error?
        for _ in 0..<3 {
            do { try await passwordGrant(otp); return } catch let e as APIError {
                last = e
                if e.code != 400 { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        // Don't leave a half-finished setup behind: the user can start over with a new SMS.
        store.set(Self.kOTP, nil); store.set(Self.kPIN, nil)
        throw last ?? APIError(0, "Activation failed")
    }

    public nonisolated func checkPIN(_ pin: String) -> Bool { store.get(Self.kPIN).map { $0 == pin } ?? false }

    public func forget() {
        disconnect()
        for k in [Self.kOTP, Self.kPIN, Self.kMqttAccess, Self.kMqttExp, Self.kMqttRefresh, Self.kMqttRefreshExp] { store.set(k, nil) }
    }

    // MARK: Tokens

    private func passwordGrant(_ otp: Otp) async throws {
        let code = try await otp.nextCode()
        store.set(Self.kOTP, otp.toJSON())
        saveToken(try await api.mqttToken(["grant_type": "password", "password": code]), withRefresh: true)
    }

    private func saveToken(_ j: JSON, withRefresh: Bool) {
        guard let access = j.str("access_token") else { return }
        store.set(Self.kMqttAccess, access)
        store.set(Self.kMqttExp, String(Date().timeIntervalSince1970 + (j.num("expires_in") ?? 3600)))
        if let refresh = j.str("refresh_token") {
            store.set(Self.kMqttRefresh, refresh)
            if withRefresh || store.get(Self.kMqttRefreshExp) == nil {
                store.set(Self.kMqttRefreshExp, String(Date().timeIntervalSince1970 + 3 * 86_400))
            }
        }
    }

    private func ensureToken(force: Bool, margin: TimeInterval = 60) async throws {
        let now = Date().timeIntervalSince1970
        let exp = Double(store.get(Self.kMqttExp) ?? "") ?? 0
        if !force, store.get(Self.kMqttAccess) != nil, now < exp - margin { return }
        let refreshExp = Double(store.get(Self.kMqttRefreshExp) ?? "") ?? 0
        let refresh = store.get(Self.kMqttRefresh)
        if let refresh, now < refreshExp {
            if let j = try? await api.mqttToken(["grant_type": "refresh_token", "refresh_token": refresh]), j.str("access_token") != nil {
                saveToken(j, withRefresh: false); return
            }
        }
        guard let s = store.get(Self.kOTP), let otp = Otp.fromJSON(s) else { throw APIError(0, "Remote control isn't set up yet") }
        do { try await passwordGrant(otp) } catch {
            guard let refresh else { throw error }
            saveToken(try await api.mqttToken(["grant_type": "refresh_token", "refresh_token": refresh]), withRefresh: false)
        }
    }

    // MARK: Connection

    private func connect() async throws -> MQTTClient {
        if let c = client, await c.isConnected { return c }
        await client?.close()
        guard let customer = api.customerID else { throw APIError(0, "Missing customer id") }
        let c = MQTTClient(transport: makeTransport()) { [weak self] _, payload in await self?.handle(payload) }
        await c.setControlTimeout(controlTimeout)
        // The broker only accepts an empty client id (it assigns one), like the brand apps.
        do {
            try await c.connect(host: Self.broker.host, port: Self.broker.port, username: "IMA_OAUTH_ACCESS_TOKEN",
                                password: store.get(Self.kMqttAccess) ?? "", keepAlive: 120)
            try await c.subscribe("psa/RemoteServices/to/cid/\(customer)/#")
        } catch {
            await c.close()
            throw error
        }
        client = c
        return c
    }

    public func disconnect() {
        let c = client
        client = nil
        Task { await c?.close() }
    }

    /// Gets a token and opens the connection ahead of a command, so it goes out faster.
    public func warmUp() async {
        guard isSetUp, !busy else { return }
        _ = try? await prepared(force: false, margin: 600)
    }

    private func prepared(force: Bool, margin: TimeInterval = 60) async throws -> MQTTClient {
        if let p = preparing { return try await p.value }
        let t = Task { () async throws -> MQTTClient in
            try await self.ensureToken(force: force, margin: margin)
            if force { self.disconnect() }
            return try await self.connect()
        }
        preparing = t
        defer { preparing = nil }
        return try await t.value
    }

    func handle(_ payload: Data) {
        guard let data = JSONValue.parse(payload) as? JSON else { return }
        let id = data.optString("correlation_id")
        guard let code = data.str("return_code") ?? data.str("process_code") else { return }
        let svc = services[id] ?? "?"
        var line = "\(svc) → \(code)"
        if let r = data.str("reason") { line += " · \(r)" }
        if let rd = data.obj("resp_data") { line += " · resp_data=\(String(decoding: JSONValue.data(rd), as: UTF8.self))" }
        addLog(line)
        // 900 = accepted, 901 = car asleep (being woken), 902 = checking state, 903 = delivered to the car.
        if Self.inProgress.contains(code) {
            progress[id]?(code == "900" ? "Sent to \(api.brand.display)…" : code == "901" ? "Waking the car…" : "Checking the car…")
            return
        }
        if code == "903" {
            progress[id]?("Car received it")
            complete(id, "903")
            return
        }
        let reason = data.optString("reason")
        let finalCode = code == "400" && reason.contains("no.matching.service.key") ? "not_compatible" : code
        if finalCode != "0" && finalCode != "1" {
            if let d = Self.describeRespData(services[id], data.obj("resp_data")) { reasons[id] = d }
            let r = reason.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if !r.isEmpty { brandReasons[id] = r }
        }
        if waiters[id] != nil || expected.contains(id) { complete(id, finalCode) }
        else if let f = finals.removeValue(forKey: id) {
            f(mapCode(finalCode, reasons.removeValue(forKey: id), brandReasons.removeValue(forKey: id)))
            services.removeValue(forKey: id)
        }
    }

    private func complete(_ id: String, _ code: String?) {
        if let w = waiters.removeValue(forKey: id) { w.resume(returning: code) }
        else if expected.contains(id), let code { early[id] = code }
    }

    private func wait(_ id: String, seconds: Double) async -> String? {
        if let c = early.removeValue(forKey: id) { return c }
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            waiters[id] = c
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await self?.complete(id, nil)
            }
        }
    }

    // MARK: Sending

    private func send(_ service: String, _ params: JSON, _ tracker: Tracker, retried: Bool = false) async -> CommandResult {
        if busy && !retried { return .failed("Another command is still on its way — wait a moment") }
        busy = true
        defer { if !retried { busy = false } }
        do {
            if client == nil || retried { tracker.onProgress("Connecting…") }
            let c = try await prepared(force: retried)
            var attempt = 0
            while true {
                attempt += 1
                let id = try await publish(c, service, params, tracker)
                tracker.onProgress("Sent — waiting for the car…")
                let code = await wait(id, seconds: 90 * timeoutScale)
                expected.remove(id)
                progress.removeValue(forKey: id)
                if code == "903" {
                    // Delivered: stop making the user wait. The final answer (if any) goes to tracker.onFinal.
                    let scale = timeoutScale
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(180 * scale * 1_000_000_000))
                        await self?.forgetCommand(id)
                    }
                    return .delivered
                }
                finals.removeValue(forKey: id)
                services.removeValue(forKey: id)
                let reason = reasons.removeValue(forKey: id), bReason = brandReasons.removeValue(forKey: id)
                if code == "300" && attempt == 1 {
                    // No answer in time — often the car was waking up or briefly out of coverage. That woke it; try once more.
                    tracker.onProgress("Car didn't answer — trying again…")
                    try? await Task.sleep(nanoseconds: UInt64(5_000_000_000 * timeoutScale))
                    continue
                }
                if code == "502" && attempt == 1 {
                    // The car was still busy with an earlier request: wait a little and send once more.
                    tracker.onProgress("Car was busy — trying again…")
                    try? await Task.sleep(nanoseconds: UInt64(6_000_000_000 * timeoutScale))
                    continue
                }
                guard let code else { return .failed("No answer from the car yet — it may be asleep or out of coverage") }
                // A 400 can mean the token went stale: get a fresh one and try once more.
                if code == "400" && !retried {
                    busy = true
                    let r = await send(service, params, tracker, retried: true)
                    busy = false
                    return r
                }
                return mapCode(code, reason, bReason)
            }
        } catch {
            let msg: String
            if let m = error as? MQTTError {
                switch m.code {
                case 128: msg = "\(api.brand.display) refused remote control for this account (MQTT code 128). Usually the remote service isn't active for this car: check in \(api.brand.app) that it is activated. Lock, lights and horn need \(api.brand.doorsPack); charging and pre-heating need \(api.brand.eRemotePack)."
                case 4, 5: msg = "\(api.brand.display)'s remote-control server didn't accept the login (MQTT code \(m.code)). Set up remote control again in Settings."
                default: msg = "Couldn't connect to \(api.brand.display)'s remote-control server: \(m.message)"
                }
            } else {
                msg = HTTP.describe(error)
            }
            addLog("error: \(msg)")
            disconnect()
            return .failed(msg)
        }
    }

    private func forgetCommand(_ id: String) {
        finals.removeValue(forKey: id); services.removeValue(forKey: id); reasons.removeValue(forKey: id)
    }

    /// Builds and publishes one request; listeners are registered before the message goes out.
    private func publish(_ c: MQTTClient, _ service: String, _ params: JSON, _ tracker: Tracker) async throws -> String {
        guard let customer = api.customerID else { throw APIError(0, "Missing customer id") }
        guard let vin = api.pick(api.cachedVehicles())?.vin else { throw APIError(0, "No vehicle") }
        let now = Date()
        let stamp: String = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMddHHmmssSSS"; return f.string(from: now)
        }()
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + stamp
        let payload: JSON = ["access_token": store.get(Self.kMqttAccess) ?? "", "customer_id": customer, "correlation_id": id,
                             "req_date": ISODate.format(now), "vin": vin, "req_parameters": params]
        expected.insert(id)
        progress[id] = tracker.onProgress
        finals[id] = tracker.onFinal
        services[id] = service
        addLog("\(service) ← sent \(String(decoding: JSONValue.data(params), as: UTF8.self))")
        try await c.publish("psa/RemoteServices/from/cid/\(customer)\(service)", payload: JSONValue.data(payload))
        return id
    }

    func mapCode(_ code: String, _ reason: String?, _ brandReason: String?) -> CommandResult {
        if code == "0" || code == "1" { return .success }
        let meaning: String = switch code {
        case "400": "The car refused the command"
        case "not_compatible": "Your car or subscription doesn't support this command"
        case "502": "The car is still busy with another request — try again in a moment"
        case "300": "The car didn't answer in time — it may have poor coverage"
        case "500": "\(api.brand.display)'s remote-control server reported an internal error"
        case "422": "Privacy mode is on in the car, so remote commands are blocked"
        case "506": "The car's mobile provider isn't supported for remote commands"
        case "507": "The car has no GPS coverage right now"
        case "113": "\(api.brand.display) couldn't match the car (VIN)"
        default: "\(api.brand.display) answered with an unknown result"
        }
        let label = code == "not_compatible" ? "400" : code
        let extra = brandReason.flatMap { $0.isEmpty ? nil : " · \(api.brand.display) says: \($0)" } ?? ""
        return .failed("\(reason ?? meaning) (code \(label)\(extra))")
    }

    /// The car's own reason for refusing, from resp_data (same enums as the brand apps).
    static func describeRespData(_ service: String?, _ rd: JSON?) -> String? {
        guard let service, let rd else { return nil }
        func int(_ k: String) -> Int? { rd.num(k).map { Int($0) } }
        if service == "/Doors" {
            if int("error") == 0 { return "The engine is running" }
            switch int("lock_resp_state") {
            case 2: return "A door is open"
            case 3: return "The car refused the request"
            case 5: return "The key is inside the car"
            case 4: return "The car refused without giving a reason — check that doors, boot, bonnet and windows are fully closed and the key isn't in or right next to the car"
            default: return nil
            }
        }
        if service == "/Horn" || service == "/Lights" {
            switch int("error") {
            case 0: return "The engine is running"
            case 1, 2: return "Just done — wait a moment before sending again"
            default: return nil
            }
        }
        if service == "/ThermalPrecond" {
            switch int("error") {
            case 0: return "The engine is running"
            case 1: return "Pre-heating is already running"
            case 2: return "Communication problem in the car"
            case 3: return "Can't stop while the engine is running"
            case 4: return "Pre-heating wasn't running"
            default: return nil
            }
        }
        if service.hasPrefix("/VehCharge") {
            switch int("error") {
            case 0: return "The charging system is in standby"
            case 1: return "It's already charging"
            case 2: return "Charging communication problem in the car"
            case 3: return "The engine is running"
            default: return nil
            }
        }
        return nil
    }

    // MARK: Commands

    public func lock(_ lock: Bool, _ t: Tracker = Tracker()) async -> CommandResult { await send("/Doors", ["action": lock ? "lock" : "unlock"], t) }
    public func horn(_ t: Tracker = Tracker()) async -> CommandResult { await send("/Horn", ["nb_horn": "2", "action": "activate"], t) }
    public func lights(_ t: Tracker = Tracker()) async -> CommandResult { await send("/Lights", ["duration": "10", "action": "activate"], t) }
    /// Asks the car to report its state now (wakes it), so the next status is fresh.
    public func wakeUp(_ t: Tracker = Tracker()) async -> CommandResult { await send("/VehCharge/state", ["action": "state"], t) }

    public func preconditioning(_ on: Bool, programs: JSON, _ t: Tracker = Tracker()) async -> CommandResult {
        await send("/ThermalPrecond", ["asap": on ? "activate" : "deactivate", "programs": programs], t)
    }

    /// The car's own charge limit: daily = stop at the limit set in the car, trip = charge to 100 %.
    public func chargeLimit(daily: Bool, _ t: Tracker = Tracker()) async -> CommandResult {
        await send("/VehCharge/limit", ["action": daily ? "daily" : "trip"], t)
    }

    /// immediate = start now; delayed = wait for the scheduled start time (i.e. stop now).
    public func charging(startNow: Bool, hour: Int, minute: Int, _ t: Tracker = Tracker()) async -> CommandResult {
        await send("/VehCharge", ["program": ["hour": hour, "minute": minute] as JSON, "type": startNow ? "immediate" : "delayed"], t)
    }
}
