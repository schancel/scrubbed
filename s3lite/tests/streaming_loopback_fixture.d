/// Loopback proof for the streaming core (`s3lite.core`, issue #607).
///
/// Everything the client does here happens inside `@nogc nothrow`
/// functions: the compiler, not a comment, establishes that the core's
/// request building, signing, transport and parsing paths neither allocate
/// from the collector nor throw. The server side (`loopback_server`) is
/// ordinary test scaffolding.
///
///   A. Upload from a range of many small chunks that is generated on the
///      fly and never exists as one buffer. The server checks every byte
///      and the declared `Content-Length`, under both payload-hash policies.
///      An upload with options puts content type, storage class, a
///      checksum and user metadata on the wire, all signed; its signature
///      is compared with one derived by a separate implementation.
///   B. Download into a sink, whole and with a byte range, through both the
///      delegate form and the output-range form; an S3 error arrives as a
///      typed status and never reaches the sink.
///   C. A listing across three pages through the entry callback, with an
///      entry buffer much smaller than a page and an explicit continuation;
///      and a delimited listing whose common prefixes arrive through their
///      own callback.
///   D. All of the above over one client: the server sees one connection.
///   E. The convenience layer's range upload (`s3lite.client.putObject`)
///      with a range that allocates, and with one that throws part-way.
///
/// No AWS account, credential, or network access beyond 127.0.0.1 is used.
/// Run via: `dub run --config=streaming-loopback-fixture` (from this
/// package's own directory).
import convenience = s3lite.client;
import loopback_server;
import s3lite.core;
import s3lite.curl_transport : CurlOptions, openCurlTransport;
import s3lite.sigv4 : sha256Hex;
import std.algorithm.searching : canFind, startsWith;
import std.conv : to;
import std.stdio : writeln;
import std.string : indexOf;

void check(bool condition, lazy string label) {
    if (!condition) throw new Exception("FAIL: " ~ label);
}

// ---------------------------------------------------------------------
// The object: a deterministic byte pattern, so neither side needs a copy.
// ---------------------------------------------------------------------

ubyte patternByte(ulong offset) @nogc nothrow pure {
    return cast(ubyte)((offset * 31 + (offset >> 8) * 7) & 0xff);
}

enum size_t smallChunk = 37;
enum ulong uploadChunks = 20_000;
enum ulong uploadLength = smallChunk * uploadChunks; // 740,000 bytes in 20,000 pieces

/// A forward range of `smallChunk`-byte chunks of the pattern. Each chunk
/// is produced into the one small buffer the range points at; the object
/// as a whole never exists in memory.
struct PatternChunks {
    ubyte[] buffer;
    ulong offset;
    ulong total;

@nogc nothrow:
    bool empty() const { return offset >= total; }

    const(ubyte)[] front() {
        immutable n = total - offset < buffer.length ? cast(size_t)(total - offset) : buffer.length;
        foreach (i; 0 .. n) buffer[i] = patternByte(offset + i);
        return buffer[0 .. n];
    }

    void popFront() {
        offset += total - offset < buffer.length ? total - offset : buffer.length;
    }

    PatternChunks save() { return this; }
}

static assert(isChunkRange!PatternChunks);

// ---------------------------------------------------------------------
// Client side: every call into the core is inside @nogc nothrow.
// ---------------------------------------------------------------------

immutable fixedTime = AmzTime.fromUnix(1_440_938_160); // 20150830T123600Z

S3Status openClient(ref S3Client client, scope const(char)[] origin, Credentials credentials,
        char[] work) @nogc nothrow {
    Transport transport;
    auto opened = openCurlTransport(CurlOptions.init, transport);
    if (!opened.ok) return S3Status(FailureKind.transportError, 0, opened.failure);
    S3Config config;
    config.region = "us-east-1";
    config.credentials = credentials;
    config.dispatchOrigin = origin;
    return client.open(config, transport, work);
}

PutResult uploadPattern(ref S3Client client, scope const(char)[] key, PayloadHash hash,
        PutObjectOptions options = PutObjectOptions.init) @nogc nothrow {
    ubyte[smallChunk] buffer = void;
    auto chunks = PatternChunks(buffer[], 0, uploadLength);
    return client.putObject("examplebucket", key, chunks, uploadLength, hash, options, fixedTime);
}

