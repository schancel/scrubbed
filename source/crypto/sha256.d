/// Private incremental SHA-256 facade with safely selected architecture backends.
module crypto.sha256;

import crypto.sha256_arm64 : armSha2Available, compressArmSha2;
import crypto.sha256_x86_64 : compressX86ShaNi, x86ShaNiAvailable;
import std.exception : enforce;

enum Sha256Backend : ubyte { automatic, scalar, armSha2, x86ShaNi }

private alias Compression = void function(ref uint[8], const(ubyte)*) pure @safe;

private uint rotateRight(uint value, uint count) pure @safe {
    return value >> count | value << (32 - count);
}

private immutable uint[64] roundConstants = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

private void compressScalar(ref uint[8] state, const(ubyte)* block) pure @trusted {
    uint[64] words;
    foreach (i; 0 .. 16) {
        auto bytes = block + i * 4;
        words[i] = cast(uint)bytes[0] << 24 | cast(uint)bytes[1] << 16 |
            cast(uint)bytes[2] << 8 | bytes[3];
    }
    foreach (i; 16 .. 64) {
        auto s0 = rotateRight(words[i - 15], 7) ^
            rotateRight(words[i - 15], 18) ^ words[i - 15] >> 3;
        auto s1 = rotateRight(words[i - 2], 17) ^
            rotateRight(words[i - 2], 19) ^ words[i - 2] >> 10;
        words[i] = words[i - 16] + s0 + words[i - 7] + s1;
    }
    uint a = state[0], b = state[1], c = state[2], d = state[3];
    uint e = state[4], f = state[5], g = state[6], h = state[7];
    foreach (i; 0 .. 64) {
        auto sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
        auto choose = (e & f) ^ (~e & g);
        auto first = h + sum1 + choose + roundConstants[i] + words[i];
        auto sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
        auto majority = (a & b) ^ (a & c) ^ (b & c);
        auto second = sum0 + majority;
        h = g; g = f; f = e; e = d + first;
        d = c; c = b; b = a; a = first + second;
    }
    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

private Sha256Backend detectBackend() nothrow {
    if (armSha2Available) return Sha256Backend.armSha2;
    if (x86ShaNiAvailable) return Sha256Backend.x86ShaNi;
    return Sha256Backend.scalar;
}

private immutable Sha256Backend processBackend;
shared static this() { processBackend = detectBackend; }

Sha256Backend selectedSha256Backend() nothrow { return processBackend; }
bool sha256BackendAvailable(Sha256Backend backend) nothrow {
    final switch (backend) {
    case Sha256Backend.automatic: return true;
    case Sha256Backend.scalar: return true;
    case Sha256Backend.armSha2: return armSha2Available;
    case Sha256Backend.x86ShaNi: return x86ShaNiAvailable;
    }
}

string sha256BackendName(Sha256Backend backend) pure nothrow {
    final switch (backend) {
    case Sha256Backend.automatic: return "automatic";
    case Sha256Backend.scalar: return "scalar";
    case Sha256Backend.armSha2: return "armv8-sha2";
    case Sha256Backend.x86ShaNi: return "x86-sha-ni";
    }
}

private Compression compressionFor(Sha256Backend backend) {
    final switch (backend) {
    case Sha256Backend.automatic:
        return compressionFor(processBackend);
    case Sha256Backend.scalar:
        return &compressScalar;
    case Sha256Backend.armSha2:
        enforce(armSha2Available, "SHA-256 backend unavailable: armv8-sha2");
        return &compressArmSha2;
    case Sha256Backend.x86ShaNi:
        enforce(x86ShaNiAvailable, "SHA-256 backend unavailable: x86-sha-ni");
        return &compressX86ShaNi;
    }
}

struct Sha256 {
private:
    uint[8] state;
    ubyte[64] pending;
    size_t pendingLength;
    ulong totalBytes;
    Compression compress;
    Sha256Backend backendValue;
    bool active;

public:
    static Sha256 create(Sha256Backend requested = Sha256Backend.automatic) {
        Sha256 result;
        result.backendValue = requested == Sha256Backend.automatic
            ? processBackend : requested;
        result.compress = compressionFor(result.backendValue);
        result.start;
        return result;
    }

    Sha256Backend backend() const pure nothrow { return backendValue; }

    void start() pure {
        enforce(compress !is null, "SHA-256 facade is not initialized");
        state = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
        pending[] = 0;
        pendingLength = 0;
        totalBytes = 0;
        active = true;
    }

    void put(scope const(ubyte)[] input) pure {
        enforce(active, "SHA-256 facade is not active");
        enforce(input.length <= (ulong.max >> 3) - totalBytes,
            "SHA-256 input length overflow");
        totalBytes += input.length;
        size_t at;
        if (pendingLength) {
            auto amount = input.length < pending.length - pendingLength
                ? input.length : pending.length - pendingLength;
            pending[pendingLength .. pendingLength + amount] = input[0 .. amount];
            pendingLength += amount;
            at += amount;
            if (pendingLength == pending.length) {
                compress(state, pending.ptr);
                pendingLength = 0;
            }
        }
        while (at + 64 <= input.length) {
            compress(state, input.ptr + at);
            at += 64;
        }
        if (at < input.length) {
            pending[0 .. input.length - at] = input[at .. $];
            pendingLength = input.length - at;
        }
    }

    ubyte[32] finish() pure {
        enforce(active, "SHA-256 facade is not active");
        auto bitLength = totalBytes << 3;
        pending[pendingLength++] = 0x80;
        if (pendingLength > 56) {
            pending[pendingLength .. $] = 0;
            compress(state, pending.ptr);
            pendingLength = 0;
        }
        pending[pendingLength .. 56] = 0;
        foreach (i; 0 .. 8)
            pending[63 - i] = cast(ubyte)(bitLength >> (i * 8));
        compress(state, pending.ptr);
        ubyte[32] result;
        foreach (i, word; state) {
            result[i * 4] = cast(ubyte)(word >> 24);
            result[i * 4 + 1] = cast(ubyte)(word >> 16);
            result[i * 4 + 2] = cast(ubyte)(word >> 8);
            result[i * 4 + 3] = cast(ubyte)word;
        }
        active = false;
        pending[] = 0;
        return result;
    }
}
