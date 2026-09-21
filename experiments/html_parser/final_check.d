// Restricted Lexbor boundary proof only; no production parser is selected.
module experiments.html_parser.final_check;

import text.decoding : decodeBytes;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.file : read;
import std.format : format;
import std.stdio : writeln;
import std.algorithm.searching : canFind;

extern(C) {
    struct Node {
        void* events;
        size_t localName, prefix, ns;
        void* owner;
        Node* next, prev, parent, first, last;
        void* user;
        int type;
    }
    struct NativeString { const(char)* data; size_t length; }
    struct Text { Node node; NativeString data; }
    void* lxb_html_document_create();
    int lxb_html_document_parse(void*, const(ubyte)*, size_t);
    void* lxb_html_document_destroy(void*);
    const(char)* lxb_dom_element_qualified_name(Node*, size_t*);
    void* lxb_dom_element_first_attribute_noi(Node*);
    void* lxb_dom_element_next_attribute_noi(void*);
    const(char)* lxb_dom_attr_qualified_name(void*, size_t*);
    const(char)* lxb_dom_attr_value_noi(void*, size_t*);
}

enum size_t maxRawBytes = 64 * 1024;
enum size_t maxNodes = 8192;
enum size_t maxDepth = 128;
enum size_t maxObservationBytes = 1024 * 1024;

enum Fault { none, beforeParse, afterParse, duringObserve, beforeCleanup }
struct Accounting { size_t created, destroyed; }

private string copyNative(const(char)* p, size_t n) {
    if (n == 0) return "";
    if (p is null) throw new Exception("null native string");
    return p[0 .. n].idup;
}

private void append(ref string target, string part) {
    if (part.length > maxObservationBytes - target.length)
        throw new Exception("observation cap exceeded");
    target ~= part;
}

private void observe(Node* node, ref string result, ref size_t count,
    size_t depth, Fault fault) {
    if (depth > maxDepth) throw new Exception("tree depth cap exceeded");
    for (; node !is null; node = node.next) {
        if (++count > maxNodes) throw new Exception("node cap exceeded");
        if (fault == Fault.duringObserve && count == 3)
            throw new Exception("injected observation failure");
        if (node.type == 1) {
            size_t n;
            auto tag = copyNative(lxb_dom_element_qualified_name(node, &n), n);
            append(result, "<" ~ tag);
            for (auto attr = lxb_dom_element_first_attribute_noi(node);
                 attr !is null; attr = lxb_dom_element_next_attribute_noi(attr)) {
                auto name = lxb_dom_attr_qualified_name(attr, &n);
                auto key = copyNative(name, n);
                auto value = lxb_dom_attr_value_noi(attr, &n);
                append(result, " " ~ key ~ "=\"" ~ copyNative(value, n) ~ "\"");
            }
            append(result, ">");
            observe(node.first, result, count, depth + 1, fault);
            append(result, "</" ~ tag ~ ">");
        } else if (node.type == 3) {
            auto value = (cast(Text*) node).data;
            append(result, "{" ~ copyNative(value.data, value.length) ~ "}");
        } else if (node.first !is null) {
            observe(node.first, result, count, depth + 1, fault);
        }
    }
}

// The only native owner is local; every post-create failure closes it exactly once.
private string parseOwned(string utf8, Fault fault, ref Accounting accounting) {
    auto native = lxb_html_document_create();
    if (native is null) throw new Exception("native create failed");
    ++accounting.created;
    scope(exit) {
        lxb_html_document_destroy(native);
        ++accounting.destroyed;
    }
    if (fault == Fault.beforeParse) throw new Exception("injected pre-parse failure");
    auto status = lxb_html_document_parse(native,
        cast(const(ubyte)*) utf8.ptr, utf8.length);
    if (status != 0) throw new Exception("native parse status " ~ to!string(status));
    if (fault == Fault.afterParse) throw new Exception("injected post-parse failure");
    size_t count;
    string result;
    observe((cast(Node*) native).first, result, count, 0, fault);
    if (fault == Fault.beforeCleanup) throw new Exception("injected pre-cleanup failure");
    return result;
}

private string restricted(const(ubyte)[] raw, string charset,
    ref Accounting accounting, Fault fault = Fault.none) {
    if (raw.length > maxRawBytes) throw new Exception("raw-byte cap exceeded");
    auto outcome = decodeBytes(raw, charset, "html-parser-final-check");
    if (!outcome.isDecoded)
        throw new Exception("quarantined: " ~ to!string(outcome.quarantined.reason));
    // decodeBytes returns a fresh, owned UTF-8 buffer. Lexbor does not sniff.
    return parseOwned(outcome.decoded.text, fault, accounting);
}

private void equal(string label, string got, string expected) {
    if (got != expected) throw new Exception(label ~ " observed " ~ got);
    writeln(label, " exact=pass sha256=", format("%(%02x%)", sha256Of(got)));
}

private void reject(string label, const(ubyte)[] raw, string charset,
    string expectedReason, bool nativeCreated = false) {
    Accounting a;
    try {
        restricted(raw, charset, a);
        throw new Exception(label ~ " unexpectedly accepted");
    } catch (Exception e) {
        if (!e.msg.canFind(expectedReason)) throw e;
    }
    if (a.created != a.destroyed || (a.created != 0) != nativeCreated)
        throw new Exception(label ~ " ownership accounting failed");
    writeln(label, " rejected=pass");
}

