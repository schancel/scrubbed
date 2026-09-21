// Evidence-only WARC/1.1 gzip-member and proposed zstd-frame probe.
// Link against an externally built, pinned libzstd.a; never ship it here.
import core.stdc.config : c_ulong;
import core.memory : GC;
import core.sys.posix.sys.resource : RUSAGE_SELF, getrusage, rusage;
import std.conv : to;
import std.digest.sha : sha256Of, toHexString;
import std.file : SpanMode, dirEntries, remove, tempDir;
import std.path : buildPath;
import std.stdio : File, writeln;
import std.string : fromStringz, indexOf, startsWith;
import std.zlib : Compress, HeaderFormat;
import std.uuid : randomUUID;

extern(C) nothrow @nogc {
    struct ZStream {
        ubyte* next_in;
        uint avail_in;
        c_ulong total_in;
        ubyte* next_out;
        uint avail_out;
        c_ulong total_out;
        char* msg;
        void* state;
        void* zalloc;
        void* zfree;
        void* opaque;
        int data_type;
        c_ulong adler;
        c_ulong reserved;
    }
    const(char)* zlibVersion();
    int inflateInit2_(ZStream*, int, const(char)*, int);
    int inflate(ZStream*, int);
    int inflateEnd(ZStream*);
    void* ZSTD_createCCtx();
    size_t ZSTD_freeCCtx(void*);
    size_t ZSTD_CCtx_setParameter(void*, int, int);
    size_t ZSTD_compress2(void*, void*, size_t, const(void)*, size_t);
    size_t ZSTD_compressBound(size_t);
    void* ZSTD_createDStream();
    size_t ZSTD_freeDStream(void*);
    size_t ZSTD_initDStream(void*);
    size_t ZSTD_DCtx_setParameter(void*, int, int);
    struct ZIn { const(void)* src; size_t size; size_t pos; }
    struct ZOut { void* dst; size_t size; size_t pos; }
    size_t ZSTD_decompressStream(void*, ZOut*, ZIn*);
    size_t ZSTD_findFrameCompressedSize(const(void)*, size_t);
    ulong ZSTD_getFrameContentSize(const(void)*, size_t);
    uint ZSTD_isError(size_t);
}

enum maxCompressed = 1024 * 1024;
enum maxRecord = 128 * 1024;
enum maxHeader = 4096;
enum maxBody = 64 * 1024;
enum maxRatio = 64;
enum chunk = 127;

class Reject : Exception { this(string message) { super(message); } }
void require(bool ok, string reason) { if (!ok) throw new Reject(reason); }

struct Record {
    string id, uri, date, kind, blockHash, headerHash, sourceKey;
    size_t bodyLength;
}

// The full-record buffer is bounded, including headers and body. A production
// reader would stream the block to a sink; this experiment intentionally does not.
class Parser {
    private ubyte[] pending;
    Record[] records;
    string sourceKey;
    this(string key) { sourceKey = key; }

