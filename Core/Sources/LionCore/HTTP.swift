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
        let who = serviceName(host: host)
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
        // A server's own error page (HTML) says nothing useful.
        if code >= 500 && body.trimmingCharacters(in: .whitespaces).hasPrefix("<") { return "\(who) error \(code) (\(meaning))" }
        let detail: String
        if let j = JSONValue.parse(body) as? JSON {
            detail = serverMessages(j, code: code)
        } else {
            detail = shortText(body)
        }
        return "\(who) error \(code) (\(meaning))" + (detail.isEmpty ? "" : ": \(detail)")
    }

    private static func serviceName(host: String) -> String {
        if ["psa", "mpsa", "stellantis", "peugeot"].contains(where: host.contains) { return "Peugeot" }
        if host.contains("met.no") { return "MET weather" }
        if host.contains("nobil") { return "NOBIL" }
        return host
    }

    /// The messages in a JSON error body, each once; the code only when it adds something to the HTTP status.
    private static func serverMessages(_ j: JSON, code: Int) -> String {
        let messages = [j.str("error_description"), j.str("message"),
                        j.objects("errors").first.flatMap { e in e.str("message") ?? e.str("code") },
                        j.str("error"), j.str("code").flatMap { $0 == String(code) ? nil : $0 }]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
        var seen = Set<String>()
        return messages.filter { seen.insert($0).inserted }.joined(separator: " · ")
    }

    /// A text or HTML body as one short line.
    private static func shortText(_ body: String) -> String {
        String(body.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).prefix(160))
    }

    /// Human text for any error from a network call.
    public static func describe(_ e: Error) -> String {
        if let apiError = e as? APIError { return apiError.message }
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
