/// Command-line orchestration and filesystem boundary for scrubbed.
module cli;

import composition.compiler : CompiledJob, compileJob;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import effects.bounded_input : BoundedInput, InputLimits;
import effects.jsonl_stream : JsonlFailure, JsonlLimits;
import effects.stdio_stream : processStandardJsonl;
import effects.local_manifest : LocalManifest, SinkKey, Inspection, SinkState,
    configDigest, inputDigest, outputDigest;
import effects.failure_journal : FailureJournal;
import effects.atomic_piece_sink : OutputPolicyViolation, ResourceExhaustion,
    writeAtomicPieces;
import effects.failure_policy : recordDocumentFailure;
import effects.local_job : LocalJobOutcome, runLocalJob;
import effects.runner : EffectFailure, EffectPhase;
import domain.failure : FailureClass, FailurePhase, FailureRecord;
import content.pieces : Content, ContentPiece;
import domain.document : Document, DocumentId, OutputName, SourceLocator;
import effects.html_tree : checkedHtmlByteLimit, defaultExtractHtmlBytes;
import effects.html_tree_json_stage : htmlTreeJsonPlan;
import effects.html_markdown_stage : htmlMarkdownPlan;
import stages.contract : EventKind, ResourceDeclaration, StageDeclaration,
    StageDocument, StageEvent, runStage;
import stages.config : buildConfigV2;
import stages.text_transform;
import job.cli_tokens : parseJobTokens;
import job.json : jobIdentity, parseJobJson;
import job.legacy : lowerLegacyDefault, lowerLegacyJson, lowerLegacyNames;
import job.spec : JobSpec;
import filters.entities;
import filters.mojibake;
import filters.normalize;
import filters.punctuation;
import pipeline;
import std.algorithm.searching : canFind, startsWith;
import std.algorithm.iteration : map;
import std.algorithm.sorting : sort;
import std.array : array, split;
import std.conv : to;
import std.file : FileException, SpanMode, dirEntries, exists, getAttributes,
    getSize, isDir, isFile, isSymlink, mkdir, mkdirRecurse, remove, rename, readText,
    setAttributes, write, thisExePath;
import std.getopt : config, defaultGetoptPrinter, getopt;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
import std.mmfile : MmFile;
import std.parallelism : totalCPUs;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath,
    dirName, dirSeparator, isAbsolute, pathSplitter, relativePath;
import std.stdio : File, stderr, writefln, writeln;
import std.string : indexOf, join;
import std.typecons : Nullable;
import std.utf : UTFException, validate;
import std.uuid : randomUUID;
import std.digest.sha : SHA256;
import core.stdc.errno : errno, EINTR;
import core.sys.posix.fcntl : open, O_RDONLY, O_NOFOLLOW;
import core.sys.posix.sys.stat : fstat, stat, stat_t, S_ISREG;
import core.sys.posix.unistd : close, posixRead = read;
import std.string : toStringz;

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

/// Check the output route without creating it. Traversal still checks every
/// component again at write time, since another process may change the tree.
private void preflightOutput(string outputPath, bool inputIsDir) {
    auto directory = inputIsDir ? outputPath : dirName(outputPath);
    auto current = normalizedAbsolute(directory);
    while (!exists(current)) {
        auto parent = dirName(current);
        if (parent == current) break;
        current = parent;
    }
    if (isSymlink(current) || !isDir(current))
        throw new Exception("output ancestor is not a plain directory: " ~ current);
    if (inputIsDir && exists(outputPath) && !isDir(outputPath))
        throw new Exception("output directory is not a directory: " ~ outputPath);
    if (!inputIsDir && exists(outputPath) && isDir(outputPath))
        throw new Exception("output file is a directory: " ~ outputPath);
}

private void preflightDestination(string destination, string outputRoot) {
    auto current = dirName(normalizedAbsolute(destination));
    auto root = normalizedAbsolute(outputRoot);
    if (!pathIsWithin(current, root))
        throw new Exception("output escaped its selected root: " ~ destination);
    while (pathIsWithin(current, root)) {
        if (exists(current) && (isSymlink(current) || !isDir(current)))
            throw new Exception("output path component is not a plain directory: " ~ current);
        if (current == root) break;
        current = dirName(current);
    }
    if (exists(destination) && (isSymlink(destination) || isDir(destination)))
        throw new Exception("output destination is not a plain file: " ~ destination);
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
        ".scrubbed-" ~ randomUUID.toString ~ ".tmp");
    scope(failure) if (exists(temporary)) remove(temporary);
    write(temporary, content);
    if (destinationExists)
        setAttributes(temporary, destinationAttributes);
    rename(temporary, destination);
}

