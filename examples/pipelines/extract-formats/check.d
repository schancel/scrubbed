/// Release-active actual-binary check for the `extract-formats` structural-
/// fidelity showcase (issue #504). Mirrors `examples/pipelines/quickstart/
/// check.d`/`examples/pipelines/pii-policy/check.d`'s structure: validate
/// the corpus manifest and a handful of negative mutants, then run every
/// documented recipe against a freshly built release binary from a clean
/// temp directory and diff each output against its own pinned golden.
///
/// Covers all six `extract --format=...` modes (tree-json/markdown/
/// main-content-markdown/csv/xml/xml-tei) plus a `run --stage html-main-
/// content` include-comments=true/false pair -- see README.md's "Why
/// include-comments needs `run --stage`, not `extract`" section for why
/// that pair is not one of extract's own six formats: none of extract's
/// six format-stage registrations (verified by reading `source/effects/
/// html_tree_json_stage.d`, `html_markdown_stage.d`, `html_main_content_
/// markdown_stage.d`, `extract_formats_stage.d`) declares an
/// `include-comments` option -- only the standalone `html-main-content`
/// stage does.
///
/// XML/XML-TEI well-formedness is checked with dxml's real streaming
/// parser (already a pinned repository dependency -- `dxml==0.4.5` in
/// dub.json, and the exact mechanism `source/effects/extract_formats.d`'s
/// own unittests already use for the same purpose). CSV is decoded with a
/// real, bounded RFC 4180 parser below and cross-checked once against
/// Python's own `csv` module while authoring this corpus (see README.md);
/// a real TEI-DTD validation against pinned trafilatura==2.2.0's own
/// bundled `tei_corpus.dtd` is a separate, rerunnable evidence script
/// (`validate_tei.sh`/`validate_tei.py`, mirroring `experiments/
/// html_main_content/compare_trafilatura_extract_formats.sh`'s own
/// established idiom) -- not part of this release-active D checker, which
/// stays dependency-free (no Python/network requirement) so it can gate
/// every ordinary `dub build`/checker run.
///
/// compile with ldc2 -O, then pass scrubbed:
///   ldc2 -O -release -preview=dip1000 -i -Isource \
///     $(dub describe --data=import-paths | tr ' ' '\n' | grep dxml) \
///     -of=.dub/extract-formats-check examples/pipelines/extract-formats/check.d
///   .dub/extract-formats-check ./scrubbed
module extract_formats_check;

import std.algorithm : equal, sort;
import std.algorithm.searching : canFind, startsWith;
import std.array : replace, split;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : SpanMode, dirEntries, exists, getSize, isFile, mkdirRecurse,
    read, readText, rmdirRecurse, tempDir, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, buildPath, relativePath;
import std.process : execute;
import std.string : indexOf, strip;
import std.uuid : randomUUID;

private enum provenance = "Authored for scrubbed issue #504 by Shammah Chancellor.";
private enum documentIdPlaceholder = "<DOCUMENT_ID>";

private void need(bool condition, string label) {
    if (!condition) throw new Exception("extract-formats check: " ~ label);
}

private string digest(string path) {
    return toHexString!(LetterCase.lower)(sha256Of(read(path))).idup;
}

private void expectRejected(string label, void delegate() mutation) {
    bool rejected;
    try mutation();
    catch (Exception) rejected = true;
    need(rejected, "negative mutant accepted: " ~ label);
}

private string[] strings(JSONValue value) {
    string[] result;
    foreach (entry; value.array) result ~= entry.str;
    return result;
}

private string[] filesBelow(string root, string relativeRoot) {
    string[] result;
    auto directory = buildPath(root, relativeRoot);
    foreach (entry; dirEntries(directory, SpanMode.depth)) {
        if (entry.isFile) {
            auto local = relativePath(entry.name, directory);
            result ~= relativeRoot.length ? relativeRoot ~ "/" ~ local : local;
        }
    }
    result.sort;
    return result;
}

