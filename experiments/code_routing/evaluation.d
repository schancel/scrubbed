/// Shared D-only code-routing feasibility model; not production routing.
module evaluation;

import std.algorithm : all, count, map;
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
    return parseManifest(readText(buildPath(root, "fixtures", "manifest.tsv")));
}

private bool manifestBoolean(string value)
{
    if (value != "yes" && value != "no")
        throw new Exception("manifest expected-route must be yes or no");
    return value == "yes";
}

private void validateManifestSemantics(const Fixture fixture)
{
    const routed = fixture.expectedRoute;
    const annotation = fixture.syntaxAnnotation;
    bool valid;
    if (annotation == "balanced-braces-parens-semicolon")
        valid = routed && fixture.language == "d";
    else if (annotation == "balanced-parens-colon-indent")
        valid = routed && fixture.language == "python";
    else if (annotation == "balanced-braces-brackets-colon")
        valid = routed && fixture.language == "json";
    else if (annotation == "none")
        valid = !routed && fixture.language == "none";
    else if (annotation == "unclosed-fence")
        valid = !routed && supportedLanguage(fixture.language);
    else if (annotation == "non-code-fence")
        valid = !routed && fixture.language == "text";
    else if (annotation == "no-surrounding-prose")
        valid = !routed && supportedLanguage(fixture.language);
    if (!valid)
        throw new Exception("manifest language/syntax/route mismatch: " ~ fixture.file);
}

Fixture[] parseManifest(string text)
{
    auto lines = text.splitLines;
    if (lines.length < 3 || lines[0] !=
            "# Authored fixtures only. Markers are synthetic test text, not license grants." ||
        lines[1] != "# file\tsha256\tlanguage\texpected-route\tsyntax-annotation\tlicense-marker\tproxy-token\tfixture-rights")
        throw new Exception("manifest schema/header mismatch");
    Fixture[] fixtures;
    bool[string] files;
    foreach (line; lines[2 .. $])
    {
        if (!line.length || line[0] == '#')
            throw new Exception("manifest contains an unexpected row");
        auto fields = line.split('\t');
        if (fields.length != 8)
            throw new Exception("manifest row must have eight fields");
        if (!fields[0].length || fields[0] in files)
            throw new Exception("manifest fixture file is empty or duplicated");
        if (fields[1].length != 64 ||
            !fields[1].all!(character => (character >= '0' && character <= '9') ||
                (character >= 'a' && character <= 'f')))
            throw new Exception("manifest fixture hash is not lowercase SHA-256");
        auto fixture = Fixture(fields[0], fields[1], fields[2],
            manifestBoolean(fields[3]), fields[4], fields[5], fields[6], fields[7]);
        if (!fixture.proxyToken.length || fixture.fixtureRights != "CC0-1.0")
            throw new Exception("manifest proxy token/fixture rights mismatch");
        validateManifestSemantics(fixture);
        files[fixture.file] = true;
        fixtures ~= fixture;
    }
    return fixtures;
}

private bool supportedLanguage(string language)
{
    return language == "d" || language == "python" || language == "json";
}

private ptrdiff_t findClosingFence(string input, size_t search,
    size_t openingTicks, out size_t afterLine)
{
    while (search < input.length)
    {
        const lineStart = search + 1;
        if (lineStart >= input.length)
            break;
        auto lineEnd = input.indexOf('\n', lineStart);
        if (lineEnd < 0)
            lineEnd = cast(ptrdiff_t) input.length;
        size_t ticks;
        while (lineStart + ticks < lineEnd && input[lineStart + ticks] == '`')
            ++ticks;
        auto suffixEnd = cast(size_t) lineEnd;
        if (suffixEnd > lineStart + ticks && input[suffixEnd - 1] == '\r')
            --suffixEnd;
        bool onlyWhitespace = true;
        foreach (character; input[lineStart + ticks .. suffixEnd])
            if (character != ' ' && character != '\t')
                onlyWhitespace = false;
        if (ticks >= openingTicks && onlyWhitespace)
        {
            afterLine = lineEnd < input.length ? cast(size_t) lineEnd + 1 :
                cast(size_t) lineEnd;
            return cast(ptrdiff_t) search;
        }
        if (lineEnd >= input.length)
            break;
        search = cast(size_t) lineEnd;
    }
    return -1;
}

/// Route exactly one supported fenced block only when prose exists on both sides.
Route classify(string input)
{
    const opening = input.indexOf("```");
    if (opening < 0 || (opening > 0 && input[opening - 1] != '\n'))
        return Route.init;
    size_t openingTicks = 3;
    while (opening + openingTicks < input.length &&
            input[opening + openingTicks] == '`')
        ++openingTicks;
    const languageEnd = input.indexOf('\n', opening + openingTicks);
    if (languageEnd < 0)
        return Route.init;
    const language = input[opening + openingTicks .. languageEnd].strip;
    if (!supportedLanguage(language))
        return Route.init;
    size_t afterLine;
    const closing = findClosingFence(input, cast(size_t) languageEnd,
        openingTicks, afterLine);
    if (closing < 0)
        return Route.init;
    if (input.indexOf("```", afterLine) >= 0 ||
        input[0 .. opening].strip.length == 0 ||
        input[afterLine .. $].strip.length == 0)
        return Route.init;
    return Route(true, language, cast(size_t) languageEnd + 1,
        cast(size_t) closing);
}

private bool annotationHolds(const Fixture fixture, string input, Route route)
{
    const annotation = fixture.syntaxAnnotation;
    if (fixture.expectedRoute)
    {
        if (!route.routed || route.language != fixture.language)
            return false;
        const selected = input[route.start .. route.end];
        if (annotation == "balanced-braces-parens-semicolon")
            return balanced(selected, '{', '}') && balanced(selected, '(', ')') &&
                selected.count(';') > 0;
        if (annotation == "balanced-parens-colon-indent")
            return balanced(selected, '(', ')') && selected.indexOf("def ") >= 0 &&
                selected.indexOf(':') >= 0 && selected.indexOf("\n    ") >= 0;
        if (annotation == "balanced-braces-brackets-colon")
            try return parseJSON(selected).type == JSONType.object;
            catch (Exception) return false;
        return false;
    }
    if (route.routed)
        return false;
    if (annotation == "none")
        return input.indexOf("```") < 0;
    const opener = "```" ~ fixture.language;
    const opening = input.indexOf(opener);
    if (opening < 0 || (opening > 0 && input[opening - 1] != '\n'))
        return false;
    const languageEnd = input.indexOf('\n', opening + opener.length);
    if (languageEnd < 0 || input[opening + 3 .. languageEnd] != fixture.language)
        return false;
    size_t afterLine;
    const closing = findClosingFence(input, cast(size_t) languageEnd, 3,
        afterLine);
    if (annotation == "unclosed-fence")
        return closing < 0;
    if (annotation == "non-code-fence")
        return fixture.language == "text" && closing >= 0;
    if (annotation == "no-surrounding-prose")
        return closing >= 0 &&
            (input[0 .. opening].strip.length == 0 ||
                input[afterLine .. $].strip.length == 0);
    return false;
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
    if (!annotationHolds(fixture, input, route))
        throw new Exception("fixture language/syntax annotation mismatch: " ~ fixture.file);
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