private FilterSpec[] parseFilterConfig(string contents) {
    const root = parseJSON(contents);
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

private FilterSpec[] loadFilterConfig(string path) {
    return parseFilterConfig(readText(path));
}

private string destinationFor(string file, string inputRoot, string outputRoot,
                              bool inputIsDir) {
    return inputIsDir ? buildPath(outputRoot, relativePath(file, inputRoot)) : outputRoot;
}

/// Opt-in local selected-tree export. It does not use the filter/manifest route.
int runExtract(string requestedInput, string requestedOutput,
    string declaredCharset = null, string format = "tree-json",
    ulong requestedHtmlBytes = 0, string configPath = null) {
    if (configPath.length && (requestedHtmlBytes != 0 || declaredCharset !is null))
        throw new Exception("extract --config cannot be combined with HTML stage options");
    auto byteLimit = requestedHtmlBytes == 0 ? defaultExtractHtmlBytes :
        checkedHtmlByteLimit(requestedHtmlBytes);
    if (!exists(requestedInput) || isSymlink(requestedInput))
        throw new Exception("extract input must be an existing plain path");
    if (exists(requestedOutput) && isSymlink(requestedOutput))
        throw new Exception("extract output must not be a symlink");
    rejectUnresolvableAncestorLinks(requestedInput);
    rejectUnresolvableAncestorLinks(requestedOutput);
    auto input = resolveExistingPrefix(requestedInput);
    auto output = resolveExistingPrefix(requestedOutput);
    const isTree = isDir(input);
    if (!isTree && !isFile(input))
        throw new Exception("extract input is not a regular file or directory");
    if (isTree && pathIsWithin(output, input))
        throw new Exception("extract output must not be inside input tree");
    preflightOutput(output, isTree);
    auto sourceRoot = isTree ? input : dirName(input);
    auto outputRoot = isTree ? output : dirName(output);
    auto plan = configPath.length ? buildConfigV2(readText(configPath)) :
        (format == "markdown" ? htmlMarkdownPlan(declaredCharset, byteLimit) :
        htmlTreeJsonPlan(declaredCharset, byteLimit));
    auto expectedStage = format == "markdown" ? "html-markdown" : "html-tree-json";
    if (plan.stages.length != 1 || plan.stages[0].declaration.key != expectedStage)
        throw new Exception("extract config must contain exactly one " ~ expectedStage ~ " stage");
    auto configuredLimit = "max-html-bytes" in plan.stages[0].options;
    byteLimit = configuredLimit is null ? defaultExtractHtmlBytes :
        checkedHtmlByteLimit(configuredLimit.asInteger());
    auto specification = plan.stages[0].declaration;
    auto stage = StageDeclaration(specification.key.idup, specification.passMode,
        ResourceDeclaration(specification.resources.cpuSlots,
            specification.resources.memoryBytes));
    size_t quarantined, published;
    auto scheduler = new BoundedInput(InputLimits(1, byteLimit + 1, 1), 1,
        (string file, ulong reservedBytes) {
            if (isSymlink(file) || !isFile(file))
                throw new Exception("extract input changed to non-regular file: " ~ file);
            auto recordKey = relativePath(file, sourceRoot);
            auto name = recordKey ~ (format == "markdown" ? ".md" : ".tree.json");
            auto destination = isTree ? buildPath(output, name) : output;
            preflightDestination(destination, outputRoot);
            stat_t inputStat, outputStat;
            if (stat(file.toStringz, &inputStat) != 0)
                throw new Exception("cannot stat extract input: " ~ file);
            if (exists(destination) && stat(destination.toStringz, &outputStat) == 0 &&
                inputStat.st_dev == outputStat.st_dev && inputStat.st_ino == outputStat.st_ino)
                throw new Exception("extract output aliases input: " ~ destination);
            auto document = Document(SourceLocator("local-html:v1", sourceRoot,
                recordKey), OutputName(name));
            if (reservedBytes > byteLimit) {
                stderr.writefln("SKIP %s DocumentId %s: rawLimit", file, document.id.text);
                ++quarantined;
                return;
            }
            ubyte[] raw = new ubyte[cast(size_t)reservedBytes];
            {
                scope source = File(file, "rb");
                if (source.size != reservedBytes)
                    throw new Exception("extract input changed size after admission: " ~ file);
                if (source.rawRead(raw).length != raw.length || source.size != reservedBytes)
                    throw new Exception("extract input changed while reading: " ~ file);
            }
            auto content = new Content([ContentPiece.own(raw)]);
            auto result = runStage([StageDocument(document, content)], stage,
                plan.stages[0].transform);
            if (result.events.length != 1)
                throw new Exception("extract stage produced unexpected decision count");
            auto event = result.events[0];
            if (event.kind == EventKind.quarantined || event.kind == EventKind.rejected) {
                stderr.writefln("SKIP %s DocumentId %s: %s", file,
                    document.id.text, event.reason);
                ++quarantined;
                return;
            }
            if (event.kind != EventKind.emitted || event.payload.document.id != document.id)
                throw new Exception("extract stage changed document identity");
            ensurePlainDirectory(outputRoot, dirName(destination));
            writeAtomicPieces(destination, event.payload.content.pieces());
            ++published;
        }, (string file, Throwable error) {
            stderr.writefln("FATAL %s: %s", file, error.msg);
        }, (Throwable error) { return true; });
    try {
        if (isTree) {
            foreach (entry; dirEntries(input, SpanMode.depth, false)) {
                if (entry.isSymlink)
                    throw new Exception("refusing symlink in extract input tree: " ~ entry.name);
                if (!entry.isFile) continue;
                auto size = getSize(entry.name);
                if (!scheduler.submit(entry.name, size > byteLimit ? byteLimit + 1 : size))
                    throw new Exception("extract admission canceled");
            }
        } else {
            auto size = getSize(input);
            if (!scheduler.submit(input, size > byteLimit ? byteLimit + 1 : size))
                throw new Exception("extract admission canceled");
        }
    } catch (Exception error) {
        scheduler.cancel();
        scheduler.finish();
        throw error;
    }
    scheduler.finish();
    if (scheduler.fatal() !is null)
        throw new Exception("fatal extract processing failure: " ~ scheduler.fatal().msg);
    stderr.writefln("extract done: %s published, %s quarantined", published,
        quarantined);
    return quarantined ? 1 : 0;
}

/// Returns whether the filter chain changed the document. In dry-run mode the
/// same mapping and filter path executes, but no output path is created.
bool processOne(string file, string inputRoot, string outputRoot,
                bool inputIsDir, const ref Pipeline chain, ulong reservedBytes,
                bool dryRun = false) {
    if (isSymlink(file))
        throw new Exception("refusing symlink input: " ~ file);

    string outPath = destinationFor(file, inputRoot, outputRoot, inputIsDir);
    preflightDestination(outPath, inputIsDir ? outputRoot : dirName(outputRoot));

    if (reservedBytes == 0) {
        // MmFile cannot map an empty file. Check size on an opened handle so
        // growth between traversal and open cannot bypass the byte budget.
        {
            scope input = File(file, "rb");
            if (input.size != 0)
                throw new Exception("input changed size after admission: " ~ file);
        }
        auto cleanedEmpty = chain.run("");
        if (!dryRun)
            atomicWrite(outPath, inputIsDir ? outputRoot : dirName(outputRoot), cleanedEmpty);
        return cleanedEmpty.length != 0;
    }

    string cleaned;
    bool changed;
    {
        if (getSize(file) != reservedBytes)
            throw new Exception("input changed size after admission: " ~ file);
        // Close the mapping before rename: Windows does not grant delete/
        // rename sharing to MmFile's read handle. Only copy when a no-op (or
        // custom slicing) filter returns storage that aliases the mapping.
        // A fixed-size map cannot transiently map beyond the byte token if
        // the file grows after traversal but before this open.
        scope mm = new MmFile(file, MmFile.Mode.read, reservedBytes, null);
        if (getSize(file) != reservedBytes)
            throw new Exception("input changed size after admission: " ~ file);
        auto text = cast(string)(cast(ubyte[]) mm[]);
        cleaned = chain.run(text);
        changed = cleaned != text;
        if (cleaned.length) {
            const textStart = cast(size_t) text.ptr;
            const textEnd = textStart + text.length;
            const cleanedStart = cast(size_t) cleaned.ptr;
            if (cleanedStart >= textStart && cleanedStart < textEnd)
                cleaned = cleaned.idup;
        }
    }
    if (!dryRun)
        atomicWrite(outPath, inputIsDir ? outputRoot : dirName(outputRoot), cleaned);
    return changed;
}

private LocalJobOutcome processCompiledOne(string file, string inputRoot,
        string outputRoot, bool inputIsDir, const ref CompiledJob job,
        ulong reservedBytes, bool dryRun, PublicationOrder publication) {
    auto relative = inputIsDir ? relativePath(file, inputRoot) : ".";
    auto rootDestination = destinationFor(file, inputRoot, outputRoot, inputIsDir);
    auto document = Document(SourceLocator("local-files:v1", inputRoot, relative),
        OutputName(inputIsDir ? relative : baseName(outputRoot)));
    auto ordinal = publication.ordinal(file);
    bool entered;
    try {
        auto result = runLocalJob(file, reservedBytes, document, job,
            (const ref StageEvent event) {
                if (!event.isChild) return rootDestination;
                auto selectedRoot = inputIsDir ? outputRoot : dirName(outputRoot);
                return buildPath(selectedRoot,
                    checkedOutputName(event.payload.document.outputName.text));
            },
            (string destination, const ref StageEvent event) {
                auto selectedRoot = inputIsDir ? outputRoot : dirName(outputRoot);
                publication.reserve(normalizedAbsolute(destination));
                if (event.isChild && exists(destination))
                    throw new OutputPolicyViolation(
                        "derived output already exists: " ~ destination);
                preflightDestination(destination, selectedRoot);
                if (!dryRun)
                    ensurePlainDirectory(selectedRoot,
                        dirName(normalizedAbsolute(destination)));
            },
            () {
                publication.enter(ordinal);
                entered = true;
            }, dryRun);
        // Every valid compiled job emits at least one terminal event, so entering
        // publication is part of completing a root.
        if (!entered) throw new Exception("compiled job produced no terminal decision");
        publication.complete();
        return result;
    } catch (Throwable error) {
        publication.fail(ordinal);
        throw error;
    }
}

private string explanationRecord(string file, string destination, string chain,
                                 string decision, string reason = "",
                                 string detail = "", string documentId = "",
                                 string sinkKey = "") {
    auto record = "EXPLAIN\tinput=" ~ JSONValue(file).toString ~
        "\toutput=" ~ JSONValue(destination).toString ~
        "\tchain=" ~ JSONValue(chain).toString ~
        "\tstatus=" ~ decision;
    if (reason.length) record ~= "\treason=" ~ JSONValue(reason).toString;
    if (detail.length) record ~= "\tdetail=" ~ JSONValue(detail).toString;
    if (sinkKey.length)
        record ~= "\tdocument_id=" ~ JSONValue(documentId).toString ~
            "\tsink_key=" ~ JSONValue(sinkKey).toString;
    return record;
}

private void explainOne(string file, string destination, string chain,
                        string decision, string reason = "", string detail = "",
                        string documentId = "", string sinkKey = "") {
    writeln(explanationRecord(file, destination, chain, decision, reason, detail,
        documentId, sinkKey));
}

/// Only admitted or admission-blocked paths live here. The scheduler bounds
/// this set to its queued/active reservation plus one waiting producer.
private final class PendingExplanations {
    private Mutex mutex;
    private bool[string] paths;

    this() { mutex = new Mutex; }

    void add(string path) {
        mutex.lock();
        scope(exit) mutex.unlock();
        paths[path] = true;
    }

    void remove(string path) {
        mutex.lock();
        scope(exit) mutex.unlock();
        paths.remove(path);
    }

    string[] drain() {
        mutex.lock();
        scope(exit) mutex.unlock();
        string[] remaining;
        foreach (path; paths.keys) remaining ~= path;
        paths = null;
        return remaining;
    }
}

private bool canFindOption(const string[] args, string option) {
    foreach (arg; args)
        if (arg == option || arg.startsWith(option ~ "=")) return true;
    return false;
}

private bool isCompositionOption(string value, out string name) {
    foreach (candidate; ["--stage", "--stage-option", "--filter", "--filter-option"])
        if (value == candidate || value.startsWith(candidate ~ "=")) {
            name = candidate;
            return true;
        }
    return false;
}

/// Remove composition-only options before std.getopt while retaining their
/// exact cross-option declaration order for the canonical token parser.
private string[] takeCompositionTokens(ref string[] args) {
    string[] kept = args.length ? [args[0]] : null;
    string[] tokens;
    for (size_t i = args.length ? 1 : 0; i < args.length; ++i) {
        string name;
        if (!isCompositionOption(args[i], name)) {
            kept ~= args[i];
            continue;
        }
        auto separator = args[i].indexOf('=');
        if (separator >= 0) {
            tokens ~= [name, args[i][separator + 1 .. $]];
        } else {
            if (i + 1 >= args.length)
                throw new Exception("missing value for " ~ name);
            tokens ~= [name, args[++i]];
        }
    }
    args = kept;
    return tokens;
}

private bool hasJobVersion(string json) {
    auto root = parseJSON(json, 16,
        JSONOptions.strictParsing | JSONOptions.preserveObjectOrder);
    if (root.type != JSONType.object) return false;
    foreach (ref member; root.orderedObject)
        if (member.key == "version") return true;
    return false;
}

private JobSpec selectedJob(string[] compositionTokens, bool filtersExplicit,
        string filterList, bool configExplicit, string configContents,
        bool versionedConfig) {
    if (compositionTokens.length) return parseJobTokens(compositionTokens);
    if (configExplicit)
        return versionedConfig ? parseJobJson(configContents) :
            lowerLegacyJson(configContents);
    if (filtersExplicit) return lowerLegacyNames(filterList.split(","));
    return lowerLegacyDefault();
}

private final class PublicationOrder {
    private Mutex mutex;
    private Condition changed;
    private size_t next;
    private bool stopped;
    private bool[string] destinations;
    private size_t[string] ordinals;
    private size_t assigned;

    this() {
        mutex = new Mutex;
        changed = new Condition(mutex);
    }

    void enter(size_t ordinal) {
        mutex.lock();
        while (!stopped && ordinal != next) changed.wait();
        if (stopped) {
            mutex.unlock();
            throw new OrderedPublicationCanceled;
        }
        mutex.unlock();
    }

    void assign(string path) {
        mutex.lock();
        ordinals[path] = assigned++;
        mutex.unlock();
    }

    size_t ordinal(string path) {
        mutex.lock();
        auto found = path in ordinals;
        if (found is null) {
            mutex.unlock();
            throw new Exception("missing publication ordinal");
        }
        auto result = *found;
        mutex.unlock();
        return result;
    }

    void reserve(string destination) {
        mutex.lock();
        scope(exit) mutex.unlock();
        if (destination in destinations)
            throw new OutputPolicyViolation("output collision: " ~ destination);
        destinations[destination] = true;
    }

    void complete() {
        mutex.lock();
        ++next;
        changed.notifyAll();
        mutex.unlock();
    }

    /// Sequence a processing failure behind every earlier canonical root.
    /// The winning failure stops later publication; later failures and
    /// waiters become cancellation outcomes so they cannot replace its cause.
    void fail(size_t ordinal) {
        mutex.lock();
        while (!stopped && ordinal != next) changed.wait();
        if (stopped) {
            mutex.unlock();
            throw new OrderedPublicationCanceled;
        }
        stopped = true;
        changed.notifyAll();
        mutex.unlock();
    }

    void abort() {
        mutex.lock();
        stopped = true;
        changed.notifyAll();
        mutex.unlock();
    }
}

private final class OrderedPublicationCanceled : Exception {
    this() { super("ordered publication canceled after an earlier fatal root"); }
}

private string effectFailureDetail(EffectFailure failure) {
    return "completed-root-prefix=" ~ failure.completed.to!string ~
        ";committed-event-prefix=" ~ failure.eventOrdinal.to!string ~
        ";partial-write-possible=" ~ failure.partialWritePossible.to!string;
}

private string checkedOutputName(string name) {
    if (isAbsolute(name)) throw new OutputPolicyViolation("split output name is absolute");
    bool previousSeparator = true;
    foreach (character; name) {
        version (Windows) const separator = character == '/' || character == '\\';
        else const separator = character == '/';
        if (separator && previousSeparator)
            throw new OutputPolicyViolation("split output name has empty component");
        previousSeparator = separator;
    }
    if (previousSeparator)
        throw new OutputPolicyViolation("split output name has empty component");
    string[] parts;
    foreach (part; pathSplitter(name)) {
        if (!part.length || part == "." || part == "..")
            throw new OutputPolicyViolation("split output name has unsafe component");
        parts ~= part;
    }
    if (!parts.length) throw new OutputPolicyViolation("split output name is empty");
    return buildPath(parts);
}

private bool sameFile(string a, string b) {
    if (!exists(a) || !exists(b)) return false;
    stat_t left, right;
    if (stat(a.toStringz, &left) != 0 || stat(b.toStringz, &right) != 0)
        throw new Exception("cannot stat manifest route");
    return left.st_dev == right.st_dev && left.st_ino == right.st_ino;
}

private void preflightManifest(string path, string inputPath, string outputPath,
                               bool inputIsDir) {
    if (!path.length) throw new Exception("--manifest path is required");
    foreach (candidate; [path, path ~ "-wal", path ~ "-shm"]) {
        auto resolved = resolveExistingPrefix(candidate);
        bool link;
        try link = isSymlink(candidate);
        catch (FileException failure) { if (exists(candidate)) throw failure; }
        if (link || (exists(candidate) && !isFile(candidate)))
            throw new Exception("manifest and companions must be plain files");
        if ((inputIsDir && pathIsWithin(resolved, inputPath)) ||
            (!inputIsDir && (resolved == inputPath || sameFile(candidate, inputPath))) ||
            (inputIsDir && pathIsWithin(resolved, outputPath)) ||
            (!inputIsDir && (resolved == outputPath || sameFile(candidate, outputPath))))
            throw new Exception("manifest and companions must be outside input and output");
        if (exists(candidate)) {
            // A hard link to any tree member would be expensive to discover;
            // reject every multiply linked DB/companion instead.
            stat_t info;
            if (stat(candidate.toStringz, &info) != 0 || info.st_nlink != 1)
                throw new Exception("manifest companion has a hard-link alias");
        }
    }
}

private ubyte[32] runningExecutableDigest() {
    auto path = thisExePath();
    if (!path.length || isSymlink(path))
        throw new Exception("cannot prove running executable path");
    stat_t before, opened, after;
    if (stat(path.toStringz, &before) != 0 || !S_ISREG(before.st_mode))
        throw new Exception("cannot stat running executable");
    int fd = open(path.toStringz, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) throw new Exception("cannot open running executable");
    scope(exit) close(fd);
    if (fstat(fd, &opened) != 0 || !S_ISREG(opened.st_mode) ||
        before.st_dev != opened.st_dev || before.st_ino != opened.st_ino ||
        before.st_size != opened.st_size)
        throw new Exception("running executable changed before hashing");
    SHA256 digest;
    ubyte[64 * 1024] buffer;
    ulong total;
    while (true) {
        auto n = posixRead(fd, buffer.ptr, buffer.length);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) throw new Exception("running executable read failed");
        if (n == 0) break;
        digest.put(buffer[0 .. cast(size_t)n]);
        total += cast(ulong)n;
    }
    if (stat(path.toStringz, &after) != 0 ||
        opened.st_dev != after.st_dev || opened.st_ino != after.st_ino ||
        opened.st_size != after.st_size || total != cast(ulong)opened.st_size)
        throw new Exception("running executable changed while hashing");
    return digest.finish();
}

