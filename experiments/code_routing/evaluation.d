/// Shared D-only code-routing feasibility model; not production routing.
module evaluation;

import std.algorithm : count, map;
import std.array : array;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : read, readText;
import std.json : JSONType, parseJSON;
import std.path : buildPath;
import std.string : indexOf, split, splitLines, strip, toLower;

struct Fixture
{
    string file;
    string sha256;
    string language;
    bool expectedRoute;
    string syntaxAnnotation;
    string licenseMarker;
    string proxyToken;
    string fixtureRights;
}

struct Route
{
    bool routed;
    string language;
    size_t start;
    size_t end;
}

struct Measurement
{
    string file;
    bool expectedRoute;
    bool actualRoute;
    string language;
    bool baselineIntegrity;
    bool candidateIntegrity;
    bool licenseRetained;
    bool outsideEqual;
    bool baselineProxy;
    bool candidateProxy;
}

string hashBytes(const(ubyte)[] bytes)
{
    return sha256Of(bytes).toHexString.toLower;
}

Fixture[] loadManifest(string root)
{
    Fixture[] fixtures;
    foreach (line; readText(buildPath(root, "fixtures", "manifest.tsv")).splitLines)
    {
        if (!line.length || line[0] == '#')
            continue;
        auto fields = line.split('\t');
        if (fields.length != 8)
            throw new Exception("manifest row must have eight fields");
        fixtures ~= Fixture(fields[0], fields[1], fields[2], fields[3] == "yes",
            fields[4], fields[5], fields[6], fields[7]);
    }
    return fixtures;
}

private bool supportedLanguage(string language)
{
    return language == "d" || language == "python" || language == "json";
}

/// Route exactly one supported fenced block only when prose exists on both sides.
Route classify(string input)
{
    const opening = input.indexOf("```");
    if (opening < 0 || (opening > 0 && input[opening - 1] != '\n'))
        return Route.init;
    const languageEnd = input.indexOf('\n', opening + 3);
    if (languageEnd < 0)
        return Route.init;
    const language = input[opening + 3 .. languageEnd].strip;
    if (!supportedLanguage(language))
        return Route.init;
    const closing = input.indexOf("\n```", languageEnd + 1);
    if (closing < 0)
        return Route.init;
    const afterFence = cast(size_t) closing + 4;
    if (afterFence < input.length && input[afterFence] == '\r')
        return Route.init;
    const afterLine = afterFence < input.length && input[afterFence] == '\n' ?
        afterFence + 1 : afterFence;
    if (input.indexOf("```", afterLine) >= 0 ||
        input[0 .. opening].strip.length == 0 ||
        input[afterLine .. $].strip.length == 0)
        return Route.init;
    return Route(true, language, cast(size_t) languageEnd + 1,
        cast(size_t) closing);
}

private bool balanced(string input, char open, char close)
{
    ptrdiff_t depth;
    foreach (character; input)
    {
        if (character == open)
            ++depth;
        else if (character == close && --depth < 0)
            return false;
    }
    return depth == 0;
}

bool integrity(string language, string code)
{
    final switch (language)
    {
    case "d":
        return balanced(code, '{', '}') && balanced(code, '(', ')') &&
            code.count(';') > 0;
    case "python":
        return balanced(code, '(', ')') && code.indexOf("def ") >= 0 &&
            code.indexOf(':') >= 0 && code.indexOf("\n    ") >= 0;
    case "json":
        try
        {
            return parseJSON(code).type == JSONType.object;
        }
        catch (Exception)
        {
            return false;
        }
    }
}

Measurement measure(string root, const Fixture fixture)
{
    const path = buildPath(root, "fixtures", fixture.file);
    const bytes = cast(ubyte[]) read(path);
    if (hashBytes(bytes) != fixture.sha256)
        throw new Exception("fixture hash mismatch: " ~ fixture.file);
    const input = cast(string) bytes;
    const route = classify(input);
    const baselineOutput = input;
    const candidateOutput = input; // metadata-only routing preserves the document.
    bool baselineIntegrity;
    bool candidateIntegrity;
    bool licenseRetained = fixture.licenseMarker.length == 0 ||
        candidateOutput.indexOf(fixture.licenseMarker) >= 0;
    bool candidateProxy;
    if (route.routed)
    {
        const selected = candidateOutput[route.start .. route.end];
        const baselineSelected = baselineOutput[route.start .. route.end];
        baselineIntegrity = integrity(route.language, baselineSelected);
        candidateIntegrity = integrity(route.language, selected);
        licenseRetained = licenseRetained &&
            (fixture.licenseMarker.length == 0 ||
                selected.indexOf(fixture.licenseMarker) >= 0);
        candidateProxy = selected.indexOf(fixture.proxyToken) >= 0;
    }
    return Measurement(fixture.file, fixture.expectedRoute, route.routed,
        route.routed ? route.language : "none", baselineIntegrity,
        candidateIntegrity, licenseRetained, baselineOutput == candidateOutput,
        false, candidateProxy);
}

Measurement[] measureAll(string root)
{
    return loadManifest(root).map!(fixture => measure(root, fixture)).array;
}
