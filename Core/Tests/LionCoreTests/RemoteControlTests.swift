import Foundation
import Testing
@testable import LionCore

/// A stand-in for the brand's MQTT broker: answers CONNECT and SUBSCRIBE, and replies to each command with scripted codes.
final class FakeBroker: MQTTTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var readers: [CheckedContinuation<Data, Error>] = []
    private(set) var published: [(topic: String, payload: JSON)] = []
    var suback: UInt8 = 0
    var connack: UInt8 = 0
    /// Never answers the login (a broker that hangs).
    var silent = false
    /// Codes to answer the n-th command with (each element = one answer message), e.g. [["900", "903"], ["0"]].
    var script: [[String]] = []
    var respData: JSON?

    func open(host: String, port: Int) async throws {}
    /// Like a real socket: whoever is reading gets an error.
    func close() {
        lock.lock(); let r = readers; readers = []; lock.unlock()
        for c in r { c.resume(throwing: MQTTError(code: 0, message: "closed")) }
    }

    func send(_ data: Data) async throws {
        var buf = data
        let first = data.first ?? 0
        if first == 0x10 { if !silent { push(Data([0x20, 0x02, 0x00, connack])) }; return }
        if first == 0x82 { push(Data([0x90, 0x03, data[2], data[3], suback])); return }
        guard first == 0x30, case .publish(let topic, let payload)? = MQTTPacket.decode(&buf),
              let j = JSONValue.parse(payload) as? JSON else { return }
        lock.lock(); published.append((topic, j)); let n = published.count; lock.unlock()
        let codes = n <= script.count ? script[n - 1] : ["0"]
        for c in codes {
            var answer: JSON = ["correlation_id": j.optString("correlation_id"), "return_code": c]
            if let respData, !["900", "901", "902", "903"].contains(c) { answer["resp_data"] = respData }
            push(MQTTPacket.publish(topic: "psa/RemoteServices/to/cid/C1/VehCharge", payload: JSONValue.data(answer)))
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if !inbox.isEmpty { let d = inbox.removeFirst(); lock.unlock(); c.resume(returning: d) }
            else { readers.append(c); lock.unlock() }
        }
    }

    private func push(_ d: Data) {
        lock.lock()
        if !readers.isEmpty { let r = readers.removeFirst(); lock.unlock(); r.resume(returning: d) }
        else { inbox.append(d); lock.unlock() }
    }
}

final class Counter: @unchecked Sendable { private let l = NSLock(); private var n = 0
    func bump() { l.lock(); n += 1; l.unlock() }
    var value: Int { l.lock(); defer { l.unlock() }; return n } }