/// Checks a download against the pattern as it arrives; keeps nothing.
struct PatternSink {
    ulong base;      // object offset the first byte should have
    ulong received;
    ulong mismatches;
    size_t calls;

@nogc nothrow:
    bool take(scope const(ubyte)[] chunk) {
        put(chunk);
        return true;
    }

    // Output-range form.
    void put(scope const(ubyte)[] chunk) {
        foreach (i, b; chunk)
            if (b != patternByte(base + received + i)) mismatches++;
        received += chunk.length;
        calls++;
    }
}

GetResult downloadViaDelegate(ref S3Client client, scope const(char)[] key, ByteRange range,
        ref PatternSink sink) @nogc nothrow {
    return client.getObject("examplebucket", key, &sink.take, GetObjectOptions(range), fixedTime);
}

GetResult downloadViaOutputRange(ref S3Client client, scope const(char)[] key, ByteRange range,
        ref PatternSink sink) @nogc nothrow {
    return client.getObject("examplebucket", key, sink, GetObjectOptions(range), fixedTime);
}

GetResult downloadWithEveryOption(ref S3Client client, ref PatternSink sink) @nogc nothrow {
    GetObjectOptions options;
    options.range = ByteRange.bytes(10, 19);
    options.ifMatch = `"pattern-etag"`;
    options.ifNoneMatch = `"some-other-etag"`;
    return client.getObject("examplebucket", "pattern.bin", &sink.take, options, fixedTime);
}

/// Folds listing entries into a few numbers and a bounded text, proving the
/// callback sees every entry without anything being kept per entry.
struct EntryFold {
    ulong count;
    ulong totalSize;
    char[32] firstKey = 0;
    size_t firstKeyLen;
    char[32] lastKey = 0;
    size_t lastKeyLen;
    bool sawEscapedKey;

    bool take(scope ref const S3ObjectView entry) @nogc nothrow {
        if (count == 0) {
            firstKeyLen = entry.key.length;
            firstKey[0 .. firstKeyLen] = entry.key[];
        }
        lastKeyLen = entry.key.length;
        lastKey[0 .. lastKeyLen] = entry.key[];
        if (entry.key == "p/a&b <1>.bin") sawEscapedKey = true;
        totalSize += entry.size;
        count++;
        return true;
    }
}

struct ListOutcome {
    S3Status status;
    uint pages;
    ulong entries;
}

/// Walks a whole listing: the continuation is a value the caller holds and
/// passes back, and the loop is the caller's.
ListOutcome listAll(ref S3Client client, ref EntryFold fold, char[] entryBuffer) @nogc nothrow {
    ListOutcome outcome;
    ListContinuation where;
    ListOptions options;
    options.prefix = "p/";
    options.maxKeys = pageSize;
    while (!where.done) {
        auto page = client.listObjectsV2("examplebucket", options, where, entryBuffer, &fold.take, null, fixedTime);
        outcome.status = page.status;
        if (!page.ok) return outcome;
        outcome.pages++;
        outcome.entries += page.entries;
    }
    return outcome;
}

/// Collects common prefixes into a bounded text.
struct PrefixFold {
    char[96] text = 0;
    size_t len;
    ulong count;

    bool take(scope const(char)[] prefix) @nogc nothrow {
        text[len .. len + prefix.length] = prefix[];
        len += prefix.length;
        text[len++] = '|';
        count++;
        return true;
    }
}

ListPageResult listDelimited(ref S3Client client, ref EntryFold entries, ref PrefixFold prefixes,
        char[] entryBuffer) @nogc nothrow {
    ListContinuation where;
    ListOptions options;
    options.prefix = "p/";
    options.delimiter = "/";
    return client.listObjectsV2("examplebucket", options, where, entryBuffer, &entries.take, &prefixes.take,
        fixedTime);
}

// ---------------------------------------------------------------------
// Server side
// ---------------------------------------------------------------------

enum uint pageSize = 40;
enum uint listedObjects = 100; // three pages: 40, 40, 20
enum ulong downloadLength = 300_000;

/// What the server observed, for the assertions in `main`.
final class Observed {
    string[] putHeads;       // "PUT <target>|<content-length>|<x-amz-content-sha256>|<authorization>"
    ulong[] putBodyBytes;
    ulong[] putMismatches;
    string[] putSha256;
    string[string] optionsPutHeaders; // the request headers of PUT /up/options.bin
    string[string] lastGetHeaders;    // ... and of the latest GET /pattern.bin
    string[] ranges;
    string[] listTargets;
}