    void feed(const(ubyte)[] data) {
        require(data.length <= maxRecord - pending.length, "record cap");
        pending ~= data;
        while (pending.length) {
            auto text = cast(string) pending;
            auto split = text.indexOf("\r\n\r\n");
            if (split < 0) {
                require(pending.length <= maxHeader, "header cap");
                return;
            }
            auto headerEnd = cast(size_t) split + 4;
            require(headerEnd <= maxHeader, "header cap");
            auto header = text[0 .. headerEnd];
            require(header.startsWith("WARC/1.1\r\n"), "version or CRLF");
            string id, uri, date, kind, lenText;
            auto lines = header[0 .. $ - 4].split("\r\n");
            foreach (line; lines[1 .. $]) {
                auto part = line;
                require(part.indexOf('\r') < 0 && part.indexOf('\n') < 0, "header CRLF");
                auto colon = part.indexOf(':');
                require(colon > 0, "header field");
                auto name = part[0 .. colon].toLower;
                auto value = part[cast(size_t) colon + 1 .. $].strip;
                if (name == "warc-record-id") { require(id.length == 0, "duplicate id"); id = value; }
                else if (name == "warc-target-uri") { require(uri.length == 0, "duplicate uri"); uri = value; }
                else if (name == "warc-date") { require(date.length == 0, "duplicate date"); date = value; }
                else if (name == "warc-type") { require(kind.length == 0, "duplicate type"); kind = value; }
                else if (name == "content-length") { require(lenText.length == 0, "duplicate length"); lenText = value; }
            }
            require(id.startsWith("<urn:") && id.endsWith(">") && uri.length && date.length && kind.length, "required fields");
            require(lenText.length > 0, "missing length");
            size_t bodyLength;
            foreach (digit; lenText) {
                require(digit >= '0' && digit <= '9', "invalid length");
                require(bodyLength <= (maxBody - cast(size_t)(digit - '0')) / 10, "body cap/overflow");
                bodyLength = bodyLength * 10 + digit - '0';
            }
            auto total = headerEnd + bodyLength + 4;
            require(total <= maxRecord, "record cap");
            if (pending.length < total) return;
            require(pending[headerEnd + bodyLength .. total] == cast(const(ubyte)[]) "\r\n\r\n", "record terminator");
            auto body = pending[headerEnd .. headerEnd + bodyLength];
            records ~= Record(id, uri, date, kind, toHexString(sha256Of(body)).idup,
                toHexString(sha256Of(cast(const(ubyte)[]) header)).idup, sourceKey, bodyLength);
            pending = pending[total .. $].dup;
        }
    }
    void finish() { require(pending.length == 0, "truncated record"); }
}

import std.string : endsWith, split, strip, toLower;

ubyte[] warc(string id, string uri, string kind, const(ubyte)[] block,
             string lenOverride = "") {
    auto header = "WARC/1.1\r\nWARC-Type: " ~ kind ~
        "\r\nWARC-Record-ID: <urn:uuid:" ~ id ~ ">\r\n" ~
        "WARC-Target-URI: " ~ uri ~ "\r\nWARC-Date: 2026-09-21T00:00:00Z\r\n" ~
        "Content-Type: " ~ (kind == "conversion" ? "text/plain" : "application/http") ~
        "\r\nContent-Length: " ~ (lenOverride.length ? lenOverride : to!string(block.length)) ~ "\r\n\r\n";
    return (cast(ubyte[]) header.dup ~ block ~ cast(ubyte[]) "\r\n\r\n").dup;
}

ubyte[] gzipMember(const(ubyte)[] raw) {
    auto c = new Compress(HeaderFormat.gzip);
    auto a = cast(ubyte[]) c.compress(raw);
    return (a ~ cast(ubyte[]) c.flush()).dup;
}

ubyte[] zstdFrame(const(ubyte)[] raw) {
    auto c = ZSTD_createCCtx();
    require(c !is null, "zstd create");
    scope(exit) ZSTD_freeCCtx(c);
    // ZSTD_c_checksumFlag = 201; compress2 records content size for known srcSize.
    require(!ZSTD_isError(ZSTD_CCtx_setParameter(c, 201, 1)), "zstd checksum flag");
    auto output = new ubyte[ZSTD_compressBound(raw.length)];
    auto count = ZSTD_compress2(c, output.ptr, output.length, raw.ptr, raw.length);
    require(!ZSTD_isError(count), "zstd compress");
    return output[0 .. count].dup;
}

