/// Real system-zlib-backed implementation of `extraction.container`'s
/// injected `ZipInflateV1` boundary. Loaded the same way as
/// `effects.warc_compressed`'s gzip-member decoder: `dlopen` a system
/// path/soname and `dlsym` the exact entry points used, never a link-time
/// `dub.json` "libs" dependency (owner decision on issue #156: match this
/// codebase's existing system-zlib precedent, not `effects.curl_ffi`'s
/// static-link pattern, since zlib already has an established, evaluated
/// access pattern here -- see `docs/warc-reader-evaluation.md`). `etc.c.zlib`
/// supplies the `z_stream` struct/constants already used by
/// `effects.warc_compressed`; only the missing native entry points are
/// declared here.
///
/// Portability (issue #353): macOS keeps its single pinned system path.
/// Linux instead dlopen's the real `libz.so.1`/`libz.so` sonames (not a
/// hardcoded absolute path -- see `systemZlibCandidates` below for the real
/// distro-layout evidence behind that choice), letting the platform's own
/// dynamic linker resolve the actual on-disk location. Both platforms keep
/// the same dlopen/dlsym access pattern; only the candidate list and dlopen
/// flags differ.
///
/// This is the effects-layer half of the injection: `extraction.container`
/// defines the pure `ZipInflateV1` callback type and never performs I/O
/// itself (per `extraction/README.md`); this module supplies the real,
/// impure implementation and exposes it as `zipInflateV1`, for a caller
/// that has both layers in view to pass into `inspectZipContainerV1`.
module effects.zlib_ffi;

import core.sys.posix.dlfcn : dlclose, dlopen, dlsym, RTLD_NOW;
version (OSX) import core.sys.posix.dlfcn : RTLD_FIRST;
import etc.c.zlib : z_stream, Z_NO_FLUSH, Z_OK, Z_STREAM_END;
import extraction.container : ZipInflateOutcomeV1, ZipInflateV1;

version (OSX) {
    version (AArch64) {} else static assert(0,
        "system libz ABI is only verified for macOS arm64");
} else version (linux) {
    // Portability (issue #353): zlib.so.1's inflate ABI is expected to
    // match Phobos's etc.c.zlib declarations, same as macOS's system libz.
    // This ticket adds Linux CI (ubuntu-24.04/-arm, see
    // .github/workflows/sha256-native-backends.yml) running this module's
    // own release-active unittests below to generate the real evidence for
    // that; treat it as unverified until that CI run is green.
} else static assert(0,
    "system libz ABI is only verified for macOS arm64 and Linux x86_64/aarch64");

private alias InflateInit2 = extern(C) int function(z_stream*, int, const(char)*, int);
private alias Inflate = extern(C) int function(z_stream*, int);
private alias InflateEnd = extern(C) int function(z_stream*);
private alias ZlibVersion = extern(C) const(char)* function();

/// Negative window bits select raw DEFLATE (no zlib/gzip header or trailer),
/// matching the bare compressed-data format ZIP local entries store.
private enum int rawInflateWindowBits = -15;

version (OSX) {
    private enum int systemZlibOpenFlags = RTLD_NOW | RTLD_FIRST;
    /// macOS ships exactly one system libz, always at this fixed path (see
    /// this module's own header comment for the owner-decided precedent).
    private enum string[] systemZlibCandidates = ["/usr/lib/libz.1.dylib"];
} else version (linux) {
    private enum int systemZlibOpenFlags = RTLD_NOW;
    // Real evidence (issue #353), not a guess: unlike macOS's single fixed
    // system path, Linux's actual install path for libz varies by distro/
    // multiarch layout (Debian/Ubuntu: /usr/lib/<triplet>/libz.so.1,
    // Fedora/RHEL: /usr/lib64/libz.so.1, Alpine/Arch: /usr/lib/libz.so.1).
    // Hardcoding any one of those absolute paths would just relocate the
    // exact macOS-style fragility this ticket exists to fix. zlib has
    // shipped ABI-stable under soname "libz.so.1" since 1998 and is a
    // near-universal base-system runtime dependency (transitively required
    // by bash/git/gzip/ssh/python and effectively every other package that
    // touches compression) -- so instead of guessing the absolute path,
    // this passes the bare soname to dlopen and lets the platform's own
    // dynamic linker (ld.so, via its ldconfig-built cache) resolve it,
    // exactly the way every other dynamically-linked consumer of libz on
    // that system already does. The unversioned "libz.so" is tried second,
    // for the rarer case where only a dev-symlink is present. Expected
    // present via `ldconfig -p | grep libz.so.1` on ubuntu-24.04
    // x86_64/aarch64 base images; this ticket's own added CI (see
    // .github/workflows/sha256-native-backends.yml) is what turns that
    // expectation into real evidence -- not yet confirmed as of this
    // commit, since no CI run for this branch exists yet.
    private enum string[] systemZlibCandidates = ["libz.so.1", "libz.so"];
}

