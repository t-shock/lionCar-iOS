// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif
import BigInt
import CryptoSwift

/// The inWebo one-time-password generator the brand apps use for remote commands. Swift port of LionFlow's Otp.kt,
/// itself ported from psa_car_controller (GPL-3.0, Florian Bezannier) via homeassistant-stellantis-vehicles.
///
/// Activation (once): SMS code + the brand app's security code (PIN). After that it produces one-time passwords that
/// are traded for an MQTT token. Stellantis allows only a handful of codes a day, so tokens are reused while valid.
public final class Otp {
    public struct OtpError: Error, LocalizedError, Sendable {
        public let message: String
        /// The OTP server's own code, e.g. "NOK:ACCESS".
        public var serverCode: String? = nil
        public var errorDescription: String? {
            switch serverCode {
            case "NOK:ACCESS": "The SMS code or the security code wasn't accepted (NOK:ACCESS). Check the security code — the 4-digit code the brand app asks for before remote actions — request a new SMS, and try once more. If it still fails with the right codes, the server may be having problems; wait a few hours before trying again."
            case "NOK:MAXNBTOOLS", "NOK:FORBIDDEN": "Remote setup is locked for this account after too many activations (\(serverCode!)). To unlock: delete and reinstall the brand app, sign in, and follow its prompt to reset remote control. Then set up LionCar again."
            default: message
            }
        }
    }

    public static let macID = "bb8e981582b0f31353108fb020bead1c"
    static let host = "https://otp.mpsa.com"
    static let ok = 0, otpTwice = 10
    static let activateMode = "activate", otpMode = "otp", msMode = "ms"
    private static let base36 = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    /// Fetches the OTP server's XML answer for a query; replaced in tests.
    typealias Fetch = ([(String, String)]) async throws -> String

    let macid: String
    public var deviceID: String
    var iwalea: String
    var kiw: String?
    var kfact: String?
    var codepin = ""
    var smsCode = ""
    var challenge = ""
    var action = ""
    var mode = Otp.activateMode
    var defi = "0"
    var iwid = ""
    var iwTsync = "0"
    var iwK0 = ""
    var iwK1 = ""
    var iwsecid = ""
    var iwsecval = ""
    var fetch: Fetch = Otp.httpFetch
    var random: (Int) -> [UInt8] = Otp.secureRandom

    public init(macid: String = Otp.macID, deviceID: String) {
        self.macid = macid; self.deviceID = deviceID
        iwalea = Otp.randomHex(16)
    }

    private var serial: String { "\(deviceID)/_/\(iwalea)" }

    func kma(_ pin: String) -> String { String(Self.sha256Hex("\(pin);\(serial)").prefix(32)) }

    func getR() -> [(String, String)] {
        let iw = iwK0
        let r2 = action == "synchro" ? "\(challenge);\(iw);\(codepin)" : "\(challenge);\(iw);"
        return [("R0", Self.sha256Hex("\(challenge);\(iw);\(serial)")),
                ("R1", Self.sha256Hex("\(challenge);\(iw);\(iwK1)")),
                ("R2", Self.sha256Hex(r2))]
    }

    private func request(_ params: [(String, String)], setup: Bool) async throws -> [String: String] {
        let raw = try await fetch(params)
        guard let x = Self.parseXML(raw, root: setup ? "ActionSetup" : "ActionFinalize") else { throw OtpError(message: "Bad response from OTP server") }
        return x
    }

    /// Step 1 of activation, or step 1 of producing an OTP.
    @discardableResult
    func activationStart() async throws -> Bool {
        var p: [(String, String)] = [("action", "ActionSetup"), ("mode", mode), ("id", iwid), ("lastsync", iwTsync),
                                     ("version", "Generator-1.0/0.2.11"), ("macid", macid)]
        if mode == Self.otpMode { p.append(("sid", iwsecid)) } else if mode == Self.activateMode { p.append(("code", smsCode)) }
        let xml = try await request(p, setup: true)
        guard xml["err"] == "OK" else { throw OtpError(message: "OTP setup refused: \(xml["err"] ?? "?")", serverCode: xml["err"]) }
        if mode == Self.activateMode {
            guard let kf = xml["Kfact"] else { throw OtpError(message: "Missing Kfact") }
            guard let k = xml["Kiw"] else { throw OtpError(message: "Missing Kiw") }
            kfact = kf
            kiw = try Self.decodeOAEP(k, modulusHex: kf)
        } else if mode == Self.otpMode {
            challenge = xml["challenge"] ?? ""
        }
        return true
    }

