/// Loopback proof for the libcurl transport itself (issue #607 review):
/// what a reused easy handle does after an exchange goes wrong, and that
/// the request on the wire is the request that was described.
///
///   A. A reused connection that the server resets mid-upload.
///      With a single-pass body the upload fails as "not rewindable" --
///      and the same client then completes a download and a listing. (The
///      handle used to keep callback pointers into the failed call's dead
///      stack frame.) No more of the body is taken once the rewind has
///      failed.
///      With a rewindable body the transport rewinds once, resends on a
///      new connection, and the server receives exactly the object -- which
///      also proves the partly-sent chunk in hand was discarded.
///      A third sequence has the server refuse the upload part-way (an
///      early 403 and a closed connection) and then uses the client again.
///   B. Keys with "." and ".." segments reach the server byte for byte as
///      they were signed, not collapsed.
///   C. The transport sends the call's method: HEAD and DELETE.
///   D. A sink that stops a download: typed `aborted`, and the client
///      carries on.
///
/// All client calls are made from `@nogc nothrow` functions. No network
/// access beyond 127.0.0.1. Run via:
/// `dub run --config=transport-loopback-fixture` (from this package's own
/// directory).
import loopback_server;
import s3lite.core;
import s3lite.curl_transport : CurlOptions, openCurlTransport;
import s3lite.transport : HttpCall, HttpHeader, HttpMethod, TransportResult;
import std.algorithm.searching : canFind, startsWith;
import std.conv : to;
import std.stdio : writeln;

void check(bool condition, lazy string label) {
    if (!condition) throw new Exception("FAIL: " ~ label);
}

ubyte patternByte(ulong offset) @nogc nothrow pure {
    return cast(ubyte)((offset * 131 + (offset >> 9) * 17 + 5) & 0xff);
}

// Far more than the loopback socket buffers can absorb, so the client is
// still sending when the server hangs up.
enum ulong uploadLength = 48 * 1024 * 1024 + 4321;
// Larger than libcurl's upload buffer and not a multiple of it, so at any
// moment the transport is part-way through a chunk.
enum size_t chunkBytes = 100_003;
enum ulong downloadLength = 200_000;

/// An upload body in pull form. `rewindable` decides whether it can be
/// read a second time; `rewinds` counts how often it was.
struct PatternBody {
    ubyte[] buffer;
    ulong total;
    bool rewindable;
    ulong offset;
    int rewinds;

@nogc nothrow:
    bool pull(ref const(ubyte)[] chunk) {
        immutable n = total - offset < buffer.length ? cast(size_t)(total - offset) : buffer.length;
        foreach (i; 0 .. n) buffer[i] = patternByte(offset + i);
        chunk = buffer[0 .. n];
        offset += n;
        return true;
    }

    bool rewind() {
        offset = 0;
        rewinds++;
        return true;
    }

    BodySource source() return {
        return BodySource(total, &pull, rewindable ? &rewind : null);
    }
}

struct Sink {
    ulong received;
    ulong mismatches;
    ulong stopAfter = ulong.max;

    bool take(scope const(ubyte)[] chunk) @nogc nothrow {
        if (received + chunk.length > stopAfter) return false;
        foreach (i, b; chunk) if (b != patternByte(received + i)) mismatches++;
        received += chunk.length;
        return true;
    }
}

struct KeyCount {
    ulong count;
    bool take(scope ref const S3ObjectView entry) @nogc nothrow { count++; return true; }
}

immutable fixedTime = AmzTime.fromUnix(1_440_938_160);

S3Status openClient(ref S3Client client, scope const(char)[] origin, char[] work) @nogc nothrow {
    Transport transport;
    auto opened = openCurlTransport(CurlOptions.init, transport);
    if (!opened.ok) return S3Status(FailureKind.transportError);
    S3Config config;
    config.region = "us-east-1";
    config.credentials = Credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");
    config.dispatchOrigin = origin;
    return client.open(config, transport, work);
}

