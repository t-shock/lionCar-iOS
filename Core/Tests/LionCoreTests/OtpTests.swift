import Foundation
import Testing
@testable import LionCore

/// Vectors from scripts/make_otp_vectors.py, made with Python's `cryptography` and OpenSSL (independent of this code).
private func vectors() throws -> [String: String] {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/otp_vectors", withExtension: "json"))
    return try #require(JSONValue.parse(try Data(contentsOf: url)) as? [String: String])
}

@Test func oaepEncryptMatchesReference() throws {
    let v = try vectors()
    let seed = Otp.hexToBytes(v["oaep_seed"]!)
    let ct = try Otp.oaepEncrypt(Otp.hexToBytes(v["oaep_msg"]!), modulusHex: v["modulus"]!, random: { _ in seed })
    #expect(ct.toHexString() == v["oaep_ct"]!)
}

@Test func decodeOaepUnwrapsTwoBlocks() throws {
    let v = try vectors()
    #expect(try Otp.decodeOAEP(v["decode_in"]!, modulusHex: v["modulus"]!) == v["decode_out"]!)
    // A wrong key must be refused, not produce garbage.
    let bad = String(v["decode_in"]!.prefix(256))
    let otherModulus = String(v["modulus"]!.dropLast(2)) + "ff"
    #expect(throws: Otp.OtpError.self) { _ = try Otp.decodeOAEP(bad, modulusHex: otherModulus) }
}

@Test func aesEcbBothWays() throws {
    let v = try vectors()
    let key = Otp.hexToBytes(v["aes_key"]!)
    #expect(try Otp.aesECB(Otp.hexToBytes(v["aes_plain"]!), key: key, encrypt: true).toHexString() == v["aes_ct"]!)
    #expect(try Otp.aesECB(Otp.hexToBytes(v["aes_ct"]!), key: key, encrypt: false).toHexString() == v["aes_plain"]!)
    // FIPS-197 appendix C.1
    #expect(try Otp.aesECB(Otp.hexToBytes("00112233445566778899aabbccddeeff"),
                           key: Otp.hexToBytes("000102030405060708090a0b0c0d0e0f"), encrypt: true).toHexString()
            == "69c4e0d86a7b0430d8cdb78070b4c55a")
}

@Test func otpCodeMatchesReference() throws {
    let v = try vectors()
    let o = Otp(deviceID: "dev")
    o.iwK1 = v["otp_k1"]!; o.defi = v["otp_defi"]!; o.iwsecval = v["otp_secval"]!
    #expect(o.computeOTP() == v["otp"]!)
}

@Test func xmlIsFlattened() {
    let raw = #"""
    <?xml version="1.0" encoding="UTF-8"?><ActionFinalize><err>OK</err><K0>abcd</K0><K0>later</K0><empty/><ms_n> 1 </ms_n></ActionFinalize>
    """#
    let x = Otp.parseXML(raw, root: "ActionFinalize")
    #expect(x?["err"] == "OK")
    #expect(x?["K0"] == "abcd")
    #expect(x?["ms_n"] == "1")
    #expect(x?["empty"] == "")
    #expect(Otp.parseXML(raw, root: "ActionSetup") == nil)
}

@Test func stateSurvivesSaving() throws {
    let o = Otp(deviceID: "abc123")
    o.iwid = "42"; o.iwK1 = "k1"; o.codepin = "1234"; o.kiw = "ff"; o.defi = "7"
    let back = try #require(Otp.fromJSON(o.toJSON()))
    #expect(back.toJSON() == o.toJSON())
    #expect(back.kfact == nil)
}

@Test func sha256AndKma() {
    #expect(Otp.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let o = Otp(deviceID: "dev")
    #expect(o.kma("1234").count == 32)
    #expect(o.getR().map(\.0) == ["R0", "R1", "R2"])
}

@Test func otpServerCodesAreExplained() {
    #expect(Otp.OtpError(message: "x", serverCode: "NOK:ACCESS").errorDescription!.contains("security code"))
    #expect(Otp.OtpError(message: "x", serverCode: "NOK:MAXNBTOOLS").errorDescription!.contains("locked"))
    #expect(Otp.OtpError(message: "plain").errorDescription == "plain")
}
