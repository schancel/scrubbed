// Standalone D-only HTML parser evaluation. Native libraries are built outside
// this checkout at the pinned revisions documented in the accompanying report.
module experiments.html_parser.evaluate;

import core.stdc.stdlib : exit;
import core.stdc.string : strlen;
import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;
import std.conv : to;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.stdio : writeln, stderr;
import std.algorithm.searching : canFind, count;
import std.digest.sha : sha256Of;
import std.format : format;

extern(C) {
    struct LNode {
        void* events;
        size_t localName, prefix, ns;
        void* owner;
        LNode* next, prev, parent, first, last;
        void* user;
        int type;
    }
    struct LString { const(char)* data; size_t length; }
    struct LText { LNode node; LString data; }
    void* lxb_html_document_create();
    int lxb_html_document_parse(void*, const(ubyte)*, size_t);
    void* lxb_html_document_destroy(void*);
    const(char)* lxb_dom_element_qualified_name(LNode*, size_t*);

    struct GVector { void** data; uint length, capacity; }
    struct GPiece { const(char)* data; size_t length; }
    struct GPosition { uint line, column, offset; }
    struct GDocument {
        GVector children;
        bool hasDoctype;
        const(char)* name, publicId, systemId;
        int quirks;
    }
    struct GElement {
        GVector children;
        int tag, nameSpace;
        GPiece originalTag, originalEndTag;
        GPosition start, end;
        GVector attributes;
    }
    struct GText { const(char)* text; GPiece original; GPosition start; }
    struct GNode {
        int type;
        GNode* parent;
        size_t index;
        int flags;
        union { GDocument document; GElement element; GText text; }
    }
    struct GOutput { GNode* document, root; GVector errors; }
    GOutput* gumbo_parse_with_options(const void*, const(char)*, size_t);
    void gumbo_destroy_output(const void*, GOutput*);
    extern const ubyte kGumboDefaultOptions;
    const(char)* gumbo_normalized_tagname(int);
}

struct Fixture { string name; ubyte[] input; string[] required; string expected; size_t tagCount; }

Fixture[] fixtures() {
    Fixture[] cases = [
        Fixture("broken-nesting", cast(ubyte[])"<p>one<b>two</p>three", [],
            "<html><head></head><body><p>{one}<b>{two}</b></p><b>{three}</b></body></html>"),
        Fixture("table-foster", cast(ubyte[])"<table>outside<tr><td>cell</table>", [],
            "<html><head></head><body>{outside}<table><tbody><tr><td>{cell}</td></tr></tbody></table></body></html>"),
        Fixture("entity-utf8", cast(ubyte[])"<p>A&amp;B &#x1F642; café</p>", [],
            "<html><head></head><body><p>{A&B 🙂 café}</p></body></html>"),
        Fixture("nul-truncated", [cast(ubyte)'<', 'p', '>', 'a', 0, 'b', '<', 'i'], [],
            "<html><head></head><body><p>{ab}</p></body></html>"),
        Fixture("charset-meta", cast(ubyte[])"<meta charset='iso-8859-1'><p>caf\xE9</p>", ["<meta>", "caf"]),
    ];
    string deep;
    foreach (_; 0 .. 256) deep ~= "<div>";
    deep ~= "leaf";
    cases ~= Fixture("deep-256", cast(ubyte[])deep, ["{leaf}"], "", 256);
    string wide;
    foreach (i; 0 .. 512) wide ~= "<span>" ~ to!string(i) ~ "</span>";
    cases ~= Fixture("wide-512", cast(ubyte[])wide, ["{0}", "{511}"], "", 512);
    return cases;
}

void appendText(ref string observation, const(char)* ptr, size_t length) {
    if (ptr is null || length == 0) return;
    observation ~= "{" ~ ptr[0 .. length].idup ~ "}";
}

void lexWalk(LNode* node, ref string observation) {
    for (; node !is null; node = node.next) {
        if (node.type == 1) {
            size_t length;
            auto name = lxb_dom_element_qualified_name(node, &length);
            auto tag = name[0 .. length].idup;
            observation ~= "<" ~ tag ~ ">";
            lexWalk(node.first, observation);
            observation ~= "</" ~ tag ~ ">";
        } else if (node.type == 3) {
            auto data = (cast(LText*)node).data;
            appendText(observation, data.data, data.length);
        } else {
            lexWalk(node.first, observation);
        }
    }
}

