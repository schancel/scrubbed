/// Bounded, deterministic UTF-8 representation of the selected HTML tree.
module effects.html_tree_export;

import domain.document : Document;
import effects.html_tree : HtmlNodeKind, HtmlTree;
import std.conv : to;
import std.exception : enforce;

enum size_t maxTreeJsonBytes = 4 * 1024 * 1024;

class HtmlTreeOutputLimit : Exception {
    this() pure { super("tree-json output exceeds 4 MiB"); }
}

private struct Writer {
    char[] bytes;

    void put(string value) pure {
        if (value.length > maxTreeJsonBytes - bytes.length)
            throw new HtmlTreeOutputLimit;
        bytes ~= value;
    }

    void quoted(string value) pure {
        put("\"");
        foreach (char c; value) {
            switch (c) {
            case '"': put("\\\""); break;
            case '\\': put("\\\\"); break;
            case '\b': put("\\b"); break;
            case '\f': put("\\f"); break;
            case '\n': put("\\n"); break;
            case '\r': put("\\r"); break;
            case '\t': put("\\t"); break;
            default:
                if (cast(ubyte)c < 0x20) {
                    immutable hex = "0123456789abcdef";
                    char[6] escaped = ['\\', 'u', '0', '0',
                        hex[(cast(ubyte)c >> 4) & 15], hex[cast(ubyte)c & 15]];
                    put(cast(string)escaped[]);
                } else put(cast(string)(&c)[0 .. 1]);
            }
        }
        put("\"");
    }
}

/// Key order, node order, and one trailing LF are part of tree-json:v1.
string serializeTreeJson(Document document, const ref HtmlTree tree) pure {
    Writer writer;
    auto source = document.source;
    writer.put(`{"version":"tree-json:v1","documentId":`);
    writer.quoted(document.id.text);
    writer.put(`,"source":{"namespace":`);
    writer.quoted(source.datasetNamespace);
    writer.put(`,"sourceKey":`);
    writer.quoted(source.sourceKey);
    writer.put(`,"recordKey":`);
    writer.quoted(source.recordKey);
    writer.put(`},"outputName":`);
    writer.quoted(document.outputName.text);
    writer.put(`,"nodes":[`);
    foreach (index, node; tree.nodes) {
        if (index) writer.put(",");
        writer.put(`{"kind":`);
        writer.quoted(node.kind == HtmlNodeKind.element ? "element" : "text");
        writer.put(`,"parent":`);
        writer.put(node.parentIndex == size_t.max ? "null" : node.parentIndex.to!string);
        writer.put(`,"name":`);
        writer.quoted(node.name);
        writer.put(`,"attributes":[`);
        foreach (attributeIndex, attribute; node.attributes) {
            if (attributeIndex) writer.put(",");
            writer.put(`{"name":`);
            writer.quoted(attribute.name);
            writer.put(`,"value":`);
            writer.quoted(attribute.value);
            writer.put("}");
        }
        writer.put(`],"text":`);
        writer.quoted(node.text);
        writer.put("}");
    }
    writer.put("]}\n");
    return writer.bytes.idup;
}

unittest {
    import domain.document : OutputName, SourceLocator;
    import effects.html_tree : HtmlAttribute, HtmlNode;
    import std.json : parseJSON;
    import std.exception : assertThrown;

    auto document = Document(SourceLocator("local-html:v1", "/tmp/a", "x.html"),
        OutputName("x.html.tree.json"));
    HtmlTree tree;
    tree.nodes = [HtmlNode(HtmlNodeKind.element, size_t.max, "x", "",
        [HtmlAttribute("a", "\u0000\n")])];
    auto encoded = serializeTreeJson(document, tree);
    enforce(encoded[$ - 1] == '\n');
    auto json = parseJSON(encoded);
    enforce(json["version"].str == "tree-json:v1");
    enforce(json["nodes"].array[0]["attributes"].array[0]["value"].str == "\u0000\n");
    auto controls = new char[1024 * 1024];
    controls[] = '\u0001';
    tree.nodes[0].text = controls.idup;
    assertThrown!HtmlTreeOutputLimit(serializeTreeJson(document, tree));
}
