module check;

import std.algorithm : all, canFind, count, filter;
import std.array : array, join, replicate;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : read, readText;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf, split, splitLines, strip, toLower;
import std.utf : validate;

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

struct Observation
{
    string adapter;
    string sample;
    long timeoutMs;
    string argv;
    string boundaryOutcome;
    int boundaryExit;
    long elapsedMs;
    long peakRssBytes;
    string extractedHex;
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
    auto lines = readText(path).splitLines
        .filter!(line => line.strip.length > 0).array;
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
        values ~= Sample(row[0], row[1], row[2], row[3], row[4], row[5],
            row[6], row[7]);
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
        values ~= Adapter(row[0], row[1], row[2], row[3], row[4], row[5],
            row[6], row[7], row[8], row[9].to!long, row[10].to!long,
            row[11].to!long, row[12], row[13]);
    return values;
}

private Observation[] loadObservations(string root)
{
    Observation[] values;
    foreach (row; rows(buildPath(root, "observations.tsv"), 9))
        values ~= Observation(row[0], row[1], row[2].to!long, row[3],
            row[4], row[5].to!int, row[6].to!long, row[7].to!long, row[8]);
    return values;
}

private Result[] loadResults(string root)
{
    Result[] values;
    foreach (row; rows(buildPath(root, "results.tsv"), 13))
        values ~= Result(row[0], row[1], row[2], row[3].to!int,
            row[4].to!long, row[5].to!long, row[6], row[7], row[8].to!int,
            row[9].to!int, row[10].to!int, row[11].to!int, row[12]);
    return values;
}

private bool validHash(string value)
{
    return value.length == 64 && value.all!(character =>
        (character >= '0' && character <= '9') ||
        (character >= 'a' && character <= 'f'));
}

private string bytesHash(const(ubyte)[] bytes)
{
    return sha256Of(bytes).toHexString.toLower;
}

private string fileHash(string path)
{
    return bytesHash(cast(ubyte[]) read(path));
}

private ubyte hexNibble(char value)
{
    if (value >= '0' && value <= '9')
        return cast(ubyte) (value - '0');
    if (value >= 'a' && value <= 'f')
        return cast(ubyte) (value - 'a' + 10);
    throw new Exception("observation contains non-canonical hex");
}

private ubyte[] decodeObservation(string encoded)
{
    if (encoded == "-")
        return [];
    enforce(encoded.length > 0 && encoded.length % 2 == 0,
        "observation has malformed hex length");
    ubyte[] bytes;
    bytes.length = encoded.length / 2;
    foreach (index; 0 .. bytes.length)
        bytes[index] = cast(ubyte) ((hexNibble(encoded[index * 2]) << 4) |
            hexNibble(encoded[index * 2 + 1]));
    return bytes;
}

private Sample* findSample(ref Sample[] values, string id)
{
    foreach (ref value; values)
        if (value.id == id)
            return &value;
    return null;
}

private Truth* findTruth(ref Truth[] values, string id)
{
    foreach (ref value; values)
        if (value.sample == id)
            return &value;
    return null;
}

private Adapter* findAdapter(ref Adapter[] values, string id)
{
    foreach (ref value; values)
        if (value.id == id)
            return &value;
    return null;
}