/// Bounded, deterministic hex decode of the sidecar's structured extension
/// value -- identical algorithm to `pii-policy/check.d`'s own `decodeHex`
/// (that one is `private` to its own module, so it is restated here rather
/// than shared across example checkers, matching this repository's own
/// existing per-example-checker granularity).
private ubyte[] decodeHex(string hex) {
    need(hex.length % 2 == 0, "odd-length hex payload");
    auto result = new ubyte[hex.length / 2];
    foreach (i; 0 .. result.length) {
        int high = hexNibble(hex[i * 2]);
        int low = hexNibble(hex[i * 2 + 1]);
        result[i] = cast(ubyte) ((high << 4) | low);
    }
    return result;
}

private int hexNibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    need(false, "non-lowercase-hex byte in structured extension payload");
    assert(0);
}

// ==== Real, bounded RFC 4180 decoder (tab-delimited, one row) ============
//
// Phobos has no CSV parser. This is the same algorithm independently
// cross-checked against Python's real `csv` module while authoring this
// corpus (see README.md) -- not a stub that merely "doesn't crash": it
// actually reverses `effects.extract_formats.csvField`'s own quoting
// (surrounding double quotes whenever a field contains a tab/quote/
// newline, with an embedded quote doubled), and this checker asserts the
// exact decoded field count and content below, not just that decoding
// completed.
private string[] parseCsvRow(string text) {
    string body = text;
    if (body.length && body[$ - 1] == '\n') body = body[0 .. $ - 1];
    string[] fields;
    size_t i;
    while (true) {
        string field;
        if (i < body.length && body[i] == '"') {
            ++i;
            while (true) {
                need(i < body.length, "unterminated quoted CSV field");
                if (body[i] == '"') {
                    if (i + 1 < body.length && body[i + 1] == '"') {
                        field ~= '"';
                        i += 2;
                        continue;
                    }
                    ++i;
                    break;
                }
                field ~= body[i];
                ++i;
            }
        } else {
            while (i < body.length && body[i] != '\t') {
                field ~= body[i];
                ++i;
            }
        }
        fields ~= field;
        if (i < body.length && body[i] == '\t') {
            ++i;
            continue;
        }
        break;
    }
    return fields;
}

/// tree-json wraps content with `document.id`/`source.sourceKey`, both
/// derived from `--input`'s own resolved *absolute* path (see `runExtract`/
/// `serializeTreeJson`) -- not reproducible byte-for-byte across machines
/// or temp directories, the identical non-determinism `pii-policy/check.d`'s
/// `document_id` and `clean-web-document/check.d`'s `documentId` normalize
/// away. Every other byte (the whole real parsed tree, in document order)
/// is fully content-deterministic and diffed exactly below.
private string replaceField(string text, string marker, string placeholder) {
    auto start = text.indexOf(marker);
    need(start >= 0, "tree-json missing expected field: " ~ marker);
    auto valueStart = start + marker.length;
    auto valueEnd = text.indexOf("\"", valueStart);
    need(valueEnd > valueStart, "tree-json malformed field: " ~ marker);
    return text[0 .. valueStart] ~ placeholder ~ text[valueEnd .. $];
}

private string normalizeTreeJson(string text) {
    auto result = replaceField(text, `"documentId":"`, documentIdPlaceholder);
    result = replaceField(result, `"sourceKey":"`, "<SOURCE_KEY>");
    return result;
}

/// Well-formedness proof using dxml's real streaming parser -- the same
/// mechanism `effects.extract_formats`'s own unittests already use
/// (`assertWellFormedXml`); `parseXML` throws on anything malformed.
private void assertWellFormedXml(string xml, string label) {
    import dxml.parser : parseXML, simpleXML, XMLParsingException;
    try {
        foreach (node; parseXML!simpleXML(xml)) {}
    } catch (XMLParsingException error) {
        throw new Exception(label ~ ": not well-formed XML: " ~ error.msg);
    }
}

