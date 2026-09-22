module check;

import std.algorithm : all, canFind, count, filter, map;
import std.array : array;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : read, readText;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : split, splitLines, strip, toLower;

struct Sample
{
    string id;
    string format;
    string split;
    string caseName;
    string path;
    string sha256;
    string license;
    string provenance;
}

struct Truth
{
    string sample;
    string tokens;
    string geometry;
}

struct Adapter
{
    string id;
    string format;
    string status;
    string versionName;
    string license;
    string artifactSha256;
    string sourceUrl;
    string sourceSha256;
    string provenance;
    long packageKib;
    long dependencyKib;
    long binaryBytes;
    string dependencyNote;
    string rejection;
}

struct Result
{
    string adapter;
    string sample;
    string outcome;
    int exitCode;
    long elapsedMs;
    long peakRssBytes;
    string outputSha256;
    string observedTokens;
    int matched;
    int total;
    int orderErrors;
    int geometryHits;
    string diagnostic;
}

private string[][] rows(string path, size_t columns)
{
    auto lines = readText(path).splitLines.filter!(line => line.strip.length > 0).array;
    enforce(lines.length > 1, path ~ ": no data rows");
    string[][] parsed;
    foreach (line; lines[1 .. $])
    {
        auto fields = line.split('\t');
        enforce(fields.length == columns, path ~ ": wrong column count");
        parsed ~= fields;
    }
    return parsed;
}

private Sample[] loadSamples(string root)
{
    Sample[] values;
    foreach (row; rows(buildPath(root, "samples.tsv"), 8))
        values ~= Sample(row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7]);
    return values;
}

private Truth[] loadTruth(string root)
{
    Truth[] values;
    foreach (row; rows(buildPath(root, "ground_truth.tsv"), 3))
        values ~= Truth(row[0], row[1], row[2]);
    return values;
}

private Adapter[] loadAdapters(string root)
{
    Adapter[] values;
    foreach (row; rows(buildPath(root, "adapters.tsv"), 14))
        values ~= Adapter(row[0], row[1], row[2], row[3], row[4], row[5], row[6],
            row[7], row[8], row[9].to!long, row[10].to!long, row[11].to!long,
            row[12], row[13]);
    return values;
}

private Result[] loadResults(string root)
{
    Result[] values;
    foreach (row; rows(buildPath(root, "results.tsv"), 13))
        values ~= Result(row[0], row[1], row[2], row[3].to!int, row[4].to!long,
            row[5].to!long, row[6], row[7], row[8].to!int, row[9].to!int,
            row[10].to!int, row[11].to!int, row[12]);
    return values;
}

private bool validHash(string value)
{
    if (value.length != 64)
        return false;
    return value.all!(character => (character >= '0' && character <= '9') ||
        (character >= 'a' && character <= 'f'));
}

private string fileHash(string path)
{
    return sha256Of(cast(ubyte[]) read(path)).toHexString.toLower;
}

private Sample* findSample(ref Sample[] samples, string id)
{
    foreach (ref sample; samples)
        if (sample.id == id)
            return &sample;
    return null;
}

private Truth* findTruth(ref Truth[] truths, string id)
{
    foreach (ref truth; truths)
        if (truth.sample == id)
            return &truth;
    return null;
}

private Adapter* findAdapter(ref Adapter[] adapters, string id)
{
    foreach (ref adapter; adapters)
        if (adapter.id == id)
            return &adapter;
    return null;
}

private int[2] accuracy(string expectedText, string observedText)
{
    const expected = expectedText.split('|');
    const observed = observedText == "-" ? [] : observedText.split('|');
    size_t[string] occurrences;
    size_t[string] positions;
    foreach (position, token; observed)
    {
        const occurrence = ++occurrences[token];
        positions[token ~ "#" ~ occurrence.to!string] = position;
    }

    occurrences = null;
    size_t[] mapped;
    foreach (token; expected)
    {
        const occurrence = ++occurrences[token];
        const key = token ~ "#" ~ occurrence.to!string;
        if (auto position = key in positions)
            mapped ~= *position;
    }
    int inversions;
    foreach (left; 0 .. mapped.length)
        foreach (right; left + 1 .. mapped.length)
            if (mapped[left] > mapped[right])
                ++inversions;
    return [cast(int) mapped.length, inversions];
}

