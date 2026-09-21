// Regenerate or verify the pinned WHATWG named-character-reference table.
// Run from the repository root; see THIRD_PARTY_NOTICES.md for commands.
module generate_entities;

import std.algorithm.sorting : sort;
import std.array : appender;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : read, readText, write;
import std.json : parseJSON;
import std.stdio : stderr, writeln;
import std.string : toLower;

private enum expectedHash =
    "d741d877ac77c4194c4ad526b5b4a19aef8dfe411ab840a466891cdbb9f362e6";
private enum defaultOutput = "source/filters/entities_data.d";
private enum hexDigits = "0123456789abcdef";

private string dString(string value) {
    auto result = appender!string;
    result.put('"');
    for (size_t i; i < value.length; i++) {
        if (i + 3 <= value.length && value[i .. i + 3] == "\u200E") {
            result.put("\\u200E");
            i += 2;
            continue;
        }
        if (i + 3 <= value.length && value[i .. i + 3] == "\u200F") {
            result.put("\\u200F");
            i += 2;
            continue;
        }
        const c = value[i];
        switch (c) {
            case '"': result.put("\\\""); break;
            case '\\': result.put("\\\\"); break;
            case '\b': result.put("\\b"); break;
            case '\f': result.put("\\f"); break;
            case '\n': result.put("\\n"); break;
            case '\r': result.put("\\r"); break;
            case '\t': result.put("\\t"); break;
            default:
                if (cast(ubyte) c < 0x20) {
                    result.put("\\u00");
                    result.put(hexDigits[(cast(ubyte) c) >> 4]);
                    result.put(hexDigits[(cast(ubyte) c) & 15]);
                } else {
                    result.put(c);
                }
        }
    }
    result.put('"');
    return result.data;
}

private string generate(string jsonBytes) {
    auto data = parseJSON(jsonBytes);
    auto names = data.object.keys;
    sort(names);
    if (names.length != 2231)
        throw new Exception("Expected 2,231 WHATWG references");

    auto result = appender!string;
    result.put("// Generated from WHATWG entities.json (SHA-256 " ~ expectedHash ~ ").\n");
    result.put("// Copyright © WHATWG (Apple, Google, Mozilla, Microsoft); BSD-3-Clause terms in THIRD_PARTY_NOTICES.md.\n");
    result.put("module filters.entities_data;\n\n");
    result.put("private string[string] namedEntities;\n\n");
    result.put("static this() {\n    namedEntities = [\n");
    foreach (name; names) {
        result.put("        ");
        result.put(dString(name));
        result.put(": ");
        result.put(dString(data[name]["characters"].str));
        result.put(",\n");
    }
    result.put("    ];\n}\n\n");
    result.put("string findNamedEntity(string name) {\n");
    result.put("    auto value = name in namedEntities;\n");
    result.put("    return value is null ? null : *value;\n");
    result.put("}\n");
    return result.data;
}

int main(string[] args) {
    if (args.length < 3 || args.length > 4 ||
        (args[1] != "--check" && args[1] != "--write")) {
        stderr.writeln("usage: generate_entities --check|--write entities.json [output.d]");
        return 2;
    }
    const outputPath = args.length == 4 ? args[3] : defaultOutput;
    const raw = read(args[2]);
    const digest = sha256Of(cast(ubyte[]) raw);
    const actualHash = toLower(toHexString(digest).idup);
    if (actualHash != expectedHash) {
        stderr.writeln("WHATWG input SHA-256 mismatch: ", actualHash);
        return 1;
    }
    const generated = generate(cast(string) raw);
    if (args[1] == "--check") {
        if (readText(outputPath) != generated) {
            stderr.writeln("Generated table differs: ", outputPath);
            return 1;
        }
        writeln("Verified 2,231 named references: ", outputPath);
    } else {
        write(outputPath, generated);
        writeln("Generated 2,231 named references: ", outputPath);
    }
    return 0;
}