private final class SystemZlib {
    void* handle;
    InflateInit2 inflateInit2;
    Inflate inflateStep;
    InflateEnd inflateEnd;
    ZlibVersion versionOf;

    private this() {}

    /// Returns `null` on any load/link failure instead of throwing: the
    /// caller reports this as a clean, coded `ZipInflateOutcomeV1.unavailable`
    /// result, never an uncaught exception. Tries each real system-libz
    /// candidate path/soname in turn (see `systemZlibCandidates`); if none
    /// load, this fails closed -- it never falls back to a bundled or
    /// substitute implementation.
    static SystemZlib open() {
        void* handle;
        foreach (candidate; systemZlibCandidates) {
            handle = dlopen(candidate.ptr, systemZlibOpenFlags);
            if (handle !is null) break;
        }
        if (handle is null) return null;
        auto inflateInit2 = cast(InflateInit2) dlsym(handle, "inflateInit2_");
        auto inflateStep = cast(Inflate) dlsym(handle, "inflate");
        auto inflateEnd = cast(InflateEnd) dlsym(handle, "inflateEnd");
        auto versionOf = cast(ZlibVersion) dlsym(handle, "zlibVersion");
        if (inflateInit2 is null || inflateStep is null ||
                inflateEnd is null || versionOf is null) {
            dlclose(handle);
            return null;
        }
        auto zlib = new SystemZlib();
        zlib.handle = handle;
        zlib.inflateInit2 = inflateInit2;
        zlib.inflateStep = inflateStep;
        zlib.inflateEnd = inflateEnd;
        zlib.versionOf = versionOf;
        return zlib;
    }

    ~this() {
        if (handle !is null) dlclose(handle);
    }
}

/// Streams a raw-DEFLATE member fully materialized in `input` (the caller
/// already bounded its byte count against the physical-archive limits the
/// same way STORE payload bytes are bounded). `emit` receives each produced
/// output chunk immediately and may throw to abort the loop before the
/// stream finishes. Never throws itself: every failure is a coded
/// `ZipInflateOutcomeV1` value.
private ZipInflateOutcomeV1 rawInflateImpl(const(ubyte)[] input,
        scope void delegate(const(ubyte)[]) pure emit) {
    auto zlib = SystemZlib.open();
    if (zlib is null) return ZipInflateOutcomeV1.unavailable;
    scope(exit) destroy(zlib);
    z_stream stream = z_stream.init;
    if (zlib.inflateInit2(&stream, rawInflateWindowBits, zlib.versionOf(),
            cast(int) z_stream.sizeof) != Z_OK)
        return ZipInflateOutcomeV1.unavailable;
    scope(exit) zlib.inflateEnd(&stream);
    stream.next_in = input.ptr;
    stream.avail_in = cast(uint) input.length;
    ubyte[65_536] outBuffer;
    while (true) {
        stream.next_out = outBuffer.ptr;
        stream.avail_out = cast(uint) outBuffer.length;
        auto availInBefore = stream.avail_in;
        auto result = zlib.inflateStep(&stream, Z_NO_FLUSH);
        auto produced = outBuffer.length - stream.avail_out;
        if (produced) emit(outBuffer[0 .. produced]);
        if (result == Z_STREAM_END) return ZipInflateOutcomeV1.ok;
        if (result != Z_OK) return ZipInflateOutcomeV1.malformed;
        if (stream.avail_in == availInBefore && produced == 0)
            return ZipInflateOutcomeV1.malformed; // truncated: no progress possible
    }
}

/// The real system-zlib-backed implementation of `extraction.container`'s
/// injected `ZipInflateV1` boundary, cast to `pure` at this single
/// boundary. `rawInflateImpl` only ever touches its own stack-local zlib
/// handle/state and its parameters -- deterministic and side-effect-free
/// from any caller's perspective, even though it performs real `dlopen`/
/// `dlsym`/`inflate` calls internally. This is the same trust
/// `extraction.port.ExtractorApplyV1` places in every registered extractor;
/// asserted here by cast instead of proven by the compiler, because real
/// FFI cannot be proven pure by construction.
immutable ZipInflateV1 zipInflateV1 = cast(ZipInflateV1) &rawInflateImpl;

