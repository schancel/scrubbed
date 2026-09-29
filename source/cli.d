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
import effects.bounded_input : BoundedInput, CoordinationMetricsV2,
    CoordinationPhaseV2, InputLimits, beginCoordinationMetricV2;
import effects.jsonl_stream : JsonlFailure, JsonlFailureKind, JsonlLimits;
import effects.jsonl_job : runJsonlFieldOutcome;
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
import effects.mapped_file : openMappedFile;
import effects.independent_sinks : IndependentSinkFailure;
import effects.runner : EffectFailure, EffectPhase;
import effects.side_output_sink : SideOutputSink;
import content.pieces : Content, ContentPiece;
import domain.document : Document, DocumentId, DocumentViewOwner, OutputName,
    SourceLocator;
import domain.encoding_failure : InvalidEncodingFailure;
import effects.html_tree : checkedHtmlByteLimit, defaultExtractHtmlBytes;
import effects.html_tree_json_stage;
import effects.html_markdown_stage;
import effects.html_main_content_markdown_stage;
import stages.contract : EventKind, ResourceDeclaration, StageDeclaration,
    StageDocument, StageEvent, TerminalSideOutput;
import stages.pii_four_class;
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
import std.digest : LetterCase, toHexString;
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
import std.string : indexOf, join, lastIndexOf;
import std.utf : UTFException, validate;
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

private void requireUnaliasedFileOrAbsent(string path, string label) {
    bool link;
    try link = isSymlink(path);
    catch (FileException failure) { if (exists(path)) throw failure; }
    if (link || exists(path) && !isFile(path))
        throw new OutputPolicyViolation(label ~ " must be a plain file or absent");
    if (exists(path)) {
        stat_t info;
        if (stat(path.toStringz, &info) != 0 || info.st_nlink != 1)
            throw new OutputPolicyViolation(label ~ " has a hard-link alias");
    }
}

private void preflightSidecarRoots(string inputPath, string outputPath,
        string sidecarPath, bool inputIsDir) {
    if (!sidecarPath.length)
        throw new OutputPolicyViolation(
            "side-output-producing plan requires --sidecar-output");
    if (exists(sidecarPath) && isSymlink(sidecarPath))
        throw new OutputPolicyViolation("refusing symlink sidecar output path");
    rejectUnresolvableAncestorLinks(sidecarPath);
    auto resolved = resolveExistingPrefix(sidecarPath);
    if (inputIsDir) {
        if (pathsOverlap(resolved, inputPath) ||
                pathsOverlap(resolved, outputPath))
            throw new OutputPolicyViolation(
                "sidecar root overlaps input or primary output");
        preflightOutput(resolved, true);
    } else {
        if (resolved == inputPath || resolved == outputPath ||
                sameFile(sidecarPath, inputPath) ||
                sameFile(sidecarPath, outputPath) ||
                sameFile(inputPath, outputPath))
            throw new OutputPolicyViolation(
                "sidecar destination aliases input or primary output");
        preflightOutput(resolved, false);
        requireUnaliasedFileOrAbsent(sidecarPath, "sidecar destination");
        requireUnaliasedFileOrAbsent(outputPath, "primary destination");
    }
}

private string sidecarDestinationFor(string sidecarRoot, bool inputIsDir,
        const ref StageEvent event, const ref TerminalSideOutput output) {
    if (!inputIsDir) return sidecarRoot;
    return buildPath(sidecarRoot,
        checkedOutputName(event.payload.document.outputName.text ~ output.suffix));
}

/// Stages complete side records in input/field order, then atomically replace
/// the append-free JSONL destination only after the whole stream succeeds.
private final class JsonlSidecarWriter : SideOutputSink {
    private string destination;
    private string spoolPath;
    private File spool;
    private ulong bytes;
    private size_t recordLimit;
    private ulong aggregateLimit;
    private bool dryRun;
    private bool finished;

    this(string destination, size_t recordLimit, ulong aggregateLimit,
            bool dryRun) {
        this.destination = destination.idup;
        this.recordLimit = recordLimit;
        this.aggregateLimit = aggregateLimit;
        this.dryRun = dryRun;
        if (!dryRun) {
            auto parent = dirName(destination);
            ensurePlainDirectory(parent, parent);
            spoolPath = buildPath(parent, "." ~ baseName(destination) ~
                ".scrubbed-sidecar-" ~ randomUUID.toString ~ ".tmp");
            spool = File(spoolPath, "wxb");
        }
    }

    void append(const ref TerminalSideOutput output) {
        auto payload = output.bytes;
        auto recordBytes = cast(ulong) payload.length + 1;
        if (recordBytes > recordLimit)
            throw new ResourceExhaustion(
                "JSONL side-output record exceeds byte cap", 0);
        if (recordBytes > aggregateLimit || bytes > aggregateLimit - recordBytes)
            throw new ResourceExhaustion(
                "JSONL side-output aggregate exceeds byte cap", 0);
        // A JSONL destination admits one complete JSON object per selected
        // field. The generic effects layer validates framing, not its schema.
        try {
            auto parsed = parseJSON(cast(string) payload);
            if (parsed.type != JSONType.object)
                throw new Exception("record is not an object");
        } catch (Exception) {
            throw new OutputPolicyViolation(
                "JSONL side output is not one JSON object");
        }
        if (!dryRun) {
            spool.rawWrite(payload);
            spool.rawWrite(cast(const(ubyte)[]) "\n");
        }
        bytes += recordBytes;
    }

    /// SideOutputSink conformance: this adapter has one fixed destination,
    /// set at construction, so the caller-resolved destination is unused.
    void publish(const ref TerminalSideOutput output, string) {
        append(output);
    }

    void commit() {
        if (finished) return;
        if (dryRun) { finished = true; return; }
        spool.flush();
        spool.close();
        scope owner = bytes == 0 ? new DocumentViewOwner(new ubyte[0]) :
            openMappedFile(spoolPath, bytes);
        auto content = new Content([ContentPiece.borrow(
            owner.view(0, cast(size_t) bytes))]);
        writeAtomicPieces(destination, content.pieces());
        owner.close();
        remove(spoolPath);
        spoolPath = null;
        finished = true;
    }

    void abort() nothrow {
        if (finished) return;
        finished = true;
        try spool.close(); catch (Exception) {}
        try if (spoolPath.length && exists(spoolPath)) remove(spoolPath);
        catch (Exception) {}
    }
}

/// Writes each side output immediately, atomically, to its caller-resolved
/// destination. `cli` uses one instance for the tree-mirrored sidecar route
/// (destinations chosen via `sidecarDestinationFor`) and for both
/// durable-ledger side-output routes (`--manifest` and `--error-journal`,
/// which choose destinations the same way); all three call sites publish
/// through this same stateless adapter. Every publish is already a
/// complete, independent atomic replace, so commit()/abort() are no-ops.
private final class MirroredFileSideOutputSink : SideOutputSink {
    void publish(const ref TerminalSideOutput output, string destination) {
        auto content = new Content([ContentPiece.own(output.bytes)]);
        writeAtomicPieces(destination, content.pieces());
    }

    void commit() {}
    void abort() nothrow {}
}

/// Structural proof for the side-output publication seam (issue #282, seam
/// 3): every local side-output writer conforms to SideOutputSink, and each
/// of the four original call sites -- the JSONL sidecar route, the
/// tree-mirror route inside processCompiledOne, and both durable-ledger
/// routes inside processDurableOne (--manifest and --error-journal) -- holds
/// and drives its writer only through this interface type, never through a
/// writer-specific branch. This is a structural check, not a new behavioral
/// acceptance criterion.
unittest {
    static assert(is(JsonlSidecarWriter : SideOutputSink),
        "JsonlSidecarWriter must conform to SideOutputSink");
    static assert(is(MirroredFileSideOutputSink : SideOutputSink),
        "MirroredFileSideOutputSink must conform to SideOutputSink");

    SideOutputSink[] sinks = [
        cast(SideOutputSink) new JsonlSidecarWriter("unused", 1, 1, true),
        cast(SideOutputSink) new MirroredFileSideOutputSink,
    ];
    foreach (sink; sinks) {
        assert(sink !is null);
        sink.commit();
        sink.abort();
    }
}

private string destinationFor(string file, string inputRoot, string outputRoot,
                              bool inputIsDir) {
    return inputIsDir ? buildPath(outputRoot, relativePath(file, inputRoot)) : outputRoot;
}

private string durableOutputIdentity(string primary, string sidecar) {
    return sidecar.length ? primary ~ "\nsidecar-output=" ~ sidecar : primary;
}

