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
    /// A command is on its way; only one at a time.
    private var busy = false
    /// The one "get a token and connect" in progress: a warm-up and a command must not both fetch tokens (each fresh
    /// one-time code advances the generator, and only a few are allowed a day) or open two connections.
    private var preparing: Task<MQTTClient, Error>?
    var controlTimeout: Double = 20

    // Per command, by correlation id:
    /// send() waiting for the car's answer.
    private var waiters: [String: CheckedContinuation<String?, Never>] = [:]
    /// Answers that came before send() started waiting.
    private var earlyAnswers: [String: String] = [:]
    /// Commands send() is still following (from publish until its wait ends).
    private var expected: Set<String> = []
    private var progress: [String: @Sendable (String) -> Void] = [:]
    /// Where a late final answer goes once send() has stopped waiting (after "delivered").
    private var finals: [String: @Sendable (CommandResult) -> Void] = [:]
    private var services: [String: String] = [:]
    /// The car's own reason for refusing (from resp_data), and the brand server's reason text.
    private var reasons: [String: String] = [:]
    private var brandReasons: [String: String] = [:]

    /// Last answers from the car, newest first — for troubleshooting.
    public private(set) var log: [String] = []
    /// Waits are shortened in tests.
    var timeoutScale: Double = 1

    private static let answerWait: Double = 90
    /// How long a delivered command's late final answer is still passed on.
    private static let lateAnswerWait: Double = 180
    private static let noAnswerPause: Double = 5
    private static let carBusyPause: Double = 6
    private static let maxLogLines = 40

    public init(api: StellantisAPI, store: SecretStore, makeTransport: @escaping @Sendable () -> MQTTTransport) {
        self.api = api; self.store = store; self.makeTransport = makeTransport
    }

    public nonisolated var isSetUp: Bool { store.get(Self.kOTP) != nil }

    public func addLog(_ line: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.insert("\(f.string(from: Date()))  \(line)", at: 0)
        if log.count > Self.maxLogLines { log.removeLast(log.count - Self.maxLogLines) }
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
        var lastError: Error?
        for _ in 0..<3 {
            do { try await passwordGrant(otp); return } catch let e as APIError {
                lastError = e
                if e.code != 400 { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        // Don't leave a half-finished setup behind: the user can start over with a new SMS.
        store.set(Self.kOTP, nil); store.set(Self.kPIN, nil)
        throw lastError ?? APIError(0, "Activation failed")
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

    /// withRefresh: the token came from a one-time password, so its refresh token starts a new ~3-day life.
    /// A refresh grant keeps the saved end date (refreshing doesn't extend it), unless none is saved yet.
    private func saveToken(_ response: JSON, withRefresh: Bool) {
        guard let access = response.str("access_token") else { return }
        store.set(Self.kMqttAccess, access)
        store.set(Self.kMqttExp, String(Date().timeIntervalSince1970 + (response.num("expires_in") ?? 3600)))
        if let refresh = response.str("refresh_token") {
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
        // The refresh token first: one-time passwords are rationed.
        if let refresh, now < refreshExp {
            if let response = try? await api.mqttToken(["grant_type": "refresh_token", "refresh_token": refresh]),
               response.str("access_token") != nil {
                saveToken(response, withRefresh: false); return
            }
        }
        guard let saved = store.get(Self.kOTP), let otp = Otp.fromJSON(saved) else { throw APIError(0, "Remote control isn't set up yet") }
        do { try await passwordGrant(otp) } catch {
            // The one-time password couldn't be used: fall back to the refresh token.
            guard let refresh else { throw error }
            saveToken(try await api.mqttToken(["grant_type": "refresh_token", "refresh_token": refresh]), withRefresh: false)
        }
    }

    // MARK: Connection

    private func customerID() throws -> String {
        guard let customer = api.customerID else { throw APIError(0, "Missing customer id") }
        return customer
    }

    private func connect() async throws -> MQTTClient {
        if let existing = client, await existing.isConnected { return existing }
        await client?.close()
        let customer = try customerID()
        let c = MQTTClient(transport: makeTransport()) { [weak self] _, payload in await self?.handle(payload) }
        await c.setControlTimeout(controlTimeout)
        // The MQTT password is the token; the client id is left empty because the broker only accepts that
        // (it assigns one), like the brand apps.
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

    /// A token and a connection, sharing the one already being prepared. force: get a new token and reconnect.
    private func prepared(force: Bool, margin: TimeInterval = 60) async throws -> MQTTClient {
        if let running = preparing { return try await running.value }
        let task = Task { () async throws -> MQTTClient in
            try await self.ensureToken(force: force, margin: margin)
            if force { self.disconnect() }
            return try await self.connect()
        }
        preparing = task
        defer { preparing = nil }
        return try await task.value
    }

    func handle(_ payload: Data) {
        guard let data = JSONValue.parse(payload) as? JSON else { return }
        let id = data.optString("correlation_id")
        guard let code = data.str("return_code") ?? data.str("process_code") else { return }
        var line = "\(services[id] ?? "?") → \(code)"
        if let reason = data.str("reason") { line += " · \(reason)" }
        if let respData = data.obj("resp_data") { line += " · resp_data=\(String(decoding: JSONValue.data(respData), as: UTF8.self))" }
        addLog(line)
        // 900 = accepted, 901 = car asleep (being woken), 902 = checking state, 903 = delivered to the car.
        if Self.inProgress.contains(code) {
            progress[id]?(progressText(code))
            return
        }
        if code == "903" {
            progress[id]?("Car received it")
            complete(id, "903")
            return
        }
        let reason = data.optString("reason")
        let finalCode = code == "400" && reason.contains("no.matching.service.key") ? "not_compatible" : code
        // Only for a command still being followed: a late answer for a forgotten one is just logged above.
        if finalCode != "0" && finalCode != "1", services[id] != nil {
            if let carReason = Self.describeRespData(services[id], data.obj("resp_data")) { reasons[id] = carReason }
            let brandReason = reason.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if !brandReason.isEmpty { brandReasons[id] = brandReason }
        }
        if waiters[id] != nil || expected.contains(id) { complete(id, finalCode) }
        else if let onFinal = finals.removeValue(forKey: id) {
            // send() has already returned "delivered": this is the car's late final answer.
            onFinal(mapCode(finalCode, reasons[id], brandReasons[id]))
            forget(id)
        }
    }

    private func progressText(_ code: String) -> String {
        switch code {
        case "900": "Sent to \(api.brand.display)…"
        case "901": "Waking the car…"
        default: "Checking the car…"
        }
    }

    /// Hands an answer (nil = timed out) to send(), or keeps it if send() isn't waiting yet.
    private func complete(_ id: String, _ code: String?) {
        if let waiter = waiters.removeValue(forKey: id) { waiter.resume(returning: code) }
        else if expected.contains(id), let code { earlyAnswers[id] = code }
    }

    private func wait(_ id: String, seconds: Double) async -> String? {
        if let answer = earlyAnswers.removeValue(forKey: id) { return answer }
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            waiters[id] = c
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await self?.complete(id, nil)
            }
        }
    }

    // MARK: Sending

    private func send(_ service: String, _ params: JSON, _ tracker: Tracker) async -> CommandResult {
        if busy { return .failed("Another command is still on its way — wait a moment") }
        busy = true
        defer { busy = false }
        return await sendNow(service, params, tracker, freshToken: false)
    }

    /// freshToken: this is the one retry after a 400 (possibly a stale token): get a new token and reconnect first.
    private func sendNow(_ service: String, _ params: JSON, _ tracker: Tracker, freshToken: Bool) async -> CommandResult {
        do {
            if client == nil || freshToken { tracker.onProgress("Connecting…") }
            let c = try await prepared(force: freshToken)
            var attempt = 0
            while true {
                attempt += 1
                let id = try await publish(c, service, params, tracker)
                tracker.onProgress("Sent — waiting for the car…")
                let code = await wait(id, seconds: Self.answerWait * timeoutScale)
                expected.remove(id)
                earlyAnswers.removeValue(forKey: id)   // a second answer that came in just now
                progress.removeValue(forKey: id)
                if code == "903" {
                    // Delivered: stop making the user wait. The final answer (if any) goes to tracker.onFinal.
                    let scale = timeoutScale
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(Self.lateAnswerWait * scale * 1_000_000_000))
                        await self?.forgetCommand(id)
                    }
                    return .delivered
                }
                let reason = reasons[id], brandReason = brandReasons[id]
                forget(id)
                if code == "300" && attempt == 1 {
                    // No answer in time — often the car was waking up or briefly out of coverage. That woke it; try once more.
                    tracker.onProgress("Car didn't answer — trying again…")
                    try? await Task.sleep(nanoseconds: UInt64(Self.noAnswerPause * 1_000_000_000 * timeoutScale))
                    continue
                }
                if code == "502" && attempt == 1 {
                    // The car was still busy with an earlier request: wait a little and send once more.
                    tracker.onProgress("Car was busy — trying again…")
                    try? await Task.sleep(nanoseconds: UInt64(Self.carBusyPause * 1_000_000_000 * timeoutScale))
                    continue
                }
                guard let code else { return .failed("No answer from the car yet — it may be asleep or out of coverage") }
                // A 400 can mean the token went stale: get a fresh one and try once more.
                if code == "400" && !freshToken {
                    return await sendNow(service, params, tracker, freshToken: true)
                }
                return mapCode(code, reason, brandReason)
            }
        } catch {
            let message = describeConnectionError(error)
            addLog("error: \(message)")
            disconnect()
            return .failed(message)
        }
    }

    private func describeConnectionError(_ error: Error) -> String {
        guard let m = error as? MQTTError else { return HTTP.describe(error) }
        switch m.code {
        case 128: return "\(api.brand.display) refused remote control for this account (MQTT code 128). Usually the remote service isn't active for this car: check in \(api.brand.app) that it is activated. Lock, lights and horn need \(api.brand.doorsPack); charging and pre-heating need \(api.brand.eRemotePack)."
        case 4, 5: return "\(api.brand.display)'s remote-control server didn't accept the login (MQTT code \(m.code)). Set up remote control again in Settings."
        default: return "Couldn't connect to \(api.brand.display)'s remote-control server: \(m.message)"
        }
    }

    /// Stops passing on a delivered command's final answer.
    private func forgetCommand(_ id: String) { forget(id) }

    /// Drops everything kept for one command. Every way a command can end comes through here, so nothing is left behind.
    private func forget(_ id: String) {
        expected.remove(id)
        earlyAnswers.removeValue(forKey: id)
        progress.removeValue(forKey: id)
        finals.removeValue(forKey: id)
        services.removeValue(forKey: id)
        reasons.removeValue(forKey: id)
        brandReasons.removeValue(forKey: id)
    }

    /// How many commands still have something kept for them (for tests).
    var trackedCommands: Int {
        Set(expected).union(earlyAnswers.keys).union(progress.keys).union(finals.keys).union(services.keys)
            .union(reasons.keys).union(brandReasons.keys).union(waiters.keys).count
    }

    /// Builds and publishes one request; listeners are registered before the message goes out.
    private func publish(_ c: MQTTClient, _ service: String, _ params: JSON, _ tracker: Tracker) async throws -> String {
        let customer = try customerID()
        guard let vin = api.pick(api.cachedVehicles())?.vin else { throw APIError(0, "No vehicle") }
        let now = Date()
        let stamp: String = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMddHHmmssSSS"; return f.string(from: now)
        }()
        // Correlation id: 32 hex digits + the UTC time to the millisecond.
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + stamp
        let payload: JSON = ["access_token": store.get(Self.kMqttAccess) ?? "", "customer_id": customer, "correlation_id": id,
                             "req_date": ISODate.format(now), "vin": vin, "req_parameters": params]
        expected.insert(id)
        progress[id] = tracker.onProgress
        finals[id] = tracker.onFinal
        services[id] = service
        addLog("\(service) ← sent \(String(decoding: JSONValue.data(params), as: UTF8.self))")
        do {
            try await c.publish("psa/RemoteServices/from/cid/\(customer)\(service)", payload: JSONValue.data(payload))
        } catch {
            forget(id)
            throw error
        }
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