unittest {
    import std.exception : enforce;

    // ABI probe: a real raw-DEFLATE stream (zlib.compressobj(wbits=-15) for
    // b"hello", generated offline) round-trips through the linked system
    // library's actual entry points, not just the declared signatures.
    ubyte[7] helloDeflate = [0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00];
    ubyte[] output;
    auto outcome = rawInflateImpl(helloDeflate, (const(ubyte)[] chunk) { output ~= chunk; });
    enforce(outcome == ZipInflateOutcomeV1.ok, "raw inflate ABI probe failed");
    enforce(output == cast(const(ubyte)[]) "hello", "raw inflate ABI probe mismatch");

    // Truncated stream: refused, not a crash or hang.
    ubyte[] truncated = helloDeflate[0 .. 3].dup;
    ubyte[] partial;
    auto truncatedOutcome = rawInflateImpl(truncated, (const(ubyte)[] chunk) { partial ~= chunk; });
    enforce(truncatedOutcome != ZipInflateOutcomeV1.ok, "truncated stream unexpectedly completed");

    // A delegate that throws mid-stream aborts before the loop completes.
    size_t chunkCalls;
    bool threw;
    try {
        rawInflateImpl(helloDeflate, (const(ubyte)[] chunk) {
            ++chunkCalls;
            throw new Exception("abort for test");
        });
    } catch (Exception) {
        threw = true;
    }
    enforce(threw && chunkCalls == 1, "emit delegate exception did not abort rawInflateImpl");
}