private string sideOutputExplainRecord(const ref StageEvent event,
        const ref TerminalSideOutput output, string status) {
    return ("EXPLAIN\tside_output_status=" ~ status ~
        "\tdocument_id=" ~ event.payload.document.id.text ~
        "\tschema=" ~ output.schema ~ "\tsink_key=" ~ output.key ~
        "\tdigest=" ~ toHexString!(LetterCase.lower)(output.digest)).idup;
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
    auto expectedStage = format == "markdown" ? "html-markdown" :
        format == "main-content-markdown" ? "html-main-content-markdown" : "html-tree-json";
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
            auto name = recordKey ~
                ((format == "markdown" || format == "main-content-markdown") ?
                    ".md" : ".tree.json");
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

/// True when `error` (possibly wrapped by `EffectFailure`/`CompiledJobFailure`)
/// ultimately stems from a stage rejecting non-UTF-8 input -- either
/// `std.utf.validate` surfacing directly as `UTFException` (text-transform's
/// filter chain, composition/executor.d's `materializeUtf8`), or another
/// stage/domain module that independently re-validates UTF-8 ahead of
/// text-transform in a custom `run --stage` pipeline and rewraps the failure
/// into its own exception type marked `domain.encoding_failure.InvalidEncodingFailure`
/// (#402: pii_patterns/pii_policy/structured_chunks/similarity_signature/
/// pii_overlay all do this). Walking the wrapper chain by type, rather than
/// matching on rendered message text, keeps this immune to message wording
/// changes in any wrapper, and matching by interface rather than by each
/// domain module's own concrete exception type keeps this detector from
/// needing to know about every stage that can hit invalid UTF-8.
private bool isInvalidEncodingFailure(Throwable error) {
    if (auto compiled = cast(CompiledJobFailure) error)
        return isInvalidEncodingFailure(compiled.original);
    if (auto effect = cast(EffectFailure) error)
        return isInvalidEncodingFailure(effect.original);
    return (cast(UTFException) error) !is null ||
        (cast(InvalidEncodingFailure) error) !is null;
}

/// A per-document, quarantine-eligible reason string that names the actual
/// problem (invalid UTF-8) instead of surfacing the generic wrapped-exception
/// message a reader would otherwise see under a "FATAL"/"SKIP" prefix.
private string invalidEncodingReason(Throwable error) {
    if (auto compiled = cast(CompiledJobFailure) error)
        return invalidEncodingReason(compiled.original);
    if (auto effect = cast(EffectFailure) error)
        return invalidEncodingReason(effect.original);
    return "invalid encoding: input is not valid UTF-8 (" ~ error.msg ~ ")";
}

private LocalJobOutcome processCompiledOne(string file, string inputRoot,
        string outputRoot, bool inputIsDir, ref RuntimePlanV1 job,
        ulong reservedBytes, bool dryRun, PublicationOrder publication,
        CoordinationMetricsV2 metrics = null, string sidecarRoot = null,
        SideOutputSink sideOutputSink = null) {
    auto relative = inputIsDir ? relativePath(file, inputRoot) : ".";
    auto rootDestination = destinationFor(file, inputRoot, outputRoot, inputIsDir);
    auto document = Document(SourceLocator("local-files:v1", inputRoot, relative),
        OutputName(inputIsDir ? relative : baseName(outputRoot)));
    auto ordinal = publication.ordinal(file);
    bool entered;
    try {
        string dispatchRecord;
        if (sidecarRoot.length) {
            struct PendingWrite {
                string sink;
                string destination;
                Content content;
                bool isSideOutput;
                TerminalSideOutput sideOutput;
            }
            string[] sideRecords;
            auto result = runLocalJobBatch(file, reservedBytes, document, job,
                (ref const ubyte[32]) {},
                (ref RuntimeExecutionV1 execution, ref const ubyte[32]) {
                    if (execution.hasDispatch)
                        dispatchRecord = canonicalDispatchRecordV1(
                            execution.dispatch);
                    PendingWrite[] writes;
                    bool[string] destinations;
                    foreach (ref event; execution.events) {
                        if (event.kind == EventKind.emitted) {
                            auto destination = !event.isChild ? rootDestination :
                                buildPath(inputIsDir ? outputRoot : dirName(outputRoot),
                                    checkedOutputName(
                                        event.payload.document.outputName.text));
                            writes ~= PendingWrite("local-primary:v1",
                                destination, event.payload.content);
                        }
                        if (event.kind == EventKind.emitted) {
                            foreach (ref output; event.sideOutputs) {
                                auto destination = sidecarDestinationFor(sidecarRoot,
                                    inputIsDir, event, output);
                                auto write = PendingWrite("side-output:" ~ output.key,
                                    destination, null);
                                write.isSideOutput = true;
                                write.sideOutput = output;
                                writes ~= write;
                                sideRecords ~= sideOutputExplainRecord(event, output,
                                    dryRun ? "dry-run" : "published");
                            }
                        }
                    }
                    // Resolve and reserve the complete destination set before
                    // the first publication attempt for this document.
                    foreach (ref pendingWrite; writes) {
                        auto selectedRoot = pendingWrite.sink == "local-primary:v1"
                            ? (inputIsDir ? outputRoot : dirName(outputRoot))
                            : (inputIsDir ? sidecarRoot : dirName(sidecarRoot));
                        auto normalized = normalizedAbsolute(
                            pendingWrite.destination);
                        if (normalized in destinations)
                            throw new OutputPolicyViolation(
                                "primary and side-output destinations collide");
                        destinations[normalized] = true;
                        publication.reserve(normalized);
                        preflightDestination(pendingWrite.destination,
                            selectedRoot);
                        requireUnaliasedFileOrAbsent(pendingWrite.destination,
                            pendingWrite.sink);
                    }
                    foreach (ref pendingWrite; writes) {
                        auto selectedRoot = pendingWrite.sink == "local-primary:v1"
                            ? (inputIsDir ? outputRoot : dirName(outputRoot))
                            : (inputIsDir ? sidecarRoot : dirName(sidecarRoot));
                        if (!dryRun) ensurePlainDirectory(selectedRoot,
                            dirName(normalizedAbsolute(pendingWrite.destination)));
                    }
                    publication.enter(ordinal);
                    entered = true;
                    IndependentSinkFailure first;
                    if (!dryRun) foreach (ref pendingWrite; writes) try {
                        if (pendingWrite.isSideOutput)
                            sideOutputSink.publish(pendingWrite.sideOutput,
                                pendingWrite.destination);
                        else
                            writeAtomicPieces(pendingWrite.destination,
                                pendingWrite.content.pieces());
                    } catch (Exception failure) {
                        if (first is null) first = new IndependentSinkFailure(
                            pendingWrite.sink, failure);
                    }
                    if (first !is null) throw first;
                });
            if (!entered)
                throw new Exception("compiled job produced no terminal decision");
            publication.complete();
            result.dispatchRecord = dispatchRecord;
            result.sideOutputRecords = sideRecords;
            return result;
        }
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
            }, dryRun, metrics);
        // Every valid compiled job emits at least one terminal event, so entering
        // publication is part of completing a root.
        if (!entered) throw new Exception("compiled job produced no terminal decision");
        publication.complete();
        result.dispatchRecord = dispatchRecord;
        return result;
    } catch (Throwable error) {
        // #400: a single non-UTF-8/binary file anywhere in a directory batch
        // used to cancel every other queued/in-flight file -- `publication`
        // enforces strict input-order publication, so any throw here
        // (regardless of how BoundedInput's own isFatal delegate would have
        // classified it) previously called `publication.fail(ordinal)`
        // unconditionally, which stops every later-ordinal file's own
        // `publication.enter`/`fail` with `OrderedPublicationCanceled`. Fold
        // an invalid-UTF-8 root into the same per-document quarantine outcome
        // "no extractable content" already uses (a terminal decision
        // returned normally, not an exceptional one) so publication order
        // advances past it exactly as it would past any other quarantined
        // document, and the rest of a directory batch completes. A
        // single-file (non-directory-batch) invocation keeps today's fatal
        // exit-code behavior; only its message reasoning is available via
        // `invalidEncodingReason` if ever needed here too.
        if (inputIsDir && isInvalidEncodingFailure(error)) {
            if (!entered) {
                publication.enter(ordinal);
                entered = true;
            }
            publication.complete();
            LocalJobOutcome outcome;
            outcome.quarantined = 1;
            outcome.firstReason = invalidEncodingReason(error);
            return outcome;
        }
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
    private CoordinationMetricsV2 metrics;

    this(CoordinationMetricsV2 metrics = null) {
        this.metrics = metrics;
        mutex = new Mutex;
        changed = new Condition(mutex);
    }

    void enter(size_t ordinal) {
        auto started = beginCoordinationMetricV2(metrics);
        scope(exit) if (metrics !is null)
            metrics.record(CoordinationPhaseV2.orderedResultWait, 0, started);
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
        auto started = beginCoordinationMetricV2(metrics);
        scope(exit) if (metrics !is null)
            metrics.record(CoordinationPhaseV2.orderedResultWait, 0, started);
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

unittest {
    import core.sync.semaphore : Semaphore;
    import core.thread : Thread;
    import core.time : msecs;
    import std.exception : assertThrown;

    auto order = new PublicationOrder;
    auto laterStarted = new Semaphore(0);
    auto laterFinished = new Semaphore(0);
    Throwable laterError;
    auto later = new Thread({
        laterStarted.notify();
        try order.fail(1);
        catch (Throwable error) { laterError = error; }
        laterFinished.notify();
    });
    later.start();
    laterStarted.wait();
    assert(!laterFinished.wait(50.msecs),
        "later canonical failure did not wait for the earlier root");
    order.enter(0);
    order.complete();
    assert(laterFinished.wait(500.msecs));
    later.join();
    assert(laterError is null);
    assertThrown!OrderedPublicationCanceled(order.enter(2));
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
                               bool inputIsDir, string sidecarPath = null) {
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
        if (sidecarPath.length && (pathsOverlap(resolved, sidecarPath) ||
                sameFile(candidate, sidecarPath)))
            throw new Exception(
                "manifest and companions must be outside sidecar output");
        if (exists(candidate)) {
            // A hard link to any tree member would be expensive to discover;
            // reject every multiply linked DB/companion instead.
            stat_t info;
            if (stat(candidate.toStringz, &info) != 0 || info.st_nlink != 1)
                throw new Exception("manifest companion has a hard-link alias");
        }
    }
}

private final class CoordinationMetricsPathConflict : Exception {
    this() {
        super("coordination metrics path conflicts with another artifact route");
    }
}

private bool pathsOverlap(string left, string right) {
    return pathIsWithin(left, right) || pathIsWithin(right, left);
}

private string preflightCoordinationMetrics(string path, string inputPath,
        string outputPath, bool inputIsDir, string configPath,
        string manifestPath, string errorJournalPath) {
    bool link;
    try link = isSymlink(path);
    catch (FileException failure) { if (exists(path)) throw failure; }
    if (link || exists(path))
        throw new Exception("coordination metrics destination must not exist");
    auto resolved = resolveExistingPrefix(path);
    if ((inputIsDir && pathIsWithin(resolved, inputPath)) ||
        (!inputIsDir && resolved == inputPath) ||
        pathsOverlap(resolved, outputPath))
        throw new CoordinationMetricsPathConflict;
    foreach (protectedPath; [configPath, manifestPath, errorJournalPath])
        if (protectedPath.length) foreach (candidate;
                protectedPath == configPath ? [protectedPath] :
                [protectedPath, protectedPath ~ "-wal", protectedPath ~ "-shm"])
            if (pathsOverlap(resolved, resolveExistingPrefix(candidate)))
                throw new CoordinationMetricsPathConflict;
    return resolved;
}

private void publishCoordinationMetrics(string path, string text) {
    auto destination = File(path, "wx");
    destination.write(text);
    destination.close();
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
    string[] sideOutputRecords;
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
    private void failureAt(string databasePath, string phase, string file,
            size_t eventOrdinal = size_t.max) {
        auto markers = [databasePath ~ ".fault-" ~ phase];
        if (eventOrdinal != size_t.max)
            markers = [databasePath ~ ".fault-" ~ phase ~ "-" ~
                eventOrdinal.to!string] ~ markers;
        foreach (marker; markers)
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
        bool targeted, bool requireRuntimeEvidence, bool allowVerifiedSkip,
        string sidecarRoot = null, SideOutputSink sideOutputSink = null) {
    auto relative = inputIsDir ? relativePath(file, inputRoot) : ".";
    auto document = Document(SourceLocator("local-files:v1", inputRoot, relative),
        OutputName(inputIsDir ? relative : baseName(outputRoot)));
    auto selectedRoot = inputIsDir ? outputRoot : dirName(outputRoot);
    DurableRootKey rootKey;
    LocalJobOutcome outcome;
    bool allEventsPreviouslyTerminal = true;
    bool verifiedSkip;
    string dispatchRecord;
    string[] sideOutputRecords;
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
            Content[] planContents;
            string[] planSideSchemas;
            string[] planSideKeys;
            bool[string] destinations;
            TerminalSideOutput[size_t] sideOutputsByOrdinal;
            foreach (ref event; events) {
                DurableEventPlan plan;
                plan.ordinal = plans.length;
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
                        derivedSink(plan.kind, plan.document, plan.ordinal);
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
                    plan.sink = derivedSink(plan.kind, plan.document,
                        plan.ordinal);
                }
                plans ~= plan;
                planContents ~= event.kind == EventKind.emitted
                    ? event.payload.content : null;
                planSideSchemas ~= null;
                planSideKeys ~= null;
                if (event.kind == EventKind.emitted) {
                    foreach (ref output; event.sideOutputs) {
                        DurableEventPlan side;
                        side.ordinal = plans.length;
                        side.kind = "emitted";
                        side.document = event.payload.document.id;
                        side.outputName = event.payload.document.outputName.text ~
                            output.suffix;
                        side.hasOutput = true;
                        side.destination = sidecarDestinationFor(sidecarRoot,
                            inputIsDir, event, output);
                        side.outputSha256 = output.digest;
                        side.sink = "side-output:" ~ output.key;
                        try preflightDestination(side.destination,
                            inputIsDir ? sidecarRoot : dirName(sidecarRoot));
                        catch (Exception failure) {
                            throw new DurableDocumentFailure(rootKey, "failure",
                                "policy-failed", side.sink, failure, true);
                        }
                        try requireUnaliasedFileOrAbsent(side.destination,
                            side.sink);
                        catch (Exception failure) {
                            throw new DurableDocumentFailure(rootKey, "failure",
                                "policy-failed", side.sink, failure, true);
                        }
                        auto normalized = normalizedAbsolute(side.destination);
                        if (normalized in destinations)
                            throw new OutputPolicyViolation(
                                "primary and side-output destinations collide");
                        destinations[normalized] = true;
                        sideOutputsByOrdinal[side.ordinal] = output;
                        plans ~= side;
                        planContents ~= new Content([
                            ContentPiece.own(output.bytes)]);
                        planSideSchemas ~= output.schema;
                        planSideKeys ~= output.key;
                    }
                }
            }
            try ledger.planEvents(rootKey, plans);
            catch (Exception failure) {
                throw new DurableDocumentFailure(rootKey, "failure",
                    "manifest-failed", plans.length ? plans[0].sink :
                        derivedSink("root", rootKey.document, 0), failure, true);
            }
            version (ManifestCliHarness) manifestKillAt(databasePath, "after-event-plan");
            DurableDocumentFailure firstSinkFailure;
            foreach (ordinal, ref plan; plans) {
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
                            plan.sink, decision);
                    throw new DurableDocumentFailure(rootKey, "failure",
                        cast(ResourceExhaustion)decision !is null ?
                            "resource-failed" : "inspect-invalidated",
                        plan.sink, decision, true);
                }
                if (action == DurableAction.skip) {
                    if (planSideSchemas[ordinal].length)
                        sideOutputRecords ~= ("EXPLAIN\tside_output_status=verified" ~
                            "\tdocument_id=" ~ plan.document.text ~
                            "\tschema=" ~ planSideSchemas[ordinal] ~
                            "\tsink_key=" ~ planSideKeys[ordinal] ~
                            "\tdigest=" ~ toHexString!(LetterCase.lower)(
                                plan.outputSha256)).idup;
                    continue;
                }
                bool touched;
                string activePhase = "policy";
                try {
                    auto activeRoot = plan.sink.startsWith("side-output:")
                        ? (inputIsDir ? sidecarRoot : dirName(sidecarRoot))
                        : selectedRoot;
                    ensurePlainDirectory(activeRoot,
                        dirName(plan.destination));
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
                            symlink(file, plan.destination);
                        }
                    }
                    version (FailurePolicyHarness)
                        failureAt(databasePath, "sink", file, ordinal);
                    {
                        auto publicationStarted = beginDurableMetricV1();
                        scope(exit) recordDurableMetricV1(
                            DurableMetricPhaseV1.publication,
                            planContents[ordinal].size, publicationStarted);
                        if (auto sideOutput = ordinal in sideOutputsByOrdinal)
                            sideOutputSink.publish(*sideOutput, plan.destination);
                        else
                            writeAtomicPieces(plan.destination,
                                planContents[ordinal].pieces());
                    }
                    version (ManifestCliHarness) manifestKillAt(databasePath,
                        ordinal == 0 ? "after-first-publish" : "after-last-output");
                    version (ManifestCliHarness) if (ordinal == 1)
                        manifestKillAt(databasePath, "after-second-publish");
                    version (ManifestCliHarness) manifestKillAt(databasePath,
                        "after-publish");
                    ledger.commitPublished(rootKey, ordinal);
                    if (planSideSchemas[ordinal].length)
                        sideOutputRecords ~= ("EXPLAIN\tside_output_status=" ~
                            (retry ? "retried" : "published") ~
                            "\tdocument_id=" ~ plan.document.text ~
                            "\tschema=" ~ planSideSchemas[ordinal] ~
                            "\tsink_key=" ~ planSideKeys[ordinal] ~
                            "\tdigest=" ~ toHexString!(LetterCase.lower)(
                                plan.outputSha256)).idup;
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
                    catch (Exception ledgerFailure) {
                        throw new DurableDocumentFailure(rootKey, "failure",
                            "manifest-failed", plan.sink,
                            ledgerFailure, true);
                    }
                    if (phase == "policy" || phase == "resource")
                        throw new DurableDocumentFailure(rootKey,
                            touched ? "uncertain" : "failed", code,
                            plan.sink, failure, true);
                    if (firstSinkFailure is null)
                        firstSinkFailure = new DurableDocumentFailure(rootKey,
                            touched ? "uncertain" : "failed", code,
                            plan.sink, failure);
                }
            }
            if (firstSinkFailure !is null) throw firstSinkFailure;
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
    result.sideOutputRecords = sideOutputRecords;
    return result;
}

