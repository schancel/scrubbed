/// Command-line orchestration and filesystem boundary for scrubd.
module cli;

import core.atomic : atomicLoad, atomicOp;
import filters.entities;
import filters.mojibake;
import filters.normalize;
import filters.punctuation;
import pipeline;
import std.algorithm.searching : startsWith;
import std.array : split;
import std.conv : to;
import std.file : FileException, SpanMode, dirEntries, exists, getAttributes,
    getSize, isDir, isSymlink, mkdir, mkdirRecurse, remove, rename, readText,
    setAttributes, write;
import std.getopt : config, defaultGetoptPrinter, getopt;
import std.json : JSONType, parseJSON;
import std.mmfile : MmFile;
import std.parallelism : TaskPool, totalCPUs;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath,
    dirName, dirSeparator, isAbsolute, pathSplitter, relativePath;
import std.stdio : stderr, writefln, writeln;
import std.string : join;
import std.uuid : randomUUID;

private string normalizedAbsolute(string path) {
    return buildNormalizedPath(absolutePath(path));
}

private void rejectUnresolvableAncestorLinks(string path) {
    version (Windows) {
        string current;
        foreach (part; pathSplitter(normalizedAbsolute(path))) {
            current = current.length ? buildPath(current, part) : part;
            if (exists(current) && isSymlink(current))
                throw new Exception("refusing path through reparse point: " ~ current);
        }
    }
}

private string canonicalExisting(string path) {
    version (Posix) {
        import core.stdc.stdlib : free;
        import core.sys.posix.stdlib : realpath;
        import std.string : fromStringz, toStringz;

        auto resolved = realpath(path.toStringz, null);
        if (resolved is null)
            throw new Exception("could not resolve path: " ~ path);
        scope(exit) free(resolved);
        return fromStringz(resolved).idup;
    } else {
        return normalizedAbsolute(path);
    }
}

private string resolveExistingPrefix(string path) {
    auto cursor = normalizedAbsolute(path);
    string[] suffix;
    while (!exists(cursor)) {
        suffix ~= baseName(cursor);
        auto parent = dirName(cursor);
        if (parent == cursor) break;
        cursor = parent;
    }
    cursor = canonicalExisting(cursor);
    foreach_reverse (part; suffix)
        cursor = buildPath(cursor, part);
    return cursor;
}

private bool pathIsWithin(string child, string parent) {
    const relative = relativePath(normalizedAbsolute(child), normalizedAbsolute(parent));
    if (relative == ".") return true;
    return !isAbsolute(relative) && relative != ".." &&
        !relative.startsWith(".." ~ dirSeparator);
}

private void ensurePlainDirectory(string root, string path) {
    root = normalizedAbsolute(root);
    path = normalizedAbsolute(path);
    if (!pathIsWithin(path, root))
        throw new Exception("output escaped its selected root: " ~ path);
    mkdirRecurse(root);
    if (isSymlink(root))
        throw new Exception("refusing symlink output root: " ~ root);

    string current = root;
    const relative = relativePath(path, root);
    if (relative == ".") return;
    foreach (part; pathSplitter(relative)) {
        current = buildPath(current, part);
        if (exists(current)) {
            if (isSymlink(current))
                throw new Exception("refusing output path through symlink: " ~ current);
            if (!isDir(current))
                throw new Exception("output path component is not a directory: " ~ current);
        } else {
            try {
                mkdir(current);
            } catch (FileException error) {
                // Another worker may have created this shared output
                // directory after our exists() check. Accept only the exact
                // safe state we wanted; otherwise preserve the real failure.
                if (!exists(current) || isSymlink(current) || !isDir(current))
                    throw error;
            }
        }
    }
}

/// Write beside the destination and rename into place. This makes same-file
/// input/output safe even when `content` is still a view into an MmFile, and
/// prevents readers from observing a partially-written destination.
private void atomicWrite(string destination, string outputRoot, const void[] content) {
    auto parent = dirName(normalizedAbsolute(destination));
    ensurePlainDirectory(outputRoot, parent);
    uint destinationAttributes;
    const destinationExists = exists(destination);
    if (destinationExists) {
        if (isSymlink(destination))
            throw new Exception("refusing to replace output symlink: " ~ destination);
        destinationAttributes = getAttributes(destination);
    }

    auto temporary = buildPath(parent, "." ~ baseName(destination) ~
        ".scrubd-" ~ randomUUID.toString ~ ".tmp");
    scope(failure) if (exists(temporary)) remove(temporary);
    write(temporary, content);
    if (destinationExists)
        setAttributes(temporary, destinationAttributes);
    rename(temporary, destination);
}

