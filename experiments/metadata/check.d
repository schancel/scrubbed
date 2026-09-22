// Release-active, D-only field and stage goldens for metadata-json:v1.
module experiments.metadata.check;

import content.pieces : Content, ContentPiece;
import domain.document : Document, OutputName, SourceLocator;
import effects.html_metadata : extractHtmlMetadata, serializeHtmlMetadata;
import effects.html_metadata_stage : htmlMetadataPlan;
import effects.html_tree : HtmlAttribute, HtmlNode, HtmlNodeKind, HtmlTree,
    maxRawBytes, parseHtml;
import stages.contract : DecisionKind, ResourceDeclaration, StageDeclaration,
    StageDocument;
import std.conv : to;
import std.json : JSONType, parseJSON;
import std.stdio : writeln;
import std.string : indexOf;

private void check(bool condition, string message) {
    if (!condition) throw new Exception(message);
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
    auto plan = htmlMetadataPlan();
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
        auto decision = plan.stages[0].transform(input);
        check(decision.kind == DecisionKind.map, "stage did not map");
        // StageDecision payload is observed through the public runStage boundary.
        import stages.contract : runStage;
        auto spec = plan.stages[0].declaration;
        auto declaration = StageDeclaration(spec.key.idup, spec.passMode,
            ResourceDeclaration(spec.resources.cpuSlots, spec.resources.memoryBytes));
        auto output = runStage([input], declaration,
            plan.stages[0].transform);
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
        if (fixtureIndex == 5 || fixtureIndex == 6)
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
        import stages.contract : runStage;
        auto spec = plan.stages[0].declaration;
        auto declaration = StageDeclaration(spec.key.idup, spec.passMode,
            ResourceDeclaration(spec.resources.cpuSlots, spec.resources.memoryBytes));
        auto result = runStage([capped], declaration, plan.stages[0].transform);
        check(result.events.length == 1 && result.events[0].payload.document.id == document.id,
            "capped stage identity mismatch");
        auto field = parseJSON(bytes(result.events[0].payload.content))["fields"]["author"];
        check(field["candidates"].array.length == 16 &&
            field["status"].str == (count == 16 ? "selected" : "overflow") &&
            field["overflow"].boolean == (count == 17), "16/17 cap mismatch");
    }
    auto malformed = parseHtml([cast(ubyte) 0xff]);
    check(!malformed.isParsed, "invalid UTF-8 accepted");
    auto badInput = StageDocument(document,
        new Content([ContentPiece.own([cast(ubyte) 0xff])]));
    auto badDecision = plan.stages[0].transform(badInput);
    check(badDecision.kind == DecisionKind.quarantine &&
        badDecision.reason.indexOf("/PRIVATE/secret") < 0 &&
        badDecision.reason.indexOf("record") < 0, "diagnostic leaked source");
    auto oversized = StageDocument(document,
        new Content([ContentPiece.own(new ubyte[maxRawBytes + 1])]));
    check(plan.stages[0].transform(oversized).kind == DecisionKind.quarantine,
        "oversized input accepted");
    auto unsupported = htmlMetadataPlan("latin1");
    auto small = StageDocument(document,
        new Content([ContentPiece.own(cast(const(ubyte)[]) "<title>X</title>")]));
    check(unsupported.stages[0].transform(small).kind == DecisionKind.quarantine,
        "unsupported charset accepted");
    foreach (i, key; ["title", "author", "date", "url"])
        writeln(key, " precision=", correct[i], "/", selected[i],
            " abstention=", abstained[i], "/", heldOut.length,
            " (small pinned corpus; not a live-web estimate)");
}