GetResult download(ref S3Client client, scope const(char)[] key, ref Sink sink) @nogc nothrow {
    return client.getObject("examplebucket", key, &sink.take, GetObjectOptions.init, fixedTime);
}

PutResult upload(ref S3Client client, ref PatternBody body_) @nogc nothrow {
    return client.putObject("examplebucket", "up/object.bin", body_.source, PayloadHash.unsigned,
        PutObjectOptions.init, fixedTime);
}

ListPageResult listOnce(ref S3Client client, ref KeyCount keys, char[] entryBuffer) @nogc nothrow {
    ListContinuation where;
    return client.listObjectsV2("examplebucket", ListOptions.init, where, entryBuffer, &keys.take, null, fixedTime);
}

/// One bodiless exchange straight through a transport, recording the
/// response.
struct Probe {
    int status;
    ulong bodyBytes;
    char[64] marker = 0;
    size_t markerLen;

@nogc nothrow:
    void onHeader(int status, scope const(char)[] name, scope const(char)[] value) {
        if (name == "X-Marker" && value.length <= marker.length) {
            marker[0 .. value.length] = value[];
            markerLen = value.length;
        }
    }

    bool onBody(int status, scope const(ubyte)[] chunk) {
        bodyBytes += chunk.length;
        return true;
    }

    TransportResult run(ref Transport transport, HttpMethod method, scope const(char)[] url) {
        static immutable HttpHeader[1] headers = [HttpHeader("X-Probe", "1")];
        HttpCall call;
        call.method = method;
        call.url = url;
        call.headers = headers[];
        call.onHeader = &onHeader;
        call.onBody = &onBody;
        auto result = transport.perform(call);
        status = result.status;
        return result;
    }
}

struct MethodProbe {
    TransportResult head, delete_, get;
    Probe headProbe, deleteProbe, getProbe;
}

/// HEAD, DELETE, then GET on one handle: each verb is the call's own and
/// none leaks into the next.
MethodProbe probeMethods(scope const(char)[] url) @nogc nothrow {
    MethodProbe p;
    Transport transport;
    if (!openCurlTransport(CurlOptions.init, transport).ok) return p;
    scope(exit) transport.close();
    p.head = p.headProbe.run(transport, HttpMethod.head, url);
    p.delete_ = p.deleteProbe.run(transport, HttpMethod.delete_, url);
    p.get = p.getProbe.run(transport, HttpMethod.get, url);
    return p;
}

// ---------------------------------------------------------------------

/// What the server saw. Guarded by the fact that each fixture section
/// drives one client, one request at a time.
final class Observed {
    string[] requests;      // "<connection id> <METHOD> <target>"
    int putsToDrop;
    int putsToRefuseEarly;
    ulong[] putBytes;       // body bytes of each PUT read to completion
    ulong[] putMismatches;
}

void handle(Observed seen, ref Request request, Connection conn) {
    seen.requests ~= conn.id.to!string ~ " " ~ request.method ~ " " ~ request.target;

    if (request.method == "PUT") {
        ubyte[8192] buffer;
        if (seen.putsToDrop > 0) {
            seen.putsToDrop--;
            // Take part of the body, then fail the connection under the
            // client without answering.
            size_t taken = 0;
            while (taken < 300_000) taken += conn.readBody(buffer[]);
            conn.reset();
        }
        if (seen.putsToRefuseEarly > 0) {
            seen.putsToRefuseEarly--;
            // Answer before the body is in, then hang up: the client is
            // left with an upload it stopped part-way.
            size_t taken = 0;
            while (taken < 300_000) taken += conn.readBody(buffer[]);
            conn.respond(403, ["Content-Type": "application/xml", "Connection": "close"],
                `<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>`);
            conn.closeAfterResponse();
        }
        ulong offset = 0, bad = 0;
        size_t n;
        while ((n = conn.readBody(buffer[])) != 0) {
            foreach (i; 0 .. n) if (buffer[i] != patternByte(offset + i)) bad++;
            offset += n;
        }
        seen.putBytes ~= offset;
        seen.putMismatches ~= bad;
        conn.respond(200, ["ETag": `"put-etag"`], null);
    } else if (request.method == "HEAD") {
        // Declares a length and, as HEAD requires, sends no body.
        conn.sendHead(200, ["X-Marker": "head-seen"], 12_345);
    } else if (request.method == "DELETE") {
        conn.respond(204, ["X-Marker": "delete-seen"], null);
    } else if (request.target.startsWith("/?")) {
        conn.respond(200, ["Content-Type": "application/xml"],
            `<ListBucketResult><IsTruncated>false</IsTruncated>` ~
            `<Contents><Key>one</Key><Size>1</Size></Contents>` ~
            `<Contents><Key>two</Key><Size>2</Size></Contents></ListBucketResult>`);
    } else if (request.target == "/probe") {
        conn.respond(200, ["X-Marker": "get-seen"], "probe-body");
    } else {
        conn.sendHead(200, ["ETag": `"get-etag"`], downloadLength);
        ubyte[4096] buffer;
        for (ulong at = 0; at < downloadLength;) {
            immutable n = downloadLength - at < buffer.length ? cast(size_t)(downloadLength - at) : buffer.length;
            foreach (i; 0 .. n) buffer[i] = patternByte(at + i);
            conn.send(buffer[0 .. n]);
            at += n;
        }
    }
}