private void validateManifest(string repository, JSONValue manifest) {
    need(manifest["schema"].str == "scrubbed.extract-formats-corpus.v1", "manifest schema");
    auto licensePath = manifest["licenseFile"].str;
    need(licensePath == "examples/corpus/extract-formats/LICENSE.txt" &&
        digest(buildPath(repository, licensePath)) ==
            "d05e83eb1213daac7371eee9bb40c8d06e767e37dc38f6f10b8f0b06d72708e0",
        "exact corpus license");
    need(!manifest["claims"]["trainingReady"].boolean &&
        !manifest["claims"]["extractExposesIncludeComments"].boolean &&
        !manifest["claims"]["extractExposesExpandedMetadata"].boolean,
        "extract-formats corpus must not claim reachability the extract command does not have");

    string[] declared;
    foreach (artifact; manifest["artifacts"].array) {
        auto path = artifact["path"].str;
        need(path.startsWith("examples/corpus/extract-formats/inputs/") ||
            path.startsWith("examples/corpus/extract-formats/expected/"),
            "artifact path escape: " ~ path);
        need(!path.canFind("..") && artifact["mediaType"].str.length != 0,
            "unsafe path or missing media type: " ~ path);
        need(artifact["provenance"].str == provenance ||
            artifact["provenance"].str.startsWith(
                "Generated from the authored issue #504 input"),
            "missing attribution/provenance: " ~ path);
        need(artifact["license"].str == "MIT", "missing artifact license: " ~ path);
        need(digest(buildPath(repository, path)) == artifact["sha256"].str,
            "artifact hash drift: " ~ path);
        declared ~= path;
    }
    declared.sort;
    auto actual = filesBelow(repository, "examples/corpus/extract-formats/inputs") ~
        filesBelow(repository, "examples/corpus/extract-formats/expected");
    actual.sort;
    need(declared.equal(actual), "undeclared or missing corpus artifact");

    auto recipes = manifest["recipes"].array;
    need(recipes.length == 8, "recipe count");
    string[][string] expectedArguments = [
        "tree-json": ["extract", "--input", "${INPUT}", "--output", "${OUTPUT}", "--format", "tree-json"],
        "markdown": ["extract", "--input", "${INPUT}", "--output", "${OUTPUT}", "--format", "markdown"],
        "main-content-markdown": ["extract", "--input", "${INPUT}", "--output", "${OUTPUT}", "--format", "main-content-markdown"],
        "csv": ["extract", "--input", "${INPUT}", "--output", "${OUTPUT}", "--format", "csv"],
        "xml": ["extract", "--input", "${INPUT}", "--output", "${OUTPUT}", "--format", "xml"],
        "xml-tei": ["extract", "--input", "${INPUT}", "--output", "${OUTPUT}", "--format", "xml-tei"],
        "comments-on": ["run", "--input", "${INPUT}", "--output", "${OUTPUT}", "--sidecar-output", "${SIDECAR}",
            "--stage", "main=html-main-content", "--stage", "pub=document-metadata-publish"],
        "comments-off": ["run", "--input", "${INPUT}", "--output", "${OUTPUT}", "--sidecar-output", "${SIDECAR}",
            "--stage", "main=html-main-content", "--stage-option", "include-comments=boolean:false",
            "--stage", "pub=document-metadata-publish"],
    ];
    bool[string] seen;
    foreach (recipe; recipes) {
        auto id = recipe["id"].str;
        need(recipe["expectedExit"].integer == 0, "recipe " ~ id ~ " must exit 0");
        need((id in expectedArguments) !is null, "unexpected recipe id: " ~ id);
        need(strings(recipe["arguments"]).equal(expectedArguments[id]), "stale recipe: " ~ id);
        seen[id] = true;
    }
    need(seen.length == 8, "every expected recipe id must appear exactly once");

    ulong corpusBytes;
    foreach (entry; dirEntries(buildPath(repository, "examples/corpus/extract-formats"), SpanMode.depth))
        if (entry.isFile) corpusBytes += getSize(entry.name);
    need(corpusBytes < 1024 * 1024, "corpus must remain below 1 MiB");
}