    /// Returns ok or otpTwice, or throws.
    func activationFinalize() async throws -> Int {
        let r = getR()
        var p: [(String, String)] = [("action", "ActionFinalize"), ("mode", mode), ("id", iwid), ("lastsync", iwTsync),
                                     ("version", "Generator-1.0/0.2.11"), ("lang", "fr"), ("ack", ""), ("macid", macid)]
        if mode == Self.otpMode {
            p += [("keytype", "0"), ("sid", iwsecid)]
        } else if mode == Self.activateMode {
            guard let modulus = kiw else { throw OtpError(message: "Not initialised") }
            let kmaCrypt = try Self.oaepEncrypt(Self.hexToBytes(kma(codepin)), modulusHex: modulus, random: random).toHexString()
            let pinCrypt = try Self.oaepEncrypt(Array(codepin.utf8), modulusHex: modulus, random: random).toHexString()
            p += [("serial", serial), ("code", smsCode), ("Kma", kmaCrypt), ("pin", pinCrypt),
                  ("name", "Android SDK built for x86_64 / UNKNOWN")]
        }
        p += r
        let xml = try await request(p, setup: false)
        guard xml["err"] == "OK" else { throw OtpError(message: "OTP error: \(xml["err"] ?? "?")", serverCode: xml["err"]) }
        try synchro(xml, key: kma(codepin))

        if mode == Self.otpMode {
            guard let d = xml["defi"] else { throw OtpError(message: "Missing defi in OTP response") }
            defi = d
            return xml["J"] != nil ? Self.otpTwice : Self.ok
        }

        guard let msN = xml["ms_n"], let msKey = xml["ms_key"] else { return Self.ok }
        if (Int(msN) ?? 0) > 1 { throw OtpError(message: "Unsupported ms_n=\(msN)") }

        challenge = xml["challenge"] ?? ""
        action = "synchro"
        guard let kf = kfact else { throw OtpError(message: "Not initialised") }
        let tempModulus = try Self.decodeOAEP(msKey, modulusHex: kf)
        let rnd = random(16)
        let kpubEncode = try Self.oaepEncrypt(rnd, modulusHex: tempModulus, random: random)
        iwsecval = try Self.aesECB(rnd, key: Self.hexToBytes(kma(codepin)), encrypt: true).toHexString()
        iwsecid = xml["s_id"] ?? ""

        var p2: [(String, String)] = [("action", "ActionFinalize"), ("mode", Self.msMode),
                                      ("ms_id0", xml["ms_id"] ?? ""), ("ms_val0", kpubEncode.toHexString()), ("macid", macid),
                                      ("id", iwid), ("lastsync", iwTsync), ("ms_n", "1")]
        p2 += getR()
        let xml2 = try await request(p2, setup: false)
        try synchro(xml2, key: kma(codepin))
        return Self.ok
    }

    private func synchro(_ x: [String: String], key: String) throws {
        let k = Self.hexToBytes(key)
        if let id = x["id"], !id.isEmpty { iwid = id }
        if let k0 = x["K0"], !k0.isEmpty { iwK0 = try Self.aesECB(Self.hexToBytes(k0), key: k, encrypt: false).toHexString() }
        if let k1 = x["K1"], !k1.isEmpty { iwK1 = try Self.aesECB(Self.hexToBytes(k1), key: k, encrypt: false).toHexString() }
        if let dk1 = x["dK1"], !dk1.isEmpty { iwK1 = String(Self.sha256Hex("\(iwK1);\(dk1)").prefix(32)) }
        if let sn = x["s_n"], !sn.isEmpty { iwTsync = x["Tsync"] ?? iwTsync }
    }