/// A. `rewindable` selects which of the two sequences runs.
void checkDroppedReusedConnection(bool rewindable) {
    writeln(rewindable
        ? "A2. reused connection dropped mid-upload, rewindable body..."
        : "A1. reused connection dropped mid-upload, single-pass body...");

    auto seen = new Observed;
    auto server = new LoopbackServer((ref Request request, Connection conn) { handle(seen, request, conn); });
    // libcurl retries a request on a reused connection only if it has heard
    // nothing back at all, so the server must not answer the upload's
    // `Expect: 100-continue` either.
    server.answerExpect = false;
    auto work = new char[recommendedWorkBytes];
    auto entryBuffer = new char[recommendedListEntryBuffer];
    auto chunkBuffer = new ubyte[chunkBytes];
    {
        S3Client client;
        check(openClient(client, server.origin, work).ok, "client should open");

        // Warm the connection, so the upload goes out on a reused one.
        Sink warm;
        check(download(client, "warm.bin", warm).ok && warm.received == downloadLength && warm.mismatches == 0,
            "warming download failed");

        seen.putsToDrop = 1;
        auto body_ = PatternBody(chunkBuffer, uploadLength, rewindable);
        auto put = upload(client, body_);

        if (rewindable) {
            check(put.ok, "a rewindable body should survive the dropped connection: " ~
                put.status.transport.to!string ~ " " ~ put.status.message[].idup);
            check(body_.rewinds == 1, "expected exactly one rewind, saw " ~ body_.rewinds.to!string);
            check(seen.putBytes == [uploadLength] && seen.putMismatches == [0UL],
                "the resent body should arrive whole and intact, got " ~ seen.putBytes.to!string ~
                " bytes with " ~ seen.putMismatches.to!string ~ " mismatches");
            check(put.etag[] == `"put-etag"`, "ETag not returned");
        } else {
            check(!put.ok, "a single-pass body cannot survive the dropped connection");
            check(put.status.kind == FailureKind.transportError &&
                put.status.transport == TransportFailure.bodyNotRewindable,
                "expected bodyNotRewindable, got " ~ put.status.kind.to!string ~ "/" ~
                put.status.transport.to!string ~ " (" ~ put.status.message[].idup ~ ")");
            check(seen.putBytes.length == 0, "no upload should have completed");
            check(put.bytesSent > 0 && put.bytesSent < uploadLength,
                "the connection should have failed mid-body, after " ~ put.bytesSent.to!string ~ " bytes");
        }

        // The same client, the same handle: nothing of the failed exchange
        // may still be registered on it.
        Sink after;
        auto got = download(client, "after.bin", after);
        check(got.ok && after.received == downloadLength && after.mismatches == 0,
            "download after the dropped upload failed: " ~ got.status.transport.to!string ~ " " ~
            got.status.message[].idup);
        KeyCount keys;
        auto listed = listOnce(client, keys, entryBuffer);
        check(listed.ok && keys.count == 2, "listing after the dropped upload failed: " ~
            listed.status.message[].idup);
        Sink again;
        check(download(client, "again.bin", again).ok && again.mismatches == 0, "second download failed");
    }
    auto failures = server.stop();
    check(seen.requests[0] == "1 GET /warm.bin" && seen.requests[1] == "1 PUT /up/object.bin",
        "the upload should have gone out on the warmed connection: " ~ seen.requests.to!string);
    if (rewindable) {
        check(failures.length == 0, "server-side failure: " ~ failures.to!string);
        check(server.connectionsAccepted == 2, "expected the dropped connection and one replacement, saw " ~
            server.connectionsAccepted.to!string);
        check(seen.requests[2] == "2 PUT /up/object.bin", "the resend should be the next request: " ~
            seen.requests.to!string);
    } else {
        // libcurl may already have opened the replacement connection and
        // sent the request head on it before finding the body cannot be
        // rewound; the server then sees that connection abandoned mid-body.
        foreach (failure; failures)
            check(failure == "client closed the connection mid-body", "server-side failure: " ~ failure);
        check(server.connectionsAccepted >= 2, "the dropped connection must have been replaced");
    }

    writeln(rewindable
        ? "   PASS: one rewind, " ~ uploadLength.to!string ~ " bytes resent intact on a new connection; GET, list, GET then succeed"
        : "   PASS: upload fails as bodyNotRewindable; GET, list and GET on the same client then succeed");
}