string listPage(uint first, uint count, bool truncated, string nextToken) {
    auto xml = `<?xml version="1.0" encoding="UTF-8"?>` ~
        `<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>examplebucket</Name>` ~
        `<Prefix>p/</Prefix><IsTruncated>` ~ (truncated ? "true" : "false") ~ `</IsTruncated>`;
    foreach (i; first .. first + count) {
        // One key needs XML escaping, to exercise in-place decoding.
        auto key = i == 41 ? "p/a&amp;b &lt;1&gt;.bin" : "p/obj-" ~ i.to!string ~ ".bin";
        xml ~= `<Contents><Key>` ~ key ~ `</Key><LastModified>2024-01-02T03:04:05.000Z</LastModified>` ~
            `<ETag>&quot;e` ~ i.to!string ~ `&quot;</ETag><Size>` ~ (i + 1).to!string ~
            `</Size><StorageClass>STANDARD</StorageClass></Contents>`;
    }
    if (truncated) xml ~= `<NextContinuationToken>` ~ nextToken ~ `</NextContinuationToken>`;
    return xml ~ `</ListBucketResult>`;
}

void handle(Observed seen, ref Request request, Connection conn) {
    import std.digest.sha : SHA256, toHexString, LetterCase;

    if (request.method == "PUT") {
        ubyte[4096] buffer;
        ulong offset = 0, mismatches = 0;
        SHA256 hash;
        hash.start();
        size_t n;
        while ((n = conn.readBody(buffer[])) != 0) {
            foreach (i; 0 .. n) if (buffer[i] != patternByte(offset + i)) mismatches++;
            hash.put(buffer[0 .. n]);
            offset += n;
        }
        seen.putHeads ~= "PUT " ~ request.target ~ "|" ~ request.header("content-length") ~ "|" ~
            request.header("x-amz-content-sha256") ~ "|" ~ request.header("authorization");
        seen.putBodyBytes ~= offset;
        seen.putMismatches ~= mismatches;
        seen.putSha256 ~= hash.finish().toHexString!(LetterCase.lower).idup;
        if (request.target == "/up/options.bin") seen.optionsPutHeaders = request.headers.dup;
        conn.respond(200, ["ETag": `"upload-etag"`], null);
        return;
    }

    if (request.target.startsWith("/?")) {
        seen.listTargets ~= request.target;
        string body_;
        if (request.target.canFind("delimiter=%2F"))
            body_ = `<?xml version="1.0" encoding="UTF-8"?><ListBucketResult><Prefix>p/</Prefix>` ~
                `<Delimiter>/</Delimiter><IsTruncated>false</IsTruncated>` ~
                `<Contents><Key>p/top.bin</Key><ETag>&quot;t&quot;</ETag><Size>9</Size></Contents>` ~
                `<CommonPrefixes><Prefix>p/2023/</Prefix></CommonPrefixes>` ~
                `<CommonPrefixes><Prefix>p/a&amp;b/</Prefix></CommonPrefixes>` ~
                `<CommonPrefixes><Prefix>p/2024/</Prefix></CommonPrefixes></ListBucketResult>`;
        else if (request.target.canFind("continuation-token=page%3D3")) body_ = listPage(80, 20, false, null);
        else if (request.target.canFind("continuation-token=page%3D2")) body_ = listPage(40, 40, true, "page=3");
        else body_ = listPage(0, 40, true, "page=2");
        conn.respond(200, ["Content-Type": "application/xml"], body_);
        return;
    }

    if (request.target == "/missing.bin") {
        conn.respond(404, ["Content-Type": "application/xml"],
            `<?xml version="1.0" encoding="UTF-8"?><Error><Code>NoSuchKey</Code>` ~
            `<Message>The specified key does not exist.</Message><Key>missing.bin</Key></Error>`);
        return;
    }

    // GET /pattern.bin, whole or ranged, streamed in small writes.
    ulong first = 0, last = downloadLength - 1;
    auto range = request.header("range");
    seen.ranges ~= range;
    if (request.target == "/pattern.bin") seen.lastGetHeaders = request.headers.dup;
    int status = 200;
    string[string] headers = ["ETag": `"pattern-etag"`, "Content-Type": "application/octet-stream"];
    if (range.length) {
        check(range.startsWith("bytes="), "unexpected Range: " ~ range);
        auto dash = range.indexOf('-');
        first = range[6 .. dash].to!ulong;
        if (dash + 1 < range.length) last = range[dash + 1 .. $].to!ulong;
        status = 206;
        headers["Content-Range"] = "bytes " ~ first.to!string ~ "-" ~ last.to!string ~ "/" ~
            downloadLength.to!string;
    }
    conn.sendHead(status, headers, last - first + 1);
    ubyte[1500] buffer;
    for (ulong at = first; at <= last;) {
        immutable n = last - at + 1 < buffer.length ? cast(size_t)(last - at + 1) : buffer.length;
        foreach (i; 0 .. n) buffer[i] = patternByte(at + i);
        conn.send(buffer[0 .. n]);
        at += n;
    }
}