void decodeGzip(const(ubyte)[] archive, Parser parser, size_t step = chunk) {
    require(archive.length <= maxCompressed, "compressed input cap");
    size_t offset;
    while (offset < archive.length) {
        auto before = parser.records.length;
        ZStream state;
        require(inflateInit2_(&state, 31, zlibVersion(), ZStream.sizeof) == 0, "gzip init");
        scope(exit) inflateEnd(&state);
        auto start = offset;
        bool ended;
        while (!ended) {
            require(offset < archive.length || state.avail_in, "truncated gzip");
            if (state.avail_in == 0) {
                auto n = (archive.length - offset) < step ? archive.length - offset : step;
                state.next_in = cast(ubyte*) archive[offset .. offset + n].ptr;
                state.avail_in = cast(uint) n;
                offset += n;
            }
            ubyte[chunk] output;
            state.next_out = output.ptr;
            state.avail_out = output.length;
            auto rc = inflate(&state, 0);
            require(rc == 0 || rc == 1, "corrupt gzip");
            auto produced = output.length - state.avail_out;
            require(state.total_out <= maxRecord, "gzip output cap");
            require(state.total_out <= maxRatio * (state.total_in + 64), "gzip ratio cap");
            parser.feed(output[0 .. produced]);
            ended = rc == 1;
        }
        offset = start + cast(size_t) state.total_in;
        require(offset > start, "gzip no progress");
        parser.finish();
        require(parser.records.length == before + 1, "gzip member must contain one record");
    }
    parser.finish();
}

void decodeZstd(const(ubyte)[] archive, Parser parser, size_t step = chunk) {
    require(archive.length <= maxCompressed, "compressed input cap");
    size_t offset;
    while (offset < archive.length) {
        auto before = parser.records.length;
        auto frameSize = ZSTD_findFrameCompressedSize(archive[offset .. $].ptr, archive.length - offset);
        require(!ZSTD_isError(frameSize) && frameSize <= archive.length - offset, "truncated/corrupt zstd frame");
        auto frame = archive[offset .. offset + frameSize];
        require(frame.length >= 6 && frame[0 .. 4] == [0x28, 0xb5, 0x2f, 0xfd], "zstd or dictionary frame");
        require((frame[4] & 0x04) != 0, "zstd checksum missing");
        auto declared = ZSTD_getFrameContentSize(frame.ptr, frame.length);
        require(declared <= maxRecord && declared <= maxRatio * (frame.length + 64), "zstd declared cap");
        auto d = ZSTD_createDStream();
        require(d !is null, "zstd stream create");
        scope(exit) ZSTD_freeDStream(d);
        require(!ZSTD_isError(ZSTD_initDStream(d)), "zstd stream init");
        // ZSTD_d_windowLogMax = 100; cap native streaming window at 128 KiB.
        require(!ZSTD_isError(ZSTD_DCtx_setParameter(d, 100, 17)), "zstd window cap");
        size_t inputPos, outputTotal;
        bool ended;
        while (!ended) {
            auto n = (frame.length - inputPos) < step ? frame.length - inputPos : step;
            require(n > 0, "truncated zstd");
            ZIn input = ZIn(frame[inputPos .. inputPos + n].ptr, n, 0);
            while (input.pos < input.size) {
                ubyte[chunk] output;
                ZOut outBuf = ZOut(output.ptr, output.length, 0);
                auto rc = ZSTD_decompressStream(d, &outBuf, &input);
                require(!ZSTD_isError(rc), "corrupt zstd");
                require(outBuf.pos <= maxRecord - outputTotal, "zstd output cap");
                outputTotal += outBuf.pos;
                require(outputTotal <= maxRatio * (inputPos + input.pos + 64), "zstd ratio cap");
                parser.feed(output[0 .. outBuf.pos]);
                if (rc == 0) { ended = true; require(input.pos == input.size && inputPos + n == frame.length, "frame trailing bytes"); break; }
                require(input.pos || outBuf.pos, "zstd no progress");
            }
            inputPos += n;
        }
        require(outputTotal == declared, "zstd size mismatch");
        parser.finish();
        require(parser.records.length == before + 1, "zstd frame must contain one record");
        offset += frameSize;
    }
    parser.finish();
}

void rejects(void delegate() action, string expected) {
    bool didReject;
    try action();
    catch (Reject e) { didReject = true; }
    require(didReject, "negative fixture accepted: " ~ expected);
}

