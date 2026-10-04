/// Peak-memory proof for the streaming core (issue #607): an object far
/// larger than any buffer the client holds is uploaded and downloaded, and
/// the process's peak resident memory does not grow with the object.
///
/// The object is a deterministic 64-bit word pattern. The client generates
/// it into one 64 KiB chunk buffer as the transport asks for data and
/// checks it as it arrives in the sink; the loopback server checks the
/// upload and generates the download the same way. Neither side ever holds
/// the object, so the whole process's peak RSS is a fair measure.
///
/// The round trip runs twice in one process: first a small object, then a
/// large one (by default larger than 4 GiB, so every length on the path is
/// exercised past 32 bits). `ru_maxrss` is a high-water mark, so its value
/// after the second run minus its value after the first is exactly what
/// the larger object added. The fixture fails if that exceeds
/// `allowedGrowthBytes`.
///
/// All client calls are made from `@nogc nothrow` functions.
///
/// Run via: `dub run --config=large-object-memory-fixture` (from this
/// package's own directory). Optional arguments: small and large object
/// sizes in MiB, e.g. `-- 64 8192`.
import loopback_server;
import s3lite.core;
import s3lite.curl_transport : CurlOptions, openCurlTransport;
import std.conv : to;
import std.stdio : writefln, writeln;

void check(bool condition, lazy string label) {
    if (!condition) throw new Exception("FAIL: " ~ label);
}

enum size_t chunkBytes = 64 * 1024;
enum ulong allowedGrowthBytes = 8 * 1024 * 1024;

ulong patternWord(ulong index) @nogc nothrow pure {
    return index * 0x9E37_79B9_7F4A_7C15UL + 0x0123_4567_89AB_CDEFUL;
}

/// Fills `buffer` with the pattern for object offset `offset` (a multiple
/// of 8; `buffer.length` likewise, except possibly at the object's end).
void fillPattern(ubyte[] buffer, ulong offset) @nogc nothrow {
    size_t i = 0;
    for (; i + 8 <= buffer.length; i += 8) {
        immutable w = patternWord((offset + i) / 8);
        *cast(ulong*)(buffer.ptr + i) = w;
    }
    for (; i < buffer.length; i++)
        buffer[i] = cast(ubyte)(patternWord((offset + i) / 8) >> (8 * ((offset + i) % 8)));
}

/// Counts bytes of `chunk` that differ from the pattern at `offset`.
ulong countMismatches(scope const(ubyte)[] chunk, ulong offset) @nogc nothrow {
    ulong bad = 0;
    size_t i = 0;
    // Bytes up to the next word boundary, whole words, then the tail.
    for (; i < chunk.length && (offset + i) % 8 != 0; i++)
        if (chunk[i] != cast(ubyte)(patternWord((offset + i) / 8) >> (8 * ((offset + i) % 8)))) bad++;
    for (; i + 8 <= chunk.length; i += 8) {
        ulong got = void;
        import core.stdc.string : memcpy;
        memcpy(&got, chunk.ptr + i, 8);
        if (got != patternWord((offset + i) / 8)) bad += 8;
    }
    for (; i < chunk.length; i++)
        if (chunk[i] != cast(ubyte)(patternWord((offset + i) / 8) >> (8 * ((offset + i) % 8)))) bad++;
    return bad;
}

/// The upload body: a forward range of chunks generated on demand into one
/// buffer.
struct PatternChunks {
    ubyte[] buffer;
    ulong offset;
    ulong total;

@nogc nothrow:
    bool empty() const { return offset >= total; }
    private size_t length() const {
        return total - offset < buffer.length ? cast(size_t)(total - offset) : buffer.length;
    }
    const(ubyte)[] front() {
        fillPattern(buffer[0 .. length], offset);
        return buffer[0 .. length];
    }
    void popFront() { offset += length; }
    PatternChunks save() { return this; }
}

/// The download sink: verifies and counts, keeps nothing.
struct VerifySink {
    ulong received;
    ulong mismatches;

    bool take(scope const(ubyte)[] chunk) @nogc nothrow {
        mismatches += countMismatches(chunk, received);
        received += chunk.length;
        return true;
    }
}

struct RoundTrip {
    PutResult put;
    GetResult get;
    VerifySink sink;
}

/// The whole client side of one round trip. `chunkBuffer` and the client's
/// work buffer are the only memory it uses.
RoundTrip roundTrip(ref S3Client client, ulong size, ubyte[] chunkBuffer) @nogc nothrow {
    RoundTrip result;
    auto chunks = PatternChunks(chunkBuffer, 0, size);
    result.put = client.putObject("examplebucket", "big/object.bin", chunks, size, PayloadHash.unsigned);
    if (!result.put.ok) return result;
    result.get = client.getObject("examplebucket", "big/object.bin", ByteRange.whole, &result.sink.take);
    return result;
}