private FilterSpec[] loadFilterConfig(string path) {
    const root = parseJSON(readText(path));
    if (root.type != JSONType.object || "filters" !in root.object ||
        root.object["filters"].type != JSONType.array)
        throw new Exception("config must contain a 'filters' array");
    foreach (key, ignored; root.object)
        if (key != "filters")
            throw new Exception("unknown config key: " ~ key);

    FilterSpec[] specs;
    foreach (entry; root.object["filters"].array) {
        FilterSpec spec;
        if (entry.type == JSONType.string) {
            spec.name = entry.str;
        } else if (entry.type == JSONType.object && "name" in entry.object &&
                   entry.object["name"].type == JSONType.string) {
            foreach (key, ignored; entry.object)
                if (key != "name" && key != "options")
                    throw new Exception("unknown key '" ~ key ~ "' for filter entry");
            spec.name = entry.object["name"].str;
            if (auto options = "options" in entry.object) {
                if (options.type != JSONType.object)
                    throw new Exception("options for " ~ spec.name ~ " must be an object");
                foreach (key, value; options.object) {
                    final switch (value.type) {
                        case JSONType.string: spec.options[key] = value.str; break;
                        case JSONType.integer: spec.options[key] = value.integer.to!string; break;
                        case JSONType.uinteger: spec.options[key] = value.uinteger.to!string; break;
                        case JSONType.true_: spec.options[key] = "true"; break;
                        case JSONType.false_: spec.options[key] = "false"; break;
                        case JSONType.null_, JSONType.float_, JSONType.array, JSONType.object:
                            throw new Exception("option " ~ key ~ " for " ~ spec.name ~
                                " must be a string, integer, or boolean");
                    }
                }
            }
        } else {
            throw new Exception("each config filter must be a name or an object with 'name'");
        }
        specs ~= spec;
    }
    return specs;
}

void processOne(string file, string inputRoot, string outputRoot,
                bool inputIsDir, const ref Pipeline chain) {
    if (isSymlink(file))
        throw new Exception("refusing symlink input: " ~ file);

    string outPath = inputIsDir
        ? buildPath(outputRoot, relativePath(file, inputRoot))
        : outputRoot;

    if (getSize(file) == 0) {
        atomicWrite(outPath, inputIsDir ? outputRoot : dirName(outputRoot), chain.run(""));
        return;
    }

    string cleaned;
    {
        // Close the mapping before rename: Windows does not grant delete/
        // rename sharing to MmFile's read handle. Only copy when a no-op (or
        // custom slicing) filter returns storage that aliases the mapping.
        scope mm = new MmFile(file);
        auto text = cast(string)(cast(ubyte[]) mm[]);
        cleaned = chain.run(text);
        if (cleaned.length) {
            const textStart = cast(size_t) text.ptr;
            const textEnd = textStart + text.length;
            const cleanedStart = cast(size_t) cleaned.ptr;
            if (cleanedStart >= textStart && cleanedStart < textEnd)
                cleaned = cleaned.idup;
        }
    }
    atomicWrite(outPath, inputIsDir ? outputRoot : dirName(outputRoot), cleaned);
}

private bool canFindOption(const string[] args, string option) {
    foreach (arg; args)
        if (arg == option || arg.startsWith(option ~ "=")) return true;
    return false;
}

private size_t backgroundWorkers(size_t executionThreads) {
    assert(executionThreads > 0);
    return executionThreads - 1;
}