    func computeOTP() -> String {
        let res = Array("\(iwK1):\(defi):\(iwsecval)".utf8).sha256()
        func be(_ s: ArraySlice<UInt8>) -> UInt64 { s.reduce(0) { $0 << 8 | UInt64($1) } }
        let a = be(res[0..<4]) & 0xfffffff
        let b = be(res[4..<8]) & 1023
        var n = a * 1024 + b
        if n == 0 { return "a" }
        var out = ""
        while n > 0 { out.append(Self.base36[Int(n % 36)]); n /= 36 }
        return out
    }

    /// Activate with SMS code and PIN. Throws on failure.
    public func activate(sms: String, pin: String) async throws {
        smsCode = sms; codepin = pin; mode = Self.activateMode
        if try await activationStart() { _ = try await activationFinalize() }
    }

    /// Produce a one-time password.
    public func nextCode() async throws -> String {
        mode = Self.otpMode
        guard try await activationStart() else { throw OtpError(message: "Can't start OTP") }
        var res = try await activationFinalize()
        if res == Self.otpTwice {
            mode = Self.otpMode
            try await activationStart()
            res = try await activationFinalize()
            if res != Self.ok { throw OtpError(message: "Can't get OTP code") }
        }
        return computeOTP()
    }

    public func toJSON() -> String {
        let j: JSON = ["deviceId": deviceID, "iwalea": iwalea, "kiw": kiw ?? "", "kfact": kfact ?? "", "codepin": codepin,
                       "action": action, "defi": defi, "iwid": iwid, "iwTsync": iwTsync, "iwK0": iwK0, "iwK1": iwK1,
                       "iwsecid": iwsecid, "iwsecval": iwsecval]
        return String(decoding: JSONValue.data(j), as: UTF8.self)
    }

    /// Restores a generator; the field names match LionFlow's, so a saved state is interchangeable.
    public static func fromJSON(_ s: String) -> Otp? {
        guard let j = JSONValue.parse(s) as? JSON, let dev = j.str("deviceId"), let alea = j.str("iwalea") else { return nil }
        let o = Otp(deviceID: dev)
        o.iwalea = alea
        o.kiw = j.str("kiw").flatMap { $0.isEmpty ? nil : $0 }
        o.kfact = j.str("kfact").flatMap { $0.isEmpty ? nil : $0 }
        o.codepin = j.optString("codepin"); o.action = j.optString("action")
        o.defi = j.str("defi") ?? "0"; o.iwid = j.optString("iwid"); o.iwTsync = j.str("iwTsync") ?? "0"
        o.iwK0 = j.optString("iwK0"); o.iwK1 = j.optString("iwK1")
        o.iwsecid = j.optString("iwsecid"); o.iwsecval = j.optString("iwsecval")
        return o
    }

    // MARK: Network

    static func httpFetch(_ params: [(String, String)]) async throws -> String {
        var c = URLComponents(string: "\(host)/iwws/MAC")!
        c.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents leaves "+" alone, but the server reads it as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var req = URLRequest(url: c.url!)
        req.setValue("Dalvik/2.1.0 (Linux; U; Android 8.0.0; Android SDK built for x86_64 Build/OSR1.180418.004)", forHTTPHeaderField: "User-Agent")
        return try await HTTP.text(req)
    }

    // MARK: Crypto helpers

    static let exponent = BigUInt(0x11)

    static func secureRandom(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
    }

    public static func randomHex(_ bytes: Int) -> String { secureRandom(bytes).toHexString() }

    static func sha256Hex(_ s: String) -> String { Array(s.utf8).sha256().toHexString() }