S3Status openClient(ref S3Client client, scope const(char)[] origin, char[] work) @nogc nothrow {
    Transport transport;
    auto opened = openCurlTransport(CurlOptions.init, transport);
    if (!opened.ok) {
        S3Status status;
        status.kind = FailureKind.transportError;
        status.transport = opened.failure;
        return status;
    }
    S3Config config;
    config.region = "us-east-1";
    config.credentials = Credentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");
    config.dispatchOrigin = origin;
    return client.open(config, transport, work);
}

/// Peak resident set size of this process, in bytes.
ulong peakRssBytes() {
    import core.sys.posix.sys.resource : RUSAGE_SELF, getrusage, rusage;
    rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    // druntime exposes Darwin's fields after the two timevals as an opaque
    // array; ru_maxrss is the first of them, and is in bytes there.
    version (OSX) return cast(ulong) usage.ru_opaque[0];
    else return cast(ulong) usage.ru_maxrss * 1024; // kilobytes elsewhere
}

void main(string[] args) {
    immutable ulong smallMiB = args.length > 1 ? args[1].to!ulong : 64;
    immutable ulong largeMiB = args.length > 2 ? args[2].to!ulong : 4352;
    enum ulong MiB = 1024 * 1024;
    // Not a multiple of the chunk size, so the last chunk is short.
    immutable ulong[2] sizes = [smallMiB * MiB + 12_345, largeMiB * MiB + 12_345];

    writeln("s3lite large-object memory fixture (issue #607)");

    // Server state: the stored object's length and what it saw of the upload.
    ulong storedLength, uploadMismatches;
    auto server = new LoopbackServer((ref Request request, Connection conn) {
        auto buffer = new ubyte[chunkBytes]; // one per request, never per object size
        if (request.method == "PUT") {
            ulong offset = 0, bad = 0;
            size_t n;
            while ((n = conn.readBody(buffer)) != 0) {
                bad += countMismatches(buffer[0 .. n], offset);
                offset += n;
            }
            check(request.contentLength == offset, "Content-Length disagrees with the bytes received");
            storedLength = offset;
            uploadMismatches = bad;
            conn.respond(200, ["ETag": `"big-etag"`], null);
        } else {
            conn.sendHead(200, ["ETag": `"big-etag"`], storedLength);
            for (ulong at = 0; at < storedLength;) {
                immutable n = storedLength - at < chunkBytes ? cast(size_t)(storedLength - at) : chunkBytes;
                fillPattern(buffer[0 .. n], at);
                conn.send(buffer[0 .. n]);
                at += n;
            }
        }
    });
    auto origin = server.origin;

    auto work = new char[recommendedWorkBytes];
    auto chunkBuffer = new ubyte[chunkBytes];
    writefln("  client buffers: %s-byte work buffer + %s-byte chunk buffer", work.length, chunkBuffer.length);

    ulong[2] peaks;
    {
        S3Client client;
        auto opened = openClient(client, origin, work);
        check(opened.ok, "client should open: " ~ opened.message[].idup);

        foreach (i, size; sizes) {
            auto trip = roundTrip(client, size, chunkBuffer);
            check(trip.put.ok, "upload failed: " ~ trip.put.status.message[].idup);
            check(trip.put.bytesSent == size && storedLength == size,
                "server received " ~ storedLength.to!string ~ " of " ~ size.to!string ~ " bytes");
            check(uploadMismatches == 0, "uploaded bytes differ from the pattern");
            check(trip.get.ok, "download failed: " ~ trip.get.status.message[].idup);
            check(trip.sink.received == size && trip.get.bytesDelivered == size,
                "sink received " ~ trip.sink.received.to!string ~ " of " ~ size.to!string ~ " bytes");
            check(trip.sink.mismatches == 0, "downloaded bytes differ from the pattern");
            check(trip.get.hasTotalSize && trip.get.totalSize == size, "total size not reported");
            peaks[i] = peakRssBytes();
            writefln("  object %12s bytes (%5s MiB): uploaded and downloaded intact; peak RSS so far %6.1f MiB",
                size, size / MiB, peaks[i] / cast(double) MiB);
        }
    }
    auto failures = server.stop();
    check(failures.length == 0, "server-side failure: " ~ failures.to!string);
    check(server.connectionsAccepted == 1, "both objects should travel over one connection");

    immutable growth = peaks[1] > peaks[0] ? peaks[1] - peaks[0] : 0;
    writefln("  object grew by %s MiB (x%.0f); peak RSS grew by %.2f MiB (allowed: %s MiB)",
        (sizes[1] - sizes[0]) / MiB, sizes[1] / cast(double) sizes[0], growth / cast(double) MiB,
        allowedGrowthBytes / MiB);
    // The default sizes must cross 4 GiB; sizes given on the command line
    // are the caller's business.
    check(args.length > 2 || sizes[1] > uint.max, "the default large object should exceed 4 GiB");
    check(growth <= allowedGrowthBytes, "peak memory grew with object size");
    writeln("s3lite large-object memory fixture: PASS (peak memory does not grow with object size)");
}
