/// Command-line orchestration and filesystem boundary for scrubbed.
module cli;

import composition.compiler : CompiledJob, compileJob;
import composition.executor : runCompiledStage;
import composition.job_executor : CompiledJobFailure;
import composition.dispatch_compiler : compileDispatchJobV1;
import composition.dispatch_executor : DispatchExecutionFailureV1;
import composition.runtime_plan : RuntimeExecutionV1, RuntimePlanV1;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import effects.bounded_input : BoundedInput, InputLimits;
import effects.jsonl_stream : JsonlFailure, JsonlFailureKind, JsonlLimits;
import effects.jsonl_job : runJsonlField;
import effects.stdio_stream : processStandardJsonlDocuments;
import effects.local_manifest : SinkKey, inputDigest;
import effects.durable_job : DurableAction, DurableEventPlan, DurableEventState,
    DurableIdentity, DurableJobLedger, DurableKind, DurableRootKey, deriveDurableIdentity,
    DurableMetricPhaseV1, beginDurableMetricV1, createJournalV3,
    derivedSink, durableMetricsJsonV1, enableDurableMetricsV1,
    reasonDigest, recordDurableMetricV1;
import effects.dispatch_record : canonicalDispatchCancellationRecordV1,
    canonicalDispatchFailureRecordV1,
    canonicalDispatchRecordV1, canonicalJsonlDispatchFailureRecordV1,
    canonicalJsonlDispatchRecordV1, canonicalJsonlRecordFailureRecordV1;
import effects.atomic_piece_sink : OutputPolicyViolation, ResourceExhaustion,
    writeAtomicPieces;
import effects.local_job : LocalJobOutcome, runLocalJob, runLocalJobBatch;
import effects.runner : EffectFailure, EffectPhase;
import content.pieces : Content, ContentPiece;
import domain.document : Document, DocumentId, OutputName, SourceLocator;
import effects.html_tree : checkedHtmlByteLimit, defaultExtractHtmlBytes;
import effects.html_tree_json_stage;
import effects.html_markdown_stage;
import stages.contract : EventKind, ResourceDeclaration, StageDeclaration,
    StageDocument, StageEvent;
import stages.text_transform;
import job.cli_tokens : parseJobTokens;
import job.json : canonicalJobJson, parseJobJson;
import job.dispatch_cli_tokens : parseDispatchJobTokensV1;
import job.dispatch_json : canonicalDispatchJobJsonV1,
    parseDispatchJobJsonV1;
import extraction.registry : coreExtractorRegistryV1;
import extraction.contracts : DetectionOutcomeV1;
import job.legacy : lowerLegacyDefault, lowerLegacyJson, lowerLegacyNames;
import job.spec : JobOption, JobSpec, JobStageSpec;
import filters.entities;
import filters.mojibake;
import filters.normalize;
import filters.punctuation;
import pipeline : availableFilters;
import std.algorithm.searching : canFind, startsWith;
import std.algorithm.iteration : map;
import std.algorithm.sorting : sort;
import std.array : array, split;
import std.conv : to;
import std.file : FileException, SpanMode, dirEntries, exists,
    getSize, isDir, isFile, isSymlink, mkdir, mkdirRecurse, remove, rename, readText,
    write, thisExePath;
import std.getopt : config, defaultGetoptPrinter, getopt;
import std.exception : enforce;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
import std.parallelism : totalCPUs;
import std.process : environment;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath,
    dirName, dirSeparator, isAbsolute, pathSplitter, relativePath;
import std.stdio : File, stderr, writefln, writeln;
import std.string : indexOf, join;
import std.utf : validate;
import std.uuid : randomUUID;
import crypto.sha256 : Sha256;
import core.stdc.errno : errno, EINTR;
import core.sys.posix.fcntl : open, O_RDONLY, O_NOFOLLOW;
import core.sys.posix.sys.stat : fstat, stat, stat_t, S_ISREG;
import core.sys.posix.unistd : close, posixRead = read;
import std.string : toStringz;

version (ManifestCliHarness) {
    import stages.contract : PassMode, StageDecision;
    import stages.registry : ConfiguredStageTransform, FilterPlacement,
        StageApply, StageConfiguration, StageOptions, StageRegistration,
        registerStage;

    private StageDecision harnessSplit(StageDocument input,
            immutable(StageConfiguration)) pure {
        StageDocument[] children;
        foreach (ordinal; 0 .. 3) {
            auto name = "part-" ~ ordinal.to!string ~ ".txt";
            auto source = input.document.source;
            auto document = Document(SourceLocator(source.datasetNamespace,
                source.sourceKey, source.recordKey ~ ":stage6:" ~
                ordinal.to!string), OutputName(name));
            children ~= StageDocument(document, input.content);
        }
        return StageDecision.split(children);
    }

    private StageDecision harnessReject(StageDocument,
            immutable(StageConfiguration)) pure {
        return StageDecision.reject("stage6-reject");
    }

    private StageDecision harnessQuarantine(StageDocument,
            immutable(StageConfiguration)) pure {
        return StageDecision.quarantine("stage6-quarantine");
    }

    private ConfiguredStageTransform harnessTransform(StageApply apply) {
        return ConfiguredStageTransform(apply);
    }

    private ConfiguredStageTransform harnessSplitFactory(const ref StageOptions) {
        return harnessTransform(&harnessSplit);
    }
    private ConfiguredStageTransform harnessRejectFactory(const ref StageOptions) {
        return harnessTransform(&harnessReject);
    }
    private ConfiguredStageTransform harnessQuarantineFactory(const ref StageOptions) {
        return harnessTransform(&harnessQuarantine);
    }

    static this() {
        foreach (registration; [
            StageRegistration(StageDeclaration("stage6-three", PassMode.singlePass,
                ResourceDeclaration(1, 0)), null, null, null,
                &harnessSplitFactory, FilterPlacement.none),
            StageRegistration(StageDeclaration("stage6-reject", PassMode.singlePass,
                ResourceDeclaration(1, 0)), null, null, null,
                &harnessRejectFactory, FilterPlacement.none),
            StageRegistration(StageDeclaration("stage6-quarantine", PassMode.singlePass,
                ResourceDeclaration(1, 0)), null, null, null,
                &harnessQuarantineFactory, FilterPlacement.none)
        ]) registerStage(registration);
    }
}

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
    auto expectedStage = format == "markdown" ? "html-markdown" : "html-tree-json";
    JobSpec spec;
    if (configPath.length) {
        spec = parseJobJson(readText(configPath));
    } else {
        JobStageSpec stage;
        stage.id = "extract";
        stage.implementation = expectedStage;
        stage.options["max-html-bytes"] = JobOption.integer(byteLimit);
        if (declaredCharset !is null)
            stage.options["charset"] = JobOption.text(declaredCharset);
        spec.stages = [stage];
    }
    if (spec.stages.length != 1 || spec.stages[0].implementation != expectedStage ||
            spec.stages[0].filters.length != 0)
        throw new Exception("extract config must contain exactly one " ~ expectedStage ~ " stage");
    auto configuredLimit = "max-html-bytes" in spec.stages[0].options;
    byteLimit = configuredLimit is null ? defaultExtractHtmlBytes :
        checkedHtmlByteLimit(configuredLimit.asInteger());
    auto plan = compileJob(spec);
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
            auto result = runCompiledStage([StageDocument(document, content)],
                plan.stages[0]);
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

