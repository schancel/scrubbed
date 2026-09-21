// Release-active integration checks for effects.warc_reader.
import effects.warc_reader;
import std.conv : to;
import std.digest.sha : sha256Of, toHexString;
import std.stdio : writeln;

void need(bool condition, string reason) {
    if (!condition) throw new Exception(reason);
}

void rejects(void delegate() action, string reason) {
    bool rejected;
    try action();
    catch (WarcError) { rejected = true; }
    need(rejected, "accepted " ~ reason);
}

ubyte[] record(string id, string kind, const(ubyte)[] block, string extra = "",
    string uri = "https://example.org/a", string length = "") {
    auto header = "WARC/1.1\r\nWARC-Type: " ~ kind ~
        "\r\nWARC-Record-ID: <urn:uuid:" ~ id ~ ">\r\n" ~
        (uri.length ? "WARC-Target-URI: " ~ uri ~ "\r\n" : "") ~
        "WARC-Date: 2026-09-21T00:00:00Z\r\n" ~ extra ~
        "Content-Length: " ~ (length.length ? length : block.length.to!string) ~
        "\r\n\r\n";
    return (cast(ubyte[]) header.dup ~ block ~ cast(ubyte[]) "\r\n\r\n").dup;
}

string fingerprint(WarcRecord r) {
    auto value = r.sourceKey ~ "|" ~ r.ordinal.to!string ~ "|" ~ r.recordId ~ "|" ~
        r.date ~ "|" ~ r.type ~ "|" ~ r.targetUri ~ "|" ~
        toHexString(sha256Of(r.block)).idup;
    foreach (field; r.fields) value ~= "|" ~ field.name ~ ":" ~ field.value;
    return value;
}

string[] decode(const(ubyte)[] bytes, size_t step) {
    string[] output;
    auto parser = new WarcReader("dataset/archive-key", (WarcRecord r) {
        output ~= fingerprint(r);
        return true;
    });
    for (size_t at; at < bytes.length; at += step) {
        auto end = at + step < bytes.length ? at + step : bytes.length;
        parser.feed(bytes[at .. end]);
    }
    parser.finish();
    return output;
}