private void negativeMutants(string repository, string manifestText) {
    expectRejected("hash drift", {
        validateManifest(repository, parseJSON(manifestText.replace(
            "188df275f10031bb5199f648c647b0f5e94666e1f7064e7ff5650ccd6e390494",
            "000000000010031bb5199f648c647b0f5e94666e1f7064e7ff5650ccd6e390494")));
    });
    expectRejected("missing attribution", {
        validateManifest(repository, parseJSON(manifestText.replace(provenance, "")));
    });
    expectRejected("missing license", {
        validateManifest(repository, parseJSON(manifestText.replace(`"license": "MIT"`,
            `"license": ""`)));
    });
    expectRejected("path escape", {
        validateManifest(repository, parseJSON(manifestText.replace(
            "examples/corpus/extract-formats/inputs/field-notes.html",
            "../../../etc/passwd")));
    });
    expectRejected("false training-ready claim", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"trainingReady": false`, `"trainingReady": true`)));
    });
    expectRejected("false extract-exposes-include-comments claim", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"extractExposesIncludeComments": false`, `"extractExposesIncludeComments": true`)));
    });
    expectRejected("false extract-exposes-expanded-metadata claim", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"extractExposesExpandedMetadata": false`, `"extractExposesExpandedMetadata": true`)));
    });
    expectRejected("stale recipe format", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"--format", "xml-tei"`, `"--format", "xml"`)));
    });
}

/// Every structural element the fixture carries must round-trip as real
/// Markdown syntax -- not merely "the run didn't crash". Shared between the
/// whole-page and main-content-scoped golden text (both carry every element
/// inside the selected `<article>`; only the surrounding chrome/comments
/// differ -- see `checkMarkdownScoping` below for that half).
private void checkMarkdownStructuralFidelity(string text, string label) {
    need(text.canFind("# Delta Survey Field Notes"), label ~ ": heading did not round-trip");
    need(text.canFind("**steady**"), label ~ ": bold did not round-trip");
    need(text.canFind("*focused*"), label ~ ": italic did not round-trip");
    need(text.canFind("[a full research permit]") && text.canFind("https://example.com/permits"),
        label ~ ": link did not round-trip");
    need(text.canFind("![The survey team") && text.canFind("https://example.com/images/survey-team.jpg"),
        label ~ ": image did not round-trip");
    need(text.canFind("- Salinity rose") && text.canFind("- Sediment cores"),
        label ~ ": list did not round-trip");
    need(text.canFind("> The western channel"), label ~ ": blockquote did not round-trip");
    need(text.canFind("| Transect | Depth") && text.canFind("|---|---|---|"),
        label ~ ": table did not round-trip");
    need(text.canFind("```\nstation,depth_m,salinity_ppt"),
        label ~ ": code block did not round-trip");
}

private void checkMarkdownScoping(string wholePage, string mainContent) {
    need(wholePage.canFind("Home About Contact"), "whole-page markdown must include nav chrome");
    need(wholePage.canFind("## Comments") && wholePage.canFind("Great writeup"),
        "whole-page markdown must include the comment section");
    need(wholePage.canFind("Copyright 2026 Delta Survey Project"),
        "whole-page markdown must include footer chrome");
    need(!mainContent.canFind("Home About Contact"),
        "main-content-markdown must exclude nav chrome");
    need(!mainContent.canFind("Great writeup"),
        "main-content-markdown must exclude the comment section (a sibling of the selected node)");
    need(!mainContent.canFind("Copyright 2026 Delta Survey Project"),
        "main-content-markdown must exclude footer chrome");
}

private void checkXmlStructuralFidelity(string xml, string label) {
    need(xml.canFind("<heading level=\"1\">Delta Survey Field Notes</heading>"),
        label ~ ": heading did not round-trip");
    need(xml.canFind("<bold>steady</bold>"), label ~ ": bold did not round-trip");
    need(xml.canFind("<italic>focused</italic>"), label ~ ": italic did not round-trip");
    need(xml.canFind("<link href=\"https://example.com/permits\">a full research permit</link>"),
        label ~ ": link did not round-trip");
    need(xml.canFind("<image src=\"https://example.com/images/survey-team.jpg\""),
        label ~ ": image did not round-trip");
    need(xml.canFind("<list ordered=\"false\">") && xml.canFind("<item>Salinity rose"),
        label ~ ": list did not round-trip");
    need(xml.canFind("<quote>") && xml.canFind("The western channel behaves"),
        label ~ ": blockquote did not round-trip");
    need(xml.canFind("<caption>Selected transect depth readings</caption>") &&
        xml.canFind("<cell header=\"true\">Transect</cell>") && xml.canFind("<cell>2.1</cell>"),
        label ~ ": table did not round-trip with real <table>/<row>/<cell> structure");
    need(xml.canFind("<code>station,depth_m,salinity_ppt"), label ~ ": code block did not round-trip");
    need(xml.canFind("<comments>") && xml.canFind("Great writeup"),
        label ~ ": comment section must be present (default include-comments=true)");
}