/// Checks that every header named in a request's `SignedHeaders` arrived
/// with a value, and returns how many there are.
size_t signedHeadersAllSent(string[string] headers) {
    import std.array : split;
    auto authorization = headers.get("authorization", "");
    auto start = authorization.indexOf("SignedHeaders=");
    check(start >= 0, "request is not signed: " ~ authorization);
    auto list = authorization[start + "SignedHeaders=".length .. $];
    auto names = list[0 .. list.indexOf(',')].split(";");
    foreach (name; names)
        check(headers.get(name, "").length > 0, "header '" ~ name ~ "' is signed but was not sent");
    return names.length;
}

void main() {
    writeln("s3lite streaming loopback fixture (issue #607)");

    auto seen = new Observed;
    auto server = new LoopbackServer((ref Request request, Connection conn) { handle(seen, request, conn); });
    auto origin = server.origin;
    auto credentials = Credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");

    // The client's whole working memory: one work buffer and one entry buffer.
    auto work = new char[recommendedWorkBytes];
    auto entryBuffer = new char[512];

    {
        S3Client client;
        auto opened = openClient(client, origin, credentials, work);
        check(opened.ok, "client should open: " ~ opened.message[].idup);

        // The reference digest, computed here only so the server-side hash
        // has something to be compared against.
        SHA256Reference reference;
        auto expectedSha = reference.ofPattern(uploadLength);

        writeln("A. upload from a range of ", uploadChunks, " chunks of ", smallChunk, " bytes...");
        auto unsignedPut = uploadPattern(client, "up/unsigned.bin", PayloadHash.unsigned);
        check(unsignedPut.ok, "unsigned-payload upload failed: " ~ unsignedPut.status.message[].idup);
        check(unsignedPut.etag[] == `"upload-etag"`, "ETag not returned: " ~ unsignedPut.etag[].idup);
        check(unsignedPut.bytesSent == uploadLength, "bytesSent should equal the declared length");

        auto signedPut = uploadPattern(client, "up/signed.bin", PayloadHash.sha256Hex(expectedSha));
        check(signedPut.ok, "supplied-SHA-256 upload failed: " ~ signedPut.status.message[].idup);

        check(seen.putHeads.length == 2, "server should have seen two PUTs");
        foreach (i; 0 .. 2) {
            check(seen.putBodyBytes[i] == uploadLength,
                "server received " ~ seen.putBodyBytes[i].to!string ~ " body bytes");
            check(seen.putMismatches[i] == 0, "uploaded bytes differ from the pattern");
            check(seen.putSha256[i] == expectedSha, "uploaded bytes hash differently");
            check(seen.putHeads[i].canFind("|" ~ uploadLength.to!string ~ "|"),
                "Content-Length should declare the total: " ~ seen.putHeads[i]);
            check(seen.putHeads[i].canFind("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request"),
                "PUT should be signed: " ~ seen.putHeads[i]);
        }
        check(seen.putHeads[0].startsWith("PUT /up/unsigned.bin|") && seen.putHeads[0].canFind("|UNSIGNED-PAYLOAD|"),
            "unsigned policy should send UNSIGNED-PAYLOAD: " ~ seen.putHeads[0]);
        check(seen.putHeads[1].canFind("|" ~ expectedSha ~ "|"),
            "supplied policy should send the caller's digest: " ~ seen.putHeads[1]);
        writeln("   PASS: ", uploadLength, " bytes arrived intact twice, Content-Length declared up front, ",
            "UNSIGNED-PAYLOAD and caller-supplied SHA-256 policies both on the wire");

        // Upload options: each becomes a header, and each header is signed.
        static immutable MetadataPair[2] metadata = [MetadataPair("Owner", "streaming fixture"),
            MetadataPair("batch-id", "607")];
        PutObjectOptions putOptions;
        putOptions.contentType = "text/plain; charset=utf-8";
        putOptions.storageClass = "STANDARD_IA";
        putOptions.contentMd5 = "DA7ZlRH1pbZ3bkrR3F5vrA=="; // the server does not verify it
        putOptions.checksumAlgorithm = ChecksumAlgorithm.crc32c;
        putOptions.checksumValue = "yZRlqg==";
        putOptions.metadata = metadata[];
        auto optionsPut = uploadPattern(client, "up/options.bin", PayloadHash.unsigned, putOptions);
        check(optionsPut.ok, "upload with options failed: " ~ optionsPut.status.message[].idup);
        auto sentHeaders = seen.optionsPutHeaders;
        check(sentHeaders.get("content-type", "") == "text/plain; charset=utf-8" &&
            sentHeaders.get("content-md5", "") == "DA7ZlRH1pbZ3bkrR3F5vrA==" &&
            sentHeaders.get("x-amz-storage-class", "") == "STANDARD_IA" &&
            sentHeaders.get("x-amz-checksum-crc32c", "") == "yZRlqg==" &&
            sentHeaders.get("x-amz-meta-owner", "") == "streaming fixture" &&
            sentHeaders.get("x-amz-meta-batch-id", "") == "607",
            "upload options not on the wire: " ~ sentHeaders.to!string);
        // Expected value derived with a separate implementation (Python's
        // hashlib/hmac) from this request's method, path, headers, fixed
        // time and example credentials -- not produced by this package.
        check(sentHeaders.get("authorization", "") ==
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request, " ~
            "SignedHeaders=content-md5;content-type;host;x-amz-checksum-crc32c;x-amz-content-sha256;" ~
            "x-amz-date;x-amz-meta-batch-id;x-amz-meta-owner;x-amz-storage-class, " ~
            "Signature=fae91e21f8ed879e1cfe57eeabb5617382e9b34006a815ef2aafc54db326d3ac",
            "signature over the option headers differs from the independent one: " ~
            sentHeaders.get("authorization", ""));
        // Every option is set on that upload: each header the signature
        // names must be on the wire, or the server could not verify it.
        check(signedHeadersAllSent(sentHeaders) == 9, "the upload should sign nine headers");
        writeln("   PASS: with every upload option set, all nine signed headers are on the wire; ",
            "signature matches an independently derived one");

        // A zero-length object: declared, sent and received as such.
        ubyte[smallChunk] unused = void;
        auto nothing = PatternChunks(unused[], 0, 0);
        auto emptyPut = client.putObject("examplebucket", "up/empty.bin", nothing, 0,
            PayloadHash.unsigned, PutObjectOptions.init, fixedTime);
        check(emptyPut.ok && emptyPut.bytesSent == 0, "empty upload failed");
        check(seen.putHeads.length == 4 && seen.putHeads[3].startsWith("PUT /up/empty.bin|0|") &&
            seen.putBodyBytes[3] == 0, "empty upload should declare and send zero bytes");

        writeln("B. download into a sink...");
        PatternSink whole;
        auto got = downloadViaDelegate(client, "pattern.bin", ByteRange.whole, whole);
        check(got.ok, "whole download failed: " ~ got.status.message[].idup);
        check(whole.received == downloadLength && whole.mismatches == 0, "whole download content is wrong");
        check(got.bytesDelivered == downloadLength && !got.partial, "whole download should be a 200");
        check(got.hasTotalSize && got.totalSize == downloadLength, "total size should come from Content-Length");
        check(got.etag[] == `"pattern-etag"` && got.contentType[] == "application/octet-stream",
            "response headers not captured");
        check(whole.calls > 1, "the body should arrive in more than one piece");

        PatternSink ranged;
        ranged.base = 123_456;
        auto part = downloadViaOutputRange(client, "pattern.bin", ByteRange.bytes(123_456, 223_455), ranged);
        check(part.ok, "ranged download failed: " ~ part.status.message[].idup);
        check(ranged.received == 100_000 && ranged.mismatches == 0, "ranged download content is wrong");
        check(part.partial && part.hasContentLength && part.contentLength == 100_000, "ranged download should be a 206");
        check(part.hasTotalSize && part.totalSize == downloadLength, "total size should come from Content-Range");

        PatternSink tail;
        tail.base = downloadLength - 4096;
        auto resumed = downloadViaDelegate(client, "pattern.bin", ByteRange.from(downloadLength - 4096), tail);
        check(resumed.ok && tail.received == 4096 && tail.mismatches == 0, "open-ended range is wrong");

        // Every download option at once: range and both conditions.
        PatternSink conditional;
        conditional.base = 10;
        auto conditionalGet = downloadWithEveryOption(client, conditional);
        check(conditionalGet.ok && conditional.received == 10 && conditional.mismatches == 0,
            "download with every option failed: " ~ conditionalGet.status.message[].idup);
        check(seen.lastGetHeaders.get("if-match", "") == `"pattern-etag"` &&
            seen.lastGetHeaders.get("if-none-match", "") == `"some-other-etag"` &&
            seen.lastGetHeaders.get("range", "") == "bytes=10-19", "download options not on the wire");
        check(signedHeadersAllSent(seen.lastGetHeaders) == 6, "the download should sign six headers");
        seen.ranges = seen.ranges[0 .. $ - 1]; // not one of the three range cases checked below
        check(seen.ranges == ["", "bytes=123456-223455", "bytes=" ~ (downloadLength - 4096).to!string ~ "-"],
            "Range headers on the wire: " ~ seen.ranges.to!string);

        PatternSink untouched;
        auto missing = downloadViaDelegate(client, "missing.bin", ByteRange.whole, untouched);
        check(!missing.ok && missing.status.kind == FailureKind.notFound, "404 should be typed notFound");
        check(missing.status.code[] == "NoSuchKey" && missing.status.httpStatus == 404, "S3 error code not parsed");
        check(untouched.received == 0, "an error body must not reach the sink");
        writeln("   PASS: whole object (", whole.calls, " sink calls), bytes=123456-223455 via an output range, ",
            "an open-ended range, and a typed NoSuchKey that never touched the sink");

        writeln("C. listing across pages through the callback...");
        EntryFold fold;
        auto listed = listAll(client, fold, entryBuffer);
        check(listed.status.ok, "listing failed: " ~ listed.status.message[].idup);
        check(listed.pages == 3 && listed.entries == listedObjects && fold.count == listedObjects,
            "expected 100 entries over 3 pages, got " ~ fold.count.to!string ~ " over " ~ listed.pages.to!string);
        check(fold.totalSize == listedObjects * (listedObjects + 1) / 2, "entry sizes not all delivered");
        check(fold.firstKey[0 .. fold.firstKeyLen] == "p/obj-0.bin" && fold.lastKey[0 .. fold.lastKeyLen] == "p/obj-99.bin",
            "entries out of order");
        check(fold.sawEscapedKey, "an escaped key should be decoded for the callback");
        check(seen.listTargets.length == 3, "expected three listing requests");
        check(!seen.listTargets[0].canFind("continuation-token"), "first page must not send a token");
        check(seen.listTargets[1].canFind("continuation-token=page%3D2") &&
            seen.listTargets[2].canFind("continuation-token=page%3D3"), "tokens should drive pages 2 and 3");
        check(seen.listTargets[0].canFind("max-keys=40") && seen.listTargets[0].canFind("prefix=p%2F"),
            "listing options not on the wire: " ~ seen.listTargets[0]);

        EntryFold topLevel;
        PrefixFold prefixes;
        auto delimited = listDelimited(client, topLevel, prefixes, entryBuffer);
        check(delimited.ok, "delimited listing failed: " ~ delimited.status.message[].idup);
        check(delimited.entries == 1 && topLevel.count == 1 && topLevel.lastKey[0 .. topLevel.lastKeyLen] == "p/top.bin",
            "delimited listing should deliver its one object");
        check(delimited.prefixes == 3 && prefixes.text[0 .. prefixes.len] == "p/2023/|p/a&b/|p/2024/|",
            "common prefixes not delivered in order: " ~ prefixes.text[0 .. prefixes.len].idup);
        writeln("   PASS: ", fold.count, " entries over ", listed.pages, " pages through a ", entryBuffer.length,
            "-byte entry buffer (pages are ~", listPage(0, 40, true, "page=2").length, " bytes); ",
            delimited.prefixes, " common prefixes through their own callback");
    }

    auto failures = server.stop();
    check(failures.length == 0, "server-side failure: " ~ failures.to!string);

    writeln("D. connection reuse...");
    check(server.connectionsAccepted == 1,
        "one client should use one connection, server accepted " ~ server.connectionsAccepted.to!string);
    writeln("   PASS: every request above went over 1 TCP connection");

    checkConvenienceRangeUpload();

    writeln("s3lite streaming loopback fixture: PASS (all core calls made from @nogc nothrow functions)");
}