void main() {
    auto a = record("one", "conversion", cast(const(ubyte)[]) "caf\xc3\xa9\n" ~
        new ubyte[65400], "Content-Type: text/plain\r\nX-Unknown: retained\r\n");
    auto b = record("two", "response", new ubyte[65400],
        "Content-Type: application/http\r\n");
    auto archive = a ~ b;
    need(archive.length > 131072, "aggregate fixture too small");
    auto expected = decode(archive, 1);
    need(expected.length == 2, "two records");
    need(expected == decode(archive, 127), "127-byte equivalence");
    need(expected == decode(archive, archive.length), "whole-feed equivalence");
    // Deterministic irregular chunk sequence.
    string[] irregular;
    auto parser = new WarcReader("dataset/archive-key", (WarcRecord r) {
        irregular ~= fingerprint(r); return true;
    });
    size_t at, seed = 17;
    while (at < archive.length) {
        seed = (seed * 37 + 11) % 997;
        auto n = 1 + seed;
        auto end = at + n < archive.length ? at + n : archive.length;
        parser.feed(archive[at .. end]);
        at = end;
    }
    parser.finish();
    need(expected == irregular, "irregular equivalence");

    WarcRecord saved;
    auto ownership = new WarcReader("key", (WarcRecord r) { saved = r; return true; });
    auto info = record("info", "warcinfo", cast(const(ubyte)[]) "software: test",
        "X-Unknown: retained\r\n", "");
    ownership.feed(info);
    ownership.finish();
    info[] = 0;
    need(!saved.hasTargetUri && saved.fields[3].name == "X-Unknown" &&
        saved.fields[3].value == " retained" && saved.block == cast(ubyte[]) "software: test",
        "owned warcinfo and ordered extension header");
    need(decode(record("meta", "metadata", [], "", ""), 127).length == 1,
        "metadata without URI");
    need(decode(record("meta", "metadata", [], "", "https://example.org/m"), 127).length == 1,
        "metadata with URI");
    need(decode(record("zero", "response", []), 1).length == 1,
        "zero-length block");
    auto mixedCase = record("case", "response", [], "X-Mixed: value\r\n");
    auto changed = cast(string) mixedCase;
    import std.string : replace;
    need(decode(cast(const(ubyte)[]) changed.replace("WARC-Type", "wArC-tYpE"), 127).length == 1,
        "case-insensitive field name");

    auto binary = record("binary", "response", cast(const(ubyte)[]) [0, 255, 13, 10],
        "Content-Type: application/http\r\n");
    auto binaryReader = new WarcReader("key", (WarcRecord r) {
        need(!r.isConversionText(), "binary misclassified");
        rejects({ r.conversionText(); }, "response conversion");
        need(r.block == cast(ubyte[]) [0, 255, 13, 10], "binary bytes");
        return true;
    });
    binaryReader.feed(binary); binaryReader.finish();
    auto textReader = new WarcReader("key", (WarcRecord r) {
        need(r.isConversionText() && r.conversionText() == "caf\xc3\xa9\n", "UTF-8 view");
        return true;
    });
    textReader.feed(record("text", "conversion", cast(const(ubyte)[]) "caf\xc3\xa9\n",
        "Content-Type: text/plain\r\n")); textReader.finish();

    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true); p.finish(); }, "empty");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(a[0 .. $ - 1]); p.finish(); }, "truncated");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        auto bad = record("bad", "response", [], "", "https://example.org", "65537");
        p.feed(bad); }, "oversized block");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], "", "https://example.org", "999999999999999999999999"));
        }, "overflow length");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], "", "https://example.org", "x"));
        }, "nondigit length");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], "WARC-Date: duplicate\r\n"));
        }, "duplicate required field");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        auto bad = record("bad", "response", []);
        bad[$ - 1] = 'X'; p.feed(bad);
        }, "corrupt terminator");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        auto bad = record("bad", "response", []);
        auto text = (cast(string) bad).replace("WARC-Date: 2026-09-21T00:00:00Z\r\n", "");
        p.feed(cast(const(ubyte)[]) text);
        }, "missing date");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "warcinfo", [], "", "https://example.org"));
        }, "warcinfo URI");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "conversion", cast(const(ubyte)[]) [255],
            "Content-Type: text/plain\r\n")); }, "invalid UTF-8");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], " X: fold\r\n")); }, "folded field");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], "X-Test: =?utf-8?B?QQ==?=\r\n"));
        }, "encoded word");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(record("bad", "response", [], "WARC-Segment-Number: 1\r\n"));
        }, "segmentation");
    rejects({ auto p = new WarcReader("k", (WarcRecord r) => true);
        p.feed(cast(const(ubyte)[]) ("WARC/1.1\r\nX: " ~ new char[4096]));
        }, "header cap");
    size_t earlier;
    auto late = new WarcReader("k", (WarcRecord r) { ++earlier; return true; });
    late.feed(record("good", "response", []));
    rejects({ late.feed(record("bad", "response", [cast(ubyte) 1])[0 .. $ - 2]);
        late.finish(); }, "late truncation");
    need(earlier == 1 && late.completedRecords == 1, "late failure emitted failed record");
    auto cancelled = new WarcReader("k", (WarcRecord r) { return false; });
    rejects({ cancelled.feed(record("cancel", "response", [])); }, "callback cancellation");
    rejects({ cancelled.feed(record("again", "response", [])); }, "cancelled reader reuse");
    bool thrown;
    auto callback = new WarcReader("k", (WarcRecord r) { throw new Exception("callback"); return true; });
    try callback.feed(record("throw", "response", []));
    catch (Exception e) { thrown = e.msg == "callback"; }
    need(thrown, "callback exception propagation");
    rejects({ callback.finish(); }, "thrown reader reuse");
    writeln("production WARC checks passed; two near-64KiB records, aggregate=", archive.length);
}