int runApp(string[] args) {
    string inputPath;
    string outputPath;
    string filterList = "normalize-line-endings,strip-control";
    string configPath;
    size_t nThreads = totalCPUs;
    bool listFilters;
    const filtersExplicit = args.canFindOption("--filters");

    auto helpInfo = getopt(args,
        config.caseSensitive,
        "input", "Input file or directory tree to process", &inputPath,
        "output", "Output path (mirrors input tree structure when --input is a directory)", &outputPath,
        "filters", "Comma-separated filter chain, applied in order", &filterList,
        "config", "JSON file containing an ordered filter list and per-filter options", &configPath,
        "threads", "Worker thread count for the TaskPool (default: all cores)", &nThreads,
        "list-filters", "Print registered filter names and exit", &listFilters);
    if (helpInfo.helpWanted) {
        defaultGetoptPrinter("scrubd", helpInfo.options);
        return 0;
    }
    if (listFilters) {
        writeln("registered filters: ", availableFilters.join(", "));
        return 0;
    }
    if (inputPath.length == 0 || outputPath.length == 0) {
        stderr.writeln("--input and --output are required (--list-filters to see what's available)");
        return 2;
    }
    if (nThreads == 0)
        throw new Exception("--threads must be positive");
    if (configPath.length && filtersExplicit)
        throw new Exception("--config and --filters are mutually exclusive");
    if (!exists(inputPath))
        throw new Exception("input path does not exist: " ~ inputPath);
    if (isSymlink(inputPath))
        throw new Exception("refusing symlink input root: " ~ inputPath);
    if (exists(outputPath) && isSymlink(outputPath))
        throw new Exception("refusing symlink output path: " ~ outputPath);
    rejectUnresolvableAncestorLinks(inputPath);
    rejectUnresolvableAncestorLinks(outputPath);
    inputPath = resolveExistingPrefix(inputPath);
    outputPath = resolveExistingPrefix(outputPath);

    auto chain = configPath.length
        ? Pipeline.buildConfigured(loadFilterConfig(configPath))
        : Pipeline.build(filterList.split(","));
    writeln("filter chain: ", chain.names.join(" -> "));

    string[] files;
    const inputIsDir = isDir(inputPath);
    if (inputIsDir) {
        if (pathIsWithin(outputPath, inputPath))
            throw new Exception("output directory must not be inside the input tree");
        foreach (entry; dirEntries(inputPath, SpanMode.depth, false)) {
            if (entry.isSymlink)
                throw new Exception("refusing symlink in input tree: " ~ entry.name);
            if (entry.isFile)
                files ~= entry.name;
        }
    } else {
        files ~= inputPath;
    }
    ensurePlainDirectory(inputIsDir ? outputPath : dirName(outputPath),
        inputIsDir ? outputPath : dirName(outputPath));
    writeln("processing ", files.length, " file(s) across ", nThreads, " thread(s)");

    // TaskPool.parallel also runs one task on the caller, so N requested
    // execution threads means N-1 background workers plus this thread.
    auto pool = new TaskPool(backgroundWorkers(nThreads));
    scope(exit) pool.finish();

    shared size_t failed;
    foreach (file; pool.parallel(files)) {
        try {
            processOne(file, inputPath, outputPath, inputIsDir, chain);
        } catch (Exception error) {
            stderr.writefln("SKIP %s: %s", file, error.msg);
            failed.atomicOp!"+="(1);
        }
    }
    const failures = failed.atomicLoad;
    writeln("done. ", files.length - failures, " succeeded, ", failures, " failed.");
    return failures == 0 ? 0 : 1;
}

