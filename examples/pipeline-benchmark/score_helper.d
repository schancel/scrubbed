// Small, pure-reuse scoring helper for examples/pipeline-benchmark/run.sh.
// This intentionally does NOT invent a new scoring methodology: every
// nontrivial computation here is a direct call into modules
// benchmarks/external_comparator.d already uses for the same purpose
// (word-level token-overlap scoring, and decoding the real
// `language-id-detect` sidecar wire format). This file only adds thin CLI
// plumbing and PII-audit JSON field reads (the audit sidecar is already
// plain, human-readable JSON per docs/pii-pipeline.md; no decoder to reuse
// there beyond std.json).
//
// Build: ldc2 -O3 -release -Isource -I. examples/pipeline-benchmark/score_helper.d \
//   source/domain/language_id.d source/domain/document.d \
//   experiments/html_main_content/token_overlap.d -of=/path/to/score_helper
//
// Subcommands:
//   score_helper mojibake-diff FILE_A FILE_B
//       Exact-byte comparison (the same style external_comparator.d's
//       mojibake/scrubbed-vs-ftfy case uses). Prints "match" or
//       "mismatch <first-differing-byte-offset>".
//   score_helper text-overlap FILE_A FILE_B
//       Word-level, case-normalized, whitespace-tokenized multiset overlap
//       (experiments.html_main_content.token_overlap, issue #26's own
//       metric, reused verbatim), computed symmetrically: once treating B's
//       tokens as "gold" for A, once treating A's tokens as "gold" for B.
//       Neither file is real ground truth for the other -- this is a
//       descriptive cross-tool agreement score, not a precision/recall
//       claim against authored gold. Prints one JSON line.
//   score_helper decode-langid SIDECAR_PATH INPUT_PATH
//       Decodes a real `--stage id=language-id-detect` sidecar via
//       `domain.language_id.decodeLanguageIdentity`, exactly as
//       benchmarks/external_comparator.d's scoreScrubbedLanguageId does.
//       Prints "detected LANG CONFIDENCE" or "abstained REASON".
//   score_helper pii-summary SIDECAR_PATH
//       Reads a real `pii-four-class` `.pii-audit.json` sidecar
//       (`scrubbed-pii-audit-v1`, plain JSON) and prints one
//       "CATEGORY COUNT" line per category with at least one "reported"
//       finding, sorted by category name.
module score_helper;

import core.stdc.stdlib : exit;
import domain.document : DocumentId, SourceLocator;
import domain.language_id : LanguageDetectionStatus, decodeLanguageIdentity;
import experiments.html_main_content.token_overlap : normalized, scoreTokenOverlap,
    tokenCounts;
import std.algorithm.sorting : sort;
import std.array : array;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.file : read, readText;
import std.json : JSONValue, parseJSON;
import std.stdio : stderr, writefln, writeln;
import std.string : toStringz;

private string resolveRealPath(string path) {
    import core.stdc.stdlib : free;
    import core.sys.posix.stdlib : realpath;
    import std.string : fromStringz;

    auto resolved = realpath(path.toStringz, null);
    if (resolved is null) {
        stderr.writeln("score_helper: cannot resolve path: ", path);
        exit(2);
    }
    scope(exit) free(resolved);
    return fromStringz(resolved).idup;
}

private ubyte[] hexDecodeBytes(string hex) {
    ubyte nibble(char c) {
        if (c >= '0' && c <= '9') return cast(ubyte)(c - '0');
        if (c >= 'a' && c <= 'f') return cast(ubyte)(c - 'a' + 10);
        if (c >= 'A' && c <= 'F') return cast(ubyte)(c - 'A' + 10);
        throw new Exception("invalid hex digit: " ~ c);
    }
    if (hex.length % 2 != 0) throw new Exception("odd-length hex string");
    auto bytes = new ubyte[hex.length / 2];
    foreach (i; 0 .. bytes.length)
        bytes[i] = cast(ubyte)((nibble(hex[i * 2]) << 4) | nibble(hex[i * 2 + 1]));
    return bytes;
}

private int cmdMojibakeDiff(string[] args) {
    if (args.length != 2) {
        stderr.writeln("usage: score_helper mojibake-diff FILE_A FILE_B");
        return 2;
    }
    auto a = cast(ubyte[]) read(args[0]);
    auto b = cast(ubyte[]) read(args[1]);
    auto n = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. n) {
        if (a[i] != b[i]) {
            writefln("mismatch %d", i);
            return 0;
        }
    }
    if (a.length != b.length) {
        writefln("mismatch %d", n);
        return 0;
    }
    writeln("match");
    return 0;
}