// Saturates at 0 rather than wrapping: `terminalDecisions` counting past
// `succeeded` is unreachable in runApp today (#387 traced every call site),
// but this is a display value, not a safety-critical invariant -- if that
// ever changes, printing "0 succeeded" is a safe degradation, not a garbage
// size_t wraparound.
private size_t succeededDisplayCount(size_t succeeded, size_t terminalDecisions) pure nothrow @nogc {
    return terminalDecisions <= succeeded ? succeeded - terminalDecisions : 0;
}

unittest {
    assert(succeededDisplayCount(5, 2) == 3);
    assert(succeededDisplayCount(3, 0) == 3);
    assert(succeededDisplayCount(2, 5) == 0, "must saturate, not wrap");
    assert(succeededDisplayCount(0, 0) == 0);
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
    string sidecarPath;
    string jsonlFields, datasetNamespace, sourceKey;
    size_t maxJsonlLineBytes, maxJsonlOutputBytes;
    ulong maxJsonlSidecarBytes = 64UL * 1024 * 1024;
    const filtersExplicit = args.canFindOption("--filters");
    const descriptorsExplicit = args.canFindOption("--max-open-inputs");
    const fieldsExplicit = args.canFindOption("--jsonl-fields");
    const namespaceExplicit = args.canFindOption("--dataset-namespace");
    const sourceExplicit = args.canFindOption("--source-key");
    const lineCapExplicit = args.canFindOption("--max-jsonl-line-bytes");
    const outputCapExplicit = args.canFindOption("--max-jsonl-output-bytes");
    const sidecarCapExplicit = args.canFindOption(
        "--max-jsonl-sidecar-bytes");
    const manifestExplicit = args.canFindOption("--manifest");
    const errorJournalExplicit = args.canFindOption("--error-journal");
    const sidecarExplicit = args.canFindOption("--sidecar-output");
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
        "sidecar-output", "Generic terminal side-output file or mirrored tree root", &sidecarPath,
        "jsonl-fields", "Comma-separated selected JSONL text fields", &jsonlFields,
        "dataset-namespace", "Stable JSONL dataset namespace", &datasetNamespace,
        "source-key", "Stable JSONL source key", &sourceKey,
        "max-jsonl-line-bytes", "Maximum input JSONL record bytes", &maxJsonlLineBytes,
        "max-jsonl-output-bytes", "Maximum output JSONL record bytes including LF", &maxJsonlOutputBytes,
        "max-jsonl-sidecar-bytes", "Maximum aggregate terminal side-output JSONL bytes", &maxJsonlSidecarBytes);
    if (helpInfo.helpWanted) {
        defaultGetoptPrinter("scrubbed", helpInfo.options);
        return 0;
    }
    const jsonlOptions = fieldsExplicit || namespaceExplicit || sourceExplicit ||
        lineCapExplicit || outputCapExplicit || sidecarCapExplicit;
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
        if (!maxJsonlSidecarBytes || maxJsonlSidecarBytes > size_t.max)
            throw new Exception("JSONL sidecar byte cap is out of range");
        if (sidecarCapExplicit && !sidecarExplicit)
            throw new Exception(
                "--max-jsonl-sidecar-bytes requires --sidecar-output");
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
        const producesSideOutput = runtimePlan.producesTerminalSideOutput;
        if (producesSideOutput != sidecarExplicit)
            throw new Exception(producesSideOutput ?
                "side-output-producing plan requires --sidecar-output" :
                "--sidecar-output requires a side-output-producing plan");
        if (sidecarExplicit) {
            if (!sidecarPath.length || sidecarPath == "-")
                throw new Exception(
                    "JSONL --sidecar-output must name a distinct file");
            if (exists(sidecarPath) && isSymlink(sidecarPath))
                throw new Exception("refusing symlink sidecar output path");
            rejectUnresolvableAncestorLinks(sidecarPath);
            sidecarPath = resolveExistingPrefix(sidecarPath);
            preflightOutput(sidecarPath, false);
            requireUnaliasedFileOrAbsent(sidecarPath,
                "JSONL sidecar destination");
            if (configPath.length && (sidecarPath ==
                    resolveExistingPrefix(configPath) ||
                    sameFile(sidecarPath, configPath)))
                throw new Exception(
                    "JSONL sidecar destination aliases configuration");
        }
        if (explain && !runtimePlan.isDispatch)
            throw new Exception("--explain is unavailable for v3 JSONL mode");
        if (validateOnly) {
            stderr.writeln("valid JSONL invocation; no stdin read.");
            return 0;
        }
        string[] pendingDispatchRecords;
        TerminalSideOutput[] pendingSideOutputs;
        SideOutputSink sideWriter;
        if (sidecarExplicit)
            sideWriter = new JsonlSidecarWriter(sidecarPath,
                maxJsonlOutputBytes, maxJsonlSidecarBytes, dryRun);
        scope(failure) if (sideWriter !is null) sideWriter.abort();
        size_t completed;
        size_t committedPrimary;
        try {
            completed = processStandardJsonlDocuments(datasetNamespace,
                sourceKey, fields,
                (string field, string text, SourceLocator source,
                        size_t selectedOrdinal) {
                    auto result = runJsonlFieldOutcome(source, field, text,
                        runtimePlan,
                        (ref RuntimeExecutionV1 execution) {
                            if (explain && execution.hasDispatch)
                                pendingDispatchRecords ~=
                                    canonicalJsonlDispatchRecordV1(
                                        execution.dispatch, selectedOrdinal);
                        });
                    pendingSideOutputs ~= result.sideOutputs;
                    return result.text;
                },
                JsonlLimits(maxJsonlLineBytes, maxJsonlOutputBytes), dryRun,
                (SourceLocator committed) {
                    ++committedPrimary;
                    if (sideWriter !is null)
                        foreach (ref output; pendingSideOutputs)
                            sideWriter.publish(output, null);
                    if (explain) foreach (ref output; pendingSideOutputs)
                        stderr.writeln("EXPLAIN\tside_output_status=",
                            dryRun ? "dry-run" : "staged",
                            "\tdocument_id=", DocumentId.from(committed).text,
                            "\tschema=", output.schema,
                            "\tsink_key=", output.key,
                            "\tdigest=", toHexString!(LetterCase.lower)(
                                output.digest));
                    pendingSideOutputs = null;
                    foreach (record; pendingDispatchRecords)
                        stderr.writeln("EXPLAIN\t", record);
                    pendingDispatchRecords = null;
                });
            if (sideWriter !is null) sideWriter.commit();
            stderr.writeln("JSONL done. ", completed, " records processed", dryRun ? "; dry-run, no stdout." : ".");
            return 0;
        } catch (JsonlFailure error) {
            if (sideWriter !is null) sideWriter.abort();
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
        } catch (Exception error) {
            if (sideWriter !is null) sideWriter.abort();
            stderr.writefln("JSONL side output failed after %s primary records fully flushed; side destination not committed",
                committedPrimary);
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
    auto coordinationPath =
        environment.get("SCRUBBED_COORDINATION_METRICS_V2", "");
    if (coordinationPath.length && durableRoute)
        throw new Exception(
            "coordination metrics are unavailable with durable routes");
    auto runtimePlan = selectedRuntimePlan(compositionTokens, filtersExplicit,
        filterList, configPath.length != 0, configContents, versionedConfig);
    const producesSideOutput = runtimePlan.producesTerminalSideOutput;
    if (producesSideOutput != sidecarExplicit)
        throw new Exception(producesSideOutput ?
            "side-output-producing plan requires --sidecar-output" :
            "--sidecar-output requires a side-output-producing plan");
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
    if (sidecarExplicit) {
        preflightSidecarRoots(inputPath, outputPath, sidecarPath, inputIsDir);
        sidecarPath = resolveExistingPrefix(sidecarPath);
    }
    if (!errorTargeted) preflightOutput(outputPath, inputIsDir);
    if (manifestPath.length) {
        manifestPath = resolveExistingPrefix(manifestPath);
        preflightManifest(manifestPath, inputPath, outputPath, inputIsDir,
            sidecarPath);
    }
    if (errorJournalPath.length) {
        errorJournalPath = resolveExistingPrefix(errorJournalPath);
        preflightManifest(errorJournalPath, inputPath, outputPath, inputIsDir,
            sidecarPath);
    }
    if (validateOnly) {
        auto executable = runningExecutableDigest();
        auto durableDigest = deriveDurableIdentity(canonicalSpec,
            runtimePlan.identity, inputIsDir ? "tree" : "file",
            durableOutputIdentity(outputPath, sidecarPath), executable);
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
    if (coordinationPath.length)
        coordinationPath = preflightCoordinationMetrics(coordinationPath,
            inputPath, outputPath, inputIsDir, configPath, manifestPath,
            errorJournalPath);
    ubyte[32] executable, configHash;
    {
        auto identityStarted = beginDurableMetricV1();
        scope(exit) if (durableRoute)
            recordDurableMetricV1(DurableMetricPhaseV1.identity, 0,
                identityStarted);
        executable = runningExecutableDigest();
        configHash = deriveDurableIdentity(canonicalSpec,
            runtimePlan.identity, inputIsDir ? "tree" : "file",
            durableOutputIdentity(outputPath, sidecarPath), executable);
    }
    DurableJobLedger durableLedger;
    if (durableRoute)
        durableLedger = new DurableJobLedger(
            manifestPath.length ? manifestPath : errorJournalPath,
            manifestPath.length ? DurableKind.manifest : DurableKind.journal,
            DurableIdentity(configHash, runtimePlan.identity));
    scope(exit) if (durableLedger !is null) durableLedger.close();
    // The tree-mirrored sidecar route and both durable-ledger side-output
    // routes (manifest and error-journal) all select a destination via
    // sidecarDestinationFor() and publish it as an atomic file replace; one
    // stateless MirroredFileSideOutputSink instance serves all of them.
    SideOutputSink sideOutputSink = sidecarPath.length ?
        new MirroredFileSideOutputSink : null;
    if (!dryRun && !errorTargeted)
        ensurePlainDirectory(inputIsDir ? outputPath : dirName(outputPath),
            inputIsDir ? outputPath : dirName(outputPath));
    if (sidecarPath.length && !dryRun && !errorTargeted)
        ensurePlainDirectory(inputIsDir ? sidecarPath : dirName(sidecarPath),
            inputIsDir ? sidecarPath : dirName(sidecarPath));
    auto pending = explain ? new PendingExplanations : null;
    auto coordination = coordinationPath.length ? new CoordinationMetricsV2 : null;
    scope(exit) if (coordination !is null) {
        coordination.finishWall();
        publishCoordinationMetrics(coordinationPath, coordination.json() ~ "\n");
    }
    auto publication = durableRoute ? null : new PublicationOrder(coordination);
    auto decisionMutex = new Mutex;
    size_t terminalDecisions;
    // #401: counts, by reason string, of every document that lands in
    // `quarantined` (not `rejected`/`failed`) so the plain (non---explain)
    // summary below can name *why* without printing one line per file. See
    // the comment at the print site for the reasoning behind this shape.
    size_t[string] quarantineReasonCounts;
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
                    errorTargeted, explain &&
                        (runtimePlan.isDispatch || sidecarPath.length),
                    allowVerifiedSkip, sidecarPath, sideOutputSink);
            } else {
                auto local = processCompiledOne(file, inputPath, outputPath,
                    inputIsDir, runtimePlan, bytes, dryRun, publication,
                    coordination, sidecarPath, sideOutputSink);
                decision.status = local.status;
                decision.detail = local.firstReason;
                decision.terminal = local.rejected != 0 || local.quarantined != 0;
                decision.dispatchRecord = local.dispatchRecord;
                decision.sideOutputRecords = local.sideOutputRecords;
            }
            if (decision.terminal) {
                decisionMutex.lock();
                ++terminalDecisions;
                if (decision.status == "quarantined") {
                    auto reason = decision.detail.length ?
                        decision.detail : "unknown";
                    // Aggregate by category, not by the raw detail string:
                    // some stages (e.g. html-metadata's decode failures,
                    // `decode:binaryControl@25`) embed a document-specific
                    // byte offset in `decision.detail`, which would
                    // otherwise give every document its own map entry and
                    // defeat this roll-up. `decision.detail` itself is
                    // untouched -- `--explain`'s output still prints it in
                    // full, offset included.
                    auto category = quarantineReasonCategory(reason);
                    if (auto existing = category in quarantineReasonCounts)
                        ++(*existing);
                    else quarantineReasonCounts[category] = 1;
                }
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
            if (explain) foreach (record; decision.sideOutputRecords)
                writeln(record);
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
        }, coordination);
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
            if (!durableRoute) {
                auto ordinalStarted = beginCoordinationMetricV2(coordination);
                scope(exit) if (coordination !is null)
                    coordination.record(CoordinationPhaseV2.ordinalAssignment,
                        1, ordinalStarted);
                publication.assign(file);
            }
            ulong bytes;
            {
                auto statStarted = beginDurableMetricV1();
                scope(exit) if (durableRoute)
                    recordDurableMetricV1(DurableMetricPhaseV1.sourceStat,
                        0, statStarted);
                auto coordinationStatStarted =
                    beginCoordinationMetricV2(coordination);
                scope(exit) if (coordination !is null)
                    coordination.record(CoordinationPhaseV2.sourceStat, 1,
                        coordinationStatStarted);
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
        auto discoveryStarted = beginCoordinationMetricV2(coordination);
        auto entries = dirEntries(directory, SpanMode.shallow, false).array;
        auto orderKey = (ref typeof(entries[0]) entry) {
            auto relative = relativePath(entry.name, inputPath);
            return !entry.isSymlink && entry.isDir ?
                relative ~ dirSeparator : relative;
        };
        sort!((left, right) => orderKey(left) < orderKey(right))(entries);
        if (coordination !is null)
            coordination.record(CoordinationPhaseV2.discovery,
                entries.length, discoveryStarted);
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
    // counts.succeeded (from BoundedInput) counts every document whose worker
    // callback returned without throwing, which includes terminal
    // (quarantine/reject) decisions -- those aren't exceptional at that
    // layer. Subtract terminalDecisions here, at the reporting layer only,
    // so the printed message agrees with the exit code below rather than
    // claiming unqualified success for documents that were quarantined.
    const displaySucceeded = succeededDisplayCount(counts.succeeded, terminalDecisions);
    if (!errorJournalPath.length) {
        if (terminalDecisions)
            writeln("done. ", displaySucceeded, " succeeded, ", failures,
                " failed, ", terminalDecisions, " quarantined.");
        else
            writeln("done. ", displaySucceeded, " succeeded, ", failures, " failed.");
        // #401: a plain (non---explain) invocation -- which is the *only*
        // form sealed presets like `clean-web-document` can ever run, since
        // their documented contract forbids adding a `--stage`/`--filter`/
        // `--explain`-style override flag -- previously gave zero
        // explanation for a quarantined document: "1 quarantined." and
        // nothing else. The actual reason was already tracked internally
        // (`local.firstReason`, threaded through as `decision.detail` above)
        // and was the same string `--explain`'s own
        // `EXPLAIN ... reason="..."` line prints; it just never reached this
        // default output path. Surface it here, by default, with no new
        // flag required.
        //
        // Deliberately an aggregated reason -> count roll-up rather than one
        // line per quarantined file: `done.` is a deliberately terse,
        // O(1)-output summary line even for directory trees with thousands
        // of inputs, and a plain per-file listing here would both blow that
        // budget out and duplicate what `--explain`'s per-file EXPLAIN
        // records already do for anyone who needs that detail. Counting by
        // reason *category* (see `quarantineReasonCategory`; this strips
        // any volatile per-document `@<offset>` suffix a stage's detail
        // string may carry) stays small while still naming the concrete,
        // actionable cause -- e.g. "abstainedBelowThreshold" -- for the
        // common single- or few-document case the sealed preset's own Quick
        // Start targets, without requiring the reader to already know
        // `--explain` exists or how to hand-reconstruct the preset's stage
        // chain to reach it. Gated on `!explain` so `--explain`'s existing,
        // already-more-detailed output is completely unchanged.
        if (!explain && quarantineReasonCounts.length)
            writeln("quarantined reasons: ",
                formatQuarantineReasonCounts(quarantineReasonCounts));
    }
    return failures == 0 && terminalDecisions == 0 ? 0 : 1;
}

