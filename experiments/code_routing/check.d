/// Release-active checker for the isolated code-routing feasibility evidence.
module check;

import evaluation : Fixture, Measurement, classify, loadManifest, measure,
    measureAll, parseManifest;
import std.algorithm : all, count, filter;
import std.array : array, replace;
import std.conv : to;
import std.exception : enforce;
import std.file : readText;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : split, splitLines, strip;

private bool yes(string value)
{
    enforce(value == "yes" || value == "no", "boolean evidence must be yes/no");
    return value == "yes";
}

private Measurement[] loadMeasurements(string root)
{
    auto lines = readText(buildPath(root, "measurements.tsv")).splitLines;
    enforce(lines.length == 9, "measurement evidence must contain eight rows");
    Measurement[] values;
    foreach (line; lines[1 .. $])
    {
        auto fields = line.split('\t');
        enforce(fields.length == 10, "measurement row must have ten fields");
        values ~= Measurement(fields[0], yes(fields[1]), yes(fields[2]),
            fields[3], yes(fields[4]), yes(fields[5]), yes(fields[6]),
            yes(fields[7]), yes(fields[8]), yes(fields[9]));
    }
    return values;
}

private void requireSame(const Measurement actual, const Measurement recorded)
{
    enforce(actual == recorded, "recorded measurement mismatch: " ~ actual.file);
}

private void checkBenchmark(string root, string inputDigest)
{
    auto lines = readText(buildPath(root, "benchmark.tsv")).splitLines;
    enforce(lines.length == 3, "benchmark must contain baseline and candidate rows");
    string[] modes;
    foreach (line; lines[1 .. $])
    {
        auto fields = line.split('\t');
        enforce(fields.length == 8, "benchmark row must have eight fields");
        modes ~= fields[0];
        enforce(fields[1].to!long == 10_000 && fields[2].to!long == 8,
            "benchmark iteration/input denominator mismatch");
        enforce(fields[3] == inputDigest, "benchmark input digest mismatch");
        enforce(fields[4].to!long > 0 && fields[5].to!long > 0,
            "benchmark runtime/RSS missing");
        if (fields[0] == "baseline")
            enforce(fields[6].to!long == 0 && fields[7].to!long == 0,
                "baseline must not claim routing/proxy hits");
        else
            enforce(fields[0] == "candidate" && fields[6].to!long == 30_000 &&
                fields[7].to!long == 30_000,
                "candidate benchmark counts mismatch");
    }
    enforce(modes == ["baseline", "candidate"], "benchmark mode order mismatch");
}

private void negativeControls()
{
    enforce(!classify("Use `value()` in prose; no fence.").routed,
        "inline code must not route");
    enforce(!classify("SPDX-License-Identifier: MIT is prose.").routed,
        "license text must not route");
    enforce(!classify("```d\nint x;\n```\n").routed,
        "code-only input must not route");
    enforce(!classify("before\n```d\nint x;\nafter").routed,
        "unclosed fence must not route");
    enforce(!classify("before\n```text\nstatus: ok\n```\nafter").routed,
        "non-code fence must not route");
    enforce(!classify("before\n```d\nint x;\n```\nmiddle\n```d\nint y;\n```\nafter").routed,
        "multiple fences must not route");
    enforce(!classify("before\n```d\nint x;\n````\n").routed,
        "four-tick close without following prose must not route");
    enforce(!classify("before\n```d\nint x;\n```garbage\nafter").routed,
        "closing fence garbage suffix must not route");
    enforce(classify("before\n```d\nint x;\n```` \t\nafter").routed,
        "longer closing run plus spaces/tabs must route");
    enforce(classify("before\n````d\nint x;\n````\nafter").routed,
        "matching four-tick fences must route");
    enforce(!classify("before\n````d\nint x;\n```\nafter").routed,
        "closing run shorter than opener must not route");
}

private void expectReject(scope void delegate() operation, string label)
{
    bool rejected;
    try
        operation();
    catch (Exception)
        rejected = true;
    enforce(rejected, label);
}

private void manifestNegativeControls(string root)
{
    const manifest = readText(buildPath(root, "fixtures", "manifest.tsv"));
    expectReject(() { parseManifest(manifest.replace("\tyes\t", "\ttrue\t")); },
        "manifest boolean mutation must be rejected");
    expectReject(() { parseManifest(manifest.replace("syntax-annotation",
        "syntax")); }, "manifest schema mutation must be rejected");
    expectReject(() { parseManifest(manifest.replace(
        "\td\tyes\tbalanced-braces-parens-semicolon\t",
        "\tpython\tyes\tbalanced-braces-parens-semicolon\t")); },
        "manifest language mutation must be rejected");
    expectReject(() { parseManifest(manifest.replace(
        "balanced-braces-parens-semicolon", "unknown-syntax")); },
        "manifest syntax mutation must be rejected");

    const coherentMutation = manifest.replace(
        "\td\tyes\tbalanced-braces-parens-semicolon\t",
        "\tpython\tyes\tbalanced-parens-colon-indent\t");
    auto fixtures = parseManifest(coherentMutation);
    expectReject(() { measure(root, fixtures[0]); },
        "coherent language/syntax mutation must not match fixture bytes");
}

int main(string[] arguments)
{
    const root = arguments.length == 2 ? arguments[1] :
        "experiments/code_routing";
    auto fixtures = loadManifest(root);
    enforce(fixtures.length == 8, "expected eight authored fixtures");
    enforce(fixtures.all!(fixture => fixture.sha256.length == 64 &&
        fixture.syntaxAnnotation.length && fixture.proxyToken.length &&
        fixture.fixtureRights == "CC0-1.0"),
        "fixture hash/annotation/rights missing");
    enforce(fixtures.count!(fixture => fixture.expectedRoute) == 3,
        "expected three positive and five negative fixtures");

    auto actual = measureAll(root);
    auto recorded = loadMeasurements(root);
    foreach (index; 0 .. actual.length)
        requireSame(actual[index], recorded[index]);
    enforce(actual.count!(result => result.actualRoute) == 3 &&
        actual.count!(result => result.actualRoute != result.expectedRoute) == 0,
        "classification boundary mismatch");
    enforce(actual.all!(result => result.licenseRetained && result.outsideEqual),
        "license marker or outside-span bytes changed");
    enforce(actual.count!(result => result.baselineProxy) == 0 &&
        actual.count!(result => result.candidateProxy) == 3,
        "selection proxy denominator mismatch");
    enforce(actual.filter!(result => result.actualRoute)
        .all!(result => result.baselineIntegrity && result.candidateIntegrity),
        "routed delimiter/parser integrity failed");

    string inputDigest;
    foreach (fixture; fixtures)
        inputDigest ~= fixture.sha256;
    import evaluation : hashBytes;
    checkBenchmark(root, hashBytes(cast(const(ubyte)[]) inputDigest));
    manifestNegativeControls(root);
    negativeControls();
    writeln("PASS: 8 fixtures, 3/3 true routes, 0/5 false routes, ",
        "3/3 proxy selections, hashes/integrity/licenses/outside bytes checked");
    return 0;
}
