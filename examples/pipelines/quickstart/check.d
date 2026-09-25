/// Release-active actual-binary check for the offline quickstart corpus.
module quickstart_check;

import std.algorithm : equal, filter, reverse, sort;
import std.algorithm.searching : canFind;
import std.array : array;
import std.conv : to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : SpanMode, copy, dirEntries, exists, getSize, isFile, mkdirRecurse,
    read, readText, rmdirRecurse, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath, dirName, isAbsolute, relativePath;
import std.process : Redirect, execute, pipeProcess, wait;
import std.string : replace, split, startsWith;
import std.uuid : randomUUID;

private enum artifactPrefixes = [
    "examples/corpus/quickstart/inputs/",
    "examples/corpus/quickstart/expected/"
];
private enum provenance = "Authored for scrubbed issue #259 by Shammah Chancellor.";

private struct Captured {
    int status;
    string output;
    string error;
}

private void need(bool condition, string label) {
    if (!condition) throw new Exception("quickstart check: " ~ label);
}

private string digest(string path) {
    return toHexString!(LetterCase.lower)(sha256Of(read(path))).idup;
}

private string[] strings(JSONValue value) {
    string[] result;
    foreach (entry; value.array) result ~= entry.str;
    return result;
}

private bool safeRepositoryPath(string path, string[] prefixes) {
    if (path.length == 0 || isAbsolute(path) || path.canFind('\\')) return false;
    foreach (part; path.split("/"))
        if (part.length == 0 || part == "." || part == "..") return false;
    foreach (prefix; prefixes)
        if (path.startsWith(prefix)) return true;
    return false;
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

private void validateManifest(string repository, JSONValue manifest) {
    need(manifest["schema"].str == "scrubbed.quickstart-corpus.v1", "manifest schema");
    auto licensePath = manifest["licenseFile"].str;
    need(licensePath == "examples/corpus/quickstart/LICENSE.txt" &&
        digest(buildPath(repository, licensePath)) ==
            "d05e83eb1213daac7371eee9bb40c8d06e767e37dc38f6f10b8f0b06d72708e0",
        "exact corpus license");
    need(!manifest["claims"]["mainContentExtraction"].boolean &&
        !manifest["claims"]["trainingReady"].boolean,
        "no main-content or training-ready claim");

    auto expectedConfigs = [
        "examples/pipelines/quickstart/html-markdown.json":
            "c69a7156955b248703c4049eaf007314ed882ab2c5215a96d4642ada2a8ac875",
        "examples/pipelines/quickstart/text-repair.json":
            "7f3242069cb64ff4f4778b5b2707646c77159195c57be263cd40ea0f87d1b2b4"
    ];
    need(manifest["configurations"].array.length == expectedConfigs.length,
        "configuration count");
    foreach (configuration; manifest["configurations"].array) {
        auto path = configuration["path"].str;
        need((path in expectedConfigs) !is null &&
            configuration["sha256"].str == expectedConfigs[path] &&
            digest(buildPath(repository, path)) == expectedConfigs[path],
            "canonical configuration " ~ path);
    }

    string[] declared;
    foreach (artifact; manifest["artifacts"].array) {
        auto path = artifact["path"].str;
        need(safeRepositoryPath(path, artifactPrefixes), "artifact path escape: " ~ path);
        need(artifact["mediaType"].str.length != 0, "missing media type: " ~ path);
        need(artifact["provenance"].str == provenance ||
            artifact["provenance"].str.startsWith("Generated from the authored issue #259 input"),
            "missing attribution/provenance: " ~ path);
        need(artifact["license"].str == "MIT", "missing artifact license: " ~ path);
        need(artifact["intendedPipeline"].str.length != 0 &&
            artifact["expectedOutcome"].str.length != 0,
            "missing pipeline/outcome: " ~ path);
        need(isFile(buildPath(repository, path)) &&
            digest(buildPath(repository, path)) == artifact["sha256"].str,
            "artifact hash drift: " ~ path);
        declared ~= path;
    }
    declared.sort;
    auto actual = filesBelow(repository, "examples/corpus/quickstart/inputs") ~
        filesBelow(repository, "examples/corpus/quickstart/expected");
    actual.sort;
    need(declared.equal(actual), "undeclared or missing corpus artifact");

    auto recipes = manifest["recipes"].array;
    need(recipes.length == 3, "recipe count");
    auto htmlConfig = ["extract", "--input", "${INPUT}", "--output", "${OUTPUT}",
        "--format", "markdown", "--config", "${HTML_CONFIG}"];
    auto htmlCli = ["extract", "--input", "${INPUT}", "--output", "${OUTPUT}",
        "--format", "markdown", "--max-html-bytes", "1048576"];
    auto textConfig = ["repair", "--input", "${INPUT}", "--output", "${OUTPUT}",
        "--config", "${TEXT_CONFIG}", "--threads", "1"];
    auto textCli = ["repair", "--input", "${INPUT}", "--output", "${OUTPUT}",
        "--stage", "clean=text-transform", "--filter", "fix-mojibake",
        "--filter-option", "encodings=text:latin1,cp1252", "--filter-option",
        "max-passes=integer:2", "--threads", "1"];
    auto jsonPrefix = ["run", "--input", "-", "--output", "-", "--jsonl-fields",
        "text,title", "--dataset-namespace", "scrubbed-quickstart-v1", "--source-key",
        "records", "--max-jsonl-line-bytes", "1048576", "--max-jsonl-output-bytes",
        "2097152"];
    auto jsonConfig = jsonPrefix ~ ["--config", "${TEXT_CONFIG}"];
    auto jsonCli = jsonPrefix ~ ["--stage", "clean=text-transform", "--filter",
        "fix-mojibake", "--filter-option", "encodings=text:latin1,cp1252",
        "--filter-option", "max-passes=integer:2"];
    need(recipes[0]["id"].str == "html-markdown" &&
        recipes[0]["expectedExit"].integer == 1 &&
        strings(recipes[0]["configArguments"]).equal(htmlConfig) &&
        strings(recipes[0]["cliArguments"]).equal(htmlCli), "stale HTML recipe");
    need(recipes[1]["id"].str == "text-repair" &&
        recipes[1]["expectedExit"].integer == 0 &&
        strings(recipes[1]["configArguments"]).equal(textConfig) &&
        strings(recipes[1]["cliArguments"]).equal(textCli), "stale text recipe");
    need(recipes[2]["id"].str == "selected-field-jsonl" &&
        recipes[2]["expectedExit"].integer == 0 &&
        strings(recipes[2]["configArguments"]).equal(jsonConfig) &&
        strings(recipes[2]["cliArguments"]).equal(jsonCli), "stale JSONL recipe");

    ulong corpusBytes;
    foreach (entry; dirEntries(buildPath(repository, "examples/corpus/quickstart"),
            SpanMode.depth))
        if (entry.isFile) corpusBytes += getSize(entry.name);
    need(corpusBytes < 1024 * 1024, "corpus must remain below 1 MiB");
}

private void expectRejected(string label, void delegate() mutation) {
    bool rejected;
    try mutation();
    catch (Exception) rejected = true;
    need(rejected, "negative mutant accepted: " ~ label);
}

private void copyTree(string source, string destination, bool reversed) {
    auto entries = dirEntries(source, SpanMode.depth)
        .filter!(entry => entry.isFile).array;
    entries.sort!((a, b) => a.name < b.name);
    if (reversed) entries.reverse;
    foreach (entry; entries) {
        auto target = buildPath(destination, relativePath(entry.name, source));
        mkdirRecurse(dirName(target));
        copy(entry.name, target);
    }
}

private string[] substitute(string[] arguments, string input, string output,
        string htmlConfig, string textConfig) {
    string[] result;
    foreach (argument; arguments) {
        result ~= argument == "${INPUT}" ? input :
            argument == "${OUTPUT}" ? output :
            argument == "${HTML_CONFIG}" ? htmlConfig :
            argument == "${TEXT_CONFIG}" ? textConfig : argument;
    }
    return result;
}

private Captured withInput(string[] command, const(ubyte)[] input) {
    auto pipes = pipeProcess(command, Redirect.all);
    pipes.stdin.rawWrite(input);
    pipes.stdin.close();
    Captured result;
    foreach (line; pipes.stdout.byLineCopy) result.output ~= line ~ "\n";
    foreach (line; pipes.stderr.byLineCopy) result.error ~= line ~ "\n";
    result.status = pipes.pid.wait();
    return result;
}

private void sameTree(string actual, string expected, string label) {
    auto actualFiles = filesBelow(actual, "");
    auto expectedFiles = filesBelow(expected, "");
    need(actualFiles.equal(expectedFiles), label ~ " relative path set");
    foreach (path; expectedFiles)
        need(read(buildPath(actual, path)) == read(buildPath(expected, path)),
            label ~ " bytes/hash " ~ path);
}

private void rejectAllTopLevelStringsMutant(string executable, string[] jsonArgs,
        string input, string expected, string htmlConfig, string textConfig) {
    auto mutantArgs = jsonArgs.dup;
    foreach (ref argument; mutantArgs)
        if (argument == "text,title") argument = "text,title,note";
    auto mutant = withInput([executable] ~ substitute(mutantArgs, "", "",
        htmlConfig, textConfig), cast(const(ubyte)[])read(input));
    need(mutant.status == 0 && mutant.output.canFind(
        `"note":"François — must stay byte-identical"`),
        "all-top-level-string mutant did not transform unselected note");
    expectRejected("transform every top-level string", {
        need(cast(const(ubyte)[])mutant.output == read(expected),
            "all-top-level-string mutant differs from selected-field golden");
    });
}

private void runRecipes(string repository, string executable, JSONValue manifest) {
    auto htmlConfig = buildPath(repository, "examples/pipelines/quickstart/html-markdown.json");
    auto textConfig = buildPath(repository, "examples/pipelines/quickstart/text-repair.json");
    auto expected = buildPath(repository, "examples/corpus/quickstart/expected");
    auto recipes = manifest["recipes"].array;
    auto root = buildPath(tempDir, "scrubbed-quickstart-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope(exit) if (exists(root)) rmdirRecurse(root);

    foreach (iteration; 0 .. 2) {
        auto inputs = buildPath(root, "inputs-" ~ iteration.to!string);
        copyTree(buildPath(repository, "examples/corpus/quickstart/inputs"), inputs,
            iteration == 1);
        foreach (mode; 0 .. 2) {
            auto label = iteration.to!string ~ (mode == 0 ? "-config" : "-cli");

            auto htmlOutput = buildPath(root, "html-" ~ label);
            auto htmlArgs = mode == 0 ? strings(recipes[0]["configArguments"]) :
                strings(recipes[0]["cliArguments"]);
            auto html = execute([executable] ~ substitute(htmlArgs,
                buildPath(inputs, "html"), htmlOutput, htmlConfig, textConfig));
            need(html.status == 1 && html.output.canFind("2 published, 1 quarantined") &&
                html.output.canFind("depthLimit"), "HTML actual-binary quarantine " ~ label);
            sameTree(htmlOutput, buildPath(expected, "html"), "HTML " ~ label);

            auto textOutput = buildPath(root, "text-" ~ label);
            auto textArgs = mode == 0 ? strings(recipes[1]["configArguments"]) :
                strings(recipes[1]["cliArguments"]);
            auto textResult = execute([executable] ~ substitute(textArgs,
                buildPath(inputs, "text"), textOutput, htmlConfig, textConfig));
            need(textResult.status == 0, "text actual-binary exit " ~ label);
            sameTree(textOutput, buildPath(expected, "text"), "text " ~ label);

            auto jsonArgs = mode == 0 ? strings(recipes[2]["configArguments"]) :
                strings(recipes[2]["cliArguments"]);
            auto jsonResult = withInput([executable] ~ substitute(jsonArgs, "", "",
                htmlConfig, textConfig),
                cast(const(ubyte)[])read(buildPath(inputs, "records.jsonl")));
            need(jsonResult.status == 0 && cast(const(ubyte)[])jsonResult.output ==
                read(buildPath(expected, "records.jsonl")), "JSONL bytes " ~ label);

            rejectAllTopLevelStringsMutant(executable, jsonArgs,
                buildPath(inputs, "records.jsonl"), buildPath(expected, "records.jsonl"),
                htmlConfig, textConfig);
        }
    }
}

private void negativeMutants(string repository, string manifestText) {
    expectRejected("hash drift", {
        validateManifest(repository, parseJSON(manifestText.replace(
            "fb6340855e817ee81831d9263147260e915f75d893ac881ae6039ef89903743a",
            "ab6340855e817ee81831d9263147260e915f75d893ac881ae6039ef89903743a")));
    });
    expectRejected("missing attribution", {
        validateManifest(repository, parseJSON(manifestText.replace(provenance, "")));
    });
    expectRejected("missing license", {
        validateManifest(repository, parseJSON(manifestText.replace(`"license": "MIT"`,
            `"license": ""`)));
    });
    expectRejected("stale command", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"--format", "markdown", "--config"`,
            `"--format", "tree-json", "--config"`)));
    });
    expectRejected("path escape", {
        validateManifest(repository, parseJSON(manifestText.replace(
            "examples/corpus/quickstart/inputs/html/campus/index.html", "../LICENSE")));
    });
    expectRejected("false main-content claim", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"mainContentExtraction": false`, `"mainContentExtraction": true`)));
    });
    expectRejected("false training-ready claim", {
        validateManifest(repository, parseJSON(manifestText.replace(
            `"trainingReady": false`, `"trainingReady": true`)));
    });

    auto mutantRoot = buildPath(tempDir, "scrubbed-quickstart-mutant-" ~ randomUUID.toString);
    mkdirRecurse(mutantRoot);
    scope(exit) if (exists(mutantRoot)) rmdirRecurse(mutantRoot);
    foreach (path; ["examples/corpus/quickstart", "examples/pipelines/quickstart"])
        copyTree(buildPath(repository, path), buildPath(mutantRoot, path), false);
    write(buildPath(mutantRoot, "examples/pipelines/quickstart/text-repair.json"), "{}\n");
    expectRejected("stale config", {
        validateManifest(mutantRoot, parseJSON(manifestText));
    });
    copy(buildPath(repository, "examples/pipelines/quickstart/text-repair.json"),
        buildPath(mutantRoot, "examples/pipelines/quickstart/text-repair.json"));
    write(buildPath(mutantRoot,
        "examples/corpus/quickstart/expected/html/undeclared.html.md"), "extra\n");
    expectRejected("undeclared output", {
        validateManifest(mutantRoot, parseJSON(manifestText));
    });
}

int main(string[] args) {
    need(args.length == 2 || args.length == 3,
        "usage: check <release executable> [repository root]");
    auto executable = absolutePath(args[1]);
    auto repository = absolutePath(args.length == 3 ? args[2] : ".");
    auto manifestPath = buildPath(repository, "examples/corpus/quickstart/manifest.json");
    auto manifestText = readText(manifestPath);
    auto manifest = parseJSON(manifestText);
    validateManifest(repository, manifest);
    negativeMutants(repository, manifestText);
    runRecipes(repository, executable, manifest);
    need(readText(buildPath(repository, "docs/task-examples.md")).canFind(
        "not main-content extraction") && readText(buildPath(repository,
        "docs/task-examples.md")).canFind("not a training-ready corpus"),
        "documentation limitation claims");
    import std.stdio : writeln;
    writeln("quickstart check: manifest, mutants, fresh/reordered binary recipes pass");
    return 0;
}