/// Collapses a quarantine `decision.detail` string to a stable category
/// for the `quarantined reasons:` roll-up, by stripping a trailing
/// `@<offset>` suffix when present (e.g. html-metadata's decode failures,
/// `decode:binaryControl@25` -> `decode:binaryControl`). Detail strings
/// with no such suffix, and everything used for `--explain`'s own output,
/// are returned unchanged -- this only affects the roll-up's aggregation
/// key.
private string quarantineReasonCategory(string detail) pure {
    auto at = detail.lastIndexOf('@');
    if (at < 0) return detail;
    auto suffix = detail[at + 1 .. $];
    if (suffix.length == 0) return detail;
    foreach (c; suffix)
        if (c < '0' || c > '9') return detail;
    return detail[0 .. at];
}

unittest {
    assert(quarantineReasonCategory("abstainedBelowThreshold") ==
        "abstainedBelowThreshold");
    assert(quarantineReasonCategory("decode:binaryControl@25") ==
        "decode:binaryControl");
    assert(quarantineReasonCategory("decode:binaryControl@0") ==
        "decode:binaryControl");
    // No digits after '@', or '@' embedded in something else entirely:
    // leave it alone rather than guess.
    assert(quarantineReasonCategory("weird@reason") == "weird@reason");
    assert(quarantineReasonCategory("trailing@") == "trailing@");
    assert(quarantineReasonCategory("no-at-sign") == "no-at-sign");
    assert(quarantineReasonCategory("") == "");
}

/// Deterministic (sorted by reason string) rendering of a quarantine
/// reason -> count roll-up, e.g. `abstainedBelowThreshold (3), decode-failed (1)`.
private string formatQuarantineReasonCounts(size_t[string] counts) {
    auto reasons = counts.keys;
    reasons.sort();
    string rendered;
    foreach (index, reason; reasons) {
        if (index) rendered ~= ", ";
        rendered ~= reason ~ " (" ~ counts[reason].to!string ~ ")";
    }
    return rendered;
}

unittest {
    size_t[string] counts;
    assert(formatQuarantineReasonCounts(counts) == "");
    counts["abstainedBelowThreshold"] = 1;
    assert(formatQuarantineReasonCounts(counts) == "abstainedBelowThreshold (1)");
    counts["decode-failed"] = 2;
    assert(formatQuarantineReasonCounts(counts) ==
        "abstainedBelowThreshold (1), decode-failed (2)");
}