private void checkXmlTeiStructuralFidelity(string tei) {
    need(tei.canFind("<TEI xmlns=\"http://www.tei-c.org/ns/1.0\">"), "TEI root element missing");
    need(tei.canFind("<ab rend=\"h1\" type=\"header\">Delta Survey Field Notes</ab>"),
        "TEI: heading did not round-trip");
    need(tei.canFind("<hi rend=\"bold\">steady</hi>"), "TEI: bold did not round-trip");
    need(tei.canFind("<hi rend=\"italic\">focused</hi>"), "TEI: italic did not round-trip");
    need(tei.canFind("<ref target=\"https://example.com/permits\">a full research permit</ref>"),
        "TEI: link did not round-trip");
    need(tei.canFind("<graphic url=\"https://example.com/images/survey-team.jpg\"/>"),
        "TEI: image did not round-trip");
    need(tei.canFind("<list rend=\"ul\">") && tei.canFind("<item>Salinity rose"),
        "TEI: list did not round-trip");
    need(tei.canFind("<quote>") && tei.canFind("The western channel behaves"),
        "TEI: blockquote did not round-trip");
    // Documented, disclosed non-applicable combination: TEI has no
    // table/row/cell DTD declaration (see extract_formats.d's own doc
    // comment on renderTeiTable), so a table degrades to <list rend="table">
    // here -- never <table>/<row>/<cell>, which pinned trafilatura's own
    // bundled DTD rejects.
    need(tei.canFind("<list rend=\"table\">"), "TEI: table must degrade to <list rend=\"table\">");
    need(!tei.canFind("<table>") && !tei.canFind("<row>") && !tei.canFind("<cell"),
        "TEI: must never emit non-DTD-declared <table>/<row>/<cell>");
    need(tei.canFind("<hi rend=\"code\">station,depth_m,salinity_ppt"),
        "TEI: code block did not round-trip");
    need(tei.canFind("<div type=\"comments\">") && tei.canFind("Great writeup"),
        "TEI: comment section must be present (default include-comments=true)");
}

private void checkCsvStructuralFidelity(string csv) {
    auto fields = parseCsvRow(csv);
    need(fields.length == 11,
        "csv must have trafilatura's own real 11-column schema, got " ~ fields.length.to!string);
    need(fields[0] == "null" && fields[1] == "null" && fields[2] == "null" && fields[3] == "null",
        "url/id/fingerprint/hostname must be 'null' for a local extract invocation");
    need(fields[4] == "Delta Survey Field Notes", "title column must carry the real <title>");
    need(fields[5] == "null" && fields[6] == "null", "image/date columns must be 'null'");
    need(fields[7].canFind("survey team") && fields[7].canFind(`"reference dataset"`),
        "text column must carry the real flattened content, including the round-tripped embedded quote");
    // Documented, disclosed non-applicable combination: CSV has no table
    // structure at all -- the table's cell text is folded into the same
    // flat text column as everything else (see csvRow's own doc comment).
    need(fields[7].canFind("Transect") || fields[7].canFind("18"),
        "text column must still carry the table's real cell text, even though CSV has no table structure");
    need(fields[8].canFind("Great writeup") && fields[8].canFind("Station four's layering"),
        "comments column must carry the real detected comment section (default include-comments=true)");
    need(fields[9] == "null" && fields[10] == "null", "license/pagetype columns must be 'null'");
}

