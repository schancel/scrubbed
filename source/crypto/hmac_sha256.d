/// Pure HMAC-SHA256 (RFC 2104 keyed-hash message authentication code)
/// built on the existing incremental `crypto.sha256.Sha256` primitive.
///
/// This does not reimplement SHA-256: it only wraps the existing block-size-64
/// `Sha256` struct with the standard HMAC inner/outer padding construction.
module crypto.hmac_sha256;

import crypto.sha256 : Sha256, sha256Of;

private enum blockSize = 64; // SHA-256 block size in bytes (Sha256's compression block).
enum hmacSha256OutputSize = 32; // SHA-256 digest size in bytes.

/// Computes HMAC-SHA256(key, message) per RFC 2104 (with SHA-256 as the
/// underlying hash) / FIPS 198-1:
///
///   K' = key,                         if len(key) == blockSize
///        SHA256(key) padded to block, if len(key)  > blockSize
///        key padded with zero bytes,  if len(key)  < blockSize
///   HMAC(K, m) = SHA256((K' xor opad) || SHA256((K' xor ipad) || m))
ubyte[hmacSha256OutputSize] hmacSha256(scope const(ubyte)[] key, scope const(ubyte)[] message) pure {
    ubyte[blockSize] keyBlock = 0;
    if (key.length > blockSize) {
        auto hashed = sha256Of(key);
        keyBlock[0 .. hashed.length] = hashed[];
    } else {
        keyBlock[0 .. key.length] = key[];
    }

    ubyte[blockSize] ipad;
    ubyte[blockSize] opad;
    foreach (i; 0 .. blockSize) {
        ipad[i] = keyBlock[i] ^ 0x36;
        opad[i] = keyBlock[i] ^ 0x5c;
    }

    auto inner = Sha256.create;
    inner.put(ipad[]);
    inner.put(message);
    auto innerDigest = inner.finish;

    auto outer = Sha256.create;
    outer.put(opad[]);
    outer.put(innerDigest[]);
    return outer.finish;
}

/// Convenience overload for string key/message callers (e.g. SigV4 signing,
/// which HMACs UTF-8 date/region/service strings and hex string-to-sign text).
ubyte[hmacSha256OutputSize] hmacSha256(scope const(char)[] key, scope const(char)[] message) pure {
    return hmacSha256(cast(const(ubyte)[]) key, cast(const(ubyte)[]) message);
}

private ubyte[] hexToBytes(string hex) pure {
    ubyte[] result;
    result.length = hex.length / 2;
    foreach (i; 0 .. result.length) {
        ubyte hi = cast(ubyte) hexNibble(hex[i * 2]);
        ubyte lo = cast(ubyte) hexNibble(hex[i * 2 + 1]);
        result[i] = cast(ubyte)((hi << 4) | lo);
    }
    return result;
}

private int hexNibble(char c) pure {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    assert(false, "invalid hex digit");
}

private string bytesToHex(scope const(ubyte)[] bytes) pure {
    static immutable char[16] digits = "0123456789abcdef";
    auto result = new char[bytes.length * 2];
    foreach (i, b; bytes) {
        result[i * 2] = digits[b >> 4];
        result[i * 2 + 1] = digits[b & 0xf];
    }
    return cast(string) result;
}

unittest {
    // RFC 4231 Section 4 ("Test Vectors") HMAC-SHA-256 test cases, fetched
    // 2026-09-27 from https://www.rfc-editor.org/rfc/rfc4231.txt and
    // independently cross-checked against Python 3.14's stdlib
    // `hmac.new(key, data, hashlib.sha256).hexdigest()` during evaluation for
    // issue #46 (see docs/sigv4-evaluation.md). Test Case 5 (RFC 4231 4.6) is
    // intentionally excluded: it specifies HMAC-SHA-256-128, a 128-bit
    // truncation of the digest, not full HMAC-SHA-256, and so is not directly
    // comparable to this function's untruncated 256-bit output.

    // TC1: Key = 20 bytes of 0x0b, Data = "Hi There"
    assert(bytesToHex(hmacSha256(hexToBytes("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"),
        cast(const(ubyte)[]) "Hi There")) ==
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");

    // TC2: Key = "Jefe", Data = "what do ya want for nothing?"
    assert(bytesToHex(hmacSha256(cast(const(ubyte)[]) "Jefe",
        cast(const(ubyte)[]) "what do ya want for nothing?")) ==
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");

    // TC3: Key = 20 bytes of 0xaa, Data = 50 bytes of 0xdd
    {
        ubyte[20] key = 0xaa;
        ubyte[50] data = 0xdd;
        assert(bytesToHex(hmacSha256(key[], data[])) ==
            "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe");
    }

    // TC4: Key = 0x0102030405060708090a0b0c0d0e0f10111213141516171819 (25 bytes),
    // Data = 50 bytes of 0xcd
    {
        auto key = hexToBytes("0102030405060708090a0b0c0d0e0f10111213141516171819");
        ubyte[50] data = 0xcd;
        assert(bytesToHex(hmacSha256(key, data[])) ==
            "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b");
    }

    // TC6: Key = 131 bytes of 0xaa,
    // Data = "Test Using Larger Than Block-Size Key - Hash Key First"
    {
        ubyte[131] key = 0xaa;
        assert(bytesToHex(hmacSha256(key[],
            cast(const(ubyte)[]) "Test Using Larger Than Block-Size Key - Hash Key First")) ==
            "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
    }

    // TC7: Key = 131 bytes of 0xaa, Data = "This is a test using a larger than
    // block-size key and a larger than block-size data. The key needs to be
    // hashed before being used by the HMAC algorithm."
    {
        ubyte[131] key = 0xaa;
        string data = "This is a test using a larger than block-size key and a larger " ~
            "than block-size data. The key needs to be hashed before being " ~
            "used by the HMAC algorithm.";
        assert(bytesToHex(hmacSha256(key[], cast(const(ubyte)[]) data)) ==
            "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2");
    }
}
