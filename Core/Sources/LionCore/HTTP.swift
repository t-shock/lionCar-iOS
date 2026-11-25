import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct APIError: Error, LocalizedError, Sendable {
    public let code: Int
    public let message: String
    public init(_ code: Int, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
    /// The server has nothing for this car ("404 / 40400": no status, no trips).
    public var noData: Bool { code == 404 || message.contains("40400") }
}

public struct AuthExpiredError: Error, LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "Signed out — please sign in again" }
}

public enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 90
        return URLSession(configuration: c)
    }()

    public static func text(_ req: URLRequest) async throws -> String {
        let (data, resp) = try await session.data(for: req)
        let body = String(decoding: data, as: UTF8.self)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError(code, describeHTTPError(code, body: body, host: req.url?.host ?? ""))
        }
        return body
    }

    public static func json(_ req: URLRequest) async throws -> Any? { JSONValue.parse(try await text(req)) }

    /// "Peugeot error 503 (temporarily unavailable): <the server's own message>"
    public static func describeHTTPError(_ code: Int, body: String, host: String) -> String {
        let who: String
        if ["psa", "mpsa", "stellantis", "peugeot"].contains(where: host.contains) { who = "Peugeot" }
        else if host.contains("met.no") { who = "MET weather" }
        else if host.contains("nobil") { who = "NOBIL" }
        else { who = host }
        let meaning: String = switch code {
        case 400: "request rejected"
        case 401: "not signed in / session expired"
        case 403: "access denied"
        case 404: "not found"
        case 408: "timed out"
        case 409: "conflict"
        case 429: "too many requests — wait a little"
        case 500: "internal server error"
        case 502: "bad gateway"
        case 503: "temporarily unavailable"
        case 504: "gateway timeout"
        default: "error"
        }
        if code >= 500 && body.trimmingCharacters(in: .whitespaces).hasPrefix("<") { return "\(who) error \(code) (\(meaning))" }
        var detail = ""
        if let j = JSONValue.parse(body) as? JSON {
            var parts = [j.str("error_description"), j.str("message"),
                         j.objects("errors").first.flatMap { e in e.str("message") ?? e.str("code") },
                         j.str("error"), j.str("code").flatMap { $0 == String(code) ? nil : $0 }]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
            var seen = Set<String>()
            parts = parts.filter { seen.insert($0).inserted }
            detail = parts.joined(separator: " · ")
        } else {
            detail = String(body.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces).prefix(160))
        }
        return "\(who) error \(code) (\(meaning))" + (detail.isEmpty ? "" : ": \(detail)")
    }

    /// Human text for any error from a network call.
    public static func describe(_ e: Error) -> String {
        if let a = e as? APIError { return a.message }
        if e is AuthExpiredError { return AuthExpiredError().errorDescription! }
        let ns = e as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "No internet connection"
            case NSURLErrorTimedOut: return "The server didn't answer in time (timeout)"
            case NSURLErrorCannotConnectToHost: return "Couldn't connect to the server"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted: return "Secure connection failed"
            default: return "Network problem: \(ns.localizedDescription)"
            }
        }
        return (e as? LocalizedError)?.errorDescription ?? "\(e)"
    }
}