private void validate(string root, ref Sample[] samples, ref Truth[] truths,
    ref Adapter[] adapters, ref Result[] results)
{
    enforce(samples.length == 6, "expected six frozen samples");
    foreach (sample; samples)
    {
        enforce(sample.id.length && sample.provenance.length && sample.license == "CC0-1.0",
            "sample provenance/license missing: " ~ sample.id);
        enforce(validHash(sample.sha256), "sample hash missing: " ~ sample.id);
        enforce(fileHash(buildPath(root, sample.path)) == sample.sha256,
            "sample hash mismatch: " ~ sample.id);
    }
    foreach (format; ["pdf", "docx"])
    {
        enforce(samples.count!(sample => sample.format == format && sample.split == "training") >= 1,
            format ~ " training sample missing");
        enforce(samples.count!(sample => sample.format == format && sample.split == "heldout" && sample.caseName == "layout") >= 1,
            format ~ " held-out layout sample missing");
        enforce(samples.count!(sample => sample.format == format && sample.caseName == "malformed") >= 1,
            format ~ " malformed sample missing");
    }

    enforce(adapters.count!(adapter => adapter.format == "pdf" && adapter.status == "evaluated") >= 2,
        "two evaluated PDF candidates required");
    enforce(adapters.count!(adapter => adapter.format == "docx") >= 2,
        "two plausible DOCX candidates required");
    enforce(adapters.count!(adapter => adapter.format == "docx" && adapter.status == "evaluated") >= 1,
        "one feasible DOCX candidate required");
    foreach (adapter; adapters)
    {
        enforce(adapter.id.length && adapter.versionName.length && adapter.license.length,
            "adapter identity/license missing");
        enforce(validHash(adapter.artifactSha256) && validHash(adapter.sourceSha256),
            "adapter hash/provenance missing: " ~ adapter.id);
        enforce(adapter.sourceUrl.length && adapter.provenance.length && adapter.dependencyNote.length,
            "adapter provenance missing: " ~ adapter.id);
        enforce(adapter.packageKib > 0 && adapter.dependencyKib >= 0 && adapter.binaryBytes > 0,
            "adapter size evidence missing: " ~ adapter.id);
        enforce(adapter.status == "evaluated" || (adapter.status == "rejected" && adapter.rejection != "-"),
            "unsupported adapter lacks exact reason: " ~ adapter.id);
    }

    foreach (result; results)
    {
        auto sample = findSample(samples, result.sample);
        auto adapter = findAdapter(adapters, result.adapter);
        enforce(sample !is null && adapter !is null && sample.format == adapter.format,
            "result references incompatible sample/adapter");
        enforce(result.elapsedMs > 0 && result.peakRssBytes > 0,
            "startup/RSS evidence missing");
        enforce(result.diagnostic.length && !result.diagnostic.canFind('/') &&
            !result.diagnostic.canFind('\\'), "diagnostic is not redacted");

        if (sample.caseName == "malformed")
        {
            if (adapter.status == "evaluated")
                enforce(result.outcome == "rejected" && result.exitCode != 0,
                    "malformed input reported success/crash/timeout");
            else
                enforce(result.outcome == "isolated_timeout" && result.exitCode == 124,
                    "rejected adapter failure is not isolated");
            continue;
        }

        auto truth = findTruth(truths, sample.id);
        enforce(truth !is null, "expected text/geometry missing: " ~ sample.id);
        if (adapter.status == "rejected")
        {
            enforce(result.outcome == "isolated_timeout" && result.exitCode == 124 &&
                result.observedTokens == "-", "unsupported candidate must preserve timeout evidence");
            continue;
        }
        enforce(result.outcome == "ok" && result.exitCode == 0,
            "evaluated candidate crashed or timed out");
        enforce(validHash(result.outputSha256), "output hash missing");
        const measured = accuracy(truth.tokens, result.observedTokens);
        enforce(result.total == truth.tokens.split('|').length && result.matched == measured[0] &&
            result.orderErrors == measured[1], "wrong expected text/order metrics");
        enforce(result.geometryHits >= 0 && result.geometryHits <= 4,
            "invalid geometry score");
    }

    foreach (adapter; adapters)
        foreach (sample; samples.filter!(sample => sample.format == adapter.format))
            enforce(results.count!(result => result.adapter == adapter.id && result.sample == sample.id) == 1,
                "candidate/sample measurement missing");
}

private void expectFailure(void delegate() operation, string name)
{
    bool failed;
    try
        operation();
    catch (Exception)
        failed = true;
    enforce(failed, "negative control did not fail: " ~ name);
}

void main(string[] arguments)
{
    const root = arguments.length == 2 ? arguments[1] : "experiments/document_adapters";
    auto samples = loadSamples(root);
    auto truths = loadTruth(root);
    auto adapters = loadAdapters(root);
    auto results = loadResults(root);
    validate(root, samples, truths, adapters, results);

    auto wrongTruth = truths.dup;
    wrongTruth[0].tokens = "PDF|TRAINING|ALPHA|ONE|BETA|TWO";
    expectFailure(() => validate(root, samples, wrongTruth, adapters, results), "wrong text/order");

    auto missingHash = samples.dup;
    missingHash[0].sha256 = "-";
    expectFailure(() => validate(root, missingHash, truths, adapters, results), "missing sample hash");

    auto malformedSuccess = results.dup;
    foreach (ref result; malformedSuccess)
        if (result.adapter == "poppler-pdftotext" && result.sample == "pdf-malformed")
        {
            result.outcome = "ok";
            result.exitCode = 0;
        }
    expectFailure(() => validate(root, samples, truths, adapters, malformedSuccess), "malformed success");

    auto timedOut = results.dup;
    timedOut[0].outcome = "isolated_timeout";
    timedOut[0].exitCode = 124;
    expectFailure(() => validate(root, samples, truths, adapters, timedOut), "evaluated timeout");

    auto crashed = results.dup;
    crashed[0].outcome = "signal";
    crashed[0].exitCode = 125;
    expectFailure(() => validate(root, samples, truths, adapters, crashed), "evaluated crash");

    auto missingProvenance = adapters.dup;
    missingProvenance[0].provenance = "";
    expectFailure(() => validate(root, samples, truths, missingProvenance, results), "missing provenance");

    writeln("PASS: ", samples.length, " samples, ", adapters.length,
        " candidates, ", results.length, " measurements, 6 negative controls");
}
