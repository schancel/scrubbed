// Release-active, D-only field and stage goldens for metadata-json:v1.
module experiments.metadata.check;

import composition.compiler : compileJob;
import composition.executor : runCompiledStage;
import content.pieces : Content, ContentPiece;
import domain.document : Document, OutputName, SourceLocator;
import effects.html_metadata : extractHtmlMetadata, HtmlMetadata,
    MetadataCandidate, serializeHtmlMetadata;
import effects.html_metadata_stage;
import effects.html_tree : HtmlAttribute, HtmlNode, HtmlNodeKind, HtmlTree,
    maxRawBytes, parseHtml;
import stages.contract : DecisionKind, ResourceDeclaration, StageDeclaration,
    StageDocument;
import job.json : parseJobJson;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.stdio : writeln;
import std.string : indexOf;

private void check(bool condition, string message) {
    if (!condition) throw new Exception(message);
}

private void checkCandidates(JSONValue field, string[] values, string[] rules,
    long[] nodes) {
    auto candidates = field["candidates"].array;
    check(candidates.length == values.length && values.length == rules.length &&
        rules.length == nodes.length, "candidate count mismatch");
    foreach (i, candidate; candidates)
        check(candidate["value"].str == values[i] &&
            candidate["rule"].str == rules[i] &&
            candidate["node"].integer == nodes[i], "candidate golden mismatch");
}

private string bytes(Content content) {
    string result;
    foreach (piece; content.pieces()) foreach (i; 0 .. piece.size)
        result ~= cast(char) piece.at(i);
    return result;
}

private struct Fixture {
    string html;
    string[4] expected;
    string[4] status;
}