unittest {
    import content.pieces : Content, ContentPiece;
    import extraction.container : inspectZipContainerV1, ZipEntryEvidenceV1,
        ZipEvidenceV1, ZipInspectionLimitsV1, ZipInspectionReasonV1,
        ZipInspectionStatusV1, ZipPackageKindV1;
    import std.algorithm.searching : canFind;
    import std.exception : enforce;

    // Real, end-to-end DEFLATE admission through the actual injected
    // ZipInflateV1 (not a test double): a docx-shaped archive whose
    // word/document.xml is genuinely DEFLATE-compressed the way Word/
    // LibreOffice/Google Docs actually produce it. `documentDeflate` is a
    // real raw-DEFLATE stream for `documentXml`, generated offline via
    // Python's `zlib.compressobj(9, zlib.DEFLATED, -15)` (wbits -15 selects
    // raw DEFLATE, the same framing ZIP local entries use) -- a genuine
    // reference-implementation round trip, not a hand-authored byte pattern.
    auto documentXml = cast(const(ubyte)[])
        "<w:document>Hello, real DOCX world!</w:document>";
    ubyte[] documentDeflate = [
        179, 41, 183, 74, 201, 79, 46, 205, 77, 205, 43, 177, 243, 72, 205,
        201, 201, 215, 81, 40, 74, 77, 204, 81, 112, 241, 119, 142, 80, 40,
        207, 47, 202, 73, 81, 180, 209, 71, 82, 3, 0
    ];
    auto docx = buildSingleDeflateEntryZip("word/document.xml", documentDeflate,
        cast(uint) documentXml.length, ["[Content_Types].xml", "_rels/.rels"]);
    auto content = new Content([ContentPiece.own(docx)]);
    auto result = inspectZipContainerV1(content, ZipInspectionLimitsV1(), zipInflateV1);
    enforce(result.status == ZipInspectionStatusV1.admitted, "real docx was not admitted");
    enforce(result.packageKind == ZipPackageKindV1.ooxmlWord, "ooxml package kind not detected");
    enforce(result.evidence.canFind(ZipEvidenceV1.deflatePresent), "deflatePresent evidence missing");

    ZipEntryEvidenceV1 documentEvidence;
    bool foundDocument;
    foreach (entry; result.admitted.entries)
        if (entry.name == "word/document.xml") {
            documentEvidence = entry;
            foundDocument = true;
        }
    enforce(foundDocument, "word/document.xml entry missing from admitted evidence");
    enforce(documentEvidence.isDeflate, "word/document.xml not recorded as DEFLATE");
    // Byte-for-byte proof of correct decompression: the real inflate-
    // discovered size matches the real original plaintext length exactly.
    enforce(documentEvidence.expandedBytes == documentXml.length,
        "real inflate-discovered size did not match the real plaintext");
    // extraction.container's new read-time accessor (issue #156's next
    // slice), re-invoking this same real system-zlib decompressor, produces
    // the exact original plaintext bytes -- not just the right byte count.
    enforce(result.admitted.entryBytesV1("word/document.xml") == documentXml,
        "entryBytesV1 did not reproduce the real DEFLATE entry's plaintext");

    // Zip-bomb-style extreme ratio, run through the real decompressor: a
    // genuine 211-byte raw-DEFLATE stream (Python zlib over 200,000 zero
    // bytes, generated offline) expands to 200,000 bytes -- ratio ~948:1 --
    // and the declared header size (deliberately understated to 1 byte) is
    // never trusted, so this cannot slip through as a small, innocuous entry.
    ubyte[] bombDeflate = [
        237, 193, 49, 1, 0, 0, 0, 194, 160, 245, 79, 109, 6, 127, 160, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        128, 215, 0
    ];
    auto bomb = buildSingleDeflateEntryZip("bomb.bin", bombDeflate, 1, null);
    auto bombContent = new Content([ContentPiece.own(bomb)]);
    auto bombResult = inspectZipContainerV1(bombContent, ZipInspectionLimitsV1(), zipInflateV1);
    enforce(bombResult.status == ZipInspectionStatusV1.refused, "ratio bomb was admitted");
    enforce(bombResult.reason == ZipInspectionReasonV1.ratioLimit,
        "ratio bomb refused for the wrong reason");
    // Refused well short of the full 200,000-byte expansion: proof this is a
    // mid-stream abort against the real decompressor, not a check performed
    // only after full decompression.
    enforce(bombResult.cumulativeExpandedBytes > 0 &&
        bombResult.cumulativeExpandedBytes < 200_000,
        "ratio bomb was not aborted mid-stream");
    // The same real stream admits correctly once the ratio budget allows it.
    auto permissive = ZipInspectionLimitsV1();
    permissive.maxRatio = 1_000;
    auto bombAdmitted = inspectZipContainerV1(bombContent, permissive, zipInflateV1);
    enforce(bombAdmitted.status == ZipInspectionStatusV1.admitted,
        "high-but-allowed ratio was refused");
    enforce(bombAdmitted.admitted.entries[0].expandedBytes == 200_000,
        "real decompression size mismatch once admitted");

    // A genuinely truncated real DEFLATE stream: refused as malformed, not
    // a crash or hang.
    auto truncated = documentDeflate[0 .. 5].dup;
    auto truncatedZip = buildSingleDeflateEntryZip("word/document.xml", truncated, 48, null);
    auto truncatedContent = new Content([ContentPiece.own(truncatedZip)]);
    auto truncatedResult = inspectZipContainerV1(truncatedContent, ZipInspectionLimitsV1(), zipInflateV1);
    enforce(truncatedResult.status == ZipInspectionStatusV1.refused, "truncated stream was admitted");
    enforce(truncatedResult.reason == ZipInspectionReasonV1.malformed,
        "truncated stream refused for the wrong reason");
}