unittest {
    import std.exception : assertThrown;
    import std.file : rmdirRecurse, tempDir;

    auto root = buildPath(tempDir, "scrubd-cli-" ~ randomUUID.toString);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    mkdir(root);
    assert(runApp(["scrubd"]) == 2);
    assert(backgroundWorkers(1) == 0);
    assert(backgroundWorkers(4) == 3);

    auto same = buildPath(root, "same.txt");
    write(same, "already clean");
    assert(runApp(["scrubd", "--input", same, "--output", same,
        "--filters", "fix-mojibake", "--threads", "1"]) == 0);
    assert(readText(same) == "already clean");

    auto empty = buildPath(root, "empty.txt");
    auto emptyOut = buildPath(root, "empty-out.txt");
    write(empty, "");
    assert(runApp(["scrubd", "--input", empty, "--output", emptyOut,
        "--threads", "1"]) == 0);
    assert(exists(emptyOut) && getSize(emptyOut) == 0);

    auto inputDir = buildPath(root, "input");
    mkdir(inputDir);
    assertThrown(runApp(["scrubd", "--input", inputDir,
        "--output", buildPath(inputDir, "out"), "--threads", "1"]));
    assertThrown(runApp(["scrubd", "--input", same, "--output", emptyOut,
        "--config", "x.json", "--filters", "fix-mojibake"]));
    assertThrown(runApp(["scrubd", "--input", same, "--output", emptyOut,
        "--config", "x.json", "--FILTERS", "fix-mojibake"]));
    assertThrown(runApp(["scrubd", "--input", same, "--output", emptyOut,
        "--threads", "0"]));

    auto badConfig = buildPath(root, "bad.json");
    write(badConfig, `{ "filters": [{ "name": "fix-mojibake", ` ~
        `"options": { "max-pass": 0 } }] }`);
    assertThrown(runApp(["scrubd", "--input", same, "--output", emptyOut,
        "--config", badConfig, "--threads", "1"]));

    auto invalidValueConfig = buildPath(root, "invalid-value.json");
    write(invalidValueConfig, `{ "filters": [{ "name": "fix-mojibake", ` ~
        `"options": { "max-passes": "bad" } }] }`);
    auto noFiles = buildPath(root, "no-files");
    auto noFilesOutput = buildPath(root, "no-files-output");
    mkdir(noFiles);
    assertThrown(runApp(["scrubd", "--input", noFiles,
        "--output", noFilesOutput, "--config", invalidValueConfig,
        "--threads", "1"]));
    assert(!exists(noFilesOutput));

    auto validConfig = buildPath(root, "valid.json");
    write(validConfig, `{ "filters": ["uncurl-quotes", ` ~
        `{ "name": "fix-mojibake", "options": { "max-passes": 0, ` ~
        `"encodings": "cp1252" } }, "strip-control"] }`);
    auto configuredInput = buildPath(root, "configured.txt");
    auto configuredOutput = buildPath(root, "configured-output.txt");
    write(configuredInput, "“schÃ¶n”\0");
    assert(runApp(["scrubd", "--input", configuredInput,
        "--output", configuredOutput, "--config", validConfig,
        "--threads", "1"]) == 0);
    assert(readText(configuredOutput) == `"schÃ¶n"`);

    auto blockedParent = buildPath(root, "not-a-directory");
    write(blockedParent, "x");
    assertThrown(runApp(["scrubd", "--input", same,
        "--output", buildPath(blockedParent, "out.txt"), "--threads", "1"]));

    auto invalidUtf8 = buildPath(root, "invalid-utf8.bin");
    write(invalidUtf8, [cast(ubyte) 0xFF]);
    assert(runApp(["scrubd", "--input", invalidUtf8,
        "--output", buildPath(root, "invalid-output.txt"),
        "--threads", "1"]) == 1);

    auto sharedInput = buildPath(root, "shared-input", "nested");
    mkdirRecurse(sharedInput);
    foreach (index; 0 .. 64)
        write(buildPath(sharedInput, index.to!string ~ ".txt"), "clean");
    auto sharedOutput = buildPath(root, "shared-output");
    assert(runApp(["scrubd", "--input", dirName(sharedInput),
        "--output", sharedOutput, "--filters", "fix-mojibake",
        "--threads", "4"]) == 0);
    foreach (index; 0 .. 64)
        assert(readText(buildPath(sharedOutput, "nested",
            index.to!string ~ ".txt")) == "clean");

    version (Posix) {
        import std.file : symlink;
        auto link = buildPath(root, "input-link");
        symlink(same, link);
        assertThrown(runApp(["scrubd", "--input", link,
            "--output", emptyOut, "--threads", "1"]));

        auto external = buildPath(root, "external.txt");
        auto outputLink = buildPath(root, "output-link.txt");
        write(external, "must survive");
        symlink(external, outputLink);
        assertThrown(runApp(["scrubd", "--input", same,
            "--output", outputLink, "--threads", "1"]));
        assert(readText(external) == "must survive");

        auto treeLink = buildPath(inputDir, "outside-link");
        symlink(external, treeLink);
        assertThrown(runApp(["scrubd", "--input", inputDir,
            "--output", buildPath(root, "tree-output"), "--threads", "1"]));
    }
}