private void runFormatRecipes(string repository, string executable, string inputPath, string root) {
    auto expected = buildPath(repository, "examples/corpus/extract-formats/expected");
    string[string] goldenFor = [
        "tree-json": "field-notes.tree.json",
        "markdown": "field-notes.whole-page.md",
        "main-content-markdown": "field-notes.main-content.md",
        "csv": "field-notes.csv",
        "xml": "field-notes.xml",
        "xml-tei": "field-notes.tei.xml",
    ];
    string[string] outputBytes;
    foreach (format; ["tree-json", "markdown", "main-content-markdown", "csv", "xml", "xml-tei"]) {
        auto outputPath = buildPath(root, format ~ "-out");
        auto result = execute([executable, "extract", "--input", inputPath, "--output", outputPath,
            "--format", format]);
        need(result.status == 0, format ~ " recipe failed (exit " ~ result.status.to!string ~
            "): " ~ result.output);
        auto actualText = readText(outputPath);
        if (format == "tree-json") {
            // documentId/sourceKey are path-dependent, not content-dependent
            // -- see `normalizeTreeJson`'s own doc comment.
            auto expectedText = readText(buildPath(expected, goldenFor[format]));
            need(normalizeTreeJson(actualText) == expectedText,
                "tree-json: normalized output differs from pinned golden");
        } else {
            auto actualBytes = cast(const(ubyte)[]) read(outputPath);
            auto expectedBytes = cast(const(ubyte)[]) read(buildPath(expected, goldenFor[format]));
            need(actualBytes == expectedBytes, format ~ ": output bytes differ from pinned golden");
        }
        outputBytes[format] = actualText;
    }

    // Structural-fidelity proofs, on the real bytes just produced by the
    // real binary (not merely re-reading the golden file) -- every element
    // this fixture carries must be independently verified present and
    // correctly shaped for the formats that can represent it.
    checkMarkdownStructuralFidelity(outputBytes["markdown"], "markdown (whole page)");
    checkMarkdownStructuralFidelity(outputBytes["main-content-markdown"], "main-content-markdown");
    checkMarkdownScoping(outputBytes["markdown"], outputBytes["main-content-markdown"]);

    assertWellFormedXml(outputBytes["xml"], "xml");
    checkXmlStructuralFidelity(outputBytes["xml"], "xml");
    assertWellFormedXml(outputBytes["xml-tei"], "xml-tei");
    checkXmlTeiStructuralFidelity(outputBytes["xml-tei"]);

    checkCsvStructuralFidelity(outputBytes["csv"]);

    // tree-json: the whole raw parsed tree, unscoped by main-content
    // selection -- must parse as real JSON and must still carry the
    // comment section and the chrome the main-content-scoped formats
    // exclude (it is not main-content-aware at all).
    auto tree = parseJSON(outputBytes["tree-json"]);
    need(tree.type == JSONType.object || tree.type == JSONType.array,
        "tree-json must parse as real JSON");
    need(outputBytes["tree-json"].canFind("comment") || outputBytes["tree-json"].canFind("comments"),
        "tree-json (the whole parsed tree) must still carry the comment-section markup");
    need(outputBytes["tree-json"].canFind("Home About Contact"),
        "tree-json (the whole parsed tree) must still carry nav chrome (not main-content-scoped)");
}

