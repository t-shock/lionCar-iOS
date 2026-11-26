import Foundation

/// A JSON object as the car servers send it. Helpers mirror the org.json calls LionFlow uses, so the parsing
/// code can be ported line by line.
public typealias JSON = [String: Any]

public enum JSONValue {
    public static func parse(_ data: Data) -> Any? {
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    public static func parse(_ text: String) -> Any? { parse(Data(text.utf8)) }

    public static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

extension Dictionary where Key == String, Value == Any {
    /// Nested object at a path, like LionFlow's `obj("a", "b")`.
    public func obj(_ path: String...) -> JSON? {
        var current: JSON? = self
        for key in path { current = current?[key] as? JSON }
        return current
    }

    /// The value as text; nil when missing or null (org.json `str`).
    public func str(_ key: String) -> String? {
        guard let v = self[key], !(v is NSNull) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return "\(v)"
    }

    /// The value as text, or "" (org.json `optString`).
    public func optString(_ key: String) -> String { str(key) ?? "" }

    /// The value as a number; also accepts numbers sent as text. nil when missing, null or not a number.
    public func num(_ key: String) -> Double? {
        guard let v = self[key], !(v is NSNull) else { return nil }
        if let b = v as? Bool, type(of: v) == Bool.self { return b ? 1 : 0 }
        if let n = v as? NSNumber { let d = n.doubleValue; return d.isNaN ? nil : d }
        if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d.isNaN ? nil : d }
        return nil
    }

    public func bool(_ key: String) -> Bool? {
        guard let v = self[key], !(v is NSNull) else { return nil }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String {
            switch s.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        return nil
    }

    /// The objects in an array field (non-objects skipped).
    public func objects(_ key: String) -> [JSON] { (self[key] as? [Any])?.compactMap { $0 as? JSON } ?? [] }

    public func strings(_ key: String) -> [String] { (self[key] as? [Any])?.compactMap { $0 as? String } ?? [] }

    public func has(_ key: String) -> Bool { self[key] != nil }
}

/// Dates the car servers send: ISO 8601 with or without fractional seconds.
public enum ISODate {
    public static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    public static func format(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// "PT7H30M" -> (7, 30)
    public static func parsePT(_ s: String?) -> (hours: Int, minutes: Int)? {
        guard let s, s.hasPrefix("PT") else { return nil }
        func part(_ unit: Character) -> Int {
            guard let r = s.range(of: "(\\d+)\(unit)", options: .regularExpression) else { return 0 }
            return Int(s[r].dropLast()) ?? 0
        }
        return (part("H"), part("M"))
    }
}