private Observation* findObservation(ref Observation[] values,
    string adapter, string sample)
{
    foreach (ref value; values)
        if (value.adapter == adapter && value.sample == sample)
            return &value;
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

private string tokensFrom(const(ubyte)[] bytes)
{
    auto text = cast(string) bytes;
    validate(text);
    string[] tokens;
    string token;
    foreach (character; text)
    {
        if ((character >= 'A' && character <= 'Z') ||
            (character >= '0' && character <= '9'))
            token ~= character;
        else if (token.length)
        {
            tokens ~= token;
            token = null;
        }
    }
    if (token.length)
        tokens ~= token;
    return tokens.length ? tokens.join("|") : "-";
}

private ptrdiff_t lineWith(string[] lines, string first, string second = "")
{
    foreach (index, line; lines)
        if (line.canFind(first) && (!second.length || line.canFind(second)))
            return cast(ptrdiff_t) index;
    return -1;
}

private bool alignedColumns(string[] lines, string leftOne, string rightOne,
    string leftTwo, string rightTwo)
{
    const firstLine = lineWith(lines, leftOne, rightOne);
    const secondLine = lineWith(lines, leftTwo, rightTwo);
    if (firstLine < 0 || secondLine < 0)
        return false;
    const firstLeft = lines[firstLine].indexOf(leftOne);
    const firstRight = lines[firstLine].indexOf(rightOne);
    const secondLeft = lines[secondLine].indexOf(leftTwo);
    const secondRight = lines[secondLine].indexOf(rightTwo);
    return firstLeft >= 0 && secondLeft >= 0 && firstRight > firstLeft &&
        secondRight > secondLeft && firstRight == secondRight;
}

private bool geometryPredicate(string name, string[] lines)
{
    switch (name)
    {
    case "pdf_row_a_columns":
        return lineWith(lines, "LEFT A", "RIGHT A") >= 0;
    case "pdf_row_b_columns":
        return lineWith(lines, "LEFT B", "RIGHT B") >= 0;
    case "pdf_right_column_aligned":
        return alignedColumns(lines, "LEFT A", "RIGHT A", "LEFT B", "RIGHT B");
    case "pdf_footer_after_columns":
        return lineWith(lines, "FOOTER END") > lineWith(lines, "RIGHT B") &&
            lineWith(lines, "RIGHT B") >= 0 && lineWith(lines, "LEFT B") >= 0;
    case "docx_row1_cells":
        return lineWith(lines, "ROW1 LEFT", "ROW1 RIGHT") >= 0;
    case "docx_row2_cells":
        return lineWith(lines, "ROW2 LEFT", "ROW2 RIGHT") >= 0;
    case "docx_right_column_aligned":
        return alignedColumns(lines, "ROW1 LEFT", "ROW1 RIGHT",
            "ROW2 LEFT", "ROW2 RIGHT");
    case "docx_footer_after_table":
        return lineWith(lines, "OFFICE END") > lineWith(lines, "ROW2 RIGHT") &&
            lineWith(lines, "ROW2 RIGHT") >= 0;
    default:
        throw new Exception("unknown geometry predicate: " ~ name);
    }
}

private int geometryScore(string geometry, const(ubyte)[] bytes)
{
    if (geometry == "none")
        return 0;
    auto predicates = geometry.split(';');
    enforce(predicates.length == 4, "layout truth must name four predicates");
    auto text = cast(string) bytes;
    validate(text);
    auto lines = text.splitLines;
    int hits;
    foreach (predicate; predicates)
        if (geometryPredicate(predicate, lines))
            ++hits;
    return hits;
}

private string expectedArgv(string adapter)
{
    switch (adapter)
    {
    case "poppler-pdftotext":
        return "pdftotext|-layout|{input}|{output}";
    case "mupdf-mutool":
        return "mutool|draw|-q|-F|txt|-o|{output}|{input}";
    case "pandoc-docx":
        return "pandoc|-f|docx|-t|plain|--wrap=none|{input}|-o|{output}";
    case "libreoffice-writer":
        return "soffice|-env:UserInstallation=file://{profile}|--headless|" ~
            "--nologo|--nodefault|--nolockcheck|--norestore|--convert-to|" ~
            "txt:Text|--outdir|{output_dir}|{input}";
    default:
        throw new Exception("unknown observation adapter: " ~ adapter);
    }
}

private string derivedOutcome(const Observation observation)
{
    if (observation.boundaryOutcome == "timeout")
        return "isolated_timeout";
    enforce(observation.boundaryOutcome == "exit",
        "unknown subprocess boundary outcome");
    return observation.boundaryExit == 0 ? "ok" : "rejected";
}

private void validateEvidence(string root, ref Sample[] samples,
    ref Truth[] truths, ref Adapter[] adapters,
    ref Observation[] observations, ref Result[] results)
{
    enforce(samples.length == 6, "expected six frozen samples");
    foreach (sample; samples)
    {
        enforce(sample.id.length && sample.provenance.length &&
            sample.license == "CC0-1.0",
            "sample provenance/license missing: " ~ sample.id);
        enforce(validHash(sample.sha256), "sample hash missing: " ~ sample.id);
        enforce(fileHash(buildPath(root, sample.path)) == sample.sha256,
            "sample hash mismatch: " ~ sample.id);
    }
    foreach (format; ["pdf", "docx"])
    {
        enforce(samples.count!(sample => sample.format == format &&
            sample.split == "training") >= 1, format ~ " training sample missing");
        enforce(samples.count!(sample => sample.format == format &&
            sample.split == "heldout" && sample.caseName == "layout") >= 1,
            format ~ " held-out layout sample missing");
        enforce(samples.count!(sample => sample.format == format &&
            sample.caseName == "malformed") >= 1,
            format ~ " malformed sample missing");
    }

    enforce(adapters.count!(adapter => adapter.format == "pdf" &&
        adapter.status == "evaluated") >= 2,
        "two evaluated PDF candidates required");
    enforce(adapters.count!(adapter => adapter.format == "docx") >= 2,
        "two plausible DOCX candidates required");
    enforce(adapters.count!(adapter => adapter.format == "docx" &&
        adapter.status == "evaluated") >= 1,
        "one feasible DOCX candidate required");
    foreach (adapter; adapters)
    {
        enforce(adapter.id.length && adapter.versionName.length &&
            adapter.license.length, "adapter identity/license missing");
        enforce(validHash(adapter.artifactSha256) &&
            validHash(adapter.sourceSha256),
            "adapter hash/provenance missing: " ~ adapter.id);
        enforce(adapter.sourceUrl.length && adapter.provenance.length &&
            adapter.dependencyNote.length,
            "adapter provenance missing: " ~ adapter.id);
        enforce(adapter.packageKib > 0 && adapter.dependencyKib >= 0 &&
            adapter.binaryBytes > 0,
            "adapter size evidence missing: " ~ adapter.id);
        enforce(adapter.status == "evaluated" ||
            (adapter.status == "rejected" && adapter.rejection != "-"),
            "unsupported adapter lacks exact reason: " ~ adapter.id);
    }

    enforce(observations.length == results.length,
        "raw observation/result count mismatch");
    foreach (observation; observations)
    {
        auto sample = findSample(samples, observation.sample);
        auto adapter = findAdapter(adapters, observation.adapter);
        enforce(sample !is null && adapter !is null &&
            sample.format == adapter.format,
            "observation references incompatible sample/adapter");
        enforce(observation.timeoutMs > 0 && observation.elapsedMs > 0 &&
            observation.peakRssBytes > 0, "observation limits/metrics missing");
        enforce(observation.argv == expectedArgv(observation.adapter) &&
            observation.argv.split('|').all!(argument => argument.length > 0),
            "exact probe arguments missing or malformed");
        if (observation.boundaryOutcome == "timeout")
            enforce(observation.boundaryExit == 124 &&
                observation.elapsedMs >= observation.timeoutMs,
                "timeout boundary evidence is inconsistent");
        else
            enforce(observation.boundaryOutcome == "exit" &&
                observation.elapsedMs <= observation.timeoutMs,
                "exit boundary evidence is inconsistent");
        decodeObservation(observation.extractedHex);
    }

    foreach (result; results)
    {
        auto sample = findSample(samples, result.sample);
        auto adapter = findAdapter(adapters, result.adapter);
        auto observation = findObservation(observations, result.adapter,
            result.sample);
        enforce(sample !is null && adapter !is null && observation !is null &&
            sample.format == adapter.format,
            "result references incompatible or missing evidence");
        enforce(observations.count!(value => value.adapter == result.adapter &&
            value.sample == result.sample) == 1,
            "result must have exactly one raw observation");

        auto bytes = decodeObservation(observation.extractedHex);
        enforce(validHash(result.outputSha256) &&
            result.outputSha256 == bytesHash(bytes),
            "recorded output hash does not match preserved bytes: " ~
            result.adapter ~ "/" ~ result.sample);
        enforce(result.outcome == derivedOutcome(*observation) &&
            result.exitCode == observation.boundaryExit &&
            result.elapsedMs == observation.elapsedMs &&
            result.peakRssBytes == observation.peakRssBytes,
            "summary does not match raw boundary observation");
        enforce(result.diagnostic.length && !result.diagnostic.canFind('/') &&
            !result.diagnostic.canFind('\\'), "diagnostic is not redacted");

        auto truth = findTruth(truths, sample.id);
        if (truth is null)
        {
            enforce(sample.caseName == "malformed" &&
                result.observedTokens == "-" && result.matched == 0 &&
                result.total == 0 && result.orderErrors == 0 &&
                result.geometryHits == 0,
                "malformed summary contains fabricated accuracy");
        }
        else
        {
            const derivedTokens = tokensFrom(bytes);
            const measured = accuracy(truth.tokens, derivedTokens);
            const geometry = geometryScore(truth.geometry, bytes);
            enforce(result.observedTokens == derivedTokens,
                "recorded tokens do not match preserved bytes");
            enforce(result.total == truth.tokens.split('|').length &&
                result.matched == measured[0] &&
                result.orderErrors == measured[1],
                "recorded text/order metrics do not match preserved bytes");
            enforce(result.geometryHits == geometry,
                "recorded geometry score does not match named predicates");
        }

        if (sample.caseName == "malformed")
        {
            if (adapter.status == "evaluated")
                enforce(result.outcome == "rejected" && result.exitCode != 0,
                    "malformed input reported success/crash/timeout");
            else
                enforce(result.outcome == "isolated_timeout" &&
                    result.exitCode == 124,
                    "rejected adapter failure is not isolated");
        }
        else if (adapter.status == "rejected")
            enforce(result.outcome == "isolated_timeout" &&
                result.observedTokens == "-",
                "unsupported candidate must preserve timeout evidence");
        else
            enforce(result.outcome == "ok" && result.exitCode == 0,
                "evaluated candidate crashed or timed out");
    }

    foreach (adapter; adapters)
        foreach (sample; samples.filter!(sample => sample.format == adapter.format))
            enforce(results.count!(result => result.adapter == adapter.id &&
                result.sample == sample.id) == 1,
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
    const root = arguments.length == 2 ? arguments[1] :
        "experiments/document_adapters";
    auto samples = loadSamples(root);
    auto truths = loadTruth(root);
    auto adapters = loadAdapters(root);
    auto observations = loadObservations(root);
    auto results = loadResults(root);
    validateEvidence(root, samples, truths, adapters, observations, results);

    auto wrongTruth = truths.dup;
    wrongTruth[0].tokens = "PDF|TRAINING|ALPHA|ONE|BETA|TWO";
    expectFailure(() => validateEvidence(root, samples, wrongTruth, adapters,
        observations, results), "wrong text/order");

    auto missingHash = samples.dup;
    missingHash[0].sha256 = "-";
    expectFailure(() => validateEvidence(root, missingHash, truths, adapters,
        observations, results), "missing sample hash");

    auto malformedSuccess = results.dup;
    malformedSuccess[2].outcome = "ok";
    malformedSuccess[2].exitCode = 0;
    expectFailure(() => validateEvidence(root, samples, truths, adapters,
        observations, malformedSuccess), "malformed success");

    auto timedOut = results.dup;
    timedOut[0].outcome = "isolated_timeout";
    timedOut[0].exitCode = 124;
    expectFailure(() => validateEvidence(root, samples, truths, adapters,
        observations, timedOut), "evaluated timeout");

    auto crashed = results.dup;
    crashed[0].outcome = "signal";
    crashed[0].exitCode = 125;
    expectFailure(() => validateEvidence(root, samples, truths, adapters,
        observations, crashed), "evaluated crash");

    auto missingProvenance = adapters.dup;
    missingProvenance[0].provenance = "";
    expectFailure(() => validateEvidence(root, samples, truths,
        missingProvenance, observations, results), "missing provenance");

    auto wrongOutputHash = results.dup;
    wrongOutputHash[0].outputSha256 = "0".replicate(64);
    expectFailure(() => validateEvidence(root, samples, truths, adapters,
        observations, wrongOutputHash), "fabricated output hash");

    auto wrongTokens = results.dup;
    wrongTokens[0].observedTokens = "TRAINING|PDF|BETA|TWO|ALPHA|ONE";
    expectFailure(() => validateEvidence(root, samples, truths, adapters,
        observations, wrongTokens), "fabricated observed tokens");

    auto wrongGeometryScore = results.dup;
    wrongGeometryScore[1].geometryHits = 0;
    expectFailure(() => validateEvidence(root, samples, truths, adapters,
        observations, wrongGeometryScore), "fabricated geometry score");

    auto unknownGeometry = truths.dup;
    unknownGeometry[1].geometry = "fabricated_one;fabricated_two;" ~
        "fabricated_three;fabricated_four";
    expectFailure(() => validateEvidence(root, samples, unknownGeometry,
        adapters, observations, results), "fabricated geometry structure");

    auto missingArguments = observations.dup;
    missingArguments[0].argv = "";
    expectFailure(() => validateEvidence(root, samples, truths, adapters,
        missingArguments, results), "missing exact arguments");

    auto malformedBytes = observations.dup;
    malformedBytes[0].extractedHex = "0";
    expectFailure(() => validateEvidence(root, samples, truths, adapters,
        malformedBytes, results), "malformed preserved bytes");

    auto missingObservation = observations[1 .. $].dup;
    expectFailure(() => validateEvidence(root, samples, truths, adapters,
        missingObservation, results), "missing raw observation");

    writeln("PASS: ", samples.length, " samples, ", adapters.length,
        " candidates, ", results.length,
        " measurements, hashes/tokens/order/geometry recomputed, 13 controls");
}