string parseLexbor(const(ubyte)[] input, out size_t errors) {
    auto document = lxb_html_document_create();
    if (document is null) throw new Exception("Lexbor create returned null");
    scope(exit) lxb_html_document_destroy(document);
    auto status = lxb_html_document_parse(document, input.ptr, input.length);
    if (status != 0) throw new Exception("Lexbor parse status " ~ to!string(status));
    errors = 0; // Lexbor's public simple parse API does not expose a count here.
    string observation;
    lexWalk((cast(LNode*)document).first, observation);
    return observation;
}

void gumboWalk(GNode* node, ref string observation) {
    if (node is null) return;
    GVector children;
    if (node.type == 0) children = node.document.children;
    else if (node.type == 1 || node.type == 6) {
        auto name = gumbo_normalized_tagname(node.element.tag);
        auto tag = name is null ? "" : name[0 .. strlen(name)].idup;
        observation ~= "<" ~ tag ~ ">";
        children = node.element.children;
        foreach (i; 0 .. children.length) gumboWalk(cast(GNode*)children.data[i], observation);
        observation ~= "</" ~ tag ~ ">";
        return;
    } else if (node.type == 2 || node.type == 3 || node.type == 5) {
        auto value = node.text.text;
        appendText(observation, value, value is null ? 0 : strlen(value));
    }
    foreach (i; 0 .. children.length) gumboWalk(cast(GNode*)children.data[i], observation);
}

string parseGumbo(const(ubyte)[] input, out size_t errors) {
    // Gumbo retains original-tag/text slices into input until destroy.
    auto output = gumbo_parse_with_options(&kGumboDefaultOptions, cast(const(char)*)input.ptr, input.length);
    if (output is null) throw new Exception("Gumbo parse returned null");
    scope(exit) gumbo_destroy_output(&kGumboDefaultOptions, output);
    errors = output.errors.length;
    string observation;
    gumboWalk(output.document, observation);
    return observation;
}

bool quality(string observation, const(string)[] required, string expected = "", size_t tagCount = 0) {
    foreach (part; required) if (!observation.canFind(part)) return false;
    if (expected.length && observation != expected) return false;
    if (tagCount && observation.count(tagCount == 256 ? "<div>" : "<span>") != tagCount) return false;
    return true;
}

void main(string[] args) {
    if (args.length != 3 || (args[1] != "lexbor" && args[1] != "gumbo")) {
        stderr.writeln("usage: evaluate lexbor|gumbo iterations");
        exit(2);
    }
    auto iterations = to!size_t(args[2]);
    if (iterations < 2) throw new Exception("need cold plus warm iterations");
    auto corpus = fixtures();
    assert(!quality("<p>{bad}</p>", ["<p>", "good"])); // negative quality control
    writeln("candidate=", args[1], " iterations=", iterations,
        " cases=", corpus.length, " negative_control=rejected");
    foreach (fixture; corpus) {
        string first;
        size_t errors;
        long coldMicros, warmMicros;
        auto before = rusage.init;
        getrusage(RUSAGE_SELF, &before);
        foreach (i; 0 .. iterations) {
            auto timer = StopWatch(AutoStart.yes);
            string result = args[1] == "lexbor" ? parseLexbor(fixture.input, errors)
                                                  : parseGumbo(fixture.input, errors);
            auto us = timer.peek.total!"usecs";
            if (i == 0) { first = result; coldMicros = us; }
            else { warmMicros += us; if (result != first) throw new Exception("unstable output"); }
        }
        auto after = rusage.init;
        getrusage(RUSAGE_SELF, &after);
        auto cpu = (after.ru_utime.tv_sec - before.ru_utime.tv_sec) * 1_000_000L
                 + (after.ru_utime.tv_usec - before.ru_utime.tv_usec)
                 + (after.ru_stime.tv_sec - before.ru_stime.tv_sec) * 1_000_000L
                 + (after.ru_stime.tv_usec - before.ru_stime.tv_usec);
        bool pass = quality(first, fixture.required, fixture.expected, fixture.tagCount);
        writeln(fixture.name, " quality=", pass ? "pass" : "FAIL",
            " errors=", args[1] == "gumbo" ? to!string(errors) : "unsupported",
            " cold_us=", coldMicros, " warm_mean_us=", warmMicros / (iterations - 1),
            " cpu_us=", cpu, " process_peak_rss_bytes=", after.ru_opaque[0],
            " observation_sha256=", format("%(%02x%)", sha256Of(first)),
            " observation=", first.length < 800 ? first : first[0 .. 800] ~ "...[truncated]");
        if (!pass) exit(1);
    }
}