unittest {
    import std.exception : assertThrown;
    import std.file : read, rmdirRecurse, tempDir;

    auto root = buildPath(tempDir, "scrubbed-cli-" ~ randomUUID.toString);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    mkdir(root);
    assert(runApp(["scrubbed"]) == 2);

    auto same = buildPath(root, "same.txt");
    write(same, "already clean");
    assert(runApp(["scrubbed", "run", "--input", same, "--output", same,
        "--filters", "fix-mojibake", "--threads", "1"]) == 0);
    assert(readText(same) == "already clean");

    // #381 regression: a trivially short/thin document (the issue's own
    // `printf '<p>hi</p>'` repro) is correctly quarantined by
    // html-main-content ("no extractable content") -- a terminal decision,
    // not a throw, so BoundedInput's worker still counts it toward
    // `counts.succeeded`. Before the fix, the printed "done." message
    // reported only `counts.succeeded`/`counts.failed` ("1 succeeded, 0
    // failed") while the exit code additionally gated on
    // `terminalDecisions`, so a success-sounding message accompanied a
    // nonzero exit and no output was written. The message and the exit
    // code must agree.
    {
        import job.presets : cleanWebDocumentTokensV1;

        auto thin = buildPath(root, "tiny.html");
        write(thin, "<p>hi</p>");
        auto thinOut = buildPath(root, "tiny-out.txt");
        auto thinSidecar = thinOut ~ ".document-metadata.json";
        auto invocation = invokeJsonl(["scrubbed", "run", "--input", thin,
            "--output", thinOut, "--sidecar-output", thinSidecar,
            "--threads", "1"] ~ cleanWebDocumentTokensV1, []);
        auto message = cast(string) invocation.stdoutBytes;
        assert(invocation.code == 1,
            "quarantined-only run must exit nonzero: " ~ message);
        assert(!message.canFind("1 succeeded"),
            "message must not claim success for a quarantined document: " ~
            message);
        assert(message.canFind("quarantined"),
            "message must explain the nonzero exit: " ~ message);
        assert(!exists(thinOut),
            "quarantined document must not publish output");
        assert(!exists(thinSidecar),
            "quarantined document must not publish a metadata sidecar");

        // #401 regression: the sealed clean-web-document/v1 preset (and any
        // other plain, non---explain invocation, which is all a sealed
        // preset can ever run) must surface *why* a document quarantined,
        // by default, with no `--explain`/`--stage`/`--filter` flag -- the
        // preset's own documented contract forbids adding one. The reason
        // string here ("abstainedBelowThreshold") is exactly what
        // `--explain`'s `EXPLAIN ... reason="..."` line already prints for
        // this same input; this only checks it also reaches the default,
        // no-flags-needed output path.
        assert(message.canFind("quarantined reasons:"),
            "plain (non---explain) output must name the quarantine " ~
            "reason without requiring --explain: " ~ message);
        assert(message.canFind("abstainedBelowThreshold"),
            "plain output must include the actual internal reason " ~
            "string, not just the word \"quarantined\": " ~ message);
    }
    // #400 regression: a single non-UTF-8/binary file anywhere in a
    // directory batch used to print "FATAL <file>: ... Invalid UTF-8
    // sequence ..." for that file and then "CANCELED <other file>: ordered
    // publication canceled after an earlier fatal root" for every other
    // queued/in-flight file, aborting the whole batch with exit code 2 and
    // publishing nothing at all -- including files that had nothing wrong
    // with them. Invalid UTF-8 must instead become a per-document quarantine
    // outcome (like html-main-content's "no extractable content" above): the
    // rest of the batch completes and the valid file's output is written.
    {
        import job.presets : cleanWebDocumentTokensV1;

        auto mixedRoot = buildPath(root, "mixed-batch");
        mkdir(mixedRoot);
        // Not valid UTF-8: 0x80/0x81 are continuation bytes with no leading
        // byte, and 0xFF/0xFE never appear in well-formed UTF-8 at all.
        write(buildPath(mixedRoot, "bad.html"),
            cast(ubyte[])[0x00, 0x01, 0x02, 0xFF, 0xFE, 0x80, 0x81, 0x00]);
        write(buildPath(mixedRoot, "good.html"),
            "<p>a perfectly normal real page with enough content to " ~
            "survive main-content extraction thresholds and not get " ~
            "quarantined for being too thin, repeated so it clearly " ~
            "counts as real page text content here.</p>");
        auto mixedOut = buildPath(root, "mixed-out");
        auto mixedSidecar = buildPath(root, "mixed-sidecar");
        auto invocation = invokeJsonl(["scrubbed", "run", "--input", mixedRoot,
            "--output", mixedOut, "--sidecar-output", mixedSidecar,
            "--threads", "2", "--explain"] ~ cleanWebDocumentTokensV1, []);
        auto message = cast(string) invocation.stdoutBytes;
        assert(invocation.code == 1,
            "one bad file in a batch must fail that file only (exit 1), " ~
            "not abort the whole batch as fatal (exit 2): " ~ message ~
            invocation.stderrText);
        assert(!invocation.stderrText.canFind("FATAL"),
            "an invalid-UTF-8 file must not be reported as FATAL: " ~
            invocation.stderrText);
        assert(!invocation.stderrText.canFind("CANCELED"),
            "an invalid-UTF-8 file must not cancel the rest of the batch: " ~
            invocation.stderrText);
        assert(message.canFind("quarantined"),
            "message must explain the nonzero exit: " ~ message);
        assert(message.canFind(
            "reason=\"invalid encoding: input is not valid UTF-8"),
            "the quarantine reason must specifically identify invalid " ~
            "encoding, not a generic message: " ~ message);
        auto goodOut = buildPath(mixedOut, "good.html");
        assert(exists(goodOut),
            "the batch's other, valid file must still be published even " ~
            "though an earlier file in the same batch was invalid UTF-8");
        assert(readText(goodOut).canFind("perfectly normal"),
            "the valid file's published content must be intact");
        assert(!exists(buildPath(mixedOut, "bad.html")),
            "the quarantined invalid-UTF-8 file must not publish output");
    }
    // Regression for an independent review finding against #401: html-
    // metadata's decode failures embed a document-specific byte offset in
    // `decision.detail` (e.g. `decode:binaryControl@25`), so aggregating
    // the `quarantined reasons:` roll-up by the *exact* detail string gave
    // every differently-offset document its own map entry -- one line per
    // file for a real dirty-HTML corpus, defeating the entire point of the
    // roll-up (and the "stays small" claim in its own comment/docs). Three
    // files, each with one stray control byte (0x01) at a different offset,
    // must still aggregate into a single roll-up line.
    {
        import job.presets : cleanWebDocumentTokensV1;
        import std.array : replicate;

        auto offsetRoot = buildPath(root, "offset-batch");
        mkdir(offsetRoot);
        auto filler = "<html><body><p>" ~ replicate("x", 150) ~
            "</p></body></html>";
        foreach (i, offset; [25, 65, 105]) {
            ubyte[] bytes = cast(ubyte[]) filler.dup;
            bytes[offset] = 0x01;
            write(buildPath(offsetRoot, "doc" ~ i.to!string ~ ".html"), bytes);
        }
        auto offsetOut = buildPath(root, "offset-out");
        auto offsetSidecar = buildPath(root, "offset-sidecar");
        auto invocation = invokeJsonl(["scrubbed", "run", "--input", offsetRoot,
            "--output", offsetOut, "--sidecar-output", offsetSidecar,
            "--threads", "1"] ~ cleanWebDocumentTokensV1, []);
        auto message = cast(string) invocation.stdoutBytes;
        assert(invocation.code == 1,
            "all three offset-only files must quarantine: " ~ message);
        assert(message.canFind("3 quarantined"),
            "all three files must be counted as quarantined: " ~ message);
        assert(message.canFind("quarantined reasons: decode:binaryControl (3)"),
            "same-category reasons differing only by byte offset must " ~
            "aggregate into a single roll-up entry, not one per offset: " ~
            message);
        assert(!message.canFind("@25") && !message.canFind("@65") &&
            !message.canFind("@105"),
            "the roll-up must not leak the volatile per-document byte " ~
            "offset that defeats aggregation: " ~ message);
    }
    {
        // #402 regression: #400's quarantine path only recognized invalid UTF-8
        // by casting to `std.utf.UTFException` while walking the
        // `CompiledJobFailure`/`EffectFailure` wrapper chain. That is correct
        // for `clean-web-document`'s sealed preset, which always runs
        // text-transform (with fix-mojibake, the sole `UTFException` source)
        // first -- but a hand-composed `run --stage` pipeline can put a stage
        // that independently re-validates and rewraps UTF-8 (e.g.
        // `pii-four-class`, via `domain.pii_patterns.scanPii`) ahead of
        // text-transform. Before the fix, that rewrapped failure
        // (`domain.pii_patterns.InvalidUtf8ScanException`, previously
        // `PiiScanException`) failed the `UTFException` cast and fell back to
        // the pre-#400 FATAL/batch-canceling behavior for the whole directory
        // batch.
        auto reorderedRoot = buildPath(root, "reordered-batch");
        mkdir(reorderedRoot);
        // Same invalid-UTF-8 fixture as the #400 case above.
        write(buildPath(reorderedRoot, "bad.txt"),
            cast(ubyte[])[0x00, 0x01, 0x02, 0xFF, 0xFE, 0x80, 0x81, 0x00]);
        write(buildPath(reorderedRoot, "good.txt"),
            "a perfectly normal plain-text document with enough content " ~
            "to be an unremarkable, valid UTF-8 file for this batch.");
        auto reorderedOut = buildPath(root, "reordered-out");
        auto invocation = invokeJsonl(["scrubbed", "run", "--input",
            reorderedRoot, "--output", reorderedOut, "--threads", "2",
            "--explain",
            "--stage", "pii-four-class=pii-four-class",
            "--stage", "text-transform=text-transform",
            "--filter", "fix-mojibake"], []);
        auto message = cast(string) invocation.stdoutBytes;
        assert(invocation.code == 1,
            "a stage ahead of text-transform hitting invalid UTF-8 must " ~
            "fail that file only (exit 1), not abort the whole batch as " ~
            "fatal (exit 2): " ~ message ~ invocation.stderrText);
        assert(!invocation.stderrText.canFind("FATAL"),
            "an invalid-UTF-8 file must not be reported as FATAL " ~
            "regardless of which stage detects it: " ~
            invocation.stderrText);
        assert(!invocation.stderrText.canFind("CANCELED"),
            "an invalid-UTF-8 file rewrapped by a non-text-transform " ~
            "stage must not cancel the rest of the batch: " ~
            invocation.stderrText);
        assert(message.canFind("quarantined"),
            "message must explain the nonzero exit: " ~ message);
        assert(message.canFind(
            "reason=\"invalid encoding: input is not valid UTF-8"),
            "the quarantine reason must specifically identify invalid " ~
            "encoding even when pii-four-class (not text-transform) " ~
            "detected it: " ~ message);
        auto goodOut = buildPath(reorderedOut, "good.txt");
        assert(exists(goodOut),
            "the batch's other, valid file must still be published even " ~
            "though an earlier-ordinal file was invalid UTF-8");
        assert(readText(goodOut).canFind("perfectly normal"),
            "the valid file's published content must be intact");
        assert(!exists(buildPath(reorderedOut, "bad.txt")),
            "the quarantined invalid-UTF-8 file must not publish output");
    }
    {
        auto priorMetrics =
            environment.get("SCRUBBED_COORDINATION_METRICS_V2", "");
        scope(exit) {
            if (priorMetrics.length)
                environment["SCRUBBED_COORDINATION_METRICS_V2"] = priorMetrics;
            else environment.remove("SCRUBBED_COORDINATION_METRICS_V2");
        }
        auto separateOutput = buildPath(root, "metrics-collision-output.txt");
        environment["SCRUBBED_COORDINATION_METRICS_V2"] = same;
        assertThrown(runApp(["scrubbed", "run", "--input", same,
            "--output", separateOutput, "--filters", "fix-mojibake",
            "--threads", "1"]));
        assert(readText(same) == "already clean" && !exists(separateOutput));
        environment["SCRUBBED_COORDINATION_METRICS_V2"] = separateOutput;
        assertThrown(runApp(["scrubbed", "run", "--input", same,
            "--output", separateOutput, "--filters", "fix-mojibake",
            "--threads", "1"]));
        assert(readText(same) == "already clean" && !exists(separateOutput));
        auto metricsAncestor = buildPath(root, "metrics-ancestor");
        auto nestedOutput = buildPath(metricsAncestor, "output.txt");
        environment["SCRUBBED_COORDINATION_METRICS_V2"] = metricsAncestor;
        assertThrown!CoordinationMetricsPathConflict(runApp(["scrubbed",
            "run", "--input", same, "--output", nestedOutput, "--filters",
            "fix-mojibake", "--threads", "1"]));
        assert(readText(same) == "already clean" &&
            !exists(metricsAncestor) && !exists(nestedOutput));
        auto outputAncestor = buildPath(root, "output-ancestor.txt");
        auto nestedMetrics = buildPath(outputAncestor, "metrics.json");
        environment["SCRUBBED_COORDINATION_METRICS_V2"] = nestedMetrics;
        assertThrown!CoordinationMetricsPathConflict(runApp(["scrubbed",
            "run", "--input", same, "--output", outputAncestor, "--filters",
            "fix-mojibake", "--threads", "1"]));
        assert(readText(same) == "already clean" &&
            !exists(outputAncestor) && !exists(nestedMetrics));
        auto durableMetrics = buildPath(root, "durable-metrics.json");
        auto manifestOutput = buildPath(root, "metrics-manifest-output.txt");
        auto manifestStore = buildPath(root, "metrics-manifest.db");
        environment["SCRUBBED_COORDINATION_METRICS_V2"] = durableMetrics;
        assertThrown(runApp(["scrubbed", "run", "--input", same,
            "--output", manifestOutput, "--filters", "fix-mojibake",
            "--threads", "1", "--manifest", manifestStore]));
        assert(!exists(durableMetrics) && !exists(manifestOutput) &&
            !exists(manifestStore));
        auto journalOutput = buildPath(root, "metrics-journal-output.txt");
        auto journalStore = buildPath(root, "metrics-journal.db");
        createJournalV3(journalStore);
        auto journalBefore = read(journalStore);
        assertThrown(runApp(["scrubbed", "run", "--input", same,
            "--output", journalOutput, "--filters", "fix-mojibake",
            "--threads", "1", "--error-journal", journalStore]));
        assert(!exists(durableMetrics) && !exists(journalOutput) &&
            read(journalStore) == journalBefore &&
            !exists(journalStore ~ "-wal") && !exists(journalStore ~ "-shm"));
        auto metricsPath = buildPath(root, "coordination-metrics.json");
        environment["SCRUBBED_COORDINATION_METRICS_V2"] = metricsPath;
        assert(runApp(["scrubbed", "run", "--input", same,
            "--output", separateOutput, "--filters", "fix-mojibake",
            "--threads", "1"]) == 0);
        assert(parseJSON(readText(metricsPath))["schema"].str ==
            "scrubbed.coordination-metrics.v2");
        auto racedMetricsPath = buildPath(root,
            "coordination-metrics-raced.json");
        write(racedMetricsPath, "sentinel");
        assertThrown(publishCoordinationMetrics(racedMetricsPath,
            `{"schema":"must-not-replace"}`));
        assert(readText(racedMetricsPath) == "sentinel");
    }

    auto empty = buildPath(root, "empty.txt");
    auto emptyOut = buildPath(root, "empty-out.txt");
    write(empty, "");
    assert(runApp(["scrubbed", "run", "--input", empty, "--output", emptyOut,
        "--threads", "1"]) == 0);
    assert(exists(emptyOut) && getSize(emptyOut) == 0);

    auto inputDir = buildPath(root, "input");
    mkdir(inputDir);
    assertThrown(runApp(["scrubbed", "run", "--input", inputDir,
        "--output", buildPath(inputDir, "out"), "--threads", "1"]));
    assertThrown(runApp(["scrubbed", "run", "--input", same, "--output", emptyOut,
        "--config", "x.json", "--filters", "fix-mojibake"]));
    assertThrown(runApp(["scrubbed", "run", "--input", same, "--output", emptyOut,
        "--config", "x.json", "--FILTERS", "fix-mojibake"]));
    assertThrown(runApp(["scrubbed", "run", "--input", same, "--output", emptyOut,
        "--threads", "0"]));

    auto badConfig = buildPath(root, "bad.json");
    write(badConfig, `{ "filters": [{ "name": "fix-mojibake", ` ~
        `"options": { "max-pass": 0 } }] }`);
    assertThrown(runApp(["scrubbed", "run", "--input", same, "--output", emptyOut,
        "--config", badConfig, "--threads", "1"]));

    auto emptyConfig = buildPath(root, "empty-config.json");
    write(emptyConfig, "");
    write(emptyOut, "sentinel");
    assertThrown(runApp(["scrubbed", "run", "--input", same, "--output", emptyOut,
        "--config", emptyConfig, "--threads", "1"]));
    assert(readText(emptyOut) == "sentinel");

    auto invalidValueConfig = buildPath(root, "invalid-value.json");
    write(invalidValueConfig, `{ "filters": [{ "name": "fix-mojibake", ` ~
        `"options": { "max-passes": "bad" } }] }`);
    auto noFiles = buildPath(root, "no-files");
    auto noFilesOutput = buildPath(root, "no-files-output");
    mkdir(noFiles);
    assertThrown(runApp(["scrubbed", "run", "--input", noFiles,
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
    assert(runApp(["scrubbed", "run", "--input", configuredInput,
        "--output", configuredOutput, "--config", validConfig,
        "--threads", "1"]) == 0);
    assert(readText(configuredOutput) == `"schÃ¶n"`);

    auto blockedParent = buildPath(root, "not-a-directory");
    write(blockedParent, "x");
    assertThrown(runApp(["scrubbed", "run", "--input", same,
        "--output", buildPath(blockedParent, "out.txt"), "--threads", "1"]));

    auto invalidUtf8 = buildPath(root, "invalid-utf8.bin");
    write(invalidUtf8, [cast(ubyte) 0xFF]);
    assertThrown(runApp(["scrubbed", "run", "--input", invalidUtf8,
        "--output", buildPath(root, "invalid-output.txt"),
        "--threads", "1"]));

    auto sharedInput = buildPath(root, "shared-input", "nested");
    mkdirRecurse(sharedInput);
    foreach (index; 0 .. 64)
        write(buildPath(sharedInput, index.to!string ~ ".txt"), "clean");
    auto sharedOutput = buildPath(root, "shared-output");
    assert(runApp(["scrubbed", "run", "--input", dirName(sharedInput),
        "--output", sharedOutput, "--filters", "fix-mojibake",
        "--threads", "4", "--max-queued-docs", "1",
        "--max-input-bytes", "5", "--max-open-inputs", "1"]) == 0);
    foreach (index; 0 .. 64)
        assert(readText(buildPath(sharedOutput, "nested",
            index.to!string ~ ".txt")) == "clean");

    auto oversized = buildPath(root, "oversized.txt");
    write(oversized, "too large");
    auto oversizedOutput = buildPath(root, "oversized-output.txt");
    assertThrown(runApp(["scrubbed", "run", "--input", oversized,
        "--output", oversizedOutput, "--threads", "1",
        "--max-input-bytes", "2"]));
    assert(!exists(oversizedOutput));

    version (Posix) {
        import std.file : symlink;
        auto link = buildPath(root, "input-link");
        symlink(same, link);
        assertThrown(runApp(["scrubbed", "run", "--input", link,
            "--output", emptyOut, "--threads", "1"]));

        auto external = buildPath(root, "external.txt");
        auto outputLink = buildPath(root, "output-link.txt");
        write(external, "must survive");
        symlink(external, outputLink);
        assertThrown(runApp(["scrubbed", "run", "--input", same,
            "--output", outputLink, "--threads", "1"]));
        assert(readText(external) == "must survive");

        auto treeLink = buildPath(inputDir, "outside-link");
        symlink(external, treeLink);
        assertThrown(runApp(["scrubbed", "run", "--input", inputDir,
            "--output", buildPath(root, "tree-output"), "--threads", "1"]));
    }
}

// Regression for #294: the side-output publication loop above must not
// publish a side output for a quarantined/rejected event, only for an
// emitted one -- mirroring the primary-content-write gate immediately
// preceding it in the same loop. Exercised through the real `run` command
// (runApp), not a local test copy of the registry/executor.
unittest {
    import effects.html_tree : maxDepth;
    import std.file : rmdirRecurse, tempDir;

    auto root = buildPath(tempDir, "scrubbed-side-output-gate-" ~ randomUUID.toString);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    mkdir(root);

    // Negative case: a genuine HtmlTree depth-limit quarantine trigger (the
    // ticket's own cited repro). html-metadata's SideOutputCapability.terminal
    // registration requires composition.executor.validateCapabilities to
    // attach an empty-payload placeholder TerminalSideOutput to this
    // quarantined event; before the #294 fix, cli.d's unconditional
    // side-output loop published that placeholder as a spurious 0-byte
    // sidecar file on disk.
    {
        auto inputDir = buildPath(root, "in");
        auto outputDir = buildPath(root, "out");
        auto sidecarDir = buildPath(root, "sidecar");
        mkdir(inputDir);
        string deepBody;
        foreach (i; 0 .. maxDepth + 40) deepBody ~= "<div>";
        foreach (i; 0 .. maxDepth + 40) deepBody ~= "</div>";
        write(buildPath(inputDir, "depth.html"),
            "<html><head><title>Depth</title></head><body>" ~ deepBody ~
            "</body></html>");
        assert(runApp(["scrubbed", "run", "--input", inputDir, "--output", outputDir,
            "--stage", "id=html-metadata", "--sidecar-output", sidecarDir,
            "--threads", "1"]) == 1,
            "a quarantined document must report a nonzero terminal status");
        assert(!exists(buildPath(outputDir, "depth.html")),
            "a quarantined document must not publish primary content");
        assert(!exists(buildPath(sidecarDir, "depth.html.metadata.json")),
            "a quarantined document must not publish its placeholder side " ~
            "output as a spurious sidecar file (#294)");
    }

    // Positive case: an *emitted* html-metadata event's side output is
    // still published -- proves the #294 gate did not also suppress the
    // working path.
    {
        auto inputDir = buildPath(root, "in2");
        auto outputDir = buildPath(root, "out2");
        auto sidecarDir = buildPath(root, "sidecar2");
        mkdir(inputDir);
        string html = `<html><head><title>Emitted Case</title>` ~
            `<meta name="author" content="Ada"></head><body>` ~
            `<p>hello</p></body></html>`;
        write(buildPath(inputDir, "ok.html"), html);
        assert(runApp(["scrubbed", "run", "--input", inputDir, "--output", outputDir,
            "--stage", "id=html-metadata", "--sidecar-output", sidecarDir,
            "--threads", "1"]) == 0,
            "an emitted document must report success");
        assert(readText(buildPath(outputDir, "ok.html")) == html,
            "an emitted event's content must pass through unmodified");
        auto sidecarPath = buildPath(sidecarDir, "ok.html.metadata.json");
        assert(exists(sidecarPath),
            "an emitted event's side output must still be published " ~
            "(#294 regression check)");
        auto parsed = parseJSON(readText(sidecarPath));
        assert(parsed["version"].str == "metadata-json:v2");
        assert(parsed["fields"]["title"]["status"].str == "selected" &&
            parsed["fields"]["title"]["value"].str == "Emitted Case",
            "published side output must still carry real extracted metadata");
    }
}

// Regression for #334: processDurableOne's side-output plan-building loop
// (the --manifest/--error-journal durable route) has the same unconditional
// side-output-publication bug #294 fixed above in the plain local-write
// route (processCompiledOne) -- a separate loop, same root cause. Exercised
// through the real `run` command's --manifest route (runApp), not a local
// test copy of the registry/executor/ledger.
unittest {
    import effects.html_tree : maxDepth;
    import std.file : rmdirRecurse, tempDir;

    auto root = buildPath(tempDir,
        "scrubbed-durable-side-output-gate-" ~ randomUUID.toString);
    scope(exit) if (exists(root)) rmdirRecurse(root);
    mkdir(root);

    // Negative case: the same depth-limit quarantine trigger as the plain
    // route's #294 regression test above, this time driven through
    // --manifest so processDurableOne's plan-building loop is under test
    // instead of processCompiledOne's. Before the #334 fix, the placeholder
    // TerminalSideOutput attached to this quarantined event would be turned
    // into a spurious DurableEventPlan side-output entry, which the durable
    // publication loop then writes to disk as a 0-byte sidecar file.
    {
        auto inputDir = buildPath(root, "in");
        auto outputDir = buildPath(root, "out");
        auto sidecarDir = buildPath(root, "sidecar");
        auto manifestStore = buildPath(root, "quarantine-manifest.db");
        mkdir(inputDir);
        string deepBody;
        foreach (i; 0 .. maxDepth + 40) deepBody ~= "<div>";
        foreach (i; 0 .. maxDepth + 40) deepBody ~= "</div>";
        write(buildPath(inputDir, "depth.html"),
            "<html><head><title>Depth</title></head><body>" ~ deepBody ~
            "</body></html>");
        assert(runApp(["scrubbed", "run", "--input", inputDir, "--output", outputDir,
            "--stage", "id=html-metadata", "--sidecar-output", sidecarDir,
            "--manifest", manifestStore, "--threads", "1"]) == 1,
            "a quarantined document must report a nonzero terminal status");
        assert(!exists(buildPath(outputDir, "depth.html")),
            "a quarantined document must not publish primary content");
        assert(!exists(buildPath(sidecarDir, "depth.html.metadata.json")),
            "a quarantined document must not publish its placeholder side " ~
            "output as a spurious sidecar file via the durable route (#334)");
    }

    // Positive case: an *emitted* html-metadata event's side output is
    // still recorded and published through the durable route -- proves the
    // #334 gate did not also suppress the working path. A replay (the
    // manifest already records this root as completed) must still report
    // success and must not disturb the previously published side output.
    {
        auto inputDir = buildPath(root, "in2");
        auto outputDir = buildPath(root, "out2");
        auto sidecarDir = buildPath(root, "sidecar2");
        auto manifestStore = buildPath(root, "emitted-manifest.db");
        mkdir(inputDir);
        string html = `<html><head><title>Emitted Case</title>` ~
            `<meta name="author" content="Ada"></head><body>` ~
            `<p>hello</p></body></html>`;
        write(buildPath(inputDir, "ok.html"), html);
        assert(runApp(["scrubbed", "run", "--input", inputDir, "--output", outputDir,
            "--stage", "id=html-metadata", "--sidecar-output", sidecarDir,
            "--manifest", manifestStore, "--threads", "1"]) == 0,
            "an emitted document must report success");
        assert(readText(buildPath(outputDir, "ok.html")) == html,
            "an emitted event's content must pass through unmodified");
        auto sidecarPath = buildPath(sidecarDir, "ok.html.metadata.json");
        assert(exists(sidecarPath),
            "an emitted event's side output must still be published " ~
            "through the durable route (#334 regression check)");
        auto parsed = parseJSON(readText(sidecarPath));
        assert(parsed["version"].str == "metadata-json:v2");
        assert(parsed["fields"]["title"]["status"].str == "selected" &&
            parsed["fields"]["title"]["value"].str == "Emitted Case",
            "published side output must still carry real extracted metadata");

        assert(runApp(["scrubbed", "run", "--input", inputDir, "--output", outputDir,
            "--stage", "id=html-metadata", "--sidecar-output", sidecarDir,
            "--manifest", manifestStore, "--threads", "1"]) == 0,
            "a replayed emitted document must report success");
        assert(exists(sidecarPath),
            "replay must not remove the previously published side output");
    }
}

private void requireCli(bool condition, string message) {
    if (!condition) throw new Exception("CLI inspection test: " ~ message);
}

private struct JsonlInvocation {
    int code;
    ubyte[] stdoutBytes;
    string stderrText;
}

/// Drives the real `runApp` JSONL route (`--input -`/`--output -`) against
/// actual OS-level stdin/stdout/stderr file descriptors -- `effects.stdio_stream`
/// reads/writes those directly (`stdin.fileno`, `stdout.rawWrite`), so there
/// is no injectable File handle to mock in this path. This redirects fd
/// 0/1/2 to private pipes for the duration of the call, feeds `input` and
/// drains stdout/stderr on background daemon threads concurrently with
/// `runApp` running on its own thread, and restores the real fds before
/// returning. Running the read/write/execute concurrently on real pipes
/// (rather than e.g. an in-memory buffer swapped in ahead of time) means a
/// payload larger than the OS pipe buffer cannot complete unless the
/// implementation is genuinely streaming; a bounded wait below turns a
/// full-buffering deadlock into a clear test failure instead of hanging the
/// process.
private JsonlInvocation invokeJsonl(string[] args, const(ubyte)[] input) {
    import core.sync.semaphore : Semaphore;
    import core.thread : Thread;
    import core.time : seconds;
    import core.sys.posix.unistd : dup, dup2, pipe, posixWrite = write;
    import std.stdio : stdout;

    int[2] inPipe, outPipe, errPipe;
    enforce(pipe(inPipe) == 0, "failed to create JSONL test stdin pipe");
    enforce(pipe(outPipe) == 0, "failed to create JSONL test stdout pipe");
    enforce(pipe(errPipe) == 0, "failed to create JSONL test stderr pipe");

    stdout.flush();
    stderr.flush();
    auto savedIn = dup(0);
    auto savedOut = dup(1);
    auto savedErr = dup(2);
    enforce(savedIn >= 0 && savedOut >= 0 && savedErr >= 0,
        "failed to save real stdio file descriptors");

    dup2(inPipe[0], 0);
    dup2(outPipe[1], 1);
    dup2(errPipe[1], 2);
    close(inPipe[0]);
    close(outPipe[1]);
    close(errPipe[1]);

    ubyte[] capturedOut, capturedErr;
    auto writer = new Thread({
        auto remaining = input;
        while (remaining.length) {
            auto n = posixWrite(inPipe[1], remaining.ptr, remaining.length);
            if (n <= 0) break;
            remaining = remaining[cast(size_t) n .. $];
        }
        close(inPipe[1]);
    });
    auto outReader = new Thread({
        ubyte[65536] buffer;
        for (;;) {
            auto n = posixRead(outPipe[0], buffer.ptr, buffer.length);
            if (n <= 0) break;
            capturedOut ~= buffer[0 .. cast(size_t) n];
        }
    });
    auto errReader = new Thread({
        ubyte[65536] buffer;
        for (;;) {
            auto n = posixRead(errPipe[0], buffer.ptr, buffer.length);
            if (n <= 0) break;
            capturedErr ~= buffer[0 .. cast(size_t) n];
        }
    });
    writer.isDaemon = true;
    outReader.isDaemon = true;
    errReader.isDaemon = true;
    writer.start();
    outReader.start();
    errReader.start();

    int code;
    Exception failure;
    auto done = new Semaphore(0);
    auto runner = new Thread({
        try code = runApp(args);
        catch (Exception error) failure = error;
        done.notify();
    });
    runner.isDaemon = true;
    runner.start();
    auto completed = done.wait(30.seconds);

    stdout.flush();
    stderr.flush();
    dup2(savedIn, 0);
    dup2(savedOut, 1);
    dup2(savedErr, 2);
    close(savedIn);
    close(savedOut);
    close(savedErr);

    if (!completed)
        throw new Exception("JSONL invocation did not finish within 30s " ~
            "(possible non-streaming/full-buffering deadlock)");
    runner.join();
    writer.join();
    outReader.join();
    errReader.join();
    if (failure !is null) throw failure;
    return JsonlInvocation(code, capturedOut, cast(string) capturedErr);
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
        runApp(["scrubbed", "run", "--input", input, "--output", output,
            "--config", badConfig, "--threads", "1"]);
        throw new Exception("invalid config was accepted");
    } catch (Exception error) {
        requireCli(error.msg != "invalid config was accepted", "invalid config rejected");
    }
    requireCli(!exists(dirName(output)), "invalid config created output parent");

    requireCli(runApp(["scrubbed", "run", "--input", input, "--output", output,
        "--validate", "--threads", "1"]) == 0, "validate exit");
    requireCli(!exists(dirName(output)), "validate created output parent");
    requireCli(runApp(["scrubbed", "run", "--input", input, "--output", output,
        "--dry-run", "--explain", "--threads", "1"]) == 0, "dry-run exit");
    requireCli(!exists(dirName(output)), "dry-run created output parent");
    requireCli(readText(input) == "line\r\n", "dry-run changed source");
    requireCli(runApp(["scrubbed", "run", "--input", input, "--output", input,
        "--dry-run", "--threads", "1"]) == 0, "same-file dry-run exit");
    requireCli(readText(input) == "line\r\n", "same-file dry-run changed source");

    auto inputTree = buildPath(root, "tree");
    mkdir(inputTree);
    write(buildPath(inputTree, "changed.txt"), "line\r\n");
    write(buildPath(inputTree, "unchanged.txt"), "clean");
    write(buildPath(inputTree, "bad.bin"), [cast(ubyte) 0xFF]);
    auto treeOutput = buildPath(root, "tree-output");
    // #400 regression: `bad.bin`'s invalid UTF-8 is a per-document quarantine
    // outcome now (see the mixed-batch regression above), not a fatal root
    // that cancels the rest of a directory batch -- so this multi-thread,
    // bounded-admission run no longer throws. It still reports the batch's
    // overall nonzero exit status (one quarantined document), and being a
    // dry-run, it still creates no output tree either way.
    requireCli(runApp(["scrubbed", "run", "--input", inputTree, "--output", treeOutput,
        "--dry-run", "--explain", "--threads", "4", "--max-queued-docs", "1",
        "--max-open-inputs", "1"]) == 1, "multi-thread quarantine exit");
    requireCli(!exists(treeOutput), "multi-thread dry-run created output tree");
    version (Posix) {
        import std.file : symlink;
        auto unsafeOutput = buildPath(root, "unsafe-output");
        mkdir(unsafeOutput);
        auto linkedFile = buildPath(unsafeOutput, "changed.txt");
        symlink(input, linkedFile);
        assertThrown(runApp(["scrubbed", "run", "--input", inputTree,
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
    requireCli(runApp(["scrubbed", "run", "--input", input, "--output", plainOutput,
        "--filters", "normalize-line-endings", "--threads", "1"]) == 0,
        "legacy invocation exit");
    requireCli(readText(plainOutput) == "line\n", "legacy invocation output");

    // The test-only fixture stage proves that the switched local sink treats a
    // terminal rejection as an acknowledged per-document outcome: no output
    // is published and the invocation exits 1 rather than becoming fatal.
    auto rejectedOutput = buildPath(root, "rejected.txt");
    requireCli(runApp(["scrubbed", "run", "--input", input, "--output",
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
    assert(runApp(["scrubbed", "run", "--input", input, "--output", routed,
        "--threads", "1"] ~ routeTokens) == 0);
    assert(readText(routed) == "hello");

    auto passOutput = buildPath(root, "passed.txt");
    assert(runApp(["scrubbed", "run", "--input", input, "--output", passOutput,
        "--threads", "1"] ~ dispatchTokens("pass")) == 0);
    assert(readText(passOutput) == "hello");
    foreach (policy; ["reject", "quarantine"]) {
        auto output = buildPath(root, policy ~ ".txt");
        assert(runApp(["scrubbed", "run", "--input", input, "--output", output,
            "--threads", "1"] ~ dispatchTokens(policy)) == 1);
        assert(!exists(output));
    }

    auto below = buildPath(root, "below.txt");
    assertThrown(runApp(["scrubbed", "run", "--input", input, "--output", below,
        "--threads", "1"] ~ dispatchTokens("route", 4)));
    assert(!exists(below));
    auto above = buildPath(root, "above.txt");
    assert(runApp(["scrubbed", "run", "--input", input, "--output", above,
        "--threads", "1"] ~ dispatchTokens("route", 6)) == 0);

    auto invalid = buildPath(root, "invalid.txt");
    ubyte[] invalidBytes = new ubyte[4097];
    invalidBytes[] = 'a';
    invalidBytes[$ - 1] = 0xff;
    write(invalid, invalidBytes);
    auto invalidOutput = buildPath(root, "invalid-output.txt");
    assertThrown(runApp(["scrubbed", "run", "--input", invalid,
        "--output", invalidOutput, "--threads", "1"] ~
        dispatchTokens("route", 5000)));
    assert(!exists(invalidOutput));

    auto malformed = dispatchTokens("route", 5);
    malformed = malformed[0 .. $ - 1] ~ ["--route-option",
        "max-output-bytes=integer:5", "--common"];
    auto unopenedOutput = buildPath(root, "unopened.txt");
    auto unopenedStore = buildPath(root, "unopened.db");
    assertThrown(runApp(["scrubbed", "run", "--input", buildPath(root, "missing"),
        "--output", unopenedOutput, "--manifest", unopenedStore] ~ malformed));
    assert(!exists(unopenedOutput) && !exists(unopenedStore));

    auto durableOutput = buildPath(root, "durable.txt");
    auto durableStore = buildPath(root, "v4.db");
    auto durableArgs = ["scrubbed", "--input", input, "--output", durableOutput,
        "--threads", "1", "--manifest", durableStore] ~ routeTokens;
    assert(runApp(durableArgs) == 0);
    assert(runApp(durableArgs) == 0);
    assertThrown(runApp(["scrubbed", "run", "--input", input, "--output", durableOutput,
        "--threads", "1", "--manifest", durableStore] ~
        dispatchTokens("route", 6)));

    auto v3Output = buildPath(root, "v3.txt");
    auto v3Store = buildPath(root, "v3.db");
    auto v3Args = ["scrubbed", "--input", input, "--output", v3Output,
        "--threads", "1", "--manifest", v3Store];
    assert(runApp(v3Args) == 0);
    assertThrown(runApp(["scrubbed", "run", "--input", input, "--output", v3Output,
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

// Issue #41 -- selected-field JSONL streaming mode (docs/jsonl-stream.md) has
// no other coverage anywhere in the suite. These six tests drive the real
// `runApp` JSONL route through `invokeJsonl` (real OS stdin/stdout, real
// `--input -`/`--output -`, not a mock of the streaming adapter) and prove
// this ticket's six acceptance criteria against that shipped behavior.

unittest {
    // 1) Stable IDs: a record's DocumentId is derived only from
    // --dataset-namespace, --source-key and the record's 1-based physical
    // line ordinal (docs/jsonl-stream.md), independent of transport path.
    // Retrying with the same key and line positions must reproduce the same
    // ID, and a different namespace must not.
    string[] jsonlArgs(string namespace, string sourceKey) {
        return ["scrubbed", "run", "--input", "-", "--output", "-",
            "--jsonl-fields", "text", "--dataset-namespace", namespace,
            "--source-key", sourceKey, "--max-jsonl-line-bytes", "4096",
            "--max-jsonl-output-bytes", "8192"];
    }
    // Line 2 is malformed so the failure diagnostic reports its DocumentId
    // on stderr without needing an --explain/dispatch plan.
    auto input = cast(const(ubyte)[]) "{\"text\":\"ok\"}\n{not-json}\n";

    auto first = invokeJsonl(jsonlArgs("corpus", "logical-source-001"), input);
    auto second = invokeJsonl(jsonlArgs("corpus", "logical-source-001"), input);
    requireCli(first.code == 1 && second.code == 1,
        "malformed second line should fail both runs");
    auto expectedId = DocumentId.from(
        SourceLocator("corpus", "logical-source-001", "2")).text;
    requireCli(first.stderrText.canFind(expectedId) &&
        second.stderrText.canFind(expectedId),
        "reported DocumentId did not match namespace+source-key+ordinal " ~
        "derivation: " ~ first.stderrText);
    requireCli(first.stderrText == second.stderrText,
        "identical retry did not produce identical stable-ID diagnostics");
    requireCli(first.code == second.code &&
        first.stdoutBytes == second.stdoutBytes,
        "identical retry produced different stdout/exit code");

    auto differentNamespace = invokeJsonl(
        jsonlArgs("other-corpus", "logical-source-001"), input);
    requireCli(differentNamespace.code == 1 &&
        !differentNamespace.stderrText.canFind(expectedId),
        "DocumentId did not change with a different dataset namespace");
}

unittest {
    // 2) Explicit JSON null is preserved (not dropped, not coerced to "").
    // docs/jsonl-stream.md: "All other fields retain their parsed JSON
    // semantic values ... including ... null" for anything not itself
    // selected for text transform. A field that IS selected for transform is
    // separately documented as "must be a JSON string when present"; confirm
    // that's a loud, distinct invalidText failure rather than the null being
    // silently coerced away.
    import std.string : splitLines;

    auto base = ["scrubbed", "run", "--input", "-", "--output", "-",
        "--jsonl-fields", "text", "--dataset-namespace", "corpus",
        "--source-key", "nulls", "--max-jsonl-line-bytes", "4096",
        "--max-jsonl-output-bytes", "8192"];

    auto passthrough = invokeJsonl(base, cast(const(ubyte)[])
        "{\"text\":\"hello\",\"note\":null,\"tags\":[1,null,\"x\"]}\n");
    requireCli(passthrough.code == 0,
        "explicit-null record should succeed: " ~ passthrough.stderrText);
    auto lines = (cast(string) passthrough.stdoutBytes).splitLines();
    requireCli(lines.length == 1, "expected exactly one output record");
    auto parsed = parseJSON(lines[0]);
    requireCli(parsed["note"].type == JSONType.null_,
        "unselected null field was dropped or coerced");
    requireCli(parsed["tags"].array[1].type == JSONType.null_,
        "nested null array element was dropped or coerced");
    requireCli(parsed["text"].str == "hello", "selected field unexpectedly changed");

    auto selectedNull = invokeJsonl(base, cast(const(ubyte)[]) "{\"text\":null}\n");
    requireCli(selectedNull.code == 1 && selectedNull.stdoutBytes.length == 0 &&
        selectedNull.stderrText.canFind("invalidText"),
        "null in a selected field was not rejected as documented: " ~
        selectedNull.stderrText);
}

unittest {
    // 3) Unicode round-trip: multi-byte UTF-8 (accented Latin, CJK, and an
    // astral-plane emoji requiring a 4-byte UTF-8 sequence) in a selected
    // field must come back byte-for-byte identical.
    import std.string : splitLines;

    auto original = "héllo wörld café résumé 日本語のテスト emoji😀🎉 中文测试";
    auto args = ["scrubbed", "run", "--input", "-", "--output", "-",
        "--jsonl-fields", "text", "--dataset-namespace", "corpus",
        "--source-key", "unicode", "--max-jsonl-line-bytes", "4096",
        "--max-jsonl-output-bytes", "8192"];
    auto record = JSONValue(["text": JSONValue(original)]);
    auto line = record.toString() ~ "\n";
    auto result = invokeJsonl(args, cast(const(ubyte)[]) line);
    requireCli(result.code == 0, "unicode record should succeed: " ~ result.stderrText);
    auto lines = (cast(string) result.stdoutBytes).splitLines();
    requireCli(lines.length == 1, "expected exactly one output record");
    auto parsed = parseJSON(lines[0]);
    requireCli(parsed["text"].str == original,
        "unicode content did not round-trip through JSON parsing");
    requireCli(canFind(result.stdoutBytes, cast(const(ubyte)[]) original),
        "unicode bytes were not preserved verbatim (byte-for-byte) in raw stdout");
}

unittest {
    // 4) Schema-version field: --explain in v4/dispatch JSONL mode emits one
    // bounded scrubbed.dispatch.v1 record per present selected field to
    // stderr (docs/jsonl-stream.md), and its document_id follows the same
    // namespace+source-key+ordinal derivation proven in criterion 1.
    import std.algorithm.iteration : filter;
    import std.string : splitLines;

    string[] passDispatchTokens() {
        auto tokens = [
            "--dispatch-option", "detector-prefix-bytes=4096",
            "--dispatch-option", "detector-evidence-records=16",
            "--dispatch-option", "detector-warnings=8",
            "--dispatch-option", "container-max-physical-bytes=33554432",
            "--dispatch-option", "container-max-expanded-bytes=134217728",
            "--dispatch-option", "container-max-entries=2048",
            "--dispatch-option", "container-max-depth=2",
            "--dispatch-option", "container-max-ratio=100",
        ];
        foreach (outcome; ["unknown", "plain-text", "html", "pdf", "png",
                "jpeg", "gif", "ambiguous", "malformed", "encrypted",
                "unsupported", "generic-zip", "ooxml-word"])
            tokens ~= ["--action", outcome ~ "=" ~
                (outcome == "plain-text" ? "pass" : "reject") ~ ":policy"];
        tokens ~= "--common";
        return tokens;
    }

    auto args = ["scrubbed", "run", "--input", "-", "--output", "-",
        "--jsonl-fields", "text", "--dataset-namespace", "corpus",
        "--source-key", "explain-source", "--max-jsonl-line-bytes", "4096",
        "--max-jsonl-output-bytes", "8192", "--explain"] ~ passDispatchTokens();
    auto result = invokeJsonl(args, cast(const(ubyte)[]) "{\"text\":\"hello world\"}\n");
    requireCli(result.code == 0,
        "explain dispatch run should succeed: " ~ result.stderrText);

    auto explainLines = result.stderrText.splitLines()
        .filter!(l => l.startsWith("EXPLAIN\t")).array;
    requireCli(explainLines.length == 1,
        "expected exactly one bounded dispatch record for the single " ~
        "present selected field: " ~ result.stderrText);
    auto record = parseJSON(explainLines[0]["EXPLAIN\t".length .. $]);
    requireCli(record["schema"].str == "scrubbed.dispatch.v1",
        "schema-version field missing or incorrect: " ~ explainLines[0]);
    auto expectedId = DocumentId.from(
        SourceLocator("corpus", "explain-source", "1")).text;
    requireCli(record["document_id"].str == expectedId,
        "explain record document_id did not match stable-ID derivation");
}

unittest {
    // 5) Round-trip through a real pinned reader: parse real output from the
    // built binary with Python's stdlib json module, one json.loads() call
    // per line, matching this repo's uv-pinned-Python-tooling convention.
    import std.process : execute;
    import std.file : tempDir, remove;
    import std.string : splitLines;

    auto pythonAvailable = execute(["python3", "--version"]);
    requireCli(pythonAvailable.status == 0,
        "python3 must be on PATH for the pinned-reader proof");

    auto args = ["scrubbed", "run", "--input", "-", "--output", "-",
        "--jsonl-fields", "text", "--dataset-namespace", "corpus",
        "--source-key", "python-roundtrip", "--max-jsonl-line-bytes", "4096",
        "--max-jsonl-output-bytes", "8192"];
    auto input =
        "{\"text\":\"plain\",\"n\":18446744073709551615,\"note\":null}\n" ~
        "{\"text\":\"日本語 emoji😀\",\"tags\":[1,null,true]}\n";
    auto result = invokeJsonl(args, cast(const(ubyte)[]) input);
    requireCli(result.code == 0,
        "python round-trip fixture should succeed: " ~ result.stderrText);
    requireCli((cast(string) result.stdoutBytes).splitLines().length == 2,
        "expected exactly two output records");

    auto outPath = buildPath(tempDir,
        "scrubbed-jsonl-py-" ~ randomUUID.toString ~ ".jsonl");
    write(outPath, result.stdoutBytes);
    scope(exit) if (exists(outPath)) remove(outPath);

    auto script = "import json, sys\n" ~
        "path = sys.argv[1]\n" ~
        "with open(path, \"r\", encoding=\"utf-8\") as handle:\n" ~
        "    lines = [line for line in handle.read().split(\"\\n\") if line]\n" ~
        "assert len(lines) == 2, f\"expected 2 lines, got {len(lines)}\"\n" ~
        "first = json.loads(lines[0])\n" ~
        "second = json.loads(lines[1])\n" ~
        "assert first[\"text\"] == \"plain\"\n" ~
        "assert first[\"n\"] == 18446744073709551615\n" ~
        "assert first[\"note\"] is None\n" ~
        "assert second[\"text\"] == \"日本語 emoji😀\"\n" ~
        "assert second[\"tags\"] == [1, None, True]\n" ~
        "print(\"python round-trip: ok\")\n";
    auto pythonResult = execute(["python3", "-c", script, outPath]);
    requireCli(pythonResult.status == 0 &&
        pythonResult.output.canFind("python round-trip: ok"),
        "python json.loads round-trip failed: " ~ pythonResult.output);
}

unittest {
    // 6) Streaming memory-boundedness: a large-N synthetic input, driven
    // through an OS pipe far smaller than the total payload, must complete
    // (invokeJsonl's bounded wait turns a full-buffering deadlock into a
    // failure rather than hanging); and a single record's raw bytes are
    // genuinely capped by --max-jsonl-line-bytes, not just the aggregate.
    import std.array : appender, replicate;
    import std.string : splitLines;

    auto args = ["scrubbed", "run", "--input", "-", "--output", "-",
        "--jsonl-fields", "text", "--dataset-namespace", "corpus",
        "--source-key", "large-n", "--max-jsonl-line-bytes", "256",
        "--max-jsonl-output-bytes", "512"];
    enum recordCount = 20_000;
    auto input = appender!string;
    foreach (i; 0 .. recordCount)
        input.put("{\"text\":\"record-" ~ i.to!string ~ "\"}\n");
    requireCli(input.data.length > 256 * 1024,
        "synthetic input must exceed a typical OS pipe buffer to prove streaming");

    auto result = invokeJsonl(args, cast(const(ubyte)[]) input.data);
    requireCli(result.code == 0, "large-N stream should succeed: " ~ result.stderrText);
    requireCli((cast(string) result.stdoutBytes).splitLines().length == recordCount,
        "large-N stream lost or duplicated records");
    requireCli(result.stderrText.canFind(recordCount.to!string ~ " records processed"),
        "large-N stream completion count mismatch: " ~ result.stderrText);

    auto oversizedText = replicate("x", 300);
    auto capped = invokeJsonl(args, cast(const(ubyte)[])
        ("{\"text\":\"" ~ oversizedText ~ "\"}\n"));
    requireCli(capped.code == 1 && capped.stdoutBytes.length == 0 &&
        capped.stderrText.canFind("inputLimit"),
        "oversized record was not rejected by the per-record byte cap: " ~
        capped.stderrText);
}