private LocalJobOutcome processCompiledOne(string file, string inputRoot,
        string outputRoot, bool inputIsDir, ref RuntimePlanV1 job,
        ulong reservedBytes, bool dryRun, PublicationOrder publication) {
    auto relative = inputIsDir ? relativePath(file, inputRoot) : ".";
    auto rootDestination = destinationFor(file, inputRoot, outputRoot, inputIsDir);
    auto document = Document(SourceLocator("local-files:v1", inputRoot, relative),
        OutputName(inputIsDir ? relative : baseName(outputRoot)));
    auto ordinal = publication.ordinal(file);
    bool entered;
    try {
        string dispatchRecord;
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
            }, (ref RuntimeExecutionV1 execution, ref const ubyte[32]) {
                if (execution.hasDispatch)
                    dispatchRecord = canonicalDispatchRecordV1(
                        execution.dispatch);
            }, dryRun);
        // Every valid compiled job emits at least one terminal event, so entering
        // publication is part of completing a root.
        if (!entered) throw new Exception("compiled job produced no terminal decision");
        publication.complete();
        result.dispatchRecord = dispatchRecord;
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
    foreach (candidate; ["--stage", "--stage-option", "--filter", "--filter-option",
            "--dispatch-option", "--route", "--route-option", "--action", "--common"])
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
        if (name == "--common") {
            enforce(args[i] == "--common", "--common does not take a value");
            tokens ~= name;
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

private long selectedJobVersion(string json) {
    auto root = parseJSON(json, 16,
        JSONOptions.strictParsing | JSONOptions.preserveObjectOrder);
    if (root.type != JSONType.object) return 0;
    foreach (ref member; root.orderedObject)
        if (member.key == "version") {
            enforce(member.value.type == JSONType.integer,
                "job version must be an integer");
            return member.value.integer;
        }
    return 0;
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

private RuntimePlanV1 selectedRuntimePlan(string[] compositionTokens,
        bool filtersExplicit, string filterList, bool configExplicit,
        string configContents, bool versionedConfig) {
    bool dispatchTokens;
    foreach (token; compositionTokens)
        if (token == "--dispatch-option" || token == "--route" ||
                token == "--route-option" || token == "--action" ||
                token == "--common") dispatchTokens = true;
    if (dispatchTokens) {
        auto spec = parseDispatchJobTokensV1(compositionTokens);
        auto canonical = canonicalDispatchJobJsonV1(spec);
        auto registry = coreExtractorRegistryV1();
        return RuntimePlanV1.dispatchV4(
            compileDispatchJobV1(spec, &registry), canonical);
    }
    if (configExplicit && versionedConfig && selectedJobVersion(configContents) == 4) {
        auto spec = parseDispatchJobJsonV1(configContents);
        auto canonical = canonicalDispatchJobJsonV1(spec);
        auto registry = coreExtractorRegistryV1();
        return RuntimePlanV1.dispatchV4(
            compileDispatchJobV1(spec, &registry), canonical);
    }
    auto spec = selectedJob(compositionTokens, filtersExplicit, filterList,
        configExplicit, configContents, versionedConfig);
    return RuntimePlanV1.linearV3(compileJob(spec), canonicalJobJson(spec));
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
    auto digest = Sha256.create;
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
    bool terminal;
    string dispatchRecord;
}

private ManifestOutcome manifestOutcome(string status, string detail, SinkKey key,
        bool terminal = false) {
    ManifestOutcome result;
    result.status = status;
    result.detail = detail;
    result.key = key;
    result.hasKey = true;
    result.terminal = terminal;
    return result;
}







private void v2Explain(string status, SinkKey key, string sinkId,
        string phase = "", string code = "") {
    auto line = "EXPLAIN\tstatus=" ~ status ~ "\tphase=" ~ phase ~
        "\tcode=" ~ code ~ "\tdocument_id=" ~ key.document.text;
    if (sinkId.length) line ~= "\tsink_id=" ~ sinkId;
    writeln(line);
}

version (FailurePolicyHarness) {
    private void failureAt(string databasePath, string phase, string file) {
        auto marker = databasePath ~ ".fault-" ~ phase;
        if (exists(marker) && (readText(marker).length == 0 ||
            readText(marker) == baseName(file)))
            throw new Exception("injected " ~ phase ~ " fault");
    }
}

private final class DurableDocumentFailure : Exception {
    DurableRootKey key;
    string status;
    string code;
    string sink;
    bool fatal;
    Exception original;
    this(DurableRootKey key, string status, string code, string sink,
            Exception cause, bool fatal = false) {
        super(cause.msg);
        this.key = key;
        this.status = status;
        this.code = code;
        this.sink = sink;
        this.fatal = fatal;
        this.original = cause;
    }
}

private struct DispatchFailureFacts {
    bool found;
    DetectionOutcomeV1 outcome;
    string phase;
    string code;
    string reason;
}

/// Recover the same dispatch failure through each shipping transport wrapper.
private DispatchFailureFacts dispatchFailureFacts(Throwable failure) {
    if (failure is null) return DispatchFailureFacts.init;
    if (auto dispatch = cast(DispatchExecutionFailureV1)failure) {
        auto phase = dispatch.phase == "refine" ? "inspect" :
            dispatch.phase == "extract" ? "decode" : "filter";
        auto code = phase == "inspect" ? "inspect-invalidated" :
            phase == "decode" ? "decode-failed" : "filter-failed";
        return DispatchFailureFacts(true, dispatch.outcome, phase, code,
            dispatch.original is null ? dispatch.msg : dispatch.original.msg);
    }
    if (auto effect = cast(EffectFailure)failure) {
        auto facts = dispatchFailureFacts(effect.original);
        if (facts.found) return facts;
    }
    if (auto durable = cast(DurableDocumentFailure)failure) {
        auto facts = dispatchFailureFacts(durable.original);
        if (facts.found) return facts;
    }
    if (auto jsonl = cast(JsonlFailure)failure) {
        auto facts = dispatchFailureFacts(jsonl.original);
        if (facts.found) return facts;
    }
    return dispatchFailureFacts(failure.next);
}

private DocumentId localDocumentId(string file, string inputPath,
        bool inputIsDir) {
    auto relative = inputIsDir ? relativePath(file, inputPath) : ".";
    return DocumentId.from(SourceLocator("local-files:v1", inputPath, relative));
}

private void explainDispatchInputProblem(ref RuntimePlanV1 plan,
        string file, string inputPath, bool inputIsDir, bool canceled) {
    auto id = localDocumentId(file, inputPath, inputIsDir);
    auto record = canceled ? canonicalDispatchCancellationRecordV1(
        plan.identity, id, "source", "canceled", "input-canceled") :
        canonicalDispatchFailureRecordV1(plan.identity, id,
            DetectionOutcomeV1.unknown, "source", "input-failed",
            "input-failed");
    writeln("EXPLAIN\t", record);
}

private ubyte[32] durableContentDigest(Content content) {
    auto digest = Sha256.create;
    content.stream((const(ubyte)[] chunk) { digest.put(chunk); });
    return digest.finish();
}

private ManifestOutcome processDurableOne(DurableJobLedger ledger,
        string databasePath, string file, string inputRoot, string outputRoot,
        bool inputIsDir, ref RuntimePlanV1 job, ulong reservedBytes,
        ref const(ubyte[32]) configHash, bool retry, bool journalRoute,
        bool targeted, bool requireRuntimeEvidence, bool allowVerifiedSkip) {
    auto relative = inputIsDir ? relativePath(file, inputRoot) : ".";
    auto document = Document(SourceLocator("local-files:v1", inputRoot, relative),
        OutputName(inputIsDir ? relative : baseName(outputRoot)));
    auto selectedRoot = inputIsDir ? outputRoot : dirName(outputRoot);
    DurableRootKey rootKey;
    LocalJobOutcome outcome;
    bool allEventsPreviouslyTerminal = true;
    bool verifiedSkip;
    string dispatchRecord;
    try outcome = runLocalJobBatch(file, reservedBytes, document, job,
        (ref const ubyte[32] inputHash) {
            rootKey = DurableRootKey(document.id, inputHash, configHash);
            if (targeted && !ledger.hasOutstanding(rootKey))
                throw new DurableDocumentFailure(rootKey,
                    "target-mismatch", "target-mismatch",
                    derivedSink("root", rootKey.document, 0),
                    new Exception("durable job: target-mismatch"));
            if (journalRoute && !retry &&
                    ledger.hasOutstanding(rootKey))
                throw new DurableDocumentFailure(rootKey,
                    "retry-required", "retry-required",
                    derivedSink("root", rootKey.document, 0),
                    new Exception("durable job: retry-required"));
            if (allowVerifiedSkip && !retry && !requireRuntimeEvidence)
                verifiedSkip = ledger.verifiedEmittedSkip(rootKey);
            if (verifiedSkip) return;
            ledger.planRoot(rootKey);
            version (FailurePolicyHarness) {
                foreach (phase; ["read", "decode", "filter"]) try {
                    failureAt(databasePath, phase, file);
                } catch (Exception failure) {
                    if (exists(databasePath ~ ".fault-v2-arm-ack-on-failure"))
                        write(databasePath ~ ".fault-v2-ack", "1");
                    if (journalRoute)
                        ledger.recordRootFailure(rootKey, phase, phase ~ "-failed");
                    if (exists(databasePath ~ ".fault-log-ack"))
                        throw new Exception("durable job: injected-log-ack-failure");
                    throw new DurableDocumentFailure(rootKey, "failed",
                        phase ~ "-failed",
                        derivedSink("root", rootKey.document, 0), failure);
                }
            }
            version (ManifestCliHarness) manifestKillAt(databasePath, "after-root-plan");
            version (ManifestCliHarness) manifestKillAt(databasePath, "after-plan");
        },
        (ref RuntimeExecutionV1 execution, ref const ubyte[32] inputHash) {
            auto events = execution.events;
            if (execution.hasDispatch)
                dispatchRecord = canonicalDispatchRecordV1(
                    execution.dispatch);
            DurableEventPlan[] plans;
            bool[string] destinations;
            foreach (ordinal, ref event; events) {
                DurableEventPlan plan;
                plan.ordinal = ordinal;
                final switch (event.kind) {
                case EventKind.emitted: plan.kind = "emitted"; break;
                case EventKind.rejected: plan.kind = "rejected"; break;
                case EventKind.quarantined: plan.kind = "quarantined"; break;
                }
                plan.document = event.payload.document.id;
                plan.outputName = event.payload.document.outputName.text;
                if (event.kind == EventKind.emitted) {
                    plan.hasOutput = true;
                    plan.destination = !event.isChild ?
                        destinationFor(file, inputRoot, outputRoot, inputIsDir) :
                        buildPath(selectedRoot, checkedOutputName(plan.outputName));
                    plan.outputSha256 = durableContentDigest(event.payload.content);
                    plan.sink = !event.isChild ? "local-primary:v1" :
                        derivedSink(plan.kind, plan.document, ordinal);
                    try preflightDestination(plan.destination, selectedRoot);
                    catch (Exception failure) {
                        throw new DurableDocumentFailure(rootKey, "failure",
                            "policy-failed", plan.sink, failure, true);
                    }
                    auto normalized = normalizedAbsolute(plan.destination);
                    if (normalized in destinations)
                        throw new OutputPolicyViolation(
                            "output collision: " ~ plan.destination);
                    destinations[normalized] = true;
                } else {
                    plan.hasReason = true;
                    plan.reasonSha256 = reasonDigest(event.reason);
                    plan.sink = derivedSink(plan.kind, plan.document, ordinal);
                }
                plans ~= plan;
            }
            try ledger.planEvents(rootKey, plans);
            catch (Exception failure) {
                throw new DurableDocumentFailure(rootKey, "failure",
                    "manifest-failed", plans.length ? plans[0].sink :
                        derivedSink("root", rootKey.document, 0), failure, true);
            }
            version (ManifestCliHarness) manifestKillAt(databasePath, "after-event-plan");
            foreach (ordinal, ref event; events) {
                auto prior = ledger.readEvent(rootKey, ordinal);
                if (prior.state != DurableEventState.committed &&
                        prior.state != DurableEventState.acknowledged)
                    allEventsPreviouslyTerminal = false;
                DurableAction action;
                try action = ledger.prepare(rootKey, ordinal, retry);
                catch (Exception decision) {
                    if (decision.msg == "durable job: retry-required")
                        throw new DurableDocumentFailure(rootKey,
                            "retry-required", "retry-required",
                            plans[ordinal].sink, decision);
                    throw new DurableDocumentFailure(rootKey, "failure",
                        cast(ResourceExhaustion)decision !is null ?
                            "resource-failed" : "inspect-invalidated",
                        plans[ordinal].sink, decision, true);
                }
                if (action == DurableAction.skip) continue;
                bool touched;
                string activePhase = "policy";
                try {
                    ensurePlainDirectory(selectedRoot,
                        dirName(plans[ordinal].destination));
                    version (FailurePolicyHarness)
                        failureAt(databasePath, "policy", file);
                    version (FailurePolicyHarness)
                        failureAt(databasePath, "content-own", file);
                    ledger.beginPublication(rootKey, ordinal);
                    version (ManifestCliHarness) manifestKillAt(databasePath,
                        ordinal == 0 ? "after-first-intent" : "after-intent");
                    version (ManifestCliHarness) manifestKillAt(databasePath,
                        "before-publish");
                    activePhase = "sink";
                    touched = true;
                    version (FailurePolicyHarness) {
                        if (exists(databasePath ~ ".fault-policy-swap")) {
                            import std.file : symlink;
                            symlink(file, plans[ordinal].destination);
                        }
                    }
                    version (FailurePolicyHarness)
                        failureAt(databasePath, "sink", file);
                    {
                        auto publicationStarted = beginDurableMetricV1();
                        scope(exit) recordDurableMetricV1(
                            DurableMetricPhaseV1.publication,
                            event.payload.content.size, publicationStarted);
                        writeAtomicPieces(plans[ordinal].destination,
                            event.payload.content.pieces());
                    }
                    version (ManifestCliHarness) manifestKillAt(databasePath,
                        ordinal == 0 ? "after-first-publish" : "after-last-output");
                    version (ManifestCliHarness) if (ordinal == 1)
                        manifestKillAt(databasePath, "after-second-publish");
                    version (ManifestCliHarness) manifestKillAt(databasePath,
                        "after-publish");
                    ledger.commitPublished(rootKey, ordinal);
                    version (ManifestCliHarness) manifestKillAt(databasePath,
                        ordinal == 0 ? "after-first-commit" : "after-event-commit");
                    version (ManifestCliHarness) manifestKillAt(databasePath,
                        "after-commit");
                } catch (Exception failure) {
                    string phase = activePhase;
                    string code = phase == "sink" ? "sink-write-failed" :
                        "policy-failed";
                    if (cast(OutputPolicyViolation)failure !is null) {
                        phase = "policy"; code = "policy-failed";
                    } else if (cast(ResourceExhaustion)failure !is null) {
                        phase = "resource"; code = "resource-failed";
                    }
                    try ledger.recordFailure(rootKey, ordinal, touched, phase, code);
                    catch (Throwable ignored) { throw failure; }
                    if (phase == "policy" || phase == "resource")
                        throw new DurableDocumentFailure(rootKey,
                            touched ? "uncertain" : "failed", code,
                            plans[ordinal].sink, failure, true);
                    throw new DurableDocumentFailure(rootKey,
                        touched ? "uncertain" : "failed", code,
                        plans[ordinal].sink, failure);
                }
            }
            version (ManifestCliHarness) manifestKillAt(databasePath,
                "before-root-commit");
            ledger.completeRoot(rootKey);
            version (ManifestCliHarness) manifestKillAt(databasePath, "after-root-commit");
        }, { return verifiedSkip; });
    catch (DispatchExecutionFailureV1 failure) {
        if (rootKey.document.text.length != 0) {
            auto phase = failure.phase == "refine" ? "inspect" :
                failure.phase == "extract" ? "decode" : "filter";
            auto code = phase == "inspect" ? "inspect-invalidated" :
                phase == "decode" ? "decode-failed" : "filter-failed";
            try ledger.recordRootFailure(rootKey, phase, code);
            catch (Exception unavailable) {
                if (unavailable.msg != "durable job: root-failure-unavailable")
                    throw unavailable;
            }
            throw new DurableDocumentFailure(rootKey, "failed", code,
                derivedSink("root", rootKey.document, 0), failure);
        }
        throw failure;
    }
    catch (CompiledJobFailure failure) {
        if (rootKey.document.text.length != 0) {
            try ledger.recordRootFailure(rootKey, "filter", "filter-failed");
            catch (Exception unavailable) {
                // Manifest v2 has workflow state but deliberately no failure
                // history. The planned root remains replayable.
                if (unavailable.msg != "durable job: root-failure-unavailable")
                    throw unavailable;
            }
            throw new DurableDocumentFailure(rootKey, "failed",
                "filter-failed", derivedSink("root", rootKey.document, 0),
                failure);
        }
        throw failure;
    }
    auto terminal = outcome.rejected != 0 || outcome.quarantined != 0;
    auto status = terminal ? outcome.status :
        (allEventsPreviouslyTerminal ? "skipped" :
            (retry ? "retry" : outcome.status));
    auto result = manifestOutcome(status, outcome.firstReason,
        SinkKey(rootKey.document, rootKey.inputSha256, rootKey.configSha256,
            "local-primary:v1"), terminal);
    result.dispatchRecord = dispatchRecord;
    return result;
}

int runApp(string[] args) {
    auto metricsPath = environment.get("SCRUBBED_DURABLE_METRICS_V1", "");
    const allowVerifiedSkip =
        environment.get("SCRUBBED_DURABLE_SKIP_DISABLE_V1", "") != "1";
    if (metricsPath.length) enableDurableMetricsV1();
    scope(exit) if (metricsPath.length)
        write(metricsPath, durableMetricsJsonV1() ~ "\n");
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
        "error-journal", "Existing opt-in v3 failure journal", &errorJournalPath,
        "error-retry", "Explicitly retry unresolved v3 outputs", &errorRetry,
        "error-targeted", "Retry only exact local v3 outstanding targets", &errorTargeted,
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
        throw new Exception("v3 journal is exclusive with manifest and dry-run");
    if (jsonlRoute) {
        if (manifestPath.length || manifestRetry || errorJournalPath.length ||
            errorRetry || errorTargeted)
            throw new Exception("--manifest is unavailable in JSONL mode");
        if (inputPath != "-" || outputPath != "-" ||
            !fieldsExplicit || !namespaceExplicit || !sourceExplicit ||
            !lineCapExplicit || !outputCapExplicit)
            throw new Exception("JSONL requires --input -, --output -, selected fields, identity, and both byte caps");
        if (listFilters)
            throw new Exception("--list-filters is unavailable in JSONL mode");
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
        if (compositionExplicit && (configPath.length || filtersExplicit))
            throw new Exception("composition options are mutually exclusive with --config and --filters");
        configContents = configPath.length ? readText(configPath) : "";
        versionedConfig = configContents.length && hasJobVersion(configContents);
        auto runtimePlan = selectedRuntimePlan(compositionTokens, filtersExplicit,
            filterList, configPath.length != 0, configContents, versionedConfig);
        if (explain && !runtimePlan.isDispatch)
            throw new Exception("--explain is unavailable for v3 JSONL mode");
        if (validateOnly) {
            stderr.writeln("valid JSONL invocation; no stdin read.");
            return 0;
        }
        string[] pendingDispatchRecords;
        try {
            const completed = processStandardJsonlDocuments(datasetNamespace,
                sourceKey, fields,
                (string field, string text, SourceLocator source,
                        size_t selectedOrdinal) =>
                    runJsonlField(source, field, text, runtimePlan,
                        (ref RuntimeExecutionV1 execution) {
                            if (explain && execution.hasDispatch)
                                pendingDispatchRecords ~=
                                    canonicalJsonlDispatchRecordV1(
                                        execution.dispatch, selectedOrdinal);
                        }),
                JsonlLimits(maxJsonlLineBytes, maxJsonlOutputBytes), dryRun,
                (SourceLocator committed) {
                    foreach (record; pendingDispatchRecords)
                        stderr.writeln("EXPLAIN\t", record);
                    pendingDispatchRecords = null;
                });
            stderr.writeln("JSONL done. ", completed, " records processed", dryRun ? "; dry-run, no stdout." : ".");
            return 0;
        } catch (JsonlFailure error) {
            if (explain && runtimePlan.isDispatch &&
                    (error.kind == JsonlFailureKind.rejected ||
                        error.kind == JsonlFailureKind.quarantined))
                foreach (record; pendingDispatchRecords)
                    stderr.writeln("EXPLAIN\t", record);
            pendingDispatchRecords = null;
            if (explain && runtimePlan.isDispatch &&
                    error.kind != JsonlFailureKind.rejected &&
                    error.kind != JsonlFailureKind.quarantined) {
                auto dispatchFailure = dispatchFailureFacts(error);
                auto outcome = dispatchFailure.found ? dispatchFailure.outcome :
                    DetectionOutcomeV1.unknown;
                auto phase = dispatchFailure.found ? dispatchFailure.phase :
                    (error.kind == JsonlFailureKind.writer ? "sink" :
                        error.kind == JsonlFailureKind.outputLimit ?
                            "resource" : "decode");
                auto code = dispatchFailure.found ? dispatchFailure.code :
                    (error.kind == JsonlFailureKind.writer ?
                        "sink-write-failed" :
                        error.kind == JsonlFailureKind.outputLimit ?
                            "resource-failed" : "decode-failed");
                auto reason = dispatchFailure.found ?
                    dispatchFailure.reason : error.msg;
                auto record = error.selectedOrdinal == size_t.max ?
                    canonicalJsonlRecordFailureRecordV1(runtimePlan.identity,
                        error.documentId, outcome, phase, code, reason) :
                    canonicalJsonlDispatchFailureRecordV1(runtimePlan.identity,
                        error.documentId, outcome, phase, code, reason,
                        error.selectedOrdinal);
                stderr.writeln("EXPLAIN\t", record);
            }
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
    configContents = configPath.length ? readText(configPath) : "";
    versionedConfig = configContents.length && hasJobVersion(configContents);

    const durableRoute = (manifestPath.length || errorJournalPath.length) && !dryRun;
    auto runtimePlan = selectedRuntimePlan(compositionTokens, filtersExplicit,
        filterList, configPath.length != 0, configContents, versionedConfig);
    auto canonicalSpec = runtimePlan.canonical;
    string chainLabel = runtimePlan.identity;
    if (!versionedConfig && !compositionExplicit) {
        auto legacySpec = selectedJob(null, filtersExplicit, filterList,
            configPath.length != 0, configContents, false);
        chainLabel = legacySpec.stages[0].filters
            .map!(filter => filter.name).join(" -> ");
    }
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
        auto executable = runningExecutableDigest();
        auto durableDigest = deriveDurableIdentity(canonicalSpec,
            runtimePlan.identity, inputIsDir ? "tree" : "file",
            outputPath, executable);
        if (errorJournalPath.length) {
            auto checkedJournal = new DurableJobLedger(errorJournalPath,
                DurableKind.journal,
                DurableIdentity(durableDigest, runtimePlan.identity));
            checkedJournal.close();
        } else if (manifestPath.length && exists(manifestPath)) {
            auto checkedManifest = new DurableJobLedger(manifestPath,
                DurableKind.manifest,
                DurableIdentity(durableDigest, runtimePlan.identity));
            checkedManifest.close();
        }
        if (!errorJournalPath.length) writeln("valid. No files processed.");
        return 0;
    }
    ubyte[32] executable, configHash;
    {
        auto identityStarted = beginDurableMetricV1();
        scope(exit) if (durableRoute)
            recordDurableMetricV1(DurableMetricPhaseV1.identity, 0,
                identityStarted);
        executable = runningExecutableDigest();
        configHash = deriveDurableIdentity(canonicalSpec,
            runtimePlan.identity, inputIsDir ? "tree" : "file",
            outputPath, executable);
    }
    DurableJobLedger durableLedger;
    if (durableRoute)
        durableLedger = new DurableJobLedger(
            manifestPath.length ? manifestPath : errorJournalPath,
            manifestPath.length ? DurableKind.manifest : DurableKind.journal,
            DurableIdentity(configHash, runtimePlan.identity));
    scope(exit) if (durableLedger !is null) durableLedger.close();
    if (!dryRun && !errorTargeted)
        ensurePlainDirectory(inputIsDir ? outputPath : dirName(outputPath),
            inputIsDir ? outputPath : dirName(outputPath));
    auto pending = explain ? new PendingExplanations : null;
    auto publication = durableRoute ? null : new PublicationOrder;
    auto decisionMutex = new Mutex;
    size_t terminalDecisions;
    auto scheduler = new BoundedInput(
        InputLimits(maxQueuedDocuments, maxInputBytes, maxOpenInputs),
        manifestPath.length || errorJournalPath.length ? 1 : nThreads,
        (string file, ulong bytes) {
            ManifestOutcome decision;
            if (durableRoute) {
                decision = processDurableOne(durableLedger,
                    manifestPath.length ? manifestPath : errorJournalPath,
                    file, inputPath, outputPath, inputIsDir, runtimePlan,
                    bytes, configHash,
                    manifestPath.length ? manifestRetry : errorRetry,
                    errorJournalPath.length != 0,
                    errorTargeted, explain && runtimePlan.isDispatch,
                    allowVerifiedSkip);
            } else {
                auto local = processCompiledOne(file, inputPath, outputPath,
                    inputIsDir, runtimePlan, bytes, dryRun, publication);
                decision.status = local.status;
                decision.detail = local.firstReason;
                decision.terminal = local.rejected != 0 || local.quarantined != 0;
                decision.dispatchRecord = local.dispatchRecord;
            }
            if (decision.terminal) {
                decisionMutex.lock();
                ++terminalDecisions;
                decisionMutex.unlock();
            }
            if (explain && runtimePlan.isDispatch && decision.dispatchRecord.length)
                writeln("EXPLAIN\t", decision.dispatchRecord);
            else if (explain && errorJournalPath.length)
                v2Explain(decision.status, decision.key,
                    durableLedger.publicSinkId(decision.key.sink));
            else if (explain)
                explainOne(file, destinationFor(file, inputPath, outputPath, inputIsDir),
                    chainLabel, decision.status,
                    !durableRoute ? decision.detail : "", durableRoute ? decision.detail : "",
                    decision.hasKey ? decision.key.document.text : "",
                    decision.hasKey ? decision.key.sink : "");
            if (explain) pending.remove(file);
        },
        (string file, Throwable error) {
            auto durableDecision = cast(DurableDocumentFailure)error;
            auto effectFailure = cast(EffectFailure)error;
            auto orderedCanceled = cast(OrderedPublicationCanceled)error;
            if (explain && runtimePlan.isDispatch && orderedCanceled is null) {
                auto id = localDocumentId(file, inputPath, inputIsDir);
                auto dispatchFailure = dispatchFailureFacts(error);
                writeln("EXPLAIN\t", canonicalDispatchFailureRecordV1(
                    runtimePlan.identity, id,
                    dispatchFailure.found ? dispatchFailure.outcome :
                        DetectionOutcomeV1.unknown,
                    dispatchFailure.found ? dispatchFailure.phase : "filter",
                    dispatchFailure.found ? dispatchFailure.code : "filter-failed",
                    dispatchFailure.found ? dispatchFailure.reason : error.msg));
                if (explain) pending.remove(file);
            }
            if (errorJournalPath.length) {
                stderr.writeln("scrubbed: ", durableDecision !is null ?
                    durableDecision.code : "error-journal-fatal");
                if (explain && !runtimePlan.isDispatch && durableDecision !is null) {
                    auto display = SinkKey(durableDecision.key.document,
                        durableDecision.key.inputSha256,
                        durableDecision.key.configSha256, durableDecision.sink);
                    v2Explain(durableDecision.status, display,
                        durableLedger.publicSinkId(durableDecision.sink),
                        "sink", durableDecision.code);
                }
                if (explain) pending.remove(file);
                return;
            }
            if (orderedCanceled !is null) {
                stderr.writefln("CANCELED %s: %s", file, error.msg);
                if (explain) {
                    if (runtimePlan.isDispatch)
                        explainDispatchInputProblem(runtimePlan, file, inputPath,
                            inputIsDir, true);
                    else explainOne(file, destinationFor(file, inputPath,
                        outputPath, inputIsDir), chainLabel, "canceled", error.msg);
                }
                if (explain) pending.remove(file);
                return;
            }
            auto renderedError = effectFailure is null ? error.msg :
                error.msg ~ " (" ~ effectFailureDetail(effectFailure) ~ ")";
            stderr.writefln("%s %s: %s",
                durableDecision !is null && !durableDecision.fatal ?
                    "SKIP" : "FATAL",
                file, renderedError);
            if (explain && !runtimePlan.isDispatch) {
                string status = "failure", detail, documentId, sinkKey;
                if (durableDecision !is null) {
                    status = durableDecision.status;
                    documentId = durableDecision.key.document.text;
                    sinkKey = durableDecision.sink;
                } else if (effectFailure !is null) {
                    status = effectFailure.partialWritePossible ? "uncertain" : "failure";
                    detail = effectFailureDetail(effectFailure);
                    documentId = effectFailure.documentId.text;
                }
                explainOne(file, destinationFor(file, inputPath, outputPath, inputIsDir),
                    chainLabel, status, error.msg, detail, documentId, sinkKey);
            }
            if (explain) pending.remove(file);
        }, (Throwable error) {
            return cast(OrderedPublicationCanceled)error is null &&
                (cast(DurableDocumentFailure)error is null ||
                    (cast(DurableDocumentFailure)error).fatal);
        });
    bool workerFatalAdmission;
    void submitPath(string file) {
        bool admissionCanceled;
        try {
            if (errorTargeted) {
                auto relative = inputIsDir ? relativePath(file, inputPath) : ".";
                auto id = DocumentId.from(SourceLocator("local-files:v1",
                    inputPath, relative));
                if (!durableLedger.hasOutstanding(id)) return;
            }
            if (explain) pending.add(file);
            if (!durableRoute) publication.assign(file);
            ulong bytes;
            {
                auto statStarted = beginDurableMetricV1();
                scope(exit) if (durableRoute)
                    recordDurableMetricV1(DurableMetricPhaseV1.sourceStat,
                        0, statStarted);
                bytes = getSize(file);
            }
            if (!scheduler.submit(file, bytes)) {
                admissionCanceled = true;
                workerFatalAdmission = true;
                throw new Exception("input admission canceled: " ~ file);
            }
        } catch (Exception error) {
            if (explain && !admissionCanceled && !errorJournalPath.length) {
                pending.remove(file);
                if (runtimePlan.isDispatch)
                    explainDispatchInputProblem(runtimePlan, file, inputPath,
                        inputIsDir, false);
                else explainOne(file, destinationFor(file, inputPath, outputPath,
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
                if (explain && !errorJournalPath.length) {
                    if (runtimePlan.isDispatch)
                        explainDispatchInputProblem(runtimePlan, entry.name,
                            inputPath, inputIsDir, false);
                    else explainOne(entry.name, destinationFor(entry.name,
                        inputPath, outputPath, inputIsDir), chainLabel,
                        "failure", reason);
                }
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
            walkCanonical(inputPath);
        } else {
            submitPath(inputPath);
        }
    } catch (Exception error) {
        if (!durableRoute) publication.abort();
        scheduler.cancel();
        scheduler.finish();
        if (explain && !errorJournalPath.length)
            foreach (file; pending.drain()) {
                if (runtimePlan.isDispatch)
                    explainDispatchInputProblem(runtimePlan, file, inputPath,
                        inputIsDir, true);
                else explainOne(file, destinationFor(file, inputPath, outputPath,
                    inputIsDir), chainLabel,
                    workerFatalAdmission ? "canceled" : "failure",
                    workerFatalAdmission ?
                        "canceled after fatal processing failure" :
                        "canceled after traversal error");
            }
        auto workerFatal = scheduler.fatal();
        if (workerFatalAdmission && workerFatal !is null)
            throw new Exception("fatal file processing failure: " ~ workerFatal.msg);
        throw error;
    }
    const counts = scheduler.finish();
    if (scheduler.fatal() !is null) {
        if (explain && !errorJournalPath.length)
            foreach (file; pending.drain()) {
                if (runtimePlan.isDispatch)
                    explainDispatchInputProblem(runtimePlan, file, inputPath,
                        inputIsDir, true);
                else explainOne(file, destinationFor(file, inputPath,
                    outputPath, inputIsDir), chainLabel, "canceled",
                    "fatal processing failure");
            }
        throw new Exception("fatal file processing failure: " ~ scheduler.fatal().msg);
    }
    if (durableLedger !is null) durableLedger.checkpoint();
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
    auto terminalArgs = ["--input", input, "--output", rejectedOutput,
        "--stage", "stop=fixture", "--stage-option", "suffix=text:policy-stop",
        "--stage-option", "enabled=boolean:true", "--threads", "1", "--explain"];
    auto durableManifest = buildPath(root, "terminal-manifest.db");
    requireCli(runApp(["scrubbed", "run"] ~ terminalArgs ~
        ["--manifest", durableManifest]) == 1, "manifest terminal first exit");
    requireCli(runApp(["scrubbed", "run"] ~ terminalArgs ~
        ["--manifest", durableManifest]) == 1, "manifest terminal replay exit");
    requireCli(runApp(["scrubbed", "run"] ~ terminalArgs ~
        ["--manifest", durableManifest, "--manifest-retry"]) == 1,
        "manifest terminal retry exit");
    auto durableJournal = buildPath(root, "terminal-journal.db");
    createJournalV3(durableJournal);
    requireCli(runApp(["scrubbed", "run"] ~ terminalArgs ~
        ["--error-journal", durableJournal]) == 1, "journal terminal first exit");
    requireCli(runApp(["scrubbed", "run"] ~ terminalArgs ~
        ["--error-journal", durableJournal]) == 1, "journal terminal replay exit");
    requireCli(runApp(["scrubbed", "run"] ~ terminalArgs ~
        ["--error-journal", durableJournal, "--error-retry"]) == 1,
        "journal terminal retry exit");
    requireCli(!exists(rejectedOutput), "durable rejection published output");
}

unittest {
    import std.exception : assertThrown;
    import std.file : rmdirRecurse, tempDir;

    string[] dispatchTokens(string action, long cap = 268435456) {
        auto tokens = [
            "--dispatch-option", "detector-prefix-bytes=4096",
            "--dispatch-option", "detector-evidence-records=16",
            "--dispatch-option", "detector-warnings=8",
            "--dispatch-option", "container-max-physical-bytes=33554432",
            "--dispatch-option", "container-max-expanded-bytes=134217728",
            "--dispatch-option", "container-max-entries=2048",
            "--dispatch-option", "container-max-depth=2",
            "--dispatch-option", "container-max-ratio=100"
        ];
        if (action == "route") tokens ~= [
            "--route", "text=core-plain-text",
            "--route-option", "max-output-bytes=integer:" ~ cap.to!string
        ];
        foreach (outcome; ["unknown", "plain-text", "html", "pdf", "png",
                "jpeg", "gif", "ambiguous", "malformed", "encrypted",
                "unsupported", "generic-zip", "ooxml-word"]) {
            auto selected = outcome == "plain-text" ? action : "reject";
            auto target = selected == "route" ? "text" : "policy";
            tokens ~= ["--action", outcome ~ "=" ~ selected ~ ":" ~ target];
        }
        tokens ~= "--common";
        return tokens;
    }

    auto root = buildPath(tempDir, "scrubbed-dispatch-cli-" ~ randomUUID.toString);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    mkdir(root);
    auto input = buildPath(root, "input.txt");
    write(input, "hello");

    auto routeTokens = dispatchTokens("route", 5);
    auto tokenPlan = selectedRuntimePlan(routeTokens, false, null,
        false, null, false);
    auto json = tokenPlan.canonical;
    auto jsonPlan = selectedRuntimePlan(null, false, null, true, json, true);
    assert(tokenPlan.identity == jsonPlan.identity &&
        tokenPlan.canonical == jsonPlan.canonical);

    auto routed = buildPath(root, "routed.txt");
    assert(runApp(["scrubbed", "--input", input, "--output", routed,
        "--threads", "1"] ~ routeTokens) == 0);
    assert(readText(routed) == "hello");

    auto passOutput = buildPath(root, "passed.txt");
    assert(runApp(["scrubbed", "--input", input, "--output", passOutput,
        "--threads", "1"] ~ dispatchTokens("pass")) == 0);
    assert(readText(passOutput) == "hello");
    foreach (policy; ["reject", "quarantine"]) {
        auto output = buildPath(root, policy ~ ".txt");
        assert(runApp(["scrubbed", "--input", input, "--output", output,
            "--threads", "1"] ~ dispatchTokens(policy)) == 1);
        assert(!exists(output));
    }

    auto below = buildPath(root, "below.txt");
    assertThrown(runApp(["scrubbed", "--input", input, "--output", below,
        "--threads", "1"] ~ dispatchTokens("route", 4)));
    assert(!exists(below));
    auto above = buildPath(root, "above.txt");
    assert(runApp(["scrubbed", "--input", input, "--output", above,
        "--threads", "1"] ~ dispatchTokens("route", 6)) == 0);

    auto invalid = buildPath(root, "invalid.txt");
    ubyte[] invalidBytes = new ubyte[4097];
    invalidBytes[] = 'a';
    invalidBytes[$ - 1] = 0xff;
    write(invalid, invalidBytes);
    auto invalidOutput = buildPath(root, "invalid-output.txt");
    assertThrown(runApp(["scrubbed", "--input", invalid,
        "--output", invalidOutput, "--threads", "1"] ~
        dispatchTokens("route", 5000)));
    assert(!exists(invalidOutput));

    auto malformed = dispatchTokens("route", 5);
    malformed = malformed[0 .. $ - 1] ~ ["--route-option",
        "max-output-bytes=integer:5", "--common"];
    auto unopenedOutput = buildPath(root, "unopened.txt");
    auto unopenedStore = buildPath(root, "unopened.db");
    assertThrown(runApp(["scrubbed", "--input", buildPath(root, "missing"),
        "--output", unopenedOutput, "--manifest", unopenedStore] ~ malformed));
    assert(!exists(unopenedOutput) && !exists(unopenedStore));

    auto durableOutput = buildPath(root, "durable.txt");
    auto durableStore = buildPath(root, "v4.db");
    auto durableArgs = ["scrubbed", "--input", input, "--output", durableOutput,
        "--threads", "1", "--manifest", durableStore] ~ routeTokens;
    assert(runApp(durableArgs) == 0);
    assert(runApp(durableArgs) == 0);
    assertThrown(runApp(["scrubbed", "--input", input, "--output", durableOutput,
        "--threads", "1", "--manifest", durableStore] ~
        dispatchTokens("route", 6)));

    auto v3Output = buildPath(root, "v3.txt");
    auto v3Store = buildPath(root, "v3.db");
    auto v3Args = ["scrubbed", "--input", input, "--output", v3Output,
        "--threads", "1", "--manifest", v3Store];
    assert(runApp(v3Args) == 0);
    assertThrown(runApp(["scrubbed", "--input", input, "--output", v3Output,
        "--threads", "1", "--manifest", v3Store] ~ routeTokens));
    assert(runApp(v3Args) == 0);
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
