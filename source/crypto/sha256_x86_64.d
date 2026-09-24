/// x86-64 SHA-NI compression isolated from portable SHA-256 state management.
module crypto.sha256_x86_64;

version (X86_64) {
    import core.cpuid : hasSha;
    import core.simd : int4, uint4;
    import ldc.attributes : target;
    import ldc.gccbuiltins_x86 : __builtin_ia32_sha256rnds2;
    import ldc.simd : loadUnaligned;

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

    private uint rotateRight(uint value, uint count) pure @safe {
        return value >> count | value << (32 - count);
    }
    private uint sigma0(uint value) pure {
        return rotateRight(value, 7) ^ rotateRight(value, 18) ^ value >> 3;
    }
    private uint sigma1(uint value) pure {
        return rotateRight(value, 17) ^ rotateRight(value, 19) ^ value >> 10;
    }
    private uint loadBigEndian(const(ubyte)* bytes) pure @trusted {
        return cast(uint) bytes[0] << 24 | cast(uint) bytes[1] << 16 |
            cast(uint) bytes[2] << 8 | bytes[3];
    }
    private int4 vector(uint a, uint b, uint c, uint d) pure @trusted {
        uint[4] values = [a, b, c, d];
        return cast(int4) loadUnaligned!uint4(values.ptr);
    }

    /// Scalar expansion keeps this first backend auditable; SHA-NI executes
    /// all 64 rounds. The facade checks CPUID before entering this function.
    @target("sha")
    package(crypto) void compressX86ShaNi(ref uint[8] state,
            const(ubyte)* block) pure @trusted {
        uint[64] words;
        foreach (i; 0 .. 16) words[i] = loadBigEndian(block + i * 4);
        foreach (i; 16 .. 64)
            words[i] = sigma1(words[i - 2]) + words[i - 7] +
                sigma0(words[i - 15]) + words[i - 16];

        // SHA256RNDS2 uses the ABEF/CDGH layout used by Intel's reference
        // sequence. Explicit construction avoids depending on host byte order
        // or unaligned vector loads.
        auto state0 = vector(state[5], state[4], state[1], state[0]); // FEBA
        auto state1 = vector(state[7], state[6], state[3], state[2]); // HGDC
        const saved0 = state0;
        const saved1 = state1;
        foreach (group; 0 .. 16) {
            auto message = vector(words[group * 4] + roundConstants[group * 4],
                words[group * 4 + 1] + roundConstants[group * 4 + 1],
                words[group * 4 + 2] + roundConstants[group * 4 + 2],
                words[group * 4 + 3] + roundConstants[group * 4 + 3]);
            state1 = __builtin_ia32_sha256rnds2(state1, state0, message);
            auto high = vector(cast(uint)message.array[2],
                cast(uint)message.array[3], 0, 0);
            state0 = __builtin_ia32_sha256rnds2(state0, state1, high);
        }
        state0 += saved0;
        state1 += saved1;
        state[0] = cast(uint) state0.array[3];
        state[1] = cast(uint) state0.array[2];
        state[2] = cast(uint) state1.array[3];
        state[3] = cast(uint) state1.array[2];
        state[4] = cast(uint) state0.array[1];
        state[5] = cast(uint) state0.array[0];
        state[6] = cast(uint) state1.array[1];
        state[7] = cast(uint) state1.array[0];
    }

    package(crypto) bool x86ShaNiAvailable() nothrow { return hasSha; }
} else {
    package(crypto) void compressX86ShaNi(ref uint[8], const(ubyte)*) pure @safe {
        assert(false, "x86 SHA-NI backend is not compiled for this target");
    }
    package(crypto) bool x86ShaNiAvailable() nothrow { return false; }
}
