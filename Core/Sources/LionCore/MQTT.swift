import Foundation

/// A byte pipe to the MQTT broker (TLS). The iPhone app supplies one built on Network.framework; tests use a fake.
public protocol MQTTTransport: AnyObject, Sendable {
    func open(host: String, port: Int) async throws
    func send(_ data: Data) async throws
    /// Next chunk of bytes; throws when the connection is closed.
    func receive() async throws -> Data
    func close()
}

public struct MQTTError: Error, LocalizedError, Sendable {
    /// CONNACK return code (1–5), or 128 for a refused subscription, or 0 for other failures.
    public let code: Int
    public let message: String
    public var errorDescription: String? { message }
}

/// The few MQTT 3.1.1 packets the brand apps use: connect with a token, subscribe, publish at QoS 0, ping.
public enum MQTTPacket: Equatable, Sendable {
    case connack(returnCode: UInt8)
    case suback(packetID: UInt16, codes: [UInt8])
    case publish(topic: String, payload: Data)
    case pingresp
    case other(type: UInt8)

    static func encodeLength(_ n: Int) -> [UInt8] {
        var x = n, out: [UInt8] = []
        repeat {
            var b = UInt8(x % 128); x /= 128
            if x > 0 { b |= 0x80 }
            out.append(b)
        } while x > 0
        return out
    }

    static func string(_ s: String) -> [UInt8] {
        let b = Array(s.utf8)
        return [UInt8(b.count >> 8), UInt8(b.count & 0xff)] + b
    }

    static func packet(_ header: UInt8, _ body: [UInt8]) -> Data { Data([header] + encodeLength(body.count) + body) }

    /// Clean session, user name and password; an empty client id lets the broker assign one (Peugeot's requires that).
    public static func connect(clientID: String = "", username: String, password: String, keepAlive: UInt16) -> Data {
        let flags: UInt8 = 0x80 | 0x40 | 0x02
        let body = string("MQTT") + [4, flags, UInt8(keepAlive >> 8), UInt8(keepAlive & 0xff)]
            + string(clientID) + string(username) + string(password)
        return packet(0x10, body)
    }

    public static func subscribe(packetID: UInt16, topic: String, qos: UInt8 = 0) -> Data {
        packet(0x82, [UInt8(packetID >> 8), UInt8(packetID & 0xff)] + string(topic) + [qos])
    }

    public static func publish(topic: String, payload: Data) -> Data { packet(0x30, string(topic) + Array(payload)) }
    public static let pingreq = Data([0xC0, 0x00])
    public static let disconnect = Data([0xE0, 0x00])

    /// Takes one complete packet off the front of the buffer, or returns nil if more bytes are needed.
    public static func decode(_ buffer: inout Data) -> MQTTPacket? {
        let b = [UInt8](buffer)
        guard b.count >= 2 else { return nil }
        var mult = 1, len = 0, i = 1
        while true {
            guard i < b.count, i <= 4 else { return nil }
            let byte = Int(b[i]); i += 1
            len += (byte & 0x7f) * mult
            if byte & 0x80 == 0 { break }
            mult *= 128
        }
        guard b.count >= i + len else { return nil }
        let body = Array(b[i..<(i + len)])
        buffer.removeFirst(i + len)
        let type = b[0] >> 4
        switch type {
        case 2: return .connack(returnCode: body.count >= 2 ? body[1] : 255)
        case 9:
            guard body.count >= 2 else { return .other(type: type) }
            return .suback(packetID: UInt16(body[0]) << 8 | UInt16(body[1]), codes: Array(body.dropFirst(2)))
        case 3:
            guard body.count >= 2 else { return .other(type: type) }
            let tl = Int(body[0]) << 8 | Int(body[1])
            guard body.count >= 2 + tl else { return .other(type: type) }
            let topic = String(decoding: body[2..<(2 + tl)], as: UTF8.self)
            let qos = (b[0] >> 1) & 0x03
            let start = 2 + tl + (qos > 0 ? 2 : 0)
            return .publish(topic: topic, payload: Data(body[min(start, body.count)...]))
        case 13: return .pingresp
        default: return .other(type: type)
        }
    }
}