private void appendField(ref string bytes, string field) {
    bytes ~= field.length.to!string ~ ":" ~ field;
}

private ubyte[32] manifestConfig(string filterList, string configContents,
                                  bool configured,
                                  string outputPath, bool inputIsDir) {
    string bytes = "scrubbed:cli-output:v1;";
    appendField(bytes, configured ? "config" : "filters");
    appendField(bytes, configured ? configContents : filterList);
    appendField(bytes, inputIsDir ? "tree" : "file");
    appendField(bytes, outputPath);
    appendField(bytes, "utf8-text:atomic-piece:v1");
    appendField(bytes, cast(string)runningExecutableDigest()[]);
    return configDigest(cast(const(ubyte)[])bytes);
}

version (ManifestCliHarness) {
    // A separate release-mode D harness binary injects deterministic process
    // crashes. This branch is absent from the shipping executable.
    private void manifestKillAt(string databasePath, string phase) {
        import core.sys.posix.signal : kill, SIGKILL;
        import core.sys.posix.unistd : getpid;
        if (exists(databasePath ~ ".kill-" ~ phase))
            kill(getpid(), SIGKILL);
    }
}

private struct ManifestOutcome {
    string status;
    string detail;
    SinkKey key;
    bool hasKey;
}

private ManifestOutcome manifestOutcome(string status, string detail, SinkKey key) {
    return ManifestOutcome(status, detail, key, true);
}

private class ManifestDecisionFailure : Exception {
    string status;
    DocumentId documentId;
    string sinkKey;
    this(string status, string message, DocumentId documentId, string sinkKey) {
        super(message);
        this.status = status;
        this.documentId = documentId;
        this.sinkKey = sinkKey;
    }
}

private class FatalManifestPreFilter : Exception {
    SinkKey key;
    this(SinkKey key, Exception cause) {
        super("fatal manifest pre-filter operation: " ~ cause.msg);
        this.key = key;
    }
}

private class FatalPlannedFailure : Exception {
    SinkKey key;
    this(SinkKey key, Exception cause) {
        super("fatal pre-sink failure: " ~ cause.msg);
        this.key = key;
    }
}

private class DocumentFailure : Exception {
    FailureRecord record;
    this(FailureRecord record) {
        super(record.reason);
        this.record = record;
    }
}

private class FatalDocumentFailure : Exception {
    FailureRecord record;
    bool acknowledged;
    this(FailureRecord record, Exception cause, bool acknowledged) {
        super("fatal document failure: " ~ cause.msg);
        this.record = record;
        this.acknowledged = acknowledged;
    }
}

private class V2DocumentFailure : Exception {
    SinkKey key;
    string status;
    string phase;
    string code;
    bool hasPublicSink;
    this(SinkKey key, string status, string phase, string code,
            bool hasPublicSink) {
        super(code);
        this.key = key;
        this.status = status;
        this.phase = phase;
        this.code = code;
        this.hasPublicSink = hasPublicSink;
    }
}

private class V2FatalFailure : Exception {
    this() { super("error-journal-fatal"); }
}