/// A3. The server refuses an upload before the body is in.
void checkEarlyRefusal() {
    writeln("A3. upload refused part-way with a single-pass body...");

    auto seen = new Observed;
    auto server = new LoopbackServer((ref Request request, Connection conn) { handle(seen, request, conn); });
    server.answerExpect = false;
    auto work = new char[recommendedWorkBytes];
    auto entryBuffer = new char[recommendedListEntryBuffer];
    auto chunkBuffer = new ubyte[chunkBytes];
    {
        S3Client client;
        check(openClient(client, server.origin, work).ok, "client should open");
        Sink warm;
        check(download(client, "warm.bin", warm).ok, "warming download failed");

        seen.putsToRefuseEarly = 1;
        auto body_ = PatternBody(chunkBuffer, uploadLength, false);
        auto put = upload(client, body_);
        check(!put.ok && put.status.kind == FailureKind.forbidden && put.status.code[] == "AccessDenied",
            "expected the server's AccessDenied, got " ~ put.status.kind.to!string ~ "/" ~
            put.status.transport.to!string ~ " (" ~ put.status.message[].idup ~ ")");
        check(put.bytesSent < uploadLength, "the upload should have stopped part-way");

        // libcurl now holds an upload it abandoned; the next exchange on
        // the handle must not reach back into it.
        Sink after;
        check(download(client, "after.bin", after).ok && after.received == downloadLength && after.mismatches == 0,
            "download after the refused upload failed");
        KeyCount keys;
        check(listOnce(client, keys, entryBuffer).ok && keys.count == 2, "listing after the refused upload failed");
    }
    auto failures = server.stop();
    check(failures.length == 0, "server-side failure: " ~ failures.to!string);

    writeln("   PASS: typed AccessDenied with the upload stopped part-way; GET and list on the same client then succeed");
}