unittest {
    import content.pieces : Content, ContentPiece;
    import extraction.container : inspectZipContainerV1, ZipInspectionLimitsV1,
        ZipInspectionStatusV1, ZipPackageKindV1;
    import std.exception : enforce;
    import std.file : exists, read;

    // Real end-to-end proof against a real Word-produced .docx already
    // checked into this repo as a test-only fixture (#67's frozen corpus;
    // see the project's fixture-licensing precedent) -- every entry in this
    // real file is genuinely DEFLATE-compressed (method 8), the way Word/
    // LibreOffice actually produce it, not a hand-authored synthetic
    // archive. `expectedDocumentXml` below is the real, byte-exact
    // `word/document.xml` this file contains, independently verified with
    // Python's own `zipfile` module (a reference implementation, not this
    // codebase's own decompressor) before being pinned here.
    auto fixture = "experiments/document_adapters/fixtures/docx-training.docx";
    if (!exists(fixture)) return; // run from a working directory without the fixture checked out

    enum expectedDocumentXml = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` ~
        `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` ~
        `<w:body><w:p><w:r><w:t>TRAINING DOCX</w:t></w:r></w:p>` ~
        `<w:p><w:r><w:t>GAMMA THREE</w:t></w:r></w:p>` ~
        `<w:p><w:r><w:t>DELTA FOUR</w:t></w:r></w:p><w:sectPr/></w:body></w:document>`;

    auto bytes = cast(ubyte[]) read(fixture);
    auto content = new Content([ContentPiece.own(bytes)]);
    auto result = inspectZipContainerV1(content, ZipInspectionLimitsV1(), zipInflateV1);
    enforce(result.status == ZipInspectionStatusV1.admitted,
        "real docx-training.docx fixture was not admitted");
    enforce(result.packageKind == ZipPackageKindV1.ooxmlWord,
        "real docx-training.docx fixture was not detected as ooxmlWord");
    enforce(result.admitted.entryBytesV1("word/document.xml") ==
        cast(const(ubyte)[]) expectedDocumentXml,
        "real docx-training.docx word/document.xml did not match the independently-verified reference inflate");
}

version (unittest) {
    private void put16(ref ubyte[] bytes, ushort value) {
        bytes ~= cast(ubyte) value;
        bytes ~= cast(ubyte) (value >> 8);
    }

    private void put32(ref ubyte[] bytes, uint value) {
        foreach (shift; 0 .. 4) bytes ~= cast(ubyte) (value >> (8 * shift));
    }

    /// Minimal single-disk classic ZIP with one DEFLATE (method 8) entry
    /// named `deflateName`, plus zero-byte STORE entries for each name in
    /// `extraOoxmlNames` (used to also exercise OOXML package detection).
    /// A small, self-contained mirror of `extraction.container`'s own
    /// (private, module-local) `zipFixture` test helper -- this module
    /// cannot reuse that one directly since it is private to its module.
    private ubyte[] buildSingleDeflateEntryZip(string deflateName,
            ubyte[] deflateData, uint declaredExpanded, string[] extraOoxmlNames) {
        ubyte[] bytes;
        struct Written { string name; uint offset; ushort method; uint compressed; uint expanded; }
        Written[] written;

        void writeStoreEntry(string name) {
            auto offset = cast(uint) bytes.length;
            put32(bytes, 0x04034b50); // local file header signature
            put16(bytes, 20); put16(bytes, 0); put16(bytes, 0); // version, flags, method (STORE)
            put16(bytes, 0); put16(bytes, 0); // mod time/date
            put32(bytes, 0); // crc32
            put32(bytes, 0); put32(bytes, 0); // compressed/expanded size (empty)
            put16(bytes, cast(ushort) name.length); put16(bytes, 0);
            bytes ~= cast(const(ubyte)[]) name;
            written ~= Written(name, offset, 0, 0, 0);
        }

        void writeDeflateEntry(string name, ubyte[] data, uint expanded) {
            auto offset = cast(uint) bytes.length;
            put32(bytes, 0x04034b50);
            put16(bytes, 20); put16(bytes, 0); put16(bytes, 8); // method DEFLATE
            put16(bytes, 0); put16(bytes, 0);
            put32(bytes, 0);
            put32(bytes, cast(uint) data.length); put32(bytes, expanded);
            put16(bytes, cast(ushort) name.length); put16(bytes, 0);
            bytes ~= cast(const(ubyte)[]) name;
            bytes ~= data;
            written ~= Written(name, offset, 8, cast(uint) data.length, expanded);
        }

        foreach (name; extraOoxmlNames) writeStoreEntry(name);
        writeDeflateEntry(deflateName, deflateData, declaredExpanded);

        auto centralOffset = cast(uint) bytes.length;
        foreach (entry; written) {
            put32(bytes, 0x02014b50);
            put16(bytes, 20); put16(bytes, 20);
            put16(bytes, 0); put16(bytes, entry.method);
            put16(bytes, 0); put16(bytes, 0);
            put32(bytes, 0);
            put32(bytes, entry.compressed); put32(bytes, entry.expanded);
            put16(bytes, cast(ushort) entry.name.length);
            put16(bytes, 0); put16(bytes, 0);
            put16(bytes, 0); put16(bytes, 0); put32(bytes, 0);
            put32(bytes, entry.offset);
            bytes ~= cast(const(ubyte)[]) entry.name;
        }
        auto centralBytes = cast(uint) bytes.length - centralOffset;
        put32(bytes, 0x06054b50);
        put16(bytes, 0); put16(bytes, 0);
        put16(bytes, cast(ushort) written.length);
        put16(bytes, cast(ushort) written.length);
        put32(bytes, centralBytes);
        put32(bytes, centralOffset);
        put16(bytes, 0);
        return bytes;
    }
}