private void v2Explain(string status, SinkKey key, string sinkId,
        string phase = "", string code = "") {
    auto line = "EXPLAIN\tstatus=" ~ status ~ "\tphase=" ~ phase ~
        "\tcode=" ~ code ~ "\tdocument_id=" ~ key.document.text;
    if (sinkId.length) line ~= "\tsink_id=" ~ sinkId;
    writeln(line);
}

private ManifestOutcome processV2One(FailureJournal journal, string databasePath,
        string file, string inputRoot, string outputRoot, bool inputIsDir,
        const ref Pipeline chain, ulong reservedBytes, ubyte[32] configHash,
        bool retry, bool targeted) {
    // Until the input digest is trustworthy there is no key to journal.
    if (isSymlink(file) || getSize(file) != reservedBytes)
        throw new V2FatalFailure;
    scope mm = reservedBytes ? new MmFile(file, MmFile.Mode.read, reservedBytes, null) : null;
    string text;
    if (mm !is null) text = cast(string)(cast(ubyte[])mm[]);
    else {
        scope source = File(file, "rb");
        if (source.size != 0) throw new V2FatalFailure;
    }
    if (getSize(file) != reservedBytes) throw new V2FatalFailure;
    auto relative = inputIsDir ? relativePath(file, inputRoot) : ".";
    auto id = DocumentId.from(SourceLocator("local-files:v1", inputRoot, relative));
    SinkKey key = SinkKey(id, inputDigest(cast(const(ubyte)[])text),
        configHash, "local-primary:v1");
    if (targeted && !journal.hasOutstanding(key))
        throw new V2DocumentFailure(key, "target-mismatch", "inspect",
            "target-mismatch", true);
    auto destination = destinationFor(file, inputRoot, outputRoot, inputIsDir);
    bool replacing;
    try {
        preflightDestination(destination, inputIsDir ? outputRoot : dirName(outputRoot));
        ensurePlainDirectory(inputIsDir ? outputRoot : dirName(outputRoot),
            dirName(destination));
        journal.requireDestinationOwner(key, destination);
        auto inspected = journal.inspect(key);
        if (inspected == Inspection.verifiedCommitted)
            return manifestOutcome("skipped", "", key);
        auto previous = journal.lookup(key);
        bool destinationExists = exists(destination);
        bool unresolved = !previous.isNull &&
            (previous.get.state != SinkState.planned || journal.hasOutstanding(key));
        if (!retry && (destinationExists || unresolved))
            throw new V2DocumentFailure(key,
                !previous.isNull && previous.get.state == SinkState.uncertain ?
                    "uncertain" : "retry-required", "inspect", "retry-required",
                    !previous.isNull);
        journal.plan(key, destination);
        replacing = retry && (destinationExists || unresolved);
        if (replacing && !previous.isNull) journal.retry(key);
        version (ManifestCliHarness) manifestKillAt(databasePath, "after-plan");
    } catch (V2DocumentFailure decision) { throw decision; }
      catch (Throwable ignored) { throw new V2FatalFailure; }
    string phase = "filter";
    bool touched;
    try {
        version (FailurePolicyHarness) {
            phase = "read";
            failureAt(databasePath, "read", file);
            phase = "decode";
            failureAt(databasePath, "decode", file);
            phase = "filter";
            failureAt(databasePath, "filter", file);
        }
        auto cleaned = chain.run(text);
        phase = "scheduler";
        if (getSize(file) != reservedBytes ||
            inputDigest(mm is null ? cast(const(ubyte)[])"" :
                cast(const(ubyte)[])mm[]) != key.inputSha256)
            throw new Exception("input changed before publication");
        const changed = cleaned != text;
        phase = "policy";
        version (FailurePolicyHarness) failureAt(databasePath, "policy", file);
        auto content = new Content([ContentPiece.own(cast(const(ubyte)[])cleaned)]);
        phase = "sink";
        try {
            journal.beginPublication(key);
        } catch (Throwable ignored) { throw new V2FatalFailure; }
        version (ManifestCliHarness) manifestKillAt(databasePath, "before-publish");
        touched = true;
        version (FailurePolicyHarness) failureAt(databasePath, "sink", file);
        writeAtomicPieces(destination, content.pieces());
        version (ManifestCliHarness) manifestKillAt(databasePath, "after-publish");
        try {
            journal.commitPublished(key, destination,
                outputDigest(cast(const(ubyte)[])cleaned));
        } catch (Throwable ignored) { throw new V2FatalFailure; }
        version (ManifestCliHarness) manifestKillAt(databasePath, "after-commit");
        return manifestOutcome(replacing ? "retry" :
            (changed ? "changed" : "unchanged"), "", key);
    } catch (V2FatalFailure fatal) { throw fatal; }
      catch (Exception failure) {
        if (cast(OutputPolicyViolation)failure !is null) phase = "policy";
        if (cast(ResourceExhaustion)failure !is null) phase = "resource";
        if (phase == "filter" && cast(UTFException)failure !is null)
            phase = "decode";
        const code = phase == "sink" ? "sink-write-failed" : phase ~ "-failed";
        try {
            version (FailurePolicyHarness) {
                if (exists(databasePath ~ ".fault-v2-arm-ack-on-failure"))
                    write(databasePath ~ ".fault-v2-ack", "1");
            }
            journal.recordFailure(key, phase, code, touched);
        }
        catch (Throwable ignored) { throw new V2FatalFailure; }
        if (phase == "policy" || phase == "resource" || phase == "scheduler")
            throw new V2FatalFailure;
        throw new V2DocumentFailure(key, touched ? "uncertain" : "failed",
            phase, code, true);
    }
}

private bool isLocalPrimaryTarget(FailureJournal journal, string file,
        string inputRoot, bool inputIsDir) {
    auto relative = inputIsDir ? relativePath(file, inputRoot) : ".";
    auto id = DocumentId.from(SourceLocator("local-files:v1", inputRoot, relative));
    return journal.hasOutstandingForDocumentSink(id, "local-primary:v1");
}

version (FailurePolicyHarness) {
    private void failureAt(string databasePath, string phase, string file) {
        auto marker = databasePath ~ ".fault-" ~ phase;
        if (exists(marker) && (readText(marker).length == 0 ||
            readText(marker) == baseName(file)))
            throw new Exception("injected " ~ phase ~ " fault");
    }
}