    static func hexToBytes(_ hex: String) -> [UInt8] {
        let clean = hex.count % 2 == 1 ? "0" + hex : hex
        var out: [UInt8] = []
        out.reserveCapacity(clean.count / 2)
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            out.append(UInt8(clean[i..<j], radix: 16) ?? 0)
            i = j
        }
        return out
    }

    static func aesECB(_ data: [UInt8], key: [UInt8], encrypt: Bool) throws -> [UInt8] {
        let aes = try AES(key: key, blockMode: ECB(), padding: .noPadding)
        return encrypt ? try aes.encrypt(data) : try aes.decrypt(data)
    }

    private static func mgf1(_ seed: [UInt8], _ length: Int) -> [UInt8] {
        var out: [UInt8] = []
        var counter: UInt32 = 0
        while out.count < length {
            out += (seed + [UInt8(counter >> 24 & 0xff), UInt8(counter >> 16 & 0xff), UInt8(counter >> 8 & 0xff), UInt8(counter & 0xff)]).sha256()
            counter += 1
        }
        return Array(out.prefix(length))
    }

    private static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] { zip(a, b).map { $0 ^ $1 } }

    private static func i2osp(_ x: BigUInt, _ len: Int) -> [UInt8] {
        let raw = Array(x.serialize())
        if raw.count == len { return raw }
        if raw.count > len { return Array(raw.suffix(len)) }
        return [UInt8](repeating: 0, count: len - raw.count) + raw
    }

    /// RSA-OAEP (SHA-256, MGF1-SHA-256, empty label) encryption with public exponent 0x11.
    static func oaepEncrypt(_ message: [UInt8], modulusHex: String, random: (Int) -> [UInt8] = secureRandom) throws -> [UInt8] {
        guard let n = BigUInt(modulusHex, radix: 16) else { throw OtpError(message: "Bad modulus") }
        let k = (n.bitWidth - n.leadingZeroBitCount + 7) / 8
        let hLen = 32
        let psLen = k - message.count - 2 * hLen - 2
        guard psLen >= 0 else { throw OtpError(message: "Message too long") }
        let lHash = [UInt8]().sha256()
        let db = lHash + [UInt8](repeating: 0, count: psLen) + [1] + message
        let seed = random(hLen)
        let maskedDB = xor(db, mgf1(seed, k - hLen - 1))
        let maskedSeed = xor(seed, mgf1(maskedDB, hLen))
        let em = [0] + maskedSeed + maskedDB
        let c = BigUInt(Data(em)).power(exponent, modulus: n)
        return i2osp(c, k)
    }

    /// The vendor's "decrypt with the public key" OAEP unwrap, block by block (128-byte blocks).
    static func decodeOAEP(_ encHex: String, modulusHex: String) throws -> String {
        guard let n = BigUInt(modulusHex, radix: 16) else { throw OtpError(message: "Bad modulus") }
        let k = (n.bitWidth - n.leadingZeroBitCount + 7) / 8
        let hLen = 32
        let lHash = [UInt8]().sha256()
        let enc = hexToBytes(encHex)
        var out = ""
        var off = 0
        while off < enc.count {
            let end = min(off + 128, enc.count)
            let m = BigUInt(Data(enc[off..<end])).power(exponent, modulus: n)
            let em = i2osp(m, k)
            guard em.count > hLen + 1 else { throw OtpError(message: "Incorrect decryption") }
            let maskedSeed = Array(em[1...hLen])
            let maskedDB = Array(em[(hLen + 1)...])
            let seed = xor(maskedSeed, mgf1(maskedDB, hLen))
            let db = xor(maskedDB, mgf1(seed, k - hLen - 1))
            guard Array(db.prefix(hLen)) == lHash else { throw OtpError(message: "Incorrect decryption") }
            var onePos = -1
            for i in hLen..<db.count {
                if db[i] == 1 { onePos = i; break }
                if db[i] != 0 { break }
            }
            guard onePos >= 0 else { throw OtpError(message: "Incorrect decryption") }
            out += Array(db[(onePos + 1)...]).toHexString()
            off = end
        }
        return out
    }

    /// Flattens the children of the given root element into tag -> text (first non-empty text wins).
    static func parseXML(_ raw: String, root: String) -> [String: String]? {
        let text = raw.range(of: "?>").map { String(raw[$0.upperBound...]) } ?? raw
        let p = FlatXML(root: root)
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = p
        _ = parser.parse()
        return p.out.isEmpty ? nil : p.out
    }

    private final class FlatXML: NSObject, XMLParserDelegate {
        let root: String
        var out: [String: String] = [:]
        var depth = 0
        var inRoot = false
        var current: String?
        var buffer = ""
        init(root: String) { self.root = root }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            depth += 1
            if depth == 1 { inRoot = name == root }
            else if depth == 2 && inRoot {
                current = name; buffer = ""
                if out[name] == nil { out[name] = "" }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inRoot && depth == 2 && current != nil { buffer += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if depth == 2, let tag = current {
                let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && (out[tag] ?? "").isEmpty { out[tag] = t }
                current = nil
            }
            depth -= 1
        }
    }
}
