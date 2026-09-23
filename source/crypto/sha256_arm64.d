/// ARMv8 SHA2 compression isolated from portable SHA-256 state management.
module crypto.sha256_arm64;

version (AArch64) {
    import core.simd : uint4;
    import ldc.attributes : target;
    import ldc.simd : loadUnaligned;

    version (OSX)
        private extern(C) nothrow int sysctlbyname(const(char)*, void*, size_t*,
            const(void)*, size_t);
    else version (linux)
        private extern(C) nothrow ulong getauxval(ulong);

    pragma(LDC_intrinsic, "llvm.aarch64.crypto.sha256h")
    private uint4 sha256h(uint4, uint4, uint4) pure @safe;
    pragma(LDC_intrinsic, "llvm.aarch64.crypto.sha256h2")
    private uint4 sha256h2(uint4, uint4, uint4) pure @safe;
    pragma(LDC_intrinsic, "llvm.aarch64.crypto.sha256su0")
    private uint4 sha256su0(uint4, uint4) pure @safe;
    pragma(LDC_intrinsic, "llvm.aarch64.crypto.sha256su1")
    private uint4 sha256su1(uint4, uint4, uint4) pure @safe;

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

    private uint loadBigEndian(const(ubyte)* bytes) pure @trusted {
        return cast(uint) bytes[0] << 24 | cast(uint) bytes[1] << 16 |
            cast(uint) bytes[2] << 8 | bytes[3];
    }

    private uint4 vector(uint a, uint b, uint c, uint d) pure @trusted {
        uint[4] values = [a, b, c, d];
        return loadUnaligned!uint4(values.ptr);
    }

    /// This function alone is compiled for SHA2. Callers must first prove the
    /// running CPU supports SHA2; the portable facade owns that decision.
    @target("sha2")
    void compressArmSha2(ref uint[8] state, const(ubyte)* block) pure @trusted {
        uint4[16] message;
        foreach (group; 0 .. 4) {
            auto at = block + group * 16;
            message[group] = vector(loadBigEndian(at), loadBigEndian(at + 4),
                loadBigEndian(at + 8), loadBigEndian(at + 12));
        }
        foreach (group; 4 .. 16) {
            auto partial = sha256su0(message[group - 4], message[group - 3]);
            message[group] = sha256su1(partial, message[group - 2],
                message[group - 1]);
        }

        uint4 abcd = vector(state[0], state[1], state[2], state[3]);
        uint4 efgh = vector(state[4], state[5], state[6], state[7]);
        const originalAbcd = abcd;
        const originalEfgh = efgh;
        foreach (group; 0 .. 16) {
            auto constants = vector(roundConstants[group * 4],
                roundConstants[group * 4 + 1], roundConstants[group * 4 + 2],
                roundConstants[group * 4 + 3]);
            auto schedule = message[group] + constants;
            auto priorAbcd = abcd;
            abcd = sha256h(abcd, efgh, schedule);
            efgh = sha256h2(efgh, priorAbcd, schedule);
        }
        abcd += originalAbcd;
        efgh += originalEfgh;
        foreach (i; 0 .. 4) {
            state[i] = abcd.array[i];
            state[i + 4] = efgh.array[i];
        }
    }

    bool armSha2Available() nothrow {
        version (OSX) {
            import std.string : toStringz;
            int value;
            size_t length = value.sizeof;
            return sysctlbyname("hw.optional.arm.FEAT_SHA256".toStringz,
                &value, &length, null, 0) == 0 && length == value.sizeof &&
                value == 1;
        } else version (linux) {
            enum ulong AT_HWCAP = 16;
            enum ulong HWCAP_SHA2 = 1UL << 6;
            return (getauxval(AT_HWCAP) & HWCAP_SHA2) != 0;
        } else return false;
    }
} else {
    void compressArmSha2(ref uint[8], const(ubyte)*) pure @safe {
        assert(false, "ARM SHA2 backend is not compiled for this target");
    }
    bool armSha2Available() nothrow { return false; }
}