private ManifestOutcome processManifestOne(LocalManifest manifest, string databasePath,
        string file, string inputRoot,
        string outputRoot, bool inputIsDir, const ref Pipeline chain,
        ulong reservedBytes, ubyte[32] configHash, bool retry, bool dryRun,
        size_t completedPrefix) {
    if (isSymlink(file)) throw new Exception("refusing symlink input: " ~ file);
    auto destination = destinationFor(file, inputRoot, outputRoot, inputIsDir);
    if (getSize(file) != reservedBytes)
        throw new Exception("input changed size after admission: " ~ file);
    scope mm = reservedBytes ? new MmFile(file, MmFile.Mode.read, reservedBytes, null) : null;
    string text;
    if (mm !is null) text = cast(string)(cast(ubyte[])mm[]);
    else {
        scope input = File(file, "rb");
        if (input.size != 0) throw new Exception("empty input grew after admission");
    }
    auto firstHash = inputDigest(cast(const(ubyte)[])text);
    auto relative = inputIsDir ? relativePath(file, inputRoot) : ".";
    auto id = DocumentId.from(SourceLocator("local-files:v1", inputRoot, relative));
    SinkKey key = SinkKey(id, firstHash, configHash, "local-primary:v1");
    try {
        preflightDestination(destination, inputIsDir ? outputRoot : dirName(outputRoot));
    } catch (Exception failure) {
        throw new FatalManifestPreFilter(key, failure);
    }
    bool replacing;
    if (!dryRun) {
        try {
            auto inspected = manifest.inspect(key, destination);
            if (inspected == Inspection.verifiedCommitted)
                return manifestOutcome("skipped", "", key);
            auto previous = manifest.lookup(key);
            bool destinationExists = exists(destination);
            bool unresolved = !previous.isNull && previous.get.state != SinkState.planned;
            if (!retry && (destinationExists || unresolved))
                throw new ManifestDecisionFailure(
                    !previous.isNull && previous.get.state == SinkState.uncertain
                        ? "uncertain" : "retry-required",
                    "manifest output requires explicit --manifest-retry after inspection: " ~ destination,
                    id, key.sink);
            auto row = manifest.plan(key, destination);
            replacing = retry && (destinationExists || row.state != SinkState.planned);
            if (replacing)
                manifest.retry(key);
            version (ManifestCliHarness) manifestKillAt(databasePath, "after-plan");
        } catch (ManifestDecisionFailure decision) {
            throw decision;
        } catch (Exception failure) {
            throw new FatalManifestPreFilter(key, failure);
        }
    }
    bool sinkTouched;
    FailurePhase phase = FailurePhase.filter;
    try {
        version (FailurePolicyHarness) {
            phase = FailurePhase.read;
            failureAt(databasePath, "read", file);
            phase = FailurePhase.decode;
            failureAt(databasePath, "decode", file);
            phase = FailurePhase.filter;
            failureAt(databasePath, "filter", file);
        }
        auto cleaned = chain.run(text);
        phase = FailurePhase.scheduler;
        if (getSize(file) != reservedBytes ||
            inputDigest(mm is null ? cast(const(ubyte)[])"" :
                cast(const(ubyte)[])mm[]) != firstHash)
            throw new Exception("mapped input changed before publish: " ~ file);
        const changed = cleaned != text;
        if (dryRun) return manifestOutcome(changed ? "dry-run-changed" :
            "dry-run-unchanged", "", key);
        version (ManifestCliHarness) manifestKillAt(databasePath, "before-publish");
        // The F08 sink owns its buffer and fsync-before-rename publication.
        phase = FailurePhase.policy;
        version (FailurePolicyHarness) failureAt(databasePath, "policy", file);
        ensurePlainDirectory(inputIsDir ? outputRoot : dirName(outputRoot),
            dirName(destination));
        version (FailurePolicyHarness) failureAt(databasePath, "content-own", file);
        auto content = new Content([ContentPiece.own(cast(const(ubyte)[])cleaned)]);
        // A no-op filter may return the mapped input. Keep its owner live
        // until ContentPiece.own has copied those bytes.
        if (mm !is null && mm[].length != reservedBytes)
            throw new Exception("mapped input length changed");
        phase = FailurePhase.sink;
        sinkTouched = true;
        version (FailurePolicyHarness) {
            if (exists(databasePath ~ ".fault-policy-swap")) {
                import std.file : symlink;
                symlink(file, destination);
            }
        }
        version (FailurePolicyHarness) failureAt(databasePath, "sink", file);
        writeAtomicPieces(destination, content.pieces());
        version (ManifestCliHarness) manifestKillAt(databasePath, "after-publish");
        phase = FailurePhase.manifest;
        manifest.commitPublished(key, destination,
            outputDigest(cast(const(ubyte)[])cleaned));
        version (ManifestCliHarness) manifestKillAt(databasePath, "after-commit");
        return manifestOutcome(replacing ? "retry" :
            (changed ? "changed" : "unchanged"),
            replacing ? (changed ? "changed" : "unchanged") : "", key);
    } catch (Exception failure) {
        if (dryRun) throw failure;
        if (phase == FailurePhase.policy || phase == FailurePhase.scheduler)
            throw new FatalPlannedFailure(key, failure);
        if (cast(OutputPolicyViolation)failure !is null)
            phase = FailurePhase.policy;
        if (cast(ResourceExhaustion)failure !is null)
            phase = FailurePhase.resource;
        if (phase == FailurePhase.filter && cast(UTFException)failure !is null)
            phase = FailurePhase.decode;
        const fatal = phase == FailurePhase.policy ||
            phase == FailurePhase.resource || phase == FailurePhase.manifest;
        auto record = FailureRecord(id, key.sink, phase,
            fatal ? FailureClass.fatal : FailureClass.document,
            sinkTouched, completedPrefix, failure.msg, failure);
        // A manifest write or acknowledgment failure is fatal; it must never
        // be mistaken for a quarantined document.
        try {
            version (FailurePolicyHarness) {
                failureAt(databasePath, "pre-mark", file);
                recordDocumentFailure(manifest, key, record,
                    (in FailureRecord logged) { failureAt(databasePath, "log-ack", file); });
            } else recordDocumentFailure(manifest, key, record);
        } catch (Exception acknowledgmentFailure) {
            record.classification = FailureClass.fatal;
            throw new FatalDocumentFailure(record, acknowledgmentFailure, false);
        }
        if (fatal)
            throw new FatalDocumentFailure(record, failure, true);
        throw new DocumentFailure(record);
    }
}

