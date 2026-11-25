import Foundation
import Network
import LionCore

/// TLS byte pipe to the MQTT broker, on Apple's Network framework.
final class NWTransport: MQTTTransport, @unchecked Sendable {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "lioncar.mqtt")

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func open(host: String, port: Int) async throws {
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: .tls)
        connection = c
        final class Once: @unchecked Sendable { var done = false; let lock = NSLock()
            func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true } }
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { cont.resume() }
                case .failed(let e): if once.take() { cont.resume(throwing: Failure(message: "\(e.localizedDescription)")) }
                case .waiting(let e): if once.take() { c.cancel(); cont.resume(throwing: Failure(message: "No connection: \(e.localizedDescription)")) }
                case .cancelled: if once.take() { cont.resume(throwing: Failure(message: "Cancelled")) }
                default: break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 20) {
                if once.take() { c.cancel(); cont.resume(throwing: Failure(message: "Timed out connecting")) }
            }
        }
    }

    func send(_ data: Data) async throws {
        guard let c = connection else { throw Failure(message: "Not connected") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { e in
                if let e { cont.resume(throwing: e) } else { cont.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        guard let c = connection else { throw Failure(message: "Not connected") }
        return try await withCheckedThrowingContinuation { cont in
            c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty { cont.resume(returning: data) }
                else if let error { cont.resume(throwing: error) }
                else if isComplete { cont.resume(throwing: Failure(message: "Connection closed")) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    func close() {
        connection?.cancel()
        connection = nil
    }
}