/// `html-main-content`'s own `include-comments` option (issue #475), NOT
/// one of extract's six format modes -- see README.md's "Why
/// include-comments needs `run --stage`" section. Runs the true opt-in
/// default and the true opt-out, diffs each primary output and normalized
/// sidecar against its own pinned golden, and positively proves both
/// directions: the opt-in sidecar carries a real "comments" extension
/// field, the opt-out sidecar's extension array is empty, and the primary
/// content -- unaffected either way -- is byte-identical between the two.
private void runCommentsToggleRecipes(string repository, string executable, string inputPath,
        string root) {
    auto expected = buildPath(repository, "examples/corpus/extract-formats/expected");

    struct ToggleResult { string outputPath; string documentId; string normalizedSidecar; JSONValue wire; }

    ToggleResult run(string label, bool includeComments) {
        auto outputPath = buildPath(root, label ~ "-out.txt");
        auto sidecarPath = buildPath(root, label ~ "-sidecar.json");
        string[] command = [executable, "run", "--input", inputPath, "--output", outputPath,
            "--sidecar-output", sidecarPath, "--stage", "main=html-main-content"];
        if (!includeComments)
            command ~= ["--stage-option", "include-comments=boolean:false"];
        command ~= ["--stage", "pub=document-metadata-publish"];
        auto result = execute(command);
        need(result.status == 0, label ~ " recipe failed (exit " ~ result.status.to!string ~
            "): " ~ result.output);

        auto wireText = readText(sidecarPath);
        auto wire = parseJSON(wireText);
        need(wire["version"].str == "document-metadata:v1", label ~ " sidecar version");
        auto documentId = wire["documentId"].str;
        need(documentId.startsWith("doc:v1:") && documentId.length == 71,
            label ~ " document ID shape");
        auto normalized = wireText.replace(documentId, documentIdPlaceholder);
        return ToggleResult(outputPath, documentId, normalized, wire);
    }

    auto on = run("comments-on", true);
    auto off = run("comments-off", false);

    auto expectedOnBytes = read(buildPath(expected, "field-notes.comments-on.txt"));
    auto expectedOffBytes = read(buildPath(expected, "field-notes.comments-off.txt"));
    need(cast(const(ubyte)[]) read(on.outputPath) == expectedOnBytes,
        "comments-on: primary output differs from pinned golden");
    need(cast(const(ubyte)[]) read(off.outputPath) == expectedOffBytes,
        "comments-off: primary output differs from pinned golden");
    need(cast(const(ubyte)[]) read(on.outputPath) == cast(const(ubyte)[]) read(off.outputPath),
        "include-comments must gate comment detection only, never the primary content");

    auto expectedOnSidecar = readText(buildPath(expected, "field-notes.comments-on.sidecar.json")).strip;
    auto expectedOffSidecar = readText(buildPath(expected, "field-notes.comments-off.sidecar.json")).strip;
    need(on.normalizedSidecar.strip == expectedOnSidecar,
        "comments-on: normalized sidecar differs from pinned golden");
    need(off.normalizedSidecar.strip == expectedOffSidecar,
        "comments-off: normalized sidecar differs from pinned golden");

    // Positive proof of the opt-in default: a real "comments" extension
    // field, sourced from html-main-content.
    auto onExtension = on.wire["extension"].array;
    need(onExtension.length == 1 && onExtension[0]["key"].str == "comments" &&
        onExtension[0]["sourceStage"].str == "html-main-content",
        "comments-on: sidecar must carry exactly one 'comments' extension field");
    auto decodedComments = cast(string) decodeHex(onExtension[0]["value"].str);
    need(decodedComments.canFind("Great writeup") && decodedComments.canFind("Station four's layering"),
        "comments-on: extension field must carry the real detected comment text");

    // Positive proof of the opt-out: comments are not merely filtered out
    // after the fact, they are never scanned for at all -- the extension
    // array is empty, not present-but-suppressed.
    need(off.wire["extension"].array.length == 0,
        "comments-off: include-comments=false must add no extension field at all");
}

private void runRecipes(string repository, string executable) {
    auto root = buildPath(tempDir, "scrubbed-extract-formats-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope (exit) if (exists(root)) rmdirRecurse(root);

    // A clean temp directory: the fixture is copied in, never read from the
    // repository checkout, so the checker exercises the same path a
    // downstream user copying the example would take.
    auto inputPath = buildPath(root, "field-notes.html");
    write(inputPath, read(buildPath(repository,
        "examples/corpus/extract-formats/inputs/field-notes.html")));

    runFormatRecipes(repository, executable, inputPath, root);
    runCommentsToggleRecipes(repository, executable, inputPath, root);
}

int main(string[] args) {
    need(args.length == 2 || args.length == 3,
        "usage: check <release executable> [repository root]");
    auto executable = absolutePath(args[1]);
    auto repository = absolutePath(args.length == 3 ? args[2] : ".");
    auto manifestPath = buildPath(repository, "examples/corpus/extract-formats/manifest.json");
    auto manifestText = readText(manifestPath);
    auto manifest = parseJSON(manifestText);
    validateManifest(repository, manifest);
    negativeMutants(repository, manifestText);
    runRecipes(repository, executable);
    import std.stdio : writeln;
    writeln("extract-formats check: manifest, mutants, all six extract --format modes " ~
        "(byte-diff + structural fidelity + XML well-formedness), and the include-comments " ~
        "opt-in/opt-out pair (run --stage html-main-content) all pass");
    return 0;
}