int runApp(string[] args) {
    auto compositionTokens = takeCompositionTokens(args);
    const compositionExplicit = compositionTokens.length != 0;
    string inputPath;
    string outputPath;
    string filterList = "normalize-line-endings,strip-control";
    string configPath;
    size_t nThreads = totalCPUs;
    size_t maxQueuedDocuments = 64;
    ulong maxInputBytes = 256UL * 1024 * 1024;
    size_t maxOpenInputs;
    bool listFilters;
    bool validateOnly;
    bool dryRun;
    bool explain;
    string manifestPath;
    bool manifestRetry;
    string errorJournalPath;
    bool errorRetry;
    bool errorTargeted;
    string jsonlFields, datasetNamespace, sourceKey;
    size_t maxJsonlLineBytes, maxJsonlOutputBytes;
    const filtersExplicit = args.canFindOption("--filters");
    const descriptorsExplicit = args.canFindOption("--max-open-inputs");
    const fieldsExplicit = args.canFindOption("--jsonl-fields");
    const namespaceExplicit = args.canFindOption("--dataset-namespace");
    const sourceExplicit = args.canFindOption("--source-key");
    const lineCapExplicit = args.canFindOption("--max-jsonl-line-bytes");
    const outputCapExplicit = args.canFindOption("--max-jsonl-output-bytes");
    const manifestExplicit = args.canFindOption("--manifest");
    const errorJournalExplicit = args.canFindOption("--error-journal");
    const fileSchedulingExplicit = args.canFindOption("--threads") ||
        args.canFindOption("--max-queued-docs") ||
        args.canFindOption("--max-input-bytes") || descriptorsExplicit;

    string[] ignoredStages, ignoredStageOptions, ignoredStageFilters,
        ignoredFilterOptions;
    auto helpInfo = getopt(args,
        config.caseSensitive,
        "input", "Input file or directory tree to process", &inputPath,
        "output", "Output path (mirrors input tree structure when --input is a directory)", &outputPath,
        "filters", "Comma-separated filter chain, applied in order", &filterList,
        "config", "JSON file containing an ordered filter list and per-filter options", &configPath,
        "stage", "Ordered stage ID=IMPLEMENTATION", &ignoredStages,
        "stage-option", "Typed option KEY=TYPE:VALUE for the preceding stage", &ignoredStageOptions,
        "filter", "Filter for the preceding stage", &ignoredStageFilters,
        "filter-option", "Typed option KEY=TYPE:VALUE for the preceding filter", &ignoredFilterOptions,
        "threads", "Worker thread count for the TaskPool (default: all cores)", &nThreads,
        "max-queued-docs", "Maximum queued input documents (default: 64)", &maxQueuedDocuments,
        "max-input-bytes", "Maximum reserved input bytes (default: 268435456)", &maxInputBytes,
        "max-open-inputs", "Maximum worker-held input descriptors (default: threads)", &maxOpenInputs,
        "list-filters", "Print registered filter names and exit", &listFilters,
        "validate", "Validate invocation, filter chain and roots without processing", &validateOnly,
        "dry-run", "Run filters without creating or writing output", &dryRun,
        "explain", "Print one decision record per input file", &explain,
        "manifest", "Opt-in local SQLite restart manifest path", &manifestPath,
        "manifest-retry", "Inspect and replace unresolved manifest output", &manifestRetry,
        "error-journal", "Existing opt-in v2 failure journal", &errorJournalPath,
        "error-retry", "Explicitly retry unresolved v2 outputs", &errorRetry,
        "error-targeted", "Retry only exact local v2 outstanding targets", &errorTargeted,
        "jsonl-fields", "Comma-separated selected JSONL text fields", &jsonlFields,
        "dataset-namespace", "Stable JSONL dataset namespace", &datasetNamespace,
        "source-key", "Stable JSONL source key", &sourceKey,
        "max-jsonl-line-bytes", "Maximum input JSONL record bytes", &maxJsonlLineBytes,
        "max-jsonl-output-bytes", "Maximum output JSONL record bytes including LF", &maxJsonlOutputBytes);
    if (helpInfo.helpWanted) {
        defaultGetoptPrinter("scrubbed", helpInfo.options);
        return 0;
    }
    const jsonlOptions = fieldsExplicit || namespaceExplicit || sourceExplicit ||
        lineCapExplicit || outputCapExplicit;
    const jsonlRoute = jsonlOptions || inputPath == "-" || outputPath == "-";
    string configContents;
    bool versionedConfig;
    if (manifestExplicit && !manifestPath.length)
        throw new Exception("--manifest path must be nonempty");
    if (manifestRetry && !manifestPath.length)
        throw new Exception("--manifest-retry requires --manifest");
    if (errorJournalExplicit && !errorJournalPath.length)
        throw new Exception("--error-journal path must be nonempty");
    if (errorRetry && !errorJournalPath.length)
        throw new Exception("--error-retry requires --error-journal");
    if (errorTargeted && (!errorJournalPath.length || !errorRetry))
        throw new Exception("--error-targeted requires --error-journal and --error-retry");
    if (errorJournalPath.length && (manifestExplicit || manifestRetry || dryRun))
        throw new Exception("v2 journal is exclusive with manifest and dry-run");
    if (jsonlRoute) {
        if (manifestPath.length || manifestRetry || errorJournalPath.length ||
            errorRetry || errorTargeted)
            throw new Exception("--manifest is unavailable in JSONL mode");
        if (inputPath != "-" || outputPath != "-" ||
            !fieldsExplicit || !namespaceExplicit || !sourceExplicit ||
            !lineCapExplicit || !outputCapExplicit)
            throw new Exception("JSONL requires --input -, --output -, selected fields, identity, and both byte caps");
        if (listFilters || explain)
            throw new Exception("--list-filters and --explain are unavailable in JSONL mode");
        if (fileSchedulingExplicit)
            throw new Exception("file scheduling limits are unavailable in JSONL mode");
        if (!maxJsonlLineBytes || !maxJsonlOutputBytes)
            throw new Exception("JSONL byte caps must be positive");
        auto fields = jsonlFields.split(",");
        if (!fields.length || !datasetNamespace.length || !sourceKey.length)
            throw new Exception("JSONL fields, namespace and source key must be nonempty");
        foreach (i, field; fields) {
            if (!field.length) throw new Exception("JSONL field names must be nonempty");
            validate(field);
            if (fields[0 .. i].canFind(field))
                throw new Exception("duplicate JSONL field: " ~ field);
        }
        SourceLocator(datasetNamespace, sourceKey, "1");
        if (configPath.length && filtersExplicit)
            throw new Exception("--config and --filters are mutually exclusive");
        configContents = configPath.length ? readText(configPath) : "";
        versionedConfig = configContents.length && hasJobVersion(configContents);
        if (compositionExplicit || versionedConfig)
            throw new Exception("canonical v3 jobs are not migrated to JSONL in Stage 5a");
        auto chain = configPath.length
            ? Pipeline.buildConfigured(loadFilterConfig(configPath))
            : Pipeline.build(filterList.split(","));
        if (validateOnly) {
            stderr.writeln("valid JSONL invocation; no stdin read.");
            return 0;
        }
        try {
            const completed = processStandardJsonl(datasetNamespace, sourceKey,
                fields, (string field, string text, DocumentId id) => chain.run(text),
                JsonlLimits(maxJsonlLineBytes, maxJsonlOutputBytes), dryRun);
            stderr.writeln("JSONL done. ", completed, " records processed", dryRun ? "; dry-run, no stdout." : ".");
            return 0;
        } catch (JsonlFailure error) {
            stderr.writefln("JSONL %s at physical line %s, DocumentId %s: %s; %s prior records %s; current record %s",
                error.kind, error.line, error.documentId.text, error.msg,
                error.completedRecords, dryRun ? "processed, no stdout" :
                    "fully flushed", dryRun ? "produced no stdout" :
                    (error.partialOutputPossible ? "may be partially written" :
                    "was not written"));
            return 1;
        }
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
    if (maxOpenInputs == 0 && !descriptorsExplicit) maxOpenInputs = nThreads;
    if (maxQueuedDocuments == 0 || maxInputBytes == 0 || maxOpenInputs == 0)
        throw new Exception("input limits must be positive");
    if (configPath.length && filtersExplicit)
        throw new Exception("--config and --filters are mutually exclusive");
    if (compositionExplicit && (configPath.length || filtersExplicit))
        throw new Exception("composition options are mutually exclusive with --config and --filters");
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

    configContents = configPath.length ? readText(configPath) : "";
    versionedConfig = configContents.length && hasJobVersion(configContents);

    const durableRoute = manifestPath.length || errorJournalPath.length;
    if (durableRoute && (compositionExplicit || versionedConfig))
        throw new Exception("canonical v3 jobs are not migrated to durable routes in Stage 5a");
    Pipeline chain;
    Nullable!CompiledJob compiledJob;
    string chainLabel;
    if (durableRoute) {
        chain = configPath.length
            ? Pipeline.buildConfigured(parseFilterConfig(configContents))
            : Pipeline.build(filterList.split(","));
        chainLabel = chain.names.join(" -> ");
    } else {
        auto spec = selectedJob(compositionTokens, filtersExplicit, filterList,
            configPath.length != 0, configContents, versionedConfig);
        compiledJob = compileJob(spec);
        chainLabel = versionedConfig || compositionExplicit ? compiledJob.get.identity :
            spec.stages[0].filters.map!(filter => filter.name).join(" -> ");
    }
    if (!errorJournalPath.length)
        writeln(versionedConfig || compositionExplicit ? "job: " : "filter chain: ",
            chainLabel);

    const inputIsDir = isDir(inputPath);
    if (!inputIsDir && !isFile(inputPath))
        throw new Exception("input root is not a regular file or directory: " ~ inputPath);
    if (inputIsDir) {
        if (pathIsWithin(outputPath, inputPath))
            throw new Exception("output directory must not be inside the input tree");
    }
    if (!errorTargeted) preflightOutput(outputPath, inputIsDir);
    if (manifestPath.length) {
        manifestPath = resolveExistingPrefix(manifestPath);
        preflightManifest(manifestPath, inputPath, outputPath, inputIsDir);
    }
    if (errorJournalPath.length) {
        errorJournalPath = resolveExistingPrefix(errorJournalPath);
        preflightManifest(errorJournalPath, inputPath, outputPath, inputIsDir);
    }
    if (validateOnly) {
        if (manifestPath.length || errorJournalPath.length)
            manifestConfig(filterList, configContents, configPath.length != 0,
                outputPath, inputIsDir);
        if (errorJournalPath.length) {
            auto checkedJournal = new FailureJournal(errorJournalPath);
            checkedJournal.close();
        }
        if (!errorJournalPath.length) writeln("valid. No files processed.");
        return 0;
    }
    ubyte[32] configHash;
    LocalManifest manifest;
    FailureJournal errorJournal;
    if (manifestPath.length || errorJournalPath.length) {
        configHash = manifestConfig(filterList, configContents,
            configPath.length != 0, outputPath, inputIsDir);
        if (manifestPath.length && !dryRun) manifest = new LocalManifest(manifestPath);
        if (errorJournalPath.length) errorJournal = new FailureJournal(errorJournalPath);
    }
    scope(exit) if (manifest !is null) manifest.close();
    scope(exit) if (errorJournal !is null) errorJournal.close();
    if (!dryRun && !errorTargeted)
        ensurePlainDirectory(inputIsDir ? outputPath : dirName(outputPath),
            inputIsDir ? outputPath : dirName(outputPath));
    auto pending = explain ? new PendingExplanations : null;
    auto publication = durableRoute ? null : new PublicationOrder;
    auto decisionMutex = new Mutex;
    size_t terminalDecisions;
    size_t manifestCompletedPrefix;
    auto scheduler = new BoundedInput(
        InputLimits(maxQueuedDocuments, maxInputBytes, maxOpenInputs),
        manifestPath.length || errorJournalPath.length ? 1 : nThreads,
        (string file, ulong bytes) {
            ManifestOutcome decision;
            if (manifestPath.length)
                decision = processManifestOne(manifest, manifestPath, file, inputPath, outputPath,
                    inputIsDir, chain, bytes, configHash, manifestRetry, dryRun,
                    manifestCompletedPrefix);
            else if (errorJournalPath.length)
                decision = processV2One(errorJournal, errorJournalPath, file, inputPath,
                    outputPath, inputIsDir, chain, bytes, configHash, errorRetry,
                    errorTargeted);
            else {
                auto local = processCompiledOne(file, inputPath, outputPath,
                    inputIsDir, compiledJob.get, bytes, dryRun, publication);
                decision.status = local.status;
                decision.detail = local.firstReason;
                if (local.rejected || local.quarantined) {
                    decisionMutex.lock();
                    ++terminalDecisions;
                    decisionMutex.unlock();
                }
            }
            if (explain && errorJournalPath.length)
                v2Explain(decision.status, decision.key,
                    errorJournal.publicSinkId(decision.key.sink));
            else if (explain)
                explainOne(file, destinationFor(file, inputPath, outputPath, inputIsDir),
                    chainLabel, decision.status,
                    !durableRoute ? decision.detail : "", durableRoute ? decision.detail : "",
                    decision.hasKey ? decision.key.document.text : "",
                    decision.hasKey ? decision.key.sink : "");
            if (explain) pending.remove(file);
            if (manifestPath.length) ++manifestCompletedPrefix;
        },
        (string file, Throwable error) {
            auto documentFailure = cast(DocumentFailure)error;
            auto fatalDocumentFailure = cast(FatalDocumentFailure)error;
            auto manifestDecision = cast(ManifestDecisionFailure)error;
            auto fatalPreFilter = cast(FatalManifestPreFilter)error;
            auto fatalPlanned = cast(FatalPlannedFailure)error;
            auto v2Decision = cast(V2DocumentFailure)error;
            auto effectFailure = cast(EffectFailure)error;
            auto orderedCanceled = cast(OrderedPublicationCanceled)error;
            if (errorJournalPath.length) {
                stderr.writeln("scrubbed: ", v2Decision !is null ?
                    v2Decision.code : "error-journal-fatal");
                if (explain && v2Decision !is null)
                    v2Explain(v2Decision.status, v2Decision.key,
                        v2Decision.hasPublicSink ?
                            errorJournal.publicSinkId(v2Decision.key.sink) : "",
                        v2Decision.phase, v2Decision.code);
                if (explain) pending.remove(file);
                return;
            }
            if (orderedCanceled !is null) {
                stderr.writefln("CANCELED %s: %s", file, error.msg);
                if (explain)
                    explainOne(file, destinationFor(file, inputPath, outputPath,
                        inputIsDir), chainLabel, "canceled", error.msg);
                if (explain) pending.remove(file);
                return;
            }
            auto renderedError = effectFailure is null ? error.msg :
                error.msg ~ " (" ~ effectFailureDetail(effectFailure) ~ ")";
            stderr.writefln("%s %s: %s",
                documentFailure !is null || manifestDecision !is null ? "SKIP" : "FATAL",
                file, renderedError);
            if (explain) {
                string status = "failure", detail, documentId, sinkKey;
                if (documentFailure !is null) {
                    status = documentFailure.record.sinkTouched ? "uncertain" : "failed";
                    detail = "completed-prefix=" ~
                        documentFailure.record.completedPrefix.to!string;
                    documentId = documentFailure.record.documentId.text;
                    sinkKey = documentFailure.record.sinkKey;
                } else if (fatalDocumentFailure !is null) {
                    status = !fatalDocumentFailure.acknowledged ? "unacknowledged" :
                        (fatalDocumentFailure.record.sinkTouched ? "uncertain" : "failed");
                    detail = "completed-prefix=" ~
                        fatalDocumentFailure.record.completedPrefix.to!string;
                    documentId = fatalDocumentFailure.record.documentId.text;
                    sinkKey = fatalDocumentFailure.record.sinkKey;
                } else if (manifestDecision !is null) {
                    status = manifestDecision.status;
                    documentId = manifestDecision.documentId.text;
                    sinkKey = manifestDecision.sinkKey;
                } else if (fatalPreFilter !is null) {
                    documentId = fatalPreFilter.key.document.text;
                    sinkKey = fatalPreFilter.key.sink;
                } else if (fatalPlanned !is null) {
                    status = "unacknowledged";
                    detail = "manifest-state=planned";
                    documentId = fatalPlanned.key.document.text;
                    sinkKey = fatalPlanned.key.sink;
                } else if (effectFailure !is null) {
                    status = effectFailure.partialWritePossible ? "uncertain" : "failure";
                    detail = effectFailureDetail(effectFailure);
                    documentId = effectFailure.documentId.text;
                }
                explainOne(file, destinationFor(file, inputPath, outputPath, inputIsDir),
                    chainLabel, status, error.msg, detail, documentId, sinkKey);
            }
            if (explain) pending.remove(file);
            if (documentFailure !is null) ++manifestCompletedPrefix;
        }, (Throwable error) {
            return cast(OrderedPublicationCanceled)error is null &&
                cast(V2DocumentFailure)error is null &&
                cast(DocumentFailure)error is null &&
                cast(ManifestDecisionFailure)error is null;
        });
    bool workerFatalAdmission;
    void submitPath(string file) {
        bool admissionCanceled;
        try {
            if (explain) pending.add(file);
            if (!durableRoute) publication.assign(file);
            auto bytes = getSize(file);
            if (!scheduler.submit(file, bytes)) {
                admissionCanceled = true;
                workerFatalAdmission = true;
                throw new Exception("input admission canceled: " ~ file);
            }
        } catch (Exception error) {
            if (explain && !admissionCanceled && !errorJournalPath.length) {
                pending.remove(file);
                explainOne(file, destinationFor(file, inputPath, outputPath,
                    inputIsDir), chainLabel, "failure", error.msg);
            }
            throw error;
        }
    }
    void walkCanonical(string directory) {
        auto entries = dirEntries(directory, SpanMode.shallow, false).array;
        auto orderKey = (ref typeof(entries[0]) entry) {
            auto relative = relativePath(entry.name, inputPath);
            return !entry.isSymlink && entry.isDir ?
                relative ~ dirSeparator : relative;
        };
        sort!((left, right) => orderKey(left) < orderKey(right))(entries);
        foreach (entry; entries) {
            if (entry.isSymlink) {
                auto reason = "refusing symlink in input tree: " ~ entry.name;
                if (explain && !errorJournalPath.length)
                    explainOne(entry.name, destinationFor(entry.name, inputPath,
                        outputPath, inputIsDir), chainLabel, "failure", reason);
                throw new Exception(reason);
            }
            if (entry.isFile) {
                submitPath(entry.name);
                continue;
            }
            if (entry.isDir) walkCanonical(entry.name);
        }
    }
    try {
        if (inputIsDir) {
            if (!durableRoute) walkCanonical(inputPath);
            else foreach (entry; dirEntries(inputPath, SpanMode.depth, false)) {
                if (entry.isSymlink) {
                    auto reason = "refusing symlink in input tree: " ~ entry.name;
                    if (explain && !errorJournalPath.length)
                        explainOne(entry.name, destinationFor(entry.name, inputPath,
                            outputPath, inputIsDir), chainLabel, "failure", reason);
                    throw new Exception(reason);
                }
                if (!entry.isFile) continue;
                if (errorTargeted && !isLocalPrimaryTarget(errorJournal,
                    entry.name, inputPath, inputIsDir)) continue;
                submitPath(entry.name);
            }
        } else {
            if (!errorTargeted || isLocalPrimaryTarget(errorJournal,
                    inputPath, inputPath, inputIsDir)) submitPath(inputPath);
        }
    } catch (Exception error) {
        if (!durableRoute) publication.abort();
        scheduler.cancel();
        scheduler.finish();
        if (explain && !errorJournalPath.length)
            foreach (file; pending.drain())
                explainOne(file, destinationFor(file, inputPath, outputPath, inputIsDir),
                    chainLabel, workerFatalAdmission ? "canceled" : "failure",
                    workerFatalAdmission ? "canceled after fatal processing failure" :
                        "canceled after traversal error");
        auto workerFatal = scheduler.fatal();
        if (workerFatalAdmission && workerFatal !is null)
            throw new Exception("fatal file processing failure: " ~ workerFatal.msg);
        throw error;
    }
    const counts = scheduler.finish();
    if (scheduler.fatal() !is null) {
        if (explain && !errorJournalPath.length)
            foreach (file; pending.drain())
                explainOne(file, destinationFor(file, inputPath, outputPath, inputIsDir),
                    chainLabel, "canceled", "fatal processing failure");
        throw new Exception("fatal file processing failure: " ~ scheduler.fatal().msg);
    }
    if (manifest !is null) manifest.checkpoint();
    const failures = counts.failed;
    if (!errorJournalPath.length)
        writeln("done. ", counts.succeeded, " succeeded, ", failures, " failed.");
    return failures == 0 && terminalDecisions == 0 ? 0 : 1;
}

unittest {
    import std.exception : assertThrown;
    import std.file : rmdirRecurse, tempDir;

    auto root = buildPath(tempDir, "scrubbed-cli-" ~ randomUUID.toString);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    mkdir(root);
    assert(runApp(["scrubbed"]) == 2);

    auto same = buildPath(root, "same.txt");
    write(same, "already clean");
    assert(runApp(["scrubbed", "--input", same, "--output", same,
        "--filters", "fix-mojibake", "--threads", "1"]) == 0);
    assert(readText(same) == "already clean");

    auto empty = buildPath(root, "empty.txt");
    auto emptyOut = buildPath(root, "empty-out.txt");
    write(empty, "");
    assert(runApp(["scrubbed", "--input", empty, "--output", emptyOut,
        "--threads", "1"]) == 0);
    assert(exists(emptyOut) && getSize(emptyOut) == 0);

    auto inputDir = buildPath(root, "input");
    mkdir(inputDir);
    assertThrown(runApp(["scrubbed", "--input", inputDir,
        "--output", buildPath(inputDir, "out"), "--threads", "1"]));
    assertThrown(runApp(["scrubbed", "--input", same, "--output", emptyOut,
        "--config", "x.json", "--filters", "fix-mojibake"]));
    assertThrown(runApp(["scrubbed", "--input", same, "--output", emptyOut,
        "--config", "x.json", "--FILTERS", "fix-mojibake"]));
    assertThrown(runApp(["scrubbed", "--input", same, "--output", emptyOut,
        "--threads", "0"]));

    auto badConfig = buildPath(root, "bad.json");
    write(badConfig, `{ "filters": [{ "name": "fix-mojibake", ` ~
        `"options": { "max-pass": 0 } }] }`);
    assertThrown(runApp(["scrubbed", "--input", same, "--output", emptyOut,
        "--config", badConfig, "--threads", "1"]));

    auto emptyConfig = buildPath(root, "empty-config.json");
    write(emptyConfig, "");
    write(emptyOut, "sentinel");
    assertThrown(runApp(["scrubbed", "--input", same, "--output", emptyOut,
        "--config", emptyConfig, "--threads", "1"]));
    assert(readText(emptyOut) == "sentinel");

    auto invalidValueConfig = buildPath(root, "invalid-value.json");
    write(invalidValueConfig, `{ "filters": [{ "name": "fix-mojibake", ` ~
        `"options": { "max-passes": "bad" } }] }`);
    auto noFiles = buildPath(root, "no-files");
    auto noFilesOutput = buildPath(root, "no-files-output");
    mkdir(noFiles);
    assertThrown(runApp(["scrubbed", "--input", noFiles,
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
    assert(runApp(["scrubbed", "--input", configuredInput,
        "--output", configuredOutput, "--config", validConfig,
        "--threads", "1"]) == 0);
    assert(readText(configuredOutput) == `"schÃ¶n"`);

    auto blockedParent = buildPath(root, "not-a-directory");
    write(blockedParent, "x");
    assertThrown(runApp(["scrubbed", "--input", same,
        "--output", buildPath(blockedParent, "out.txt"), "--threads", "1"]));

    auto invalidUtf8 = buildPath(root, "invalid-utf8.bin");
    write(invalidUtf8, [cast(ubyte) 0xFF]);
    assertThrown(runApp(["scrubbed", "--input", invalidUtf8,
        "--output", buildPath(root, "invalid-output.txt"),
        "--threads", "1"]));

    auto sharedInput = buildPath(root, "shared-input", "nested");
    mkdirRecurse(sharedInput);
    foreach (index; 0 .. 64)
        write(buildPath(sharedInput, index.to!string ~ ".txt"), "clean");
    auto sharedOutput = buildPath(root, "shared-output");
    assert(runApp(["scrubbed", "--input", dirName(sharedInput),
        "--output", sharedOutput, "--filters", "fix-mojibake",
        "--threads", "4", "--max-queued-docs", "1",
        "--max-input-bytes", "5", "--max-open-inputs", "1"]) == 0);
    foreach (index; 0 .. 64)
        assert(readText(buildPath(sharedOutput, "nested",
            index.to!string ~ ".txt")) == "clean");

    auto oversized = buildPath(root, "oversized.txt");
    write(oversized, "too large");
    auto oversizedOutput = buildPath(root, "oversized-output.txt");
    assertThrown(runApp(["scrubbed", "--input", oversized,
        "--output", oversizedOutput, "--threads", "1",
        "--max-input-bytes", "2"]));
    assert(!exists(oversizedOutput));

    auto changed = buildPath(root, "changed.txt");
    auto changedOutput = buildPath(root, "changed-output.txt");
    write(changed, "old");
    write(changed, "larger");
    auto changedChain = Pipeline.build(["fix-mojibake"]);
    assertThrown(processOne(changed, changed, changedOutput, false,
        changedChain, 3));
    assert(!exists(changedOutput));
    assertThrown(processOne(changed, changed, changedOutput, false,
        changedChain, 0));
    assert(!exists(changedOutput));

    version (Posix) {
        import std.file : symlink;
        auto link = buildPath(root, "input-link");
        symlink(same, link);
        assertThrown(runApp(["scrubbed", "--input", link,
            "--output", emptyOut, "--threads", "1"]));

        auto external = buildPath(root, "external.txt");
        auto outputLink = buildPath(root, "output-link.txt");
        write(external, "must survive");
        symlink(external, outputLink);
        assertThrown(runApp(["scrubbed", "--input", same,
            "--output", outputLink, "--threads", "1"]));
        assert(readText(external) == "must survive");

        auto treeLink = buildPath(inputDir, "outside-link");
        symlink(external, treeLink);
        assertThrown(runApp(["scrubbed", "--input", inputDir,
            "--output", buildPath(root, "tree-output"), "--threads", "1"]));
    }
}

private void requireCli(bool condition, string message) {
    if (!condition) throw new Exception("CLI inspection test: " ~ message);
}

unittest {
    import std.file : rmdirRecurse, tempDir;
    import std.exception : assertThrown;

    auto root = buildPath(tempDir, "scrubbed-inspection-" ~ randomUUID.toString);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    mkdir(root);
    auto input = buildPath(root, "input.txt");
    write(input, "line\r\n");
    auto output = buildPath(root, "new", "output.txt");
    auto badConfig = buildPath(root, "bad.json");
    write(badConfig, `{ "filters": [{ "name": "strip-control", ` ~
        `"options": { "not-an-option": true } }] }`);
    try {
        runApp(["scrubbed", "--input", input, "--output", output,
            "--config", badConfig, "--threads", "1"]);
        throw new Exception("invalid config was accepted");
    } catch (Exception error) {
        requireCli(error.msg != "invalid config was accepted", "invalid config rejected");
    }
    requireCli(!exists(dirName(output)), "invalid config created output parent");

    requireCli(runApp(["scrubbed", "--input", input, "--output", output,
        "--validate", "--threads", "1"]) == 0, "validate exit");
    requireCli(!exists(dirName(output)), "validate created output parent");
    requireCli(runApp(["scrubbed", "--input", input, "--output", output,
        "--dry-run", "--explain", "--threads", "1"]) == 0, "dry-run exit");
    requireCli(!exists(dirName(output)), "dry-run created output parent");
    requireCli(readText(input) == "line\r\n", "dry-run changed source");
    requireCli(runApp(["scrubbed", "--input", input, "--output", input,
        "--dry-run", "--threads", "1"]) == 0, "same-file dry-run exit");
    requireCli(readText(input) == "line\r\n", "same-file dry-run changed source");

    auto inputTree = buildPath(root, "tree");
    mkdir(inputTree);
    write(buildPath(inputTree, "changed.txt"), "line\r\n");
    write(buildPath(inputTree, "unchanged.txt"), "clean");
    write(buildPath(inputTree, "bad.bin"), [cast(ubyte) 0xFF]);
    auto treeOutput = buildPath(root, "tree-output");
    assertThrown(runApp(["scrubbed", "--input", inputTree, "--output", treeOutput,
        "--dry-run", "--explain", "--threads", "4", "--max-queued-docs", "1",
        "--max-open-inputs", "1"]));
    requireCli(!exists(treeOutput), "multi-thread dry-run created output tree");
    version (Posix) {
        import std.file : symlink;
        auto unsafeOutput = buildPath(root, "unsafe-output");
        mkdir(unsafeOutput);
        auto linkedFile = buildPath(unsafeOutput, "changed.txt");
        symlink(input, linkedFile);
        assertThrown(runApp(["scrubbed", "--input", inputTree,
            "--output", unsafeOutput, "--dry-run", "--threads", "1"]));
        requireCli(readText(input) == "line\r\n", "unsafe dry-run followed output link");
    }
    requireCli(explanationRecord("in\n", "out", "strip-control", "changed") ==
        "EXPLAIN\tinput=\"in\\n\"\toutput=\"out\"\tchain=\"strip-control\"\tstatus=changed",
        "changed record format");
    requireCli(explanationRecord("in", "out", "strip-control", "unchanged") ==
        "EXPLAIN\tinput=\"in\"\toutput=\"out\"\tchain=\"strip-control\"\tstatus=unchanged",
        "unchanged record format");
    requireCli(explanationRecord("in", "out", "strip-control", "failure", "bad\tdata") ==
        "EXPLAIN\tinput=\"in\"\toutput=\"out\"\tchain=\"strip-control\"\tstatus=failure\treason=\"bad\\tdata\"",
        "failure record format");
    foreach (unsafeName; ["a//b", "a/b/", "/a/b"])
        assertThrown(checkedOutputName(unsafeName));
    requireCli(checkedOutputName("a/b") == buildPath("a", "b"),
        "safe split output name retained");
    auto splitDocument = Document(SourceLocator("test", "split", "root"),
        OutputName("a/b"));
    auto splitFailure = new EffectFailure(EffectPhase.sink, 0, 1,
        splitDocument.id, true, new Exception("second child failed"));
    requireCli(effectFailureDetail(splitFailure) ==
        "completed-root-prefix=0;committed-event-prefix=1;partial-write-possible=true",
        "split failure retains committed prefix");

    auto plainOutput = buildPath(root, "plain.txt");
    requireCli(runApp(["scrubbed", "--input", input, "--output", plainOutput,
        "--filters", "normalize-line-endings", "--threads", "1"]) == 0,
        "legacy invocation exit");
    requireCli(readText(plainOutput) == "line\n", "legacy invocation output");

    // The test-only fixture stage proves that the switched local sink treats a
    // terminal rejection as an acknowledged per-document outcome: no output
    // is published and the invocation exits 1 rather than becoming fatal.
    auto rejectedOutput = buildPath(root, "rejected.txt");
    requireCli(runApp(["scrubbed", "--input", input, "--output",
        rejectedOutput, "--stage", "stop=fixture", "--stage-option",
        "suffix=text:policy-stop", "--stage-option", "enabled=boolean:true",
        "--threads", "1"]) == 1, "compiled rejection exit");
    requireCli(!exists(rejectedOutput), "compiled rejection published output");
}

// Model the late-traversal-fault boundary deterministically: one worker has
// begun, another file is admitted but queued, then traversal discovers the
// fault and cancels. The scheduler skips the queued callback by design.
unittest {
    import core.sync.semaphore : Semaphore;

    auto entered = new Semaphore(0);
    auto release = new Semaphore(0);
    auto pending = new PendingExplanations;
    auto scheduler = new BoundedInput(InputLimits(2, 2, 1), 2,
        (string file, ulong bytes) {
            entered.notify();
            release.wait();
            pending.remove(file);
        },
        (string file, Throwable error) {
            pending.remove(file);
            throw new Exception("unexpected worker failure: " ~ error.msg);
        });
    pending.add("working.txt");
    requireCli(scheduler.submit("working.txt", 1), "first file admitted");
    entered.wait();
    pending.add("queued.txt");
    requireCli(scheduler.submit("queued.txt", 1), "second file admitted");
    // A late symlink is a traversal error, not a per-file filter failure.
    scheduler.cancel();
    release.notify();
    auto counts = scheduler.finish();
    auto canceled = pending.drain();
    requireCli(counts.succeeded == 1 && counts.skipped == 1,
        "late traversal cancellation retained scheduler semantics");
    requireCli(canceled.length == 1 && canceled[0] == "queued.txt",
        "exactly queued path requires a canceled explanation");
    requireCli(explanationRecord(canceled[0], "out/queued.txt", "strip-control",
        "failure", "canceled after traversal error").canFind("status=failure"),
        "canceled path has a failure record");
}