/// B. The request target is the signed path, byte for byte.
void checkPathSentAsSigned() {
    writeln("B. keys with '.' and '..' segments are sent as signed...");

    auto seen = new Observed;
    auto server = new LoopbackServer((ref Request request, Connection conn) { handle(seen, request, conn); });
    auto work = new char[recommendedWorkBytes];
    immutable keys = ["a/../b", "../x", "./x", "a/./b", "..", ".", "x/..", "a/b/../../c d"];
    // What SigV4 signs for each: the key with each segment URI-encoded and
    // nothing removed.
    immutable signedPaths = ["/a/../b", "/../x", "/./x", "/a/./b", "/..", "/.", "/x/..", "/a/b/../../c%20d"];
    {
        S3Client client;
        check(openClient(client, server.origin, work).ok, "client should open");
        foreach (key; keys) {
            Sink sink;
            check(download(client, key, sink).ok, "download of key '" ~ key ~ "' failed");
        }
    }
    auto failures = server.stop();
    check(failures.length == 0, "server-side failure: " ~ failures.to!string);
    check(seen.requests.length == keys.length, "expected one request per key");
    foreach (i, key; keys)
        check(seen.requests[i] == "1 GET " ~ signedPaths[i],
            "key '" ~ key ~ "' was sent as '" ~ seen.requests[i] ~ "', signed as '" ~ signedPaths[i] ~ "'");

    writeln("   PASS: ", keys.length, " keys, each request target identical to its signed path");
}

/// C. HEAD and DELETE through the transport.
void checkMethods() {
    writeln("C. the transport sends the call's method...");

    auto seen = new Observed;
    auto server = new LoopbackServer((ref Request request, Connection conn) { handle(seen, request, conn); });
    auto url = server.origin ~ "/probe";
    auto p = probeMethods(url);
    auto failures = server.stop();
    check(failures.length == 0, "server-side failure: " ~ failures.to!string);

    check(seen.requests == ["1 HEAD /probe", "1 DELETE /probe", "1 GET /probe"],
        "methods on the wire: " ~ seen.requests.to!string);
    check(p.head.ok && p.headProbe.status == 200 && p.headProbe.bodyBytes == 0 &&
        p.headProbe.marker[0 .. p.headProbe.markerLen] == "head-seen",
        "HEAD should return headers and no body");
    check(p.delete_.ok && p.deleteProbe.status == 204 &&
        p.deleteProbe.marker[0 .. p.deleteProbe.markerLen] == "delete-seen", "DELETE should return 204");
    check(p.get.ok && p.getProbe.status == 200 && p.getProbe.bodyBytes == "probe-body".length,
        "a GET after HEAD and DELETE should be a plain GET with its body");

    writeln("   PASS: HEAD (headers, no body), DELETE (204) and GET in turn over one connection");
}

/// D. A sink that says stop.
void checkSinkAbort() {
    writeln("D. a sink stops a download...");

    auto seen = new Observed;
    auto server = new LoopbackServer((ref Request request, Connection conn) {
        // The client hangs up part-way through the first response; that is
        // the point, not a server failure.
        try handle(seen, request, conn);
        catch (ConnectionDropped e) throw e;
        catch (Exception) conn.drop();
    });
    auto work = new char[recommendedWorkBytes];
    {
        S3Client client;
        check(openClient(client, server.origin, work).ok, "client should open");

        Sink stops;
        stops.stopAfter = 20_000;
        auto stopped = download(client, "stop.bin", stops);
        check(!stopped.ok && stopped.status.kind == FailureKind.aborted &&
            stopped.status.transport == TransportFailure.aborted,
            "expected aborted, got " ~ stopped.status.kind.to!string ~ "/" ~ stopped.status.transport.to!string);
        check(stops.received <= 20_000 && stopped.bytesDelivered == stops.received && stops.mismatches == 0,
            "the sink should have received only what it accepted");
        check(stopped.etag[] == `"get-etag"`, "headers of the interrupted response should be reported");

        Sink whole;
        check(download(client, "whole.bin", whole).ok && whole.received == downloadLength && whole.mismatches == 0,
            "the client should carry on after an aborted download");
    }
    server.stop();

    writeln("   PASS: typed 'aborted' with the bytes accepted so far; the next download on the same client succeeds");
}

void main() {
    writeln("s3lite transport loopback fixture (issue #607 review)");
    checkDroppedReusedConnection(false);
    checkDroppedReusedConnection(true);
    checkEarlyRefusal();
    checkPathSentAsSigned();
    checkMethods();
    checkSinkAbort();
    writeln("s3lite transport loopback fixture: PASS");
}