void main() {
    Fixture[] heldOut = [
        Fixture(`<head><title>Fallback</title><meta property="og:title" content="Café &amp; Tea">
            <meta name="author" content="Ana &quot;Q&quot;"><meta name="date" content="2024-02-29">
            <link rel="canonical" href="https://example.org/a?x=1&amp;y=2">
            <meta property="og:url" content="https://elsewhere.org/a"></head>`,
            ["Café & Tea", `Ana "Q"`, "2024-02-29", "https://example.org/a?x=1&y=2"],
            ["selected", "selected", "selected", "selected"]),
        Fixture(`<head><meta property="og:title" content="One"><meta property="og:title" content="Two">
            <meta name="author" content="A"><meta name="author" content="B">
            <meta name="date" content="2024-01-01"><meta name="date" content="2024-01-02">
            <link rel="canonical" href="https://a.test/"><link rel="canonical" href="https://b.test/"></head>`,
            ["", "", "", ""], ["ambiguous", "ambiguous", "ambiguous", "ambiguous"]),
        Fixture(`<head><title>Solo</title><meta property="og:title" content="Solo">
            <meta name="author" content=" Zoë  Smith "><meta property="article:published_time" content="2024-03-05T10:11:12Z">
            <meta property="og:url" content="https://example.test/story"></head>`,
            ["Solo", "Zoë Smith", "2024-03-05", "https://example.test/story"],
            ["selected", "selected", "selected", "selected"]),
        Fixture(`<head><meta name="date" content="2024-02-30"><link rel="canonical" href="/relative">
            <meta name="author" content=" "></head>`,
            ["", "", "", ""], ["absent", "invalid", "invalid", "invalid"]),
        Fixture(`<head><title>Real</title><meta name="og:title" content="Wrong">
            <meta property="author" content="Wrong"><meta name="article:published_time" content="2024-01-01">
            <meta property="date" content="2024-01-02"><meta name="og:url" content="https://wrong.test/"></head>`,
            ["Real", "", "", ""], ["selected", "absent", "absent", "absent"]),
        Fixture(`<head><link rel="canonical" href="https://:443/path">
            <meta property="og:url" content="https://fallback.test/path"></head>`,
            ["", "", "", "https://fallback.test/path"],
            ["absent", "absent", "absent", "selected"]),
        Fixture(`<head><link rel="canonical" href="https://example.test:bad/path">
            <meta property="og:url" content="https://fallback.test/second"></head>`,
            ["", "", "", "https://fallback.test/second"],
            ["absent", "absent", "absent", "selected"]),
        Fixture(`<head><link rel="canonical" href="https://[:::]/">
            <meta property="og:url" content="https://fallback.test/malformed"></head>`,
            ["", "", "", "https://fallback.test/malformed"],
            ["absent", "absent", "absent", "selected"]),
        Fixture(`<head><link rel="canonical" href="https://[2001:db8::1]/">
            <meta property="og:url" content="https://fallback.test/ipv6"></head>`,
            ["", "", "", "https://fallback.test/ipv6"],
            ["absent", "absent", "absent", "selected"]),
        Fixture(`<head><link rel="canonical" href="https://[:]/"></head>`,
            ["", "", "", ""], ["absent", "absent", "absent", "invalid"]),
    ];
    auto document = Document(SourceLocator("fixture:v1", "/PRIVATE/secret", "record"),
        OutputName("record.metadata.json"));
    HtmlTree wireTree;
    wireTree.nodes = [
        HtmlNode(HtmlNodeKind.element, size_t.max, "head"),
        HtmlNode(HtmlNodeKind.element, 0, "meta", "",
            [HtmlAttribute("property", "og:title"), HtmlAttribute("content", "X")])
    ];
    auto exact = `{"version":"metadata-json:v1","documentId":"` ~ document.id.text ~
        `","fields":{"title":{"status":"selected","value":"X","rule":"og:title","node":1,"conflict":false,"invalidEvidence":false,"overflow":false,"candidates":[{"value":"X","rule":"og:title","node":1}]},` ~
        `"author":{"status":"absent","value":null,"rule":null,"node":null,"conflict":false,"invalidEvidence":false,"overflow":false,"candidates":[]},` ~
        `"date":{"status":"absent","value":null,"rule":null,"node":null,"conflict":false,"invalidEvidence":false,"overflow":false,"candidates":[]},` ~
        `"url":{"status":"absent","value":null,"rule":null,"node":null,"conflict":false,"invalidEvidence":false,"overflow":false,"candidates":[]}}}` ~ "\n";
    check(serializeHtmlMetadata(document.id, extractHtmlMetadata(wireTree)) == exact,
        "exact canonical wire mismatch");
    HtmlMetadata ordinalMetadata;
    ordinalMetadata.title.status = "selected";
    ordinalMetadata.title.value = "X";
    ordinalMetadata.title.rule = "r";
    ordinalMetadata.title.node = 8191;
    foreach (node; [size_t(0), 9, 10, 99, 100, 8191])
        ordinalMetadata.title.candidates ~= MetadataCandidate("X", "r", node);
    ordinalMetadata.author.status = "absent";
    ordinalMetadata.date.status = "absent";
    ordinalMetadata.url.status = "absent";
    auto ordinalExact = `{"version":"metadata-json:v1","documentId":"` ~
        document.id.text ~ `","fields":{"title":{"status":"selected","value":"X",` ~
        `"rule":"r","node":8191,"conflict":false,"invalidEvidence":false,` ~
        `"overflow":false,"candidates":[{"value":"X","rule":"r","node":0},` ~
        `{"value":"X","rule":"r","node":9},{"value":"X","rule":"r","node":10},` ~
        `{"value":"X","rule":"r","node":99},{"value":"X","rule":"r","node":100},` ~
        `{"value":"X","rule":"r","node":8191}]},` ~
        `"author":{"status":"absent","value":null,"rule":null,"node":null,` ~
        `"conflict":false,"invalidEvidence":false,"overflow":false,"candidates":[]},` ~
        `"date":{"status":"absent","value":null,"rule":null,"node":null,` ~
        `"conflict":false,"invalidEvidence":false,"overflow":false,"candidates":[]},` ~
        `"url":{"status":"absent","value":null,"rule":null,"node":null,` ~
        `"conflict":false,"invalidEvidence":false,"overflow":false,"candidates":[]}}}` ~
        "\n";
    auto ordinalWire = serializeHtmlMetadata(document.id, ordinalMetadata);
    check(ordinalWire == ordinalExact, "metadata ordinal transition bytes");
    auto metadataSpec = parseJobJson(`{"version":3,"stages":[{"id":"metadata",` ~
        `"implementation":"html-metadata","options":{},"filters":[]}]}`);
    auto plan = compileJob(metadataSpec);
    check(plan.stages.length == 1 && plan.stages[0].declaration.key == "html-metadata",
        "stage not registered");
    size_t[4] selected, correct, abstained;
    foreach (fixtureIndex, fixture; heldOut) {
        auto parsed = parseHtml(cast(const(ubyte)[]) fixture.html);
        check(parsed.isParsed, "fixture parse failed");
        auto metadata = extractHtmlMetadata(parsed.tree);
        auto direct = serializeHtmlMetadata(document.id, metadata);
        check(direct == serializeHtmlMetadata(document.id, extractHtmlMetadata(parsed.tree)),
            "non-deterministic output");
        auto input = StageDocument(document,
            new Content([ContentPiece.own(cast(const(ubyte)[]) fixture.html)]));
        auto transform = plan.stages[0].transform;
        auto decision = transform(input);
        check(decision.kind == DecisionKind.map, "stage did not map");
        auto output = runCompiledStage([input], plan.stages[0]);
        check(output.events.length == 1 && output.events[0].payload.document.id == document.id,
            "DocumentId changed");
        check(bytes(output.events[0].payload.content) == direct, "stage wire differs");
        check(direct.indexOf("/PRIVATE/secret") < 0 && direct.indexOf("record.metadata.json") < 0,
            "source or path leaked");
        auto json = parseJSON(direct);
        check(json["version"].str == "metadata-json:v1" &&
            json["documentId"].str == document.id.text, "wire header mismatch");
        if (fixtureIndex == 0) {
            check(json["fields"]["title"]["rule"].str == "og:title" &&
                json["fields"]["title"]["candidates"].array.length == 2 &&
                json["fields"]["title"]["conflict"].boolean &&
                json["fields"]["url"]["rule"].str == "link:canonical" &&
                json["fields"]["url"]["candidates"].array.length == 2 &&
                json["fields"]["url"]["conflict"].boolean &&
                json["fields"]["author"]["rule"].str == "author" &&
                json["fields"]["date"]["rule"].str == "date",
                "field precedence or source evidence mismatch");
            checkCandidates(json["fields"]["title"], ["Fallback", "Café & Tea"],
                ["title", "og:title"], [2, 4]);
            checkCandidates(json["fields"]["author"], [`Ana "Q"`], ["author"], [6]);
            checkCandidates(json["fields"]["date"], ["2024-02-29"], ["date"], [7]);
            checkCandidates(json["fields"]["url"],
                ["https://example.org/a?x=1&y=2", "https://elsewhere.org/a"],
                ["link:canonical", "og:url"], [9, 11]);
        }
        if (fixtureIndex == 1) {
            checkCandidates(json["fields"]["title"], ["One", "Two"],
                ["og:title", "og:title"], [2, 3]);
            checkCandidates(json["fields"]["author"], ["A", "B"],
                ["author", "author"], [5, 6]);
            checkCandidates(json["fields"]["date"], ["2024-01-01", "2024-01-02"],
                ["date", "date"], [8, 9]);
            checkCandidates(json["fields"]["url"], ["https://a.test/", "https://b.test/"],
                ["link:canonical", "link:canonical"], [11, 12]);
        }
        if (fixtureIndex == 2)
            check(!json["fields"]["title"]["conflict"].boolean &&
                json["fields"]["title"]["candidates"].array.length == 2 &&
                json["fields"]["date"]["rule"].str == "article:published_time" &&
                json["fields"]["url"]["rule"].str == "og:url",
                "duplicate or fallback precedence mismatch");
        if (fixtureIndex == 3)
            check(json["fields"]["date"]["invalidEvidence"].boolean &&
                json["fields"]["url"]["invalidEvidence"].boolean,
                "invalid evidence flag missing");
        if (fixtureIndex == 4)
            check(json["fields"]["title"]["candidates"].array.length == 1 &&
                json["fields"]["title"]["rule"].str == "title" &&
                json["fields"]["author"]["candidates"].array.length == 0 &&
                json["fields"]["date"]["candidates"].array.length == 0 &&
                json["fields"]["url"]["candidates"].array.length == 0,
                "wrong-kind attributes became evidence");
        if (fixtureIndex >= 5 && fixtureIndex <= 8)
            check(json["fields"]["url"]["rule"].str == "og:url" &&
                json["fields"]["url"]["candidates"].array.length == 1 &&
                json["fields"]["url"]["invalidEvidence"].boolean,
                "invalid canonical did not fall back");
        foreach (i, key; ["title", "author", "date", "url"]) {
            auto field = json["fields"][key];
            check(field["status"].str == fixture.status[i], key ~ " status mismatch");
            if (fixture.status[i] == "selected") {
                ++selected[i];
                check(field["value"].str == fixture.expected[i], key ~ " selected value mismatch");
                ++correct[i];
                check(field["rule"].str.length && field["candidates"].array.length,
                    key ~ " provenance missing");
            } else {
                ++abstained[i];
                check(field["value"].type == JSONType.null_, key ~ " did not abstain");
            }
            if (fixture.status[i] == "ambiguous")
                check(field["conflict"].boolean && field["candidates"].array.length == 2,
                    key ~ " conflict evidence missing");
        }
    }
    foreach (count; [16, 17]) {
        string html = "<head>";
        foreach (_; 0 .. count) html ~= `<meta name="author" content="Same">`;
        html ~= "</head>";
        auto capped = StageDocument(document,
            new Content([ContentPiece.own(cast(const(ubyte)[]) html)]));
        auto result = runCompiledStage([capped], plan.stages[0]);
        check(result.events.length == 1 && result.events[0].payload.document.id == document.id,
            "capped stage identity mismatch");
        auto field = parseJSON(bytes(result.events[0].payload.content))["fields"]["author"];
        check(field["candidates"].array.length == 16 &&
            field["status"].str == (count == 16 ? "selected" : "overflow") &&
            field["overflow"].boolean == (count == 17), "16/17 cap mismatch");
    }
    string slashes;
    foreach (_; 0 .. 512) slashes ~= "\\";
    string largeMetadata = "<head>";
    foreach (_; 0 .. 16) {
        largeMetadata ~= `<meta property="og:title" content="` ~ slashes ~ `">`;
        largeMetadata ~= `<meta name="author" content="` ~ slashes ~ `">`;
    }
    largeMetadata ~= "</head>";
    auto largeInput = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[]) largeMetadata)]));
    auto transform = plan.stages[0].transform;
    auto largeDecision = transform(largeInput);
    check(largeDecision.kind == DecisionKind.quarantine &&
        largeDecision.reason == "outputLimit", "metadata output cap failed");
    auto malformed = parseHtml([cast(ubyte) 0xff]);
    check(!malformed.isParsed, "invalid UTF-8 accepted");
    auto badInput = StageDocument(document,
        new Content([ContentPiece.own([cast(ubyte) 0xff])]));
    auto badDecision = transform(badInput);
    check(badDecision.kind == DecisionKind.quarantine &&
        badDecision.reason.indexOf("/PRIVATE/secret") < 0 &&
        badDecision.reason.indexOf("record") < 0, "diagnostic leaked source");
    auto oversized = StageDocument(document,
        new Content([ContentPiece.own(new ubyte[maxRawBytes + 1])]));
    check(transform(oversized).kind == DecisionKind.quarantine,
        "oversized input accepted");
    auto unsupportedSpec = parseJobJson(`{"version":3,"stages":[{"id":"metadata",` ~
        `"implementation":"html-metadata","options":{"charset":"latin1"},` ~
        `"filters":[]}]}`);
    auto unsupported = compileJob(unsupportedSpec);
    auto small = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[]) "<title>X</title>")]));
    auto unsupportedTransform = unsupported.stages[0].transform;
    check(unsupportedTransform(small).kind == DecisionKind.quarantine,
        "unsupported charset accepted");
    foreach (i, key; ["title", "author", "date", "url"])
        writeln(key, " precision=", correct[i], "/", selected[i],
            " abstention=", abstained[i], "/", heldOut.length,
            " (small pinned corpus; not a live-web estimate)");
}