private int cmdTextOverlap(string[] args) {
    if (args.length != 2) {
        stderr.writeln("usage: score_helper text-overlap FILE_A FILE_B");
        return 2;
    }
    auto textA = tokenCounts(normalized(readText(args[0])));
    auto textB = tokenCounts(normalized(readText(args[1])));
    auto aVsB = scoreTokenOverlap(textA, textB); // B tokens as gold for A
    auto bVsA = scoreTokenOverlap(textB, textA); // A tokens as gold for B
    JSONValue result = JSONValue([
        "aVsB": JSONValue([
            "precision": JSONValue(aVsB.precision),
            "recall": JSONValue(aVsB.recall),
            "overlap": JSONValue(aVsB.overlap),
            "extractedTotal": JSONValue(aVsB.extractedTotal),
            "goldTotal": JSONValue(aVsB.goldTotal),
        ]),
        "bVsA": JSONValue([
            "precision": JSONValue(bVsA.precision),
            "recall": JSONValue(bVsA.recall),
            "overlap": JSONValue(bVsA.overlap),
            "extractedTotal": JSONValue(bVsA.extractedTotal),
            "goldTotal": JSONValue(bVsA.goldTotal),
        ]),
    ]);
    writeln(result.toString);
    return 0;
}

// #300 Slice 2 converged language-id-detect onto the shared
// document-metadata sidecar: the sidecar file is no longer the raw
// language-id wire bytes directly, it's a document-metadata:v1/v2 JSON
// wrapper with the original wire bytes hex-encoded under
// extension[].value where key == "language-id" (see docs/cli-commands.md).
// decodeLanguageIdentity's own wire format is unchanged; only how to reach
// its bytes changed.
private ubyte[] extractLanguageIdWireBytes(string sidecarPath) {
    auto doc = parseJSON(readText(sidecarPath));
    if (auto ext = "extension" in doc.object)
        foreach (entry; ext.array)
            if (entry["key"].str == "language-id")
                return hexDecodeBytes(entry["value"].str);
    throw new Exception("no language-id extension entry in " ~ sidecarPath);
}

private int cmdDecodeLangId(string[] args) {
    if (args.length != 2) {
        stderr.writeln("usage: score_helper decode-langid SIDECAR_PATH INPUT_PATH");
        return 2;
    }
    auto sidecarPath = args[0];
    auto inputPath = args[1];
    auto expectedId = DocumentId.from(SourceLocator("local-files:v1",
        resolveRealPath(inputPath), "."));
    ubyte[32] revision = sha256Of(read(inputPath));
    try {
        auto record = decodeLanguageIdentity(extractLanguageIdWireBytes(sidecarPath), expectedId,
            revision);
        if (record.result.status == LanguageDetectionStatus.detected) {
            writefln("detected %s %f", record.result.language.to!string,
                record.result.confidence);
        } else {
            writefln("abstained %s", record.result.reason.to!string);
        }
    } catch (Exception exc) {
        writefln("error %s", typeid(exc).name);
    }
    return 0;
}

// #300 Slice 3 converged pii-four-class onto the shared document-metadata
// sidecar too: the original scrubbed-pii-audit-v1 JSON blob (still exactly
// the shape this file already knew how to read) now lives hex-encoded
// under structuredSections[].payload where sectionId == "pii-audit",
// nested inside a document-metadata:v1/v2 wrapper, instead of being the
// sidecar file's own top-level content.
private JSONValue extractPiiAuditJson(string sidecarPath) {
    auto outer = parseJSON(readText(sidecarPath));
    if (auto sections = "structuredSections" in outer.object)
        foreach (section; sections.array)
            if (section["sectionId"].str == "pii-audit")
                return parseJSON(cast(string) hexDecodeBytes(section["payload"].str));
    throw new Exception("no pii-audit structured section in " ~ sidecarPath);
}

private int cmdPiiSummary(string[] args) {
    if (args.length != 1) {
        stderr.writeln("usage: score_helper pii-summary SIDECAR_PATH");
        return 2;
    }
    auto doc = extractPiiAuditJson(args[0]);
    int[string] counts;
    if (auto unions = "unions" in doc.object) {
        foreach (u; unions.array) {
            if (u["outcome"].str != "reported") continue;
            foreach (c; u["contributors"].array)
                counts[c["category"].str] = counts.get(c["category"].str, 0) + 1;
        }
    }
    auto names = counts.keys;
    names.sort();
    foreach (name; names) writefln("%s %d", name, counts[name]);
    return 0;
}

void main(string[] args) {
    if (args.length < 2) {
        stderr.writeln("usage: score_helper SUBCOMMAND ...");
        exit(2);
    }
    auto subcommand = args[1];
    auto rest = args[2 .. $];
    int status;
    switch (subcommand) {
        case "mojibake-diff": status = cmdMojibakeDiff(rest); break;
        case "text-overlap": status = cmdTextOverlap(rest); break;
        case "decode-langid": status = cmdDecodeLangId(rest); break;
        case "pii-summary": status = cmdPiiSummary(rest); break;
        default:
            stderr.writeln("score_helper: unknown subcommand: ", subcommand);
            status = 2;
    }
    exit(status);
}