void main(string[] args) {
    Accounting a;
    auto simple = cast(const(ubyte)[]) "<article><nav><a href='/x'>A&amp;B</a></nav><ul><li>One<li>Two</ul></article>";
    auto simpleExpected = "<html><head></head><body><article><nav><a href=\"/x\">{A&B}</a></nav><ul><li>{One}</li><li>{Two}</li></ul></article></body></html>";
    auto mutableInput = cast(ubyte[]) simple.dup;
    auto ownedObservation = restricted(mutableInput, "utf-8", a);
    mutableInput[0] = '!';
    equal("article-nav-list-after-native-destroy-and-input-mutation", ownedObservation, simpleExpected);
    equal("utf8-bom", restricted(cast(ubyte[]) [0xef, 0xbb, 0xbf] ~ cast(ubyte[]) "<p>café</p>", null, a),
        "<html><head></head><body><p>{café}</p></body></html>");
    equal("utf16le-bom", restricted([cast(ubyte) 0xff, 0xfe, 0x3c, 0, 0x70, 0, 0x3e, 0, 0x41, 0, 0x3c, 0, 0x2f, 0, 0x70, 0, 0x3e, 0], "utf-16", a),
        "<html><head></head><body><p>{A}</p></body></html>");
    equal("utf16be-declared", restricted([cast(ubyte) 0, 0x3c, 0, 0x70, 0, 0x3e, 0, 0x42, 0, 0x3c, 0, 0x2f, 0, 0x70, 0, 0x3e], "utf-16be", a),
        "<html><head></head><body><p>{B}</p></body></html>");
    equal("custom-attrs", restricted(cast(const(ubyte)[]) "<x-note data-id='a&amp;b' disabled>Hi</x-note>", null, a),
        "<html><head></head><body><x-note data-id=\"a&b\" disabled=\"\">{Hi}</x-note></body></html>");
    equal("table-foster", restricted(cast(const(ubyte)[]) "<table>outside<tr><td>cell</table>", null, a),
        "<html><head></head><body>{outside}<table><tbody><tr><td>{cell}</td></tr></tbody></table></body></html>");
    equal("broken-nesting", restricted(cast(const(ubyte)[]) "<p>one<b>two</p>three", null, a),
        "<html><head></head><body><p>{one}<b>{two}</b></p><b>{three}</b></body></html>");
    equal("script-style", restricted(cast(const(ubyte)[]) "<style>a>b{c:d}</style><script>if(a<b)c()</script><p>X</p>", null, a),
        "<html><head><style>{a>b{c:d}}</style><script>{if(a<b)c()}</script></head><body><p>{X}</p></body></html>");
    reject("latin1-label", cast(const(ubyte)[]) "<p>caf\xE9</p>", "iso-8859-1", "unsupportedCharset");
    reject("meta-sniff-not-supported", cast(const(ubyte)[]) "<meta charset='iso-8859-1'><p>caf\xE9</p>", null, "malformedUnicode");
    reject("bad-unicode", [cast(ubyte) 0xed, 0xa0, 0x80], null, "malformedUnicode");
    reject("bom-conflict", [cast(ubyte) 0xef, 0xbb, 0xbf, 0x41], "utf-16le", "conflictingCharset");
    reject("raw-cap", new ubyte[maxRawBytes + 1], null, "raw-byte cap");
    string deep;
    foreach (_; 0 .. 180) deep ~= "<div>";
    deep ~= "leaf";
    reject("tree-depth-cap", cast(const(ubyte)[]) deep, null, "tree depth cap", true);
    string broad;
    foreach (_; 0 .. 8200) broad ~= "<i></i>";
    reject("tree-node-cap", cast(const(ubyte)[]) broad, null, "node cap", true);
    foreach (fault; [Fault.beforeParse, Fault.afterParse, Fault.duringObserve, Fault.beforeCleanup]) {
        Accounting injected;
        try {
            restricted(simple, null, injected, fault);
            throw new Exception("injected failure was accepted");
        } catch (Exception e) {
            if (!e.msg.canFind("injected")) throw e;
        }
        if (injected.created != 1 || injected.destroyed != 1)
            throw new Exception("injected failure leaked native owner");
    }
    writeln("injected_failures=4 owners_closed=4");
    if (a.created != a.destroyed) throw new Exception("successful run leaked native owner");
    try {
        equal("negative-control", ownedObservation, "deliberately wrong");
        throw new Exception("negative control accepted");
    } catch (Exception e) {
        if (!e.msg.canFind("negative-control observed")) throw e;
    }
    writeln("negative_control=rejected owners_closed=", a.destroyed);
    if (args.length == 2) {
        auto raw = cast(ubyte[]) read(args[1]);
        auto hash = format("%(%02x%)", sha256Of(raw));
        if (hash != "c10358bda1648db3138d1a20c5bc21961cef0eee0f613f8718a317650240efe1")
            throw new Exception("WPT fixture hash mismatch");
        auto observation = restricted(raw, "utf-8", a);
        if (!observation.canFind("<title>{Ambiguous ampersand}</title>") ||
            !observation.canFind("<a href=\"?a=b&c=d&a0b=c&copy=1&noti=n&not=in&notin=∉¬&;& &\">{Link}</a>") ||
            !observation.canFind("<p>{Text: ?a=b&c=d&a0b=c©=1¬i=n¬=in¬in=∉¬&;& &}</p>"))
            throw new Exception("WPT selected semantics mismatch");
        auto observedHash = format("%(%02x%)", sha256Of(observation));
        if (observedHash != "72c7704cb54e8cca442036822e609149e33da68a25c53aff7ae18b852b23f4f3")
            throw new Exception("WPT full observation hash mismatch");
        writeln("wpt-ambiguous-ampersand selected=pass observation_sha256=",
            observedHash);
    }
}