private func setUp(_ broker: FakeBroker, transports: Counter = Counter()) async -> RemoteControl {
    let store = MemoryStore()
    store.set("customer_id", "C1")
    store.set("vehicles", #"[{"id":"v1","vin":"VR3TESTVIN0000001","motorization":"Hybrid","brand":"Peugeot"}]"#)
    store.set("mqtt_access", "token-1")
    store.set("mqtt_expires", String(Date().timeIntervalSince1970 + 3600))
    store.set("otp_state", Otp(deviceID: "d").toJSON())
    let api = StellantisAPI(store: store, brand: .peugeot, country: "GR")
    let rc = RemoteControl(api: api, store: store, makeTransport: { transports.bump(); return broker })
    await rc.setTimeoutScale(0.01)
    await rc.setControlTimeout(0.3)
    return rc
}

extension RemoteControl {
    func setTimeoutScale(_ s: Double) { timeoutScale = s }
    func setControlTimeout(_ s: Double) { controlTimeout = s }
}

@Test func mqttPacketsRoundTrip() {
    var b = MQTTPacket.publish(topic: "a/b", payload: Data("hi".utf8)) + Data([0xD0, 0x00])
    #expect(MQTTPacket.decode(&b) == .publish(topic: "a/b", payload: Data("hi".utf8)))
    #expect(MQTTPacket.decode(&b) == .pingresp)
    #expect(b.isEmpty)
    var partial = MQTTPacket.publish(topic: "t", payload: Data(repeating: 7, count: 300)).prefix(10)
    #expect(MQTTPacket.decode(&partial) == nil)
    #expect(MQTTPacket.encodeLength(321) == [0xC1, 0x02])
    let c = MQTTPacket.connect(username: "IMA_OAUTH_ACCESS_TOKEN", password: "p", keepAlive: 120)
    #expect(c[0] == 0x10)
    #expect(Array(c[2...9]) == [0, 4] + Array("MQTT".utf8) + [4, 0xC2])
}

@Test func lockIsDeliveredAndPublishedLikeTheBrandApp() async {
    let broker = FakeBroker()
    broker.script = [["900", "901", "903"]]
    let rc = await setUp(broker)
    final class Lines: @unchecked Sendable { var v: [String] = [] }
    let lines = Lines()
    let r = await rc.lock(true, Tracker(onProgress: { lines.v.append($0) }))
    #expect(r == .delivered)
    #expect(lines.v.contains("Waking the car…"))
    #expect(lines.v.contains("Car received it"))
    let p = broker.published[0]
    #expect(p.topic == "psa/RemoteServices/from/cid/C1/Doors")
    #expect(p.payload.str("vin") == "VR3TESTVIN0000001")
    #expect(p.payload.str("access_token") == "token-1")
    #expect(p.payload.obj("req_parameters")?.str("action") == "lock")
    #expect(p.payload.optString("correlation_id").count == 32 + 17)
}

@Test func unlockSucceedsOnFinalCode() async {
    let broker = FakeBroker()
    broker.script = [["900", "0"]]
    let rc = await setUp(broker)
    #expect(await rc.lock(false) == .success)
    #expect(broker.published[0].payload.obj("req_parameters")?.str("action") == "unlock")
}

@Test func busyCarIsRetriedOnce() async {
    let broker = FakeBroker()
    broker.script = [["502"], ["0"]]
    let rc = await setUp(broker)
    #expect(await rc.horn() == .success)
    #expect(broker.published.count == 2)
}

@Test func carsOwnReasonIsShown() async {
    let broker = FakeBroker()
    broker.script = [["422"]]
    let rc = await setUp(broker)
    guard case .failed(let m) = await rc.lights() else { Issue.record("should fail"); return }
    #expect(m.contains("Privacy mode"))
    #expect(m.contains("code 422"))

    let b2 = FakeBroker()
    b2.script = [["113"]]
    b2.respData = ["lock_resp_state": 2]
    let rc2 = await setUp(b2)
    guard case .failed(let m2) = await rc2.lock(true) else { Issue.record("should fail"); return }
    #expect(m2.hasPrefix("A door is open"))
}

@Test func refusedSubscriptionExplainsTheSubscription() async {
    let broker = FakeBroker()
    broker.suback = 0x80
    let rc = await setUp(broker)
    guard case .failed(let m) = await rc.lock(true) else { Issue.record("should fail"); return }
    #expect(m.contains("MQTT code 128"))
    #expect(m.contains("Remote Control (Connect PLUS pack)"))
}

@Test func noAnswerTimesOut() async {
    let broker = FakeBroker()
    broker.script = [["900"], ["900"]]
    let rc = await setUp(broker)
    guard case .failed(let m) = await rc.lock(true) else { Issue.record("should fail"); return }
    #expect(m.contains("No answer from the car"))
}

@Test func warmUpAndCommandShareOneConnection() async {
    let broker = FakeBroker()
    let made = Counter()
    let rc = await setUp(broker, transports: made)
    async let w: Void = rc.warmUp()
    async let r = rc.lock(true)
    _ = await w
    #expect(await r == .success)
    #expect(made.value == 1)
}

@Test func silentBrokerFailsInsteadOfHanging() async {
    let broker = FakeBroker()
    broker.silent = true
    let rc = await setUp(broker)
    guard case .failed(let m) = await rc.lock(true) else { Issue.record("should fail"); return }
    #expect(m.contains("didn't answer"))
    broker.silent = false
    #expect(await rc.lock(false) == .success)  // not stuck as "another command is on its way"
}

@Test func earlyConnackIsNotLost() async throws {
    var b = Data([0x20, 0x02, 0x00, 0x00, 0x90, 0x03, 0x00, 0x01, 0x00])
    #expect(MQTTPacket.decode(&b) == .connack(returnCode: 0))
    #expect(MQTTPacket.decode(&b) == .suback(packetID: 1, codes: [0]))
}