/// A minimal MQTT client: connect, subscribe, publish, keep alive, and hand incoming messages to [onMessage].
public actor MQTTClient {
    private let transport: MQTTTransport
    private var buffer = Data()
    private var reader: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    /// The one CONNACK/SUBACK wait in progress (connect and subscribe run one after the other), and any that came early.
    private var waiter: (token: Int, continuation: CheckedContinuation<MQTTPacket, Error>)?
    private var controlBuffer: [MQTTPacket] = []
    private var waitToken = 0
    /// How long to wait for the broker's CONNACK / SUBACK.
    var controlTimeout: Double = 20
    private var nextID: UInt16 = 1
    public private(set) var isConnected = false
    private let onMessage: @Sendable (String, Data) async -> Void

    public init(transport: MQTTTransport, onMessage: @escaping @Sendable (String, Data) async -> Void) {
        self.transport = transport; self.onMessage = onMessage
    }

    public func connect(host: String, port: Int, username: String, password: String, keepAlive: UInt16 = 120) async throws {
        try await transport.open(host: host, port: port)
        startReader()
        let reply: MQTTPacket
        do {
            try await transport.send(MQTTPacket.connect(username: username, password: password, keepAlive: keepAlive))
            reply = try await nextControlPacket()
        } catch {
            close()
            throw error
        }
        guard case .connack(let rc) = reply else { close(); throw MQTTError(code: 0, message: "No CONNACK") }
        guard rc == 0 else {
            close()
            throw MQTTError(code: Int(rc), message: "The broker refused the login (MQTT code \(rc))")
        }
        isConnected = true
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(keepAlive) / 2 * 1_000_000_000)
                guard let self, await self.isConnected else { return }
                try? await self.transport.send(MQTTPacket.pingreq)
            }
        }
    }

    public func subscribe(_ topic: String) async throws {
        let id = nextID; nextID &+= 1
        try await transport.send(MQTTPacket.subscribe(packetID: id, topic: topic))
        guard case .suback(_, let codes) = try await nextControlPacket() else { throw MQTTError(code: 0, message: "No SUBACK") }
        if codes.contains(0x80) { throw MQTTError(code: 128, message: "Subscription refused (MQTT code 128)") }
    }

    public func publish(_ topic: String, payload: Data) async throws {
        guard isConnected else { throw MQTTError(code: 0, message: "Not connected") }
        try await transport.send(MQTTPacket.publish(topic: topic, payload: payload))
    }

    public func close() {
        if isConnected { let t = transport; Task { try? await t.send(MQTTPacket.disconnect); t.close() } } else { transport.close() }
        isConnected = false
        reader?.cancel(); pinger?.cancel()
        reader = nil; pinger = nil
        failWaiter("Connection closed")
    }

    public func setControlTimeout(_ seconds: Double) { controlTimeout = seconds }

    private func failWaiter(_ message: String) {
        if let w = waiter { waiter = nil; w.continuation.resume(throwing: MQTTError(code: 0, message: message)) }
    }

    /// The next CONNACK/SUBACK, also if it arrived before we started waiting; gives up after [controlTimeout].
    private func nextControlPacket() async throws -> MQTTPacket {
        if !controlBuffer.isEmpty { return controlBuffer.removeFirst() }
        waitToken += 1
        let token = waitToken
        let seconds = controlTimeout
        return try await withCheckedThrowingContinuation { c in
            waiter = (token, c)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await self?.timeOut(token)
            }
        }
    }

    private func timeOut(_ token: Int) {
        guard waiter?.token == token else { return }
        failWaiter("The remote-control server didn't answer")
        transport.close()
    }

    private func startReader() {
        reader = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let chunk = try await self.transport.receive()
                    await self.feed(chunk)
                } catch {
                    await self.lost()
                    return
                }
            }
        }
    }

    private func feed(_ chunk: Data) async {
        buffer.append(chunk)
        while let p = MQTTPacket.decode(&buffer) {
            switch p {
            case .publish(let topic, let payload): await onMessage(topic, payload)
            case .connack, .suback:
                if let w = waiter { waiter = nil; w.continuation.resume(returning: p) } else { controlBuffer.append(p) }
            default: break
            }
        }
    }

    private func lost() {
        isConnected = false
        pinger?.cancel()
        failWaiter("Connection lost")
    }
}