/// E. The convenience layer accepts ranges the core's `@nogc nothrow` form
/// cannot: here one whose every chunk is a fresh allocation, and one that
/// throws. Neither is gathered into a buffer first.
void checkConvenienceRangeUpload() {
    import s3lite.http : GetOptions;
    import std.algorithm.iteration : map;
    import std.range : iota;

    writeln("E. convenience-layer upload from an allocating range, and from one that throws...");

    static ubyte[] allocatedChunk(ulong index) {
        auto chunk = new ubyte[smallChunk];
        foreach (i, ref b; chunk) b = patternByte(index * smallChunk + i);
        return chunk;
    }

    auto seen = new Observed;
    auto server = new LoopbackServer((ref Request request, Connection conn) { handle(seen, request, conn); });
    GetOptions options;
    options.urlOverride = server.origin;
    auto request = convenience.PutObjectRequest("examplebucket", "up/allocating.bin", "us-east-1",
        Credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"), null, "s3", options);

    enum ulong chunks = 500;
    auto put = convenience.putObject(request, iota(chunks).map!allocatedChunk, chunks * smallChunk,
        PayloadHash.unsigned);
    check(put.ok, "allocating-range upload failed: " ~ put.error.message);
    check(put.etag == `"upload-etag"`, "ETag not returned");
    auto failures = server.stop();
    check(failures.length == 0, "server-side failure: " ~ failures.to!string);
    check(seen.putBodyBytes == [chunks * smallChunk] && seen.putMismatches == [0UL],
        "allocating-range upload arrived wrong");

    // A range that throws after 100 chunks: the upload stops, the result
    // says why, and no exception crosses the transport.
    auto broken = new LoopbackServer((ref Request request, Connection conn) { handle(seen, request, conn); });
    options.urlOverride = broken.origin;
    request.transport = options;
    auto throwing = iota(chunks).map!((ulong i) {
        if (i == 100) throw new Exception("disk read failed");
        return allocatedChunk(i);
    });
    auto failed = convenience.putObject(request, throwing, chunks * smallChunk, PayloadHash.unsigned);
    check(!failed.ok && failed.error.kind == FailureKind.aborted,
        "a throwing range should abort the upload, got " ~ failed.error.kind.to!string);
    check(failed.error.message == "body range threw: disk read failed", "unexpected message: " ~ failed.error.message);
    // The server may or may not have seen part of the request before the
    // connection dropped; what matters is that it never saw a whole one.
    broken.stop();
    check(seen.putHeads.length == 1, "an aborted upload must not complete");

    writeln("   PASS: ", chunks, " freshly allocated chunks uploaded intact; a throwing range is a typed 'aborted'");
}

/// SHA-256 of the first `length` bytes of the pattern, computed in small
/// pieces.
struct SHA256Reference {
    string ofPattern(ulong length) {
        import std.digest.sha : SHA256, toHexString, LetterCase;
        SHA256 hash;
        hash.start();
        ubyte[4096] buffer;
        for (ulong at = 0; at < length;) {
            immutable n = length - at < buffer.length ? cast(size_t)(length - at) : buffer.length;
            foreach (i; 0 .. n) buffer[i] = patternByte(at + i);
            hash.put(buffer[0 .. n]);
            at += n;
        }
        return hash.finish().toHexString!(LetterCase.lower).idup;
    }
}