size_t fdCount() {
    size_t n;
    foreach (_; dirEntries("/dev/fd", SpanMode.shallow)) ++n;
    return n;
}

long maxRss() {
    rusage usage;
    require(getrusage(RUSAGE_SELF, &usage) == 0, "getrusage");
    version (OSX) return usage.ru_opaque[0]; // Darwin's first opaque slot is ru_maxrss (bytes).
    else return usage.ru_maxrss; // Linux reports KiB.
}

void main() {
    writeln("runtime zlib=", fromStringz(zlibVersion()));
    auto fdBefore = fdCount();
    auto rssBefore = maxRss();
    auto gcBefore = GC.stats.usedSize;
    auto one = warc("00000000-0000-0000-0000-000000000001", "https://example.org/a", "response",
        cast(const(ubyte)[]) "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nhi\0there");
    auto two = warc("00000000-0000-0000-0000-000000000002", "https://example.org/b", "conversion",
        cast(const(ubyte)[]) "caf\xc3\xa9\nWET body\n");
    auto raw = one ~ two;
    auto gz = gzipMember(one) ~ gzipMember(two);
    auto zs = zstdFrame(one) ~ zstdFrame(two);
    auto fixturePath = buildPath(tempDir, "scrubd-warc-" ~ randomUUID().toString ~ ".gz");
    scope(exit) remove(fixturePath);
    {
        auto fixture = File(fixturePath, "w+b");
        require(fdCount() == fdBefore + 1, "fixture descriptor open");
        fixture.rawWrite(gz);
        fixture.seek(0);
        ubyte[chunk] readBuffer;
        ubyte[] readBack;
        for (;;) {
            auto n = fixture.rawRead(readBuffer[]);
            if (n.length == 0) break;
            require(readBack.length + n.length <= maxCompressed, "file input cap");
            readBack ~= n;
        }
        require(readBack == gz, "fixture file round trip");
        fixture.close();
        require(fdCount() == fdBefore, "fixture descriptor close");
    }
    auto plain = new Parser("archive-key");
    foreach (b; raw) plain.feed((&b)[0 .. 1]);
    plain.finish();
    auto g = new Parser("archive-key"); decodeGzip(gz, g, 1);
    auto z = new Parser("archive-key"); decodeZstd(zs, z, 1);
    require(g.records.length == 2 && z.records.length == 2, "record count");
    require(plain.records[0].id == "<urn:uuid:00000000-0000-0000-0000-000000000001>" &&
        plain.records[1].id == "<urn:uuid:00000000-0000-0000-0000-000000000002>" &&
        plain.records[0].uri == "https://example.org/a" &&
        plain.records[1].uri == "https://example.org/b" &&
        plain.records[0].date == "2026-09-21T00:00:00Z" &&
        plain.records[1].date == "2026-09-21T00:00:00Z" &&
        plain.records[0].kind == "response" && plain.records[1].kind == "conversion" &&
        plain.records[0].sourceKey == "archive-key" && plain.records[1].sourceKey == "archive-key",
        "pinned identity fields");
    foreach (i; 0 .. 2) {
        require(g.records[i] == plain.records[i] && z.records[i] == plain.records[i], "record equivalence");
        writeln(plain.records[i].id, " ", plain.records[i].uri, " ", plain.records[i].date,
            " header_sha256=", plain.records[i].headerHash, " body_sha256=", plain.records[i].blockHash);
    }
    require(plain.records[0].headerHash == "1AF48705DC634605AD10FBEE02711C2635FA429B3E7271E74D6AB5FD7B8E3420" &&
        plain.records[0].blockHash == "39AD3DAD2662D694C233E7BA171EDCB439020FBEBAFB8D8127C11EDFE7A411E4" &&
        plain.records[1].headerHash == "E6CB6BE0F41709D716C8D871E8AFF0A60D310FEAACF69784FE1DB617E02F97DF" &&
        plain.records[1].blockHash == "1F359813ACDD5E1A8BB0EF7AA6EBF46E477889FD0387BFD5050A1B0FF6A01D61",
        "pinned fixture hashes");
    rejects({ auto p = new Parser("k"); p.feed(warc("x", "u", "response", cast(const(ubyte)[]) "x", "x")); }, "invalid length");
    rejects({ auto p = new Parser("k"); p.feed(warc("x", "u", "response", cast(const(ubyte)[]) "x", "999999999999999999999999")); }, "overflow length");
    rejects({ auto p = new Parser("k"); p.feed(warc("x", "u", "response", cast(const(ubyte)[]) "x", "65537")); }, "body cap");
    // Build an explicitly absent field independent of the fixture block length.
    auto lengthStart = (cast(string) one).indexOf("Content-Length:");
    auto lengthEnd = (cast(string) one)[cast(size_t) lengthStart .. $].indexOf("\r\n");
    auto missing = (cast(string) one)[0 .. cast(size_t) lengthStart] ~
        (cast(string) one)[cast(size_t) lengthStart + cast(size_t) lengthEnd + 2 .. $];
    rejects({ auto p = new Parser("k"); p.feed(cast(const(ubyte)[]) missing); }, "missing length");
    auto longHeader = new char[maxHeader]; longHeader[] = 'a';
    rejects({ auto p = new Parser("k"); p.feed(cast(const(ubyte)[]) ("WARC/1.1\r\nX: " ~ longHeader ~ "\r\n\r\n")); }, "header cap");
    rejects({ auto p = new Parser("k"); decodeGzip(new ubyte[maxCompressed + 1], p); }, "compressed input cap");
    rejects({ auto p = new Parser("k"); p.feed(one[0 .. $ - 1]); p.finish(); }, "truncated record");
    rejects({ auto p = new Parser("k"); decodeGzip(gz[0 .. $ - 1], p); }, "truncated gzip");
    rejects({ auto p = new Parser("k"); decodeZstd(zs[0 .. $ - 1], p); }, "truncated zstd");
    auto corruptGz = gz.dup; corruptGz[$ - 5] ^= 0xff;
    rejects({ auto p = new Parser("k"); decodeGzip(corruptGz, p); }, "corrupt gzip");
    auto corruptZs = zs.dup; corruptZs[$ - 5] ^= 0xff;
    rejects({ auto p = new Parser("k"); decodeZstd(corruptZs, p); }, "corrupt zstd");
    auto large = new ubyte[maxBody + 1]; large[] = 'a';
    auto hugeGz = gzipMember(warc("x", "u", "response", large));
    rejects({ auto p = new Parser("k"); decodeGzip(hugeGz, p); }, "high-ratio oversized body");
    auto hugeZs = zstdFrame(warc("x", "u", "response", large));
    rejects({ auto p = new Parser("k"); decodeZstd(hugeZs, p); }, "declared oversized frame");
    auto ratioBody = new ubyte[60 * 1024]; ratioBody[] = 'r';
    auto ratioGz = gzipMember(warc("x", "u", "response", ratioBody));
    rejects({ auto p = new Parser("k"); decodeGzip(ratioGz, p); }, "gzip expansion ratio");
    auto ratioZs = zstdFrame(warc("x", "u", "response", ratioBody));
    rejects({ auto p = new Parser("k"); decodeZstd(ratioZs, p); }, "zstd expansion ratio");
    foreach (_; 0 .. 100) {
        auto bounded = new Parser("archive-key");
        decodeGzip(gz, bounded, 1);
        require(bounded.records.length == 2, "repeat count");
    }
    GC.collect();
    auto fdAfter = fdCount();
    require(fdAfter == fdBefore, "descriptor leak");
    writeln("resource evidence: max_rss_before=", rssBefore,
        " max_rss_after=", maxRss(), " gc_used_before=", gcBefore,
        " gc_used_after_collect=", GC.stats.usedSize,
        " fd_before=", fdBefore, " fd_after=", fdAfter);
    writeln("PASS: 2 records, gzip members, zstd frames, 15 release-active negatives");
}
