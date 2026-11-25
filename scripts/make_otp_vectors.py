#!/usr/bin/env python3
"""Writes Core/Tests/LionCoreTests/Fixtures/otp_vectors.json: independent test vectors for the OTP crypto,
checked against the `cryptography` library (RSA-OAEP-SHA256 with e=17, AES-ECB, SHA-256)."""
import hashlib, json, os, subprocess, sys
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

out = sys.argv[1]
# OpenSSL can make a key with the vendor's public exponent 17; `cryptography` only generates 3 or 65537.
pem = subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:1024",
                      "-pkeyopt", "rsa_keygen_pubexp:17"], check=True, capture_output=True).stdout
key = serialization.load_pem_private_key(pem, password=None)
pn = key.private_numbers(); n, d, e = pn.public_numbers.n, pn.d, pn.public_numbers.e
k, hlen = 128, 32
sha = lambda b: hashlib.sha256(b).digest()
def mgf1(seed, length):
    o = b""; c = 0
    while len(o) < length: o += sha(seed + c.to_bytes(4, "big")); c += 1
    return o[:length]
xor = lambda a, b: bytes(x ^ y for x, y in zip(a, b))
def oaep_em(msg, seed):
    db = sha(b"") + b"\0" * (k - len(msg) - 2 * hlen - 2) + b"\1" + msg
    mdb = xor(db, mgf1(seed, k - hlen - 1)); ms = xor(seed, mgf1(mdb, hlen))
    return b"\0" + ms + mdb
oaep = padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None)

msg = bytes.fromhex("00112233445566778899aabbccddeeff")
seed = bytes(range(1, 33))
ct = pow(int.from_bytes(oaep_em(msg, seed), "big"), e, n).to_bytes(k, "big")
assert key.decrypt(ct, oaep) == msg  # the reference encoding is real OAEP
# "decrypt with the public key": the server applies the private key to an OAEP-encoded block
m1, m2 = os.urandom(40), os.urandom(20)
blocks = b"".join(pow(int.from_bytes(oaep_em(m, os.urandom(32)), "big"), d, n).to_bytes(k, "big") for m in (m1, m2))
akey, adata = os.urandom(16), os.urandom(32)
enc = Cipher(algorithms.AES(akey), modes.ECB()).encryptor()
aes_ct = enc.update(adata) + enc.finalize()
k1, defi, secval = "3f2a" * 8, "123456", "ab" * 16
res = sha(f"{k1}:{defi}:{secval}".encode())
num = (int.from_bytes(res[0:4], "big") & 0xfffffff) * 1024 + (int.from_bytes(res[4:8], "big") & 1023)
otp = ""
while num > 0: otp += "abcdefghijklmnopqrstuvwxyz0123456789"[num % 36]; num //= 36
json.dump({"modulus": format(n, "x"), "oaep_msg": msg.hex(), "oaep_seed": seed.hex(), "oaep_ct": ct.hex(),
           "decode_in": blocks.hex(), "decode_out": (m1 + m2).hex(),
           "aes_key": akey.hex(), "aes_plain": adata.hex(), "aes_ct": aes_ct.hex(),
           "otp_k1": k1, "otp_defi": defi, "otp_secval": secval, "otp": otp or "a"}, open(out, "w"), indent=1)
print("ok")
